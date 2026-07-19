# F1 Tagged-only 方向预测与 FDQ 周期研究

> 日期：2026-07-14  
> 范围：只修改 C++ 架构探索器和文档，没有修改 RTL  
> 负载：六个 `02_Design/coe/single_issue` 程序，全部运行到 stop PC

## 1. 最终结论

最推荐继续进入 RTL 设计的方向结构是：

```text
BP/F0 system base
├── 256-entry PC-indexed bimodal PHT（2-bit counter）
├── F0：JAL 恒 taken，并计算 JAL/B 的 PC+imm direct target
└── F1 tagged-only
    ├── T0：64 entries，H4，6-bit tag，3-bit signed counter，u/v 各 1 bit
    ├── T1：64 entries，H8，7-bit tag，3-bit signed counter，u/v 各 1 bit
    ├── provider：最长 tag 命中；弱的新 provider 使用 alternate
    └── late override：final tagged source 为 strong 或 useful 时才允许改口
```

F1 **没有私有 bimodal base**。tag miss 时必须逐位保持 BP/F0 的预测结果，
不能产生 correction；更新时仍训练命中的 provider、useful 和 allocation。

方向上，这个方案在 delay=6/10 下相对当前 GShare 分别少
10.272%/8.814% 的 B-type 方向错误，六个程序逐一均不退化。方向状态总计
约 1,992 bit；相对当前 512-bit PHT+8-bit GHR，新增约 1,472 bit。

是否值得把它作为 F1 correction 落地，有一个明确的接口门槛：

- 若 correct 后的正确 fetch packet 在下一个正常到达周期进入队列，即
  `F1R1`，六程序周期模型提升 **1.205%**，每个程序均不退化；推荐落地。
- 若 correct 会额外丢掉一个 producer interval，即 `F1R2`，8-entry FDQ
  模型为 **-0.064%**，已经是临界/略负；不建议无条件覆盖。
- 若额外丢掉两个 interval，即 `F1R3`，模型为 **-1.624%**；明确淘汰。

这里的门槛已经考虑“correct 不清空整个 FDQ、保留正确前缀”。模型在 R2
下每次 correction 平均保留 3.473 条指令，correction 当刻队列为空的比例
为 0%，一个名义空档最终只折算成约 0.381 cycle/correction。问题不是把
correct 当成 backend flush，而是约 1.996 亿次 correction 即使每次只泄漏
很小代价，累积后仍足以抵消方向收益。

## 2. 为什么模型要改成 tagged-only

上一版把 F1 建模为传统完整 TAGE：F1 自己包含一个 bimodal base，tag miss
时也可能用该 base 覆盖一级预测。这不符合目标架构。

目标架构中的系统 base 已经是 BP/F0 的有效预测：

1. BP 用 ABTB type/target 和一级 PHT 进行最早 steering。
2. F0 译码后可以确定 JAL 方向以及 JAL/B 的 direct target。
3. F1 只需要判断某个历史上下文是否有足够证据推翻 BP/F0。

因此新模型把 BP/F0 的有效 taken/not-taken 作为 `external_base_prediction`
传入 F1。tag miss、弱新 entry 选择 external alternate、或 late override 被
过滤时，都保留原 next PC。单元测试专门检查 tag miss 不改口。

## 3. 前端各类控制流的职责

| 指令 | 方向 | target | F1 tagged table |
| --- | --- | --- | --- |
| B-type | 一级 PHT，必要时由 F1 修正 | F0 `PC+B-imm` | 是 |
| JAL | 恒 taken | F0 `PC+J-imm` | 否 |
| RET | 恒 taken | 未来 RAS | 否 |
| 普通 JALR | 恒 taken，但前端 target 未知 | 暂由后端/未来间接预测器 | 否 |

F0 算出 B target 不等于在所有 ABTB miss 上采用 PHT taken。当前负载中大量
ABTB miss 是长期 not-taken B；无条件使用一级方向会引入 false taken。
模型在 tag miss 时保持 BP/F0 的有效方向，只在 F1 有 tagged 证据时使用
已经算好的 direct target。

