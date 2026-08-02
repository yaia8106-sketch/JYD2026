// ============================================================
// Module: mem_wb_reg_s1
// Description: Slot 1 MEM/WB structured payload register.
// Domain: pipeline boundary.
// ============================================================

module mem_wb_reg_s1
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    input  logic          mem_s1_valid,
    input  logic          mem_ready_go,
    input  logic          wb_allowin,

    input  mem_wb_slot1_t mem_payload,
    output logic          wb_s1_valid,
    output mem_wb_slot1_t wb_payload
);

    always_ff @(posedge clk) begin
        if (!rst_n)
            wb_s1_valid <= 1'b0;
        else if (wb_allowin)
            wb_s1_valid <= mem_s1_valid & mem_ready_go;
    end

    always_ff @(posedge clk) begin
        if (wb_allowin)
            wb_payload <= mem_payload;
    end

endmodule
