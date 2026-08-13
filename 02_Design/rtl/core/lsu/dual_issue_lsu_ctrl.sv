// ============================================================
// Module: dual_issue_lsu_ctrl
// Description: Coordinate the single LSU across two issue slots.
// Domain: load/store unit.
//
// ID decides whether a Slot-0 ALU result will feed a paired Slot-1 store.
// EX selects the active LSU lane and suppresses younger Slot-1 side effects
// when the older Slot-0 instruction redirects or traps.
// ============================================================

module dual_issue_lsu_ctrl (
    // ID-stage same-pair store-data bypass qualification.
    input  logic        id_slot1_valid,
    input  logic        id_slot0_alu_only,
    input  logic        id_slot0_reg_write_en,
    input  logic [4:0]  id_slot0_rd,
    input  logic        id_slot1_mem_write_en,
    input  logic [4:0]  id_slot1_rs1,
    input  logic [4:0]  id_slot1_rs2,
    output logic        id_slot0_to_slot1_store_bypass,

    // EX-stage lane selection and younger-side-effect suppression.
    input  logic        ex_slot1_valid,
    input  logic        ex_slot1_mem_read_en,
    input  logic        ex_slot1_mem_write_en,
    input  logic        ex_slot0_branch_redirect,
    input  logic        ex_slot0_priv_trap,
    input  logic        ex_slot1_addr_replay,
    output logic        ex_slot1_lsu_select,
    output logic        ex_slot1_side_effect_kill,

    // The bypass decision is registered with ID/EX; only the data mux remains
    // in EX, so register comparisons never enter the ALU-to-store-data path.
    input  logic        ex_slot0_store_bypass_q,
    input  logic [31:0] ex_slot0_alu_result,
    input  logic [31:0] ex_slot1_rs2_data,
    output logic [31:0] ex_slot1_store_data
);

    assign id_slot0_to_slot1_store_bypass = id_slot1_valid
        & id_slot0_alu_only
        & id_slot1_mem_write_en
        & id_slot0_reg_write_en
        & (id_slot0_rd != 5'd0)
        & (id_slot1_rs2 == id_slot0_rd)
        & (id_slot1_rs1 != id_slot0_rd);

    assign ex_slot1_lsu_select = ex_slot1_valid
        & (ex_slot1_mem_read_en | ex_slot1_mem_write_en);
    assign ex_slot1_side_effect_kill = ex_slot0_branch_redirect
                                     | ex_slot0_priv_trap
                                     | ex_slot1_addr_replay;

    assign ex_slot1_store_data = ex_slot0_store_bypass_q
                               ? ex_slot0_alu_result
                               : ex_slot1_rs2_data;

endmodule
