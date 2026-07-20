# 前端分支预测 C++ 模型、实验结果与硬件一致性审查

> **更新说明：** 本文的完整 TAGE/F1 固定 penalty 分析已被
> `TAGGED_ONLY_F1_STUDY_20260714.md` 取代。新模型中 F1 没有私有 bimodal
> base，tag miss 保持 BP/F0；并使用保留正确前缀的 instruction-granular
> FDQ 周期模型。本文的 ABTB、RAS 边界和 RTL 更新时序仍可参考。

> 日期：2026-07-14  
> 范围：只新增/修改 C++ 架构探索器和文档，没有修改 RTL  
> 负载：六个 `02_Design/verification/riscv/coe/single_issue` 竞赛程序，全部运行到 stop PC

## 1. 先给结论

1. 当前 ABTB 的 target 存储总体足够。resolved CFI hit 为 92.22%，但
   绝大多数 miss 是实际 not-taken B；真正 actionable miss 只有约
   423 万次，占全部 CFI 约 0.35%。不建议先扩 ABTB 容量。
2. 纯方向上，`B256 + T0(64,H4) + T1(64,H8)` 在 delay=6/10 下都比
   当前 GShare-256 H8 少约 11.6% 的方向错误；H1/H2、H2/H4 会明显损失
   收益，H3/H6 是时序不够时较合理的降级方案。
3. 两个位置复制 tagged table 没有必要。真正执行到第二个 B 的事件只占
   全部 B 约 0.55%；只查程序序最老 B 与双读结果等价。
4. F0 能准确识别 B/JAL 并算出 direct target，不代表 F0 应在每个 ABTB
   miss 上无条件采用一级 B 方向。这样做在完整运行中反而增加最终错误。
5. F1 TAGE 的主要风险不是逻辑准确率，而是晚覆盖次数。传统 TAGE
   无条件覆盖会产生约 1.4～2.2 亿次 F1 direction change；必须结合实际
   F1 correction 代价。简单 confidence filter 能减少约 8%～16% change，
   但不能把 change 数量降到可忽略。
6. actual-path pending RAS 几乎完美，只能说明“正确路径 CALL/RET 距离很近，
   committed-only RAS 太晚”，不能证明不带 checkpoint/recovery 的 RTL RAS
   会同样准确。旧 RTL 日志中的投机 RAS 在 `src1/src2` 有大量漏预测/错
   target，RAS 必须单独做恢复模型与时序验证。

## 2. 模型覆盖内容

### 2.1 方向预测

- 当前 256-entry、2-bit、weakly-not-taken GShare；
- committed GHR，预测时 index/counter 延迟更新；
- PC-only bimodal、GSelect；
- 两级/三级小 TAGE，不同 history、tag、容量和 PC[2] bank 组织；
- provider、alternate、useful、allocation failure 和 stale provider update。

### 2.2 集成前端

- 当前 `2 bank × 16 set × 2 way` ABTB；
- 7-bit tag、type、32-bit target、valid、伪 LRU；
- taken B 才分配，JAL/CALL/RET 分配；
- 使用预测时携带的 hit/way 更新，保留 stale-hit 写语义；
- BP/F0/F1 三个预测观察点；
- F0 B/JAL immediate decode 和 direct target；
- 双 tagged read 与 oldest-B-only 单读；
- committed、2-entry pending overlay 和 actual-path speculative RAS 上界；
- 所有重定向、仅 B 方向重定向、无重定向屏障三种更新可见性。

所有 direct target 都由 C++ 指令译码器从 PC+immediate 计算，不借用真实
next PC。单元测试覆盖 B/JAL/CALL/RET 译码、ABTB 分配过滤、延迟 RAS、
F0 JAL 修正、方向屏障和 oldest-only 重取。

## 3. 与旧 RTL 日志的校准

旧日志目录：

```text
02_Design/verification/riscv/work/perf/runs/coe/20260704_125720/logs
```

六程序退休指令数与 C++ 完整执行一致。旧 RTL 的 PHT confirmed branch 为
1,079,316,064，C++ 为 1,079,314,150，相差 1,914（约 0.00018%）。旧 RTL
方向错误为 242,805,245：

| 基线 | 方向错误 | 相对旧 RTL |
| --- | ---: | ---: |
| 旧 RTL 日志 | 242,805,245 | — |
| C++ GShare delay=6 | 225,619,852 | -7.08% |
| C++ GShare delay=10 | 247,939,678 | +2.12% |

