# DCache 设计规格书

> **版本**: v1.1
> **日期**: 2026-04-24
> **状态**: 已实现，FPGA 验证通过（src2 通过）
> **关联决策**: design_decisions.md 决策 L/N

---

## 1. 设计目标

| 目标 | 要求 |
|------|------|
| **消除 250MHz 瓶颈** | DRAM 68×BRAM36 布线（4.71ns）不再在 CPU 关键路径上 |
| **性能不降级** | 250MHz + DCache ≥ 200MHz 无 Cache 的吞吐量 |
| **实现简洁** | 学生竞赛项目，可维护性优先 |

---

## 2. 架构参数（仿真确定）

> 参数由 `cache_sweep.py` 在 4 个测试程序上扫描 1440 种配置后确定。

| 参数 | 值 | 理由 |
|------|:--:|------|
| **容量** | 2KB | vs 4KB 仅差 0.5% hit rate，省一半 BRAM |
| **关联度** | 2-way set-associative | vs 4W 差 0.1%，省 1 级 way MUX |
| **行大小** | 16B (4 words) | 16B 与 32B 在无 CWF 下差距小，实现简单 |
| **组数** | 64 组 | 2KB / 2way / 16B = 64 sets |
| **写策略** | Write-Through | 与 WB 性能相同（有 Store Buffer 时），无 dirty bit，简单 |
| **Write-Allocate** | Yes | 明显优于 NWA |
| **Store Buffer** | Yes (1 entry) | WT 必须有，否则每 store 都 stall |
| **替换策略** | LRU (1-bit per set) | 2-way LRU 只需 1 bit |

### 预期性能（DRAM 2 cycle/word）

| 程序 | Hit Rate | CPI | vs 200MHz |
|------|:------:|:---:|:---------:|
| current | 97.75% | 1.014 | +23.3% |
| src0 | ~96% | ~1.02 | +22% |
| **平均** | **~97.9%** | **~1.013** | **+23.5%** |

---

## 3. 地址位分解

```
CPU 字节地址 [31:0]:

  31        22  21  20  19 18  17        10  9    4  3    2  1  0
 ┌──────────┬───┬───┬───┬───┬────────────┬────────┬──────┬──────┐
 │ 高位恒定  │   │   │   │   │            │        │      │      │
 │(不使用)   │ 0 │ 1 │ 0 │ 0 │  Tag (8b)  │Index(6)│ Word │ Byte │
 │           │   │   │   │   │ addr[17:10]│ [9:4]  │[3:2] │ [1:0]│
 └──────────┴───┴───┴───┴───┴────────────┴────────┴──────┴──────┘
                │   │
                │   └── addr[20]=1: DRAM 区域（可缓存）
                └────── addr[21]=0: 非 MMIO
```

| 字段 | 位范围 | 宽度 | 说明 |
|------|:------:|:----:|------|
| Tag | addr[17:10] | 8 bit | 与存储的 tag 比较判断命中 |
| Index | addr[9:4] | 6 bit | 选择组（64 组） |
| Word offset | addr[3:2] | 2 bit | 行内字选择（4 字） |
| Byte offset | addr[1:0] | 2 bit | 字内字节（LB/LH 用） |

### 可缓存判定

```sv
wire is_cacheable = alu_addr[20] & ~alu_addr[21] & ~alu_addr[19] & ~alu_addr[18];
// 4 输入 → 1 LUT，0 额外延迟
// 等价于: addr 在 0x8010_0000 ~ 0x8013_FFFF (DRAM 256KB 范围)
```

---

## 4. 存储结构

### 4.1 Tag RAM（LUTRAM，每 way 独立）

```
Way 0 Tag RAM: 64 entries × (1 valid + 8 tag) = 64 × 9 bit
Way 1 Tag RAM: 64 entries × (1 valid + 8 tag) = 64 × 9 bit
LRU RAM:       64 entries × 1 bit
```

| 字段 | 位宽 | 说明 |
|------|:----:|------|
| valid | 1 | 行有效标志 |
| tag | 8 | addr[17:10] |
| **合计/way** | **9** | |

**为什么用 LUTRAM**：
- 异步读：tag 在 EX 级呈地址后立即可用，不需要等时钟沿
- 64×9 bit 很小，2-3 个 LUTRAM slice 即可

### 4.2 Data RAM（BRAM18，每 way 独立）

```
Way 0 Data RAM: 64 sets × 4 words × 32 bit = 8 Kbit → 1 BRAM18
Way 1 Data RAM: 64 sets × 4 words × 32 bit = 8 Kbit → 1 BRAM18

BRAM 地址 = {index[5:0], word_offset[1:0]} = 8 bit → 256 entries × 32 bit
```

每个 way 用 1 个 BRAM18，共 2 个 BRAM18（= 1 BRAM36）。

