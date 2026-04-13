# 设计决策记录

> 本文档记录所有架构级设计决策的结论和理由。供自己回顾用。
> 决策结论会被提炼到 `design_rules/` 中供 AI 遵守。

---

## A. 寄存器堆读写冲突策略

**决策：Read-first（读旧值）**

- WB 写 x5 同一拍 ID 读 x5 → ID 读到**旧值**
- 实现方式：regfile 无需内部 bypass，纯 32:1 MUX 读取
- 影响：前递 MUX 需要处理 EX、MEM、WB 三级前递
- 理由：read-first regfile + 3 级前递的**总组合路径比** write-first + 2 级前递**更短**（bypass MUX 串联在 regfile 读路径上增加深度，而前递 MUX 多一级只是并联输入）

---

## B. 分支 Flush 代价

**决策：Flush 代价 = 2 拍气泡**

- 分支在 EX 级判断，默认顺序执行，错了 flush
- IROM 为 1 拍 BRAM（无 Output Register），flush 时 `irom_addr` 立即切换到 `branch_target`
- 冲刷 2 条指令：IF/ID 中的错误指令 + BRAM 正在取的下一条错误指令
- 时序（阶段→动作）：
  ```
  Cycle N:    EX 检测分支 → flush=1, irom_addr=branch_target, IF/ID.valid←0
  Cycle N+1:  BRAM Clk-to-Q 出目标指令, ID=bubble, EX=bubble（第1拍气泡）
  Cycle N+2:  IF/ID 锁存目标指令(id_valid=1), EX=bubble（第2拍气泡）
  Cycle N+3:  目标指令进入 EX，恢复正常执行
  ```
- 对比旧方案（2 拍 BRAM）：flush 代价从 3 拍降到 2 拍

---

## C. JAL/JALR 跳转处理

**决策：初版全部在 EX 级处理，后期优化 JAL 提前到 ID 级**

- 初版：BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR 全部在 EX 级判断，flush 代价统一 2 拍
- 后期优化（时序允许时）：JAL 提前到 ID 级判断，penalty 从 2 拍降到 1 拍
  - JAL 在 ID 级只需要 PC + imm 的加法，组合路径可控
  - JALR 需要读寄存器 + 加立即数，组合路径可能太长，暂不考虑提前
- 理由：先保证正确性和架构简洁，性能优化后面再做

---

## D. 控制信号定义

**决策：已定义，见 `design_rules/isa_encoding.md`**

- 14 个控制信号，覆盖 ALU 操作、操作数选择、写回、访存、分支判断、立即数类型
- ALU 操作用 4-bit 编码 10 种运算
- 分支条件直接复用 funct3 编码，无需额外转换
- LUI 通过 alu_src1_sel=0（零）+ ADD 实现，不需要额外的 ALU 操作码
- 分支/跳转判断：ALU 计算目标地址，独立比较器判断条件，两者并行
- JAL/JALR 的 link 地址（PC+4）在 ID 级计算并通过流水线传递，wb_sel=10 选择

---

## E. DRAM 访存细节

**决策：32-bit Single Port BRAM + 4-bit WEA 字节使能**

- DRAM 宽度 32-bit，BRAM 地址端口接收 word 地址（`ALU_result[?:2]`，去掉低 2 位）
- `addr[1:0]`（ALU_result 的低 2 位）**不送 BRAM**，而是通过流水线传递，用于：
  - Store：与 `mem_size` 一起生成 WEA（字节使能）+ 将写数据移位到正确的字节位置
  - Load：在 WB 级与 `mem_size`/`mem_unsigned` 一起从 BRAM 32-bit dout 中提取正确的 byte/halfword，并做符号/零扩展
- WEA 由 `addr[1:0]`（定位在哪）+ `mem_size`（定义写多宽）共同决定
- `addr[1:0]`、`mem_size`、`mem_unsigned` 需要通过流水线传递到 WB 级

---

## F. 前递完整路径

**决策：前递 MUX 在 ID 级，3 级前递（EX > MEM > WB > regfile）**

前递 MUX 为 rs1 和 rs2 各一个，采用并行匹配 + 优先级编码 + one-hot MUX 结构（详见 `pipeline.md` §9.1）。

MEM 级前递显式排除 Load 指令（`!mem_is_load`），因为 MEM 级的 ALU 结果是 Load 的地址而非数据。

