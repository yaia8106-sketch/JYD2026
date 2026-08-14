// ============================================================
// 中文说明：维护前端取指 PC、请求状态、响应等待和重定向后的取指状态。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：frontend_fetch_state。
// 说明：维护 BP0 PC/epoch、已接受的 F0 元数据和未完成请求计数。
// 所属阶段：frontend。
// 本模块的输出都是时钟沿更新的状态；预测和取指包构造仍在 frontend_ftq
// 中以组合逻辑完成。
// ============================================================

module frontend_fetch_state
    import cpu_defs::*;
#(
    parameter int FTQ_PTR_W = 3,
    parameter bit WIDE_ABTB_META = 1'b0,
    parameter bit VARIABLE_IROM_LATENCY = 1'b0,
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       redirect_valid,
    input  logic [31:0]                redirect_target,

    input  logic                       accept,
    input  logic                       response,
    input  logic [ 1:0]                accept_base_mask,
    input  frontend_steer_result_t     accept_steer,
    input  frontend_f0_bank_meta_t     accept_bank0_meta,
    input  frontend_f0_bank_meta_t     accept_bank1_meta,
    input  frontend_abtb_meta_t        accept_abtb_bank0_meta,
    input  frontend_abtb_meta_t        accept_abtb_bank1_meta,

    output logic [31:0]                current_pc,
    output logic [ 1:0]                frontend_epoch,
    output frontend_f0_state_t         f0_state,
    output frontend_abtb_meta_t        f0_abtb_bank0_meta,
    output frontend_abtb_meta_t        f0_abtb_bank1_meta,
    output logic [FTQ_PTR_W:0]         outstanding_count
);

    logic f0_abtb_bank0_hit_r;
    logic f0_abtb_bank0_way_r;
    logic f0_abtb_bank1_hit_r;
    logic f0_abtb_bank1_way_r;

    assign f0_abtb_bank0_meta.hit = f0_abtb_bank0_hit_r;
    assign f0_abtb_bank0_meta.way = f0_abtb_bank0_way_r;
    assign f0_abtb_bank1_meta.hit = f0_abtb_bank1_hit_r;
    assign f0_abtb_bank1_meta.way = f0_abtb_bank1_way_r;

    // BP0 PC 状态在预测请求被接受时前进，在后端重定向时立即重置。
    // epoch 用来标记尚未返回的 F0 响应。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            current_pc <= RESET_PC;
            frontend_epoch <= 2'd0;
        end else if (redirect_valid) begin
            current_pc <= redirect_target;
            frontend_epoch <= frontend_epoch + 2'd1;
        end else if (accept) begin
            current_pc <= accept_steer.next_pc;
        end
    end

    // 本地同步 ROM 恰好在接受请求后一拍返回；AXI 指令端口则必须一直保存
    // 请求上下文，直到响应到达。显式区分这两种时序约定，保证 JYD 的 BRAM
    // 路径不变，同时让 NSCSCC 路径能够容忍任意 AXI 延迟。
    generate
        if (VARIABLE_IROM_LATENCY) begin : g_variable_irom_valid
            always_ff @(posedge clk) begin
                if (!rst_n || redirect_valid)
                    f0_state.valid <= 1'b0;
                else if (accept)
                    f0_state.valid <= 1'b1;
                else if (response)
                    f0_state.valid <= 1'b0;
            end
        end else begin : g_fixed_irom_valid
            always_ff @(posedge clk) begin
                if (!rst_n || redirect_valid)
                    f0_state.valid <= 1'b0;
                else
                    f0_state.valid <= accept;
            end
        end
    endgenerate

    // F0 元数据是与 IROM 响应配对的一拍延迟取指包上下文。
    // 集成前端不会在重定向同周期接受请求；即使单元测试同时驱动两者，
    // 上面的 valid 逻辑仍会让重定向优先，因此推测 payload 写入不会产生影响。
    always_ff @(posedge clk) begin
        if (accept) begin
            f0_state.epoch <= frontend_epoch;
            f0_state.start_pc <= current_pc;
            f0_state.base_mask <= accept_base_mask;
            f0_state.steer.taken <= accept_steer.taken;
            f0_state.steer.source_abtb <= accept_steer.source_abtb;
            f0_state.steer.bank <= accept_steer.bank;
            f0_state.steer.cfi_type <= accept_steer.cfi_type;
            f0_state.steer.target <= accept_steer.target;
            f0_state.steer.next_pc <= accept_steer.next_pc;
            f0_state.bank0_meta <= accept_bank0_meta;
            f0_state.bank1_meta <= accept_bank1_meta;
            f0_abtb_bank0_hit_r <= accept_abtb_bank0_meta.hit;
            f0_abtb_bank0_way_r <= accept_abtb_bank0_meta.way;
            f0_abtb_bank1_hit_r <= accept_abtb_bank1_meta.hit;
            f0_abtb_bank1_way_r <= accept_abtb_bank1_meta.way;
        end
    end

    // outstanding 计数等于已接受的 BP0 请求数减去已返回的 F0 取指包数。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            outstanding_count <= '0;
        end else if (redirect_valid) begin
            outstanding_count <= '0;
        end else begin
            case ({accept, response})
                2'b10: outstanding_count <=
                    outstanding_count + {{FTQ_PTR_W{1'b0}}, 1'b1};
                2'b01: outstanding_count <=
                    outstanding_count - {{FTQ_PTR_W{1'b0}}, 1'b1};
                default: ;
            endcase
        end
    end

    generate
        // 宽元数据只供观测/调试版本使用；正常功能预测只使用 hit/way 和
        // 随请求携带的普通预测字段。
        if (WIDE_ABTB_META) begin : g_wide_abtb_meta
            logic [ 1:0] bank0_cfi_type_r;
            logic [31:0] bank0_target_r;
            logic        bank0_pred_taken_r;
            logic [31:0] bank0_pred_target_r;
            logic [ 1:0] bank1_cfi_type_r;
            logic [31:0] bank1_target_r;
            logic        bank1_pred_taken_r;
            logic [31:0] bank1_pred_target_r;

            assign f0_abtb_bank0_meta.cfi_type = bank0_cfi_type_r;
            assign f0_abtb_bank0_meta.target = bank0_target_r;
            assign f0_abtb_bank0_meta.pred_taken = bank0_pred_taken_r;
            assign f0_abtb_bank0_meta.pred_target = bank0_pred_target_r;
            assign f0_abtb_bank1_meta.cfi_type = bank1_cfi_type_r;
            assign f0_abtb_bank1_meta.target = bank1_target_r;
            assign f0_abtb_bank1_meta.pred_taken = bank1_pred_taken_r;
            assign f0_abtb_bank1_meta.pred_target = bank1_pred_target_r;

            always_ff @(posedge clk) begin
                if (accept) begin
                    bank0_cfi_type_r <= accept_abtb_bank0_meta.cfi_type;
                    bank0_target_r <= accept_abtb_bank0_meta.target;
                    bank0_pred_taken_r <= accept_abtb_bank0_meta.pred_taken;
                    bank0_pred_target_r <= accept_abtb_bank0_meta.pred_target;
                    bank1_cfi_type_r <= accept_abtb_bank1_meta.cfi_type;
                    bank1_target_r <= accept_abtb_bank1_meta.target;
                    bank1_pred_taken_r <= accept_abtb_bank1_meta.pred_taken;
                    bank1_pred_target_r <= accept_abtb_bank1_meta.pred_target;
                end
            end
        end else begin : g_narrow_abtb_meta
            assign f0_abtb_bank0_meta.cfi_type = 2'd0;
            assign f0_abtb_bank0_meta.target = 32'd0;
            assign f0_abtb_bank0_meta.pred_taken = 1'b0;
            assign f0_abtb_bank0_meta.pred_target = 32'd0;
            assign f0_abtb_bank1_meta.cfi_type = 2'd0;
            assign f0_abtb_bank1_meta.target = 32'd0;
            assign f0_abtb_bank1_meta.pred_taken = 1'b0;
            assign f0_abtb_bank1_meta.pred_target = 32'd0;
        end
    endgenerate

endmodule
