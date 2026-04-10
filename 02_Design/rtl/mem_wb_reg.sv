// ============================================================
// Module: mem_wb_reg
// Description: MEM/WB pipeline register
// Note: Does NOT store Load data. dram_dout is provided directly
//       to WB writeback MUX from BRAM output register.
// ============================================================

module mem_wb_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        mem_valid,
    input  logic        mem_ready_go,
    output logic        wb_allowin,
    output logic        wb_valid,

    // Data in (from MEM stage)
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_pc,
    input  logic [ 4:0] mem_rd,
    input  logic        mem_reg_write_en,
    input  logic [ 1:0] mem_wb_sel,
    input  logic        mem_mem_read_en,    // is_load flag, needed for WB forwarding
    input  logic [ 1:0] mem_mem_size,       // needed for WB byte extraction
    input  logic        mem_mem_unsigned,   // needed for WB sign/zero extension
    input  logic [ 1:0] mem_addr_low,       // ALU_result[1:0], needed for WB byte extraction

    // Data out (to WB stage)
    output logic [31:0] wb_alu_result,
    output logic [31:0] wb_pc,
    output logic [ 4:0] wb_rd,
    output logic        wb_reg_write_en,
    output logic [ 1:0] wb_wb_sel,
    output logic        wb_is_load,
    output logic [ 1:0] wb_mem_size,
    output logic        wb_mem_unsigned,
    output logic [ 1:0] wb_addr_low
);

    // ---- Handshake (WB is last stage, no downstream backpressure) ----
    wire wb_ready_go = 1'b1;
    assign wb_allowin = !wb_valid || wb_ready_go;   // simplifies to 1

    // ---- Pipeline register (no flush) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_valid         <= 1'b0;
            wb_alu_result    <= 32'd0;
            wb_pc            <= 32'd0;
            wb_rd            <= 5'd0;
            wb_reg_write_en  <= 1'b0;
            wb_wb_sel        <= 2'd0;
            wb_is_load       <= 1'b0;
            wb_mem_size      <= 2'd0;
            wb_mem_unsigned  <= 1'b0;
            wb_addr_low      <= 2'd0;
        end else if (wb_allowin) begin
            wb_valid         <= mem_valid & mem_ready_go;
            wb_alu_result    <= mem_alu_result;
            wb_pc            <= mem_pc;
            wb_rd            <= mem_rd;
            wb_reg_write_en  <= mem_reg_write_en;
            wb_wb_sel        <= mem_wb_sel;
            wb_is_load       <= mem_mem_read_en;
            wb_mem_size      <= mem_mem_size;
            wb_mem_unsigned  <= mem_mem_unsigned;
            wb_addr_low      <= mem_addr_low;
        end
    end

endmodule
