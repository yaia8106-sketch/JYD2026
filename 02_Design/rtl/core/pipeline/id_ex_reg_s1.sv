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

    always_ff @(posedge clk) begin
        if (!rst_n)
            ex_s1_valid <= 1'b0;
        else if (ex_flush)
            ex_s1_valid <= 1'b0;
        else if (ex_allowin)
            ex_s1_valid <= id_s1_valid & id_ready_go;
    end

    // All Slot-1 architectural consumers are qualified by ex_s1_valid.  Keep
    // the shared allow signal out of individual payload D-input masks.
    always_ff @(posedge clk) begin
        if (ex_allowin)
            ex_payload <= id_payload;
    end

endmodule
