# 前端预测器规格（历史记录）

> [!NOTE]
> 本文档记录分支预测器的实现历史。当前有效规格见 `branch_predictor_spec.md`。
> 当前实现：**NLP (Next-Line Predictor) Tournament 架构**，FPGA 验证通过。

## 历史记录

- `d1fb38f` Phase 1: JAL ID-stage early resolution — **FPGA 跑飞，已废弃**
- `c2efc29` Phase 2+: BTB + BHT + RAS — **仿真通过但未上板验证，已废弃**
- `99d0896` 关闭 JAL ID-stage + 预测器 = FPGA OK，确认 EX-only 基线稳定
- `50a5757` 回退 RTL 到基线
- `7a918e9` Tournament branch predictor (2-way BTB) — 仿真通过
- `6413b3a` DRAM SDP 修复 + FPGA 验证通过（EX-only 基线）
- `50b1414` **NLP timing optimization**: BTB direct-mapped + ID-stage Tournament verification
- `99849fd` **Fix: stall 期间 id_bp_redirect 门控** — ✅ FPGA 验证通过

## 当前性能

- 数字孪生平台 @200MHz：**FPGA 验证通过**（current COE，NLP 架构）
- EX-only 基线：11.134s @200MHz

## 已知教训

1. **JAL ID-stage 解析在 200MHz 下时序不足** — BRAM→decoder→adder→MUX 路径超过 5ns
2. **行为仿真不能检测时序问题** — 40/40 riscv-tests 通过但 FPGA 跑飞
3. **RAS 的 stall 门控是必须的** — 否则 stall 期间 RAS 会被反复 Pop
4. **非 RET 的 JALR 不能存 BTB** — 会错误触发 RAS Pop
5. **NLP id_bp_redirect 必须门控 stall** — 否则 load-use stall 期间分支指令丢失
6. **ID redirect 时必须覆盖 EX 的 bp_taken/bp_target** — 否则 EX 用旧值做误预测检测