**对比：当前 DRAM 使用 68×BRAM36 → 降为 1×BRAM36**。

### 4.3 Store Buffer（寄存器）

```
1 entry:
  ┌───────┬──────┬───────┬───────┐
  │ valid │ addr │ data  │  wea  │
  │  (1)  │ (18) │ (32)  │  (4)  │
  └───────┴──────┴───────┴───────┘
```

- 深度 1：WT 每个 store hit 只需缓冲 1 次 DRAM 写
- FSM 空闲时（IDLE 且无 miss）排空 store buffer → 写入 DRAM
- 如果 store buffer 满且新 store 来了 → stall 1 cycle 先排空

---

## 5. 流水线集成

### 5.1 Cache 在流水线中的位置

```
IF ──→ ID ──→ EX ──→ MEM ──→ WB
                │      │
                │      ├── Cache tag 比较 (LUTRAM 异步读, EX级呈地址)
                │      ├── Cache data 读 (BRAM, EX级地址→MEM级数据)
                │      ├── hit/miss 判定
                │      └── miss FSM (stall pipeline)
                │
                └── is_cacheable 判定 (1 LUT)
                └── alu_addr → Cache 地址端口
```

### 5.2 时序模型（1-cycle hit）

```
Cycle N (EX stage):
  ├── alu_addr 计算完成
  ├── addr → Tag LUTRAM 异步读 → tag_way0, tag_way1 (EX级可用)
  ├── addr → Data BRAM 地址端口 (注册)
  └── is_cacheable → EX/MEM 寄存器

Cycle N+1 (MEM stage):
  ├── Tag 比较: tag_stored == addr_tag → hit_way0, hit_way1
  ├── Data BRAM 输出可用 → data_way0, data_way1
  ├── Way 选择 MUX: hit_wayN → data_out
  ├── hit = hit_way0 | hit_way1
  └── mem_ready_go = !is_mem_access | hit | !cacheable | fsm_done
```

### 5.3 信号时序

```
          EX stage            │         MEM stage
                              │
  alu_addr ──→ Tag LUTRAM ────│──→ tag compare ──→ hit
  alu_addr ──→ Data BRAM addr │──→ data out ──→ way MUX ──→ cache_dout
  alu_addr ──→ is_cacheable ──│──→ (from EX/MEM reg)
                              │
                        EX/MEM edge
```

### 5.4 MEM 级控制信号

```sv
// Cache hit 判定 (dcache.sv 内部, MEM stage 组合逻辑)
wire hit_w0 = mem_tag_vld[0] & (mem_tag_rd[0] == mem_tag) | (rf_fwd_match & ~rf_fwd_way);
wire hit_w1 = mem_tag_vld[1] & (mem_tag_rd[1] == mem_tag) | (rf_fwd_match &  rf_fwd_way);
wire cache_hit = hit_w0 | hit_w1;

// cpu_ready 由 dcache.sv 内部生成:
//   IDLE + cache_hit & ~sb_conflict → ready
//   S_DONE → ready
//   其他状态 → not ready

// cpu_top.sv 中:
wire mem_ready_go_w = cache_ready;  // DCache 控制 MEM stage flow
wire mem_allowin = !mem_valid | (mem_ready_go & wb_allowin);
```

> **注意**: 实际实现还包括 refill tag 前递、store 字节级前递、refill 最后一个 word 前递等机制。详见 `dcache.sv` 源码。

---

## 6. Miss 处理状态机

### 6.1 状态定义

```
         ┌──────────────────────────────────────────────────┐
         │                                      flush   │
         ▼                                              │
      ┌──────┐   miss  ┌───────────┐  ┌─────────┐  ┌────────┐  ┌──────┐  │
 ────→│ IDLE │─────→│ REFILL    │─→│ REFILL  │─→│DONE_RD │─→│ DONE │──┘
      └──┬───┘       │ _BURST    │  │ _DRAIN  │  │(BRAM rd)│  │(完成) │
         │          └────┬──────┘  └────┬────┘  └────────┘  └──────┘
         │ sb_valid      │ addr done    │ all data
         │ (always       │              │ received
         │  drain first) │              │
         ▼               │              │
      ┌──────────┐       │              │
      │ SB_DRAIN │       │              │
      └──────────┘       │              │
```

| 状态 | 行为 | 持续 |
|------|------|:----:|
| **S_IDLE** | 正常运行，cache hit 1 cycle 通过 | 1 cycle |
| **S_REFILL_BURST** | 发送地址 + 接收数据（pipeline 重叠） | ~4 cycles |
| **S_REFILL_DRAIN** | 地址发送完毕，等剩余数据到达 | ~2 cycles |
| **S_DONE_RD** | DCache BRAM 读取 hit word | 1 cycle |
| **S_DONE** | 写入 tag，解除 stall，输出数据 | 1 cycle |
| **S_SB_DRAIN** | Store buffer 排空到 DRAM | 1 cycle |

