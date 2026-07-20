// ============================================================
// Module: id_ex_payload_builder
// Description: Build ID/EX payloads from ISA-neutral decoded uops.
// Domain: pipeline boundary.
// ============================================================

module id_ex_payload_builder
    import cpu_defs::*;
(
    input  logic [31:0]      s0_pc,
    input  decoded_uop_t     s0_uop,
    input  logic [31:0]      s0_alu_src1,
    input  logic [31:0]      s0_alu_src2,
    input  logic [31:0]      s0_rs1_data,
    input  logic [31:0]      s0_rs2_data,
    input  logic             s0_rs1_wb_repair,
    input  logic             s0_rs2_wb_repair,
    input  prediction_meta_t s0_prediction,
    input  logic             s0_update_qualified,
    input  logic [ 1:0]      s0_update_cfi_type,

    input  logic [31:0]      s1_pc,
    input  logic [31:0]      s1_inst,
    input  decoded_uop_t     s1_uop,
    input  logic [31:0]      s1_alu_src1,
    input  logic [31:0]      s1_alu_src2,
    input  logic [31:0]      s1_rs1_data,
    input  logic [31:0]      s1_rs2_data,
    input  logic             s1_rs1_wb_repair,
    input  logic             s1_rs2_wb_repair,
    input  prediction_meta_t s1_prediction,
    input  logic             s1_update_qualified,
    input  logic [ 1:0]      s1_update_cfi_type,

    output id_ex_slot0_t     slot0_payload,
    output id_ex_slot1_t     slot1_payload
);

    always_comb begin
        slot0_payload = '0;
        slot0_payload.common.pc = s0_pc;
        slot0_payload.common.alu_src1 = s0_alu_src1;
        slot0_payload.common.alu_src2 = s0_alu_src2;
        slot0_payload.common.rs1_data = s0_rs1_data;
        slot0_payload.common.rs2_data = s0_rs2_data;
        slot0_payload.common.rs1_wb_repair = s0_rs1_wb_repair;
        slot0_payload.common.rs2_wb_repair = s0_rs2_wb_repair;
        slot0_payload.common.rd = s0_uop.dst_addr;
        slot0_payload.common.rs1_addr = s0_uop.src0_addr;
        slot0_payload.common.rs2_addr = s0_uop.src1_addr;
        slot0_payload.common.alu_src1_wb_repair =
            s0_rs1_wb_repair
            & (s0_uop.operand_a_sel == OPERAND_A_SRC0);
        slot0_payload.common.alu_src2_wb_repair =
            s0_rs2_wb_repair
            & (s0_uop.operand_b_sel == OPERAND_B_SRC1);
        slot0_payload.common.alu_op = s0_uop.alu_op;
        slot0_payload.common.reg_write_en = s0_uop.dst_write;
        slot0_payload.common.wb_sel = s0_uop.wb_src;
        slot0_payload.common.mem_read_en = s0_uop.mem_cmd == MEM_LOAD;
        slot0_payload.common.mem_write_en = s0_uop.mem_cmd == MEM_STORE;
        slot0_payload.common.mem_size = s0_uop.mem_size;
        slot0_payload.common.mem_unsigned = s0_uop.mem_unsigned;
        slot0_payload.common.control_flow = s0_uop.control_flow;
        slot0_payload.common.branch_op = s0_uop.branch_op;
        slot0_payload.common.target_clear_mask = s0_uop.target_clear_mask;
        slot0_payload.common.prediction.prediction = s0_prediction;
        slot0_payload.common.prediction.update_qualified =
            s0_update_qualified;
        slot0_payload.common.prediction.update_cfi_type =
            s0_update_cfi_type;
        slot0_payload.priv_op = s0_uop.priv_op;
        slot0_payload.priv_uses_imm = s0_uop.priv_uses_imm;
        slot0_payload.priv_cmd = s0_uop.priv_cmd;
        slot0_payload.priv_addr = s0_uop.priv_addr;
        slot0_payload.priv_imm = s0_uop.priv_imm;
        slot0_payload.is_muldiv = s0_uop.exec_unit == EXEC_MULDIV;
        slot0_payload.muldiv_op = s0_uop.muldiv_op;

        slot1_payload = '0;
        slot1_payload.common.pc = s1_pc;
        slot1_payload.common.alu_src1 = s1_alu_src1;
        slot1_payload.common.alu_src2 = s1_alu_src2;
        slot1_payload.common.rs1_data = s1_rs1_data;
        slot1_payload.common.rs2_data = s1_rs2_data;
        slot1_payload.common.rs1_wb_repair = s1_rs1_wb_repair;
        slot1_payload.common.rs2_wb_repair = s1_rs2_wb_repair;
        slot1_payload.common.rd = s1_uop.dst_addr;
        slot1_payload.common.rs1_addr = s1_uop.src0_addr;
        slot1_payload.common.rs2_addr = s1_uop.src1_addr;
        slot1_payload.common.alu_src1_wb_repair =
            s1_rs1_wb_repair
            & (s1_uop.operand_a_sel == OPERAND_A_SRC0);
        slot1_payload.common.alu_src2_wb_repair =
            s1_rs2_wb_repair
            & (s1_uop.operand_b_sel == OPERAND_B_SRC1);
        slot1_payload.common.alu_op = s1_uop.alu_op;
        slot1_payload.common.reg_write_en = s1_uop.dst_write;
        slot1_payload.common.wb_sel = s1_uop.wb_src;
        slot1_payload.common.mem_read_en = s1_uop.mem_cmd == MEM_LOAD;
        slot1_payload.common.mem_write_en = s1_uop.mem_cmd == MEM_STORE;
        slot1_payload.common.mem_size = s1_uop.mem_size;
        slot1_payload.common.mem_unsigned = s1_uop.mem_unsigned;
        slot1_payload.common.control_flow = s1_uop.control_flow;
        slot1_payload.common.branch_op = s1_uop.branch_op;
        slot1_payload.common.target_clear_mask = s1_uop.target_clear_mask;
        slot1_payload.common.prediction.prediction = s1_prediction;
        slot1_payload.common.prediction.update_qualified =
            s1_update_qualified;
        slot1_payload.common.prediction.update_cfi_type =
            s1_update_cfi_type;
        slot1_payload.inst = s1_inst;
    end

endmodule
