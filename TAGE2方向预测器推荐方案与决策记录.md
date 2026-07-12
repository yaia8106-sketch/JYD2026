# TAGE2 方向预测器推荐方案与决策记录

> 日期：2026-07-12  
> 状态：C++ 架构级筛选完成，尚未修改 RTL  
> 用途：供后续人工设计、AI 分析、RTL 实现与性能复核参考

## 1. 最终推荐

当前最推荐的方向预测方案是一个只负责 RISC-V B-type 条件分支的
两级小型 TAGE：

```text
TAGE2
├── Base：256-entry bimodal，2-bit counter，按 PC[2] 物理分 bank
├── T0：共享 64 entries，使用最近 4 个已提交分支结果
├── T1：共享 64 entries，使用最近 8 个已提交分支结果
└── GHR：8-bit committed GHR
```

推荐的 base 物理组织为：

```text
bank = branch_PC[2]
row  = branch_PC[9:3]
```

它在预测意义上严格等价于一张使用 `branch_PC[9:2]` 索引的
256-entry bimodal 表，但两个相邻指令位置天然进入不同 bank，因此 base
不需要为了双读口复制整张表。

T0/T1 暂不建议固定拆成两个互不共享的 `2×32-entry` bank。第一版 RTL
应保留每张表完整的 64-entry 共享容量；如何提供双指令位置查询能力，
应通过复制、预译码后按需查询或流水化调度解决，而不是先切掉共享容量。

## 2. 该预测器负责什么

TAGE 只预测 B-type 条件分支的方向：

```text
taken / not-taken
```

它不保存、也不预测跳转地址。

建议把前端控制流处理拆成：

| 指令类型 | 方向 | 目标地址来源 |
| --- | --- | --- |
| B-type | TAGE | F0/F1 中计算 `PC + B-imm` |
| JAL | 恒 taken | F0/F1 中计算 `PC + J-imm` |
| RET | 恒 taken | 未来的 RAS |
| 其他 JALR | 恒 taken，但前端目标未知 | 暂由 EX 修正，未来按需求增加间接目标预测 |

因此，JAL、JALR 不进入 TAGE；B-type 的 target 也不需要存入 TAGE 或
额外 target table。JAL/JALR 的“恒 taken”只代表方向在语义上确定：普通
JALR 的 target 仍依赖 `rs1`，只有 RET 可以由 RAS 提前提供目标。

当前 RTL 的 F0 已经能预译码出 B/JAL/JALR，但还没有完成“直接立即数目标
计算后在 F0/F1 redirect”的完整路径。把 direct target generation 加入
F0/F1 是未来 RTL 工作，不是当前已经存在的能力。

## 3. 具体参数

### 3.1 Base bimodal

```text
总 entries：256
物理 bank：2
每 bank rows：128
每 entry：2-bit saturating counter
初始化：01（weakly not-taken）
预测：counter[1]
```

状态转移：

```text
00：strongly not-taken
01：weakly not-taken
10：weakly taken
11：strongly taken
```

实际 taken 时饱和加一，实际 not-taken 时饱和减一。

### 3.2 T0

```text
entries：64，共享容量
history length：4
tag：6 bit
direction counter：signed 3 bit，范围 -4～+3
useful：1 bit
valid：1 bit
```

### 3.3 T1

```text
entries：64，共享容量
history length：8
tag：7 bit
direction counter：signed 3 bit，范围 -4～+3
useful：1 bit
valid：1 bit
```

### 3.4 状态成本

```text
Base = 256 × 2                         = 512 bit
T0   = 64 × (6 tag + 3 ctr + u + v)  = 704 bit
T1   = 64 × (7 tag + 3 ctr + u + v)  = 768 bit
GHR  =                                      8 bit
-------------------------------------------------
逻辑状态总计                         = 1,992 bit
```

如果 base 按 PC[2] 分 bank、不复制，而两张 tagged table 为两个指令位置
各保留一份读副本，则保守的双读等效状态为：

```text
Base              =   512 bit
2 × (T0 + T1)     = 2,944 bit
GHR               =     8 bit
--------------------------------
双读等效状态      = 3,464 bit
```

这里的 bit 数是架构状态估算，不等于最终 Vivado LUT/FF/BRAM 使用量。

## 4. 查询和 provider 选择

