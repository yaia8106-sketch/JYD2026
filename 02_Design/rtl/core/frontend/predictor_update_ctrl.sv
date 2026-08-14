// ============================================================
// 中文说明：根据已确认的分支结果更新方向预测器和 ABTB，并屏蔽错误路径上的更新。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：predictor_update_ctrl。
// 说明：选择一条已经确认的 CFI，并生成 ABTB/PHT 更新。
// 所属阶段：frontend。
// 发射策略保证每个发射组最多只有一个 slot 包含 CFI。
// ============================================================

module predictor_update_ctrl
    import cpu_defs::*;
(
    input  logic               clk,
    input  logic               rst_n,

    input  logic               ex_ready_go,
    input  logic               mem_allowin,
    input  logic               mem_branch_flush, // MEM redirect 抑制错误路径上的新训练事件

    // 每个结构体同时携带 EX 实际结果和预测时保存的 metadata。
    input  predictor_resolve_t slot0_resolve,
    input  predictor_resolve_t slot1_resolve,

    output logic               slot0_cfi_valid,
    output logic               slot1_cfi_valid,
    output predictor_train_t   train,
    output abtb_update_t       abtb_update,
    output pht_update_t        pht_update,

    // 已寄存的预测器写事件。上面的原始输出仍与 EX 对齐，用于重定向和观测；
    // 只有这些事件会真正修改 ABTB/PHT/GHR。
    // 真正的 write 事件相对 EX 延后一拍。
    output abtb_update_t       abtb_write,
    output pht_update_t        pht_write
);

    wire slot0_cfi_candidate = slot0_resolve.valid
                             & (slot0_resolve.is_conditional_branch
                              | slot0_resolve.is_direct_jump
                              | slot0_resolve.is_indirect_jump);
    wire slot1_cfi_candidate = slot1_resolve.valid
                             & (slot1_resolve.is_conditional_branch
                              | slot1_resolve.is_direct_jump
                              | slot1_resolve.is_indirect_jump);
    // frontend_pair_policy 已拒绝两个 CFI 的配对，Slot0 JALR 也被强制单发。
    // 这里仍让两个 slot 独立处理，使一个 slot 的 CFI 译码不会进入另一个
    // slot 的预测器写使能路径；下面的断言在仿真中保护这个流水线不变量。
    wire slot0_selected = slot0_cfi_candidate;
    wire slot1_selected = slot1_cfi_candidate;
    wire update_fire = ex_ready_go & mem_allowin & ~mem_branch_flush;

    // 在最终优先级选择之前分别筛选每个 slot。
    // 特别是 Slot1 的 actual_taken 不再先经过 selected type/actual MUX，
    // 而是直接进入 ABTB update-valid 判断。
    wire slot0_is_abtb_branch =
        slot0_resolve.update_cfi_type == CFI_TYPE_BRANCH;
    wire slot1_is_abtb_branch =
        slot1_resolve.update_cfi_type == CFI_TYPE_BRANCH;
    wire slot0_abtb_qualified = slot0_resolve.update_qualified
                              & (~slot0_is_abtb_branch
                                 | slot0_resolve.actual_taken);
    wire slot1_abtb_qualified = slot1_resolve.update_qualified
                              & (~slot1_is_abtb_branch
                                 | slot1_resolve.actual_taken);
    // update_qualified 只对可以训练预测器的 CFI 产生，因此不需要再增加
    // 一个重复的控制流类别候选门。
    wire slot0_abtb_fire = update_fire & slot0_resolve.valid
                         & slot0_abtb_qualified;
    wire slot1_abtb_fire = update_fire & slot1_resolve.valid
                         & slot1_abtb_qualified;
    wire slot0_pht_fire = update_fire & slot0_resolve.valid
                        & slot0_resolve.is_conditional_branch;
    wire slot1_pht_fire = update_fire & slot1_resolve.valid
                        & slot1_resolve.is_conditional_branch;

    assign slot0_cfi_valid = slot0_cfi_candidate;
    assign slot1_cfi_valid = slot1_cfi_candidate;

    // 每周期只有一条 CFI 训练预测器。由于两个 slot 的 CFI 有效条件互斥，
    // 这里保持 one-hot 选择，不需要跨 slot 的优先级依赖。
    always_comb begin
        train = '0;
        abtb_update = '0;
        pht_update = '0;
        train.from_slot1 = slot1_selected;
        train.valid = update_fire & (slot0_selected | slot1_selected);

        if (slot1_selected) begin
            train.pc = slot1_resolve.pc;
            train.is_conditional_branch = slot1_resolve.is_conditional_branch;
            train.is_direct_jump = slot1_resolve.is_direct_jump;
            train.is_indirect_jump = slot1_resolve.is_indirect_jump;
            train.actual_taken = slot1_resolve.actual_taken;
            train.actual_target = slot1_resolve.actual_target;
            abtb_update.hit = slot1_resolve.abtb_hit;
            abtb_update.way = slot1_resolve.abtb_way;
            abtb_update.cfi_type = slot1_resolve.update_cfi_type;
            pht_update.index = slot1_resolve.pht_index;
            pht_update.counter = slot1_resolve.pht_counter;
        end else begin
            train.pc = slot0_resolve.pc;
            train.is_conditional_branch = slot0_resolve.is_conditional_branch;
            train.is_direct_jump = slot0_resolve.is_direct_jump;
            train.is_indirect_jump = slot0_resolve.is_indirect_jump;
            train.actual_taken = slot0_resolve.actual_taken;
            train.actual_target = slot0_resolve.actual_target;
            abtb_update.hit = slot0_resolve.abtb_hit;
            abtb_update.way = slot0_resolve.abtb_way;
            abtb_update.cfi_type = slot0_resolve.update_cfi_type;
            pht_update.index = slot0_resolve.pht_index;
            pht_update.counter = slot0_resolve.pht_counter;
        end

        abtb_update.valid = slot0_abtb_fire | slot1_abtb_fire;
        abtb_update.pc = train.pc;
        abtb_update.target = train.actual_target;

        pht_update.valid = slot0_pht_fire | slot1_pht_fire;
        pht_update.actual_taken = train.actual_taken;
    end

    // EX 确认和前端预测器状态之间有真实的时钟边界。payload 字段故意自由运行；
    // 复位和末级错误路径抑制只影响 valid。事件一旦捕获，下一拍必须写入，
    // 即使这时又出现了新的 MEM 重定向。
    // 该流水线每周期可接受一个事件，因此连续 CFI 在不增加队列和反压路径的
    // 情况下仍保持原有程序顺序。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            abtb_write.valid <= 1'b0;
            pht_write.valid  <= 1'b0;
        end else begin
            abtb_write.valid <= abtb_update.valid;
            pht_write.valid  <= pht_update.valid;
        end

        abtb_write.hit      <= abtb_update.hit;
        abtb_write.way      <= abtb_update.way;
        abtb_write.pc       <= abtb_update.pc;
        abtb_write.cfi_type <= abtb_update.cfi_type;
        abtb_write.target   <= abtb_update.target;

        pht_write.index        <= pht_update.index;
        pht_write.counter      <= pht_update.counter;
        pht_write.actual_taken <= pht_update.actual_taken;
    end

`ifndef SYNTHESIS
    abtb_update_t expected_abtb_write;
    pht_update_t  expected_pht_write;

    always @(posedge clk) begin
        if (rst_n && slot0_cfi_valid && slot1_cfi_valid)
            $error("Single predictor update port saw simultaneous slot0 and slot1 control flow");
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            expected_abtb_write <= '0;
            expected_pht_write  <= '0;
        end else begin
            if (abtb_write.valid !== expected_abtb_write.valid)
                $error("ABTB write event is not exactly one cycle after EX capture");
            if (pht_write.valid !== expected_pht_write.valid)
                $error("PHT write event is not exactly one cycle after EX capture");
            if (expected_abtb_write.valid
                && (abtb_write !== expected_abtb_write))
                $error("Registered ABTB write payload changed across the boundary");
            if (expected_pht_write.valid
                && (pht_write !== expected_pht_write))
                $error("Registered PHT write payload changed across the boundary");

            expected_abtb_write <= abtb_update;
            expected_pht_write  <= pht_update;
        end
    end
`endif

endmodule
