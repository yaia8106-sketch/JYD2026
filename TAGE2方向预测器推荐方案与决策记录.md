# TAGE2 方向预测器推荐方案与决策记录

> 最后更新：2026-07-14  
> 状态：C++ 六程序方向与 FDQ 研究完成；未修改 RTL

## 最终推荐

结合当前 BP/F0/F1 前端，推荐的第一版方向结构不是传统“F1 完整 TAGE”，
而是“系统一级预测 + F1 两张 tagged table”：

```text
BP/F0
├── 256-entry PC-indexed bimodal PHT
├── F0 识别 JAL/B，并计算 PC+imm
└── JAL 恒 taken；B 保留一级有效方向

F1 tagged-only
├── T0：64 entries，history=4，tag=6
├── T1：64 entries，history=8，tag=7
├── 每 entry：3-bit signed counter + useful + valid
├── 弱新 provider 使用 alternate
├── tag miss：严格保持 BP/F0，不 correct
└── final tagged source 为 strong 或 useful 时才允许 correct
```

TAGE 只负责 B-type 方向，不负责 target；JAL/JALR 不进入 TAGE。B/JAL
target 由 F0 的 `PC+imm` 产生，RET 留给未来独立 RAS。

## 为什么选它

六程序共有 1,079,314,150 个动态 B-type。推荐方案相对当前 GShare：

| 更新延迟 | 当前方向错误 | 推荐方向错误 | 降幅 |
| --- | ---: | ---: | ---: |
| delay=6 | 221,855,950 | 199,067,139 | 10.272% |
| delay=10 | 240,730,785 | 219,513,622 | 8.814% |

六个程序逐一均不退化。H1/H2、H2/H4 收益明显较少；H4/H8 在 2×64
配置的 delay=6/10 中都最好；H12/H16 没有带来额外收益。8-bit GHR 因此
并不大，正好覆盖当前最优最长历史。

2×128 能把方向错误再降到 194,177,465/216,650,491，但 tagged/history
状态从约 1,480 bit 增至 3,208 bit，额外收益不足以成为第一版首选。

PC bimodal 单独使用会比当前 GShare 多 12.46%/5.30% 方向错误，所以不要
只改 PC 索引后长期停留；应把 PC base 与 F1 tagged tables 作为一个整体。

## 参数与资源

```text
Base index：bank=PC[2]，row=PC[9:3]
Base：256 × 2 bit                           = 512 bit
T0：64 × (tag6 + counter3 + useful + valid)= 704 bit
T1：64 × (tag7 + counter3 + useful + valid)= 768 bit
Committed GHR                               =   8 bit
------------------------------------------------------
方向状态总计                                = 1992 bit
```

相对当前 512-bit PHT+8-bit GHR，新增约 1,472 bit。只查询 fetch block 中
程序序最老的 B，T0/T1 保留共享 64-entry 容量，不复制双读表。

推荐 late-override：

```text
allow_override = final_source_is_tagged
               && (counter <= -2 || counter >= +1 || useful)
```

它比无过滤版本同时更准、correct 更少：delay=10 的 correction 从
207,282,944 降到 199,564,845；tag miss correction 恒为 0。

## F1 correct 的落地门槛

FDQ C++ 模型保留 correct 前的正确队列前缀，没有把 correct 当成 backend
flush。depth=8、一个额外 producer interval 时，每次 correct 平均仍保留
3.473 条指令，队列在 correction 当刻为空的比例为 0%；一个名义空档只
折算成约 0.381 cycle/correction。

尽管如此，约 2.0 亿次 correct 的累积影响仍然明显：

| correct 后正确 packet 到达 | 六程序周期变化 | 决策 |
| --- | ---: | --- |
| 下一个正常周期，0 个额外 interval（R1） | **+1.205%** | 推荐 |
| 额外丢 1 个 interval（R2） | **-0.064%** | 临界，不无条件启用 |
| 额外丢 2 个 interval（R3） | **-1.624%** | 淘汰 |

R1 下六个程序逐一不退化；R2 下 `src2` 为 -0.486%，
`new_without_Mext` 为 -1.326%。因此真正的下一步不是继续扩大 TAGE，
而是按时钟沿确认 F1 correct 到 corrected IROM packet 的实际间隔。若接口
属于 R1，本方案有明确正收益；若属于 R2，应保留当前 GShare 一级或继续
降低 correction，而不是直接采用 PC-base unconditional override。

诊断数据也支持这个 fallback：当前 GShare 一级接相同 2×64 tagged-only
时，R2 汇总为 +0.195%，因为 correction 约 1.51 亿次而不是 2.00 亿次；
代价是方向错误比 PC-base 推荐门控多约 116 万次，且仍有单程序回退。

## 与本架构结合的关键规则

1. F0 译码出 JAL 后方向恒 taken，并直接使用 `PC+J-imm`。
2. F0 可以提前算 B target，但不能在所有 ABTB miss 上无条件采用 PHT
   taken；tag miss 时保留 BP/F0 的有效方向。
3. F1 不含私有 bimodal base；两张 tag 都 miss 时 next PC 完全不变。
4. prediction-time GHR/index/tag/provider/counter/useful 随指令保存，更新时
   不用新 GHR 重算。
5. TAGE 使用 committed 8-bit GHR，在 EX 结果允许进入 MEM 的时钟沿训练。
6. JALR/RET 不进入 TAGE。RAS 必须单独考虑 pending CALL 可见性和错误路径
   checkpoint/recovery，避免再次形成 F1 关键路径。
7. 当前 ABTB actionable miss 只占 resolved CFI 约 0.35%，不优先扩 target
   容量；方向和 RET target 的优先级更高。

## 推荐实施顺序

1. 先用沿/周期图或小 testbench 确认 F1 correct 是 R1 还是 R2。
2. 增加 F0 JAL/B direct-target generator；JAL 可先独立落地。
3. PC bimodal 与 F1 tagged-only 一起实现，避免只留下退化的 bimodal。
4. 第一版固定 2×64、H4/H8、6/7-bit tag、oldest-B 单读口。
5. 实现 alternate、allocation、useful 和 `strong OR useful` 门控。
6. 六 COE 全部功能通过后比较总周期、逐程序回退、WNS/Fmax 和资源。
7. TAGE 稳定后再独立加入带恢复的 RAS。

## 详细数据与代码

完整思考过程、逐配置结果、FDQ 场景和模型差异：

```text
02_Design/cpp_arch_explorer/TAGGED_ONLY_F1_STUDY_20260714.md
```

C++ 探索器：

```text
02_Design/cpp_arch_explorer/src/direction_predictor.*
02_Design/cpp_arch_explorer/src/frontend_model.*
02_Design/cpp_arch_explorer/src/fdq_model.*
```

原始 CSV 位于 `02_Design/cpp_arch_explorer/results/`，该目录被 gitignore，
只保留在当前工作区。旧的完整 TAGE/break-even 分析已被本次 tagged-only
和 FDQ 研究取代，不应再引用“F1 私有 bimodal base”或把每次 correct 当作
固定 penalty。
