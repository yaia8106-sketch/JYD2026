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

    // Standard valid/allow pipeline rule: MEM can accept a new payload when it
    // is empty or the current payload can advance to WB.
    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // A registered redirect invalidates the younger EX instruction only when
    // MEM can advance. A stalled miss must remain valid until completion.
    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_valid <= 1'b0;
        else if (mem_allowin)
            mem_valid <= ex_valid & ex_ready_go & ~mem_redirect.valid;
    end

    // The payload has no independent lifetime; mem_valid is its sole owner.
    always_ff @(posedge clk) begin
        if (mem_allowin)
            mem_payload <= ex_payload;
    end

    // Redirect propagation must not be blocked by MEM backpressure.
    // Frontend replay must see control-flow recovery even while a load waits.
    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_redirect.valid <= 1'b0;
        else
            mem_redirect.valid <= ex_redirect.valid;
    end

    // The source and direction are don't-care unless redirect.valid is set.
    // Keeping them outside reset prevents the reset net from reaching payload
    // flops and leaves only three narrow control bits on this boundary.
    always_ff @(posedge clk) begin
        mem_redirect.source <= ex_redirect.source;
        mem_redirect.actual_taken <= ex_redirect.actual_taken;
    end

endmodule
