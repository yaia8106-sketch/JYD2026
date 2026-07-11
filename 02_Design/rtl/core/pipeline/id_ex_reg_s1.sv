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
    input  logic          ex_allowin,
    input  logic          ex_flush,

    input  id_ex_slot1_t  id_payload,
    output logic          ex_s1_valid,
    output id_ex_slot1_t  ex_payload
);

    function automatic id_ex_slot1_t reset_payload();
        begin
            reset_payload = '0;
            reset_payload.common.prediction.prediction.stage1_pht_counter =
                2'b01;
        end
    endfunction

    // Slot 1 shares the Slot 0 handshake. When Slot 1 is absent, keep debug
    // fields visible but mask all side-effect controls.
    function automatic id_ex_slot1_t accepted_payload(
        input id_ex_slot1_t payload,
        input logic         slot_valid
    );
        begin
            accepted_payload = payload;
            accepted_payload.common.rs1_wb_repair &= slot_valid;
            accepted_payload.common.rs2_wb_repair &= slot_valid;
            accepted_payload.common.alu_src1_wb_repair &= slot_valid;
            accepted_payload.common.alu_src2_wb_repair &= slot_valid;
            accepted_payload.common.reg_write_en  &= slot_valid;
            accepted_payload.common.mem_read_en   &= slot_valid;
            accepted_payload.common.mem_write_en  &= slot_valid;
            accepted_payload.common.is_branch     &= slot_valid;
            accepted_payload.common.is_jal        &= slot_valid;
            accepted_payload.common.is_jalr       &= slot_valid;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_s1_valid <= 1'b0;
            ex_payload <= reset_payload();
        end else if (ex_flush) begin
            // Prediction and repair tags are cleared with validity on redirects.
            ex_s1_valid <= 1'b0;
            ex_payload.common.rs1_wb_repair <= 1'b0;
            ex_payload.common.rs2_wb_repair <= 1'b0;
            ex_payload.common.alu_src1_wb_repair <= 1'b0;
            ex_payload.common.alu_src2_wb_repair <= 1'b0;
            ex_payload.common.prediction.prediction.taken <= 1'b0;
            ex_payload.common.prediction.prediction.source_abtb <= 1'b0;
            ex_payload.common.prediction.prediction.stage1_branch_owned <=
                1'b0;
        end else if (ex_allowin) begin
            ex_s1_valid <= id_s1_valid & id_ready_go;
            ex_payload <= accepted_payload(id_payload, id_s1_valid);
        end
    end

endmodule
