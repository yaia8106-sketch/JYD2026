// ============================================================
// Module: id_ex_reg_s1
// Description: Slot 1 ID/EX structured payload register.
// Domain: pipeline boundary.
// ============================================================

module id_ex_reg_s1
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    input  logic          id_s1_valid,
    input  logic          id_ready_go,
    input  logic          cache_ready,
    input  logic          ex_allowin_if_cache_ready,
    input  logic          ex_allowin_if_cache_wait,
    input  logic          ex_flush,

    input  id_ex_slot1_t  id_payload,
    output logic          ex_s1_valid,
    (* extract_enable = "yes", extract_reset = "no" *)
    output id_ex_slot1_t  ex_payload
);

    logic ex_allowin_src1;
    logic ex_allowin_src2;
    logic ex_allowin_control;

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

    always_ff @(posedge clk) begin
        if (!rst_n)
            ex_s1_valid <= 1'b0;
        else if (ex_flush)
            ex_s1_valid <= 1'b0;
        else if (ex_allowin_control)
            ex_s1_valid <= id_s1_valid & id_ready_go;
    end

    // The three enables are logically identical but physically local to the
    // consumers they control.  Splitting the 500+ load global CE keeps each
    // copy inside one operand/control placement cluster without introducing
    // data-input hold muxes.
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
            ex_payload.common.mem_write_en <= id_payload.common.mem_write_en;
            ex_payload.common.mem_size <= id_payload.common.mem_size;
            ex_payload.common.mem_unsigned <= id_payload.common.mem_unsigned;
            ex_payload.common.control_flow <= id_payload.common.control_flow;
            ex_payload.common.branch_op <= id_payload.common.branch_op;
            ex_payload.common.target_clear_mask <=
                id_payload.common.target_clear_mask;
            ex_payload.common.prediction <= id_payload.common.prediction;
            ex_payload.inst <= id_payload.inst;
        end
    end

`ifndef SYNTHESIS
    wire ex_allowin_reference = cache_ready
        ? ex_allowin_if_cache_ready : ex_allowin_if_cache_wait;
    always_ff @(posedge clk) begin
        if (rst_n
            && ((ex_allowin_src1 !== ex_allowin_reference)
                || (ex_allowin_src2 !== ex_allowin_reference)
                || (ex_allowin_control !== ex_allowin_reference)))
            $fatal(1, "Slot-1 ID/EX local enables diverged");
    end
`endif

endmodule
