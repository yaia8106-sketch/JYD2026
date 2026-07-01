// ============================================================
// Module: frontend_pair_policy
// Description: Stateless dual-issue pairing policy.
// Domain: frontend.
// ============================================================

module frontend_pair_policy
    import cpu_defs::*;
(
    input  logic                contiguous,
    input  logic                slot0_valid,
    input  logic                slot1_valid,
    input  frontend_pair_meta_t slot0_meta,
    input  frontend_pair_meta_t slot1_meta,

    output logic                raw_dep,
    output logic                pair_supported,
    output logic                pair_ok
);

    logic slot0_supported;
    logic slot1_supported;
    logic both_lsu;
    logic both_cfi;

    always_comb begin
        raw_dep =
            slot0_meta.writes_rd
            && (slot0_meta.rd != 5'd0)
            && ((slot1_meta.uses_rs1
                 && (slot1_meta.rs1 == slot0_meta.rd))
                || (slot1_meta.uses_rs2
                    && (slot1_meta.rs2 == slot0_meta.rd)));

        slot0_supported =
            slot0_meta.is_alu_type | slot0_meta.is_lsu | slot0_meta.is_cfi;
        slot1_supported =
            slot1_meta.is_alu_type | slot1_meta.is_lsu | slot1_meta.is_cfi;
        both_lsu = slot0_meta.is_lsu & slot1_meta.is_lsu;
        both_cfi = slot0_meta.is_cfi & slot1_meta.is_cfi;

        pair_supported =
            slot0_supported & slot1_supported & ~both_lsu & ~both_cfi;
        pair_ok =
            slot0_valid
            && slot1_valid
            && contiguous
            && !slot0_meta.pred_taken
            && !slot0_meta.force_single
            && !slot1_meta.force_single
            && !raw_dep
            && pair_supported;
    end

endmodule
