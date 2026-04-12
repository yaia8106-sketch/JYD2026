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
- 方案 B BRAM（两级流水线）导致 flush 后需要 2 拍重新填充 IROM 流水线
- 时序分析详见 `pipeline.md` 第 8 节
- BRAM 流水线残留的错误指令通过 IF/ID_reg.valid = 0 屏蔽，不产生副作用

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
| WB | `wb_write_data` | `wb_is_load ? dram_dout : wb_alu_result` | Load 数据此时才可用（DRAM dout 与 MEM/WB_reg 对齐） |
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

**IROM：Single Port ROM，32-bit，启用输出寄存器（2 拍延迟），COE 文件初始化 — 不变**

**DRAM：Single Port RAM，32-bit，不启用输出寄存器（1 拍延迟），WEA 4-bit 字节使能 — 已确定**

- 不需要双端口：Load 和 Store 统一用 EX 级 ALU 输出作地址，同一时刻只有一条指令在 EX
- 地址粒度：word 地址（BRAM 地址 = ALU_result[?:2]）
- 当前 DRAM 为 65536×32bit（256KB），使用约 64 个 RAMB36E1

### Output Register 决策过程

三种方案对比后确定不勾选 output register：
- 内建 output reg（2 拍）：MUX 在输出寄存器之后，WB 的 Clk-to-Q = 2.1ns
- 手动加 reg（2 拍）：MEM 阶段压力与不勾选完全相同（3.5ns），多等 1 拍无优势
- 不勾选（1 拍）：MEM/WB 寄存器承担原来 output register 的角色

### 已完成的 standalone 改动

- `mem_wb_reg.sv`：新增 `mem_dram_dout` → `wb_dram_dout` 传递
- `cpu_top.sv`：`mem_interface.load_dram_dout` 从 `dram_dout` 改接 `wb_dram_dout`（经 MEM/WB 寄存器）
- IROM 保持 2 拍延迟不变

### 计划变更（数字孪生平台集成）

1. **IROM**：移到 `student_top`，cpu_top 通过 `irom_addr` / `irom_data` 端口访问
2. **DRAM**：由自研 `perip_bridge` 管理，EX 阶段 ALU 直连 BRAM 地址
3. **MMIO 读**：组合逻辑，在 MEM 阶段用 `mem_alu_result` 做地址译码（组合路径 ~3ns < BRAM 路径 ~3.5ns，不构成瓶颈）
4. **MMIO 写**：时序逻辑，与 DRAM 写在同一个时钟沿（EX→MEM）执行
5. **DRAM 容量**：待定，65536 时 3 级输出 MUX 使 MEM 阶段偏紧

---

## H. Flush 时 BRAM 残留数据处理

**决策：通过 valid gating 自然屏蔽**

- Flush 后 IROM BRAM 流水线中可能有错误路径的指令正在 stage1→stage2 传递
- 但 flush 已将 IF/ID_reg.valid = 0，所以这些残留指令即使到了 IROM dout，对应的 IF/ID_reg.valid 仍为 0（气泡）
- 气泡不会产生任何副作用（所有副作用操作都经过 valid gating）
- **不需要额外的 BRAM flush 机制**
