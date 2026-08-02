// ============================================================
// Module: redirect_target_select
// Description: Select the final registered redirect PC in MEM.
// Domain: architectural control.
// ============================================================

module redirect_target_select
    import cpu_defs::*;
(
    input  redirect_t     redirect,
    input  ex_mem_slot0_t slot0_payload,
    input  ex_mem_slot1_t slot1_payload,
    output logic [31:0]   target
);

    wire [31:0] slot0_control_target = slot0_payload.alu_result
        & ~{30'd0, slot0_payload.target_clear_mask};
    wire [31:0] slot1_control_target = slot1_payload.alu_result
        & ~{30'd0, slot1_payload.target_clear_mask};

    always_comb begin
        case (redirect.source)
            REDIRECT_PRIVILEGED:
                target = slot0_payload.priv_target;
            REDIRECT_S1_CONTROL:
                target = redirect.actual_taken ? slot1_control_target
                                                : slot1_payload.pc_plus_4;
            REDIRECT_S1_REPLAY:
                target = slot1_payload.pc;
            default:
                target = redirect.actual_taken ? slot0_control_target
                                                : slot0_payload.pc_plus_4;
        endcase
    end

endmodule