## 4. 参数与存储

### 4.1 一级 PC bimodal

```text
bank = branch_PC[2]
row  = branch_PC[9:3]
counter = 2-bit saturating，初值 weakly not-taken
```

两个 bank 各 128 entry，总计 512 bit。它在预测意义上等价于直接用
`PC[9:2]` 索引 256-entry 表，但更适合相邻两个指令位置并行读取。

### 4.2 两张 tagged table

```text
T0 = 64 × (tag6 + ctr3 + useful1 + valid1) = 704 bit
T1 = 64 × (tag7 + ctr3 + useful1 + valid1) = 768 bit
committed GHR                                  =   8 bit
PC bimodal                                     = 512 bit
---------------------------------------------------------
总方向状态                                     = 1992 bit
```

T0/T1 共享完整容量，不按 PC[2] 固定切成 `2×32`。前端只查询 fetch block
中程序序最老的 B，因此第一版只需一个 tagged query port，不需要为两个
slot 复制整张表。

索引和 tag 使用 PC 与折叠历史：

```text
index = PC_word XOR fold(GHR) XOR rotate(fold(GHR), 1)
tag   = PC_word XOR fold0(GHR) XOR (fold1(GHR) << 1)
```

预测时的 GHR、index、tag、provider、alternate、counter 和 useful 必须随
指令保存；更新时不能用更新时刻的新 GHR 重算。

## 5. 六程序方向结果

总动态 B-type 为 1,079,314,150。集成前端中的当前 GShare 方向错误为：

```text
delay=6  : 221,855,950
delay=10 : 240,730,785
```

### 5.1 历史长度

固定每张 tagged table 64 entry、默认 6/7-bit tag、external PC base：

| Histories | delay=6 错误 | delay=10 错误 |
| --- | ---: | ---: |
| H1/H2 | 221,289,515 | 235,283,522 |
| H2/H4 | 210,141,856 | 228,200,757 |
| H3/H6 | 201,343,367 | 221,394,512 |
| H4/H8 | **199,810,873** | **219,634,574** |
| H4/H12 | 204,478,706 | 223,077,337 |
| H4/H16 | 207,222,567 | 224,853,918 |
| H6/H12 | 201,506,505 | 220,603,791 |
| H8/H16 | 206,856,414 | 226,828,190 |

H4/H8 在两档延迟下都最好。H2/H4 可工作，但明确放弃约 850～1030 万次
方向收益；更长历史也没有继续改善。因此 8-bit GHR 不大，恰好覆盖当前
最优最长历史；2/4-bit 历史只适合作为时序降级，不是首选。

### 5.2 容量与资源收益比

| 配置 | 增量 tagged/history | d6 相对当前 | d10 相对当前 |
| --- | ---: | ---: | ---: |
| 2×32 H4/H8 | 680 bit | +6.801% | +7.417% |
| 2×64 H4/H8 | 1,480 bit | +9.937% | +8.763% |
| 2×128 H4/H8 | 3,208 bit | +12.476% | +10.003% |

2×128 的确更准，但相对 2×64 再增加 1,728 bit，只多减少约 241～563 万次
错误。第一版优先 2×64；2×128 是资源充裕后的升级点。

### 5.3 late-override 过滤

| 过滤 | d6 方向错误 | d6 correct | d10 方向错误 | d10 correct |
| --- | ---: | ---: | ---: | ---: |
| 无过滤 | 199,810,873 | 195,818,055 | 219,634,574 | 207,282,944 |
| strong | 199,772,620 | 181,962,831 | 220,702,441 | 188,242,909 |
| useful | 218,541,086 | 118,306,699 | 233,848,864 | 130,082,329 |
| **strong OR useful** | **199,067,139** | **188,482,240** | **219,513,622** | **199,564,845** |
| strong AND useful | 219,162,936 | 111,932,917 | 234,586,558 | 120,129,534 |