真实值总体落在 delay=6/10 之间且靠近 delay=10。逐程序最合适延迟不同：
`current` 接近 6，而 `src0/src2/new_without_Mext` 更接近 10。这证明不能从
单一固定动态指令延迟得出结论；后文只把两档都成立的排序视为稳健。

注意：这批旧日志显示 RAS enabled/speculative，而当前 RTL 已经删除 RAS。
因此只用它校准仍相同的 PHT/程序路径，不把其 RAS 数字当作当前硬件状态。

## 4. 纯方向结果

总动态 B 为 1,079,314,150：

| 配置 | delay=6 错误 | 相对 GShare | delay=10 错误 | 相对 GShare |
| --- | ---: | ---: | ---: | ---: |
| 当前 GShare H8 | 225,619,852 | — | 247,939,678 | — |
| bimodal B256 | 249,394,458 | -10.54% | 253,403,735 | -2.20% |
| GSelect PC4/H4 | 229,453,933 | -1.70% | 242,760,515 | +2.09% |
| TAGE2 H1/H2 | 220,627,858 | +2.21% | 235,046,223 | +5.20% |
| TAGE2 H2/H4 | 210,261,582 | +6.81% | 228,097,283 | +8.00% |
| TAGE2 H3/H6 | 201,604,446 | +10.64% | 221,519,736 | +10.66% |
| TAGE2 H4/H8 | 199,544,133 | +11.56% | 219,003,913 | +11.67% |

H4/H8 在两档总数上最好，六个程序都不比当前 GShare 差。H3/H6 只比
H4/H8 多约 206～252 万次错误，若综合表明 H4/H8 的 fold/tag 路径过紧，
它是优先降级点。

## 5. ABTB 与双 CFI

### 5.1 resolved ABTB

| 项目 | 数量/比例 |
| --- | ---: |
| resolved CFI | 1,208,524,620 |
| hit | 1,114,538,572（92.22%） |
| B hit | 988,553,003（91.59%） |
| JAL hit | 71,177,965（98.41%） |
| JALR hit | 54,807,604（96.36%） |
| actionable miss | 4,225,803 |
| not-taken B miss | 89,760,245 |

bank0/bank1 总 hit 分别为 91.80%/92.81%。bank1 的 allocation/replacement
集中在少数 set：set2 约 310 万次 replacement，set9 约 82 万次，set8
约 24 万次。另一方面，一些低 hit set 几乎不 replacement，原因是对应 B
长期 not-taken、按策略不分配。不能把所有低 hit set 都解释为容量冲突。

### 5.2 双 CFI 与 tagged read

| 项目 | 数量/比例 |
| --- | ---: |
| actual-path fetch block | 3,360,549,781 |
| 静态两个 CFI | 232,900,096（6.93%） |
| 执行到第二个 CFI | 34,673,365 |
| 第二个为 B | 5,917,812（全部 B 的约 0.55%） |

| tagged policy | delay=6 最终错误 | delay=10 最终错误 |
| --- | ---: | ---: |
| dual slot | 256,304,214 | 275,857,723 |
| oldest B only | 256,301,822 | 275,852,628 |

oldest-only 抑制约 591 万次年轻 B tagged query，但最终结果没有退化。若老
B 错误预测 taken，后续 PC+4 重取会让年轻 B 重新获得唯一查询口。

## 6. 集成预测结果与代价

### 6.1 不带 RAS 的最终错误

| 配置 | delay=6 | delay=10 |
| --- | ---: | ---: |
| current GShare | 279,888,455 | 298,762,797 |
| current GShare，方向屏障 | 279,836,036 | 299,977,289 |
| current GShare，无屏障 | 273,930,755 | 290,438,272 |
| TAGE2 oldest | 256,301,822 | 275,852,628 |
| TAGE2 oldest，方向屏障 | 256,423,734 | 275,878,396 |
| TAGE2 oldest，无屏障 | 254,091,440 | 264,108,300 |

同屏障比较，TAGE 的最终错误降幅约为 7.24%～9.07%，所以收益不是屏障
不公平造成的。但无屏障与有屏障本身可相差一千多万次，仍说明 cycle-
accurate update visibility 是 RTL 前最后一个重要不确定项。

