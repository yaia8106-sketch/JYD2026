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
    input  logic        id_rs1_wb_repair,
    input  logic        id_rs2_wb_repair,
    input  logic [ 4:0] id_rd,
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic        id_alu_src1_is_rs1,
    input  logic        id_alu_src2_is_rs2,
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
    input  logic        id_pred_taken,
    input  logic [31:0] id_pred_target,
    input  logic        id_pred_source_abtb,
    input  logic        id_stage1_branch_owned,
    input  logic        id_abtb_hit,
    input  logic        id_abtb_way,
    input  logic [ 1:0] id_abtb_cfi_type,
    input  logic [31:0] id_abtb_target,
    input  logic        id_abtb_pred_taken,
    input  logic [31:0] id_abtb_pred_target,
    input  logic        id_abtb_update_qualified,
    input  logic [ 1:0] id_abtb_update_cfi_type,
    input  logic [ 7:0] id_stage1_pht_index,
    input  logic [ 1:0] id_stage1_pht_counter,

    output logic        ex_s1_valid,
    output logic [31:0] ex_s1_pc,
    output logic [31:0] ex_s1_inst,
    output logic [31:0] ex_s1_alu_src1,
    output logic [31:0] ex_s1_alu_src2,
    output logic [31:0] ex_s1_rs1_data,
    output logic [31:0] ex_s1_rs2_data,
    output logic        ex_s1_rs1_wb_repair,
    output logic        ex_s1_rs2_wb_repair,
    output logic [ 4:0] ex_s1_rd,
    output logic [ 4:0] ex_s1_rs1_addr,
    output logic [ 4:0] ex_s1_rs2_addr,
    output logic        ex_s1_alu_src1_is_rs1,
    output logic        ex_s1_alu_src2_is_rs2,
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
    output logic        ex_s1_is_jalr,
    output logic        ex_s1_pred_taken,
    output logic [31:0] ex_s1_pred_target,
    output logic        ex_s1_pred_source_abtb,
    output logic        ex_s1_stage1_branch_owned,
    // Shadow ABTB training consumes only hit/way plus decoded update
    // qualification/type. Wider prediction metadata is kept observable in
    // simulation but must remain removable from synthesis until steering uses it.
    output logic        ex_s1_abtb_hit,
    output logic        ex_s1_abtb_way,
    output logic [ 1:0] ex_s1_abtb_cfi_type,
    output logic [31:0] ex_s1_abtb_target,
    output logic        ex_s1_abtb_pred_taken,
    output logic [31:0] ex_s1_abtb_pred_target,
    output logic        ex_s1_abtb_update_qualified,
    output logic [ 1:0] ex_s1_abtb_update_cfi_type,
    output logic [ 7:0] ex_s1_stage1_pht_index,
    output logic [ 1:0] ex_s1_stage1_pht_counter
);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_s1_valid        <= 1'b0;
            ex_s1_pc           <= 32'd0;
            ex_s1_inst         <= 32'd0;
            ex_s1_alu_src1     <= 32'd0;
            ex_s1_alu_src2     <= 32'd0;
            ex_s1_rs1_data     <= 32'd0;
            ex_s1_rs2_data     <= 32'd0;
            ex_s1_rs1_wb_repair <= 1'b0;
            ex_s1_rs2_wb_repair <= 1'b0;
            ex_s1_rd           <= 5'd0;
            ex_s1_rs1_addr     <= 5'd0;
            ex_s1_rs2_addr     <= 5'd0;
            ex_s1_alu_src1_is_rs1 <= 1'b0;
            ex_s1_alu_src2_is_rs2 <= 1'b0;
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
            ex_s1_pred_taken     <= 1'b0;
            ex_s1_pred_target    <= 32'd0;
            ex_s1_pred_source_abtb <= 1'b0;
            ex_s1_stage1_branch_owned <= 1'b0;
            ex_s1_abtb_hit         <= 1'b0;
            ex_s1_abtb_way         <= 1'b0;
            ex_s1_abtb_cfi_type    <= 2'd0;
            ex_s1_abtb_target      <= 32'd0;
            ex_s1_abtb_pred_taken  <= 1'b0;
            ex_s1_abtb_pred_target <= 32'd0;
            ex_s1_abtb_update_qualified <= 1'b0;
            ex_s1_abtb_update_cfi_type <= 2'd0;
            ex_s1_stage1_pht_index <= 8'd0;
            ex_s1_stage1_pht_counter <= 2'b01;
        end else if (ex_flush) begin
            ex_s1_valid        <= 1'b0;
            ex_s1_rs1_wb_repair <= 1'b0;
            ex_s1_rs2_wb_repair <= 1'b0;
            ex_s1_pred_taken     <= 1'b0;
            ex_s1_pred_source_abtb <= 1'b0;
            ex_s1_stage1_branch_owned <= 1'b0;
        end else if (ex_allowin) begin
            ex_s1_valid        <= id_s1_valid & id_ready_go;
            ex_s1_pc           <= id_pc;
            ex_s1_inst         <= id_inst;
            ex_s1_alu_src1     <= id_alu_src1;
            ex_s1_alu_src2     <= id_alu_src2;
            ex_s1_rs1_data     <= id_rs1_data;
            ex_s1_rs2_data     <= id_rs2_data;
            ex_s1_rs1_wb_repair <= id_rs1_wb_repair & id_s1_valid;
            ex_s1_rs2_wb_repair <= id_rs2_wb_repair & id_s1_valid;
            ex_s1_rd           <= id_rd;
            ex_s1_rs1_addr     <= id_rs1_addr;
            ex_s1_rs2_addr     <= id_rs2_addr;
            ex_s1_alu_src1_is_rs1 <= id_alu_src1_is_rs1;
            ex_s1_alu_src2_is_rs2 <= id_alu_src2_is_rs2;
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
            ex_s1_pred_taken     <= id_pred_taken;
            ex_s1_pred_target    <= id_pred_target;
            ex_s1_pred_source_abtb <= id_pred_source_abtb;
            ex_s1_stage1_branch_owned <= id_stage1_branch_owned;
            ex_s1_abtb_hit         <= id_abtb_hit;
            ex_s1_abtb_way         <= id_abtb_way;
            ex_s1_abtb_cfi_type    <= id_abtb_cfi_type;
            ex_s1_abtb_target      <= id_abtb_target;
            ex_s1_abtb_pred_taken  <= id_abtb_pred_taken;
            ex_s1_abtb_pred_target <= id_abtb_pred_target;
            ex_s1_abtb_update_qualified <= id_abtb_update_qualified;
            ex_s1_abtb_update_cfi_type <= id_abtb_update_cfi_type;
            ex_s1_stage1_pht_index <= id_stage1_pht_index;
            ex_s1_stage1_pht_counter <= id_stage1_pht_counter;
        end
    end

endmodule
