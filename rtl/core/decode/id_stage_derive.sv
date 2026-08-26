// ============================================================
// 中文说明：从已译码的中间指令信息中整理 ID 阶段需要的相关性、修复和发射控制字段。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：从统一操作描述中整理 ID 阶段的相关性和修复元数据。
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

    // 相关性字段来自已寄存的通用提示。完整 uop 仍然是执行阶段的权威
    // 来源，但不再进入 ID-ready 到 IF/ID 时钟使能的反馈路径。
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

    // 普通 ALU/LSU 操作和条件分支比较器可以在 EX 使用已寄存的 WB 修复值。
    // 间接控制流不允许这样做，因为 JIRL 还要用 rs1 形成重定向目标。
    assign id_s0_alu_only = slot0_hint.alu_only;
    assign id_s1_repair_ok = slot1_hint.alu_only
                           | slot1_hint.conditional_control
                           | slot1_hint.mem_read
                           | slot1_hint.mem_write;

    // 调用/返回约定在 ISA 边界完成译码；通用预测器只接收与具体 ISA
    // 实现无关的控制流分类。
    assign id_abtb_update_qualified = slot0_uop.cfi_update;
    assign id_abtb_update_cfi_type = slot0_uop.cfi_type;
    assign id_s1_abtb_update_qualified = slot1_uop.cfi_update;
    assign id_s1_abtb_update_cfi_type = slot1_uop.cfi_type;

endmodule
