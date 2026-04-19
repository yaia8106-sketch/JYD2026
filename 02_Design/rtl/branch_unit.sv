// ============================================================
// Module: branch_unit
// Description: Branch/jump decision + misprediction detection (EX stage)
//   With branch prediction: compares predicted vs actual outcome.
//   Flush only on misprediction (not on every taken branch).
// Spec: 02_Design/spec/branch_unit_spec.md
// ============================================================

module branch_unit (
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] alu_result,      // branch/jump target from ALU
    input  logic [31:0] ex_pc,           // PC of the instruction in EX
    input  logic        is_branch,
    input  logic [ 2:0] branch_cond,
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

    // ---- Shared subtractor (reuse for all comparisons) ----
    wire [31:0] diff = rs1_data - rs2_data;
    wire        neq  = |diff;

    // ---- Unified comparator ----
    // Same sign → check diff sign bit
    // Different sign → signed: rs1[31], unsigned: rs2[31]
    wire is_unsigned = branch_cond[1];   // BLT/BGE: [1]=0, BLTU/BGEU: [1]=1
    wire cmp = (rs1_data[31] == rs2_data[31]) ? diff[31]
             : is_unsigned ? rs2_data[31] : rs1_data[31];

    // ---- Branch condition evaluation (AND-OR) ----
    // branch_cond[2:0] = funct3 from instruction
    //   000 = BEQ    001 = BNE
    //   100 = BLT    101 = BGE
    //   110 = BLTU   111 = BGEU
    wire sel_eq  = (branch_cond == 3'b000);
    wire sel_ne  = (branch_cond == 3'b001);
    wire sel_lt  = (branch_cond == 3'b100) | (branch_cond == 3'b110);  // BLT / BLTU
    wire sel_ge  = (branch_cond == 3'b101) | (branch_cond == 3'b111);  // BGE / BGEU

    wire branch_taken = (sel_eq & ~neq)
                      | (sel_ne &  neq)
                      | (sel_lt &  cmp)
                      | (sel_ge & ~cmp);

    // ---- Actual outcome ----
    assign actual_taken  = is_jal | is_jalr | (is_branch & branch_taken);
    assign actual_target = is_jalr ? (alu_result & ~32'd1) : alu_result;

    // ---- Misprediction detection ----
    // Case 1: direction wrong (predicted taken ≠ actual taken)
    // Case 2: target wrong (both taken but different targets)
    wire direction_wrong = (actual_taken != predicted_taken);
    wire target_wrong    = actual_taken & predicted_taken &
                           (actual_target != predicted_target);

    assign branch_flush = ex_valid & (direction_wrong | target_wrong);

    // ---- Flush target (correct next PC) ----
    // Actual taken → redirect to actual target
    // Actual not-taken (but predicted taken) → redirect to ex_pc + 4
    assign branch_target = actual_taken ? actual_target : (ex_pc + 32'd4);

endmodule