`strong OR useful` 同时比无过滤更准、correct 更少，是明确 Pareto 点。
`useful` 和 `strong AND useful` 在若干程序上方向回退，淘汰。

推荐门控条件：

```text
allow_override = final_source_is_tagged
               && (final_counter <= -2
                   || final_counter >= +1
                   || final_useful == 1)
```

3-bit signed counter 以 `counter >= 0` 预测 taken；`-1/0` 是两个弱状态。

### 5.4 一级仍用 GShare 的诊断

虽然目标方案倾向 PC base，本轮保留了一组“当前 GShare 一级 + 相同
2×64 H4/H8 tagged-only”的诊断。delay=10 时它有 220,670,439 次方向
错误、151,003,169 次 F1 correction。相对 PC-base 推荐门控，它多约
116 万次方向错误，但少约 4856 万次 correction。

在 D8/R2 direction-only 周期模型中，GShare+T64 为 +0.195%，PC-base
推荐方案为 -0.064%。这说明如果真实接口只能达到 R2，保留 GShare 并非
保守惯性，而是有数据支持的 fallback；若接口达到 R1，PC base 的简单
索引、无 GHR XOR 时序和 tagged 互补性才更适合作为首版目标。

## 6. F1 correction 到底发生多少次

推荐方案 delay=10：

| 指标 | 数量 |
| --- | ---: |
| F1 correction | 199,564,845 |
| ABTB hit 上的 correction | 198,836,996 |
| ABTB miss 上的 correction | 727,849 |
| not-taken → taken | 90,318,850 |
| taken → not-taken | 109,245,995 |
| tag miss 仍 correction | **0** |
| tagged query | 1,073,399,778 |
| provider hit | 784,982,787 |
| no provider | 288,416,991 |
| alternate fallback | 184,574,283 |

所以“只有 F1 与 BP/F0 方向不同才 correct”是对的；在六个长程序的全部
动态执行中，这个条件仍累计约 2.0 亿次。绝大多数发生在 ABTB 已命中的
热分支，不是 tag miss 私有 base 在乱改口。

## 7. FDQ 周期模型

### 7.1 模型表达的语义

- 8-entry instruction-granular FDQ，并复用当前 RTL 的双发射 pairing 规则；
- F1 correct 只丢弃错误 suffix，保留队列中更老的正确 prefix；
- backend redirect 与 F1 correct 使用不同 refill 参数；
- 后端 RAW/cache/muldiv 停顿总量由旧 RTL 六程序 CPI stack 校准；
- 同时跑 depth=4、depth=8、均匀/8-cycle burst 停顿；
- R1/R2/R3 分别表示 correct 后 0/1/2 个额外 producer interval。

模型不把 F1 correct 当成清空 FDQ。推荐方案在 depth=8、R2 时：

```text
average retained at correction = 3.473 instructions
empty FDQ at correction         = 0%
nominal one-gap effective cost  = 0.381 cycle/correction
second gap incremental cost     = 0.468 cycle/correction
```

### 7.2 六程序加权周期

backend direction refill 固定为 6 cycle，使用 RTL pairing 和校准停顿：

| 场景 | 相对当前 GShare 周期 |
| --- | ---: |
| D8，R1，direction-only，均匀停顿 | **+1.205%** |
| D8，R2，direction-only，均匀停顿 | **-0.064%** |
| D8，R2，direction-only，burst8 | -0.149% |
| D4，R2，direction-only，均匀停顿 | +0.255% |
| D8，R3，direction-only，均匀停顿 | -1.624% |
| D8，R2，全部 control redirect | -0.462% |

R1 逐程序：

| current | src0 | src1 | src2 | new_without_Mext | new_with_Mext |
| ---: | ---: | ---: | ---: | ---: | ---: |
| +3.523% | +1.373% | +1.043% | +1.789% | +0.429% | 0.000% |

R2 逐程序：

| current | src0 | src1 | src2 | new_without_Mext | new_with_Mext |
| ---: | ---: | ---: | ---: | ---: | ---: |
| +0.136% | +0.385% | +0.688% | -0.486% | -1.326% | 0.000% |

