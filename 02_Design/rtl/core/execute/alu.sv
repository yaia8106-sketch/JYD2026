// ============================================================
// Module: alu
// Description: Architectural integer result plus independent LSU address add.
// Domain: execute.
// Spec: 02_Design/spec/alu_spec.md
// Encoding: semantic values are defined by cpu_defs::alu_op_t.
// ============================================================

module alu
    import cpu_defs::*;
(
    input  logic [ 3:0] alu_op,
    input  logic [31:0] alu_src1,
    input  logic [31:0] alu_src2,
    input  logic [31:0] alu_addr_src1,
    input  logic [31:0] alu_addr_src2,
    output logic [31:0] alu_result,
    output logic [31:0] alu_sum,
    output logic [31:0] alu_addr
);

    alu_result_datapath u_result_datapath (
        .alu_op     (alu_op),
        .alu_src1   (alu_src1),
        .alu_src2   (alu_src2),
        .shift_amount(alu_src2[4:0]),
        .alu_result (alu_result),
        .alu_sum    (alu_sum)
    );

    // LSU address calculation is deliberately not part of the duplicated
    // forwarding datapath.  Its operands retain WB repair semantics.
    assign alu_addr = alu_addr_src1 + alu_addr_src2;

endmodule
