// ============================================================
// 中文说明：计算直接跳转和间接跳转的目标地址，并输出 EX 阶段的控制流结果。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：branch_unit
// 说明：在 EX 阶段计算分支/跳转结果，并检测预测错误。
// 所属阶段：execute。
// 使用预测时，比较预测结果与实际结果；只有预测错误才清空流水线，
// 不会因为每次实际跳转都清空。EX 只输出方向和修复控制，MEM 再选择最终重取 PC。
// 规格说明：02_Design/spec/branch_unit_spec.md。
// ============================================================

module branch_unit
    import cpu_defs::*;
(
    input  logic [31:0] target_pc,
    input  logic [31:0] src0_data,
    input  logic [31:0] src1_data,
    input  control_flow_t control_flow,
    input  branch_op_t    branch_op,
    input  logic        ex_valid,

    // 来自流水线（IF -> ID -> EX）的预测信息。
    input  logic        predicted_taken,
    input  logic [31:0] predicted_target,

    // 流水线清空输出。
    output logic        branch_flush,

    // 实际执行结果（供预测器更新）。
    output logic        actual_taken,
    output logic [31:0] actual_target     // 实际目标地址
);

    wire branch_taken;

    // 条件分支使用比较器结果；跳转指令无条件视为跳转。
    branch_condition u_branch_condition (
        .src0_data (src0_data),
        .src1_data (src1_data),
        .branch_op (branch_op),
        .taken     (branch_taken)
    );

    // ---- 实际结果 ----
    wire is_conditional = control_flow == CF_CONDITIONAL;
    wire is_unconditional = (control_flow == CF_DIRECT)
                          | (control_flow == CF_INDIRECT);
    assign actual_taken = is_unconditional | (is_conditional & branch_taken);
    assign actual_target = target_pc;

    // ---- 预测错误检测 ----
    // 情况 1：预测方向错误。
    // 情况 2：预测和实际都跳转，但目标地址错误。
    // 时序上，将 EX 比较结果作为末级 MUX 选择信号，避免在重定向路径上
    // 同时经过 XOR 和 target-wrong 的 OR 逻辑树。
    wire target_mismatch = (target_pc != predicted_target);
    wire direction_to_target = actual_taken & ~predicted_taken;
    wire direction_to_fallthrough = ~actual_taken & predicted_taken;
    wire target_mismatch_flush = actual_taken & predicted_taken & target_mismatch;

    // 分支重定向不进入同周期的 IROM 地址路径；所有分支预测错误都从
    // 已寄存的 EX/MEM 重定向信息出发，下一拍重新取指。
    assign branch_flush = ex_valid & (direction_to_target
                                    | direction_to_fallthrough
                                    | target_mismatch_flush);

endmodule