> **flush 处理**: 任何非 IDLE/SB_DRAIN 状态下收到 flush 立即回 IDLE。
> Refill 开始时先失效 victim tag，防止 flush 中断后部分覆写的 line 被命中。

### 6.2 REFILL 流程（DRAM 2 cycle read latency，DOB_REG=1）

```
                Registered addr
Cache FSM ───→ [dram_rd_addr] ───→ DRAM BRAM (DOB_REG=1)
                                        │
DRAM BRAM output register ───→ Cache FSM (dram_rdata)

Timeline (4 words, DRAM_LATENCY=4, including dram_rdata_r):
  burst_cycle=0: S_REFILL_BURST  send addr[0]
  burst_cycle=1: S_REFILL_BURST  send addr[1]
  burst_cycle=2: S_REFILL_BURST  send addr[2]
  burst_cycle=3: S_REFILL_BURST  send addr[3], dram_rdata_r=data[0] → write
  burst_cycle=4: S_REFILL_DRAIN                dram_rdata_r=data[1] → write
  burst_cycle=5: S_REFILL_DRAIN                dram_rdata_r=data[2] → write
  burst_cycle=6: S_REFILL_DRAIN                dram_rdata_r=data[3] → write
  burst_cycle=7: S_DONE_RD       DCache BRAM read for hit word
  burst_cycle=8: S_DONE          output data, update tag, signal ready

启动延迟 = DRAM_LATENCY = 4 cycles (registered addr + BRAM read + output register + dram_rdata_r)
稳态吞吐 = 1 word / cycle (pipeline overlap)
4 字 refill = 9 cycles total

总 miss penalty ≈ 9 cycles
```

> [!IMPORTANT]
> DRAM4MyOwn IP 配置了 `Register_PortB_Output_of_Memory_Primitives = true`（DOB_REG=1），
> 读延迟为 2 cycle。再加上 `dram_rd_addr` 寄存器和 DCache 内部 `dram_rdata_r` 寄存器，总延迟 = DRAM_LATENCY = 4。
> `rf_data_valid = (rf_burst_cycle >= DRAM_LATENCY)` 确保在正确时刻开始采样数据。

### 6.3 Store Buffer 排空

```
FSM 在 IDLE 状态检查:
  if (sb_valid) → S_SB_DRAIN  // 无论是否有 miss，先排 SB
  SB_DRAIN: 将 sb_addr/sb_data/sb_wea 写入 DRAM (1 cycle)
  完成后 → IDLE, sb_valid ← 0, 重新评估 miss

如果 miss 和 sb_drain 同时需要:
  SB drain 优先！否则 refill 从 DRAM 读到的是过时数据（SB 还没写回）。
  drain 后 FSM 回 IDLE，重新检测 miss 并启动 refill。
```

---

## 7. Store 处理（Write-Through + Write-Allocate）

### 7.1 Store Hit

```
1. 写入 Cache data RAM (当前 way, 当前 word) → 1 cycle
2. 写入 Store Buffer (addr + data + wea) → 1 cycle (同步)
3. Pipeline 不 stall（store buffer 吸收了 DRAM 写延迟）
4. Store buffer 在后台排空到 DRAM
```

### 7.2 Store Miss (Write-Allocate)

```
1. 触发 REFILL（和 load miss 一样，从 DRAM 取整行）
2. REFILL 完成后，写入 Cache data RAM
3. 同时写入 Store Buffer
4. 解除 stall
```

### 7.3 Store Buffer 满（sb_conflict）

```
如果 store hit 但 sb_valid=1（上一次还没排空）:
  → sb_conflict = 1 → FSM 进入 S_SB_DRAIN
  → cpu_ready = 0 (cache_hit & ~sb_conflict = 0)
  → SB_DRAIN 排空后回 IDLE，重新评估 store hit，此时 sb_valid=0，正常写入
```

---

## 8. 系统架构变更

### 8.1 总体拓扑

```
                         ┌─────────────────────────┐
                         │       cpu_top.sv         │
                         │                          │
  IROM ←── irom_addr ←───┤  IF → ID → EX → MEM → WB│
                         │              │    │      │
                         │     is_cacheable  │      │
                         │         │    │    │      │
                         └─────────┼────┼────┼──────┘
                                   │    │    │
                              ┌────┘    │    └────┐
                              │         │         │
                         ┌────▼────┐    │    ┌────▼────┐
                         │  DCache  │    │    │ MMIO    │
                         │ (新增)   │    │    │ Bridge  │
                         │          │    │    │ (精简)  │
                         │ tag RAM  │    │    │ LED/SEG │
                         │ data RAM │    │    │ SW/KEY  │
                         │ FSM      │    │    │ CNT     │
                         │ sb       │    │    └─────────┘
                         └────┬─────┘    │
                              │          │
                         ┌────▼────┐     │
                         │  DRAM   │     │
                         │ BRAM IP │     │
                         │65536×32 │     │
                         └─────────┘     │
                                         │
                         student_top.sv 例化以上所有
```

