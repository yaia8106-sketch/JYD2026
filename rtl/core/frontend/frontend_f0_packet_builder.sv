// ============================================================
// 模块：frontend_f0_packet_builder
//
// 作用：把 ICache 返回的一次 64 位取指结果拆成两条 32 位指令，
//      再结合当前取指 PC、预译码结果和分支预测结果，生成送入 FQ
//      （Fetch Queue，取指队列）的两个表项。
//
// 本模块处在前端 F0 阶段，只整理和标记指令，不执行指令，也不修改
// 预测器或取指队列中的状态。slot0 和 slot1 分别表示一次取指包中的
// 第一条和第二条候选指令。
// ============================================================

module frontend_f0_packet_builder
    import cpu_defs::*;
(
    // ICache 已经接受本次取指结果时为 1。
    input  logic                       accept_base,
    // 本次 64 位取指包对应的起始 PC。start_pc[2] 决定当前 PC
    // 对应返回包的低 32 位还是高 32 位。
    input  logic [31:0]                start_pc,
    // 取指包中两个位置是否带有数据。bit[0] 对应 slot0，bit[1]
    // 对应 slot1；它只描述数据是否存在，不包含预测跳转带来的冲刷。
    input  logic [ 1:0]                base_mask,
    // 以 8 字节边界取回的两条 32 位指令。
    input  logic [63:0]                irom_data,
    // ICache 为包中两条指令保存的 7 位预译码信息，共 14 位。
    input  logic [13:0]                irom_predecode,

    // 分支预测器给出的本次取指预测信息。steer_taken 表示预测器
    // 认为某条控制流指令会跳转。
    input  logic                       steer_taken,
    // 预测是否来自 ABTB（地址分支目标表）。该信息会随指令保存，
    // 供后续确认预测结果时判断训练来源。
    input  logic                       steer_source_abtb,
    // 预测命中了取指包中的哪一个 bank。0 表示 slot0，1 表示 slot1。
    input  logic                       steer_bank,
    // 预测器判定的控制流指令类型。
    input  logic [ 1:0]                steer_cfi_type,
    // 预测跳转目标地址。预测未跳转时，slot0 使用顺序地址 PC+4，
    // slot1 不使用该地址。
    input  logic [31:0]                steer_target,
    // 两个预测 bank 的附加信息，包括 PHT 索引、计数器，以及该 bank
    // 是否拥有当前条件分支。
    input  frontend_f0_bank_meta_t     bank0_meta,
    input  frontend_f0_bank_meta_t     bank1_meta,

    // payload 表示取指包中确实带有对应位置的数据；valid 还要额外
    // 考虑 slot0 跳转对 slot1 的冲刷。
    output logic                       enq0_payload,
    output logic                       enq1_payload,
    output logic                       enq0_valid,
    output logic                       enq1_valid,
    // slot0 是静态禁止后续发射的指令，或者 slot0 被预测为跳转时，
    // slot1 不再进入 FQ。
    output logic                       kill_after_slot0,
    // 两个准备写入 FQ 的完整表项。
    output frontend_fq_entry_t         entry0,
    output frontend_fq_entry_t         entry1,
    // 供 FQ 配对检查使用的轻量级预译码信息。
    output frontend_pair_meta_t        pair_meta0,
    output frontend_pair_meta_t        pair_meta1
);

    // 取指接口按 8 字节对齐返回数据。当 start_pc[2] 为 1 时，
    // 当前 PC 指向返回包的高 32 位，因此低 32 位不属于本次取指；
    // slot1 用零填充，后面会被视为无效位置。这个处理与分支预测
    // 无关，不能和 kill_after_slot0 的冲刷逻辑混在一起。
    wire [31:0] slot0_inst = start_pc[2] ? irom_data[63:32]
                                          : irom_data[31:0];
    wire [31:0] slot1_inst = start_pc[2] ? 32'd0
                                          : irom_data[63:32];
    wire [31:0] slot0_pc = start_pc;
    wire [31:0] slot1_pc = start_pc + 32'd4;

    frontend_predecode_t slot0_effective_dec;
    frontend_predecode_t slot1_effective_dec;
    frontend_icache_predecode_t block0_cached_dec;
    frontend_icache_predecode_t block1_cached_dec;
    frontend_icache_predecode_t slot0_cached_dec;
    frontend_icache_predecode_t slot1_cached_dec;
    frontend_pair_meta_t slot0_pair_metadata;
    frontend_pair_meta_t slot1_pair_metadata;
    logic slot0_branch_owned;
    logic slot1_branch_owned;
    logic slot0_pred_taken;
    logic [31:0] slot0_pred_target;
    logic slot0_pred_source_abtb;
    logic slot1_pred_taken;
    logic [31:0] slot1_pred_target;
    logic slot1_pred_source_abtb;
    logic [7:0] slot0_pht_index;
    logic [1:0] slot0_pht_counter;

    assign block0_cached_dec = irom_predecode[6:0];
    assign block1_cached_dec = irom_predecode[13:7];
    assign slot0_cached_dec = start_pc[2] ? block1_cached_dec
                                           : block0_cached_dec;
    // start_pc[2] 为 1 时，按照指令地址定义，slot1 并不存在。
    // 这时它的内容不会被使用；把对应预译码控制清零，可以让这个
    // 无效表项保持确定值，避免无效数据参与后续组合逻辑。
    assign slot1_cached_dec = start_pc[2] ? '0 : block1_cached_dec;

    // 该位由 ICache 在装入 cache line 时保存，用于标记一条指令是否
    // 会禁止后面的指令继续进入当前发射组。这里单独取出它，避免
    // 为了判断 slot1 是否需要冲刷而重新展开完整的预译码信息。
    wire slot0_static_kill =
        slot0_cached_dec.inst_kind[ICACHE_KIND_STATIC_KILL_BIT];

    // ICache 已经保存了指令类别和少量属性。F0 只根据这些缓存的
    // 分类信息补出前端需要的语义位，而不是在同步 ICache 输出后
    // 再放置一个完整指令译码器。
    isa_cached_predecode_expand u_expand_slot0 (
        .inst          (slot0_inst),
        .cached        (slot0_cached_dec),
        .pred_taken    (slot0_pred_taken),
        .expanded      (slot0_effective_dec),
        .pair_metadata (slot0_pair_metadata)
    );

    isa_cached_predecode_expand u_expand_slot1 (
        .inst          (slot1_inst),
        .cached        (slot1_cached_dec),
        .pred_taken    (slot1_pred_taken),
        .expanded      (slot1_effective_dec),
        .pair_metadata (slot1_pair_metadata)
    );

    // 根据当前指令及预测信息组成一个完整的 FQ 表项。
    function automatic frontend_fq_entry_t make_entry(
        input logic                  valid,
        input logic [31:0]           pc,
        input logic [31:0]           inst,
        // decoded 是 F0 阶段已经得到的指令属性，随后会随表项进入 FQ。
        input frontend_predecode_t   decoded,
        input logic                  writes_dst,
        input logic                  force_single,
        input logic                  pred_taken,
        input logic [31:0]           pred_target,
        input logic                  pred_source_abtb,
        input logic                  branch_owned,
        input logic [1:0]            final_cfi_type,
        input logic [7:0]            pht_index,
        input logic [1:0]            pht_counter
    );
        begin
            make_entry = '0;
            make_entry.valid = valid;
            make_entry.pc = pc;
            make_entry.inst = inst;
            make_entry.pred_taken = pred_taken;
            make_entry.pred_target = pred_target;
            make_entry.pred_source_abtb = pred_source_abtb;
            make_entry.stage1_branch_owned = branch_owned;
            make_entry.pred_cfi_type = branch_owned
                                     ? CFI_TYPE_BRANCH
                                     : pred_taken
                                     ? final_cfi_type
                                     : 2'd0;
            make_entry.stage1_pht_index = pht_index;
            make_entry.stage1_pht_counter = pht_counter;
            make_entry.is_conditional_branch =
                decoded.is_conditional_branch;
            make_entry.is_direct_jump = decoded.is_direct_jump;
            make_entry.is_indirect_jump = decoded.is_indirect_jump;
            make_entry.is_privileged = decoded.is_privileged;
            make_entry.is_privileged_flow = decoded.is_privileged_flow;
            make_entry.is_fence = decoded.is_fence;
            make_entry.is_illegal = decoded.is_illegal;
            make_entry.is_muldiv = decoded.is_muldiv;
            make_entry.is_mul = decoded.is_mul;
            make_entry.is_load = decoded.is_load;
            make_entry.is_store = decoded.is_store;
            make_entry.is_alu_type = decoded.is_alu_type;
            make_entry.writes_dst = writes_dst;
            make_entry.uses_src0 = decoded.uses_src0;
            make_entry.uses_src1 = decoded.uses_src1;
            make_entry.is_jump = decoded.is_jump;
            make_entry.is_control = decoded.is_control;
            make_entry.is_lsu = decoded.is_lsu;
            make_entry.force_single = force_single;
        end
    endfunction

    // 统一计算两个 FQ 表项所需的预测字段、有效位和配对元数据。
    always_comb begin
        slot0_branch_owned =
            slot0_effective_dec.is_conditional_branch
            && (start_pc[2] ? bank1_meta.branch_owned
                            : bank0_meta.branch_owned);
        slot1_branch_owned =
            slot1_effective_dec.is_conditional_branch
            && !start_pc[2] && bank1_meta.branch_owned;

        slot0_pred_taken = steer_taken && (steer_bank == start_pc[2]);
        slot0_pred_target =
            slot0_pred_taken ? steer_target : (slot0_pc + 32'd4);
        slot0_pred_source_abtb = slot0_pred_taken && steer_source_abtb;
        slot1_pred_taken = steer_taken && !start_pc[2] && steer_bank;
        slot1_pred_target = slot1_pred_taken ? steer_target : 32'd0;
        slot1_pred_source_abtb = slot1_pred_taken && steer_source_abtb;

        if (start_pc[2]) begin
            slot0_pht_index = bank1_meta.pht_index;
            slot0_pht_counter = bank1_meta.pht_counter;
        end else begin
            slot0_pht_index = bank0_meta.pht_index;
            slot0_pht_counter = bank0_meta.pht_counter;
        end

        // slot0 如果是静态禁止后续发射的指令，或者预测为跳转，
        // slot1 就不能沿着当前顺序进入 FQ。这里仅清除 slot1 的
        // 有效位，不影响已经取回的数据总线。
        kill_after_slot0 =
            slot0_static_kill
            || slot0_pred_taken;
        enq0_payload = accept_base && base_mask[0];
        enq1_payload = accept_base && base_mask[1];
        enq0_valid = enq0_payload;
        enq1_valid = enq1_payload && !kill_after_slot0;

        // 生成 slot0 的完整 FQ 表项。
        entry0 = make_entry(
            enq0_valid,
            slot0_pc,
            slot0_inst,
            slot0_effective_dec,
            slot0_cached_dec.writes_dst,
            slot0_cached_dec.block_younger,
            slot0_pred_taken,
            slot0_pred_target,
            slot0_pred_source_abtb,
            slot0_branch_owned,
            steer_cfi_type,
            slot0_pht_index,
            slot0_pht_counter
        );
        entry1 = make_entry(
            enq1_valid,
            slot1_pc,
            slot1_inst,
            slot1_effective_dec,
            slot1_cached_dec.writes_dst,
            // slot1 是否允许占用第二发射位置，取决于它进入 FQ 时的
            // 配对位置，而不是指令本身永久携带的串行属性。因此这里
            // 保存 block_younger，保证一条以取指 slot1 进入 FQ 的乘法
            // 指令移动到队首后仍能保持正确的配对限制。
            slot1_cached_dec.block_younger,
            slot1_pred_taken,
            slot1_pred_target,
            slot1_pred_source_abtb,
            slot1_branch_owned,
            steer_cfi_type,
            // slot1 有效时，它始终对应预测器的 bank1。
            bank1_meta.pht_index,
            bank1_meta.pht_counter
        );

        pair_meta0 = slot0_pair_metadata;
        pair_meta1 = slot1_pair_metadata;
    end

endmodule
