# 译码器模块规格

> 纯组合逻辑模块。根据 32-bit 指令生成 14 个控制信号。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `inst` | input | 32 | 数据 | 原始指令（来自 IF/ID 寄存器 `id_inst`） |
| `alu_op` | output | 4 | 控制（组合） | ALU 操作类型（`{funct7[5], funct3}` 编码） |
| `alu_src1_sel` | output | 2 | 控制（组合） | ALU 源 1：`00`=rs1, `01`=PC, `10`=0 |
| `alu_src2_sel` | output | 1 | 控制（组合） | ALU 源 2：`0`=rs2, `1`=立即数 |
| `reg_write_en` | output | 1 | 控制（组合） | 是否写回寄存器堆 |
| `wb_sel` | output | 2 | 控制（组合） | 写回来源：`00`=ALU, `01`=DRAM dout, `10`=PC+4 |
| `mem_read_en` | output | 1 | 控制（组合） | 是否读 DRAM（Load） |
| `mem_write_en` | output | 1 | 控制（组合） | 是否写 DRAM（Store） |
| `mem_size` | output | 2 | 控制（组合） | 访存宽度：`00`=B, `01`=H, `10`=W |
| `mem_unsigned` | output | 1 | 控制（组合） | Load 零扩展标志 |
| `is_branch` | output | 1 | 控制（组合） | 是否为 B-type 分支 |
| `branch_cond` | output | 3 | 控制（组合） | 分支条件（直接复用 funct3） |
| `is_jal` | output | 1 | 控制（组合） | 是否为 JAL |
| `is_jalr` | output | 1 | 控制（组合） | 是否为 JALR |
| `imm_type` | output | 3 | 控制（组合） | 立即数类型 |

---

## 2. 功能描述

### 2.1 指令字段提取

```
opcode = inst[6:0]
funct3 = inst[14:12]
funct7 = inst[31:25]
```

### 2.2 opcode 译码（one-hot）

| 信号 | opcode | 指令类型 |
|------|--------|---------|
| `is_r_type` | `7'b0110011` | R-type（ADD/SUB/...） |
| `is_i_alu`  | `7'b0010011` | I-type ALU（ADDI/SLTI/...） |
| `is_load`   | `7'b0000011` | Load（LB/LH/LW/LBU/LHU） |
| `is_store`  | `7'b0100011` | Store（SB/SH/SW） |
| `is_branch` | `7'b1100011` | Branch（BEQ/BNE/...） |
| `is_lui`    | `7'b0110111` | LUI |
| `is_auipc`  | `7'b0010111` | AUIPC |
| `is_jal`    | `7'b1101111` | JAL |
| `is_jalr`   | `7'b1100111` | JALR |

### 2.3 控制信号生成规则

#### `alu_op`
- R-type：`{funct7[5], funct3}` 直接透传
- I-type ALU：`{funct7[5] & (funct3 == 3'b101), funct3}`（仅移位指令使用 funct7[5] 区分 SRLI/SRAI）
- 其他所有指令：`ALU_ADD`（4'b0_000）

#### `alu_src1_sel`
- `01`（PC）：Branch, AUIPC, JAL
- `10`（零）：LUI
- `00`（rs1）：其他

#### `alu_src2_sel`
- `1`（立即数）：I-type ALU, Load, Store, Branch, LUI, AUIPC, JAL, JALR
- `0`（rs2）：R-type

#### `reg_write_en`
- `1`：R-type, I-type ALU, Load, LUI, AUIPC, JAL, JALR
- `0`：Store, Branch

#### `wb_sel`
- `01`（DRAM dout）：Load
- `10`（PC+4）：JAL, JALR
- `00`（ALU）：其他

#### `mem_read_en` / `mem_write_en`
- `mem_read_en = is_load`
- `mem_write_en = is_store`

#### `mem_size` / `mem_unsigned`
- `mem_size = funct3[1:0]`（透传）
- `mem_unsigned = funct3[2]`（透传）

#### `branch_cond`
- `funct3` 直接透传

#### `imm_type`
- I-type ALU, Load, JALR → `IMM_I`
- Store → `IMM_S`
- Branch → `IMM_B`
- LUI, AUIPC → `IMM_U`
- JAL → `IMM_J`

---

## 3. 时序约束

- 纯组合逻辑，无时钟、无寄存器
- 输入 `inst` 来自 IF/ID 寄存器 `id_inst`（寄存器 Clk-to-Q ~0.3ns），下游组合路径时间充裕

---

## 4. 边界条件

- 无时钟、无复位、无 stall/flush
- 非法指令：输出 `ALU_ADD` + 所有使能为 0（不产生副作用）

---

## 5. 依赖文档

- `design_rules/isa_encoding.md` §1-§5（完整译码真值表）
- `project_context.md` §5（并行 AND-OR 优化原则）