Base、T0、T1 对候选 B-type PC 并行查询。

```text
优先级：T1 > T0 > Base
```

1. T1 tag 命中时，T1 是最长历史 provider。
2. 否则 T0 tag 命中时，T0 是 provider。
3. 两张 tagged table 都不命中时，使用 base。
4. 新分配的 tagged entry 如果 `useful=0` 且 counter 很弱，暂时使用
   alternate，避免一个尚未学稳的新 entry 立即接管预测。

alternate 关系为：

```text
T1 的 alternate：T0，若 T0 未命中则为 Base
T0 的 alternate：Base
```

预测时必须保存并随指令携带：

- GHR 快照；
- base/T0/T1 index；
- T0/T1 tag；
- provider 与 alternate 编号；
- provider/alternate 的 prediction-time counter；
- 是否最终采用 alternate。

更新时不能重新使用届时的 GHR 计算 index，否则会训练错误的上下文。

## 5. 更新时序

当前 RTL 不是等分支在 MEM 中执行完才训练预测器。真实结果在 EX 组合
逻辑中产生；当 `ex_ready_go && mem_allowin && !mem_branch_flush` 成立时，
在 EX→MEM 交界的时钟沿更新 PHT/GHR。普通分支 redirect 同时进入 EX/MEM
redirect 寄存器，下一周期才以 MEM registered redirect 的形式到达前端。

建议未来 TAGE 保持相同的架构语义：

```text
edge x:
分支指令进入 EX。

cycle x:
EX 计算 actual_taken、actual_target 和 misprediction。
使用随指令携带的 prediction-time TAGE metadata 生成训练信息。

edge x+1:
若 EX 可以进入 MEM，更新 provider/alternate、useful、allocation 和
committed GHR；redirect 同时写入 EX/MEM redirect 寄存器。

cycle x+1:
registered redirect 对前端可见。

edge x+2:
前端 PC 切换到正确路径并清除错误路径内容。
```

TAGE 使用 committed GHR，不要求 speculative history recovery。代价是查询
时历史较旧，因此 C++ 研究同时使用 delay=6 和 delay=10 检查敏感性。

## 6. 建议的前端放置

由于时序紧张，倾向把最终 provider/tag 选择放在 F1，而不是把完整 TAGE
塞进 F0。

建议流水方式：

```text
BP：
发起 IROM 请求；保留现有早期预测/顺序取指能力。

F0：
取得指令并预译码；识别 B/JAL/JALR；生成 B/JAL immediate；
计算 direct target；计算 TAGE base/T0/T1 index，并启动表读取。

F0→F1 edge：
寄存指令类型、PC、direct target、GHR 快照和表输出。

F1：
比较 T0/T1 tag；选择 provider/alternate；得到 B-type 方向；
按程序顺序选择取指块内最早的 taken CFI，产生 correction/redirect。
```

F1 方案比 BP 直接预测多出前端延迟，因此最终性能必须在 RTL 中衡量：
准确率提高不一定能完全抵消晚一级 redirect。ABTB 是否继续承担 BP 早期
steering、F1 TAGE 是否作为 correction，是实现前必须明确的接口问题。

## 7. 选择该方案的证据

所有结论来自六个竞赛 COE 程序完整运行，不使用截断样本作为最终数据。

### 7.1 相对当前 GShare

| 配置 | delay=6 方向错误 | delay=10 方向错误 |
| --- | ---: | ---: |
| 当前 GShare-256 H8 | 225,619,852 | 247,939,678 |
| 推荐 TAGE2 | 199,544,133 | 219,003,913 |

delay=10 下，推荐 TAGE2 减少 28,935,765 次方向错误，降幅 11.67%。六个
程序均相对当前 GShare 改善。

基于现有 RTL CPI stack，把各程序的方向错误降幅映射到 redirect 周期，
估算总周期下降约 0.742%。这是筛选估算，不是 RTL 实测。

### 7.2 为什么选择 H4/H8

| TAGE2 histories | delay=6 错误 | delay=10 错误 |
| --- | ---: | ---: |
| H2/H8 | 202,025,271 | 222,167,210 |
| H4/H8 | 199,544,133 | 219,003,913 |
| H4/H12 | 203,926,045 | 222,175,514 |
| H4/H16 | 206,926,437 | 224,001,518 |

