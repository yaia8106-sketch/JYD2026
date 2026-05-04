# 双发射开发状态

> 分支：`feature/dual-issue`（基于 master M11）
> 架构主文档：`architecture.md`（13 个决策 D1-D13）

---

## 当前阶段

**Phase 4 进行中（2026-05-04）。**

说明：Phase 3 已完成并提交。Phase 4 正在做 Vivado/板级路径适配：取指路径已改为两个 32-bit slot IROM bank，slot0 保存 `word[i]`，slot1 保存 `word[i+1]`，两个 bank 共享 `irom_addr[13:2]` 以去掉 even/odd 方案中的 `+1` 地址进位链。当前 RTL 回归 `60/60 PASS`；Vivado `check current 18` 可跑完 synthesis/place/route，综合和实现 DRC 已无 IROM 组合环，但 200MHz timing 尚未闭合，当前 routed WNS 为 `-0.252ns`。剩余唯一架构级 FAIL 为 `IROM(BRAM) -> IROM(BRAM)`。

## 里程碑（详细步骤见 `dev_plan.md`）

- [x] 总体架构定稿（D1-D13，2026-05-03）
- [x] Phase 0：IROM 加宽（仿真路径，不改功能，43/43 PASS）
- [x] Phase 1：取两条，只发一条（43/43 PASS）
- [x] Phase 2：数据通路就位（仍不双发，43/43 PASS）
- [x] Phase 3：开启双发射（49/49 PASS，含 6 个专项测试） 🎯
- [ ] Phase 4：综合 + FPGA 上板（仿真通过，slot IROM Vivado 集成完成，timing 未闭合）

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
