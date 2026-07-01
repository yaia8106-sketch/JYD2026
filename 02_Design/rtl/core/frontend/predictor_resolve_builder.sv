// ============================================================
// Module: predictor_resolve_builder
// Description: Pure combinational construction of predictor resolve events.
// Domain: frontend.
// Update arbitration and architectural state remain in predictor_update_ctrl.
// ============================================================

module predictor_resolve_builder
    import cpu_defs::*;
(
    input  logic                   s0_valid,
    input  logic [31:0]            s0_pc,
    input  logic                   s0_is_branch,
    input  logic                   s0_is_jal,
    input  logic                   s0_is_jalr,
    input  logic                   s0_actual_taken,
    input  logic [31:0]            s0_actual_target,
    input  logic                   s0_update_qualified,
    input  logic [ 1:0]            s0_update_cfi_type,
    input  logic                   s0_abtb_hit,
    input  logic                   s0_abtb_way,
    input  logic [ 7:0]            s0_pht_index,
    input  logic [ 1:0]            s0_pht_counter,

    input  logic                   s1_valid,
    input  logic [31:0]            s1_pc,
    input  logic                   s1_is_branch,
    input  logic                   s1_is_jal,
    input  logic                   s1_is_jalr,
    input  logic                   s1_actual_taken,
    input  logic [31:0]            s1_actual_target,
    input  logic                   s1_update_qualified,
    input  logic [ 1:0]            s1_update_cfi_type,
    input  logic                   s1_abtb_hit,
    input  logic                   s1_abtb_way,
    input  logic [ 7:0]            s1_pht_index,
    input  logic [ 1:0]            s1_pht_counter,

    output predictor_resolve_t     slot0_resolve,
    output predictor_resolve_t     slot1_resolve
);

    always_comb begin
        slot0_resolve = '0;
        slot0_resolve.valid = s0_valid;
        slot0_resolve.pc = s0_pc;
        slot0_resolve.is_branch = s0_is_branch;
        slot0_resolve.is_jal = s0_is_jal;
        slot0_resolve.is_jalr = s0_is_jalr;
        slot0_resolve.actual_taken = s0_actual_taken;
        slot0_resolve.actual_target = s0_actual_target;
        slot0_resolve.update_qualified = s0_update_qualified;
        slot0_resolve.update_cfi_type = s0_update_cfi_type;
        slot0_resolve.abtb_hit = s0_abtb_hit;
        slot0_resolve.abtb_way = s0_abtb_way;
        slot0_resolve.pht_index = s0_pht_index;
        slot0_resolve.pht_counter = s0_pht_counter;

        slot1_resolve = '0;
        slot1_resolve.valid = s1_valid;
        slot1_resolve.pc = s1_pc;
        slot1_resolve.is_branch = s1_is_branch;
        slot1_resolve.is_jal = s1_is_jal;
        slot1_resolve.is_jalr = s1_is_jalr;
        slot1_resolve.actual_taken = s1_actual_taken;
        slot1_resolve.actual_target = s1_actual_target;
        slot1_resolve.update_qualified = s1_update_qualified;
        slot1_resolve.update_cfi_type = s1_update_cfi_type;
        slot1_resolve.abtb_hit = s1_abtb_hit;
        slot1_resolve.abtb_way = s1_abtb_way;
        slot1_resolve.pht_index = s1_pht_index;
        slot1_resolve.pht_counter = s1_pht_counter;
    end

endmodule
