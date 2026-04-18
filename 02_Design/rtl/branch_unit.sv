// ============================================================
// Module: branch_unit
// Description: Branch/jump decision unit (EX stage, pure combinational)
// Spec: 02_Design/spec/branch_unit_spec.md
// ============================================================

module branch_unit (
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] alu_result,      // branch target from ALU
    input  logic        is_branch,
    input  logic [ 2:0] branch_cond,
    input  logic        is_jal,
    input  logic        is_jalr,
    input  logic        ex_valid,
    output logic        branch_flush,
    output logic [31:0] branch_target
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

    // ---- Flush decision ----
    // Default prediction: not-taken → actual_taken means misprediction
    // JAL is now handled in EX stage (ID-stage resolution disabled)
    wire actual_taken = is_jal | is_jalr | (is_branch & branch_taken);
    assign branch_flush = ex_valid & actual_taken;

    // ---- Target address ----
    // JALR: (rs1 + imm) & ~1 (clear LSB), computed by ALU
    // JAL / Branch: PC + imm, computed by ALU
    assign branch_target = is_jalr ? (alu_result & ~32'd1) : alu_result;

endmodule
