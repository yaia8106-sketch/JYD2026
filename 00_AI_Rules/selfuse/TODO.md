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

- [x] ~~JAL 提前到 ID 级判断（penalty 2→1 拍）~~ — **已实现 (d1fb38f)，但 FPGA 验证未通过**
  > 30-bit 加法器优化，200MHz 时序通过，riscv-tests 40/40 PASS。
  > **问题**：数字孫生平台 FPGA 上跑飞。关闭后 FPGA 正常，待排查。
- [x] ~~JALR 提前到 ID 级判断（视时序余量）~~ — **取消**
  > 200MHz 下寄存器读取 + 加法器时序无法收敛。改用 BTB+RAS 方案。
- [X] **riscv-tests 功能验证环境搭建** (已完成，含 Custom Env/自动化脚本)
- [X] **riscv-tests 全量功能通过** (40/40 PASS ✅)
- [X] **Phase 2+: 前端综合预测中心 (c2efc29)**
  - [X] 32-entry BTB (LUTRAM): JAL/Branch/RET 0 拍跳转
  - [X] 4-entry RAS: 函数返回地址栈
  - [X] 64-entry BHT: 2-bit 饱和计数器方向预测
  - [X] 预测感知 branch_unit: 正确预测时抑制 flush
  - [X] 200MHz 时序通过 (WNS = +0.064ns)
- [X] **Bugfix: 预测器三个关键 Bug 修复 (8a6fac0)**
  - [X] branch_unit: JAL 纳入 actual_taken，防止 BTB 命中后 EX 错误 flush
  - [X] cpu_top: 只对真正 RET 存 BTB，防止普通 JALR 触发 RAS pop
  - [X] branch_predictor: if_allowin 门控，防止 stall 时重复 pop
  - [X] run_all.sh: 加入 branch_predictor.sv
- [~] **FPGA 数字孫生平台验证**
  - [X] 基线确认：EX-only + 无预测器 = FPGA 正常 (11.134s @ 200MHz)
  - [ ] 定位 JAL ID 级优化导致 FPGA 跑飞的根因
  - [ ] 修复后重新启用 Phase 1 + Phase 2+ 预测器
- [ ] Phase 3: GShare（如 BHT 效果不足，替换为全局预测）
- [ ] coremark 跑分验证
- [ ] P&R 策略优化（Performance_Explore / Pblock）—— 如需进一步提频

---

## 我自己想到的

- [ ] TCL 脚本一键创建 Vivado 工程（自动导入 RTL、IP、约束、COE）— **暂缓**
  > 初次尝试失败：Vivado 工程的 IP 配置、BRAM 参数、文件依赖关系等
  > 过于复杂，难以通过脚本完全自动化。等以后有空再研究。
