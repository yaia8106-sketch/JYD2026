// ============================================================
// 中文说明：整理 EX 阶段确认后的分支结果，形成预测器更新所需的统一信息。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：predictor_resolve_builder。
// 说明：纯组合的构造模块，将 EX 阶段确认/更新信息打包成预测器结构体。
// 所属阶段：frontend。
// 更新仲裁和架构状态仍由 predictor_update_ctrl 负责。
// ============================================================

module predictor_resolve_builder
    import cpu_defs::*;
(
    input  logic                   s0_valid,
    input  logic [31:0]            s0_pc,
    input  logic                   s0_is_conditional_control,
    input  logic                   s0_is_direct_control,
    input  logic                   s0_is_indirect_control,
    input  logic                   s0_actual_taken,
    input  logic [31:0]            s0_actual_target,
    input  logic                   s0_update_qualified,
    input  logic [ 1:0]            s0_update_cfi_type,
    input  logic                   s0_abtb_hit,
    input  logic                   s0_abtb_way,
    input  logic [ 7:0]            s0_pht_index,
    input  logic [ 1:0]            s0_pht_counter,

    input  logic                   s1_valid,
    input  logic [31:0]            s1_pc,
    input  logic                   s1_is_conditional_control,
    input  logic                   s1_is_direct_control,
    input  logic                   s1_is_indirect_control,
    input  logic                   s1_actual_taken,
    input  logic [31:0]            s1_actual_target,
    input  logic                   s1_update_qualified,
    input  logic [ 1:0]            s1_update_cfi_type,
    input  logic                   s1_abtb_hit,
    input  logic                   s1_abtb_way,
    input  logic [ 7:0]            s1_pht_index,
    input  logic [ 1:0]            s1_pht_counter,

    output predictor_resolve_t     slot0_resolve,
    output predictor_resolve_t     slot1_resolve
);

    // 将 EX 的实际结果与预测时保存的元数据组合，形成单一预测器更新端口
    // 所需的结构体。
    always_comb begin
        slot0_resolve = '0;
        slot0_resolve.valid = s0_valid;
        slot0_resolve.pc = s0_pc;
        slot0_resolve.is_conditional_branch =
            s0_is_conditional_control;
        slot0_resolve.is_direct_jump = s0_is_direct_control;
        slot0_resolve.is_indirect_jump = s0_is_indirect_control;
        slot0_resolve.actual_taken = s0_actual_taken;
        slot0_resolve.actual_target = s0_actual_target;
        slot0_resolve.update_qualified = s0_update_qualified;
        slot0_resolve.update_cfi_type = s0_update_cfi_type;
        slot0_resolve.abtb_hit = s0_abtb_hit;
        slot0_resolve.abtb_way = s0_abtb_way;
        slot0_resolve.pht_index = s0_pht_index;
        slot0_resolve.pht_counter = s0_pht_counter;

        slot1_resolve = '0;
        slot1_resolve.valid = s1_valid;
        slot1_resolve.pc = s1_pc;
        slot1_resolve.is_conditional_branch =
            s1_is_conditional_control;
        slot1_resolve.is_direct_jump = s1_is_direct_control;
        slot1_resolve.is_indirect_jump = s1_is_indirect_control;
        slot1_resolve.actual_taken = s1_actual_taken;
        slot1_resolve.actual_target = s1_actual_target;
        slot1_resolve.update_qualified = s1_update_qualified;
        slot1_resolve.update_cfi_type = s1_update_cfi_type;
        slot1_resolve.abtb_hit = s1_abtb_hit;
        slot1_resolve.abtb_way = s1_abtb_way;
        slot1_resolve.pht_index = s1_pht_index;
        slot1_resolve.pht_counter = s1_pht_counter;
    end

endmodule