各级前递数据来源：

| 级 | 数据信号 | 来源 | 说明 |
|----|---------|------|------|
| EX | `ex_alu_result` | EX 级 ALU 组合逻辑输出 | Load 在 EX 时数据不可用 → Load-Use stall |
| MEM | `mem_alu_result` | EX/MEM_reg 输出 | 只有 ALU 结果可前递，Load 数据在 MEM 级仍不可用 |
| WB | `wb_write_data` | `wb_is_load ? wb_dram_dout : wb_alu_result` | Load 数据此时才可用（经 MEM/WB 寄存器传递） |
| regfile | `rf_rd1_data` / `rf_rd2_data` | regfile 读端口输出 | read-first，WB 同拍写读读到旧值 |

控制信号来源：
- `ex_valid`, `ex_reg_write`, `ex_rd`：来自 ID/EX_reg 输出
- `mem_valid`, `mem_reg_write`, `mem_rd`：来自 EX/MEM_reg 输出
- `wb_valid`, `wb_reg_write`, `wb_rd`：来自 MEM/WB_reg 输出

---

## F2. Load-Use Stall 与 1-cycle BRAM 的权衡

**决策：保持 2 拍 stall 不变（暂不加 MEM Load 前递）**

DRAM 从 2 拍 BRAM（有 output register）改为 1 拍（无 output register）后，load 数据在 MEM 阶段就可用（BRAM Clk-to-Q）。
理论上可以从 MEM 阶段直接前递 load 数据到 ID 阶段，将 load-use penalty 从 2 拍降到 1 拍。

### 权衡分析

当前 `load_in_mem` stall 的原因（2 拍 BRAM 时）：MEM 阶段 load 数据不可用。
改为 1 拍 BRAM 后：MEM 阶段 BRAM 已输出数据，`load_in_mem` 可以去掉。

但需要在 MEM 阶段增加 load 前递路径：
```
BRAM Clk-to-Q(2.0) + output MUX(0.2) + mem_interface(0.5)
+ routing(0.5) + 前递MUX(0.3) + routing到ID/EX(0.5) = ~4.0ns
```

对比当前最长路径 3.65ns（EX 前递），这会成为新瓶颈。

### 决策理由

- 4.0ns 路径在 222MHz（4.5ns 周期）下 slack 仅 ~0.5ns，布线后大概率违例
- 当前 2 拍 stall 功能正确，性能损失可通过编译器调度部分弥补
- 先保证时序收敛，后期优化时再考虑此路径

### 后期优化方向

如果需要降低 load-use penalty：
1. 降频到 200MHz（5.0ns），给 MEM load 前递留更多余量
2. 只对 LW（word load）做 MEM 前递，LB/LH 走 2 拍 stall（省去 mem_interface 延迟）
3. 将 mem_interface 的字节提取逻辑移到前递 MUX 之后（WB 侧处理）

---

## G. IROM/DRAM Vivado IP 配置

**IROM：Single Port ROM，32-bit，不启用输出寄存器（1 拍延迟），COE 文件初始化 — 已确定**

**DRAM：Single Port RAM，32-bit，不启用输出寄存器（1 拍延迟），WEA 4-bit 字节使能 — 已确定**

- 不需要双端口：Load 和 Store 统一用 EX 级 ALU 输出作地址，同一时刻只有一条指令在 EX
- 地址粒度：word 地址（BRAM 地址 = ALU_result[?:2]）
- 当前 DRAM 为 65536×32bit（256KB），使用约 64 个 RAMB36E1

### IROM 取指架构（预取方案）

IROM 为 1 拍 BRAM（无 Output Register），采用预取方案：

```
irom_addr = branch_flush  ? branch_target :   // 分支：预取目标
            !if_allowin   ? pc :               // 停顿：保持当前地址
                            next_pc;           // 正常：预取下一条
```

- **正常执行**：`irom_addr = next_pc = pc + 4`，BRAM 提前 1 拍锁存下一条指令地址
- **分支 flush**：`irom_addr = branch_target`，BRAM 立即锁存目标地址，1 拍后出正确指令
- **load-use stall**：`irom_addr = pc`，BRAM 保持当前地址，stall 解除后出正确指令
- IF/ID 寄存器同时锁存 PC 和指令（`id_pc` + `id_inst`），确保 ID 阶段天然对齐
- PC 复位值 = `0x7FFF_FFFC`（= text_base - 4），使首拍 `next_pc = 0x8000_0000`

