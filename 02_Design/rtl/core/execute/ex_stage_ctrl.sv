// ============================================================
// Module: ex_stage_ctrl
// Description: EX-stage local glue for repair/result muxing and S1 redirect.
// Domain: execute.
// ============================================================

module ex_stage_ctrl
    import cpu_defs::*;
(
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_s1_pc,
    input  logic        ex_valid,

    input  logic        ex_rs1_wb_repair,
    input  logic        ex_rs2_wb_repair,
    input  logic [31:0] wb_load_data,
    input  logic [31:0] ex_alu_src1,
    input  logic [31:0] ex_alu_src2,
    input  logic        ex_alu_src1_wb_repair,
    input  logic        ex_alu_src2_wb_repair,
    input  logic [31:0] ex_rs1_data,
    input  logic [31:0] ex_rs2_data,

    input  control_flow_t ex_control_flow,
    input  logic [ 1:0] ex_target_clear_mask,
    input  logic        ex_is_priv_reg,
    input  logic [31:0] ex_priv_rdata,
    input  logic        ex_is_muldiv,
    input  logic [31:0] ex_muldiv_result,
    input  logic [31:0] alu_result,

    input  logic        ex_s1_valid,
    input  control_flow_t ex_s1_control_flow,
    input  branch_op_t    ex_s1_branch_op,
    input  logic [ 1:0]   ex_s1_target_clear_mask,
    input  logic        ex_s1_rs1_wb_repair,
    input  logic        ex_s1_rs2_wb_repair,
    input  logic [31:0] ex_s1_alu_src1,
    input  logic [31:0] ex_s1_alu_src2,
    input  logic        ex_s1_alu_src1_wb_repair,
    input  logic        ex_s1_alu_src2_wb_repair,
    input  logic [31:0] ex_s1_rs1_data,
    input  logic [31:0] ex_s1_rs2_data,
    input  logic        ex_s1_predicted_taken,
    input  logic [31:0] ex_s1_predicted_target,
    input  logic        ex_s1_addr_replay,

    input  logic        mem_branch_flush,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        ex_branch_redirect,
    input  logic [31:0] branch_target,
    input  logic        ex_priv_redirect,
    input  logic [31:0] ex_priv_target,

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

    assign ex_pc_plus_4 = ex_pc + 32'd4;
    assign ex_s1_pc_plus_4 = ex_s1_pc + 32'd4;

    // WB repair replaces only operands that originally came from rs1/rs2.
    // PC/zero/immediate operands must remain unchanged.
    assign ex_alu_src1_repair = ex_alu_src1_wb_repair ? wb_load_data
                                                       : ex_alu_src1;
    assign ex_alu_src2_repair = ex_alu_src2_wb_repair ? wb_load_data
                                                       : ex_alu_src2;
    assign ex_s1_alu_src1_repair = ex_s1_alu_src1_wb_repair
                                 ? wb_load_data : ex_s1_alu_src1;
    assign ex_s1_alu_src2_repair = ex_s1_alu_src2_wb_repair
                                 ? wb_load_data : ex_s1_alu_src2;
    assign ex_rs1_data_repair = ex_rs1_wb_repair ? wb_load_data :
                                                    ex_rs1_data;
    assign ex_rs2_data_repair = ex_rs2_wb_repair ? wb_load_data :
                                                    ex_rs2_data;
    assign ex_s1_rs1_data_repair = ex_s1_rs1_wb_repair ? wb_load_data :
                                                           ex_s1_rs1_data;
    assign ex_s1_rs2_data_repair = ex_s1_rs2_wb_repair ? wb_load_data :
                                                           ex_s1_rs2_data;
    // Forward the architectural writeback value, not always the ALU output.
    // Compute independent candidates in parallel and keep the late result
    // selection as a shallow AND-OR mux. These instruction classes are
    // mutually exclusive by decode.
    wire ex_uses_forward_special_result = ex_is_priv_reg | ex_is_muldiv;
    wire [31:0] ex_forward_selected_result =
        ({32{ex_is_priv_reg}}   & ex_priv_rdata)
      | ({32{ex_is_muldiv}}     & ex_muldiv_result)
      | ({32{~ex_uses_forward_special_result}} & alu_result);
    assign ex_forward_result = ex_forward_selected_result;
    assign ex_pipe_alu_result = ex_forward_selected_result;

    // Keep S0 and S1 targets physically separate. The issue rules make their
    // CFI paths mutually exclusive, but STA still times any shared mux output
    // into both redirect checkers.
    wire [31:0] ex_control_target_sum = ex_alu_src1_repair
                                      + ex_alu_src2_repair;
    assign ex_control_target = ex_control_target_sum
                             & ~{30'd0, ex_target_clear_mask};

    wire [31:0] ex_s1_control_target_sum = ex_s1_alu_src1_repair
                                         + ex_s1_alu_src2_repair;
    wire [31:0] ex_s1_control_target = ex_s1_control_target_sum
                                     & ~{30'd0, ex_s1_target_clear_mask};

    branch_condition u_s1_branch_condition (
        .src0_data (ex_s1_rs1_data_repair),
        .src1_data (ex_s1_rs2_data_repair),
        .branch_op (ex_s1_branch_op),
        .taken     (ex_s1_branch_taken)
    );

    wire ex_s1_is_conditional = ex_s1_control_flow == CF_CONDITIONAL;
    wire ex_s1_is_unconditional = (ex_s1_control_flow == CF_DIRECT)
                                  | (ex_s1_control_flow == CF_INDIRECT);
    wire ex_s1_actual_taken_w = ex_s1_is_unconditional
                              | (ex_s1_is_conditional & ex_s1_branch_taken);
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
    // A misaligned Slot-1 LSU is replayed from its own PC.  It then becomes
    // Slot 0 and enters the ISA-owned precise exception path after the older
    // instruction in this pair has retired.
    wire ex_s1_addr_replay_redirect = ex_valid & ex_s1_valid
                                    & ex_s1_addr_replay
                                    & ~mem_branch_flush
                                    & ex_ready_go & mem_allowin;
    assign ex_registered_branch_flush = ex_branch_redirect
                                      | ex_priv_redirect
                                      | ex_s1_branch_redirect
                                      | ex_s1_addr_replay_redirect;
    // Select by the redirect source, not by the decoded CFI class. A false
    // positive BTB hit deliberately redirects even when the decoded operation
    // is CF_NONE. In particular, an S1 false positive must resume at S1+4;
    // using decoded control validity here would incorrectly select S0+4 and
    // re-execute S1. S0 has age priority if both slots request repair.
    assign ex_registered_branch_target =
        ex_priv_redirect ? ex_priv_target :
        ex_branch_redirect ? branch_target :
        ex_s1_addr_replay_redirect ? ex_s1_pc : ex_s1_redirect_target;

endmodule
