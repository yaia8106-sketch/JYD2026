// ============================================================
// 中文说明：保存供相关性、修复和同组 store 数据路径使用的窄字段副本，帮助缩短物理布线。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 说明：保存时序敏感的 load 修复、相关性、快速前递和同组 store
// 数据路径所需的窄 ID/EX 副本。架构数据仍在 id_ex_slot*_t 中，
// 这里仅保存控制位和少量字段。
// 约束：元数据与 ID/EX 在同一个 allow 时钟沿捕获；复位/冲刷只处理
// valid 位；对应 valid 为 0 时，旧元数据不可被观察到。
// ============================================================

module id_ex_timing_mirror (
    input  logic clk,
    input  logic rst_n,
    input  logic ex_stage_allowin,
    input  logic ex_stage_flush,

    input  logic id_slot0_valid,
    input  logic id_slot1_valid,
    input  logic id_ready_go,
    input  logic id_slot0_store_bypass,
    input  cpu_defs::id_ex_slot0_t id_slot0_payload,
    input  cpu_defs::id_ex_slot1_t id_slot1_payload,

    (* extract_enable = "yes", extract_reset = "no" *)
    output logic [3:0] ex_slot0_repair_q,
    (* extract_enable = "yes", extract_reset = "no" *)
    output logic [3:0] ex_slot1_repair_q,

    (* keep = "true" *) output logic       ex_slot0_hazard_valid,
    (* keep = "true" *) output logic       ex_slot0_hazard_reg_write,
    (* keep = "true" *) output logic       ex_slot0_hazard_is_muldiv,
    (* keep = "true" *) output logic       ex_slot0_hazard_mem_read,
    (* keep = "true" *) output logic       ex_slot0_hazard_result_repair,
    (* keep = "true" *) output logic [4:0] ex_slot0_hazard_rd,

    (* keep = "true" *) output logic       ex_slot1_hazard_valid,
    (* keep = "true" *) output logic       ex_slot1_hazard_reg_write,
    (* keep = "true" *) output logic       ex_slot1_hazard_mem_read,
    (* keep = "true" *) output logic       ex_slot1_hazard_result_repair,
    (* keep = "true" *) output logic [4:0] ex_slot1_hazard_rd,

    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0] ex_slot1_fast_src2_low,
    output logic       ex_slot0_store_bypass_q
);

    import cpu_defs::*;

    logic id_slot0_uses_priv_result;
    logic id_slot0_hazard_reg_write;
    logic id_slot0_hazard_result_repair;
    logic id_slot1_hazard_reg_write;
    logic id_slot1_hazard_result_repair;

    assign id_slot0_uses_priv_result =
        (id_slot0_payload.priv_op == PRIV_REG)
      | (id_slot0_payload.priv_op == PRIV_COUNTER)
      | (id_slot0_payload.priv_op == PRIV_CPUCFG);

    assign id_slot0_hazard_reg_write =
        id_slot0_payload.common.reg_write_en
        & ~id_slot0_payload.common.mem_read_en
        & ~id_slot0_payload.is_muldiv
        & ~id_slot0_uses_priv_result;

    assign id_slot0_hazard_result_repair =
        id_slot0_payload.common.alu_src1_wb_repair
      | id_slot0_payload.common.alu_src2_wb_repair;

    assign id_slot1_hazard_reg_write =
        id_slot1_payload.common.reg_write_en
        & ~id_slot1_payload.common.mem_read_en;

    assign id_slot1_hazard_result_repair =
        id_slot1_payload.common.alu_src1_wb_repair
      | id_slot1_payload.common.alu_src2_wb_repair;

    // 修复元数据的生命周期由流水级 valid 管理，因此这些 payload 寄存器
    // 故意不连接复位和冲刷控制。
    always_ff @(posedge clk) begin
        if (ex_stage_allowin) begin
            ex_slot0_repair_q <= {
                id_slot0_payload.common.alu_src2_wb_repair,
                id_slot0_payload.common.alu_src1_wb_repair,
                id_slot0_payload.common.rs2_wb_repair,
                id_slot0_payload.common.rs1_wb_repair
            };
            ex_slot1_repair_q <= {
                id_slot1_payload.common.alu_src2_wb_repair,
                id_slot1_payload.common.alu_src1_wb_repair,
                id_slot1_payload.common.rs2_wb_repair,
                id_slot1_payload.common.rs1_wb_repair
            };
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_slot0_hazard_valid <= 1'b0;
            ex_slot1_hazard_valid <= 1'b0;
        end else if (ex_stage_flush) begin
            ex_slot0_hazard_valid <= 1'b0;
            ex_slot1_hazard_valid <= 1'b0;
        end else if (ex_stage_allowin) begin
            ex_slot0_hazard_valid <= id_slot0_valid & id_ready_go;
            ex_slot1_hazard_valid <= id_slot1_valid & id_ready_go;
        end
    end

    // 上面的 valid 寄存器会屏蔽这个纯数据 bank 中的所有旧值。
    always_ff @(posedge clk) begin
        if (ex_stage_allowin) begin
            ex_slot0_hazard_reg_write <= id_slot0_hazard_reg_write;
            ex_slot0_hazard_is_muldiv <= id_slot0_payload.is_muldiv;
            ex_slot0_hazard_mem_read <=
                id_slot0_payload.common.mem_read_en;
            ex_slot0_hazard_result_repair <=
                id_slot0_hazard_result_repair;
            ex_slot0_hazard_rd <= id_slot0_payload.common.rd;

            ex_slot1_hazard_reg_write <= id_slot1_hazard_reg_write;
            ex_slot1_hazard_mem_read <=
                id_slot1_payload.common.mem_read_en;
            ex_slot1_hazard_result_repair <=
                id_slot1_hazard_result_repair;
            ex_slot1_hazard_rd <= id_slot1_payload.common.rd;

            ex_slot1_fast_src2_low <=
                id_slot1_payload.common.alu_src2[4:0];
            ex_slot0_store_bypass_q <=
                id_ready_go & id_slot0_store_bypass;
        end
    end

endmodule
