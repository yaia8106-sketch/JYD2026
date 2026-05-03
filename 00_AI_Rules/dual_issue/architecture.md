# 双发射架构设计

> 复赛方向：在现有 RV32I 五级流水线基础上扩展为双发射（Dual-Issue）。
> 本文档记录架构讨论和决策，是双发射开发的主文档。

---

## 已确定决策

### D1. 双发射类型 — 顺序（In-order）
乱序需要 ROB + 寄存器重命名，FPGA 资源和时序代价过大。

### D2. 发射槽分工 — 非对称
- **Slot 0**（主槽）：ALU + Branch + Load/Store（万能槽，单发退化时兜底）
- **Slot 1**（副槽）：ALU only（预留多周期 `ready_go` 接口，为 M/F/Zb 扩展留口子）

理由：DCache 双端口控制逻辑过于复杂（双 miss 仲裁、store-to-load forwarding），收益有限。参考 Cortex-A7、SiFive U74、玄铁 C906 均采用非对称方案。

### D3. 取指 — 64-bit IROM，PC[2]=1 时单发
IROM 加宽到 64-bit，每拍读出两条指令。分支目标落在 PC[2]=1（非 8 字节对齐）时，仅取第二条，退化为单发。CPI 代价约 +0.02~0.03。

⚠️ **后续优化**：bank 交错取指可消除此代价。

### D4. 发射约束
```
can_dual_issue = inst1_is_alu_type          // Slot 1 能执行
               & no_RAW(inst1, inst0)       // inst1 不依赖 inst0 的结果
               & pc[2] == 0                 // 对齐取指
               & inst0_valid & inst1_valid  // 两条都有效
               & !inst0_is_branch           // [保守] inst0 非分支
```

- **WAW 不阻止双发** — 写回和前递加优先级（inst1 > inst0）即可
- ⚠️ **保守：inst0 为 Branch 时不双发** — 后续可改为配合 BP 激进双发

### D5. 流水线组织 — 两套独立级间寄存器（方案 B）
- Slot 0 保持现有级间寄存器模块不变（`if_id_reg.sv`、`id_ex_reg.sv` 等）
- Slot 1 新增平行的寄存器链（`id_ex_reg_s1.sv`、`ex_mem_reg_s1.sv`、`mem_wb_reg_s1.sv`）
- **控制信号共享**：`allowin` 每级一个，`ready_go` 取 AND（`slot0_rg & (slot1_rg | !slot1_valid)`），`valid` 每 Slot 各一个
- 两 Slot 同步推进（顺序执行，不可独立 stall）

理由：Slot 0 已验证通过 43 测试 + FPGA，不动它可避免回归风险。模块化便于开发和调试。

### D6. 寄存器堆 — FF 阵列 4R2W
- 保持现有 FF 实现，扩展到 4 读端口 + 2 写端口
- 32×32-bit 规模，4R 约 ~1400 LUT，现代 FPGA 上开销可忽略
- 双写端口 WAW 优先级：Slot 1 > Slot 0

### D7. 前递网络 — 7 选 1（完整前递，先不裁剪）
- 优先级：S1_EX > S0_EX > S1_MEM > S0_MEM > S1_WB > S0_WB > regfile
- 4 个操作数各一套 7 选 1 MUX
- S1_MEM 无需排除 Load（Slot 1 不做 L/S）
- 同周期 inst0→inst1 前递不做（D4 已拦截 RAW）

⚠️ **后续优化**：可裁剪低优先级前递路径（如去掉 S1_WB/S0_WB）换取时序，等综合报告后再决定。
⚠️ **后续优化**：放开 D4 的 RAW 约束后，需加 inst0→inst1 同周期前递。

### D8. Load-Use Stall — 检测扩展到 4 个源操作数
- 核心逻辑不变：Slot 0 的 Load 在 EX/MEM 时，stall 整条流水线
- Slot 1 不做 Load → Slot 1 在 EX/MEM 永远不触发 load-use stall
- 匹配范围从 2 个源（rs1, rs2）扩展到 4 个（inst0_rs1/rs2, inst1_rs1/rs2）
- 同对内 inst0 Load → inst1 依赖，已被 D4 RAW 约束拦截

### D9. 分支预测器 — 最小改动
- D4 保守约束（inst0 是分支不双发）使 BP 改动极小
- IF：需为 inst1 也查 BTB/BHT（连续 PC，可复用同次查询）
- ID/EX：不变，分支只在 Slot 0 执行，更新逻辑保持一路
- inst1 如被预测 taken → 两条都发射，下一拍从预测目标取指
- inst1 如 not taken → 正常 PC+8

⚠️ **后续优化**：放开 inst0 分支约束后，需处理 inst0 taken → inst1 作废的逻辑

### D10. DCache / DRAM — 不变
- Slot 1 不做 L/S（D2）→ DCache/DRAM/MMIO Bridge 保持单端口不变
- DCache miss 时两个 Slot 一起 stall（D5 同步推进）

### D11. Flush / Stall — 最小改动
- **Flush**：触发源不变（Slot 0 EX 级）；清除范围：IF/ID 和 ID/EX 的两个 Slot 的 valid
  - D4 保证分支时 Slot 1 无效，不需要特殊处理
- **Stall**：`allowin` 共享，`ready_go` 取 AND（D5），load-use 检测 4 源操作数（D8）

### D12. 指令缓冲 + PC 步进
- 新增 1 个 32-bit 指令缓冲寄存器 + valid bit
- 单发时，未发射的 inst1 暂存到缓冲
- 下一拍 inst0 来自缓冲（而非 IROM），同时取新 8 字节块配对 inst1
- 避免单发后连续浪费一拍的问题

PC 步进逻辑：
```
next_pc = bp_taken      ? bp_target :
          buf_valid     ? pc + 4    :   // 缓冲有效时只取下一个 8B 块的后半
          dual_issued   ? pc + 8    :
                          pc + 4;
```
注：当 buf_valid 时，IROM 取 pc+4 对应的 8B 块（即 pc+4 所在的对齐地址），inst0 来自缓冲。

⚠️ Flush 时必须清空指令缓冲（`buf_valid <= 0`）

### D13. 资源预算 — 可接受
- 新增约 2500-3000 LUT + 500 FF（约 30-50% 面积增长）
- BRAM 不增加（IROM 改宽度不多用 BRAM，DCache/DRAM 不变）
- 时序风险点：前递 7 选 1 MUX（+1 级 LUT）、ID 级发射判断逻辑，综合后看报告

---

## 后续优化汇总（⚠️ 标记项）

| 来源 | 优化方向 | 触发条件 |
|------|---------|---------|
| D3 | bank 交错取指，消除 PC[2]=1 单发代价 | 性能调优阶段 |
| D4 | inst0 为 Branch 时配合 BP 激进双发 | 基线稳定后 |
| D4+D7 | 放开 inst0→inst1 RAW，加同周期前递 | 基线稳定后 |
| D7 | 裁剪低优先级前递路径换时序 | 综合报告出来后 |
| D9 | BP 处理 inst0 taken → inst1 作废 | 放开分支约束时 |

---

## 实现计划

详见 `dev_plan.md`（5 Phase，design-verify loop）。
