// ============================================================
// Module: ex_mem_reg
// Description: Slot 0 EX/MEM handshake, payload, and redirect register.
// Domain: pipeline boundary.
// ============================================================

module ex_mem_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // Handshake
    input  logic          ex_valid,
    input  logic          ex_ready_go,
    output logic          mem_allowin,
    output logic          mem_valid,
    input  logic          mem_ready_go,
    input  logic          wb_allowin,

    // Redirect is registered independently from the stalled MEM payload.
    input  redirect_t     ex_redirect,
    output redirect_t     mem_redirect,

    // Registered payload
    input  ex_mem_slot0_t ex_payload,
    output ex_mem_slot0_t mem_payload
);

    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // A registered redirect invalidates the younger EX instruction only when
    // MEM can advance. A stalled miss must remain valid until completion.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_valid <= 1'b0;
            mem_payload <= '0;
        end else if (mem_allowin) begin
            mem_valid <= ex_valid & ex_ready_go & ~mem_redirect.valid;
            mem_payload <= ex_payload;
        end
    end

    // Redirect propagation must not be blocked by MEM backpressure.
    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_redirect <= '0;
        else
            mem_redirect <= ex_redirect;
    end

endmodule
