// ============================================================
// Module: id_ex_reg_s1
// Description: Slot 1 ID/EX shadow register.
// Phase 2 carries the Slot 1 datapath; until Phase 3, id_s1_valid stays 0.
// ============================================================

module id_ex_reg_s1 (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        id_s1_valid,
    input  logic        id_ready_go,
    input  logic        ex_allowin,
    input  logic        ex_flush,

    input  logic [31:0] id_pc,
    input  logic [31:0] id_inst,
    input  logic [31:0] id_alu_src1,
    input  logic [31:0] id_alu_src2,
    input  logic [31:0] id_rs1_data,
    input  logic [31:0] id_rs2_data,
    input  logic [ 4:0] id_rd,
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [ 3:0] id_alu_op,
    input  logic        id_reg_write_en,
    input  logic [ 1:0] id_wb_sel,
    input  logic        id_mem_read_en,
    input  logic        id_mem_write_en,
    input  logic [ 1:0] id_mem_size,
    input  logic        id_mem_unsigned,
    input  logic        id_is_branch,
    input  logic [ 2:0] id_branch_cond,
    input  logic        id_is_jal,
    input  logic        id_is_jalr,

    output logic        ex_s1_valid,
    output logic [31:0] ex_s1_pc,
    output logic [31:0] ex_s1_inst,
    output logic [31:0] ex_s1_alu_src1,
    output logic [31:0] ex_s1_alu_src2,
    output logic [31:0] ex_s1_rs1_data,
    output logic [31:0] ex_s1_rs2_data,
    output logic [ 4:0] ex_s1_rd,
    output logic [ 4:0] ex_s1_rs1_addr,
    output logic [ 4:0] ex_s1_rs2_addr,
    output logic [ 3:0] ex_s1_alu_op,
    output logic        ex_s1_reg_write_en,
    output logic [ 1:0] ex_s1_wb_sel,
    output logic        ex_s1_mem_read_en,
    output logic        ex_s1_mem_write_en,
    output logic [ 1:0] ex_s1_mem_size,
    output logic        ex_s1_mem_unsigned,
    output logic        ex_s1_is_branch,
    output logic [ 2:0] ex_s1_branch_cond,
    output logic        ex_s1_is_jal,
    output logic        ex_s1_is_jalr
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_s1_valid        <= 1'b0;
            ex_s1_pc           <= 32'd0;
            ex_s1_inst         <= 32'd0;
            ex_s1_alu_src1     <= 32'd0;
            ex_s1_alu_src2     <= 32'd0;
            ex_s1_rs1_data     <= 32'd0;
            ex_s1_rs2_data     <= 32'd0;
            ex_s1_rd           <= 5'd0;
            ex_s1_rs1_addr     <= 5'd0;
            ex_s1_rs2_addr     <= 5'd0;
            ex_s1_alu_op       <= 4'd0;
            ex_s1_reg_write_en <= 1'b0;
            ex_s1_wb_sel       <= 2'd0;
            ex_s1_mem_read_en  <= 1'b0;
            ex_s1_mem_write_en <= 1'b0;
            ex_s1_mem_size     <= 2'd0;
            ex_s1_mem_unsigned <= 1'b0;
            ex_s1_is_branch    <= 1'b0;
            ex_s1_branch_cond  <= 3'd0;
            ex_s1_is_jal       <= 1'b0;
            ex_s1_is_jalr      <= 1'b0;
        end else if (ex_flush) begin
            ex_s1_valid        <= 1'b0;
        end else if (ex_allowin) begin
            ex_s1_valid        <= id_s1_valid & id_ready_go;
            ex_s1_pc           <= id_pc;
            ex_s1_inst         <= id_inst;
            ex_s1_alu_src1     <= id_alu_src1;
            ex_s1_alu_src2     <= id_alu_src2;
            ex_s1_rs1_data     <= id_rs1_data;
            ex_s1_rs2_data     <= id_rs2_data;
            ex_s1_rd           <= id_rd;
            ex_s1_rs1_addr     <= id_rs1_addr;
            ex_s1_rs2_addr     <= id_rs2_addr;
            ex_s1_alu_op       <= id_alu_op;
            ex_s1_reg_write_en <= id_reg_write_en & id_s1_valid;
            ex_s1_wb_sel       <= id_wb_sel;
            ex_s1_mem_read_en  <= id_mem_read_en & id_s1_valid;
            ex_s1_mem_write_en <= id_mem_write_en & id_s1_valid;
            ex_s1_mem_size     <= id_mem_size;
            ex_s1_mem_unsigned <= id_mem_unsigned;
            ex_s1_is_branch    <= id_is_branch & id_s1_valid;
            ex_s1_branch_cond  <= id_branch_cond;
            ex_s1_is_jal       <= id_is_jal & id_s1_valid;
            ex_s1_is_jalr      <= id_is_jalr & id_s1_valid;
        end
    end

endmodule
