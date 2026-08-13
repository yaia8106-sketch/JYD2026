// ============================================================
// Module: serialization_ctrl
// Description:
//   Tracks the single serializing instruction that may occupy the backend.
//   Decode prevents a second instruction from entering while this bit is set.
// ============================================================

module serialization_ctrl (
    input  logic clk,
    input  logic rst_n,
    input  logic id_issue_fire,
    input  logic id_issue_serializing,
    input  logic wb_slot0_valid,
    output logic serializing_inflight
);

    always_ff @(posedge clk) begin
        if (!rst_n)
            serializing_inflight <= 1'b0;
        else if (wb_slot0_valid)
            serializing_inflight <= 1'b0;
        else if (id_issue_fire && id_issue_serializing)
            serializing_inflight <= 1'b1;
    end

endmodule
