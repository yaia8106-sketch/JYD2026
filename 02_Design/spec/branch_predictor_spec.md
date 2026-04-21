# 分支预测器架构规格书

> 状态：✅ RTL 实现完成，FPGA 验证通过 | 最后更新：2026-04-19

---

## 1. 设计目标

采用 **NLP (Next-Line Predictor) 两级预测架构**，将 Tournament 预测逻辑从 IF 级分离到 ID 级：
- **IF 级（L0 快速预测）**：BTB 直接映射 + Bimodal bht[1] → 驱动 IROM 地址（2-3 级逻辑）
- **ID 级（L1 Tournament 验证）**：完整 Tournament 并行验证 → 不一致时 redirect（1 bubble）
- **EX 级**：最终确认 + 所有状态更新（不变）

**适用指令**：JAL、CALL（JAL rd=ra）、B-type、RET（JALR rs1=ra rd=x0）
**不适用**：非 RET 的 JALR（不预测，每次 2 拍惩罚）

---

## 2. 架构总览

### 2.1 预测器类型

**Tournament 预测器**（竞争选择）：Bimodal + GShare，由 Selector 动态选择更可靠的一方。

```
四个核心硬件结构：

┌──────────────────────────────────────────────────────┐
│  BTB (Branch Target Buffer)                          │
│  64 entry, direct-mapped (NLP: 消除 way 选择逻辑)   │
│  每条目: valid(1)+tag(7)+target(30)+type(2)+bht(2)   │
│  = 42 bit/entry，无 LRU                              │
│  实现: LUTRAM                                        │
├──────────────────────────────────────────────────────┤
│  GShare 预测器                                       │
│  GHR: 8-bit 全局历史寄存器                           │
│  PHT: 256 × 2-bit 饱和计数器                        │
│  索引: GHR[7:0] ⊕ PC[9:2]                           │
│  实现: LUTRAM                                        │
├──────────────────────────────────────────────────────┤
│  Selector (竞争选择器)                               │
│  256 × 2-bit 饱和计数器                              │
│  索引: GHR[7:0]                                      │
│  ≥2 信 Bimodal, <2 信 GShare                        │
│  实现: LUTRAM                                        │
├──────────────────────────────────────────────────────┤
│  RAS (Return Address Stack)                          │
│  4 条目, 移位寄存器实现                              │
│  实现: 4 × 32-bit 寄存器                             │
└──────────────────────────────────────────────────────┘
```

### 2.2 NLP 流水线交互

```
  IF 阶段（L0 快速预测）       ID 阶段（L1 Tournament验证）  EX 阶段（只写，时序）
┌─────────────────────┐   ┌─────────────────────┐   ┌──────────────────────┐
│ PC → BTB LUTRAM读   │   │ 从IF/ID reg读取:    │   │ 分支确认后:          │
│    → tag比较(1级)   │   │  · bht, pht, sel    │   │  · BTB 写入/更新     │
│    → bht[1](Bimodal)│   │                     │   │  · Bimodal 计数器更新│
│    → target MUX     │   │ L1 Tournament决策:  │   │  · GHR 移位          │
│    → IROM addr      │   │  bimodal vs gshare  │   │  · PHT 计数器更新    │
│                     │   │  via selector       │   │  · Selector 更新     │
│ 并行(不在关键路径): │  │                     │   │  · RAS push/pop      │
│  · PHT 读           │   │ L0≠L1 且为BRANCH:  │   │                      │
│  · Selector 读      │   │  → id_bp_redirect   │   │ 误预测时:            │
│                     │   │  → flush IF, 1bubble│   │  · branch_flush      │
└─────────────────────┘   └─────────────────────┘   └──────────────────────┘
     2-3 级逻辑 ~3.3ns         纯组合，不限时序           纯时序
```

