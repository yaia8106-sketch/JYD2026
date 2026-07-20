// ============================================================
// Module: predictor_resolve_builder
// Description: Pure combinational builder that packages EX resolve/update
//              information into predictor structures; 将 EX 更新信息封装成结构体。
// Domain: frontend.
// Update arbitration and architectural state remain in predictor_update_ctrl.
// ============================================================

module predictor_resolve_builder
    import cpu_defs::*;
(
    input  logic                   s0_valid,
    input  logic [31:0]            s0_pc,
    input  logic                   s0_is_conditional_control,
    input  logic                   s0_is_direct_control,
    input  logic                   s0_is_indirect_control,
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
    input  logic                   s1_is_conditional_control,
    input  logic                   s1_is_direct_control,
    input  logic                   s1_is_indirect_control,
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

    // Package resolved EX facts with the prediction-time metadata needed by
    // the single predictor update port.
    always_comb begin
        slot0_resolve = '0;
        slot0_resolve.valid = s0_valid;
        slot0_resolve.pc = s0_pc;
        slot0_resolve.is_conditional_branch =
            s0_is_conditional_control;
        slot0_resolve.is_direct_jump = s0_is_direct_control;
        slot0_resolve.is_indirect_jump = s0_is_indirect_control;
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
        slot1_resolve.is_conditional_branch =
            s1_is_conditional_control;
        slot1_resolve.is_direct_jump = s1_is_direct_control;
        slot1_resolve.is_indirect_jump = s1_is_indirect_control;
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
