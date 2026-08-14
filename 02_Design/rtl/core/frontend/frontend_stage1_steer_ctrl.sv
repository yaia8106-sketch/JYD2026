// ============================================================
// 中文说明：把一级方向预测、ABTB 目标和顺序 PC 组合成前端的取指方向选择。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_stage1_steer_ctrl。
// 说明：在两个 ABTB/PHT bank 之间完成规范 BP0 仲裁。
// 所属阶段：frontend。
// ============================================================

module frontend_stage1_steer_ctrl
    import cpu_defs::*;
(
    input  logic                   lookup_valid, // ftq_alloc_ready && fq_credit_for_bp0 && !redirect_valid
    input  logic [31:0]            current_pc,
    input  frontend_steer_bank_t   bank0,
    input  frontend_steer_bank_t   bank1,

    output logic                   bank0_branch_owned,
    output logic                   bank1_branch_owned,
    output frontend_steer_result_t steer
);

    wire [31:0] sequential_next_pc =
        current_pc + (current_pc[2] ? 32'd4 : 32'd8);

    wire bank0_direct = bank0.lookup_hit
        && ((bank0.cfi_type == CFI_TYPE_JUMP)
            || (bank0.cfi_type == CFI_TYPE_CALL));
    wire bank1_direct = bank1.lookup_hit
        && ((bank1.cfi_type == CFI_TYPE_JUMP)
            || (bank1.cfi_type == CFI_TYPE_CALL));
    assign bank0_branch_owned = bank0.lookup_hit
        && (bank0.cfi_type == CFI_TYPE_BRANCH);
    assign bank1_branch_owned = bank1.lookup_hit
        && (bank1.cfi_type == CFI_TYPE_BRANCH);

    wire bank0_valid = bank0_direct || bank0_branch_owned;
    wire bank1_valid = bank1_direct || bank1_branch_owned;
    wire bank0_taken = bank0_direct
        || (bank0_branch_owned && bank0.pred_taken);
    wire bank1_taken = bank1_direct
        || (bank1_branch_owned && bank1.pred_taken);

    // 只有取指块从第一个字开始时，bank0 才是更老的指令。
    // 在处理 32 位目标地址之前，先计算两个互斥的跳转候选项。
    // bank0 的分支预测为不跳转时，故意允许 bank1 的 CFI 跳转，
    // 这与原来的程序顺序策略一致。
    wire bank0_selected_taken = !current_pc[2] && bank0_taken;
    wire bank1_selected_taken = !bank0_selected_taken && bank1_taken;
    wire selected_taken = bank0_selected_taken || bank1_selected_taken;
    wire [31:0] selected_target_candidate = bank0_selected_taken
        ? bank0.target : bank1.target;
    wire [31:0] selected_next_pc = selected_taken
        ? selected_target_candidate : sequential_next_pc;

    wire first_valid = current_pc[2] ? bank1_valid : bank0_valid;
    wire first_taken = current_pc[2] ? bank1_taken : bank0_taken;
    wire [1:0] first_cfi_type = current_pc[2]
        ? bank1.cfi_type : bank0.cfi_type;

    // 目标和 next-PC 的选择与元数据记录相互独立。
    // 只有 steer.taken 为 1 时才会使用 steer.target，因此不跳转取指包中
    // 即使写入已选择的候选目标也没有影响；valid/taken 位独自决定该推测
    // payload 是否可见。
    always_comb begin
        steer = '0;
        steer.valid = lookup_valid;
        steer.source_abtb = selected_taken;
        steer.taken = selected_taken;
        steer.bank = current_pc[2];
        steer.target = selected_target_candidate;
        steer.next_pc = selected_next_pc;

        // 第一条分支预测不跳转时，即使更年轻的 bank1 CFI 提供跳转目标，
        // 第一条指令仍保持其程序顺序上的所有权。
        if (first_valid) begin
            steer.branch_owned = first_cfi_type == CFI_TYPE_BRANCH;
            steer.branch_owned_nt =
                (first_cfi_type == CFI_TYPE_BRANCH) && !first_taken;
            steer.cfi_type = first_cfi_type;
        end

        if (bank1_selected_taken) begin
            steer.bank = 1'b1;
            steer.cfi_type = bank1.cfi_type;
        end
    end

endmodule
