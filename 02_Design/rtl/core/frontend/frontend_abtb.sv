// ============================================================
// 中文说明：实现地址分支目标表，保存分支 PC、目标地址和预测相关属性。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_abtb。
// “a”表示 ahead（提前查询），“btb”表示 branch target buffer（分支目标缓冲）。
// 说明：为一个 64 位取指块提供双 bank、两路组相联的提前查询 BTB。
// bank0 对应 block_pc，bank1 对应 block_pc + 4；两组都并行组合读出，
// 每周期最多写入一条已经确认的控制流指令更新。
// 方向预测和返回指令状态/方向由模块外部维护。
// ============================================================

module frontend_abtb #(
    parameter bit LOCAL_LOOKUP_INDEX = 1'b0,
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // 集成前端把规范取指 PC 状态观察到的同一个重定向送给 ABTB。
    // 独立使用时可以关闭本地查询索引状态，继续直接驱动 predict_pc。
    input  logic        redirect_valid,
    input  logic [31:0] redirect_target,

    // 一级查询。lookup_valid 同时作为 LRU 更新的有效条件。
    input  logic        lookup_valid,
    input  logic [31:0] predict_pc, // 当前预测 PC；模块内部同时派生顺序 PC。

    // 预留的 PHT/RAS 结果输入。J 类指令的方向由本地保存的 CFI 类型直接产生。
    input  logic        bank0_branch_taken,
    input  logic        bank1_branch_taken,
    input  logic        bank0_ret_valid,
    input  logic [31:0] bank0_ret_target,
    input  logic        bank1_ret_valid,
    input  logic [31:0] bank1_ret_target,

    // 每个 bank 的并行查询元数据。
    output logic        bank0_eligible, // predict_pc[2] 为 1 时，bank0 不参与预测
    output logic        bank0_lookup_hit, // pred_tag == bank0_tag 且 bank0_valid
    output logic        bank0_hit, // lookup_valid 且 bank0_lookup_hit
    output logic        bank0_way, // ~pred_pc[3]
    output logic [ 1:0] bank0_cfi_type, // JAL、JALR、BRANCH、RET
    output logic [31:0] bank0_abtb_pred_target, // 来自 ABTB RAM，尚未替换 RET 目标
    output logic        bank0_pred_taken,
    output logic [31:0] bank0_final_pred_target, // RET 时来自 RAS，否则来自 ABTB RAM

    output logic        bank1_eligible,
    output logic        bank1_lookup_hit,
    output logic        bank1_hit,
    output logic        bank1_way, // pred_pc[3]
    output logic [ 1:0] bank1_cfi_type,
    output logic [31:0] bank1_abtb_pred_target,
    output logic        bank1_pred_taken,
    output logic [31:0] bank1_final_pred_target,

    // 按程序顺序选择；两个候选都跳转时 bank0 优先。
    output logic        pred_taken,
    output logic        pred_bank,
    output logic [ 1:0] pred_cfi_type,
    output logic [31:0] pred_target,
    output logic [31:0] pred_next_pc, // pred_taken 为 1 时取 pred_target，否则取顺序 next PC
    // 不附加 lookup_valid 条件的预测结果。前端只在查询被接受时采样结果，
    // 这样接受/反压逻辑不会进入递归的 next-PC 数据通路。
    output logic [31:0] pred_next_pc_early,

    // 已确认更新端口。命中时使用预测阶段携带的 bank/way 元数据更新；
    // 未命中时由 valid/LRU 逻辑选择分配位置。
    input  logic        update_valid,
    input  logic        update_hit,
    // 注意：如果中间发生了替换，这些元数据可能过期。
    // 当前仍使用保存下来的位置更新；若位置已错误，结果会表现为预测错误。
    input  logic        update_way,
    input  logic [31:0] update_pc,
    input  logic [ 1:0] update_cfi_type,
    input  logic [31:0] update_target
);

    localparam int SETS = 32;
    localparam int SET_IDX_W = $clog2(SETS);
    // 比赛程序的地址分布需要比原来的 PC[13:7] tag 多保存两位地址。
    // 在 32 个 set 的配置中，PC[7:3] 选择 set，PC[16:8] 作为当前观察到的
    // 无别名九位 tag。
    localparam int TAG_W = 9;

    localparam int PAYLOAD_W = TAG_W + 2 + 32;
    localparam int TYPE_MSB = 33;
    localparam int TYPE_LSB = 32;

    // 查询有效位存放在一个紧凑的四位宽 LUTRAM 中。这样可以从递归 next-PC
    // 路径中移除四个需要复位的 32:1 FF MUX，同时让宽 payload RAM 只保留
    // 普通更新写端口。另有一个非关键路径镜像供 miss 分配使用。
    logic bank0_way0_alloc_valid [0:SETS-1];
    logic bank0_way1_alloc_valid [0:SETS-1];
    logic bank1_way0_alloc_valid [0:SETS-1];
    logic bank1_way1_alloc_valid [0:SETS-1];

    // 位顺序为 {bank1 way1, bank1 way0, bank0 way1, bank0 way0}。
    // 复位后只清除这个窄存储体；如果清除 44 位 payload 存储体，Vivado 会
    // 复制其 LUTRAM 实现，增加资源和布线。
    (* ram_style = "distributed" *)
    logic [3:0] lookup_valid_mem [0:SETS-1];

    // 每个 bank/way 的 payload 保持为一个紧凑的逻辑存储体。
    // 预测器训练在进入本模块前已经寄存，因此写使能不再包含曾经导致
    // payload 分块实验的后端 resolve/allow 逻辑链。
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank0_way0_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank0_way1_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank1_way0_payload [0:SETS-1];
    (* ram_style = "distributed" *)
    logic [PAYLOAD_W-1:0] bank1_way1_payload [0:SETS-1];

    // 当两路都有效时，表示下一次要替换的 way。
    logic bank0_lru [0:SETS-1];
    logic bank1_lru [0:SETS-1];

    wire [31:0] pred_lookup_block_pc = {predict_pc[31:3], 3'b000};
    wire [SET_IDX_W-1:0] canonical_lookup_set =
        pred_lookup_block_pc[3 +: SET_IDX_W];
    wire [TAG_W-1:0] pred_lookup_tag =
        pred_lookup_block_pc[3 + SET_IDX_W +: TAG_W];

    // PC[7:3] 同时驱动五个异步 LUTRAM 的地址位。由规范取指 PC 寄存器直接
    // 驱动所有地址引脚会形成剩余的高扇出递归时序路径。
    // 在集成核心中，为每个存储体保留一个小型、周期同步的本地索引状态。
    // 只复制索引；tag、target 和架构 PC 仍保持单份状态。
    wire [SET_IDX_W-1:0] bank0_way0_lookup_set;
    wire [SET_IDX_W-1:0] bank0_way1_lookup_set;
    wire [SET_IDX_W-1:0] bank1_way0_lookup_set;
    wire [SET_IDX_W-1:0] bank1_way1_lookup_set;
    wire [SET_IDX_W-1:0] valid_lookup_set;

    generate
        if (LOCAL_LOOKUP_INDEX) begin : g_local_lookup_index
            // KEEP 是有意且局部使用的：没有它，综合可能把五个等价的状态向量
            // 合并回原来的高扇出 PC 索引驱动器。
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank0_way0_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank0_way1_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank1_way0_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] bank1_way1_set_q;
            (* keep = "true" *) logic [SET_IDX_W-1:0] valid_set_q;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    bank0_way0_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank0_way1_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank1_way0_set_q <= RESET_PC[3 +: SET_IDX_W];
                    bank1_way1_set_q <= RESET_PC[3 +: SET_IDX_W];
                    valid_set_q <= RESET_PC[3 +: SET_IDX_W];
                end else if (redirect_valid) begin
                    bank0_way0_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank0_way1_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank1_way0_set_q <= redirect_target[3 +: SET_IDX_W];
                    bank1_way1_set_q <= redirect_target[3 +: SET_IDX_W];
                    valid_set_q <= redirect_target[3 +: SET_IDX_W];
                end else if (lookup_valid) begin
                    bank0_way0_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank0_way1_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank1_way0_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    bank1_way1_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                    valid_set_q <= pred_next_pc_early[3 +: SET_IDX_W];
                end
            end

            assign bank0_way0_lookup_set = bank0_way0_set_q;
            assign bank0_way1_lookup_set = bank0_way1_set_q;
            assign bank1_way0_lookup_set = bank1_way0_set_q;
            assign bank1_way1_lookup_set = bank1_way1_set_q;
            assign valid_lookup_set = valid_set_q;