**关键原则**：
- **IF 阶段（L0）**：仅 BTB 读 + tag 比较 + bht[1] 快速方向决策，**极短关键路径**
- **ID 阶段（L1）**：Tournament（Bimodal vs GShare via Selector）验证 L0，不一致时 redirect
- **EX 阶段只写**：分支确认后才更新所有状态
- **无投机更新**：所有状态永远正确，无需 checkpoint/恢复

---

## 3. BTB 架构

### 3.1 基本参数

| 参数 | 值 | 验证方式 |
|------|:--:|---------|
| **容量** | 64 entry | 仿真：BTB64 比 BTB32 平均命中率高 5-7% |
| **映射方式** | **直接映射** | NLP 优化：消除 way 选择 MUXF7，减少 IF 级逻辑级数 |
| **索引方式** | PC 直接取位 | 仿真：Direct 80.1% vs XOR 79.8% |
| **索引位** | `PC[7:2]` | 6 bit → 64 entry |
| **Tag 位** | `PC[14:8]` | 7 bit |
| **替换策略** | 直接覆盖 | 直接映射无需 LRU |

> [!NOTE]
> 原设计为 2-way 组相联（32 组）。NLP 优化改为直接映射以消除 IF 级的 way 选择逻辑（MUXF7），
> 将关键路径从 8 级降至 2-3 级。虽然仿真显示 2-way 比直接映射准确率高 ~2%，但 NLP 的
> ID 级 Tournament 验证弥补了这个差距。

### 3.2 地址位分解

```
PC[31:0] 的用途分配（NLP 直接映射）：

  31     13  12     8  7     2    1  0
 ┌─────────┬──────────┬─────────┬──────┐
 │ 不使用  │ Tag (5b) │Index(6b)│ 00   │
 │(高位)   │ PC[12:8] │PC[7:2]  │(对齐)│
 └─────────┴──────────┴─────────┴──────┘

覆盖范围: PC[12:2] = 11 bits = 2K 字 (8KB)
5-bit tag + valid = 6 输入 → 单 LUT6 比较（省 1 级 LUT，优化 PC→IROM 路径）
```

### 3.3 Entry 结构（每条目 40 bit）

```
 39    38 37   36 32   31                2   1  0
┌─────┬──────┬───────┬───────────────────┬─────┐
│valid│ bht  │  tag  │     target        │type │
│ (1) │ (2)  │  (5)  │      (30)         │ (2) │
└─────┴──────┴───────┴───────────────────┴─────┘
```

| 字段 | 位宽 | 说明 |
|------|:---:|------|
| `valid` | 1 | 条目有效标志，LUTRAM（无 reset，冷启动安全：误命中由 flush 纠正） |
| `tag` | 5 | `PC[12:8]`，5-bit + valid = 6 输入 → 单 LUT6 比较 |
| `target` | 30 | 预测跳转目标 `PC[31:2]`，低 2 位恒为 0 |
| `type` | 2 | 指令类型编码（NLP：ID 级用于判断是否需要 Tournament 验证） |
| `bht` | 2 | Bimodal 2-bit 饱和计数器（NLP：bht[1] 用于 IF 级 L0 快速方向决策） |
| **合计** | **40** | |

### 3.4 Type 编码

| type[1:0] | 含义 | 识别条件 |
|:---------:|------|---------|
| `2'b00` | JAL | `opcode=6F`，`rd ≠ x1` |
| `2'b01` | CALL | `opcode=6F`，`rd = x1`（即 JAL ra, offset） |
| `2'b10` | BRANCH | `opcode=63`（B-type）— NLP: **仅此类型触发 ID 级 L1 验证** |
| `2'b11` | RET | `opcode=67`，`rs1=x1`，`rd=x0` |

### 3.5 不存储的指令

**非 RET 的 JALR 不存入 BTB**。仿真验证：存入 BTB 在 src1 上导致 CALL 命中率从 97%→74%。

### 3.6 存储布局

```
64 entry × 42 bit = 2,688 bit 总计（无 LRU，全 LUTRAM）
```

---

## 4. GShare 预测器

