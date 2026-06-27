// ============================================================
// Module: mem_wb_reg
// Description: MEM/WB pipeline register
// Note: load_data is extracted and extended in MEM, then captured here so the
//       WB forwarding path starts from a registered 32-bit architectural value.
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
    input  logic [31:0] mem_pc_plus_4,
    input  logic [ 4:0] mem_rd,
    input  logic        mem_reg_write_en,
    input  logic [ 1:0] mem_wb_sel,
    input  logic        mem_mem_read_en,    // is_load flag, needed for WB forwarding
    input  logic        mem_load_valid,     // either slot completes a load this cycle
    input  logic [31:0] mem_load_data,      // extracted/extended MEM-stage load value

    // Data out (to WB stage)
    output logic [31:0] wb_alu_result,
    output logic [31:0] wb_pc_plus_4,
    output logic [ 4:0] wb_rd,
    output logic        wb_reg_write_en,
    output logic [ 1:0] wb_wb_sel,
    output logic        wb_is_load,
    output logic [31:0] wb_load_data        // registered load data for WB/repair
);

    // ---- Handshake (WB is last stage, no downstream backpressure) ----
    wire wb_ready_go = 1'b1;
    assign wb_allowin = !wb_valid || wb_ready_go;   // simplifies to 1

    // ---- Pipeline register (no flush) ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_valid         <= 1'b0;
            wb_alu_result    <= 32'd0;
            wb_pc_plus_4     <= 32'd0;
            wb_rd            <= 5'd0;
            wb_reg_write_en  <= 1'b0;
            wb_wb_sel        <= 2'd0;
            wb_is_load       <= 1'b0;
            wb_load_data     <= 32'd0;
        end else if (wb_allowin) begin
            wb_valid         <= mem_valid & mem_ready_go;
            wb_alu_result    <= mem_alu_result;
            wb_pc_plus_4     <= mem_pc_plus_4;
            wb_rd            <= mem_rd;
            wb_reg_write_en  <= mem_reg_write_en;
            wb_wb_sel        <= mem_wb_sel;
            wb_is_load       <= mem_mem_read_en;
            if (mem_load_valid & mem_ready_go)
                wb_load_data <= mem_load_data;
        end
    end

endmodule
