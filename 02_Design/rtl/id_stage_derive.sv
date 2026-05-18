// ============================================================
// Module: id_stage_derive
// Description: ID-stage field extraction, branch precompute, and NLP redirect.
// ============================================================

module id_stage_derive (
    input  logic        id_valid,
    input  logic        id_ready_go,
    input  logic        ex_allowin,
    input  logic        mem_branch_flush,

    input  logic [31:0] id_pc,
    input  logic [31:0] id_inst,
    input  logic [31:0] id_inst1,
    input  logic [31:0] id_imm,

    input  logic [ 1:0] dec_alu_src1_sel,
    input  logic        dec_alu_src2_sel,
    input  logic        dec_reg_write_en,
    input  logic [ 1:0] dec_wb_sel,
    input  logic        dec_mem_read_en,
    input  logic        dec_mem_write_en,
    input  logic        dec_is_branch,
    input  logic [ 2:0] dec_branch_cond,
    input  logic        dec_is_jal,
    input  logic        dec_is_jalr,
    input  logic        dec_is_csr,
    input  logic        dec_csr_uses_rs1,

    input  logic [ 1:0] dec1_alu_src1_sel,
    input  logic        dec1_alu_src2_sel,
    input  logic        dec1_mem_write_en,
    input  logic        dec1_is_branch,
    input  logic        dec1_csr_uses_rs1,

    input  logic [31:0] fwd_rs1_data,
    input  logic [31:0] fwd_rs2_data,
    input  logic [31:0] fwd_branch_rs1_data,
    input  logic [31:0] fwd_branch_rs2_data,
    input  logic [31:0] fwd_rs1_jalr_data,

    input  logic        id_bp_btb_hit,
    input  logic [ 1:0] id_bp_btb_type,
    input  logic [ 1:0] id_bp_btb_bht,
    input  logic [ 1:0] id_bp_pht_cnt,
    input  logic [ 1:0] id_bp_sel_cnt,
    input  logic [31:0] id_bp_target,

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
    output logic [31:0] id_branch_target_pre,
    output logic        id_rs1_used,
    output logic        id_rs2_used,
    output logic        id_s1_rs1_used,
    output logic        id_s1_rs2_used,
    output logic        id_s0_alu_only,
    output logic        id_branch_taken_pre,
    output logic        id_tournament_taken,
    output logic        id_bp_redirect_raw,
    output logic        id_bp_redirect,
    output logic        id_s1_squash_raw,
    output logic [31:0] id_redirect_target
);

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

    wire [31:0] id_pc_branch_target_sum = id_pc + id_imm;
    wire [31:0] id_jalr_target_sum = fwd_rs1_jalr_data + id_imm;
    assign id_branch_target_pre = dec_is_jalr ? {id_jalr_target_sum[31:1], 1'b0}
                                              : id_pc_branch_target_sum;

    assign id_rs1_used = (dec_alu_src1_sel == 2'b00) | dec_is_branch | dec_csr_uses_rs1;
    assign id_rs2_used = (dec_alu_src2_sel == 1'b0) | dec_is_branch | dec_mem_write_en;
    assign id_s1_rs1_used = (dec1_alu_src1_sel == 2'b00) | dec1_is_branch | dec1_csr_uses_rs1;
    assign id_s1_rs2_used = (dec1_alu_src2_sel == 1'b0) | dec1_is_branch | dec1_mem_write_en;

    assign id_s0_alu_only = dec_reg_write_en & (dec_wb_sel == 2'b00)
                          & ~dec_mem_read_en & ~dec_mem_write_en
                          & ~dec_is_branch & ~dec_is_jal & ~dec_is_jalr
                          & ~dec_is_csr;

    wire id_branch_eq = ~|(fwd_rs1_data ^ fwd_rs2_data);
    wire id_branch_taken_eqne = dec_branch_cond[0] ? ~id_branch_eq : id_branch_eq;
    wire id_branch_taken_cmp;

    branch_condition u_branch_condition (
        .rs1_data   (fwd_branch_rs1_data),
        .rs2_data   (fwd_branch_rs2_data),
        .branch_cond(dec_branch_cond),
        .taken      (id_branch_taken_cmp)
    );

    assign id_branch_taken_pre = dec_branch_cond[2] ? id_branch_taken_cmp
                                                    : id_branch_taken_eqne;

    wire id_bimodal_taken  = (id_bp_btb_bht >= 2'd2);
    wire id_gshare_taken   = (id_bp_pht_cnt >= 2'd2);
    wire id_use_bimodal    = (id_bp_sel_cnt >= 2'd2);
    assign id_tournament_taken = id_use_bimodal ? id_bimodal_taken : id_gshare_taken;

    assign id_bp_redirect_raw = id_valid & ~mem_branch_flush
                              & id_bp_btb_hit
                              & (id_bp_btb_type == 2'b10)
                              & (id_bp_btb_bht[1] != id_tournament_taken);
    assign id_bp_redirect = id_bp_redirect_raw & id_ready_go & ex_allowin;
    assign id_s1_squash_raw = id_bp_redirect_raw & id_tournament_taken;
    assign id_redirect_target = id_tournament_taken ? id_bp_target
                                                    : id_pc_plus_4;

endmodule