### 4.1 参数

| 参数 | 值 | 依据 |
|------|:--:|------|
| **GHR 长度** | 8 bit | 2^8 = 256 = PHT 大小，完美匹配 |
| **PHT 大小** | 256 entry | 仿真验证最优 |
| **PHT 计数器** | 2-bit 饱和 | 与 Bimodal 一致 |
| **PHT 索引** | `GHR[7:0] ⊕ PC[9:2]` | XOR 同时保留历史和分支区分 |

### 4.2 GHR 工作原理

```
8-bit 移位寄存器，记录最近 8 次 BRANCH 的结果：

每次 BRANCH 确认后（EX 阶段）：
  GHR = {GHR[6:0], taken_bit}

例: taken, not, taken, taken, not, taken, taken, taken
    → GHR = 8'b10110111
```

### 4.3 PHT 索引

```
GHR[7:0]:    1 0 1 1 0 1 1 1
PC[9:2]:     0 1 0 0 1 0 1 1
             ─────────────────
XOR:         1 1 1 1 1 1 0 0  → PHT[0xFC]，读出 2-bit 计数器
```

### 4.4 存储

```
PHT: 256 × 2-bit = 512 bit（LUTRAM）
GHR: 8-bit 寄存器
```

---

## 5. Selector（竞争选择器）

### 5.1 参数

| 参数 | 值 | 依据 |
|------|:--:|------|
| **大小** | 256 entry | 仿真：64=128=256，选 256 与 PHT 对齐 |
| **计数器** | 2-bit 饱和 | ≥2 信 Bimodal，<2 信 GShare |
| **索引** | `GHR[7:0]` | 仿真验证：GHR 索引 86.0% > GHR⊕PC 85.8% > PC 84.9% |
| **初始值** | 0（信 GShare） | 仿真：四种初始值无差异；0 = 复位免初始化 |

### 5.2 选择逻辑（IF 阶段）

```
sel_idx = GHR[7:0]
if (selector[sel_idx] >= 2):
    use bimodal prediction
else:
    use gshare prediction
```

### 5.3 更新规则（EX 阶段）

```
仅当两个预测器结果不一致时才更新：

if (bimodal_correct && !gshare_correct):
    selector[sel_idx] = min(3, selector[sel_idx] + 1)   // 更信 bimodal
elif (gshare_correct && !bimodal_correct):
    selector[sel_idx] = max(0, selector[sel_idx] - 1)   // 更信 gshare
// 两者都对或都错 → 不更新
```

### 5.4 存储

```
Selector: 256 × 2-bit = 512 bit（LUTRAM）
```

---

## 6. IF 阶段预测逻辑 — L0 快速预测（NLP）

### 6.1 L0 预测流程

> [!IMPORTANT]
> NLP 架构核心变化：IF 级 **不再执行 Tournament 选择**。
> BRANCH 方向仅使用 BTB 内嵌的 bht[1]（Bimodal 最高位），0 级额外逻辑。
> Tournament 验证推迟到 ID 级（见 §6A）。

```
输入: PC（当前取指地址）

── BTB 直接映射读取（单路，无 way 选择）──

  idx = PC[7:2]      // 6 bits → 64 entries
  tag = PC[12:8]     // 5 bits (5-bit compare + valid = 1 LUT6)
  读取 btb[idx] → {valid, tag, target, type, bht}
  tag 比较 → btb_hit (单 LUT6)

── 并行读取（不在关键路径上，供 pipeline 传递到 ID 级）──

  pht_idx = GHR[7:0] ⊕ PC[9:2]  →  pht_cnt
  sel_idx = GHR[7:0]             →  sel_cnt

── L0 快速预测（AND-OR 平坦逻辑）──

bp_taken（单 LUT6，5 输入）:
  = btb_hit & (
      ~type[1]                      // JAL/CALL: always taken
    | (~type[0] & bht[1])           // BRANCH: bimodal direction
    | ( type[0] & ras_valid)        // RET: RAS valid
  )

bp_target（3 路 AND-OR MUX，one-hot select）:
  sel_btb = btb_hit & ~(type[1] & type[0])              // JAL/CALL/BRANCH
  sel_ras = btb_hit &   type[1] & type[0] & ras_valid   // RET
  sel_seq = ~sel_btb & ~sel_ras                          // default

  bp_target = (sel_btb & {target, 2'b00})     // BTB target（ID 级 redirect 也需要）
            | (sel_ras & ras_top)              // RAS top
            | (sel_seq & (PC + 4))            // sequential
```

