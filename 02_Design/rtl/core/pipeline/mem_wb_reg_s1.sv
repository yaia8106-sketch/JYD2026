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

    // Slot 1 has no load-data field; mask register writes when the slot is not
    // valid while keeping the rest of the payload inspectable.
    function automatic mem_wb_slot1_t accepted_payload(
        input mem_wb_slot1_t incoming_payload,
        input logic          slot_active
    );
        accepted_payload = incoming_payload;
        accepted_payload.reg_write_en = incoming_payload.reg_write_en
                                             & slot_active;
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_s1_valid <= 1'b0;
            wb_payload <= '0;
        end else if (wb_allowin) begin
            wb_s1_valid <= mem_s1_valid & mem_ready_go;
            wb_payload <= accepted_payload(mem_payload, mem_s1_valid);
        end
    end

endmodule
