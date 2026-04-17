// ============================================================
// Module: id_ex_reg
// Description: ID/EX pipeline register
// Note: ALU operands (alu_src1/alu_src2) are pre-selected in ID stage
//       to reduce EX critical path. Raw rs1/rs2 still carried for
//       branch comparison and store data.
// ============================================================

module id_ex_reg (
    input  logic        clk,
    input  logic        rst_n,

    // Handshake
    input  logic        id_valid,
    input  logic        id_ready_go,
    output logic        ex_allowin,
    output logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,

    // Flush
    input  logic        ex_flush,

    // Data in (from ID stage)
    input  logic [31:0] id_pc,
    input  logic [31:0] id_alu_src1,       // pre-selected ALU operand 1
    input  logic [31:0] id_alu_src2,       // pre-selected ALU operand 2
    input  logic [31:0] id_rs1_data,       // raw rs1 (for branch comparison)
    input  logic [31:0] id_rs2_data,       // raw rs2 (for branch comparison + store)
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
    input  logic        id_pred_taken,     // prediction flag from IF stage
    input  logic [31:0] id_pred_target,    // predicted target from IF stage

    // Data out (to EX stage)
    output logic [31:0] ex_pc,
    output logic [31:0] ex_alu_src1,
    output logic [31:0] ex_alu_src2,
    output logic [31:0] ex_rs1_data,
    output logic [31:0] ex_rs2_data,
    output logic [ 4:0] ex_rd,
    output logic [ 4:0] ex_rs1_addr,
    output logic [ 4:0] ex_rs2_addr,
    output logic [ 3:0] ex_alu_op,
    output logic        ex_reg_write_en,
    output logic [ 1:0] ex_wb_sel,
    output logic        ex_mem_read_en,
    output logic        ex_mem_write_en,
    output logic [ 1:0] ex_mem_size,
    output logic        ex_mem_unsigned,
    output logic        ex_is_branch,
    output logic [ 2:0] ex_branch_cond,
    output logic        ex_is_jal,
    output logic        ex_is_jalr,
    output logic        ex_pred_taken,     // prediction flag for EX stage
    output logic [31:0] ex_pred_target     // predicted target for EX stage
);

    // ---- Handshake ----
    assign ex_allowin = !ex_valid || (ex_ready_go & mem_allowin);

    // ---- Pipeline register ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ex_valid         <= 1'b0;
            ex_pc            <= 32'd0;
            ex_alu_src1      <= 32'd0;
            ex_alu_src2      <= 32'd0;
            ex_rs1_data      <= 32'd0;
            ex_rs2_data      <= 32'd0;
            ex_rd            <= 5'd0;
            ex_rs1_addr      <= 5'd0;
            ex_rs2_addr      <= 5'd0;
            ex_alu_op        <= 4'd0;
            ex_reg_write_en  <= 1'b0;
            ex_wb_sel        <= 2'd0;
            ex_mem_read_en   <= 1'b0;
            ex_mem_write_en  <= 1'b0;
            ex_mem_size      <= 2'd0;
            ex_mem_unsigned  <= 1'b0;
            ex_is_branch     <= 1'b0;
            ex_branch_cond   <= 3'd0;
            ex_is_jal        <= 1'b0;
            ex_is_jalr       <= 1'b0;
            ex_pred_taken    <= 1'b0;
            ex_pred_target   <= 32'd0;
        end else if (ex_flush) begin
            ex_valid         <= 1'b0;
        end else if (ex_allowin) begin
            ex_valid         <= id_valid & id_ready_go;
            ex_pc            <= id_pc;
            ex_alu_src1      <= id_alu_src1;
            ex_alu_src2      <= id_alu_src2;
            ex_rs1_data      <= id_rs1_data;
            ex_rs2_data      <= id_rs2_data;
            ex_rd            <= id_rd;
            ex_rs1_addr      <= id_rs1_addr;
            ex_rs2_addr      <= id_rs2_addr;
            ex_alu_op        <= id_alu_op;
            ex_reg_write_en  <= id_reg_write_en;
            ex_wb_sel        <= id_wb_sel;
            ex_mem_read_en   <= id_mem_read_en;
            ex_mem_write_en  <= id_mem_write_en;
            ex_mem_size      <= id_mem_size;
            ex_mem_unsigned  <= id_mem_unsigned;
            ex_is_branch     <= id_is_branch;
            ex_branch_cond   <= id_branch_cond;
            ex_is_jal        <= id_is_jal;
            ex_is_jalr       <= id_is_jalr;
            ex_pred_taken    <= id_pred_taken;
            ex_pred_target   <= id_pred_target;
        end
    end

endmodule
