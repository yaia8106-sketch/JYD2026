# 分支预测器架构规格书

> 状态：架构确定，待 RTL 实现 | 最后更新：2026-04-18

---

## 1. 设计目标

在 5 级流水线（IF → ID → EX → MEM → WB）的 IF 阶段，预测跳转方向和目标地址，
将 JAL/CALL/B-type/RET 的跳转惩罚从 **2 拍** 降至 **0 拍**（预测正确时）。

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
│  64 entry, 2-way set-associative, 32 sets            │
│  每条目: valid(1)+tag(8)+target(30)+type(2)+bht(2)   │
│  = 43 bit/entry + 1 bit LRU/set                     │
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

### 2.2 流水线交互

```
       IF 阶段（只读，纯组合）              EX 阶段（只写，时序）
  ┌──────────────────────┐           ┌──────────────────────┐
  │                      │           │ 分支确认后:          │
  │ PC ──┬→ BTB 读       │           │  · BTB 写入/更新     │
  │      ├→ PHT 读  ┐    │           │  · Bimodal 计数器更新│
  │      └→ Selector ┤   │           │  · GHR 移位          │
  │         读     并行   │           │  · PHT 计数器更新    │
  │                  ↓    │           │  · Selector 更新     │
  │      tag比较 → 预测   │           │  · RAS push/pop      │
  │              → next_pc│           │  · LRU 更新          │
  └──────────────────────┘           │                      │
                                     │ 误预测时:            │
                                     │  · branch_flush      │
                                     │  · branch_target     │
                                     └──────────────────────┘
```

**关键原则**：
- **IF 阶段只读**：BTB + PHT + Selector + RAS 读取，纯组合逻辑
- **EX 阶段只写**：分支确认后才更新所有状态
- **无投机更新**：所有状态永远正确，无需 checkpoint/恢复

---

## 3. BTB 架构

### 3.1 基本参数

| 参数 | 值 | 验证方式 |
|------|:--:|---------|
| **容量** | 64 entry | 仿真：BTB64 比 BTB32 平均命中率高 5-7% |
| **映射方式** | 2 路组相联 | 仿真：2 路比直接映射好 2%，src0 上好 6% |
| **组数** | 32 组 | 64 / 2 = 32 |
| **索引方式** | PC 直接取位 | 仿真：Direct 80.1% vs XOR 79.8% |
| **索引位** | `PC[6:2]` | 5 bit → 32 组 |
| **Tag 位** | `PC[14:7]` | 8 bit，支持 64KB 代码空间 |
| **替换策略** | LRU | 每组 1-bit |

### 3.2 地址位分解

```
PC[31:0] 的用途分配：

  31        15  14       7  6     2    1  0
 ┌──────────┬────────────┬─────────┬──────┐
 │ 不使用   │  Tag (8b)  │Index(5b)│ 00   │
 │(高位恒定)│ PC[14:7]   │PC[6:2]  │(对齐)│
 └──────────┴────────────┴─────────┴──────┘
```

### 3.3 Entry 结构（每条目 43 bit）

```
 42    41 40   39 32   31                2   1  0
┌─────┬──────┬───────┬───────────────────┬─────┐
│valid│ bht  │  tag  │     target        │type │
│ (1) │ (2)  │  (8)  │      (30)         │ (2) │
└─────┴──────┴───────┴───────────────────┴─────┘
```

| 字段 | 位宽 | 说明 |
|------|:---:|------|
| `valid` | 1 | 条目有效标志，复位时清零 |
| `tag` | 8 | `PC[14:7]`，用于匹配 |
| `target` | 30 | 预测跳转目标 `PC[31:2]`，低 2 位恒为 0 |
| `type` | 2 | 指令类型编码 |
| `bht` | 2 | Bimodal 2-bit 饱和计数器 |
| **合计** | **43** | |

### 3.4 Type 编码

| type[1:0] | 含义 | 识别条件 |
|:---------:|------|---------|
| `2'b00` | JAL | `opcode=6F`，`rd ≠ x1` |
| `2'b01` | CALL | `opcode=6F`，`rd = x1`（即 JAL ra, offset） |
| `2'b10` | BRANCH | `opcode=63`（B-type） |
| `2'b11` | RET | `opcode=67`，`rs1=x1`，`rd=x0` |

### 3.5 不存储的指令

**非 RET 的 JALR 不存入 BTB**。仿真验证：存入 BTB 在 src1 上导致 CALL 命中率从 97%→74%。

### 3.6 每组存储布局

```
一组 = Way0 (43b) + Way1 (43b) + LRU (1b) = 87 bit
32 组 × 87 = 2,784 bit 总计
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

## 6. IF 阶段预测逻辑（组合，纯读）

### 6.1 完整预测流程

```
输入: PC（当前取指地址），GHR（全局历史寄存器）

── 并行读取（三路同时启动）──

路径 A: BTB 读取
  set_index = PC[6:2]
  tag = PC[14:7]
  读取 btb[set_index] 的两个 way
  tag 比较 → btb_hit, hit_entry (target, type, bht)

