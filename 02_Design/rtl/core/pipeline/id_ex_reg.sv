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

    // Reset and redirect invalidate the stage; stale payload is unobservable.
    always_ff @(posedge clk) begin
        if (!rst_n)
            ex_valid <= 1'b0;
        else if (ex_flush)
            ex_valid <= 1'b0;
        else if (ex_allowin)
            ex_valid <= id_valid & id_ready_go;
    end

    always_ff @(posedge clk) begin
        if (ex_allowin)
            ex_payload <= id_payload;
    end

endmodule
