// ============================================================
// Module: predictor_update_ctrl
// Description: Select one resolved CFI and generate ABTB/PHT updates.
// Domain: frontend.
// The issue policy guarantees that at most one slot contains a CFI.
// ============================================================

module predictor_update_ctrl
    import cpu_defs::*;
(
    input  logic               clk,
    input  logic               rst_n,

    input  logic               ex_ready_go,
    input  logic               mem_allowin,
    input  logic               mem_branch_flush, // MEM redirect 抑制错误路径上的新训练事件

    // 每个结构体同时携带 EX 实际结果和预测时保存的 metadata。
    input  predictor_resolve_t slot0_resolve,
    input  predictor_resolve_t slot1_resolve,

    output logic               slot0_cfi_valid,
    output logic               slot1_cfi_valid,
    output predictor_train_t   train,
    output abtb_update_t       abtb_update,
    output pht_update_t        pht_update,

    // Registered predictor write events. The raw outputs above remain aligned
    // with EX for redirect/observation; only these events mutate ABTB/PHT/GHR.
    // 原始 update 与 EX 对齐；真正修改 ABTB/PHT/GHR 的 write 事件延后一拍。
    output abtb_update_t       abtb_write,
    output pht_update_t        pht_write
);

    wire slot0_cfi_candidate = slot0_resolve.valid
                             & (slot0_resolve.is_conditional_branch
                              | slot0_resolve.is_direct_jump
                              | slot0_resolve.is_indirect_jump);
    wire slot1_cfi_candidate = slot1_resolve.valid
                             & (slot1_resolve.is_conditional_branch
                              | slot1_resolve.is_direct_jump
                              | slot1_resolve.is_indirect_jump);
    // frontend_pair_policy rejects two-CFI pairs, and Slot-0 JALR is forced
    // single.  Keep the slots independent here so one slot's CFI decode does
    // not sit on the other slot's predictor write-enable path.  The assertion
    // below guards this pipeline invariant in simulation.
    wire slot0_selected = slot0_cfi_candidate;
    wire slot1_selected = slot1_cfi_candidate;
    wire update_fire = ex_ready_go & mem_allowin & ~mem_branch_flush;

    // Qualify each slot independently before the final priority selection.
    // In particular, Slot 1 actual_taken no longer passes through a selected
    // type/actual mux before it reaches the ABTB update-valid decision.
    wire slot0_is_abtb_branch =
        slot0_resolve.update_cfi_type == CFI_TYPE_BRANCH;
    wire slot1_is_abtb_branch =
        slot1_resolve.update_cfi_type == CFI_TYPE_BRANCH;
    wire slot0_abtb_qualified = slot0_resolve.update_qualified
                              & (~slot0_is_abtb_branch
                                 | slot0_resolve.actual_taken);
    wire slot1_abtb_qualified = slot1_resolve.update_qualified
                              & (~slot1_is_abtb_branch
                                 | slot1_resolve.actual_taken);
    // update_qualified is generated only for predictor-trainable CFIs, so the
    // An additional control-flow-class candidate gate would be redundant.
    wire slot0_abtb_fire = update_fire & slot0_resolve.valid
                         & slot0_abtb_qualified;
    wire slot1_abtb_fire = update_fire & slot1_resolve.valid
                         & slot1_abtb_qualified;
    wire slot0_pht_fire = update_fire & slot0_resolve.valid
                        & slot0_resolve.is_conditional_branch;
    wire slot1_pht_fire = update_fire & slot1_resolve.valid
                        & slot1_resolve.is_conditional_branch;

    assign slot0_cfi_valid = slot0_cfi_candidate;
    assign slot1_cfi_valid = slot1_cfi_candidate;

    // Only one CFI trains the predictors each cycle.  Because the slot-valid
    // predicates are mutually exclusive for CFIs, this remains a one-hot
    // selection without a cross-slot priority dependency.
    always_comb begin
        train = '0;
        abtb_update = '0;
        pht_update = '0;
        train.from_slot1 = slot1_selected;
        train.valid = update_fire & (slot0_selected | slot1_selected);

        if (slot1_selected) begin
            train.pc = slot1_resolve.pc;
            train.is_conditional_branch = slot1_resolve.is_conditional_branch;
            train.is_direct_jump = slot1_resolve.is_direct_jump;
            train.is_indirect_jump = slot1_resolve.is_indirect_jump;
            train.actual_taken = slot1_resolve.actual_taken;
            train.actual_target = slot1_resolve.actual_target;
            abtb_update.hit = slot1_resolve.abtb_hit;
            abtb_update.way = slot1_resolve.abtb_way;
            abtb_update.cfi_type = slot1_resolve.update_cfi_type;
            pht_update.index = slot1_resolve.pht_index;
            pht_update.counter = slot1_resolve.pht_counter;
        end else begin
            train.pc = slot0_resolve.pc;
            train.is_conditional_branch = slot0_resolve.is_conditional_branch;
            train.is_direct_jump = slot0_resolve.is_direct_jump;
            train.is_indirect_jump = slot0_resolve.is_indirect_jump;
            train.actual_taken = slot0_resolve.actual_taken;
            train.actual_target = slot0_resolve.actual_target;
            abtb_update.hit = slot0_resolve.abtb_hit;
            abtb_update.way = slot0_resolve.abtb_way;
            abtb_update.cfi_type = slot0_resolve.update_cfi_type;
            pht_update.index = slot0_resolve.pht_index;
            pht_update.counter = slot0_resolve.pht_counter;
        end

        abtb_update.valid = slot0_abtb_fire | slot1_abtb_fire;
        abtb_update.pc = train.pc;
        abtb_update.target = train.actual_target;

        pht_update.valid = slot0_pht_fire | slot1_pht_fire;
        pht_update.actual_taken = train.actual_taken;
    end

    // EX resolve and frontend predictor state are separated by a real clock
    // boundary. Payload fields are deliberately free-running; reset and late
    // wrong-path suppression affect only valid. Once captured, an older event
    // must write on the next edge even if a new MEM redirect is then present.
    // This pipeline accepts one event every cycle, so consecutive CFIs retain
    // their original order without a queue or backpressure path.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            abtb_write.valid <= 1'b0;
            pht_write.valid  <= 1'b0;
        end else begin
            abtb_write.valid <= abtb_update.valid;
            pht_write.valid  <= pht_update.valid;
        end

        abtb_write.hit      <= abtb_update.hit;
        abtb_write.way      <= abtb_update.way;
        abtb_write.pc       <= abtb_update.pc;
        abtb_write.cfi_type <= abtb_update.cfi_type;
        abtb_write.target   <= abtb_update.target;

        pht_write.index        <= pht_update.index;
        pht_write.counter      <= pht_update.counter;
        pht_write.actual_taken <= pht_update.actual_taken;
    end

`ifndef SYNTHESIS
    abtb_update_t expected_abtb_write;
    pht_update_t  expected_pht_write;

    always @(posedge clk) begin
        if (rst_n && slot0_cfi_valid && slot1_cfi_valid)
            $error("Single predictor update port saw simultaneous slot0 and slot1 control flow");
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            expected_abtb_write <= '0;
            expected_pht_write  <= '0;
        end else begin
            if (abtb_write.valid !== expected_abtb_write.valid)
                $error("ABTB write event is not exactly one cycle after EX capture");
            if (pht_write.valid !== expected_pht_write.valid)
                $error("PHT write event is not exactly one cycle after EX capture");
            if (expected_abtb_write.valid
                && (abtb_write !== expected_abtb_write))
                $error("Registered ABTB write payload changed across the boundary");
            if (expected_pht_write.valid
                && (pht_write !== expected_pht_write))
                $error("Registered PHT write payload changed across the boundary");

            expected_abtb_write <= abtb_update;
            expected_pht_write  <= pht_update;
        end
    end
`endif

endmodule
