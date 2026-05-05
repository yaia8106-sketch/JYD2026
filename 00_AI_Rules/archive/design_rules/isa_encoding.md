# RV32I 控制信号定义与译码规则

> 本文档定义本项目 RV32I 处理器的控制信号编码、立即数生成规则和译码真值表。
> 所有译码器和 ALU 模块的 spec 编写以本文档为准。
>
> **范围**：RV32I 基础指令集，不含 CSR、FENCE、ECALL/EBREAK。

---

## 1. 控制信号一览

### 1.1 译码器输出信号

| 信号名 | 位宽 | 类型 | 含义 |
|--------|------|------|------|
| `alu_op` | 4 | 控制 | ALU 操作类型（见 §2） |
| `alu_src1_sel` | 2 | 控制 | ALU 操作数 1 来源：`00`=rs1, `01`=PC, `10`=0 |
| `alu_src2_sel` | 1 | 控制 | ALU 操作数 2 来源：`0`=rs2, `1`=立即数 |
| `reg_write_en` | 1 | 控制 | 是否写回寄存器堆 |
| `wb_sel` | 2 | 控制 | 写回数据来源：`00`=ALU 结果, `01`=DRAM dout, `10`=PC+4 |
| `mem_read_en` | 1 | 控制 | 是否读 DRAM（Load 指令） |
| `mem_write_en` | 1 | 控制 | 是否写 DRAM（Store 指令） |
| `mem_size` | 2 | 控制 | 访存宽度：`00`=byte, `01`=halfword, `10`=word |
| `mem_unsigned` | 1 | 控制 | Load 时是否零扩展：`0`=符号扩展, `1`=零扩展 |
| `is_branch` | 1 | 控制 | 是否为 B-type 分支指令 |
| `branch_cond` | 3 | 控制 | 分支条件（直接使用 funct3 编码，见 §3） |
| `is_jal` | 1 | 控制 | 是否为 JAL |
| `is_jalr` | 1 | 控制 | 是否为 JALR |
| `imm_type` | 3 | 控制 | 立即数类型（见 §4） |

### 1.2 信号在流水线中的流动

| 信号 | 产生于 | 使用于 | 说明 |
|------|--------|--------|------|
| `alu_op`, `alu_src1_sel`, `alu_src2_sel` | ID | EX | 经 ID/EX_reg 传递 |
| `reg_write_en`, `wb_sel` | ID | WB | 经 ID/EX_reg → EX/MEM_reg → MEM/WB_reg 传递 |
| `mem_read_en`, `mem_write_en`, `mem_size`, `mem_unsigned` | ID | MEM | 经 ID/EX_reg → EX/MEM_reg 传递 |
| `is_branch`, `branch_cond`, `is_jal`, `is_jalr` | ID | EX | 经 ID/EX_reg 传递，EX 级判断后消耗 |
| `imm_type` | ID | ID | 仅在 ID 级使用（控制立即数生成器），不传入流水线 |

---

## 2. ALU 操作编码

编码方式：`alu_op = {funct7[5], funct3}`，使 bit 位直接驱动硬件。

| `alu_op` | 编码 | 运算 | 说明 |
|----------|------|------|------|
| `ALU_ADD` | `4'b0_000` | `src1 + src2` | 加法 |
| `ALU_SUB` | `4'b1_000` | `src1 - src2` | 减法 |
| `ALU_SLL` | `4'b0_001` | `src1 << src2[4:0]` | 逻辑左移 |
| `ALU_SLT` | `4'b0_010` | `$signed(src1) < $signed(src2)` | 有符号比较 |
| `ALU_SLTU` | `4'b0_011` | `src1 < src2` | 无符号比较 |
| `ALU_XOR` | `4'b0_100` | `src1 ^ src2` | 异或 |
| `ALU_SRL` | `4'b0_101` | `src1 >> src2[4:0]` | 逻辑右移 |
| `ALU_SRA` | `4'b1_101` | `$signed(src1) >>> src2[4:0]` | 算术右移 |
| `ALU_OR`  | `4'b0_110` | `src1 \| src2` | 或 |
| `ALU_AND` | `4'b0_111` | `src1 & src2` | 与 |

**bit 位含义**（用于硬件共享，非严格对应）：

| bit | 含义 | 影响 |
|-----|------|------|
| `[3]` | funct7[5] 标志 | SUB 取反 src2；SRA 算术移位 |
| `[2]` | 移位方向 | `0`=左移（位翻转后右移），`1`=右移 |
| `[1]` | 比较标志 | SLT/SLTU 需要减法结果判断大小 |
| `[0]` | 无符号标志 | SLTU 的无符号比较 |

> **注**：译码器可直接将 `{funct7[5], funct3}` 透传为 `alu_op`（R-type / I-type ALU 指令）。非 ALU 指令（Load/Store/Branch/LUI/AUIPC/JAL/JALR）显式赋 `ALU_ADD`。

---

## 3. 分支条件编码

分支条件直接使用 RV32I 的 `funct3` 编码，无需额外转换：

| `branch_cond` | 编码 | 条件 | 含义 |
|----------------|------|------|------|
| `BEQ`  | `3'b000` | `rs1 == rs2` | 相等跳转 |
| `BNE`  | `3'b001` | `rs1 != rs2` | 不等跳转 |
| `BLT`  | `3'b100` | `$signed(rs1) < $signed(rs2)` | 有符号小于 |
| `BGE`  | `3'b101` | `$signed(rs1) >= $signed(rs2)` | 有符号大于等于 |
| `BLTU` | `3'b110` | `rs1 < rs2` | 无符号小于 |
| `BGEU` | `3'b111` | `rs1 >= rs2` | 无符号大于等于 |

