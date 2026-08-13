// ============================================================
// Module: cpu_prediction_compat_adapter
// Description: Flatten structured prediction records for legacy probes.
// Domain: observation compatibility.
//
// Predictor control and training consume packed records. This adapter keeps
// historical scalar names out of cpu_top's production wiring.
// ============================================================

module cpu_prediction_compat_adapter
    import cpu_defs::*;
(
    input  prediction_meta_t  if_slot0,
    input  prediction_meta_t  if_slot1,
    input  prediction_meta_t  id_slot0,
    input  prediction_meta_t  id_slot1,
    input  id_ex_prediction_t ex_slot0,
    input  id_ex_prediction_t ex_slot1,

    output logic        if_slot0_abtb_hit,
    output logic        if_slot0_abtb_way,
    output logic [ 1:0] if_slot0_abtb_cfi_type,
    output logic [31:0] if_slot0_abtb_target,
    output logic        if_slot0_abtb_pred_taken,
    output logic [31:0] if_slot0_abtb_pred_target,
    output logic        if_slot0_source_abtb,
    output logic        if_slot0_branch_owned,
    output logic        if_slot1_abtb_hit,
    output logic        if_slot1_abtb_way,
    output logic [ 1:0] if_slot1_abtb_cfi_type,
    output logic [31:0] if_slot1_abtb_target,
    output logic        if_slot1_abtb_pred_taken,
    output logic [31:0] if_slot1_abtb_pred_target,
    output logic        if_slot1_source_abtb,
    output logic        if_slot1_branch_owned,

    output logic        id_slot0_abtb_hit,
    output logic        id_slot0_abtb_way,
    output logic        ex_slot0_abtb_hit,
    output logic        ex_slot0_abtb_way,
    output logic [ 1:0] ex_slot0_abtb_cfi_type,
    output logic [31:0] ex_slot0_abtb_target,
    output logic        ex_slot0_abtb_pred_taken,
    output logic [31:0] ex_slot0_abtb_pred_target,

    output logic [ 7:0] if_slot0_pht_index,
    output logic [ 1:0] if_slot0_pht_counter,
    output logic [ 7:0] if_slot1_pht_index,
    output logic [ 1:0] if_slot1_pht_counter,
    output logic [ 7:0] id_slot0_pht_index,
    output logic [ 1:0] id_slot0_pht_counter,
    output logic [ 7:0] id_slot1_pht_index,
    output logic [ 1:0] id_slot1_pht_counter,
    output logic [ 7:0] ex_slot0_pht_index,
    output logic [ 1:0] ex_slot0_pht_counter,
    output logic [ 7:0] ex_slot1_pht_index,
    output logic [ 1:0] ex_slot1_pht_counter
);

    assign if_slot0_abtb_hit = if_slot0.abtb_hit;
    assign if_slot0_abtb_way = if_slot0.abtb_way;
    assign if_slot0_abtb_cfi_type = if_slot0.abtb_cfi_type;
    assign if_slot0_abtb_target = if_slot0.abtb_target;
    assign if_slot0_abtb_pred_taken = if_slot0.abtb_pred_taken;
    assign if_slot0_abtb_pred_target = if_slot0.abtb_pred_target;
    assign if_slot0_source_abtb = if_slot0.source_abtb;
    assign if_slot0_branch_owned = if_slot0.stage1_branch_owned;

    assign if_slot1_abtb_hit = if_slot1.abtb_hit;
    assign if_slot1_abtb_way = if_slot1.abtb_way;
    assign if_slot1_abtb_cfi_type = if_slot1.abtb_cfi_type;
    assign if_slot1_abtb_target = if_slot1.abtb_target;
    assign if_slot1_abtb_pred_taken = if_slot1.abtb_pred_taken;
    assign if_slot1_abtb_pred_target = if_slot1.abtb_pred_target;
    assign if_slot1_source_abtb = if_slot1.source_abtb;
    assign if_slot1_branch_owned = if_slot1.stage1_branch_owned;

    assign id_slot0_abtb_hit = id_slot0.abtb_hit;
    assign id_slot0_abtb_way = id_slot0.abtb_way;
    assign ex_slot0_abtb_hit = ex_slot0.prediction.abtb_hit;
    assign ex_slot0_abtb_way = ex_slot0.prediction.abtb_way;
    assign ex_slot0_abtb_cfi_type = ex_slot0.prediction.abtb_cfi_type;
    assign ex_slot0_abtb_target = ex_slot0.prediction.abtb_target;
    assign ex_slot0_abtb_pred_taken = ex_slot0.prediction.abtb_pred_taken;
    assign ex_slot0_abtb_pred_target = ex_slot0.prediction.abtb_pred_target;

    assign if_slot0_pht_index = if_slot0.stage1_pht_index;
    assign if_slot0_pht_counter = if_slot0.stage1_pht_counter;
    assign if_slot1_pht_index = if_slot1.stage1_pht_index;
    assign if_slot1_pht_counter = if_slot1.stage1_pht_counter;
    assign id_slot0_pht_index = id_slot0.stage1_pht_index;
    assign id_slot0_pht_counter = id_slot0.stage1_pht_counter;
    assign id_slot1_pht_index = id_slot1.stage1_pht_index;
    assign id_slot1_pht_counter = id_slot1.stage1_pht_counter;
    assign ex_slot0_pht_index = ex_slot0.prediction.stage1_pht_index;
    assign ex_slot0_pht_counter = ex_slot0.prediction.stage1_pht_counter;
    assign ex_slot1_pht_index = ex_slot1.prediction.stage1_pht_index;
    assign ex_slot1_pht_counter = ex_slot1.prediction.stage1_pht_counter;

endmodule
