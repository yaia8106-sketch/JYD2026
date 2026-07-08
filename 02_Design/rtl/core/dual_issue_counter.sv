// ============================================================
// Module: dual_issue_counter
// Description: Counts committed Slot1 instructions.
// ============================================================

module dual_issue_counter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wb_s1_valid,
    output logic [31:0] dual_issue_count
);

    // Slot 1 validity at WB is equivalent to one committed dual-issue partner.
    always_ff @(posedge clk) begin
        if (!rst_n)
            dual_issue_count <= 32'd0;
        else if (wb_s1_valid)
            dual_issue_count <= dual_issue_count + 32'd1;
    end

endmodule
