# TODO 清单

---

## AI 总结的待办

### Module Spec（待编写）

- [X] `spec/alu_spec.md` — ALU
- [X] `spec/imm_gen_spec.md` — 立即数生成器
- [X] `spec/decoder_spec.md` — 指令译码器
- [X] `spec/branch_unit_spec.md` — 分支判断单元
- [X] `spec/regfile_spec.md` — 寄存器堆（read-first）
- [X] `spec/forwarding_spec.md` — 前递 MUX + 冒险检测
- [X] `spec/if_id_reg_spec.md` — IF/ID 级间寄存器
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

- [X] 按 spec 逐模块生成 `.sv` 文件（17 个模块）
- [X] 顶层集成连线 (`cpu_top.sv`)
- [X] 例化 Vivado BRAM IP（IROM / DRAM）— 独立测试用
- [X] 独立 Implementation 时序验证（222MHz，WNS = -0.990ns）

### 数字孪生平台集成（进行中）

- [X] 确定 DRAM Output Register 策略：不勾选（1 拍延迟）
- [X] `mem_wb_reg.sv`：新增 `mem_dram_dout` / `wb_dram_dout` 传递
- [X] `cpu_top.sv`：`dram_dout` 改走 MEM/WB 寄存器
- [X] `mem_interface.sv`：修复 `* 4'd8` → `{addr, 3'b0}`
- [X] IROM/DRAM 确认为 1 拍 BRAM（无 Output Register）
- [X] IROM 预取方案：`irom_addr` 三路 MUX（branch_target / pc / next_pc）
- [X] IF/ID 寄存器存指令：`if_inst` → `id_inst`，decoder/imm_gen 使用 `id_inst`
- [X] PC 复位值改为 `0x7FFF_FFFC`（预取方案需要 text_base - 4）
- [X] 重构 `cpu_top.sv` 端口：移除内部 IROM/DRAM，暴露 IROM 和外设总线接口
- [X] 编写 `student_top.sv`：CPU + IROM + perip_bridge 连线
- [X] 仿真验证（Vivado 行为仿真 37 个测试全通过 ✅）
- [X] DRAM 容量确定为 65536×32bit（256KB）
- [X] FPGA 烧录验证通过 ✅（LED 显示对勾 + 数码管显示 37）
- [X] Implementation 时序验证通过（50MHz）
- [X] perip_bridge 写路径时序优化（ALU sum 直出 + 部分译码 + 并行 AND-OR）
- [X] Implementation 200MHz 时序验证通过（slack +0.011ns，瓶颈为布线延迟）

### 后期优化

- [ ] JAL 提前到 ID 级判断（penalty 2→1 拍）
- [ ] JALR 提前到 ID 级判断（视时序余量）
- [ ] coremark 跑分验证
- [ ] P&R 策略优化（Performance_Explore / Pblock）—— 如需进一步提频

---

## 我自己想到的
