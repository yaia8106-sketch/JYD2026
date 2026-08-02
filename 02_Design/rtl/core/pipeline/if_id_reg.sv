// ============================================================
// Module: if_id_reg
// Description: IF/ID handshake and structured payload register.
// Domain: pipeline boundary.
// ============================================================

module if_id_reg
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        if_valid,
    input  logic        if_ready_go,
    input  logic        id_allowin,
    output logic        id_valid,

    // Flush
    input  logic        id_flush,

    // Slot 1 validity stays explicit because the pair has one shared handshake.
    input  logic           if_s1_valid,
    output logic           id_s1_valid,

    // Registered payload
    input  if_id_payload_t if_payload,
    output if_id_payload_t id_payload
);

    // Validity owns reset/flush semantics.  The payload is ignored whenever
    // both slot-valid bits are clear, so neither reset nor a late redirect
    // needs to reach the wide data registers.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            id_valid    <= 1'b0;
            id_s1_valid <= 1'b0;
        end else if (id_flush) begin
            id_valid    <= 1'b0;
            id_s1_valid <= 1'b0;
        end else if (id_allowin) begin
            id_valid    <= if_valid & if_ready_go;
            id_s1_valid <= if_valid & if_ready_go & if_s1_valid;
        end
    end

    // id_allowin is only a clock enable for payload storage.  A simultaneous
    // flush may write speculative data, but the valid block above discards it.
    always_ff @(posedge clk) begin
        if (id_allowin)
            id_payload <= if_payload;
    end

endmodule
