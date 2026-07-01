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
    output logic        id_allowin,
    output logic        id_valid,
    input  logic        id_ready_go,
    input  logic        ex_allowin,

    // Flush
    input  logic        id_flush,

    // Slot 1 validity stays explicit because the pair has one shared handshake.
    input  logic           if_s1_valid,
    output logic           id_s1_valid,

    // Registered payload
    input  if_id_payload_t if_payload,
    output if_id_payload_t id_payload
);

    function automatic if_id_payload_t reset_payload();
        begin
            reset_payload = '0;
            reset_payload.slot0.prediction.stage1_pht_counter = 2'b01;
            reset_payload.slot1.prediction.stage1_pht_counter = 2'b01;
        end
    endfunction

    // ---- Handshake ----
    assign id_allowin = !id_valid || (id_ready_go & ex_allowin);

    // ---- Pipeline register ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            id_valid                                      <= 1'b0;
            id_s1_valid                                   <= 1'b0;
            id_payload                                    <= reset_payload();
        end else if (id_flush) begin
            id_valid                                        <= 1'b0;
            id_s1_valid                                     <= 1'b0;
            id_payload.slot0.prediction.source_abtb         <= 1'b0;
            id_payload.slot0.prediction.stage1_branch_owned <= 1'b0;
            id_payload.slot1.prediction.taken               <= 1'b0;
            id_payload.slot1.prediction.source_abtb         <= 1'b0;
            id_payload.slot1.prediction.stage1_branch_owned <= 1'b0;
        end else if (id_allowin) begin
            id_valid     <= if_valid & if_ready_go;
            id_s1_valid  <= if_valid & if_ready_go & if_s1_valid;
            id_payload   <= if_payload;
        end
    end

endmodule
