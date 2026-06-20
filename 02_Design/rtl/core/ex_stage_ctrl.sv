// ============================================================
// Module: ex_stage_ctrl
// Description: EX-stage local glue for repair/result muxing and S1 redirect.
// ============================================================

module ex_stage_ctrl (
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_s1_pc,
    input  logic        ex_valid,

    input  logic        ex_rs1_wb_repair,
    input  logic        ex_rs2_wb_repair,
    input  logic        ex_rs1_wb_repair_s1,
    input  logic        ex_rs2_wb_repair_s1,
    input  logic [31:0] wb_load_data,
    input  logic [31:0] wb_s1_load_data,
    input  logic [31:0] ex_alu_src1,
    input  logic [31:0] ex_alu_src2,
    input  logic        ex_alu_src1_is_rs1,
    input  logic        ex_alu_src2_is_rs2,
    input  logic [31:0] ex_rs1_data,
    input  logic [31:0] ex_rs2_data,

    input  logic        ex_is_branch,
    input  logic        ex_is_jal,
    input  logic        ex_is_jalr,
    input  logic        ex_is_csr,
    input  logic [31:0] ex_csr_rdata,
    input  logic        ex_is_muldiv,
    input  logic [31:0] ex_muldiv_result,
    input  logic [31:0] alu_result,

    input  logic        ex_s1_valid,
    input  logic        ex_s1_is_branch,
    input  logic        ex_s1_is_jal,
    input  logic        ex_s1_is_jalr,
    input  logic [ 2:0] ex_s1_branch_cond,
    input  logic        ex_s1_rs1_wb_repair,
    input  logic        ex_s1_rs2_wb_repair,
    input  logic        ex_s1_rs1_wb_repair_s1,
    input  logic        ex_s1_rs2_wb_repair_s1,
    input  logic [31:0] ex_s1_alu_src1,
    input  logic [31:0] ex_s1_alu_src2,
    input  logic        ex_s1_alu_src1_is_rs1,
    input  logic        ex_s1_alu_src2_is_rs2,
    input  logic [31:0] ex_s1_rs1_data,
    input  logic [31:0] ex_s1_rs2_data,
    input  logic        ex_s1_predicted_taken,
    input  logic [31:0] ex_s1_predicted_target,

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
    output logic [31:0] ex_s1_alu_src1_repair,
    output logic [31:0] ex_s1_alu_src2_repair,
    output logic [31:0] ex_rs1_data_repair,
    output logic [31:0] ex_rs2_data_repair,
    output logic [31:0] ex_s1_rs1_data_repair,
    output logic [31:0] ex_s1_rs2_data_repair,
    output logic [31:0] ex_forward_result,
    output logic [31:0] ex_pipe_alu_result,
    output logic [31:0] ex_control_target,
    output logic [31:0] ex_s1_branch_target,
    output logic        ex_s1_actual_taken,
    output logic        ex_s1_branch_redirect,
    output logic        ex_registered_branch_flush,
    output logic [31:0] ex_registered_branch_target
);

    wire ex_s1_branch_taken;
    wire ex_s0_control_valid;
    wire ex_s1_control_valid;

    assign ex_pc_plus_4 = ex_pc + 32'd4;
    assign ex_s1_pc_plus_4 = ex_s1_pc + 32'd4;

    wire [31:0] ex_rs1_wb_repair_data = ex_rs1_wb_repair_s1
                                       ? wb_s1_load_data
                                       : wb_load_data;
    wire [31:0] ex_rs2_wb_repair_data = ex_rs2_wb_repair_s1
                                       ? wb_s1_load_data
                                       : wb_load_data;
    wire [31:0] ex_s1_rs1_wb_repair_data = ex_s1_rs1_wb_repair_s1
                                          ? wb_s1_load_data
                                          : wb_load_data;
    wire [31:0] ex_s1_rs2_wb_repair_data = ex_s1_rs2_wb_repair_s1
                                          ? wb_s1_load_data
                                          : wb_load_data;

    assign ex_alu_src1_repair = (ex_rs1_wb_repair & ex_alu_src1_is_rs1)
                              ? ex_rs1_wb_repair_data
                              : ex_alu_src1;
    assign ex_alu_src2_repair = (ex_rs2_wb_repair & ex_alu_src2_is_rs2)
                              ? ex_rs2_wb_repair_data
                              : ex_alu_src2;
    assign ex_s1_alu_src1_repair =
        (ex_s1_rs1_wb_repair & ex_s1_alu_src1_is_rs1) ? ex_s1_rs1_wb_repair_data :
                                                         ex_s1_alu_src1;
    assign ex_s1_alu_src2_repair =
        (ex_s1_rs2_wb_repair & ex_s1_alu_src2_is_rs2) ? ex_s1_rs2_wb_repair_data :
                                                         ex_s1_alu_src2;
    assign ex_rs1_data_repair = ex_rs1_wb_repair ? ex_rs1_wb_repair_data :
                                                    ex_rs1_data;
    assign ex_rs2_data_repair = ex_rs2_wb_repair ? ex_rs2_wb_repair_data :
                                                    ex_rs2_data;
    assign ex_s1_rs1_data_repair = ex_s1_rs1_wb_repair ? ex_s1_rs1_wb_repair_data :
                                                           ex_s1_rs1_data;
    assign ex_s1_rs2_data_repair = ex_s1_rs2_wb_repair ? ex_s1_rs2_wb_repair_data :
                                                           ex_s1_rs2_data;
    assign ex_forward_result = ex_is_csr    ? ex_csr_rdata :
                               ex_is_muldiv ? ex_muldiv_result :
                                              alu_result;
    assign ex_pipe_alu_result = ex_is_csr    ? ex_csr_rdata :
                                ex_is_muldiv ? ex_muldiv_result :
                                               alu_result;

    // Keep S0 and S1 targets physically separate. The issue rules make their
    // CFI paths mutually exclusive, but STA still times any shared mux output
    // into both redirect checkers.
    wire [31:0] ex_control_target_sum = ex_alu_src1_repair
                                      + ex_alu_src2_repair;
    assign ex_control_target = ex_is_jalr
                             ? {ex_control_target_sum[31:1], 1'b0}
                             : ex_control_target_sum;

    wire [31:0] ex_s1_control_target_sum = ex_s1_alu_src1_repair
                                         + ex_s1_alu_src2_repair;
    wire [31:0] ex_s1_control_target = ex_s1_is_jalr
                                      ? {ex_s1_control_target_sum[31:1], 1'b0}
                                      : ex_s1_control_target_sum;

    branch_condition u_s1_branch_condition (
        .rs1_data   (ex_s1_rs1_data_repair),
        .rs2_data   (ex_s1_rs2_data_repair),
        .branch_cond(ex_s1_branch_cond),
        .taken      (ex_s1_branch_taken)
    );

    wire ex_s1_actual_taken_w = ex_s1_is_jal
                              | ex_s1_is_jalr
                              | (ex_s1_is_branch & ex_s1_branch_taken);
    assign ex_s0_control_valid = ex_valid
                                & (ex_is_branch | ex_is_jal | ex_is_jalr);
    assign ex_s1_control_valid = ex_s1_valid
                                & (ex_s1_is_branch | ex_s1_is_jal
                                 | ex_s1_is_jalr);
    wire ex_s1_direction_wrong =
        ex_s1_actual_taken_w != ex_s1_predicted_taken;
    wire ex_s1_target_wrong = ex_s1_actual_taken_w
                            & ex_s1_predicted_taken
                            & (ex_s1_control_target
                               != ex_s1_predicted_target);
    wire ex_s1_mispredict = ex_s1_direction_wrong | ex_s1_target_wrong;
    wire [31:0] ex_s1_redirect_target = ex_s1_actual_taken_w
                                      ? ex_s1_control_target
                                      : ex_s1_pc_plus_4;

    assign ex_s1_branch_target = ex_s1_control_target;
    assign ex_s1_actual_taken = ex_s1_actual_taken_w;
    assign ex_s1_branch_redirect = ex_s1_valid
                                 & ex_s1_mispredict
                                 & ~mem_branch_flush
                                 & ex_ready_go & mem_allowin;
    assign ex_registered_branch_flush = ex_branch_redirect
                                      | ex_system_redirect
                                      | ex_s1_branch_redirect;
    // The target payload is ignored unless ex_registered_branch_flush is high.
    // Keep the late branch_flush/mispredict result out of this wide mux.
    assign ex_registered_branch_target =
        ex_system_redirect ? ex_system_target :
        (ex_s1_control_valid & ~ex_s0_control_valid) ? ex_s1_redirect_target :
                                                       branch_target;

endmodule
