// ============================================================
// Module: id_stage_derive
// Description: Derive ID-stage dependency and repair metadata from neutral uops.
// Domain: decode and issue.
// ============================================================

module id_stage_derive
    import cpu_defs::*;
(
    input  logic [31:0]  id_pc,
    input  decoded_uop_t slot0_uop,
    input  decoded_uop_t slot1_uop,
    input  issue_hint_t  slot0_hint,
    input  issue_hint_t  slot1_hint,

    output logic [ 4:0] id_rs1_addr,
    output logic [ 4:0] id_rs2_addr,
    output logic [ 4:0] id_rd_addr,
    output logic [ 4:0] id_s1_rs1_addr,
    output logic [ 4:0] id_s1_rs2_addr,
    output logic [ 4:0] id_s1_rd_addr,
    output logic [31:0] id_pc_plus_4,
    output logic [31:0] id_s1_pc,
    output logic        id_alu_src1_is_rs1,
    output logic        id_alu_src2_is_rs2,
    output logic        id_s1_alu_src1_is_rs1,
    output logic        id_s1_alu_src2_is_rs2,
    output logic        id_rs1_used,
    output logic        id_rs2_used,
    output logic        id_s1_rs1_used,
    output logic        id_s1_rs2_used,
    output logic        id_s0_alu_only,
    output logic        id_s1_repair_ok,
    output logic        id_abtb_update_qualified,
    output logic [ 1:0] id_abtb_update_cfi_type,
    output logic        id_s1_abtb_update_qualified,
    output logic [ 1:0] id_s1_abtb_update_cfi_type
);

    // Dependency/hazard fields come from registered ISA-neutral hints. The
    // full uop remains authoritative for execution, but no longer sits in the
    // ID-ready -> IF/ID-clock-enable feedback cone.
    assign id_rs1_addr = slot0_hint.src0_addr;
    assign id_rs2_addr = slot0_hint.src1_addr;
    assign id_rd_addr = slot0_hint.dst_addr;
    assign id_s1_rs1_addr = slot1_hint.src0_addr;
    assign id_s1_rs2_addr = slot1_hint.src1_addr;
    assign id_s1_rd_addr = slot1_hint.dst_addr;
    assign id_pc_plus_4 = id_pc + 32'd4;
    assign id_s1_pc = id_pc_plus_4;

    assign id_alu_src1_is_rs1 =
        slot0_uop.operand_a_sel == OPERAND_A_SRC0;
    assign id_alu_src2_is_rs2 =
        slot0_uop.operand_b_sel == OPERAND_B_SRC1;
    assign id_s1_alu_src1_is_rs1 =
        slot1_uop.operand_a_sel == OPERAND_A_SRC0;
    assign id_s1_alu_src2_is_rs2 =
        slot1_uop.operand_b_sel == OPERAND_B_SRC1;

    assign id_rs1_used = slot0_hint.src0_used;
    assign id_rs2_used = slot0_hint.src1_used;
    assign id_s1_rs1_used = slot1_hint.src0_used;
    assign id_s1_rs2_used = slot1_hint.src1_used;

    // Only ordinary ALU results use the existing late MEM-load repair path.
    // MDU and privileged results capture or produce data through other paths.
    assign id_s0_alu_only = slot0_hint.alu_only;
    assign id_s1_repair_ok = slot1_hint.src0_used | slot1_hint.src1_used;

    // Call/return conventions are decoded at the ISA boundary. The common
    // predictor receives only an implementation-neutral CFI classification.
    assign id_abtb_update_qualified = slot0_uop.cfi_update;
    assign id_abtb_update_cfi_type = slot0_uop.cfi_type;
    assign id_s1_abtb_update_qualified = slot1_uop.cfi_update;
    assign id_s1_abtb_update_cfi_type = slot1_uop.cfi_type;

endmodule