H4/H8 在两种延迟下都最好：H2 太短，H12/H16 又因相关性稀释、alias、
训练延迟等因素退化。因此不应简单扩大单一 GHR，而应保留两个互补历史。

尚未单独完整测试“整个 TAGE 最多只有 2-bit 或 4-bit GHR”的 H1/H2、
H2/H4 组合。现有 H2/H8 仍保留 8-bit GHR，不能冒充 max-GHR=2 的结果。

### 7.3 为什么 base 选 bimodal，而不是 GShare base

Base 的职责是为 tagged miss、新 entry 未学稳等情况提供稳定后备。历史
相关性已经由 T0/T1 提供；PC-only base 不依赖陈旧 GHR，和 tagged tables
更互补。

根据设计选择，本轮没有尝试 GShare base。当前 GShare 只作为外部基线，
不作为 TAGE 内部候选。

### 7.4 为什么 base 保留 256 entries

固定 T0/T1=64 entries、H4/H8 后：

| Base | delay=6 错误 | delay=10 错误 |
| --- | ---: | ---: |
| B128 low | 199,489,470 | 219,005,828 |
| B256 low | 199,544,133 | 219,003,913 |
| B512 low | 199,539,645 | 219,005,038 |

三种容量几乎相同，说明 base 不受容量限制。delay=10 下，base 成为最长
匹配 provider 的比例约 27.4%，其条件准确率约 97.7%；落到 base 的多是
容易、强偏向的分支。

B128 也足够，但相对 B256 只节省 256 bit（32 字节）。在没有综合结果
证明 B128 能跨过实际 LUTRAM/时序边界前，B256 更保守，验证风险更小。

### 7.5 为什么 base 用 PC 低位，不采用 folded PC

PC folding 能明显减少 base 的动态 alias owner switch：B256 low 约
25.6 万次，B256 folded 约 551 次。但 standalone bimodal 总错误只改善
约 2 万次；在 TAGE 内，folded 在 delay=6 略好、delay=10 略差，收益不
稳定。

因此推荐简单的：

```text
bank = PC[2]
row  = PC[9:3]
```

不为极小且不稳定的准确率变化增加 lookup-path XOR。

### 7.6 为什么只把 base 分 bank

共享 B256 low 与 PC[2]-banked B256 low 在完整运行中逐项相同；这是索引
重排，不改变任何碰撞关系。base 分 bank 将双读等效成本从 3,976 bit
降至 3,464 bit，没有准确率代价。

但把每张 tagged table 固定切成 `2×32` 后：

| Tagged 组织 | delay=6 错误 | delay=10 错误 |
| --- | ---: | ---: |
| shared 64 entries | 199,544,133 | 219,003,913 |
| PC[2] banked 2×32 | 207,216,034 | 219,727,337 |

delay=6 增加 7,671,901 次错误（约 3.84%），并增加 allocation failure，
使更多预测退回 base。该方案对 update delay 过于敏感，因此淘汰。

### 7.7 为什么不优先选择 TAGE3

TAGE3 在 delay=10 只比 TAGE2 再减少约 135 万次错误，却增加第三张表、
848 个逻辑状态位、更长历史和更宽的 provider 选择。估算总周期收益只比
TAGE2 多约 0.033 个百分点，不足以抵消第一版 RTL 的时序和验证风险。

## 8. 被淘汰或暂缓的方向

| 方向 | 结论 |
| --- | --- |
| target-history 替代 GHR | 收益小、RTL 不友好，暂缓 |
| 扩大单一 GShare 容量 | 有收益但资源效率低于 TAGE2 |
| H2/H8 | 稳定差于 H4/H8 |
| H4/H12、H4/H16 | 更长历史反而退化 |
| TAGE3 | 额外收益不足以支持第一版复杂度 |
| folded-PC base | alias 大幅下降但总准确率几乎不变 |
| tagged table 固定 2×32 bank | delay=6 明显退化，淘汰 |
| GShare base | 按设计选择不测试 |
| RAS | 当前 RTL 不存在；未来单独设计，不属于 TAGE |

## 9. RTL 落地时不能忽略的问题

1. **F1 晚预测代价**：必须比较准确率收益和多一级 correction 延迟。
2. **两个指令位置的 tagged read**：不能默认双表复制一定便宜，也不能
   用固定 2×32 bank 破坏容量；应结合 F0 预译码研究按需读或调度。
