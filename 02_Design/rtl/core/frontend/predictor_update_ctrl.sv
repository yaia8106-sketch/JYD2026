// ============================================================
// Module: predictor_update_ctrl
// Description: Select one resolved CFI and generate ABTB/PHT updates.
// Domain: frontend.
// Slot 0 is older and therefore has priority over Slot 1.
// ============================================================

module predictor_update_ctrl
    import cpu_defs::*;
(
    input  logic               clk,
    input  logic               rst_n,

    input  logic               ex_ready_go,
    input  logic               mem_allowin,
    input  logic               mem_branch_flush,

    input  predictor_resolve_t slot0_resolve,
    input  predictor_resolve_t slot1_resolve,

    output logic               slot0_cfi_valid,
    output logic               slot1_cfi_valid,
    output predictor_train_t   train,
    output abtb_update_t       abtb_update,
    output pht_update_t        pht_update
);

    logic selected_update_qualified;
    logic [1:0] selected_update_cfi_type;
    logic selected_is_abtb_branch;
    logic selected_abtb_write_qualified;

    always_comb begin
        slot0_cfi_valid = slot0_resolve.valid
                        & (slot0_resolve.is_branch
                         | slot0_resolve.is_jal
                         | slot0_resolve.is_jalr);
        slot1_cfi_valid = slot1_resolve.valid
                        & (slot1_resolve.is_branch
                         | slot1_resolve.is_jal
                         | slot1_resolve.is_jalr);

        train = '0;
        train.from_slot1 = ~slot0_cfi_valid & slot1_cfi_valid;
        train.valid = (slot0_cfi_valid | slot1_cfi_valid)
                    & ex_ready_go
                    & mem_allowin
                    & ~mem_branch_flush;

        if (train.from_slot1) begin
            train.pc = slot1_resolve.pc;
            train.is_branch = slot1_resolve.is_branch;
            train.is_jal = slot1_resolve.is_jal;
            train.is_jalr = slot1_resolve.is_jalr;
            train.actual_taken = slot1_resolve.actual_taken;
            train.actual_target = slot1_resolve.actual_target;
            selected_update_qualified = slot1_resolve.update_qualified;
            selected_update_cfi_type = slot1_resolve.update_cfi_type;
        end else begin
            train.pc = slot0_resolve.pc;
            train.is_branch = slot0_resolve.is_branch;
            train.is_jal = slot0_resolve.is_jal;
            train.is_jalr = slot0_resolve.is_jalr;
            train.actual_taken = slot0_resolve.actual_taken;
            train.actual_target = slot0_resolve.actual_target;
            selected_update_qualified = slot0_resolve.update_qualified;
            selected_update_cfi_type = slot0_resolve.update_cfi_type;
        end

        selected_is_abtb_branch =
            selected_update_cfi_type == ABTB_TYPE_BRANCH;
        selected_abtb_write_qualified =
            selected_update_qualified
            & (!selected_is_abtb_branch | train.actual_taken);

        abtb_update.valid = train.valid & selected_abtb_write_qualified;
        abtb_update.hit = train.from_slot1 ? slot1_resolve.abtb_hit
                                           : slot0_resolve.abtb_hit;
        abtb_update.way = train.from_slot1 ? slot1_resolve.abtb_way
                                           : slot0_resolve.abtb_way;
        abtb_update.pc = train.pc;
        abtb_update.cfi_type = selected_update_cfi_type;
        abtb_update.target = train.actual_target;

        pht_update.valid = train.valid & train.is_branch;
        pht_update.index = train.from_slot1 ? slot1_resolve.pht_index
                                            : slot0_resolve.pht_index;
        pht_update.counter = train.from_slot1 ? slot1_resolve.pht_counter
                                              : slot0_resolve.pht_counter;
        pht_update.actual_taken = train.actual_taken;
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && slot0_cfi_valid && slot1_cfi_valid)
            $error("Single predictor update port saw simultaneous slot0 and slot1 control flow");
    end
`endif

endmodule