### 8.2 模块改动清单

| 模块 | 改动 | 复杂度 |
|------|------|:------:|
| **dcache.sv** | **新增**：完整 cache 模块 | ★★★★ |
| student_top.sv | 例化 DCache，重新接线 | ★★ |
| perip_bridge.sv | 移除 DRAM，瘦身为 mmio_bridge | ★★ |
| cpu_top.sv | 增加 is_cacheable；删除 store_load_hazard；cache 接口 | ★★ |
| ex_mem_reg.sv | 传递 is_cacheable 到 MEM 级 | ★ |
| mem_wb_reg.sv | dram_dout → cache_dout | ★ |
| forwarding.sv | 无逻辑变化，仅信号改名 | ★ |

### 8.3 CPU 端口变更

```sv
// cpu_top.sv 端口定义
module cpu_top (
    ...
    // DCache 接口 (EX → MEM stage)
    output logic        cache_req,              // EX: 有访存请求
    output logic        cache_wr,               // EX: 0=load, 1=store
    output logic [31:0] cache_addr,             // EX: 访存地址
    output logic [ 3:0] cache_wea,              // EX: 字节写使能
    output logic [31:0] cache_wdata,            // EX: 写数据
    input  logic [31:0] cache_rdata,            // MEM: 读数据
    input  logic        cache_ready,            // MEM: 命中或完成
    output logic        cache_flush,            // MEM: flush（分支错误中断 refill）
    output logic        cache_pipeline_stall,   // ~mem_allowin（同步 DCache EX→MEM）

    // MMIO 接口
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wr_addr,
    output logic [ 3:0] mmio_wea,
    output logic [31:0] mmio_wdata,
    input  logic [31:0] mmio_rdata
);
```

---

## 9. 时序分析

### 9.1 Cache Hit 路径（MEM 级，250MHz）

```
EX/MEM_reg Clk-to-Q                       ~0.3ns
  │
  tag compare: 8-bit (2 ways 并行)          ~0.5ns  (2 LUT levels)
  │
  hit = valid & tag_match                   ~0.1ns  (merged)
  │
  way select: 2:1 MUX (32-bit)             ~0.3ns  (1 LUT level)
  │
  MEM/WB_reg Setup                         ~0.2ns
  ─────────────────────────────────────────
  总计                                      ~1.4ns ≪ 4.0ns (250MHz)
  余量                                      ~2.6ns ✅
```

### 9.2 DRAM 访问路径（Miss FSM）

```
DRAM4MyOwn 已配置 DOB_REG=1，读延迟 = 2 cycle。加上 registered addr 和 `dram_rdata_r`，总延迟 = 4 cycle = DRAM_LATENCY。

段 1: FSM addr_reg → [routing] → DRAM BRAM addr pin
      ~2.4ns < 4.0ns ✅

段 2: DRAM BRAM output (DOB_REG) → [routing] → DCache data path
      ~2.4ns < 4.0ns ✅

DOB_REG 既提供时序分段（降低布线压力），又是 DRAM IP 固有配置。
```

---

## 10. 面积估算

| 资源 | 用量 | 说明 |
|------|:----:|------|
| BRAM18 | 2 | Data RAM (每 way 1 个) |
| BRAM36 | 0 | (2×BRAM18 = 1×BRAM36 等价) |
| LUTRAM | ~4 slice | Tag RAM (2 way × 64×9bit) |
| FF | ~80 | FSM + Store Buffer + 控制 |
| LUT | ~200 | Tag compare + MUX + FSM |

**对比：当前 DRAM 68×BRAM36 → Cache 仅 1×BRAM36 + 少量 LUT**。
释放 67×BRAM36 → 布线压力大幅缓解。

---

## 11. 测试要点

| 测试项 | 验证目标 |
|--------|---------|
| Load hit / miss | 基本功能 |
| Store hit (WT) | Cache + Store Buffer 写入 |
| Store miss (WA) | Refill → Store → SB drain |
| LRU 替换 | 2-way 交替访问不同 tag |
| MMIO bypass | LED/SEG/SW/KEY 不经 Cache |
| Store Buffer 满 | SB drain stall 正确性 |
| Miss 期间 pipeline stall | allowin 链冻结 |
| 冷启动 | 全 miss，逐步填充 |
