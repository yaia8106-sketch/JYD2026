// ============================================================
// Module: branch_condition
// Description: ISA-neutral conditional-branch comparator.
// Domain: execute.
// ============================================================

module branch_condition
    import cpu_defs::*;
(
    input  logic [31:0] src0_data,
    input  logic [31:0] src1_data,
    input  branch_op_t  branch_op,
    output logic        taken
);

    // Equality is independent of ordering.  Keep BEQ/BNE off the subtract
    // carry chain and make the reduction tree explicit: each first-level
    // group fits one LUT6, followed by one six-input OR.  The keep attributes
    // prevent the groups from being absorbed serially into the predictor
    // update enable logic.
    wire [31:0] mismatch_bits = src0_data ^ src1_data;
    (* keep = "true" *) wire neq_group0 = |mismatch_bits[ 5: 0];
    (* keep = "true" *) wire neq_group1 = |mismatch_bits[11: 6];
    (* keep = "true" *) wire neq_group2 = |mismatch_bits[17:12];
    (* keep = "true" *) wire neq_group3 = |mismatch_bits[23:18];
    (* keep = "true" *) wire neq_group4 = |mismatch_bits[29:24];
    (* keep = "true" *) wire neq_group5 = |mismatch_bits[31:30];
    wire neq = neq_group0 | neq_group1 | neq_group2
             | neq_group3 | neq_group4 | neq_group5;

    // The subtract path is needed only for signed/unsigned ordering tests.
    wire [31:0] diff = src0_data - src1_data;
    wire is_unsigned = (branch_op == BR_LTU) | (branch_op == BR_GEU);
    wire cmp = (src0_data[31] == src1_data[31]) ? diff[31] :
               is_unsigned ? src1_data[31] : src0_data[31];

    // Invalid branch funct3 values decode to not-taken because no select is set.
    wire sel_eq = branch_op == BR_EQ;
    wire sel_ne = branch_op == BR_NE;
    wire sel_lt = (branch_op == BR_LT) | (branch_op == BR_LTU);
    wire sel_ge = (branch_op == BR_GE) | (branch_op == BR_GEU);
    wire sel_always = branch_op == BR_ALWAYS;

    assign taken = sel_always
                 | (sel_eq & ~neq)
                 | (sel_ne &  neq)
                 | (sel_lt &  cmp)
                 | (sel_ge & ~cmp);

endmodule
