# Tradeoff 精简版

> 完整说明见 `tradeoffs.md`。本文件只保留结论和防回头路信息。

---

## T1. ID actual redirect 不走零周期 IROM 快路径

**结论**：当前 RTL 不保留零周期 `ID actual redirect -> irom_addr`。继续使用现有 `NLP ID redirect + EX fast redirect`，后续如果重试必须做注册化/队列化，而不是把真实分支结果组合进取指地址。

**否决方案**：

| 方案                         | 功能                                 | CPI 收益                          | FPGA 时序                         |
| ---------------------------- | ------------------------------------ | --------------------------------- | --------------------------------- |
| 全 BRANCH ID actual redirect | `run_all` 63/63，COE 20k diff 通过 | COE 200k 约降 `0.025~0.037 CPI` | post-place 约 `WNS=-2.5~-3.2ns` |
| 仅 BEQ/BNE 方向修正          | `run_all` 63/63，COE 20k diff 通过 | COE 200k 约降 `0.006~0.029 CPI` | post-place 约 `WNS=-2.8ns`      |

**为什么否决**：收益是真实的，但组合路径太长。该路径从 ID 前递/比较/目标选择一路打到 IROM 地址 MUX，直接压在 FPGA 最敏感的取指快路径上，200MHz 都明显不可接受。

**踩过的坑**：

- 把 JAL/JALR 也放进 ID actual redirect，或在 actual redirect 已知时抑制原 NLP redirect，曾导致 COE trace 错位。
- `id_actual_redirect_raw -> slot1 squash -> forwarding hazard -> id_ready_go -> id_actual_redirect` 容易形成组合环；即使拆出 S0-only ready 信号，时序仍不可接受。

**后续方向**：

- 若继续优化分支惩罚，考虑注册化 redirect/FIFO，而不是零周期进 IROM。
- CPI 优化优先看 load-use、slot1 发射限制、JALR 预测等不直接加长 IROM 地址快路径的方向。
