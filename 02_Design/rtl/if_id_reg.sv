// ============================================================
// Module: if_id_reg
// Description: IF/ID pipeline register (stores PC + instruction)
// Spec: 02_Design/spec/if_id_reg_spec.md
// Note: Instruction captured from BRAM output in IF stage
// ============================================================

module if_id_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        if_valid,
    input  logic        if_ready_go,
    output logic        id_allowin,
    output logic        id_valid,
    input  logic        id_ready_go,
    input  logic        ex_allowin,

    // Flush
    input  logic        id_flush,

    // Data
    input  logic [31:0] if_pc,
    input  logic [31:0] if_inst,       // BRAM output (irom_data), valid in IF stage
    output logic [31:0] id_pc,
    output logic [31:0] id_inst        // registered instruction for ID stage
);

    // ---- Handshake ----
    assign id_allowin = !id_valid || (id_ready_go & ex_allowin);

    // ---- Pipeline register ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            id_valid <= 1'b0;
            id_pc    <= 32'd0;
            id_inst  <= 32'd0;
        end else if (id_flush) begin
            id_valid <= 1'b0;
        end else if (id_allowin) begin
            id_valid <= if_valid & if_ready_go;
            id_pc    <= if_pc;
            id_inst  <= if_inst;
        end
    end

endmodule