### 6.2 F0/F1 修正

`GSHARE_F0_DIRECT` 把所有已译码 B/JAL 都按一级方向 steering，结果反而
比 current 多约 256～348 万次最终错误。delay=6 时 F0 correction 中
helpful=1,735,826，harmful=3,988,009；问题是 B 方向，而不是 PC+imm target。

只让 JAL 在 F0 direct correction：

| 配置 | delay=6 最终错误 | delay=10 最终错误 | F0 correction 性质 |
| --- | ---: | ---: | --- |
| current | 279,888,455 | 298,762,797 | — |
| GShare + F0 JAL-only | 278,735,357 | 297,586,762 | 约 115 万次，全部 helpful |

因此 JAL-only 是明确的简单收益；B target 仍可在 F0 算好，但等方向确定后
再使用。

无条件 F1 TAGE 的方向 change 次数：

| 一级方向 | delay=6 F1 change | helpful | harmful |
| --- | ---: | ---: | ---: |
| GShare H8 | 154,363,327 | 87,181,539 | 67,181,788 |
| bimodal | 204,928,358 | 125,256,903 | 79,671,455 |
| GSelect PC4/H4 | 144,015,502 | 82,251,408 | 61,764,094 |

所以“bimodal 与 TAGE 共享 base”最省约 520 bit，但会比 GShare/GSelect
一级产生更多晚修正。最终选择必须使用真实 F1 correction penalty，而不是
只看 backend miss。

简单 late-override filter 的结果：

| filter | d6 最终错误 | d6 F1 change | d10 最终错误 | d10 F1 change |
| --- | ---: | ---: | ---: | ---: |
| always | 256,301,822 | 204,928,358 | 275,852,628 | 221,645,024 |
| tagged strong | 256,950,724 | 180,911,809 | 278,339,021 | 186,669,945 |
| tagged useful | 277,000,909 | 109,371,234 | 292,371,990 | 110,535,592 |
| strong OR useful | 256,292,403 | 187,444,050 | 277,006,143 | 196,466,631 |
| strong AND useful | 277,313,520 | 104,286,563 | 293,403,155 | 104,329,888 |

`strong OR useful` 是较温和的 Pareto 点：d6 不损失准确率并少约 1750 万次
change；d10 多约 115 万次最终错误但少约 2520 万次 change。只看 useful
的激进策略丢失太多后端准确率。

以资源较多但修正较少的 `GShare + F0 JAL-only + TAGE oldest` 为例，它比
JAL-only baseline 少约 2243 万次 backend miss，却产生约 1.51 亿次 F1
change。忽略极小的 F0 差异，break-even 条件约为：

```text
F1_change_penalty / backend_redirect_penalty < 22.43M / 151.00M = 0.149
```

若后端 redirect 平均 6 cycle，则 F1 change 必须低于约 0.89 cycle 才可能
净赢；若后端为 4 cycle，阈值约 0.60 cycle。当前 C++ 无法证明该条件成立，
所以不能仅凭 11.6% 的纯方向收益就直接把 TAGE 放进 F1。

### 6.3 RAS 边界

六程序 CALL/RET 各 56,879,572 次，actual-path 最大栈深为 4：

| RAS 模型 | delay=6 正确率 | delay=10 正确率 |
| --- | ---: | ---: |
| committed depth8 | 89.57% | 87.89% |
| pending2 depth8 | 99.999989% | 99.999989% |
| speculative actual-path upper | 100% | 100% |

pending2 只错 6 个 target，但它没有错误路径 push/pop，也没有 checkpoint
容量、恢复和 F0/F1 flush 时序。可实现结论只有：需要让尚未提交的 CALL/RET
对后续 RET 可见；不能等价推出“两项队列且无恢复就足够”。

## 7. RTL 时序语义：沿与周期分开

当前 PHT/GHR 不是等到 MEM 组合逻辑中才更新。准确描述是：EX 计算结果，
在允许 EX 进入 MEM 的时钟沿训练。

```text
edge x:
分支指令的 EX payload 已进入 EX 寄存器；prediction-time PHT/TAGE metadata
随指令稳定保存。

cycle x:
EX 组合逻辑计算 actual_taken、actual_target 和 misprediction。
predictor_update_ctrl 组合地产生训练数据；只有
ex_ready_go && mem_allowin && !mem_branch_flush 时 update_valid 有效。

edge x+1:
PHT/GHR（未来也包括 TAGE provider/useful/allocation）在该沿更新；同一个沿
把 redirect 写入 EX→MEM 的 registered redirect 状态。

cycle x+1:
registered redirect 对前端可见，前端组合逻辑选择正确 PC 并清除错误 epoch。
```

