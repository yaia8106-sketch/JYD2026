// ============================================================
// Module: branch_unit
// Description: Branch/jump decision + misprediction detection (EX stage)
//   With branch prediction: compares predicted vs actual outcome.
//   Flush only on misprediction (not on every taken branch).
//   Redirect target is precomputed in ID and carried through ID/EX so the
//   EX redirect path does not depend on a 32-bit target adder.
//   Branch condition is also precomputed in ID and carried as a 1-bit result;
//   EX redirect can then use a short registered select instead of a 32-bit
//   compare on the IROM address path.
// Spec: 02_Design/spec/branch_unit_spec.md
// ============================================================

module branch_unit (
    input  logic [31:0] target_pc,       // precomputed taken target
    input  logic [31:0] fallthrough_pc,  // precomputed PC + 4
    input  logic        is_branch,
    input  logic        branch_taken_pre,
    input  logic        is_jal,
    input  logic        is_jalr,
    input  logic        ex_valid,

    // Prediction from pipeline (IF → ID → EX)
    input  logic        predicted_taken,
    input  logic [31:0] predicted_target,

    // Flush outputs
    output logic        branch_flush,
    output logic [31:0] branch_target,    // redirect target (correct PC)

    // Actual outcome (for predictor update)
    output logic        actual_taken,
    output logic [31:0] actual_target     // actual destination address
);

    // ---- Actual outcome ----
    assign actual_taken  = is_jal | is_jalr | (is_branch & branch_taken_pre);
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
    // Actual taken → redirect to actual target
    // Actual not-taken (but predicted taken) → redirect to ex_pc + 4
    assign branch_target = actual_taken ? actual_target : fallthrough_pc;

endmodule
