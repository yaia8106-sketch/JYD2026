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
// Cache hit 判定 (MEM stage, 组合逻辑)
wire hit_way0 = tag_valid[0] && (tag_data[0] == mem_addr_tag);
wire hit_way1 = tag_valid[1] && (tag_data[1] == mem_addr_tag);
wire cache_hit = hit_way0 | hit_way1;
wire hit_way = hit_way1;  // 0=way0, 1=way1 (for data MUX)

// MEM stage ready_go
wire mem_ready_go = !mem_valid
                  | !mem_is_mem_access          // 非访存指令
                  | !mem_cacheable_r             // MMIO: 假设 1 cycle 直通
                  | (mem_cacheable_r & cache_hit) // Cache hit
                  | fsm_done;                    // Miss refill 完成

wire mem_allowin = !mem_valid | (mem_ready_go & wb_allowin);
```

---

## 6. Miss 处理状态机

### 6.1 状态定义

```
         ┌──────────────────────────────────────────────┐
         │                                              │
         ▼                                              │
      ┌──────┐   miss    ┌──────────┐  done  ┌──────┐  │
 ────→│ IDLE │──────────→│  REFILL  │───────→│ DONE │──┘
      └──┬───┘           └────┬─────┘        └──────┘
         │                    │
         │ sb_valid &         │ word_cnt++
         │ sb_drain           │ DRAM read
         ▼                    │
      ┌──────────┐            │
      │ SB_DRAIN │            │
      │(Store Buf│            │
      │  排空)   │            │
      └──────────┘            │
                              │
```

| 状态 | 行为 | 持续 |
|------|------|:----:|
| **IDLE** | 正常运行，cache hit 1 cycle 通过 | 1 cycle |
| **REFILL** | 从 DRAM 逐字读取，填充 cache line | 4 × N cycles |
| **DONE** | 写入 tag，解除 stall | 1 cycle |
| **SB_DRAIN** | Store buffer 排空到 DRAM | N cycles |

### 6.2 REFILL 流程（DRAM 2 cycle read latency，DOB_REG=1）

```
                Registered addr
Cache FSM ───→ [dram_rd_addr] ───→ DRAM BRAM (DOB_REG=1)
                                        │
DRAM BRAM output register ───→ Cache FSM (dram_rdata)

Timeline (4 words, DRAM_LATENCY=3):
  burst_cycle=0: dram_rd_addr_r<=addr[0] (registered from IDLE transition)
  burst_cycle=1: dram_rd_addr_r<=addr[1], DRAM sees addr[0]
  burst_cycle=2: dram_rd_addr_r<=addr[2], DRAM sees addr[1], dram_rdata=data[0] → write
  burst_cycle=3: dram_rd_addr_r<=addr[3], DRAM sees addr[2], dram_rdata=data[1] → write
  burst_cycle=4: (DRAIN)                  DRAM sees addr[3], dram_rdata=data[2] → write
  burst_cycle=5: (DRAIN)                                     dram_rdata=data[3] → write
  burst_cycle=6: S_DONE_RD  DCache BRAM read for hit word
  burst_cycle=7: S_DONE     output data, update tag, signal ready

启动延迟 = DRAM_LATENCY = 3 cycles (registered addr + BRAM read + output register)
稳态吞吐 = 1 word / cycle (pipeline overlap)
4 字 refill = 8 cycles total

总 miss penalty ≈ 8 cycles
```

> [!IMPORTANT]
> DRAM4MyOwn IP 配置了 `Register_PortB_Output_of_Memory_Primitives = true`（DOB_REG=1），
> 读延迟为 2 cycle。加上 `dram_rd_addr` 寄存器的 1 cycle，总延迟 = DRAM_LATENCY = 3。
> `rf_data_valid = (rf_burst_cycle >= DRAM_LATENCY)` 确保在正确时刻开始采样数据。

### 6.3 Store Buffer 排空

```
FSM 在 IDLE 状态检查:
  if (sb_valid && !new_miss) → SB_DRAIN
  SB_DRAIN: 将 sb_addr/sb_data/sb_wea 写入 DRAM (1-2 cycles)
  完成后 → IDLE, sb_valid ← 0

如果 miss 和 sb_drain 同时需要:
  miss 优先（CPU 在等），store buffer 等 refill 完成后再排
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

### 7.3 Store Buffer 满

```
如果新 store 来了但 sb_valid=1（上一次还没排空完）:
  → mem_ready_go = 0, stall 1 cycle
  → FSM 排空 store buffer → sb_valid=0
  → 重试 store
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
// cpu_top.sv 新增端口
module cpu_top (
    ...
    // DCache 接口 (替代原 perip_* 端口)
    output logic        cache_req,          // 有访存请求
    output logic        cache_cacheable,    // 可缓存
    output logic        cache_wr,           // 0=load, 1=store
    output logic [31:0] cache_addr,         // 地址 (EX stage)
    output logic [ 3:0] cache_wea,          // 字节写使能
    output logic [31:0] cache_wdata,        // 写数据
    input  logic [31:0] cache_rdata,        // 读数据 (MEM stage)
    input  logic        cache_ready,        // hit 或 refill 完成

    // MMIO 接口 (保留原有)
    output logic [31:0] mmio_addr,
    output logic [31:0] mmio_wr_addr,
    output logic [ 3:0] mmio_wea,
    output logic [31:0] mmio_wdata,
    input  logic [31:0] mmio_rdata,
    ...
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
需要 pipeline register 将 4.71ns 路径分成两段:

段 1: FSM addr_reg → [routing] → DRAM BRAM addr pin
      ~2.4ns < 4.0ns ✅

段 2: DRAM BRAM output → [routing] → FSM data_reg
      ~2.4ns < 4.0ns ✅

如果时序允许，可去掉 pipeline register (1 cycle/word)
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