`ifndef SYNTHESIS
            always_ff @(posedge clk) begin
                if (rst_n
                    && ({bank0_way0_set_q, bank0_way1_set_q,
                         bank1_way0_set_q, bank1_way1_set_q, valid_set_q}
                        !== {5{canonical_lookup_set}}))
                    $fatal(1, "ABTB local lookup indices diverged from fetch PC");
            end
`endif
        end else begin : g_direct_lookup_index
            assign bank0_way0_lookup_set = canonical_lookup_set;
            assign bank0_way1_lookup_set = canonical_lookup_set;
            assign bank1_way0_lookup_set = canonical_lookup_set;
            assign bank1_way1_lookup_set = canonical_lookup_set;
            assign valid_lookup_set = canonical_lookup_set;
        end
    endgenerate

    wire [PAYLOAD_W-1:0] bank0_way0_lookup_payload =
        bank0_way0_payload[bank0_way0_lookup_set];
    wire [PAYLOAD_W-1:0] bank0_way1_lookup_payload =
        bank0_way1_payload[bank0_way1_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way0_lookup_payload =
        bank1_way0_payload[bank1_way0_lookup_set];
    wire [PAYLOAD_W-1:0] bank1_way1_lookup_payload =
        bank1_way1_payload[bank1_way1_lookup_set];

    logic clear_active;
    logic [SET_IDX_W-1:0] clear_set_q;
    wire abtb_ready = ~clear_active;

    wire [3:0] lookup_valid_vector = lookup_valid_mem[valid_lookup_set];
    wire bank0_way0_lookup_valid = lookup_valid_vector[0];
    wire bank0_way1_lookup_valid = lookup_valid_vector[1];
    wire bank1_way0_lookup_valid = lookup_valid_vector[2];
    wire bank1_way1_lookup_valid = lookup_valid_vector[3];

    // TAG 字段。
    wire [TAG_W-1:0] bank0_way0_lookup_tag =
        bank0_way0_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank0_way1_lookup_tag =
        bank0_way1_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank1_way0_lookup_tag =
        bank1_way0_lookup_payload[PAYLOAD_W-1 -: TAG_W];
    wire [TAG_W-1:0] bank1_way1_lookup_tag =
        bank1_way1_lookup_payload[PAYLOAD_W-1 -: TAG_W];

    // TYPE 字段。
    wire [1:0] bank0_way0_lookup_type =
        bank0_way0_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank0_way1_lookup_type =
        bank0_way1_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank1_way0_lookup_type =
        bank1_way0_lookup_payload[TYPE_MSB:TYPE_LSB];
    wire [1:0] bank1_way1_lookup_type =
        bank1_way1_lookup_payload[TYPE_MSB:TYPE_LSB];

    // TARGET 字段。
    wire [31:0] bank0_way0_stored_target = bank0_way0_lookup_payload[31:0];
    wire [31:0] bank0_way1_stored_target = bank0_way1_lookup_payload[31:0];
    wire [31:0] bank1_way0_stored_target = bank1_way0_lookup_payload[31:0];
    wire [31:0] bank1_way1_stored_target = bank1_way1_lookup_payload[31:0];

    wire bank0_way0_match = abtb_ready & bank0_way0_lookup_valid
                          && (bank0_way0_lookup_tag == pred_lookup_tag);
    wire bank0_way1_match = abtb_ready & bank0_way1_lookup_valid
                          && (bank0_way1_lookup_tag == pred_lookup_tag);
    wire bank1_way0_match = abtb_ready & bank1_way0_lookup_valid
                          && (bank1_way0_lookup_tag == pred_lookup_tag);
    wire bank1_way1_match = abtb_ready & bank1_way1_lookup_valid
                          && (bank1_way1_lookup_tag == pred_lookup_tag);

    frontend_abtb_predict_select u_predict_select (
        .lookup_valid              (lookup_valid),
        .predict_pc                (predict_pc),
        .bank0_way0_match          (bank0_way0_match),
        .bank0_way1_match          (bank0_way1_match),
        .bank0_way0_type           (bank0_way0_lookup_type),
        .bank0_way1_type           (bank0_way1_lookup_type),
        .bank0_way0_target         (bank0_way0_stored_target),
        .bank0_way1_target         (bank0_way1_stored_target),
        .bank0_branch_taken        (bank0_branch_taken),
        .bank0_ret_valid           (bank0_ret_valid),
        .bank0_ret_target          (bank0_ret_target),
        .bank1_way0_match          (bank1_way0_match),
        .bank1_way1_match          (bank1_way1_match),
        .bank1_way0_type           (bank1_way0_lookup_type),
        .bank1_way1_type           (bank1_way1_lookup_type),
        .bank1_way0_target         (bank1_way0_stored_target),
        .bank1_way1_target         (bank1_way1_stored_target),
        .bank1_branch_taken        (bank1_branch_taken),
        .bank1_ret_valid           (bank1_ret_valid),
        .bank1_ret_target          (bank1_ret_target),
        .bank0_eligible            (bank0_eligible),
        .bank0_lookup_hit          (bank0_lookup_hit),
        .bank0_hit                 (bank0_hit),
        .bank0_way                 (bank0_way),
        .bank0_cfi_type            (bank0_cfi_type),
        .bank0_abtb_pred_target    (bank0_abtb_pred_target),
        .bank0_pred_taken          (bank0_pred_taken),
        .bank0_final_pred_target   (bank0_final_pred_target),
        .bank1_eligible            (bank1_eligible),
        .bank1_lookup_hit          (bank1_lookup_hit),
        .bank1_hit                 (bank1_hit),
        .bank1_way                 (bank1_way),
        .bank1_cfi_type            (bank1_cfi_type),
        .bank1_abtb_pred_target    (bank1_abtb_pred_target),
        .bank1_pred_taken          (bank1_pred_taken),
        .bank1_final_pred_target   (bank1_final_pred_target),
        .pred_taken                (pred_taken),
        .pred_bank                 (pred_bank),
        .pred_cfi_type             (pred_cfi_type),
        .pred_target               (pred_target),
        .pred_next_pc              (pred_next_pc),
        .pred_next_pc_early        (pred_next_pc_early)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && lookup_valid
                  && (pred_next_pc_early !== pred_next_pc))
            $error("Early ABTB next PC disagrees with qualified lookup");
        if (rst_n && clear_active
                  && (bank0_lookup_hit || bank1_lookup_hit || pred_taken))
            $fatal(1, "ABTB predicted before its LUTRAM valid clear completed");
        if (rst_n && abtb_ready
                  && ({bank1_way1_lookup_valid, bank1_way0_lookup_valid,
                       bank0_way1_lookup_valid, bank0_way0_lookup_valid}
                      !== {bank1_way1_alloc_valid[canonical_lookup_set],
                           bank1_way0_alloc_valid[canonical_lookup_set],
                           bank0_way1_alloc_valid[canonical_lookup_set],
                           bank0_way0_alloc_valid[canonical_lookup_set]}))
            $fatal(1, "ABTB LUTRAM valid bits disagree with allocation mirror");
    end
`endif

    wire update_bank = update_pc[2];
    wire [31:0] update_block_pc = {update_pc[31:3], 3'b000};
    wire [SET_IDX_W-1:0] update_set =
        update_block_pc[3 +: SET_IDX_W];
    wire [TAG_W-1:0] update_tag =
        update_block_pc[3 + SET_IDX_W +: TAG_W];

    logic bank0_update_alloc_way;
    logic bank1_update_alloc_way;

    // miss 分配优先使用无效 way，两个 way 都有效时再使用伪 LRU。
    // 两个 bank 并行计算。旧的 bank-first 优先树会把 update_bank 放到
    // 分配、命中选择和 LUTRAM 写使能之前；实际上只有末级 bank-valid 门
    // 真正依赖 update_bank。
    always_comb begin
        if (!bank0_way0_alloc_valid[update_set])
            bank0_update_alloc_way = 1'b0;
        else if (!bank0_way1_alloc_valid[update_set])
            bank0_update_alloc_way = 1'b1;
        else
            bank0_update_alloc_way = bank0_lru[update_set];

        if (!bank1_way0_alloc_valid[update_set])
            bank1_update_alloc_way = 1'b0;
        else if (!bank1_way1_alloc_valid[update_set])
            bank1_update_alloc_way = 1'b1;
        else
            bank1_update_alloc_way = bank1_lru[update_set];
    end

    wire bank0_update_selected_way = update_hit ? update_way
                                                : bank0_update_alloc_way;
    wire bank1_update_selected_way = update_hit ? update_way
                                                : bank1_update_alloc_way;
    // 复位清除的短窗口内故意忽略预测器训练。这里的状态只是推测状态，
    // 架构执行仍按顺序进行；ready 后恢复正常训练。
    wire bank0_update_fire = update_valid & abtb_ready & ~update_bank;
    wire bank1_update_fire = update_valid & abtb_ready &  update_bank;

    localparam logic [SET_IDX_W-1:0] LAST_SET = SETS - 1;
    wire clear_last_set = clear_set_q == LAST_SET;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clear_active <= 1'b1;
            clear_set_q <= '0;
        end else if (clear_active) begin
            if (clear_last_set) begin
                clear_active <= 1'b0;
            end else
                clear_set_q <= clear_set_q
                    + {{(SET_IDX_W-1){1'b0}}, 1'b1};
        end
    end

    integer set_i;
    // 这个可复位镜像只供更新/分配逻辑使用；时序关键的查询使用 LUTRAM
    // 中保存的有效位。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (set_i = 0; set_i < SETS; set_i = set_i + 1) begin
                bank0_way0_alloc_valid[set_i] <= 1'b0;
                bank0_way1_alloc_valid[set_i] <= 1'b0;
                bank1_way0_alloc_valid[set_i] <= 1'b0;
                bank1_way1_alloc_valid[set_i] <= 1'b0;
            end
        end else begin
            if (bank0_update_fire) begin
                if (!bank0_update_selected_way)
                    bank0_way0_alloc_valid[update_set] <= 1'b1;
                else
                    bank0_way1_alloc_valid[update_set] <= 1'b1;
            end
            if (bank1_update_fire) begin
                if (!bank1_update_selected_way)
                    bank1_way0_alloc_valid[update_set] <= 1'b1;
                else
                    bank1_way1_alloc_valid[update_set] <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && abtb_ready) begin
            if (lookup_valid && !predict_pc[2] && bank0_hit)
                bank0_lru[canonical_lookup_set] <= !bank0_way;
            if (bank0_update_fire)
                bank0_lru[update_set] <= !bank0_update_selected_way;

            if (lookup_valid && bank1_hit && !bank0_pred_taken)
                bank1_lru[canonical_lookup_set] <= !bank1_way;
            if (bank1_update_fire)
                bank1_lru[update_set] <= !bank1_update_selected_way;
        end
    end

    wire [3:0] update_valid_vector = {
        bank1_way1_alloc_valid[update_set],
        bank1_way0_alloc_valid[update_set],
        bank0_way1_alloc_valid[update_set],
        bank0_way0_alloc_valid[update_set]
    } | (bank0_update_fire
            ? (bank0_update_selected_way ? 4'b0010 : 4'b0001)
            : 4'b0000)
      | (bank1_update_fire
            ? (bank1_update_selected_way ? 4'b1000 : 4'b0100)
            : 4'b0000);

    // 每周期清除一个 set 的窄 lookup-valid LUTRAM。最后一个 set 清除前，
    // 预测输出会被屏蔽。
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (clear_active) begin
                lookup_valid_mem[clear_set_q] <= 4'b0000;
            end else if (bank0_update_fire || bank1_update_fire)
                lookup_valid_mem[update_set] <= update_valid_vector;
        end
    end

    // 在 lookup_valid_mem 表明对应 way 有效之前，宽 payload 的内容都无关紧要；
    // 因此这些数组故意不提供复位或后台清除写端口。
    always_ff @(posedge clk) begin
        if (bank0_update_fire && !bank0_update_selected_way)
            bank0_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank0_update_fire && bank0_update_selected_way)
            bank0_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank1_update_fire && !bank1_update_selected_way)
            bank1_way0_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
        if (bank1_update_fire && bank1_update_selected_way)
            bank1_way1_payload[update_set] <=
                {update_tag, update_cfi_type, update_target};
    end

endmodule