### 6.2 IF 级关键路径（AND-OR + tag 缩减 + MUX 合并后）

```
PC → BTB LUTRAM读(1.0ns) → tag比较(1 LUT6) → btb_hit_w ──┐
                                   r_type ─────────────────┤→ 1 LUT6 → bp_taken
                                   r_bht[1] ───────────────┘
                                                             ↓
                                                     irom_addr MUX → IROM
= 3-4 级逻辑：LUTRAM(1) + tag&valid(1 LUT6) + AND-OR(1) + MUX(1)
注1: btb_valid 已为 LUTRAM，tag 缩减为 5-bit（compare+valid = 1 LUT6）
注2: next_pc_mux 已被消除，bp_taken/bp_target 直接内联到 irom_addr
```

对比改前（8 级逻辑，~7.5ns 含布线）：**路径缩短 ~4.5ns**。

---

## 6A. ID 阶段 Tournament 验证 — L1（NLP 新增）

### 6A.1 L1 验证流程

IF/ID reg 传递的 snapshot：`btb_hit, btb_type, btb_bht, pht_cnt, sel_cnt`

```
// 仅对 BRANCH 类型 + BTB 命中 执行验证

bimodal_taken   = (btb_bht >= 2)    // = bht[1]（与 L0 一致）
gshare_taken    = (pht_cnt >= 2)
use_bimodal     = (sel_cnt >= 2)
tournament_taken = use_bimodal ? bimodal_taken : gshare_taken

// L0 和 L1 是否一致？
// raw 版（快速，用于 IROM 地址选择）：
id_bp_redirect_raw = id_valid & ~branch_flush
                   & btb_hit & (btb_type == BRANCH)
                   & (bht[1] != tournament_taken)

// 门控版（安全，用于 id_flush 控制）：
id_bp_redirect = id_bp_redirect_raw & id_ready_go & ex_allowin
```

### 6A.2 Redirect 行为

| L0 (IF) | L1 (ID) | 行为 | 代价 |
|:-------:|:-------:|------|:---:|
| taken | taken | 一致，无操作 | 0 |
| not-taken | not-taken | 一致，无操作 | 0 |
| **taken** | **not-taken** | redirect → PC+4 | **1 bubble** |
| **not-taken** | **taken** | redirect → BTB target | **1 bubble** |

### 6A.3 Redirect 时的流水线操作

1. `irom_addr` = `id_redirect_target`（L1 的目标）
2. IF/ID 寄存器 flush（`id_flush = branch_flush | id_bp_redirect`，使用门控版）
3. ID→EX 的 `bp_taken/bp_target` 被 **覆盖为 Tournament 结果**
   （确保 EX 级用正确的预测值做误预测检测）

### 6A.4 Stall 安全：raw/gated 拆分设计

> [!IMPORTANT]
> **设计变更**：redirect 信号拆分为 raw 和 gated 两个版本。
>
> - `id_bp_redirect_raw`：不含 stall 门控，用于 `irom_addr` 选择（快速路径）。
>   安全保证：`irom_addr` 中 **stall 优先级高于 redirect**，stall 时自动选 `pc`。
>
> - `id_bp_redirect`：加 `id_ready_go & ex_allowin` 门控，用于 `id_flush` 控制。
>   确保分支指令必须能转入 EX 后才 flush IF/ID，防止指令丢失。

