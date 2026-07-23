// ============================================================
// Module: id_ex_reg
// Description: Slot 0 ID/EX handshake and structured payload register.
// Domain: pipeline boundary.
// ============================================================

module id_ex_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // Handshake
    input  logic          id_valid,
    input  logic          id_ready_go,
    input  logic          ex_allowin,
    output logic          ex_valid,

    // Flush
    input  logic          ex_flush,

    // Registered payload
    input  id_ex_slot0_t  id_payload,
    output id_ex_slot0_t  ex_payload
);

    // Keep the embedded PHT counter reset aligned with frontend defaults.
    function automatic id_ex_slot0_t reset_payload();
        begin
            reset_payload = '0;
            reset_payload.common.prediction.prediction.stage1_pht_counter =
                2'b01;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_valid <= 1'b0;
            ex_payload <= reset_payload();
        end else if (ex_flush) begin
            // Flush clears validity and late/prediction tags that could
            // otherwise affect the next instruction accepted into EX.
            ex_valid <= 1'b0;
            ex_payload.common.rs1_late_src <= LATE_NONE;
            ex_payload.common.rs2_late_src <= LATE_NONE;
            ex_payload.common.alu_src1_late_src <= LATE_NONE;
            ex_payload.common.alu_src2_late_src <= LATE_NONE;
            ex_payload.common.prediction.prediction.source_abtb <= 1'b0;
            ex_payload.common.prediction.prediction.stage1_branch_owned <=
                1'b0;
        end else if (ex_allowin) begin
            ex_valid <= id_valid & id_ready_go;
            ex_payload <= id_payload;
        end
    end

endmodule
