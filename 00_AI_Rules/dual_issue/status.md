# 双发射开发状态

> 分支：`feature/dual-issue`（基于 master M11）
> 架构主文档：`architecture.md`（13 个决策 D1-D13）

---

## 当前阶段

**Phase 1 已完成（2026-05-03），进入 Phase 2 前准备。**

说明：按用户要求暂不修改 Vivado 工程/IP。Phase 1 已完成 RTL/仿真路径：取两条、指令缓冲、Decoder1、Slot1 空壳寄存器链就位；`can_dual_issue=0`，Slot1 不参与执行。

## 里程碑（详细步骤见 `dev_plan.md`）

- [x] 总体架构定稿（D1-D13，2026-05-03）
- [x] Phase 0：IROM 加宽（仿真路径，不改功能，43/43 PASS）
- [x] Phase 1：取两条，只发一条（43/43 PASS）
- [ ] Phase 2：数据通路就位（仍不双发）
- [ ] Phase 3：开启双发射 🎯
- [ ] Phase 4：综合 + FPGA 上板

## 关键决策速查

| ID | 一句话 |
|----|--------|
| D1 | 顺序双发射 |
| D2 | 非对称：S0 万能，S1 ALU only |
| D3 | 64-bit IROM，PC[2]=1 单发 |
| D4 | RAW + 类型 + 分支不双发 ⚠️ |
| D5 | 两套独立级间寄存器 |
| D6 | regfile FF 4R2W |
| D7 | 前递 7 选 1 ⚠️ |
| D12 | 指令缓冲 + PC +4/+8 |