### 6A.5 irom_addr 优先级（5 路扁平 MUX）

```
irom_addr = mem_branch_flush    ? mem_branch_target :  // (1) MEM flush（最高优先，寄存器值）
            !if_allowin_w       ? pc :                  // (2) 停顿（高于 redirect！）
            id_bp_redirect_raw  ? id_redirect_target :  // (3) NLP: ID redirect（raw 快速版）
            bp_taken            ? bp_target :           // (4) L0 预测 taken
                                  (pc + 4) ;           // (5) 顺序取指
```

> [!NOTE]
> next_pc_mux 模块已被消除：bp_taken/bp_target 直接内联到 irom_addr，
> 省掉了 next_pc 中间变量的 1 级 MUX。

---

## 7. EX 阶段更新逻辑（时序，写操作）

### 7.1 更新时机

**所有更新在 EX 阶段完成**。需要从 IF 传递到 EX 的信号：
- `ex_pc`：原始 PC
- `ex_is_jal`, `ex_is_jalr`, `ex_is_branch`：指令类型
- `ex_branch_cond`：分支条件码
- `ex_rd`, `ex_rs1_addr`：寄存器号（判断 CALL/RET）
- `ex_predicted_taken`, `ex_predicted_target`：预测结果

### 7.2 BTB 更新

```
JAL/CALL/RET: Always taken，总是写入 BTB
BRANCH taken: 写入新条目或更新已有条目
BRANCH not-taken: 仅更新已有条目的 bht（不新建条目）
JALR（非 RET）: 不写入

直接映射 → 无 way 选择：
  直接写入 btb[ex_idx]，覆盖已有条目（如有冲突）
```

### 7.3 Bimodal 更新

```
仅 BRANCH 指令：
  taken:     bht = min(3, bht + 1)
  not-taken: bht = max(0, bht - 1)

状态: 00(强不跳) ↔ 01(弱不跳) ↔ 10(弱跳) ↔ 11(强跳)
```

### 7.4 GShare 更新

```
仅 BRANCH 指令：
1. GHR 移位: GHR = {GHR[6:0], taken_bit}
2. PHT 更新: 
   pht_idx = GHR_old[7:0] ⊕ PC[9:2]   // 用移位前的 GHR
   PHT[pht_idx] = taken ? min(3, cnt+1) : max(0, cnt-1)
```

### 7.5 Selector 更新

```
仅 BRANCH 指令，且两个预测器结果不一致时：
  sel_idx = GHR_old[7:0]
  bimodal 对 → selector[sel_idx] = min(3, cnt+1)
  gshare 对 → selector[sel_idx] = max(0, cnt-1)
```

### 7.6 RAS 更新

```
CALL 确认: PUSH
  entry[3] <= entry[2]
  entry[2] <= entry[1]
  entry[1] <= entry[0]
  entry[0] <= ex_pc + 4

RET 确认: POP
  entry[0] <= entry[1]
  entry[1] <= entry[2]
  entry[2] <= entry[3]
  entry[3] <= 32'h0
```

### 7.7 误预测处理

```
flush 条件（EX 阶段判断）：
  实际跳转 && (未预测跳转 || 预测目标错) → flush，目标 = 实际目标
  实际不跳 && 预测跳转了                  → flush，目标 = ex_pc + 4
  JALR（非 RET）                         → 一律 flush

flush 时：
  · IF、ID 阶段指令作废
  · PC 强制跳转到 branch_target
  · BTB/BHT/GHR/PHT/Selector/RAS 不需要回滚（EX 更新，状态永远正确）
```

---

## 8. RAS 架构

### 8.1 参数

| 参数 | 值 | 依据 |
|------|:--:|------|
| **栈深度** | 4 条目 | 仿真：RAS2=RAS4=RAS8，选 4 留余量 |
| **溢出处理** | 移位丢弃最旧 | LIFO 保证最近 N 次 RET 正确 |
| **递归压缩** | 不实现 | 当前无收益，后期可加 (+3-4 bit/条目) |
| **更新时机** | EX 阶段 | 仿真：IF vs EX 差 0.00%，EX 更简单 |
| **恢复逻辑** | 不需要 | EX 更新不会污染 RAS |