这给出确定的工程决策，而不是“数据不足”：PC-base tagged-only 只有在接口
达到 R1 时才是稳健推荐；R2 下不满足逐程序无回退，R3 明确不可接受。

### 7.3 与 RTL occupancy 的校准边界

旧 RTL 日志按周期加权的平均 FQ occupancy 为 4.101。C++ 当前基线：

```text
depth=8 model average = 5.006
depth=4 model average = 2.569
```

真实值位于两个敏感性边界之间。depth=8 对正确前缀保留略偏乐观；depth=4
则偏保守。高停顿程序仍有约 0.27～1.62 entry 的逐程序占用偏差，主要因为
模型没有表达 backend stall 与 redirect 的周期重叠。报告因此同时给两种
深度与 burst 边界，不把单一队列结果伪装成 RTL cycle-accurate 数字。

## 8. 模型与真实硬件的剩余差异

1. predictor update 用 delay=6/10 动态指令近似 EX→MEM 更新距离；真实 stall
   会让同一程序内延迟变化。
2. 模型只执行 actual path，不生成错误路径 ABTB lookup/LRU 污染。
3. FDQ 模型按 actual-path packet 表达 correct/redirect 缺口，不复现每根
   pointer、epoch 和 IROM valid 的逐沿波形。
4. calibrated consumer stall 表达总量和 burst 边界，不表达其与 redirect、
   queue empty 的精确相关性。
5. RAS actual-path pending 模型仍只是恢复需求上界；本研究未把 RAS 纳入
   TAGE 结论。

这些差异不会改变本轮的参数排序，但会影响 R1/R2 的最终归类。因此 RTL
设计前最重要的动作不是再扫 TAGE 参数，而是沿周期确认：F1 correct 在
哪个沿改变 fetch pointer，正确 target 的 IROM request 和 packet 分别在哪个
沿被接受。只要能明确归类为 R1 或 R2，本报告已经给出对应决策。

## 9. 结果位置

方向主矩阵（五程序独立结果）：

```text
results/frontend_tagged_only_per_program_20260714
```

`src2` 方向分片：

```text
results/frontend_tagged_only_src2_shards_20260714
```

过滤策略：

```text
results/frontend_tagged_only_filters_per_program_20260714
results/frontend_tagged_only_filter_shards_20260714
```

FDQ 主矩阵与过滤策略：

```text
results/fdq_final_per_program_20260714
results/fdq_final_shards_20260714
results/fdq_tagged_filter_per_program_20260714
results/fdq_tagged_strong_per_program_20260714
results/fdq_current_calibration_exact_per_program_20260714
```

`results/` 已被 `.gitignore`，这些原始 CSV 只保留在当前工作区。核心代码：

```text
src/direction_predictor.*
src/frontend_model.*
src/frontend_main.cpp
src/fdq_model.*
src/fdq_main.cpp
```

## 10. RTL 实施建议

1. 不要先单独把 GShare 改成 PC bimodal 后长期停留；bimodal standalone
   在 delay=6/10 下方向错误分别比当前多 12.46%/5.30%。PC base 与 tagged
   tables 应作为一个方向方案一起评估。
2. F0 先完成 JAL/B immediate 和 direct target；JAL 恒 taken，B 方向与
   target 分开处理。
3. F1 实现一个 oldest-B tagged query port；tag miss 严格保持 base。
4. 使用 H4/H8、2×64、6/7-bit tag、alternate 和 `strong OR useful` 门控。
5. prediction-time metadata 随指令带到 EX，在 EX 可以进入 MEM 的时钟沿
   更新；使用 committed 8-bit GHR。
6. 在 RTL 设计说明或小型时序 testbench 中先证明 correct 接口属于 R1；
   若属于 R2，不启用无条件 late override，优先保留当前 GShare 一级或继续
   研究更低 correction 的门控。
7. RAS 独立设计 depth4、pending visibility 与 checkpoint/recovery，不并入
   TAGE 的 F1 关键路径。
