// ============================================================
// Module: branch_condition
// Description: RV32 branch condition comparator.
// Domain: execute.
// ============================================================

module branch_condition (
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [ 2:0] branch_cond,
    output logic        taken
);

    // Equality is independent of ordering.  Keep it on a balanced XOR/OR
    // reduction instead of sending BEQ/BNE through the subtract carry chain.
    wire [31:0] mismatch_bits = rs1_data ^ rs2_data;
    wire        neq = |mismatch_bits;

    // The subtract path is needed only for signed/unsigned ordering tests.
    wire [31:0] diff = rs1_data - rs2_data;
    wire        is_unsigned = branch_cond[1];
    wire        cmp = (rs1_data[31] == rs2_data[31]) ? diff[31] :
                      is_unsigned ? rs2_data[31] : rs1_data[31];

    // Invalid branch funct3 values decode to not-taken because no select is set.
    wire sel_eq = (branch_cond == 3'b000);
    wire sel_ne = (branch_cond == 3'b001);
    wire sel_lt = (branch_cond == 3'b100) | (branch_cond == 3'b110);
    wire sel_ge = (branch_cond == 3'b101) | (branch_cond == 3'b111);

    assign taken = (sel_eq & ~neq)
                 | (sel_ne &  neq)
                 | (sel_lt &  cmp)
                 | (sel_ge & ~cmp);

endmodule
