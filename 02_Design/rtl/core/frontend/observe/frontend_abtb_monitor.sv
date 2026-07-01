// ============================================================
// Module: frontend_abtb_monitor
// Description: Simulation/measurement-only ABTB and PHT observability.
// Domain: frontend observation.
// These counters and sinks must never feed production control or datapaths.
// ============================================================

module frontend_abtb_monitor
    import cpu_defs::*;
(
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [31:0]             frontend_pc,
    input  logic                    lookup_accept,
    input  abtb_lookup_bank_t       bank0_lookup,
    input  abtb_lookup_bank_t       bank1_lookup,
    input  abtb_shadow_result_t     shadow_result,
    input  stage1_steer_event_t     steer_event,

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

    wire slot0_direct_resolve =
        slot0_resolve.valid
        && ex_slot0_prediction.prediction.source_abtb
        && ex_ready_go
        && mem_allowin
        && !mem_branch_flush;
    wire slot1_direct_resolve =
        slot1_resolve.valid
        && ex_slot1_prediction.prediction.source_abtb
        && ex_ready_go
        && mem_allowin
        && !mem_branch_flush
        && !slot0_cfi_valid;

    wire slot0_direct_target_miss =
        slot0_direct_resolve
        && slot0_resolve.actual_taken
        && ex_slot0_prediction.prediction.taken
        && (slot0_resolve.actual_target
            != ex_slot0_prediction.prediction.target);
    wire slot1_direct_target_miss =
        slot1_direct_resolve
        && slot1_resolve.actual_taken
        && ex_slot1_prediction.prediction.taken
        && (slot1_resolve.actual_target
            != ex_slot1_prediction.prediction.target);

    wire bank0_branch_lookup_event =
        lookup_accept
        && bank0_lookup.hit
        && (bank0_lookup.cfi_type == ABTB_TYPE_BRANCH);
    wire bank1_branch_lookup_event =
        lookup_accept
        && bank1_lookup.hit
        && (bank1_lookup.cfi_type == ABTB_TYPE_BRANCH);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            counters <= '0;
        end else begin
            if (lookup_accept)
                counters.lookup_block <= counters.lookup_block + 32'd1;
            if (lookup_accept && bank0_lookup.hit)
                counters.bank0_hit <= counters.bank0_hit + 32'd1;
            if (lookup_accept && bank1_lookup.hit)
                counters.bank1_hit <= counters.bank1_hit + 32'd1;
            if (abtb_update.valid)
                counters.ex_update <= counters.ex_update + 32'd1;
            if (abtb_update.valid && !abtb_update.hit)
                counters.allocation <= counters.allocation + 32'd1;
            if (abtb_update.valid && abtb_update.hit)
                counters.hit_update <= counters.hit_update + 32'd1;
            if (steer_event.valid)
                counters.direct_lookup <= counters.direct_lookup + 32'd1;
            if (steer_event.valid && steer_event.source_abtb) begin
                counters.direct_steer <= counters.direct_steer + 32'd1;
                if (steer_event.bank)
                    counters.direct_bank1 <= counters.direct_bank1 + 32'd1;
                else
                    counters.direct_bank0 <= counters.direct_bank0 + 32'd1;
            end
            if (steer_event.valid
                && (steer_event.source_abtb || steer_event.branch_owned))
                counters.stage1_abtb_owned <=
                    counters.stage1_abtb_owned + 32'd1;
            if (steer_event.valid && steer_event.branch_owned_nt)
                counters.stage1_branch_owned_nt <=
                    counters.stage1_branch_owned_nt + 32'd1;
            if (steer_event.valid
                && !steer_event.source_abtb
                && !steer_event.branch_owned)
                counters.stage1_sequential <=
                    counters.stage1_sequential + 32'd1;
            if (bank0_branch_lookup_event)
                counters.stage1_bank0_branch_lookup <=
                    counters.stage1_bank0_branch_lookup + 32'd1;
            if (bank1_branch_lookup_event)
                counters.stage1_bank1_branch_lookup <=
                    counters.stage1_bank1_branch_lookup + 32'd1;
            if (bank0_branch_lookup_event || bank1_branch_lookup_event)
                counters.stage1_abtb_branch_hit <=
                    counters.stage1_abtb_branch_hit
                    + {31'd0, bank0_branch_lookup_event}
                    + {31'd0, bank1_branch_lookup_event};
            if ((bank0_branch_lookup_event && bank0_lookup.pht_taken)
                || (bank1_branch_lookup_event && bank1_lookup.pht_taken))
                counters.stage1_pht_taken <=
                    counters.stage1_pht_taken
                    + {31'd0, bank0_branch_lookup_event
                               && bank0_lookup.pht_taken}
                    + {31'd0, bank1_branch_lookup_event
                               && bank1_lookup.pht_taken};
            if ((bank0_branch_lookup_event && !bank0_lookup.pht_taken)
                || (bank1_branch_lookup_event && !bank1_lookup.pht_taken))
                counters.stage1_pht_not_taken <=
                    counters.stage1_pht_not_taken
                    + {31'd0, bank0_branch_lookup_event
                               && !bank0_lookup.pht_taken}
                    + {31'd0, bank1_branch_lookup_event
                               && !bank1_lookup.pht_taken};
            if (pht_update.valid) begin
                counters.stage1_confirmed_branch <=
                    counters.stage1_confirmed_branch + 32'd1;
                if (pht_update.counter[1] == pht_update.actual_taken)
                    counters.stage1_pht_correct <=
                        counters.stage1_pht_correct + 32'd1;
                else
                    counters.stage1_pht_wrong <=
                        counters.stage1_pht_wrong + 32'd1;
            end
            if (slot0_direct_resolve) begin
                if (slot0_redirect)
                    counters.direct_redirect <=
                        counters.direct_redirect + 32'd1;
                else
                    counters.direct_correct <=
                        counters.direct_correct + 32'd1;
            end else if (slot1_direct_resolve) begin
                if (slot1_redirect)
                    counters.direct_redirect <=
                        counters.direct_redirect + 32'd1;
                else
                    counters.direct_correct <=
                        counters.direct_correct + 32'd1;
            end
            if (slot0_direct_target_miss || slot1_direct_target_miss)
                counters.direct_target_miss <=
                    counters.direct_target_miss + 32'd1;
        end
    end

`ifdef ABTB_MEASUREMENT
    localparam int ABTB_MEASUREMENT_SINK_W = 920;

    (* keep = "true" *)
    wire [ABTB_MEASUREMENT_SINK_W-1:0] measurement_sink_d = {
        frontend_pc,
        lookup_accept,
        bank0_lookup.hit,
        bank0_lookup.way,
        bank0_lookup.cfi_type,
        bank0_lookup.target,
        bank0_lookup.pred_taken,
        bank0_lookup.pred_target,
        bank1_lookup.hit,
        bank1_lookup.way,
        bank1_lookup.cfi_type,
        bank1_lookup.target,
        bank1_lookup.pred_taken,
        bank1_lookup.pred_target,
        shadow_result.pred_taken,
        shadow_result.pred_bank,
        shadow_result.pred_cfi_type,
        shadow_result.pred_target,
        shadow_result.pred_next_pc,
        if_slot0_prediction.abtb_hit,
        if_slot0_prediction.abtb_way,
        if_slot0_prediction.abtb_cfi_type,
        if_slot0_prediction.abtb_target,
        if_slot0_prediction.abtb_pred_taken,
        if_slot0_prediction.abtb_pred_target,
        if_slot1_prediction.abtb_hit,
        if_slot1_prediction.abtb_way,
        if_slot1_prediction.abtb_cfi_type,
        if_slot1_prediction.abtb_target,
        if_slot1_prediction.abtb_pred_taken,
        if_slot1_prediction.abtb_pred_target,
        id_slot0_prediction.abtb_hit,
        id_slot0_prediction.abtb_way,
        id_slot0_prediction.abtb_cfi_type,
        id_slot0_prediction.abtb_target,
        id_slot0_prediction.abtb_pred_taken,
        id_slot0_prediction.abtb_pred_target,
        id_slot1_prediction.abtb_hit,
        id_slot1_prediction.abtb_way,
        id_slot1_prediction.abtb_cfi_type,
        id_slot1_prediction.abtb_target,
        id_slot1_prediction.abtb_pred_taken,
        id_slot1_prediction.abtb_pred_target,
        ex_slot0_prediction.prediction.abtb_hit,
        ex_slot0_prediction.prediction.abtb_way,
        ex_slot0_prediction.prediction.abtb_cfi_type,
        ex_slot0_prediction.prediction.abtb_target,
        ex_slot0_prediction.prediction.abtb_pred_taken,
        ex_slot0_prediction.prediction.abtb_pred_target,
        ex_slot0_prediction.update_qualified,
        ex_slot0_prediction.update_cfi_type,
        ex_slot1_prediction.prediction.abtb_hit,
        ex_slot1_prediction.prediction.abtb_way,
        ex_slot1_prediction.prediction.abtb_cfi_type,
        ex_slot1_prediction.prediction.abtb_target,
        ex_slot1_prediction.prediction.abtb_pred_taken,
        ex_slot1_prediction.prediction.abtb_pred_target,
        ex_slot1_prediction.update_qualified,
        ex_slot1_prediction.update_cfi_type,
        abtb_update.valid,
        abtb_update.hit,
        abtb_update.way,
        abtb_update.pc,
        abtb_update.cfi_type,
        abtb_update.target,
        counters.lookup_block,
        counters.bank0_hit,
        counters.bank1_hit,
        counters.ex_update,
        counters.allocation,
        counters.hit_update
    };

    (* dont_touch = "true" *)
    logic [ABTB_MEASUREMENT_SINK_W-1:0] measurement_sink_q;

    always_ff @(posedge clk) begin
        if (!rst_n)
            measurement_sink_q <= '0;
        else
            measurement_sink_q <= measurement_sink_d;
    end
`endif

endmodule
