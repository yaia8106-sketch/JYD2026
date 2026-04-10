# TODO 清单

---

## AI 总结的待办

### Module Spec（待编写）

- [x] `spec/alu_spec.md` — ALU
- [x] `spec/imm_gen_spec.md` — 立即数生成器
- [x] `spec/decoder_spec.md` — 指令译码器
- [x] `spec/branch_unit_spec.md` — 分支判断单元
- [x] `spec/regfile_spec.md` — 寄存器堆（read-first）
- [x] `spec/forwarding_spec.md` — 前递 MUX + 冒险检测
- [x] `spec/if_id_reg_spec.md` — IF/ID 级间寄存器
- [ ] `spec/alu_src_mux_spec.md` — ALU 操作数选择 MUX
- [ ] `spec/wb_mux_spec.md` — WB 写回 MUX
- [ ] `spec/pc_reg_spec.md` — PC 寄存器（时序）
- [ ] `spec/next_pc_mux_spec.md` — next_pc 选择 MUX（组合）
- [ ] `spec/id_ex_reg_spec.md` — ID/EX 级间寄存器
- [ ] `spec/ex_mem_reg_spec.md` — EX/MEM 级间寄存器
- [ ] `spec/mem_wb_reg_spec.md` — MEM/WB 级间寄存器
- [ ] `spec/mem_interface_spec.md` — DRAM 接口（字节使能、符号扩展）
- [ ] `spec/top_spec.md` — 顶层连线

### RTL 实现

- [x] 按 spec 逐模块生成 `.sv` 文件（17 个模块）
- [x] 顶层集成连线 (`cpu_top.sv`)
- [x] 例化 Vivado BRAM IP（IROM / DRAM）— 独立测试用
- [x] 独立 Implementation 时序验证（222MHz，WNS = -0.990ns）

### 数字孪生平台集成（进行中）

- [ ] 确定 DRAM 容量（60K×32 vs 16K×32），决定是否需要 output register
- [ ] 重构 `cpu_top.sv` 端口：移除内部 IROM/DRAM，暴露外设总线接口
- [ ] `ex_mem_reg.sv` 新增字段：`mem_write_en`、`rs2_data`
- [ ] `mem_wb_reg.sv` 新增字段：`perip_rdata`
- [ ] 自研 `perip_bridge.sv`：地址译码 + BRAM DRAM + MMIO + 复用模板 counter
- [ ] 编写 `student_top.sv`：CPU + IROM + perip_bridge 连线
- [ ] 功能验证（cdp-tests 或 coremark）
- [ ] Implementation 时序验证（目标 ≥200MHz）

### 后期优化

- [ ] JAL 提前到 ID 级判断（penalty 2→1 拍）
- [ ] JALR 提前到 ID 级判断（视时序余量）
- [ ] coremark 跑分验证

---

## 我自己想到的

