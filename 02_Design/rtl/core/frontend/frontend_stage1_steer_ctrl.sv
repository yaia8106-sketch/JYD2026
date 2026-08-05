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

    wire [31:0] sequential_next_pc =
        current_pc + (current_pc[2] ? 32'd4 : 32'd8);

    wire bank0_direct = bank0.lookup_hit
        && ((bank0.cfi_type == CFI_TYPE_JUMP)
            || (bank0.cfi_type == CFI_TYPE_CALL));
    wire bank1_direct = bank1.lookup_hit
        && ((bank1.cfi_type == CFI_TYPE_JUMP)
            || (bank1.cfi_type == CFI_TYPE_CALL));
    assign bank0_branch_owned = bank0.lookup_hit
        && (bank0.cfi_type == CFI_TYPE_BRANCH);
    assign bank1_branch_owned = bank1.lookup_hit
        && (bank1.cfi_type == CFI_TYPE_BRANCH);

    wire bank0_valid = bank0_direct || bank0_branch_owned;
    wire bank1_valid = bank1_direct || bank1_branch_owned;
    wire bank0_taken = bank0_direct
        || (bank0_branch_owned && bank0.pred_taken);
    wire bank1_taken = bank1_direct
        || (bank1_branch_owned && bank1.pred_taken);

    // Bank 0 is older only when the fetch block starts at its first word.
    // Compute the two mutually exclusive taken candidates before touching the
    // 32-bit targets.  A not-taken Bank-0 branch deliberately permits a taken
    // Bank-1 CFI, matching the original program-order policy.
    wire bank0_selected_taken = !current_pc[2] && bank0_taken;
    wire bank1_selected_taken = !bank0_selected_taken && bank1_taken;
    wire selected_taken = bank0_selected_taken || bank1_selected_taken;
    wire [31:0] selected_target_candidate = bank0_selected_taken
        ? bank0.target : bank1.target;
    wire [31:0] selected_next_pc = selected_taken
        ? selected_target_candidate : sequential_next_pc;

    wire first_valid = current_pc[2] ? bank1_valid : bank0_valid;
    wire first_taken = current_pc[2] ? bank1_taken : bank0_taken;
    wire [1:0] first_cfi_type = current_pc[2]
        ? bank1.cfi_type : bank0.cfi_type;

    // Keep target/next-PC steering independent from metadata bookkeeping.
    // steer.target is consumed only when steer.taken is asserted, so writing
    // the already-selected candidate on a not-taken packet is harmless.  The
    // valid/taken bits retain sole ownership of that speculative payload.
    always_comb begin
        steer = '0;
        steer.valid = lookup_valid;
        steer.source_abtb = selected_taken;
        steer.taken = selected_taken;
        steer.bank = current_pc[2];
        steer.target = selected_target_candidate;
        steer.next_pc = selected_next_pc;

        // A not-taken first branch retains ownership even when a younger
        // Bank-1 CFI supplies the taken target.
        if (first_valid) begin
            steer.branch_owned = first_cfi_type == CFI_TYPE_BRANCH;
            steer.branch_owned_nt =
                (first_cfi_type == CFI_TYPE_BRANCH) && !first_taken;
            steer.cfi_type = first_cfi_type;
        end

        if (bank1_selected_taken) begin
            steer.bank = 1'b1;
            steer.cfi_type = bank1.cfi_type;
        end
    end

endmodule
