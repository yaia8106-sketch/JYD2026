// ============================================================
// Module: alu_src_mux
// Description: ALU operand selection; ID 阶段选择两个操作数，随后由 ID/EX 寄存。
// Domain: decode and issue.
// ============================================================

module alu_src_mux
    import cpu_defs::*;
(
    // Source data
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] pc,
    input  logic [31:0] imm,

    // Select signals (from decoder, via ID/EX_reg)
    input  operand_a_sel_t alu_src1_sel,
    input  operand_b_sel_t alu_src2_sel,

    // ALU operands
    output logic [31:0] alu_src1,
    output logic [31:0] alu_src2
);

    // ---- src1: 3-way AND-OR MUX ----
    wire sel1_rs1 = (alu_src1_sel == OPERAND_A_SRC0);
    wire sel1_pc  = (alu_src1_sel == OPERAND_A_PC);
    // sel1_zero implied by default (neither rs1 nor pc)

    assign alu_src1 = ({32{sel1_rs1}} & rs1_data)
                    | ({32{sel1_pc}}  & pc);
                    // zero: all terms are 0 -> output = 0

    // ---- src2: 2-way MUX ----
    // Memory addressing and immediate ALU operations use the decoded immediate.
    assign alu_src2 = (alu_src2_sel == OPERAND_B_IMM) ? imm : rs2_data;

endmodule
