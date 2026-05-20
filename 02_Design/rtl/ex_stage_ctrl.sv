// ============================================================
// Module: ex_stage_ctrl
// Description: EX-stage local glue for repair/result muxing and S1 redirect.
// ============================================================

module ex_stage_ctrl (
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_s1_pc,

    input  logic        ex_rs1_wb_repair,
    input  logic        ex_rs2_wb_repair,
    input  logic        ex_alu_src1_is_rs1,
    input  logic        ex_alu_src2_is_rs2,
    input  logic [ 4:0] ex_rs1_addr,
    input  logic [ 4:0] ex_rs2_addr,
    input  logic [31:0] wb_write_data,
    input  logic [31:0] ex_alu_src1,
    input  logic [31:0] ex_alu_src2,

    input  logic        mem_valid,
    input  logic        mem_reg_write_en,
    input  logic        mem_mem_read_en,
    input  logic [ 4:0] mem_rd,
    input  logic [ 1:0] mem_wb_sel,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_pc_plus_4,
    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write_en,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [ 1:0] mem_s1_wb_sel,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,

    input  logic        ex_is_csr,
    input  logic [31:0] ex_csr_rdata,
    input  logic        ex_is_muldiv,
    input  logic [31:0] ex_muldiv_result,
    input  logic [31:0] alu_forward_result,
    input  logic [31:0] alu_result,

    input  logic        ex_s1_valid,
    input  logic        ex_s1_is_branch,
    input  logic [ 2:0] ex_s1_branch_cond,
    input  logic [31:0] ex_s1_rs1_data,
    input  logic [31:0] ex_s1_rs2_data,
    input  logic [31:0] alu_s1_result,

    input  logic        mem_branch_flush,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        ex_branch_redirect,
    input  logic [31:0] branch_target,
    input  logic        ex_system_redirect,
    input  logic [31:0] ex_system_target,

    output logic [31:0] ex_pc_plus_4,
    output logic [31:0] ex_s1_pc_plus_4,
    output logic [31:0] ex_alu_src1_repair,
    output logic [31:0] ex_alu_src2_repair,
    output logic [31:0] ex_forward_result,
    output logic [31:0] ex_pipe_alu_result,
    output logic        ex_result_late,
    output logic [31:0] ex_s1_branch_target,
    output logic        ex_s1_branch_redirect,
    output logic        ex_registered_branch_flush,
    output logic [31:0] ex_registered_branch_target
);

    wire ex_s1_branch_taken;
    wire [31:0] mem_fwd_val;
    wire [31:0] mem_s1_fwd_val;
    wire        ex_rs1_s1_mem_hit;
    wire        ex_rs2_s1_mem_hit;
    wire        ex_rs1_s0_mem_hit;
    wire        ex_rs2_s0_mem_hit;

    assign ex_pc_plus_4 = ex_pc + 32'd4;
    assign ex_s1_pc_plus_4 = ex_s1_pc + 32'd4;
    assign mem_fwd_val = (mem_wb_sel == 2'b10) ? mem_pc_plus_4 : mem_alu_result;
    assign mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;
    assign ex_rs1_s1_mem_hit = ex_alu_src1_is_rs1 & mem_s1_valid & mem_s1_reg_write_en
                              & (mem_s1_rd != 5'd0) & (mem_s1_rd == ex_rs1_addr);
    assign ex_rs2_s1_mem_hit = ex_alu_src2_is_rs2 & mem_s1_valid & mem_s1_reg_write_en
                              & (mem_s1_rd != 5'd0) & (mem_s1_rd == ex_rs2_addr);
    assign ex_rs1_s0_mem_hit = ex_alu_src1_is_rs1 & mem_valid & mem_reg_write_en
                              & ~mem_mem_read_en & (mem_rd != 5'd0)
                              & (mem_rd == ex_rs1_addr);
    assign ex_rs2_s0_mem_hit = ex_alu_src2_is_rs2 & mem_valid & mem_reg_write_en
                              & ~mem_mem_read_en & (mem_rd != 5'd0)
                              & (mem_rd == ex_rs2_addr);

    assign ex_alu_src1_repair = ex_rs1_s1_mem_hit ? mem_s1_fwd_val :
                                ex_rs1_s0_mem_hit ? mem_fwd_val    :
                                ex_rs1_wb_repair  ? wb_write_data  :
                                                     ex_alu_src1;
    assign ex_alu_src2_repair = ex_rs2_s1_mem_hit ? mem_s1_fwd_val :
                                ex_rs2_s0_mem_hit ? mem_fwd_val    :
                                ex_rs2_wb_repair  ? wb_write_data  :
                                                     ex_alu_src2;
    assign ex_result_late = ex_rs1_wb_repair | ex_rs2_wb_repair
                          | ex_rs1_s1_mem_hit | ex_rs2_s1_mem_hit
                          | ex_rs1_s0_mem_hit | ex_rs2_s0_mem_hit;
    assign ex_forward_result = ex_is_csr    ? ex_csr_rdata :
                               ex_is_muldiv ? ex_muldiv_result :
                                              alu_forward_result;
    assign ex_pipe_alu_result = ex_is_csr    ? ex_csr_rdata :
                                ex_is_muldiv ? ex_muldiv_result :
                                               alu_result;

    branch_condition u_s1_branch_condition (
        .rs1_data   (ex_s1_rs1_data),
        .rs2_data   (ex_s1_rs2_data),
        .branch_cond(ex_s1_branch_cond),
        .taken      (ex_s1_branch_taken)
    );

    assign ex_s1_branch_target = alu_s1_result;
    assign ex_s1_branch_redirect = ex_s1_valid & ex_s1_is_branch
                                 & ex_s1_branch_taken
                                 & (ex_s1_branch_target != ex_s1_pc_plus_4)
                                 & ~mem_branch_flush
                                 & ex_ready_go & mem_allowin;
    assign ex_registered_branch_flush = ex_branch_redirect
                                      | ex_system_redirect
                                      | ex_s1_branch_redirect;
    assign ex_registered_branch_target = ex_branch_redirect ? branch_target :
                                         ex_system_redirect ? ex_system_target :
                                                              ex_s1_branch_target;

endmodule