### 8.2 硬件

```
4 × 32-bit 寄存器 = 128 bit
entry[0] = 栈顶（TOS），IF 阶段读取
entry[3] = 栈底
ras_count (2-bit): 跟踪栈内有效条目数
```

---

## 9. 时序分析

### 9.1 NLP IF 阶段关键路径

| 方案 | IF 逻辑级数 | 逻辑延迟 | 含布线估算 | 5ns 余量 |
|------|:--------:|:------:|:--------:|:------:|
| 无预测器 | 1-2 级 | ~1.8ns | ~2.2ns | 2.8ns |
| **NLP (L0 快速)** | **3-4 级** | **~2.0ns** | **~3.0ns** | **~2.0ns** |
| 旧 Tournament (IF全量) | 6-8 级 | ~4.5ns | ~7.5ns | **-2.5ns ❌** |

### 9.2 NLP IF 关键路径详细

```
PC(0.3ns) → BTB LUTRAM(1.0ns) → 5-bit tag比较(0.3ns, 1 LUT6) → AND-OR(0.3ns) → irom_addr MUX(0.3ns) → IROM(0.2ns)
= 3-4 级逻辑，~2.0ns（逻辑），含布线 ~3.0ns
注1: btb_valid 已为 LUTRAM，tag 缩减为 5-bit（compare+valid = 1 LUT6）
注2: next_pc_mux 已消除，bp_taken/bp_target 直接内联入 irom_addr 扁平 MUX
```

### 9.3 实际 Vivado 时序结果（@200MHz, xc7k325t）

| 路径 | WNS | 逻辑级数 | 说明 |
|------|:---:|:------:|------|
| **EX flush → IROM** | -0.647ns | 10 级 | ALU→branch_flush→irom_addr MUX→IROM |
| IF L0 → IROM | 正时序 | 2-3 级 | **NLP 优化成功，不再是最差路径** |

> [!NOTE]
> NLP 优化成功将 BTB→IROM 路径移出关键路径。当前瓶颈是 EX flush 路径（branch_unit 的
> 32-bit 目标地址比较 CARRY4 链），这是实现层面的优化范围，与预测器架构无关。

---

## 10. 面积估算

| 结构 | 位数 | 实现方式 |
|------|:---:|:-------:|
| BTB（64 × 40 bit） | 2,560 | LUTRAM |
| PHT（256 × 2 bit） | 512 | LUTRAM |
| Selector（256 × 2 bit） | 512 | LUTRAM |
| GHR（8 bit） | 8 | 寄存器 |
| RAS（4 × 32 bit） | 128 | 寄存器 |
| RAS count（3 bit） | 3 | 寄存器 |
| **合计** | **3,851** | — |

对比旧 2-way 方案（3,946 bit）：NLP 减少 **-95 bit**（移除 LRU + tag 缩 1 bit）。

Vivado 综合实际使用 **8 × RAM128X1D**（LUTRAM）。

---

## 11. 仿真验证汇总

所有数据基于 `bp_simulator.py` + `bp_sweep.py` + 专项测试脚本，5M 周期 / 程序。

### 11.1 最终配置性能

| 配置 | current | src0 | src1 | src2 | 平均 |
|------|:------:|:----:|:----:|:----:|:---:|
| Tournament (bimodal+GShare) | **92.2%** | **80.7%** | **85.8%** | **85.3%** | **86.0%** |

### 11.2 方案演进对比

