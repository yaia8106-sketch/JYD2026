// ============================================================
// Module: ex_mem_reg_s1
// Description: Slot 1 EX/MEM shadow register.
// Phase 1 keeps ex_s1_valid at 0, so this chain is inert.
// ============================================================

module ex_mem_reg_s1 (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_s1_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,

    input  logic [31:0] ex_s1_pc,
    input  logic [31:0] ex_s1_inst,
    input  logic [ 4:0] ex_s1_rd,
    input  logic        ex_s1_reg_write_en,
    input  logic [ 1:0] ex_s1_wb_sel,

    output logic        mem_s1_valid,
    output logic [31:0] mem_s1_pc,
    output logic [31:0] mem_s1_inst,
    output logic [ 4:0] mem_s1_rd,
    output logic        mem_s1_reg_write_en,
    output logic [ 1:0] mem_s1_wb_sel
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_s1_valid        <= 1'b0;
            mem_s1_pc           <= 32'd0;
            mem_s1_inst         <= 32'd0;
            mem_s1_rd           <= 5'd0;
            mem_s1_reg_write_en <= 1'b0;
            mem_s1_wb_sel       <= 2'd0;
        end else if (mem_allowin) begin
            mem_s1_valid        <= ex_s1_valid & ex_ready_go & ~mem_branch_flush;
            mem_s1_pc           <= ex_s1_pc;
            mem_s1_inst         <= ex_s1_inst;
            mem_s1_rd           <= ex_s1_rd;
            mem_s1_reg_write_en <= ex_s1_reg_write_en & ex_s1_valid;
            mem_s1_wb_sel       <= ex_s1_wb_sel;
        end
    end

endmodule
