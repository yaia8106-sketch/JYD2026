// ============================================================
// Module: ex_mem_reg_s1
// Description: Slot 1 EX/MEM structured payload register.
// Domain: pipeline boundary.
// ============================================================

module ex_mem_reg_s1
    import cpu_defs::*;
(
    input  logic          clk,
    input  logic          rst_n,

    input  logic          ex_s1_valid,
    input  logic          ex_ready_go,
    input  logic          mem_allowin,
    input  logic          ex_branch_flush,
    input  logic          mem_branch_flush,

    input  ex_mem_slot1_t ex_payload,
    output logic          mem_s1_valid,
    output ex_mem_slot1_t mem_payload
);

    wire s1_flush = ex_branch_flush | mem_branch_flush;

    function automatic ex_mem_slot1_t accepted_payload(
        input ex_mem_slot1_t payload,
        input logic          slot_active
    );
        begin
            accepted_payload = payload;
            accepted_payload.reg_write_en &= slot_active;
            accepted_payload.mem_read_en  &= slot_active;
            accepted_payload.mem_write_en &= slot_active;
            accepted_payload.store_wea = slot_active ? payload.store_wea : 4'd0;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_s1_valid <= 1'b0;
            mem_payload <= '0;
        end else if (mem_allowin) begin
            mem_s1_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
            mem_payload <= accepted_payload(
                ex_payload,
                ex_s1_valid & ~s1_flush
            );
        end
    end

endmodule
