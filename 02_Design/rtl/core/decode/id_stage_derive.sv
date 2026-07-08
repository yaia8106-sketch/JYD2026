// ============================================================
// Module: id_stage_derive
// Description: ID-stage field extraction, operand-use derive, and CFI classify.
// Domain: decode and issue.
// ============================================================

module id_stage_derive
    import cpu_defs::*;
(
    input  logic [31:0] id_pc,
    input  logic [31:0] id_inst,
    input  logic [31:0] id_inst1,

    input  logic [ 1:0] dec_alu_src1_sel,
    input  logic        dec_alu_src2_sel,
    input  logic        dec_reg_write_en,
    input  logic [ 1:0] dec_wb_sel,
    input  logic        dec_mem_read_en,
    input  logic        dec_mem_write_en,
    input  logic        dec_is_branch,
    input  logic        dec_is_jal,
    input  logic        dec_is_jalr,
    input  logic        dec_is_csr,
    input  logic        dec_csr_uses_rs1,
    input  logic        dec_is_muldiv,

    input  logic [ 1:0] dec1_alu_src1_sel,
    input  logic        dec1_alu_src2_sel,
    input  logic        dec1_mem_read_en,
    input  logic        dec1_mem_write_en,
    input  logic        dec1_is_branch,
    input  logic        dec1_is_jal,
    input  logic        dec1_is_jalr,
    input  logic        dec1_csr_uses_rs1,

    output logic [ 4:0] id_rs1_addr,
    output logic [ 4:0] id_rs2_addr,
    output logic [ 4:0] id_rd_addr,
    output logic [ 4:0] id_s1_rs1_addr,
    output logic [ 4:0] id_s1_rs2_addr,
    output logic [ 4:0] id_s1_rd_addr,
    output logic [31:0] id_pc_plus_4,
    output logic [31:0] id_s1_pc,
    output logic [ 2:0] id_csr_cmd,
    output logic [11:0] id_csr_addr,
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

    // Decode architectural register fields for both issue slots. Slot 1 is
    // always the sequential instruction at id_pc+4 when it is valid.
    assign id_rs1_addr = id_inst[19:15];
    assign id_rs2_addr = id_inst[24:20];
    assign id_rd_addr  = id_inst[11:7];
    assign id_s1_rs1_addr = id_inst1[19:15];
    assign id_s1_rs2_addr = id_inst1[24:20];
    assign id_s1_rd_addr  = id_inst1[11:7];
    assign id_pc_plus_4 = id_pc + 32'd4;
    assign id_s1_pc = id_pc_plus_4;
    assign id_csr_cmd = id_inst[14:12];
    assign id_csr_addr = id_inst[31:20];

    // These booleans let later repair logic know whether replacing rs1/rs2
    // should also replace the already-selected ALU operand.
    assign id_alu_src1_is_rs1 = dec_alu_src1_sel == 2'b00;
    assign id_alu_src2_is_rs2 = ~dec_alu_src2_sel;
    assign id_s1_alu_src1_is_rs1 = dec1_alu_src1_sel == 2'b00;
    assign id_s1_alu_src2_is_rs2 = ~dec1_alu_src2_sel;

    // Operand-use flags drive forwarding and load-use hazard detection.
    assign id_rs1_used = id_alu_src1_is_rs1 | dec_is_branch | dec_csr_uses_rs1;
    assign id_rs2_used = id_alu_src2_is_rs2 | dec_is_branch | dec_mem_write_en;
    assign id_s1_rs1_used = id_s1_alu_src1_is_rs1 | dec1_is_branch | dec1_csr_uses_rs1;
    assign id_s1_rs2_used = id_s1_alu_src2_is_rs2 | dec1_is_branch | dec1_mem_write_en;

    // Only simple ALU-like Slot 0 consumers can advance with a MEM-load repair
    // tag. DIV/REM stay out because the multi-cycle unit captures operands.
    wire id_s0_divrem = dec_is_muldiv & id_inst[14];
    assign id_s0_alu_only = dec_reg_write_en & (dec_wb_sel == 2'b00)
                          & ~dec_mem_read_en & ~dec_mem_write_en
                          & ~dec_is_branch & ~dec_is_jal & ~dec_is_jalr
                          & ~dec_is_csr & ~id_s0_divrem;
    assign id_s1_repair_ok = id_s1_alu_src1_is_rs1
                            | id_s1_alu_src2_is_rs2
                            | dec1_mem_read_en
                            | dec1_mem_write_en
                            | dec1_is_branch
                            | dec1_is_jalr;

    // Carry the confirmed CFI type to EX so RET recognition can use the full
    // JALR immediate instead of guessing from reduced EX control signals.
    wire id_rd_is_link = (id_rd_addr == 5'd1) | (id_rd_addr == 5'd5);
    wire id_rs1_is_link = (id_rs1_addr == 5'd1) | (id_rs1_addr == 5'd5);
    wire id_abtb_is_call = (dec_is_jal | dec_is_jalr) & id_rd_is_link;
    wire id_abtb_is_ret = dec_is_jalr
                         & (id_rd_addr == 5'd0)
                         & id_rs1_is_link
                         & (id_inst[31:20] == 12'd0);

    assign id_abtb_update_qualified = dec_is_branch
                                    | dec_is_jal
                                    | id_abtb_is_call
                                    | id_abtb_is_ret;
    assign id_abtb_update_cfi_type =
        id_abtb_is_ret  ? ABTB_TYPE_RET :
        id_abtb_is_call ? ABTB_TYPE_CALL :
        dec_is_branch   ? ABTB_TYPE_BRANCH :
                          ABTB_TYPE_JAL;

    wire id_s1_rd_is_link = (id_s1_rd_addr == 5'd1)
                          | (id_s1_rd_addr == 5'd5);
    wire id_s1_rs1_is_link = (id_s1_rs1_addr == 5'd1)
                           | (id_s1_rs1_addr == 5'd5);
    wire id_s1_abtb_is_call = (dec1_is_jal | dec1_is_jalr)
                            & id_s1_rd_is_link;
    wire id_s1_abtb_is_ret = dec1_is_jalr
                           & (id_s1_rd_addr == 5'd0)
                           & id_s1_rs1_is_link
                           & (id_inst1[31:20] == 12'd0);

    assign id_s1_abtb_update_qualified = dec1_is_branch
                                       | dec1_is_jal
                                       | id_s1_abtb_is_call
                                       | id_s1_abtb_is_ret;
    assign id_s1_abtb_update_cfi_type =
        id_s1_abtb_is_ret  ? ABTB_TYPE_RET :
        id_s1_abtb_is_call ? ABTB_TYPE_CALL :
        dec1_is_branch     ? ABTB_TYPE_BRANCH :
                             ABTB_TYPE_JAL;

endmodule