| 方案 | 平均命中率 | 最差程序 | IF 路径 | 新增硬件 |
|------|:--------:|:------:|:------:|:------:|
| Bimodal (2-bit 计数器) | 80.1% | 75.8% | ~3.0ns | 0 |
| GShare N=8 P256 | 83.3% | 78.3% | ~3.2ns | +520 bit |
| 局部历史 N=8 P256 | 84.3% | 78.1% | ~3.8ns | +1024 bit |
| **Tournament** | **86.0%** | **80.7%** | **~3.5ns** | **+1032 bit** |

### 11.3 验证覆盖矩阵

| 参数 | 测试范围 | 最终选择 |
|------|---------|---------|
| BTB 大小 | 32, 64 | **64** |
| 映射方式 | 直接, 2路 | **直接映射**（NLP: 为时序牺牲 ~2% 准确率） |
| BHT 模式 | 内嵌, 独立128, 独立256 | **内嵌** |
| RAS 深度 | 0, 2, 4, 8 | **4** |
| 索引方式 | Direct, XOR | **Direct** |
| Tag 宽度 | 4, 6, 7, 8, 12, 24 | **7 bit**（直接映射，index 占 6 bit） |
| Target 宽度 | 30 bit vs 偏移量 | **30 bit** |
| JALR 策略 | 存 vs 不存 | **不存** |
| RAS 更新时机 | IF vs EX | **EX** |
| 方向预测器 | bimodal, GShare, 局部, Tournament | **Tournament (NLP 两级)** |
| IF 级方向决策 | Tournament, Bimodal, bht[1] | **bht[1]**（NLP L0，0 级额外逻辑） |
| GHR 长度 | 2, 4, 8 | **8** |
| PHT 大小 | 4~256 | **256** |
| PHT 索引 | GShare, GSelect, 直接, 仅GHR | **GShare** |
| Selector 索引 | PC, GHR⊕PC, GHR | **GHR** |
| Selector 大小 | 32~256 | **256** |
| Selector 初始值 | 0, 1, 2, 3 | **0** |

---

## 12. 参数选择推理过程

### 12.1 方向预测器：Tournament

1. Bimodal 擅长稳定的单分支模式（current/src0/src1）
2. GShare 擅长分支间有关联的场景（src2）
3. 两者互补，Tournament 四程序全都最高
4. 时序：三路并行读取，关键路径仅多一个 Selector MUX（+0.3ns）

### 12.2 GHR 长度：8 bit

1. 2^8 = 256 = PHT 大小，每种历史模式占唯一 PHT 条目
2. N<8 浪费 PHT 容量，N>8 超出 PHT 索引范围

### 12.3 Selector 索引：GHR[7:0]

1. Selector 学习"在当前全局历史模式下，该信谁"
2. 仿真：GHR 86.0% > GHR⊕PC 85.8% > PC 84.9%
3. GHR 索引 = "同一种上下文模式下的偏好"，比按 PC 分更精确

### 12.4 Selector 初始值：0

1. 仿真：0/1/2/3 四种初始值无差异（86.0%）
2. 选 0 = 复位时全零，硬件最简单
3. 初始偏向 GShare，冷启动阶段信任更强的预测器

---

## 13. 后续优化方向

| 优化 | 描述 | 硬件成本 |
|------|------|---------|
| **EX flush 路径优化** | 当前最差路径，10 级逻辑 WNS=-0.647ns | 逻辑重构 |
| **递归压缩** | RAS 每条目加 3-4 bit 计数器 | +12-16 bit |
| **间接跳转缓存** | 独立小缓存处理非 RET JALR | +200-500 bit |
| **TAGE 预测器** | 多级历史长度标签匹配 | +2000-4000 bit |

---

## 14. NLP 架构 FPGA 验证记录

| 日期 | 版本 | COE | 结果 |
|------|------|-----|:---:|
| 2026-04-19 | `99849fd` NLP + stall fix | current (1271 inst) | ✅ PASS |
| — | — | src0 (2035 inst) | ⏳ 待测 |
| — | — | src1 (1909 inst) | ⏳ 待测 |
| — | — | src2 (1996 inst) | ⏳ 待测 |