3. **同周期 update/read**：必须明确 LUTRAM read-during-write 行为，当前
   C++ 没有建模写旁路。
4. **prediction-time metadata**：index/tag/provider/counter 必须随指令走到
   EX，不能在更新时用新 GHR 重算。
5. **一个周期最多一个 CFI update**：当前 issue policy 保证这一点；若
   未来放宽双 CFI issue，需要重新设计更新端口和顺序。
6. **错误路径和 redirect recovery**：当前方案用 committed GHR，避免
   speculative GHR 恢复，但仍需验证 flush 对 metadata valid 的清理。
7. **ABTB/TAGE 分工**：C++ 方向研究使用 perfect-BTB 视角；真实前端只有
   ABTB 命中且时机合适时，方向结果才能转化为早期 steering。
8. **RAS 重新加入后的时序**：此前 RAS 因时序问题删除，未来实现必须与
   TAGE/F1 路径分离评估，不能假设零成本。

## 10. 建议实施顺序

1. 先在 C++ 中补测 max-GHR=2/4：H1/H2、H2/H4，与 H4/H8 比较。
2. 在 RTL 设计文档中确定 BP、F0、F1 的 redirect 优先级及 ABTB/TAGE
   correction 关系。
3. 增加 F0 direct target generator，只处理 B/JAL 的 `PC+imm`。
4. 实现 PC[2]-banked B256 bimodal base。
5. 先实现共享容量 T0/T1，保证功能与 C++ 语义一致。
6. 携带完整 prediction-time metadata 到 EX，在 EX→MEM 边界训练。
7. 跑全部六个 COE，检查方向错误、redirect、总周期和每程序回退。
8. 跑综合/实现，检查 LUT、FF、RAM、WNS/Fmax；若 tagged 双读复制成为
   主要代价，再研究按需读或流水调度。
9. 只有在 TAGE2 RTL 性能与时序都成立后，才考虑 RAS 或第三张 TAGE 表。

## 11. 验收标准

不能只看 C++ 方向准确率。最终接受方案至少需要：

- 六个程序功能全部通过并到达 stop PC；
- 每程序和汇总方向误预测不出现无法解释的回退；
- RTL 总周期确实下降；
- F1 correction 的额外延迟没有吞掉准确率收益；
- post-implementation WNS/Fmax 不低于可接受目标；
- 资源增长与约 0.7% 级总周期预期收益匹配；
- ABTB、TAGE、未来 RAS 的职责和 redirect 优先级明确。

## 12. 数据与代码位置

当前 RTL 性能日志：

```text
/home/anokyai/Desktop/CPU_Workspace/02_Design/riscv_tests/work/perf/runs/coe/20260704_125720/logs
```

C++ 架构探索器：

```text
/home/anokyai/Desktop/CPU_Workspace-master/02_Design/cpp_arch_explorer
```

详细英文实验报告：

```text
/home/anokyai/Desktop/CPU_Workspace-master/02_Design/cpp_arch_explorer/DIRECTION_STUDY_20260712.md
```

本轮原始结果：

```text
/tmp/direction_base_bank_delay6
/tmp/direction_base_bank_delay10
/tmp/direction_base128_bank_supplement
```

关键 C++ 文件：

```text
src/direction_predictor.hpp
src/direction_predictor.cpp
src/direction_main.cpp
src/direction_predictor_tests.cpp
```

`diagnostics.csv` 分开记录了 provider 原始准确率、最终来源准确率、
alternate 使用、PC[2] bank 压力、base alias 和 tagged allocation failure。

## 13. 一句话决策摘要

> 对当前嵌入式竞赛负载，最值得首先实现的是：只预测 B-type 方向的
> TAGE2，使用 PC[2]-banked 256-entry bimodal base，以及共享的 64-entry
> H4、64-entry H8 tagged tables；B/JAL target 在 F0/F1 直接由 PC+imm
> 生成，RET 未来交给独立 RAS。该方案在两种现实 update delay 下均显著
> 优于当前 GShare，base 分 bank 无准确率代价，而 tagged 固定分 bank、
> 更长历史和 TAGE3 都未显示足够稳定的资源效率。
