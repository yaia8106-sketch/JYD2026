// ============================================================
// Module: forwarding
// Description: Forwarding MUX (rs1/rs2) + Load-Use hazard detection
// Spec: 02_Design/spec/forwarding_spec.md
// Style: parallel match + priority encode + AND-OR MUX
// ============================================================

module forwarding (
    // ID stage
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // EX stage
    input  logic        ex_valid,
    input  logic        ex_reg_write,
    input  logic        ex_mem_read,
    input  logic [ 4:0] ex_rd,
    input  logic [31:0] ex_alu_result,

    // MEM stage
    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,

    // WB stage
    input  logic        wb_valid,
    input  logic        wb_reg_write,
    input  logic [ 4:0] wb_rd,
    input  logic [31:0] wb_write_data,

    // Outputs
    output logic [31:0] id_rs1_data,
    output logic [31:0] id_rs2_data,
    output logic        id_ready_go
);

    // ================================================================
    //  RS1 Forwarding MUX
    // ================================================================

    // ---- Step 1: Parallel match ----
    wire rs1_ex_match  = ex_valid  & ex_reg_write  & (ex_rd  != 5'd0) & (ex_rd  == id_rs1_addr);
    wire rs1_mem_match = mem_valid & mem_reg_write  & ~mem_is_load & (mem_rd != 5'd0) & (mem_rd == id_rs1_addr);
    wire rs1_wb_match  = wb_valid  & wb_reg_write   & (wb_rd  != 5'd0) & (wb_rd  == id_rs1_addr);

    // ---- Step 2: Priority encode (one-hot) ----
    wire rs1_sel_ex  = rs1_ex_match;
    wire rs1_sel_mem = rs1_mem_match & ~rs1_ex_match;
    wire rs1_sel_wb  = rs1_wb_match  & ~rs1_ex_match & ~rs1_mem_match;
    wire rs1_sel_rf  = ~rs1_ex_match & ~rs1_mem_match & ~rs1_wb_match;

    // ---- Step 3: AND-OR MUX ----
    assign id_rs1_data = ({32{rs1_sel_ex}}  & ex_alu_result)
                       | ({32{rs1_sel_mem}} & mem_alu_result)
                       | ({32{rs1_sel_wb}}  & wb_write_data)
                       | ({32{rs1_sel_rf}}  & rf_rs1_data);

    // ================================================================
    //  RS2 Forwarding MUX (same structure)
    // ================================================================

    wire rs2_ex_match  = ex_valid  & ex_reg_write  & (ex_rd  != 5'd0) & (ex_rd  == id_rs2_addr);
    wire rs2_mem_match = mem_valid & mem_reg_write  & ~mem_is_load & (mem_rd != 5'd0) & (mem_rd == id_rs2_addr);
    wire rs2_wb_match  = wb_valid  & wb_reg_write   & (wb_rd  != 5'd0) & (wb_rd  == id_rs2_addr);

    wire rs2_sel_ex  = rs2_ex_match;
    wire rs2_sel_mem = rs2_mem_match & ~rs2_ex_match;
    wire rs2_sel_wb  = rs2_wb_match  & ~rs2_ex_match & ~rs2_mem_match;
    wire rs2_sel_rf  = ~rs2_ex_match & ~rs2_mem_match & ~rs2_wb_match;

    assign id_rs2_data = ({32{rs2_sel_ex}}  & ex_alu_result)
                       | ({32{rs2_sel_mem}} & mem_alu_result)
                       | ({32{rs2_sel_wb}}  & wb_write_data)
                       | ({32{rs2_sel_rf}}  & rf_rs2_data);

    // ================================================================
    //  Load-Use Hazard Detection
    // ================================================================

    // Load in EX: data available at WB, still 2 stages away
    wire load_in_ex  = ex_valid  & ex_mem_read & (ex_rd != 5'd0)
                     & ((ex_rd == id_rs1_addr) | (ex_rd == id_rs2_addr));

    // Load in MEM: dram_dout not yet updated, still 1 stage away
    wire load_in_mem = mem_valid & mem_is_load & (mem_rd != 5'd0)
                     & ((mem_rd == id_rs1_addr) | (mem_rd == id_rs2_addr));

    wire load_use_hazard = load_in_ex | load_in_mem;
    assign id_ready_go = ~load_use_hazard;

endmodule
