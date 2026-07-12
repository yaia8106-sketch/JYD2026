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
    input  logic               mem_branch_flush, // 打拍到MEM的redirect信号(我们的redirect是在MEM/WB时钟边沿触发的)

    // 即包含了EX执行后的confirm data，也包含了metadata的神秘结构体
    input  predictor_resolve_t slot0_resolve,
    input  predictor_resolve_t slot1_resolve,

    output logic               slot0_cfi_valid,
    output logic               slot1_cfi_valid,
    output predictor_train_t   train, // 似乎没什么卵用，历史遗留结构体说是
    output abtb_update_t       abtb_update, // btb update info
    output pht_update_t        pht_update // pht update info
);

    // slot0_cfi_valid = slot0_cfi_candidate
    wire slot0_cfi_candidate = slot0_resolve.valid
                             & (slot0_resolve.is_branch
                              | slot0_resolve.is_jal
                              | slot0_resolve.is_jalr);
    wire slot1_cfi_candidate = slot1_resolve.valid
                             & (slot1_resolve.is_branch
                              | slot1_resolve.is_jal
                              | slot1_resolve.is_jalr);
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
        slot0_resolve.update_cfi_type == ABTB_TYPE_BRANCH;
    wire slot1_is_abtb_branch =
        slot1_resolve.update_cfi_type == ABTB_TYPE_BRANCH;
    wire slot0_abtb_qualified = slot0_resolve.update_qualified
                              & (~slot0_is_abtb_branch
                                 | slot0_resolve.actual_taken);
    wire slot1_abtb_qualified = slot1_resolve.update_qualified
                              & (~slot1_is_abtb_branch
                                 | slot1_resolve.actual_taken);
    // update_qualified is generated only for predictor-trainable CFIs, so the
    // additional is_branch/is_jal/is_jalr candidate gate would be redundant.
    wire slot0_abtb_fire = update_fire & slot0_resolve.valid
                         & slot0_abtb_qualified;
    wire slot1_abtb_fire = update_fire & slot1_resolve.valid
                         & slot1_abtb_qualified;
    wire slot0_pht_fire = update_fire & slot0_resolve.valid
                        & slot0_resolve.is_branch;
    wire slot1_pht_fire = update_fire & slot1_resolve.valid
                        & slot1_resolve.is_branch;

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
            train.is_branch = slot1_resolve.is_branch;
            train.is_jal = slot1_resolve.is_jal;
            train.is_jalr = slot1_resolve.is_jalr;
            train.actual_taken = slot1_resolve.actual_taken;
            train.actual_target = slot1_resolve.actual_target;
            abtb_update.hit = slot1_resolve.abtb_hit;
            abtb_update.way = slot1_resolve.abtb_way;
            abtb_update.cfi_type = slot1_resolve.update_cfi_type;
            pht_update.index = slot1_resolve.pht_index;
            pht_update.counter = slot1_resolve.pht_counter;
        end else begin
            train.pc = slot0_resolve.pc;
            train.is_branch = slot0_resolve.is_branch;
            train.is_jal = slot0_resolve.is_jal;
            train.is_jalr = slot0_resolve.is_jalr;
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

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && slot0_cfi_valid && slot1_cfi_valid)
            $error("Single predictor update port saw simultaneous slot0 and slot1 control flow");
    end
`endif

endmodule
