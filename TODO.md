# 优化待办

> 按综合收益/成本比排序。每项完成后打勾并跑 profiling 更新数据。
>
> **注意：以下方案只是方向指引，不是强制执行的施工图。**
> AI 应理解每项优化的目标和约束，但具体实现方式可以自主判断。
> 如果在实现过程中发现更优方案，可以偏离计划——只要目标达成、回归通过即可。
> 但这是硬件工程，偏离需有度：不随意改模块接口，不破坏时序收敛，改动面要可控。

## Profiling 基线（2026-05-05，完成第 2 项后）

| 测试 | CPI | 双发率 | Load-use | S1-WB wait | DCache | 误预测率 |
|------|-----|--------|----------|------------|--------|---------|
| bp_stress | 1.223 | 22.8% | 54 | 41 | 54 | 31.7% |
| dcache_stress | 1.665 | 25.5% | 466 | 96 | 308 | 4.2% |
| counter_stress | 0.944 | 56.4% | 94 | 4 | 9 | 26.8% |
| sb_stress | 1.000 | 60.0% | 12 | 1 | 25 | 12.5% |

Profiling 工具：`02_Design/sim/riscv_tests/run_perf.sh`

---

## 待办

- [x] **1. Bank 交错取指**（消除 PC[2]=1 单发）
  - 预期：CPI -5~10%（PC[2]=1 占 ~30% 取指周期，最大单一瓶颈）
  - 复杂度：中
  - 要点：IROM 改为 even/odd bank（inst[0,2,4..] / inst[1,3,5..]），`PC[2]=1` 时读取 `odd[k] + even[k+1]`
  - ⚠️ `addr+PC[2]` 进位链进入 IROM 地址路径，需综合后评估时序
  - 结果：回归 63/63 PASS；bp_stress CPI 1.27→1.20，sb_stress CPI 1.05→1.00
  - ⚠️ **时序违例**：200MHz 下 IROM→IROM 自环 -0.96ns（5.352ns / 10 级），需配合 1b 修复

- [ ] **1b. 修复 IROM→IROM 时序环路**（紧急，阻塞后续所有优化）
  - 目标：打断 `IROM输出 → can_dual_issue → seq_next_pc(+4/+8) → irom_addr → IROM` 组合环路
  - 方案：**寄存 dual 判定（predict-last）**
    - 用上一周期的 `can_dual_issue` 结果（寄存为 `predict_dual`）选择 `seq_next_pc`
    - `assign seq_next_pc = predict_dual ? pc_plus8 : pc_plus4;`
    - `predict_dual` 是寄存器，不依赖本周期 IROM 输出 → 环路打断
  - 正确性论证（两种预错均无气泡）：
    - **dual→single 预错**（预测 +8 实际单发）：inst1 已由 `inst_buf` 保存，下周期直接用
    - **single→dual 预错**（预测 +4 实际可双发）：bank 交错保证 +4 地址也输出 2 条指令，可正常双发
  - 关键改动点：
    - `cpu_top.sv`：新增 `predict_dual` 寄存器（reset=0，if_accept 时锁存 can_dual_issue）
    - `cpu_top.sv`：`seq_next_pc` 改用 `predict_dual` 而非 `can_dual_issue`
    - `inst_buf` 逻辑可能需微调以配合预测错误的恢复
  - 验证：
    1. 回归 `run_all.sh` 全部 PASS
    2. `run_perf.sh` 确认 CPI 无明显回退（与当前基线对比）
    3. Vivado 综合确认 IROM→IROM 路径消失或 slack > 0
  - 复杂度：低
  - 风险：`inst_buf` 在 predict 错误场景下的边界情况，需仔细推演

- [x] **2. 裁剪 S1_WB 前递路径**
  - 预期：时序改善 ~0.3ns（7→6 选 1 MUX）
  - 复杂度：低
  - 数据：3/4 测试命中率 <1%（dcache_stress 14.3% 是特例）
  - 要点：删除 `forwarding.sv` 中 S1_WB 匹配，S1 写回的值需要多等 1 拍从 regfile 读取
  - 验证：跑回归确认无失败，跑 profiling 确认 CPI 影响可忽略
  - 结果：回归 63/63 PASS；S1_WB 从数据 MUX 裁剪为 `s1_wb_wait_hazard`；bp_stress CPI 1.20→1.223，counter_stress 0.94→0.944，sb_stress 1.00→1.000；dcache_stress 1.54→1.665，影响主要来自 96 个 S1-WB wait，非完全可忽略

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
