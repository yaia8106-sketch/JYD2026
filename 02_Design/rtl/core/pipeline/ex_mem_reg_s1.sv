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

    // Slot 1 is younger than Slot 0, so either a same-cycle EX miss or an older
    // registered MEM redirect invalidates it.
    wire s1_flush = ex_branch_flush | mem_branch_flush;

    always_ff @(posedge clk) begin
        if (!rst_n)
            mem_s1_valid <= 1'b0;
        else if (mem_allowin)
            mem_s1_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
    end

    always_ff @(posedge clk) begin
        if (mem_allowin)
            mem_payload <= ex_payload;
    end

endmodule