路径 B: PHT 读取
  pht_idx = GHR[7:0] ⊕ PC[9:2]
  gshare_cnt = PHT[pht_idx]

路径 C: Selector 读取
  sel_idx = GHR[7:0]
  sel_cnt = Selector[sel_idx]

── 汇合 ──

if (!btb_hit):
    predict_taken = 0
    predict_target = PC + 4

else:
    case (hit_entry.type)
        JAL:    predict_taken = 1
                predict_target = {hit_entry.target, 2'b00}

        CALL:   predict_taken = 1
                predict_target = {hit_entry.target, 2'b00}

        BRANCH: bimodal_taken = (hit_entry.bht >= 2)
                gshare_taken  = (gshare_cnt >= 2)
                predict_taken = (sel_cnt >= 2) ? bimodal_taken : gshare_taken
                predict_target = predict_taken ? {hit_entry.target, 2'b00} : PC+4

        RET:    if (ras_valid):
                    predict_taken = 1
                    predict_target = ras_top
                else:
                    predict_taken = 0
                    predict_target = PC + 4
    endcase

next_pc = branch_flush  ? branch_target :   // EX flush 最高优先
          !if_allowin   ? pc :               // 停顿
          predict_taken ? predict_target :    // 预测跳转
                          PC + 4              // 预测不跳
```

### 6.2 关键路径

```
       ┌→ BTB LUTRAM → tag比较 ────────────────── bimodal_taken ──┐
PC ──┤                                                            ├→ sel MUX → pred MUX → next_pc MUX → BRAM
0.3ns ├→ PHT LUTRAM → cnt≥2 ────────────────── gshare_taken ──┤    0.3ns      0.3ns       0.3ns       0.2ns
       └→ Selector LUTRAM ───────────────────── sel_cnt ──────────┘
           1.0ns        0.5ns                                  0.3ns

关键路径 = 0.3 + max(1.5, 1.2, 1.0) + 0.3 + 0.3 + 0.3 + 0.2 = ~2.9ns（逻辑）
含布线估算 = ~3.5ns，余量 ~1.5ns
```

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

写入目标 way:
  BTB 命中 → 写回同一 way
  BTB 未命中 → 写入 LRU 指示的 way（驱逐旧条目）
  更新 LRU: 刚写入的 way 标记为 MRU
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

### 9.1 IF 阶段关键路径

三路并行读取（BTB + PHT + Selector），Selector MUX 是新增的唯一串行环节。

| 方案 | 逻辑延迟 | 含布线估算 | 5ns 余量 |
|------|:------:|:--------:|:------:|
| 无预测器（当前） | ~1.8ns | ~2.2ns | 2.8ns |
| 仅 Bimodal | ~2.4ns | ~3.0ns | 2.0ns |
| **Tournament** | **~2.9ns** | **~3.5ns** | **~1.5ns** |

### 9.2 关键路径详细

```
逻辑:
  PC Tco(0.3) → max(BTB+tag=1.5, PHT=1.2, Sel=1.0) → selMUX(0.3) → predMUX(0.3) → npcMUX(0.3) → BRAM(0.2)
  = 2.9ns

含布线 (+50~60%):
  ≈ 3.5ns，余量 1.5ns
```

---

## 10. 面积估算

| 结构 | 位数 | 实现方式 |
|------|:---:|:-------:|
| BTB（64 × 43 bit） | 2,752 | LUTRAM |
| LRU（32 × 1 bit） | 32 | LUTRAM |
| PHT（256 × 2 bit） | 512 | LUTRAM |
| Selector（256 × 2 bit） | 512 | LUTRAM |
| GHR（8 bit） | 8 | 寄存器 |
| RAS（4 × 32 bit） | 128 | 寄存器 |
| RAS count（2 bit） | 2 | 寄存器 |
| **合计** | **3,946** | — |

vs 仅 Bimodal 的 2,914 bit，增加 **+1,032 bit**（+35%），换来命中率从 80.1% → 86.0%。

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
| 映射方式 | 直接, 2路 | **2路** |
| BHT 模式 | 内嵌, 独立128, 独立256 | **内嵌** |
| RAS 深度 | 0, 2, 4, 8 | **4** |
| 索引方式 | Direct, XOR | **Direct** |
| Tag 宽度 | 4, 6, 8, 12, 24 | **8 bit** |
| Target 宽度 | 30 bit vs 偏移量 | **30 bit** |
| JALR 策略 | 存 vs 不存 | **不存** |
| RAS 更新时机 | IF vs EX | **EX** |
| 方向预测器 | bimodal, GShare, 局部, Tournament | **Tournament** |
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
| **递归压缩** | RAS 每条目加 3-4 bit 计数器 | +12-16 bit |
| **间接跳转缓存** | 独立小缓存处理非 RET JALR | +200-500 bit |
| **TAGE 预测器** | 多级历史长度标签匹配 | +2000-4000 bit |
