// ============================================================
// Module: frontend_ftq_compat_adapter
// Description: Expose structured F0 state through legacy scalar probe names.
// Domain: frontend observation compatibility.
//
// Production frontend logic consumes the packed records directly. These
// scalar outputs exist for directed tests and performance tooling only.
// ============================================================

module frontend_ftq_compat_adapter
    import cpu_defs::*;
(
    input  frontend_f0_state_t f0_state,
    input  frontend_abtb_meta_t f0_bank0_abtb,
    input  frontend_abtb_meta_t f0_bank1_abtb,

    output logic        f0_valid,
    output logic [ 1:0] f0_epoch,
    output logic [31:0] f0_start_pc,
    output logic [ 1:0] f0_base_mask,
    output logic        f0_steer_taken,
    output logic        f0_steer_source_abtb,
    output logic        f0_steer_bank,
    output logic [ 1:0] f0_steer_cfi_type,
    output logic [31:0] f0_steer_target,
    output logic [31:0] f0_steer_next_pc,

    output logic        f0_bank0_branch_owned,
    output logic [ 7:0] f0_bank0_pht_index,
    output logic [ 1:0] f0_bank0_pht_counter,
    output logic        f0_bank1_branch_owned,
    output logic [ 7:0] f0_bank1_pht_index,
    output logic [ 1:0] f0_bank1_pht_counter,

    output logic        f0_bank0_abtb_hit,
    output logic        f0_bank0_abtb_way,
    output logic [ 1:0] f0_bank0_abtb_cfi_type,
    output logic [31:0] f0_bank0_abtb_target,
    output logic        f0_bank0_abtb_pred_taken,
    output logic [31:0] f0_bank0_abtb_pred_target,
    output logic        f0_bank1_abtb_hit,
    output logic        f0_bank1_abtb_way,
    output logic [ 1:0] f0_bank1_abtb_cfi_type,
    output logic [31:0] f0_bank1_abtb_target,
    output logic        f0_bank1_abtb_pred_taken,
    output logic [31:0] f0_bank1_abtb_pred_target
);

    assign f0_valid = f0_state.valid;
    assign f0_epoch = f0_state.epoch;
    assign f0_start_pc = f0_state.start_pc;
    assign f0_base_mask = f0_state.base_mask;
    assign f0_steer_taken = f0_state.steer.taken;
    assign f0_steer_source_abtb = f0_state.steer.source_abtb;
    assign f0_steer_bank = f0_state.steer.bank;
    assign f0_steer_cfi_type = f0_state.steer.cfi_type;
    assign f0_steer_target = f0_state.steer.target;
    assign f0_steer_next_pc = f0_state.steer.next_pc;

    assign f0_bank0_branch_owned = f0_state.bank0_meta.branch_owned;
    assign f0_bank0_pht_index = f0_state.bank0_meta.pht_index;
    assign f0_bank0_pht_counter = f0_state.bank0_meta.pht_counter;
    assign f0_bank1_branch_owned = f0_state.bank1_meta.branch_owned;
    assign f0_bank1_pht_index = f0_state.bank1_meta.pht_index;
    assign f0_bank1_pht_counter = f0_state.bank1_meta.pht_counter;

    assign f0_bank0_abtb_hit = f0_bank0_abtb.hit;
    assign f0_bank0_abtb_way = f0_bank0_abtb.way;
    assign f0_bank0_abtb_cfi_type = f0_bank0_abtb.cfi_type;
    assign f0_bank0_abtb_target = f0_bank0_abtb.target;
    assign f0_bank0_abtb_pred_taken = f0_bank0_abtb.pred_taken;
    assign f0_bank0_abtb_pred_target = f0_bank0_abtb.pred_target;
    assign f0_bank1_abtb_hit = f0_bank1_abtb.hit;
    assign f0_bank1_abtb_way = f0_bank1_abtb.way;
    assign f0_bank1_abtb_cfi_type = f0_bank1_abtb.cfi_type;
    assign f0_bank1_abtb_target = f0_bank1_abtb.target;
    assign f0_bank1_abtb_pred_taken = f0_bank1_abtb.pred_taken;
    assign f0_bank1_abtb_pred_target = f0_bank1_abtb.pred_target;

endmodule
