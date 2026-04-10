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
- [ ] 例化 Vivado BRAM IP（IROM / DRAM）

### 后期优化

- [ ] JAL 提前到 ID 级判断（penalty 2→1 拍）
- [ ] JALR 提前到 ID 级判断（视时序余量）

---

## 我自己想到的