> **注**：`3'b010` 和 `3'b011` 在 RV32I 分支指令中未定义。

---

## 4. 立即数类型与生成规则

| `imm_type` | 编码 | 格式 | 生成方式 |
|------------|------|------|----------|
| `IMM_I` | `3'b000` | I-type | `{{20{inst[31]}}, inst[31:20]}` |
| `IMM_S` | `3'b001` | S-type | `{{20{inst[31]}}, inst[31:25], inst[11:7]}` |
| `IMM_B` | `3'b010` | B-type | `{{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0}` |
| `IMM_U` | `3'b011` | U-type | `{inst[31:12], 12'b0}` |
| `IMM_J` | `3'b100` | J-type | `{{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0}` |

---

## 5. 译码真值表

### 5.1 按指令类型

#### R-type（寄存器-寄存器运算）

适用指令：ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND

| 信号 | 值 |
|------|----|
| `alu_op` | 由 funct3 + funct7 决定（见 §5.2） |
| `alu_src1_sel` | `00`（rs1） |
| `alu_src2_sel` | `0`（rs2） |
| `reg_write_en` | `1` |
| `wb_sel` | `00`（ALU 结果） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | don't care |

#### I-type ALU（立即数运算）

适用指令：ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI

| 信号 | 值 |
|------|----|
| `alu_op` | 由 funct3（+ funct7 对移位）决定 |
| `alu_src1_sel` | `00`（rs1） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `00`（ALU 结果） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_I` |

#### Load（I-type 访存）

适用指令：LB, LH, LW, LBU, LHU

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（计算访存地址 rs1 + imm） |
| `alu_src1_sel` | `00`（rs1） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `01`（DRAM dout） |
| `mem_read_en` | `1` |
| `mem_write_en` | `0` |
| `mem_size` | funct3[1:0]（`00`=B, `01`=H, `10`=W） |
| `mem_unsigned` | funct3[2]（`0`=符号扩展, `1`=零扩展） |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_I` |

#### Store（S-type）

适用指令：SB, SH, SW

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（计算访存地址 rs1 + imm） |
| `alu_src1_sel` | `00`（rs1） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `0` |
| `wb_sel` | don't care |
| `mem_read_en` | `0` |
| `mem_write_en` | `1` |
| `mem_size` | funct3[1:0]（`00`=B, `01`=H, `10`=W） |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_S` |

#### Branch（B-type）

适用指令：BEQ, BNE, BLT, BGE, BLTU, BGEU

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（计算跳转目标 PC + imm） |
| `alu_src1_sel` | `01`（PC） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `0` |
| `wb_sel` | don't care |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `1` |
| `branch_cond` | funct3（直接使用） |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_B` |

#### LUI（U-type）

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（0 + imm = imm） |
| `alu_src1_sel` | `10`（零） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `00`（ALU 结果） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_U` |

#### AUIPC（U-type）

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（PC + imm） |
| `alu_src1_sel` | `01`（PC） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `00`（ALU 结果） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_U` |

#### JAL（J-type）

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（PC + imm = 跳转目标） |
| `alu_src1_sel` | `01`（PC） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `10`（PC+4，link 地址） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `1` |
| `is_jalr` | `0` |
| `imm_type` | `IMM_J` |

#### JALR（I-type）

| 信号 | 值 |
|------|----|
| `alu_op` | `ALU_ADD`（rs1 + imm = 跳转目标） |
| `alu_src1_sel` | `00`（rs1） |
| `alu_src2_sel` | `1`（立即数） |
| `reg_write_en` | `1` |
| `wb_sel` | `10`（PC+4，link 地址） |
| `mem_read_en` | `0` |
| `mem_write_en` | `0` |
| `is_branch` | `0` |
| `is_jal` | `0` |
| `is_jalr` | `1` |
| `imm_type` | `IMM_I` |

### 5.2 ALU 操作编码与 funct3/funct7 的映射

| 指令 | opcode | funct3 | funct7 | `alu_op` |
|------|--------|--------|--------|----------|
| ADD  | 0110011 | 000 | 0000000 | `ALU_ADD` |
| SUB  | 0110011 | 000 | 0100000 | `ALU_SUB` |
| SLL  | 0110011 | 001 | 0000000 | `ALU_SLL` |
| SLT  | 0110011 | 010 | 0000000 | `ALU_SLT` |
| SLTU | 0110011 | 011 | 0000000 | `ALU_SLTU` |
| XOR  | 0110011 | 100 | 0000000 | `ALU_XOR` |
| SRL  | 0110011 | 101 | 0000000 | `ALU_SRL` |
| SRA  | 0110011 | 101 | 0100000 | `ALU_SRA` |
| OR   | 0110011 | 110 | 0000000 | `ALU_OR` |
| AND  | 0110011 | 111 | 0000000 | `ALU_AND` |
| ADDI | 0010011 | 000 | — | `ALU_ADD` |
| SLTI | 0010011 | 010 | — | `ALU_SLT` |
| SLTIU| 0010011 | 011 | — | `ALU_SLTU` |
| XORI | 0010011 | 100 | — | `ALU_XOR` |
| ORI  | 0010011 | 110 | — | `ALU_OR` |
| ANDI | 0010011 | 111 | — | `ALU_AND` |
| SLLI | 0010011 | 001 | 0000000 | `ALU_SLL` |
| SRLI | 0010011 | 101 | 0000000 | `ALU_SRL` |
| SRAI | 0010011 | 101 | 0100000 | `ALU_SRA` |

> 分支判断单元和 flush 逻辑的具体实现见架构文档（如 `dual_issue/architecture.md`）。
