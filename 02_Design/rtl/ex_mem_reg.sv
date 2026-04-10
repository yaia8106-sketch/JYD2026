// ============================================================
// Module: ex_mem_reg
// Description: EX/MEM pipeline register
// Note: No flush (branch instruction itself flows through normally)
// ============================================================

module ex_mem_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    output logic        mem_allowin,
    output logic        mem_valid,
    input  logic        mem_ready_go,
    input  logic        wb_allowin,

    // Data in (from EX stage)
    input  logic [31:0] ex_alu_result,
    input  logic [31:0] ex_pc,
    input  logic [ 4:0] ex_rd,
    input  logic        ex_reg_write_en,
    input  logic [ 1:0] ex_wb_sel,
    input  logic        ex_mem_read_en,
    input  logic [ 1:0] ex_mem_size,
    input  logic        ex_mem_unsigned,

    // Data out (to MEM stage)
    output logic [31:0] mem_alu_result,
    output logic [31:0] mem_pc,
    output logic [ 4:0] mem_rd,
    output logic        mem_reg_write_en,
    output logic [ 1:0] mem_wb_sel,
    output logic        mem_mem_read_en,    // = mem_is_load
    output logic [ 1:0] mem_mem_size,
    output logic        mem_mem_unsigned
);

    // ---- Handshake ----
    assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

    // ---- Pipeline register (no flush) ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_valid         <= 1'b0;
            mem_alu_result    <= 32'd0;
            mem_pc            <= 32'd0;
            mem_rd            <= 5'd0;
            mem_reg_write_en  <= 1'b0;
            mem_wb_sel        <= 2'd0;
            mem_mem_read_en   <= 1'b0;
            mem_mem_size      <= 2'd0;
            mem_mem_unsigned  <= 1'b0;
        end else if (mem_allowin) begin
            mem_valid         <= ex_valid & ex_ready_go;
            mem_alu_result    <= ex_alu_result;
            mem_pc            <= ex_pc;
            mem_rd            <= ex_rd;
            mem_reg_write_en  <= ex_reg_write_en;
            mem_wb_sel        <= ex_wb_sel;
            mem_mem_read_en   <= ex_mem_read_en;
            mem_mem_size      <= ex_mem_size;
            mem_mem_unsigned  <= ex_mem_unsigned;
        end
    end

endmodule
