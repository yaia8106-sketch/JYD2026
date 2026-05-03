// ============================================================
// Module: mem_wb_reg_s1
// Description: Slot 1 MEM/WB shadow register.
// Phase 2 carries the Slot 1 datapath; until Phase 3, mem_s1_valid stays 0.
// ============================================================

module mem_wb_reg_s1 (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        mem_s1_valid,
    input  logic        mem_ready_go,
    input  logic        wb_allowin,

    input  logic [31:0] mem_s1_pc,
    input  logic [31:0] mem_s1_inst,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,
    input  logic [ 4:0] mem_s1_rd,
    input  logic        mem_s1_reg_write_en,
    input  logic [ 1:0] mem_s1_wb_sel,

    output logic        wb_s1_valid,
    output logic [31:0] wb_s1_pc,
    output logic [31:0] wb_s1_inst,
    output logic [31:0] wb_s1_alu_result,
    output logic [31:0] wb_s1_pc_plus_4,
    output logic [ 4:0] wb_s1_rd,
    output logic        wb_s1_reg_write_en,
    output logic [ 1:0] wb_s1_wb_sel
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_s1_valid        <= 1'b0;
            wb_s1_pc           <= 32'd0;
            wb_s1_inst         <= 32'd0;
            wb_s1_alu_result   <= 32'd0;
            wb_s1_pc_plus_4    <= 32'd0;
            wb_s1_rd           <= 5'd0;
            wb_s1_reg_write_en <= 1'b0;
            wb_s1_wb_sel       <= 2'd0;
        end else if (wb_allowin) begin
            wb_s1_valid        <= mem_s1_valid & mem_ready_go;
            wb_s1_pc           <= mem_s1_pc;
            wb_s1_inst         <= mem_s1_inst;
            wb_s1_alu_result   <= mem_s1_alu_result;
            wb_s1_pc_plus_4    <= mem_s1_pc_plus_4;
            wb_s1_rd           <= mem_s1_rd;
            wb_s1_reg_write_en <= mem_s1_reg_write_en & mem_s1_valid;
            wb_s1_wb_sel       <= mem_s1_wb_sel;
        end
    end

endmodule
