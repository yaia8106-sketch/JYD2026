# 优化待办

> 按综合收益/成本比排序。每项完成后打勾并跑 profiling 更新数据。

## Profiling 基线（2026-05-05）

| 测试 | CPI | 双发率 | Load-use | DCache | 误预测率 |
|------|-----|--------|----------|--------|---------|
| bp_stress | 1.27 | 10.3% | 53 | 55 | 29.9% |
| dcache_stress | 1.54 | 24.0% | 462 | 306 | 4.2% |
| counter_stress | 0.94 | 54.2% | 92 | 9 | 26.8% |
| sb_stress | 1.05 | 45.5% | 12 | 25 | 12.5% |

Profiling 工具：`02_Design/sim/riscv_tests/run_perf.sh`

---

## 待办

- [ ] **1. Bank 交错取指**（消除 PC[2]=1 单发）
  - 预期：CPI -5~10%（PC[2]=1 占 ~30% 取指周期，最大单一瓶颈）
  - 复杂度：中
  - 要点：IROM 改为 even/odd bank（inst[0,2,4..] / inst[1,3,5..]），addr 共享但 odd bank 用 addr+1。需要新的 COE 拆分方式
  - ⚠️ odd bank 的 addr+1 进位链会吃时序，需评估

- [ ] **2. 裁剪 S1_WB 前递路径**
  - 预期：时序改善 ~0.3ns（7→6 选 1 MUX）
  - 复杂度：低
  - 数据：3/4 测试命中率 <1%（dcache_stress 14.3% 是特例）
  - 要点：删除 `forwarding.sv` 中 S1_WB 匹配，S1 写回的值需要多等 1 拍从 regfile 读取
  - 验证：跑回归确认无失败，跑 profiling 确认 CPI 影响可忽略

- [ ] **3. 裁剪 S0_WB 前递路径**
  - 预期：时序再改善 ~0.2ns（6→5 选 1 MUX）
  - 复杂度：低
  - 数据：命中率 1~17%，影响比 S1_WB 大
  - 要点：砍掉后会增加 load-use stall（WB 级数据要多等 1 拍），需要 profiling 验证 CPI 代价是否可接受
  - 验证：跑回归 + profiling 对比

- [ ] **4. Slot1 扩展 Load/Store**
  - 预期：双发率 +15~22%
  - 复杂度：很高
  - 数据：inst1 非 ALU 占 15-22% 取指周期
  - 要点：需要第二套 memory interface、DCache 双端口或仲裁、forwarding 扩展
  - 建议：等前 3 项完成、时序有余量后再考虑

- [ ] **5. inst0→inst1 同周期前递（放开 RAW）**
  - 预期：双发率 +1~13%
  - 复杂度：高
  - 数据：RAW 依赖占比低（多数测试 <2%，counter_stress 13% 是特例）
  - 要点：需要在 ID 级加 inst0→inst1 的组合前递，时序紧张
  - 建议：收益不确定，优先级最低
