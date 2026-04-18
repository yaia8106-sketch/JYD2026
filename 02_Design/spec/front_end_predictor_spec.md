# 前端预测器规格（已废弃）

> [!CAUTION]
> 本文档对应的实现（`branch_predictor.sv`）已被删除。
> 当前 RTL 基线为 **EX-only**（所有跳转/分支在 EX 阶段处理，2 周期惩罚）。
> 重新实现分支预测器时，请编写新的规格文档。

## 历史记录

- `d1fb38f` Phase 1: JAL ID-stage early resolution — **FPGA 跑飞，已废弃**
- `c2efc29` Phase 2+: BTB + BHT + RAS — **仿真通过但未上板验证，已废弃**
- `99d0896` 关闭 JAL ID-stage + 预测器 = FPGA OK，确认 EX-only 基线稳定
- `50a5757` 回退 RTL 到基线

## 当前稳定基线性能

- 数字孪生平台：11.134s @ 200MHz（EX-only，无预测）

## 已知教训

1. **JAL ID-stage 解析在 200MHz 下时序不足** — BRAM→decoder→adder→MUX 路径超过 5ns
2. **行为仿真不能检测时序问题** — 40/40 riscv-tests 通过但 FPGA 跑飞
3. **RAS 的 stall 门控是必须的** — 否则 stall 期间 RAS 会被反复 Pop
4. **非 RET 的 JALR 不能存 BTB** — 会错误触发 RAS Pop
