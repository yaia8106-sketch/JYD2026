// ============================================================
// Module: branch_unit
// Description: Branch/jump decision + misprediction detection (EX stage)
// Domain: execute.
//   With branch prediction: compares predicted vs actual outcome.
//   Flush only on misprediction (not on every taken branch).
//   Redirect target is calculated in EX, then registered before frontend replay.
// Spec: 02_Design/spec/branch_unit_spec.md
// ============================================================

module branch_unit
    import cpu_defs::*;
(
    input  logic [31:0] target_pc,
    input  logic [31:0] fallthrough_pc,
    input  logic [31:0] src0_data,
    input  logic [31:0] src1_data,
    input  control_flow_t control_flow,
    input  branch_op_t    branch_op,
    input  logic        ex_valid,

    // Prediction from pipeline (IF -> ID -> EX)
    input  logic        predicted_taken,
    input  logic [31:0] predicted_target,

    // Flush outputs
    output logic        branch_flush,
    output logic [31:0] branch_target,    // redirect target (correct PC)

    // Actual outcome (for predictor update)
    output logic        actual_taken,
    output logic [31:0] actual_target     // actual destination address
);

    wire branch_taken;

    // Conditional branches use the comparator; jumps are unconditionally taken.
    branch_condition u_branch_condition (
        .src0_data (src0_data),
        .src1_data (src1_data),
        .branch_op (branch_op),
        .taken     (branch_taken)
    );

    // ---- Actual outcome ----
    wire is_conditional = control_flow == CF_CONDITIONAL;
    wire is_unconditional = (control_flow == CF_DIRECT)
                          | (control_flow == CF_INDIRECT);
    assign actual_taken = is_unconditional | (is_conditional & branch_taken);
    assign actual_target = target_pc;

    // ---- Misprediction detection ----
    // Case 1: direction wrong
    // Case 2: both taken, but target wrong
    // Timing: keep the EX compare result as a late MUX select instead of
    // feeding both XOR and target-wrong OR trees on the redirect path.
    wire target_mismatch = (target_pc != predicted_target);
    wire direction_to_target = actual_taken & ~predicted_taken;
    wire direction_to_fallthrough = ~actual_taken & predicted_taken;
    wire target_mismatch_flush = actual_taken & predicted_taken & target_mismatch;

    // Keep branch redirects out of the same-cycle IROM address path.  All
    // branch misses replay from the registered EX/MEM redirect one cycle later.
    assign branch_flush = ex_valid & (direction_to_target
                                    | direction_to_fallthrough
                                    | target_mismatch_flush);

    // ---- Flush target (correct next PC) ----
    // Actual taken -> redirect to actual target
    // Actual not-taken (but predicted taken) -> redirect to ex_pc + 4
    assign branch_target = actual_taken ? actual_target : fallthrough_pc;

endmodule
