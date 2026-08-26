// ============================================================
// 中文说明：记录并检查 ABTB 预测与实际控制流结果之间的一致性。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_abtb_observer。
// 说明：为 ABTB/PHT 行为提供完整的只观测边界。
// 所属部分：前端观测。
//
// 正式预测器信号在这里仅作为接收端输入。这里生成的打包记录和计数器
// 绝不能反馈到取指方向、重定向、ready/valid 或预测器更新。
// ============================================================

module frontend_abtb_observer
    import cpu_defs::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [31:0]             frontend_pc,
    input  logic                    lookup_accept,

    input  logic                    bank0_hit,
    input  logic                    bank0_way,
    input  logic [ 1:0]             bank0_cfi_type,
    input  logic [31:0]             bank0_abtb_target,
    input  logic                    bank0_pred_taken,
    input  logic [31:0]             bank0_final_target,
    input  logic                    bank0_pht_taken,

    input  logic                    bank1_hit,
    input  logic                    bank1_way,
    input  logic [ 1:0]             bank1_cfi_type,
    input  logic [31:0]             bank1_abtb_target,
    input  logic                    bank1_pred_taken,
    input  logic [31:0]             bank1_final_target,
    input  logic                    bank1_pht_taken,

    input  logic                    shadow_pred_taken,
    input  logic                    shadow_pred_bank,
    input  logic [ 1:0]             shadow_pred_cfi_type,
    input  logic [31:0]             shadow_pred_target,
    input  logic [31:0]             shadow_pred_next_pc,

    input  logic                    steer_valid,
    input  logic                    steer_source_abtb,
    input  logic                    steer_branch_owned,
    input  logic                    steer_branch_owned_nt,
    input  logic                    steer_bank,

    input  prediction_meta_t        if_slot0_prediction,
    input  prediction_meta_t        if_slot1_prediction,
    input  prediction_meta_t        id_slot0_prediction,
    input  prediction_meta_t        id_slot1_prediction,
    input  id_ex_prediction_t       ex_slot0_prediction,
    input  id_ex_prediction_t       ex_slot1_prediction,

    input  predictor_resolve_t      slot0_resolve,
    input  predictor_resolve_t      slot1_resolve,
    input  logic                    ex_ready_go,
    input  logic                    mem_allowin,
    input  logic                    mem_branch_flush,
    input  logic                    slot0_cfi_valid,
    input  logic                    slot0_redirect,
    input  logic                    slot1_redirect,
    input  abtb_update_t            abtb_update,
    input  pht_update_t             pht_update,

    output frontend_abtb_counters_t counters
);

    abtb_lookup_bank_t   bank0_lookup;
    abtb_lookup_bank_t   bank1_lookup;
    abtb_shadow_result_t shadow_result;
    stage1_steer_event_t steer_event;

    frontend_abtb_monitor_adapter u_event_adapter (
        .bank0_hit               (bank0_hit),
        .bank0_way               (bank0_way),
        .bank0_cfi_type          (bank0_cfi_type),
        .bank0_abtb_pred_target  (bank0_abtb_target),
        .bank0_pred_taken        (bank0_pred_taken),
        .bank0_final_pred_target (bank0_final_target),
        .bank0_pht_taken         (bank0_pht_taken),
        .bank1_hit               (bank1_hit),
        .bank1_way               (bank1_way),
        .bank1_cfi_type          (bank1_cfi_type),
        .bank1_abtb_pred_target  (bank1_abtb_target),
        .bank1_pred_taken        (bank1_pred_taken),
        .bank1_final_pred_target (bank1_final_target),
        .bank1_pht_taken         (bank1_pht_taken),
        .shadow_pred_taken       (shadow_pred_taken),
        .shadow_pred_bank        (shadow_pred_bank),
        .shadow_pred_cfi_type    (shadow_pred_cfi_type),
        .shadow_pred_target      (shadow_pred_target),
        .shadow_pred_next_pc     (shadow_pred_next_pc),
        .steer_valid             (steer_valid),
        .steer_source_abtb       (steer_source_abtb),
        .steer_branch_owned      (steer_branch_owned),
        .steer_branch_owned_nt   (steer_branch_owned_nt),
        .steer_bank              (steer_bank),
        .bank0_lookup            (bank0_lookup),
        .bank1_lookup            (bank1_lookup),
        .shadow_result           (shadow_result),
        .steer_event             (steer_event)
    );

    frontend_abtb_monitor u_counters (
        .clk                 (clk),
        .rst_n               (rst_n),
        .frontend_pc         (frontend_pc),
        .lookup_accept       (lookup_accept),
        .bank0_lookup        (bank0_lookup),
        .bank1_lookup        (bank1_lookup),
        .shadow_result       (shadow_result),
        .steer_event         (steer_event),
        .if_slot0_prediction (if_slot0_prediction),
        .if_slot1_prediction (if_slot1_prediction),
        .id_slot0_prediction (id_slot0_prediction),
        .id_slot1_prediction (id_slot1_prediction),
        .ex_slot0_prediction (ex_slot0_prediction),
        .ex_slot1_prediction (ex_slot1_prediction),
        .slot0_resolve       (slot0_resolve),
        .slot1_resolve       (slot1_resolve),
        .ex_ready_go         (ex_ready_go),
        .mem_allowin         (mem_allowin),
        .mem_branch_flush    (mem_branch_flush),
        .slot0_cfi_valid     (slot0_cfi_valid),
        .slot0_redirect      (slot0_redirect),
        .slot1_redirect      (slot1_redirect),
        .abtb_update         (abtb_update),
        .pht_update          (pht_update),
        .counters            (counters)
    );

endmodule