C++ 的 fixed dynamic-instruction delay 只能近似这段周期关系，不能同时表达
双发射、cache/RAW stall 和 redirect 空周期，因此保留 6/10 与屏障边界。

## 8. 会显著改变结果的模型差异

### A. 高影响，RTL 前必须解决

1. **错误路径不存在**：ABTB 没有错误路径 lookup/LRU 污染；RAS 没有错误
   路径 push/pop。ABTB actionable miss 很低，所以排序影响有限；RAS 可能
   被大幅高估。
2. **F1 correction 周期成本抽象**：CSV 的 `1/2/4`、`1/3/6` 只是敏感性
   权重，不是当前流水线实测 penalty。它足以暴露“晚修正可能吞掉准确率
   收益”，不能给出最终 CPI。
3. **周期延迟换成动态指令延迟**：同一 delay 不能适配六个程序；有/无
   redirect barrier 的差异可到千万级。
4. **RAS recovery 缺失**：pending/speculative RAS 使用 actual-path 操作，
   是上界而不是预测准确率承诺。

### B. 中等或有界影响

1. RTL 同一 64-bit block 的两个 PHT bank 使用同一 GHR/表状态并行读；
   C++ 按实际执行事件顺序处理。恰在两条指令之间到期的旧更新可能让第二
   条看到新状态。第二个 B 只占约 0.55%，推荐 PC-base/oldest-tagged 对此
   不敏感，当前 GShare 校准数字可能有轻微变化。
2. ABTB 模型记录 actual-path resolved CFI lookup，不生成所有 BP 周期；
   对 resolved hit/冲突诊断有效，对 LRU 的逐周期精确复现偏乐观。
3. C++ 默认把 F1 修正视为立即改变预测路径；真实 FTQ/FQ occupancy、epoch
   和 redirect priority 可能合并、延后或屏蔽部分 correction。

### C. 已与当前 RTL 对齐的关键点

- GShare index、8-bit committed GHR、counter 初值；
- prediction-time index/counter 更新，而不是更新时重读；
- ABTB bank/set/tag/way/LRU 和 taken-B allocation；
- 简单 x1/x5 CALL/RET 分类，普通 JALR 不进 ABTB；
- JAL/B target 来自 PC+decoded immediate；
- 一个周期至多一个架构有效 CFI update 的现有 issue 前提。

## 9. 复现位置

代码与说明：

```text
02_Design/model/cpp_arch_explorer/src/direction_predictor.*
02_Design/model/cpp_arch_explorer/src/frontend_model.*
02_Design/model/cpp_arch_explorer/src/frontend_main.cpp
02_Design/model/cpp_arch_explorer/README.md
```

完整结果（`results/` 被 gitignore，仅保留在本地工作区）：

```text
results/direction_stage1_short_history_20260714
results/frontend_full_20260714
results/abtb_resolved_baseline_20260714
results/frontend_barrier_baseline_20260714
results/frontend_late_override_20260714
results/frontend_f0_policy_20260714
```

## 10. 当前建议的 RTL 实施顺序

1. 先明确 BP/F0/F1 correction 的真实 penalty、优先级和 epoch/flush 行为。
2. F0 增加 B/JAL immediate 与 direct-target generator；JAL 可直接使用，
   B target 先保存，是否 steering 与方向置信度分开。
3. 一级 base 采用 PC[2] banked B256，F1 只提供一个 oldest-B tagged query。
4. TAGE 用 H4/H8；若时序失败，先降 H3/H6，不先降到 H2/H4。
5. 在 RTL 或更精确的 FTQ/FQ 时序模型中统计 F1 override 的真实平均周期；
   只有低于约 0.6～0.9 cycle 的 break-even 区间才继续落地 late TAGE，
   并比较 always 与 `strong OR useful`。
6. RAS 独立做 depth4、pending visibility、checkpoint/recovery 设计，不与
   TAGE 组合进同一关键路径。
7. 六 COE 功能/周期和 Vivado WNS/Fmax/资源全部通过后再决定是否提交架构。
