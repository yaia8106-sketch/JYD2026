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
    output ex_mem_slot1_t mem_payload,

    // Physically independent narrow copy for the backwards ID hazard path.
    // Keeping these fields out of the ordinary MEM payload lets placement put
    // their registers next to the forwarding comparators without moving the
    // LSU/commit copy of the same metadata.
    (* keep = "true", dont_touch = "true" *)
    output logic          mem_s1_hazard_valid,
    (* keep = "true", dont_touch = "true" *)
    output logic          mem_s1_hazard_is_load,
    (* keep = "true", dont_touch = "true" *)
    output logic [4:0]    mem_s1_hazard_rd
);

    // Slot 1 is younger than Slot 0, so either a same-cycle EX miss or an older
    // registered MEM redirect invalidates it.
    wire s1_flush = ex_branch_flush | mem_branch_flush;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_s1_valid <= 1'b0;
            mem_s1_hazard_valid <= 1'b0;
        end else if (mem_allowin) begin
            mem_s1_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
            mem_s1_hazard_valid <= ex_s1_valid & ex_ready_go & ~s1_flush;
        end
    end

    always_ff @(posedge clk) begin
        if (mem_allowin) begin
            mem_payload <= ex_payload;
            mem_s1_hazard_is_load <= ex_payload.mem_read_en;
            mem_s1_hazard_rd <= ex_payload.rd;
        end
    end

`ifndef SYNTHESIS
    // The mirror is a physical implementation detail only.  Check the exact
    // cycle contract against the architectural EX/MEM payload continuously.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (mem_s1_hazard_valid !== mem_s1_valid)
                $fatal(1, "Slot 1 hazard-valid mirror diverged from EX/MEM valid");
            if (mem_s1_valid
                && ((mem_s1_hazard_is_load !== mem_payload.mem_read_en)
                    || (mem_s1_hazard_rd !== mem_payload.rd)))
                $fatal(1, "Slot 1 hazard metadata mirror diverged from EX/MEM payload");
        end
    end
`endif

endmodule
