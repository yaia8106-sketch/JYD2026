// ============================================================
// Module: frontend_stage1_steer_ctrl
// Description: Canonical BP0 arbitration across two ABTB/PHT banks.
// Domain: frontend.
// ============================================================

module frontend_stage1_steer_ctrl
    import cpu_defs::*;
(
    input  logic                   lookup_valid, // = ftq_alloc_ready && fq_credit_for_bp0 && !redirect_valid
    input  logic [31:0]            current_pc,
    input  frontend_steer_bank_t   bank0,
    input  frontend_steer_bank_t   bank1,

    output logic                   bank0_branch_owned,
    output logic                   bank1_branch_owned,
    output frontend_steer_result_t steer
);

    logic bank0_direct;
    logic bank1_direct;
    logic bank0_valid;
    logic bank1_valid;
    logic bank0_taken;
    logic bank1_taken;
    logic first_valid;
    logic first_taken;
    logic first_bank;
    logic [1:0] first_cfi_type;
    logic [31:0] first_target;
    logic second_valid;
    logic second_taken;
    logic [31:0] sequential_next_pc;

    // Steering chooses the first visible control-flow instruction in program
    // order. A lower-bank not-taken branch can still own PHT metadata.
    always_comb begin
        sequential_next_pc =
            current_pc + (current_pc[2] ? 32'd4 : 32'd8);

        bank0_direct =
            bank0.lookup_hit
            && ((bank0.cfi_type == ABTB_TYPE_JAL)
                || (bank0.cfi_type == ABTB_TYPE_CALL));
        bank1_direct =
            bank1.lookup_hit
            && ((bank1.cfi_type == ABTB_TYPE_JAL)
                || (bank1.cfi_type == ABTB_TYPE_CALL));
        bank0_branch_owned =
            bank0.lookup_hit && (bank0.cfi_type == ABTB_TYPE_BRANCH);
        bank1_branch_owned =
            bank1.lookup_hit && (bank1.cfi_type == ABTB_TYPE_BRANCH);

        bank0_valid = bank0_direct || bank0_branch_owned;
        bank1_valid = bank1_direct || bank1_branch_owned;
        bank0_taken =
            bank0_direct || (bank0_branch_owned && bank0.pred_taken);
        bank1_taken =
            bank1_direct || (bank1_branch_owned && bank1.pred_taken);

        first_valid = current_pc[2] ? bank1_valid : bank0_valid;
        first_taken = current_pc[2] ? bank1_taken : bank0_taken;
        first_bank = current_pc[2];
        first_cfi_type = current_pc[2] ? bank1.cfi_type : bank0.cfi_type;
        first_target = current_pc[2] ? bank1.target : bank0.target;
        second_valid = !current_pc[2] && bank1_valid;
        second_taken = second_valid && bank1_taken;

        steer = '0;
        steer.valid = lookup_valid;
        steer.bank = current_pc[2];
        steer.target = sequential_next_pc;
        steer.next_pc = sequential_next_pc;

        // A not-taken first branch retains ownership even if a younger bank1
        // CFI supplies the taken target.
        if (first_valid) begin
            steer.source_abtb = first_taken;
            steer.branch_owned = first_cfi_type == ABTB_TYPE_BRANCH;
            steer.branch_owned_nt =
                (first_cfi_type == ABTB_TYPE_BRANCH) && !first_taken;
            steer.taken = first_taken;
            steer.bank = first_bank;
            steer.cfi_type = first_cfi_type;
            steer.target = first_target;
            steer.next_pc = first_taken ? first_target : sequential_next_pc;

            if (!first_taken && second_taken) begin
                steer.source_abtb = 1'b1;
                steer.taken = 1'b1;
                steer.bank = 1'b1;
                steer.cfi_type = bank1.cfi_type;
                steer.target = bank1.target;
                steer.next_pc = bank1.target;
            end
        end else if (second_taken) begin
            steer.source_abtb = 1'b1;
            steer.taken = 1'b1;
            steer.bank = 1'b1;
            steer.cfi_type = bank1.cfi_type;
            steer.target = bank1.target;
            steer.next_pc = bank1.target;
        end
    end

endmodule
