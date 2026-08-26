// ============================================================
// 中文说明：在译码阶段选择 ALU 的两个操作数来源，包括寄存器、PC、立即数和零。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：在 ID 阶段选择两个 ALU 操作数，随后由 ID/EX 寄存。
// ============================================================

module alu_src_mux
    import cpu_defs::*;
(
    // 操作数数据来源
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] pc,
    input  logic [31:0] imm,

    // 选择信号（来自译码器，并由 ID/EX 传递）
    input  operand_a_sel_t alu_src1_sel,
    input  operand_b_sel_t alu_src2_sel,

    // ALU 操作数
    output logic [31:0] alu_src1,
    output logic [31:0] alu_src2
);

    // ---- src1：三路与或选择器 ----
    wire sel1_rs1 = (alu_src1_sel == OPERAND_A_SRC0);
    wire sel1_pc  = (alu_src1_sel == OPERAND_A_PC);
    // 默认情况下既不选择 rs1 也不选择 PC，因此 sel1_zero 隐含生效。

    assign alu_src1 = ({32{sel1_rs1}} & rs1_data)
                    | ({32{sel1_pc}}  & pc);
                    // 选择 zero 时所有项均为 0，输出为 0。

    // ---- src2：两路选择器 ----
    // 访存地址和立即数 ALU 操作使用译码得到的立即数。
    assign alu_src2 = (alu_src2_sel == OPERAND_B_IMM) ? imm : rs2_data;

endmodule
