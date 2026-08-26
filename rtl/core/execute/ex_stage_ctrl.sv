// ============================================================
// 中文说明：组织 EX 阶段的执行选择、结果有效性、访存请求和跳转请求。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：ex_stage_ctrl
// 说明：组织 EX 阶段的 repair、结果 MUX 以及 S1 重定向控制。
// 所属阶段：execute。
// ============================================================

module ex_stage_ctrl
    import cpu_defs::*;
(
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_s1_pc,
    input  logic        ex_valid,

    input  logic        ex_rs1_wb_repair,
    input  logic        ex_rs2_wb_repair,
    input  logic [31:0] wb_load_data_ex_s0,
    input  logic [31:0] wb_load_data_ex_s1,
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
    input  logic        ex_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic        ex_branch_actual_taken,
    input  logic        ex_priv_redirect,
    input  logic        ex_priv_flow,

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
    output redirect_source_t ex_registered_redirect_source,
    output logic        ex_registered_redirect_actual_taken
);

    wire ex_s1_branch_taken;

    assign ex_pc_plus_4 = ex_pc + 32'd4;
    assign ex_s1_pc_plus_4 = ex_s1_pc + 32'd4;

    // WB 修复只替换原本来自 rs1/rs2 的操作数；PC、常数零和立即数
    // 这些来源不应被替换。
    assign ex_alu_src1_repair = ex_alu_src1_wb_repair
                              ? wb_load_data_ex_s0 : ex_alu_src1;
    assign ex_alu_src2_repair = ex_alu_src2_wb_repair
                              ? wb_load_data_ex_s0 : ex_alu_src2;
    assign ex_s1_alu_src1_repair = ex_s1_alu_src1_wb_repair
                                 ? wb_load_data_ex_s1 : ex_s1_alu_src1;
    assign ex_s1_alu_src2_repair = ex_s1_alu_src2_wb_repair
                                 ? wb_load_data_ex_s1 : ex_s1_alu_src2;
    assign ex_rs1_data_repair = ex_rs1_wb_repair
                              ? wb_load_data_ex_s0 : ex_rs1_data;
    assign ex_rs2_data_repair = ex_rs2_wb_repair
                              ? wb_load_data_ex_s0 : ex_rs2_data;
    assign ex_s1_rs1_data_repair = ex_s1_rs1_wb_repair
                                 ? wb_load_data_ex_s1 : ex_s1_rs1_data;
    assign ex_s1_rs2_data_repair = ex_s1_rs2_wb_repair
                                 ? wb_load_data_ex_s1 : ex_s1_rs2_data;
    // 前递架构写回值，而不是固定前递 ALU 输出。
    // 各候选结果并行计算，末级只保留浅层 AND-OR MUX；这些指令类别
    // 由译码保证互斥。
    wire ex_uses_forward_special_result = ex_is_priv_reg | ex_is_muldiv;
    wire [31:0] ex_forward_selected_result =
        ({32{ex_is_priv_reg}}   & ex_priv_rdata)
      | ({32{ex_is_muldiv}}     & ex_muldiv_result)
      | ({32{~ex_uses_forward_special_result}} & alu_result);
    assign ex_forward_result = ex_forward_selected_result;
    assign ex_pipe_alu_result = ex_forward_selected_result;

    // S0 和 S1 的目标地址通路保持物理分离。虽然发射规则保证两条控制流
    // 路径互斥，STA 仍会分析共享 MUX 输出到两个重定向检查点的路径。
    // 条件分支和直接跳转的目标是 PC + 立即数；JIRL 不允许携带 repair 标签。
    // 这里使用原始目标操作数，使新增的 WB-load-to-branch 比较器前递路径
    // 不会再进入两个 32 位目标加法器和重定向检查器。
    wire [31:0] ex_control_target_sum = ex_alu_src1 + ex_alu_src2;
    assign ex_control_target = ex_control_target_sum
                             & ~{30'd0, ex_target_clear_mask};

    wire [31:0] ex_s1_control_target_sum = ex_s1_alu_src1
                                         + ex_s1_alu_src2;
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
    wire ex_s1_target_mismatch = ex_s1_control_target
                               != ex_s1_predicted_target;

    // 直接根据比较器和预测结果构造重定向真值表候选项。
    // 旧路径先生成完整的 actual_taken，再依次生成 direction_wrong、
    // target_wrong，最后再 OR；现在三个候选项并行生成，只在分支比较之后
    // 保留一个 CFI 类别选择器。
    wire ex_s1_conditional_mispredict = ex_s1_branch_taken
        ? (~ex_s1_predicted_taken | ex_s1_target_mismatch)
        : ex_s1_predicted_taken;
    wire ex_s1_unconditional_mispredict = ~ex_s1_predicted_taken
                                        | ex_s1_target_mismatch;
    wire ex_s1_no_control_mispredict = ex_s1_predicted_taken;
    wire ex_s1_mispredict = ex_s1_is_conditional
        ? ex_s1_conditional_mispredict
        : ex_s1_is_unconditional
            ? ex_s1_unconditional_mispredict
            : ex_s1_no_control_mispredict;
    assign ex_s1_branch_target = ex_s1_control_target;
    assign ex_s1_actual_taken = ex_s1_actual_taken_w;
    assign ex_s1_branch_redirect = ex_s1_valid
                                 & ex_s1_mispredict
                                 & ~mem_branch_flush
                                 & ex_ready_go & mem_allowin;
    // Slot-1 LSU 地址未对齐时，从该指令自己的 PC 重新执行。
    // 重放后它会成为 Slot 0，并在同一发射组中更老的指令提交后进入
    // ISA 规定的精确异常路径。
    wire ex_s1_addr_replay_redirect = ex_valid & ex_s1_valid
                                    & ex_s1_addr_replay
                                    & ~mem_branch_flush
                                    & ex_ready_go & mem_allowin;
    wire ex_slot0_branch_request = ex_branch_flush & ~ex_priv_flow;
    wire ex_slot0_branch_redirect = ex_slot0_branch_request
                                  & ex_redirect_fire;
    assign ex_registered_branch_flush = ex_slot0_branch_redirect
                                      | ex_priv_redirect
                                      | ex_s1_branch_redirect
                                      | ex_s1_addr_replay_redirect;
    // 这里只寄存重定向来源和实际方向。MEM 从 EX/MEM payload 中已有的候选项
    // 选择最终 32 位 PC。
    // 对于 BTB 误命中的情况，即使译码结果为 CF_NONE，也要按设计进行重定向，
    // 因此来源选择必须使用原始 repair 请求，而不是译码出的 CFI 类别。
    // S0 年龄优先于 S1，同步特权流优先于两个发射槽。
    wire ex_s1_addr_replay_request = ex_valid & ex_s1_valid
                                   & ex_s1_addr_replay;
    always_comb begin
        ex_registered_redirect_source = REDIRECT_S1_CONTROL;
        ex_registered_redirect_actual_taken = ex_s1_actual_taken_w;

        if (ex_s1_addr_replay_request) begin
            ex_registered_redirect_source = REDIRECT_S1_REPLAY;
            ex_registered_redirect_actual_taken = 1'b0;
        end
        if (ex_slot0_branch_request) begin
            ex_registered_redirect_source = REDIRECT_S0_CONTROL;
            ex_registered_redirect_actual_taken = ex_branch_actual_taken;
        end
        if (ex_priv_flow) begin
            ex_registered_redirect_source = REDIRECT_PRIVILEGED;
            ex_registered_redirect_actual_taken = 1'b0;
        end
    end

endmodule
