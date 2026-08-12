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
    (* extract_enable = "yes", extract_reset = "no" *)
    output ex_mem_slot0_t mem_payload,

    // Physically independent, narrow producer metadata for the backwards
    // forwarding/hazard network.  The architectural payload remains the sole
    // data source; these bits only keep its remote rd/control fields from
    // pulling the complete EX/MEM bank towards decode.
    (* keep = "true" *)
    output logic          mem_hazard_valid,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_reg_write,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_is_load,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic          mem_hazard_is_mul,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_hazard_rd,
    // Deterministic source-register replicas divide the four ID operand
    // comparison cones into two placement/fanout clusters.  They contain no
    // architectural state and are checked against the canonical mirror below.
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_fwd_s0_rd,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output logic [4:0]    mem_fwd_s1_rd,
    (* keep = "true", extract_enable = "yes", extract_reset = "no" *)
    output wb_src_t       mem_hazard_wb_sel
);

    // Standard valid/allow pipeline rule: MEM can accept a new payload when it
    // is empty or the current payload can advance to WB.
    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // A registered redirect invalidates the younger EX instruction only when
    // MEM can advance. A stalled miss must remain valid until completion.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_valid <= 1'b0;
            mem_hazard_valid <= 1'b0;
        end else if (mem_allowin) begin
            mem_valid <= ex_valid & ex_ready_go & ~mem_redirect.valid;
            mem_hazard_valid <= ex_valid & ex_ready_go
                              & ~mem_redirect.valid;
        end
    end

    // The payload has no independent lifetime; mem_valid is its sole owner.
    always_ff @(posedge clk) begin
        if (mem_allowin) begin
            mem_payload <= ex_payload;
            mem_hazard_reg_write <= ex_payload.reg_write_en;
            mem_hazard_is_load <= ex_payload.mem_read_en;
            mem_hazard_is_mul <= ex_payload.is_mul;
            mem_hazard_rd <= ex_payload.rd;
            mem_fwd_s0_rd <= ex_payload.rd;
            mem_fwd_s1_rd <= ex_payload.rd;
            mem_hazard_wb_sel <= ex_payload.wb_sel;
        end
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

`ifndef SYNTHESIS
    // The narrow copy is a placement aid only.  Prove continuously that it
    // observes exactly the same accept/hold/flush contract as EX/MEM.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (mem_hazard_valid !== mem_valid)
                $fatal(1, "Slot 0 MEM hazard-valid mirror diverged from EX/MEM valid");
            if (mem_valid
                && ((mem_hazard_reg_write !== mem_payload.reg_write_en)
                    || (mem_hazard_is_load !== mem_payload.mem_read_en)
                    || (mem_hazard_is_mul !== mem_payload.is_mul)
                    || (mem_hazard_rd !== mem_payload.rd)
                    || (mem_fwd_s0_rd !== mem_payload.rd)
                    || (mem_fwd_s1_rd !== mem_payload.rd)
                    || (mem_hazard_wb_sel !== mem_payload.wb_sel)))
                $fatal(1, "Slot 0 MEM hazard metadata mirror diverged from EX/MEM payload");
        end
    end
`endif

endmodule
