// ============================================================
// Module: alu_src_mux
// Description: ALU operand selection (ID stage, pure combinational)
//              输出经 ID/EX_reg 打拍后送入 EX 级 ALU
// ============================================================

module alu_src_mux (
    // Source data
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] pc,
    input  logic [31:0] imm,

    // Select signals (from decoder, via ID/EX_reg)
    input  logic [ 1:0] alu_src1_sel,   // 00=rs1, 01=PC, 10=zero
    input  logic        alu_src2_sel,   // 0=rs2, 1=imm

    // ALU operands
    output logic [31:0] alu_src1,
    output logic [31:0] alu_src2
);

    // ---- src1: 3-way AND-OR MUX ----
    wire sel1_rs1 = (alu_src1_sel == 2'b00);
    wire sel1_pc  = (alu_src1_sel == 2'b01);
    // sel1_zero implied by default (neither rs1 nor pc)

    assign alu_src1 = ({32{sel1_rs1}} & rs1_data)
                    | ({32{sel1_pc}}  & pc);
                    // zero: all terms are 0 → output = 0

    // ---- src2: 2-way MUX ----
    assign alu_src2 = alu_src2_sel ? imm : rs2_data;

endmodule
