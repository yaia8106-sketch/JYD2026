# Tradeoff 精简版

> 完整说明见 `tradeoffs.md`。本文件只保留结论和防回头路信息。

---

## T1. ID actual redirect 不走零周期 IROM 快路径

**结论**：当前 RTL 不保留零周期 `ID actual redirect -> irom_addr`。继续使用现有 `NLP ID redirect + EX fast redirect`，后续如果重试必须做注册化/队列化，而不是把真实分支结果组合进取指地址。

**否决方案**：

| 方案                         | 功能                                 | CPI 收益                          | FPGA 时序                         |
| ---------------------------- | ------------------------------------ | --------------------------------- | --------------------------------- |
| 全 BRANCH ID actual redirect | `run_all` 63/63（实验当时测试集），COE 20k diff 通过 | COE 200k 约降 `0.025~0.037 CPI` | post-place 约 `WNS=-2.5~-3.2ns` |
| 仅 BEQ/BNE 方向修正          | `run_all` 63/63（实验当时测试集），COE 20k diff 通过 | COE 200k 约降 `0.006~0.029 CPI` | post-place 约 `WNS=-2.8ns`      |

**为什么否决**：收益是真实的，但组合路径太长。该路径从 ID 前递/比较/目标选择一路打到 IROM 地址 MUX，直接压在 FPGA 最敏感的取指快路径上，200MHz 都明显不可接受。

**踩过的坑**：

- 把 JAL/JALR 也放进 ID actual redirect，或在 actual redirect 已知时抑制原 NLP redirect，曾导致 COE trace 错位。
- `id_actual_redirect_raw -> slot1 squash -> forwarding hazard -> id_ready_go -> id_actual_redirect` 容易形成组合环；即使拆出 S0-only ready 信号，时序仍不可接受。

**后续方向**：

- 若继续优化分支惩罚，考虑注册化 redirect/FIFO，而不是零周期进 IROM。
- CPI 优化优先看 load-use、slot1 发射限制、JALR 预测等不直接加长 IROM 地址快路径的方向。

---

## T2. Fetch queue / 伪前端切分不保留

**结论**：不保留 2-entry fetch packet queue 这类“队列补丁式”的前端切分。它没有真正切断 IROM 地址关键路径，反而把取指、预测、redirect、backpressure 耦合得更重。

**实测结果**：

| 对比项 | master | fetch queue 实验 |
|--------|--------|------------------|
| 官方 4 项 cycles | `3645` | `3642` |
| post-route WNS | `+0.049ns` | `-1.015ns` |
| post-route TNS | `0.000ns` | `-615.607ns` |
| failing endpoints | `0` | `1192` |
| Slice LUTs | `8666` | `9082` |
| Slice Registers | `4743` | `4926` |

**为什么否决**：周期只少 `3 cycles`，但 5ns 时钟下大面积时序失败。按运行时间看，若为了收敛放慢时钟，收益会被时钟周期恶化完全吞掉。

**后续规则**：如果重做前端流水线，必须是真正的 IF1/IF2 寄存边界，并在动 RTL 前估算 `cycles * clock_period`，不能再用队列补丁碰运气。
