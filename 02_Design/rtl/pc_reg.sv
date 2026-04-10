// ============================================================
// Module: pc_reg
// Description: PC register (Pre_IF_reg), sequential
// Priority: rst > flush (branch) > allowin > stall
// ============================================================

module pc_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        if_allowin,
    output logic        if_valid,

    // Flush (highest priority after reset)
    input  logic        branch_flush,
    input  logic [31:0] branch_target,

    // Normal update
    input  logic [31:0] next_pc,

    // Output
    output logic [31:0] pc
);

    // IF stage is always valid during normal operation
    assign if_valid = 1'b1;

    // ---- PC register ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc <= 32'h0000_0000;       // Reset vector (configurable)
        end else if (branch_flush) begin
            pc <= branch_target;        // Flush overrides stall
        end else if (if_allowin) begin
            pc <= next_pc;              // Normal advance
        end
        // else: stall, PC holds
    end

endmodule
