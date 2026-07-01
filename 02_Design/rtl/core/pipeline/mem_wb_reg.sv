// ============================================================
// Module: mem_wb_reg
// Description: Slot 0 MEM/WB handshake and structured payload register.
// Domain: pipeline boundary.
// ============================================================

module mem_wb_reg
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    // Handshake
    input  logic          mem_valid,
    input  logic          mem_ready_go,
    output logic          wb_allowin,
    output logic          wb_valid,

    // Load data is updated only when the shared LSU completes a load.
    input  logic          mem_load_valid,

    // Registered payload
    input  mem_wb_slot0_t mem_payload,
    output mem_wb_slot0_t wb_payload
);

    wire wb_ready_go = 1'b1;
    assign wb_allowin = !wb_valid || wb_ready_go;

    function automatic mem_wb_slot0_t accepted_payload(
        input mem_wb_slot0_t current_payload,
        input mem_wb_slot0_t incoming_payload,
        input logic          load_data_write
    );
        accepted_payload = incoming_payload;
        if (!load_data_write)
            accepted_payload.load_data = current_payload.load_data;
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_valid <= 1'b0;
            wb_payload <= '0;
        end else if (wb_allowin) begin
            wb_valid <= mem_valid & mem_ready_go;
            wb_payload <= accepted_payload(
                wb_payload,
                mem_payload,
                mem_load_valid & mem_ready_go
            );
        end
    end

endmodule
