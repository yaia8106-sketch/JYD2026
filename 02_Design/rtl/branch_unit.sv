// ============================================================
// Module: branch_unit
// Description: Branch/jump decision unit (EX stage, pure combinational)
// Spec: 02_Design/spec/branch_unit_spec.md
// Phase 2+: Prediction-aware flush with correct redirect target
// ============================================================

module branch_unit (
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] alu_result,      // branch/jump target from ALU
    input  logic [31:0] ex_pc,           // instruction PC (for fallthrough calc)
    input  logic        is_branch,
    input  logic [ 2:0] branch_cond,
    input  logic        is_jal,
    input  logic        is_jalr,
    input  logic        ex_valid,

    // Prediction inputs (from IF stage, pipelined through ID/EX)
    input  logic        pred_taken,
    input  logic [31:0] pred_target,     // unused in simplified flush logic

    output logic        branch_flush,
    output logic [31:0] branch_target,
    output logic        actual_taken_out  // true branch outcome for predictor training
);

    // ---- Shared subtractor (reuse for all comparisons) ----
    wire [31:0] diff = rs1_data - rs2_data;
    wire        neq  = |diff;

    // ---- Unified comparator ----
    wire is_unsigned = branch_cond[1];
    wire cmp = (rs1_data[31] == rs2_data[31]) ? diff[31]
             : is_unsigned ? rs2_data[31] : rs1_data[31];

    // ---- Branch condition evaluation (AND-OR) ----
    wire sel_eq  = (branch_cond == 3'b000);
    wire sel_ne  = (branch_cond == 3'b001);
    wire sel_lt  = (branch_cond == 3'b100) | (branch_cond == 3'b110);
    wire sel_ge  = (branch_cond == 3'b101) | (branch_cond == 3'b111);

    wire branch_taken = (sel_eq & ~neq)
                      | (sel_ne &  neq)
                      | (sel_lt &  cmp)
                      | (sel_ge & ~cmp);

    // ---- Actual outcome ----
    // JAL MUST be included: BTB can predict JAL, and EX must confirm it
    wire actual_taken = is_jal | is_jalr | (is_branch & branch_taken);

    // ---- Actual target (from ALU) ----
    wire [31:0] actual_target = is_jalr ? (alu_result & ~32'd1) : alu_result;

    // ---- Flush decision (prediction-aware) ----
    // For unpredicted JAL: ID stage already handles redirection (1-cycle penalty),
    // so EX must NOT double-flush. Predicted JAL that matches is a 0-cycle hit.
    wire missed    = actual_taken & ~pred_taken & ~is_jal;  // JAL w/o prediction → ID handles
    wire wrong_dir = ~actual_taken &  pred_taken;           // predicted jump, actually not taken

    assign branch_flush = ex_valid & (missed | wrong_dir);

    // ---- Redirect target ----
    // missed:    redirect to actual branch/jump target
    // wrong_dir: redirect to sequential PC (ex_pc + 4, fallthrough)
    assign branch_target = wrong_dir ? (ex_pc + 32'd4) : actual_target;

    // ---- Actual outcome for predictor training ----
    assign actual_taken_out = actual_taken;

endmodule
