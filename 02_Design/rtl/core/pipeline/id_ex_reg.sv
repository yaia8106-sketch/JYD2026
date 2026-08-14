// ============================================================
// 中文说明：保存 slot0 的 ID/EX 流水状态，并处理发射、保持、清空和重定向。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存 slot0 的 ID/EX 握手状态和结构化 payload。
// ============================================================

module id_ex_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // 流水线握手信号
    input  logic          id_valid,
    input  logic          id_ready_go,
    input  logic          cache_ready,
    input  logic          ex_allowin_if_cache_ready,
    input  logic          ex_allowin_if_cache_wait,
    output logic          ex_valid,

    // 冲刷信号
    input  logic          ex_flush,

    // 需要保存的流水线 payload
    input  id_ex_slot0_t  id_payload,
    (* extract_enable = "yes", extract_reset = "no" *)
    output id_ex_slot0_t  ex_payload
);

    logic ex_allowin_src1;
    logic ex_allowin_src2;
    logic ex_allowin_control;
    logic ex_allowin_priv;

    id_ex_allowin_local u_allowin_src1 (
        .cache_ready         (cache_ready),
        .allow_if_cache_ready(ex_allowin_if_cache_ready),
        .allow_if_cache_wait (ex_allowin_if_cache_wait),
        .allowin             (ex_allowin_src1)
    );

    id_ex_allowin_local u_allowin_src2 (
        .cache_ready         (cache_ready),
        .allow_if_cache_ready(ex_allowin_if_cache_ready),
        .allow_if_cache_wait (ex_allowin_if_cache_wait),
        .allowin             (ex_allowin_src2)
    );

    id_ex_allowin_local u_allowin_control (
        .cache_ready         (cache_ready),
        .allow_if_cache_ready(ex_allowin_if_cache_ready),
        .allow_if_cache_wait (ex_allowin_if_cache_wait),
        .allowin             (ex_allowin_control)
    );

    id_ex_allowin_local u_allowin_priv (
        .cache_ready         (cache_ready),
        .allow_if_cache_ready(ex_allowin_if_cache_ready),
        .allow_if_cache_wait (ex_allowin_if_cache_wait),
        .allowin             (ex_allowin_priv)
    );

    // 复位和重定向只使本级失效；只要 valid 为 0，旧 payload 就不可见。
    always_ff @(posedge clk) begin
        if (!rst_n)
            ex_valid <= 1'b0;
        else if (ex_flush)
            ex_valid <= 1'b0;
        else if (ex_allowin_control)
            ex_valid <= id_valid & id_ready_go;
    end

    // payload 字段按下游布局簇分组。每个局部使能在逻辑上完全等价，
    // 因此既不改变接受的指令，也不改变任何可观察字段移动的周期。
    always_ff @(posedge clk) begin
        if (ex_allowin_src1) begin
            ex_payload.common.alu_src1 <= id_payload.common.alu_src1;
            ex_payload.common.rs1_data <= id_payload.common.rs1_data;
            ex_payload.common.rs1_wb_repair <=
                id_payload.common.rs1_wb_repair;
            ex_payload.common.rs1_addr <= id_payload.common.rs1_addr;
            ex_payload.common.alu_src1_wb_repair <=
                id_payload.common.alu_src1_wb_repair;
        end
    end

    always_ff @(posedge clk) begin
        if (ex_allowin_src2) begin
            ex_payload.common.alu_src2 <= id_payload.common.alu_src2;
            ex_payload.common.rs2_data <= id_payload.common.rs2_data;
            ex_payload.common.rs2_wb_repair <=
                id_payload.common.rs2_wb_repair;
            ex_payload.common.rs2_addr <= id_payload.common.rs2_addr;
            ex_payload.common.alu_src2_wb_repair <=
                id_payload.common.alu_src2_wb_repair;
        end
    end

    always_ff @(posedge clk) begin
        if (ex_allowin_control) begin
            ex_payload.common.pc <= id_payload.common.pc;
            ex_payload.common.rd <= id_payload.common.rd;
            ex_payload.common.alu_op <= id_payload.common.alu_op;
            ex_payload.common.reg_write_en <=
                id_payload.common.reg_write_en;
            ex_payload.common.wb_sel <= id_payload.common.wb_sel;
            ex_payload.common.mem_read_en <= id_payload.common.mem_read_en;
            ex_payload.common.mem_write_en <=
                id_payload.common.mem_write_en;
            ex_payload.common.mem_size <= id_payload.common.mem_size;
            ex_payload.common.mem_unsigned <= id_payload.common.mem_unsigned;
            ex_payload.common.control_flow <=
                id_payload.common.control_flow;
            ex_payload.common.branch_op <= id_payload.common.branch_op;
            ex_payload.common.target_clear_mask <=
                id_payload.common.target_clear_mask;
            ex_payload.common.prediction <= id_payload.common.prediction;
            ex_payload.inst <= id_payload.inst;
        end
    end

    always_ff @(posedge clk) begin
        if (ex_allowin_priv) begin
            ex_payload.priv_op <= id_payload.priv_op;
            ex_payload.priv_uses_imm <= id_payload.priv_uses_imm;
            ex_payload.priv_cmd <= id_payload.priv_cmd;
            ex_payload.priv_addr <= id_payload.priv_addr;
            ex_payload.priv_imm <= id_payload.priv_imm;
            ex_payload.exception <= id_payload.exception;
            ex_payload.is_muldiv <= id_payload.is_muldiv;
            ex_payload.muldiv_op <= id_payload.muldiv_op;
        end
    end

`ifndef SYNTHESIS
    wire ex_allowin_reference = cache_ready
        ? ex_allowin_if_cache_ready : ex_allowin_if_cache_wait;
    always_ff @(posedge clk) begin
        if (rst_n
            && ((ex_allowin_src1 !== ex_allowin_reference)
                || (ex_allowin_src2 !== ex_allowin_reference)
                || (ex_allowin_control !== ex_allowin_reference)
                || (ex_allowin_priv !== ex_allowin_reference)))
            $fatal(1, "Slot-0 ID/EX local enables diverged");
    end
`endif

endmodule