### DRAM Output Register 决策

三种方案对比后确定不勾选 output register：
- 内建 output reg（2 拍）：MUX 在输出寄存器之后，WB 的 Clk-to-Q = 2.1ns
- 手动加 reg（2 拍）：MEM 阶段压力与不勾选完全相同（3.5ns），多等 1 拍无优势
- 不勾选（1 拍）：MEM/WB 寄存器承担原来 output register 的角色

### 已完成的改动

- `if_id_reg.sv`：新增 `if_inst` / `id_inst` 传递（锁存指令到 ID 阶段）
- `cpu_top.sv`：`irom_addr` 三路 MUX（branch_target / pc / next_pc）
- `cpu_top.sv`：decoder/imm_gen/regfile 读地址从 `irom_data` 改为 `id_inst`
- `pc_reg.sv`：复位值改为 `0x7FFF_FFFC`（预取方案需要 text_base - 4）
- `mem_wb_reg.sv`：新增 `mem_dram_dout` → `wb_dram_dout` 传递

### 平台集成架构

1. **IROM**：在 `student_top` 例化，cpu_top 通过 `irom_addr` / `irom_data` 端口访问
2. **DRAM**：由自研 `perip_bridge` 管理，EX 阶段 ALU 直连 BRAM 地址
3. **MMIO 读**：组合逻辑，在 MEM 阶段用 `mem_addr` 做地址译码
4. **MMIO 写**：时序逻辑，在 MEM→WB 沿执行（用 `mem_wea`/`mem_wdata`/`mem_addr`），⚠ [UNVERIFIED]
5. **DRAM 写**：仍在 EX→MEM 沿执行（BRAM 必须同沿写入）
6. **DRAM 容量**：65536×32bit（256KB），50MHz 下时序余量充足

---

## H. Flush / Stall 时 IROM 地址控制

**决策：通过 `irom_addr` 三路 MUX + valid gating 处理**

- **分支 flush**：`irom_addr = branch_target`，BRAM 立即锁存正确地址。flush 沿 IF/ID.valid = 0（1 拍气泡），下一拍 BRAM 输出正确指令，IF/ID 正常锁存
- **load-use stall**：`irom_addr = pc`（不是 next_pc），BRAM 保持锁存当前指令地址。stall 解除时 BRAM 输出的是正确指令（不会跳过一条）
- **正常执行**：`irom_addr = next_pc`，预取下一条
- 关键：三路 MUX 优先级为 `branch_flush > !if_allowin > default`
- 不需要额外的 BRAM flush 或 enable 控制机制

---

## I. MMIO 写时序优化 ⚠ [UNVERIFIED]

**决策：MMIO 写从 EX→MEM 沿推迟到 MEM→WB 沿**

### 背景

原始关键路径：`ID/EX_reg → ALU(6级) → is_dram(2级) → MMIO 判断(5级) → cnt_enable_cfg_reg`
= 15 级 LUT, 5.428ns, slack = -0.016ns（违例）

### 改动内容

- `perip_bridge` 新增 `mem_wea`/`mem_wdata` 打拍寄存器（与已有的 `mem_addr`/`mem_is_dram` 并列）
- MMIO 写条件从 `|wea && !is_dram` 改为 `|mem_wea && !mem_is_dram`
- DRAM 写路径不变（BRAM 仍在 EX→MEM 沿写入）

### 安全性分析（REG/COMB 标记法推演）

- MMIO 写（always_ff posedge）+ MMIO 读（wire 组合逻辑）= write-first 行为
- 背靠背 SW→LW 到同一 MMIO 地址：REG N 写入 seg_wdata，COMB N 读取 seg_wdata = 新值 ✓
- 无需 stall 或 bypass
- 详见 `design_rules/timing_notation.md` 示例

### 效果

- WNS: -0.016ns → +0.517ns（违例消除）
- cnt_enable_cfg 路径从 Top 10 消失
- 新的最差路径：ID/EX → DRAM WEA（4.455ns, 7 级, slack +0.517ns）

### 待验证

- [ ] riscv-tests ISA 合规测试
- [ ] MMIO 读写功能（LED / 数码管 / Counter）
- [ ] Coremark 跑分
