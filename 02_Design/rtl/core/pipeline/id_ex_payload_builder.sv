// ============================================================
// Module: id_ex_payload_builder
// Description: Pure combinational construction of both ID/EX payloads.
// Domain: pipeline boundary.
// Pipeline valid/allow/flush state remains in id_ex_reg modules.
// ============================================================

module id_ex_payload_builder
    import cpu_defs::*;
(
    input  logic [31:0]        s0_pc,
    input  logic [31:0]        s0_alu_src1,
    input  logic [31:0]        s0_alu_src2,
    input  logic [31:0]        s0_rs1_data,
    input  logic [31:0]        s0_rs2_data,
    input  logic               s0_rs1_wb_repair,
    input  logic               s0_rs2_wb_repair,
    input  logic [ 4:0]        s0_rd,
    input  logic [ 4:0]        s0_rs1_addr,
    input  logic [ 4:0]        s0_rs2_addr,
    input  logic               s0_alu_src1_is_rs1,
    input  logic               s0_alu_src2_is_rs2,
    input  logic [ 3:0]        s0_alu_op,
    input  logic               s0_reg_write_en,
    input  logic [ 1:0]        s0_wb_sel,
    input  logic               s0_mem_read_en,
    input  logic               s0_mem_write_en,
    input  logic [ 1:0]        s0_mem_size,
    input  logic               s0_mem_unsigned,
    input  logic               s0_is_branch,
    input  logic [ 2:0]        s0_branch_cond,
    input  logic               s0_is_jal,
    input  logic               s0_is_jalr,
    input  prediction_meta_t   s0_prediction,
    input  logic               s0_update_qualified,
    input  logic [ 1:0]        s0_update_cfi_type,
    input  logic               s0_is_csr,
    input  logic               s0_csr_uses_imm,
    input  logic [ 2:0]        s0_csr_cmd,
    input  logic [11:0]        s0_csr_addr,
    input  logic               s0_is_ecall,
    input  logic               s0_is_mret,
    input  logic               s0_is_muldiv,
    input  logic [ 2:0]        s0_muldiv_op,

    input  logic [31:0]        s1_pc,
    input  logic [31:0]        s1_inst,
    input  logic [31:0]        s1_alu_src1,
    input  logic [31:0]        s1_alu_src2,
    input  logic [31:0]        s1_rs1_data,
    input  logic [31:0]        s1_rs2_data,
    input  logic               s1_rs1_wb_repair,
    input  logic               s1_rs2_wb_repair,
    input  logic [ 4:0]        s1_rd,
    input  logic [ 4:0]        s1_rs1_addr,
    input  logic [ 4:0]        s1_rs2_addr,
    input  logic               s1_alu_src1_is_rs1,
    input  logic               s1_alu_src2_is_rs2,
    input  logic [ 3:0]        s1_alu_op,
    input  logic               s1_reg_write_en,
    input  logic [ 1:0]        s1_wb_sel,
    input  logic               s1_mem_read_en,
    input  logic               s1_mem_write_en,
    input  logic [ 1:0]        s1_mem_size,
    input  logic               s1_mem_unsigned,
    input  logic               s1_is_branch,
    input  logic [ 2:0]        s1_branch_cond,
    input  logic               s1_is_jal,
    input  logic               s1_is_jalr,
    input  prediction_meta_t   s1_prediction,
    input  logic               s1_update_qualified,
    input  logic [ 1:0]        s1_update_cfi_type,

    output id_ex_slot0_t       slot0_payload,
    output id_ex_slot1_t       slot1_payload
);

    // Start each packed payload from zero so fields unused by a slot cannot
    // leak stale state into downstream side-effect enables.
    always_comb begin
        slot0_payload = '0;
        slot0_payload.common.pc = s0_pc;
        slot0_payload.common.alu_src1 = s0_alu_src1;
        slot0_payload.common.alu_src2 = s0_alu_src2;
        slot0_payload.common.rs1_data = s0_rs1_data;
        slot0_payload.common.rs2_data = s0_rs2_data;
        slot0_payload.common.rs1_wb_repair = s0_rs1_wb_repair;
        slot0_payload.common.rs2_wb_repair = s0_rs2_wb_repair;
        slot0_payload.common.rd = s0_rd;
        slot0_payload.common.rs1_addr = s0_rs1_addr;
        slot0_payload.common.rs2_addr = s0_rs2_addr;
        slot0_payload.common.alu_src1_is_rs1 = s0_alu_src1_is_rs1;
        slot0_payload.common.alu_src2_is_rs2 = s0_alu_src2_is_rs2;
        slot0_payload.common.alu_op = s0_alu_op;
        slot0_payload.common.reg_write_en = s0_reg_write_en;
        slot0_payload.common.wb_sel = s0_wb_sel;
        slot0_payload.common.mem_read_en = s0_mem_read_en;
        slot0_payload.common.mem_write_en = s0_mem_write_en;
        slot0_payload.common.mem_size = s0_mem_size;
        slot0_payload.common.mem_unsigned = s0_mem_unsigned;
        slot0_payload.common.is_branch = s0_is_branch;
        slot0_payload.common.branch_cond = s0_branch_cond;
        slot0_payload.common.is_jal = s0_is_jal;
        slot0_payload.common.is_jalr = s0_is_jalr;
        slot0_payload.common.prediction.prediction = s0_prediction;
        slot0_payload.common.prediction.update_qualified =
            s0_update_qualified;
        slot0_payload.common.prediction.update_cfi_type =
            s0_update_cfi_type;
        slot0_payload.is_csr = s0_is_csr;
        slot0_payload.csr_uses_imm = s0_csr_uses_imm;
        slot0_payload.csr_cmd = s0_csr_cmd;
        slot0_payload.csr_addr = s0_csr_addr;
        slot0_payload.is_ecall = s0_is_ecall;
        slot0_payload.is_mret = s0_is_mret;
        slot0_payload.is_muldiv = s0_is_muldiv;
        slot0_payload.muldiv_op = s0_muldiv_op;

        slot1_payload = '0;
        slot1_payload.common.pc = s1_pc;
        slot1_payload.common.alu_src1 = s1_alu_src1;
        slot1_payload.common.alu_src2 = s1_alu_src2;
        slot1_payload.common.rs1_data = s1_rs1_data;
        slot1_payload.common.rs2_data = s1_rs2_data;
        slot1_payload.common.rs1_wb_repair = s1_rs1_wb_repair;
        slot1_payload.common.rs2_wb_repair = s1_rs2_wb_repair;
        slot1_payload.common.rd = s1_rd;
        slot1_payload.common.rs1_addr = s1_rs1_addr;
        slot1_payload.common.rs2_addr = s1_rs2_addr;
        slot1_payload.common.alu_src1_is_rs1 = s1_alu_src1_is_rs1;
        slot1_payload.common.alu_src2_is_rs2 = s1_alu_src2_is_rs2;
        slot1_payload.common.alu_op = s1_alu_op;
        slot1_payload.common.reg_write_en = s1_reg_write_en;
        slot1_payload.common.wb_sel = s1_wb_sel;
        slot1_payload.common.mem_read_en = s1_mem_read_en;
        slot1_payload.common.mem_write_en = s1_mem_write_en;
        slot1_payload.common.mem_size = s1_mem_size;
        slot1_payload.common.mem_unsigned = s1_mem_unsigned;
        slot1_payload.common.is_branch = s1_is_branch;
        slot1_payload.common.branch_cond = s1_branch_cond;
        slot1_payload.common.is_jal = s1_is_jal;
        slot1_payload.common.is_jalr = s1_is_jalr;
        slot1_payload.common.prediction.prediction = s1_prediction;
        slot1_payload.common.prediction.update_qualified =
            s1_update_qualified;
        slot1_payload.common.prediction.update_cfi_type =
            s1_update_cfi_type;
        slot1_payload.inst = s1_inst;
    end

endmodule
