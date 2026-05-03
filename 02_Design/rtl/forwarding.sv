// ============================================================
// Module: forwarding
// Description: Forwarding MUX (slot0/slot1 rs1/rs2) + Load-Use hazard detection
// Spec: 02_Design/spec/forwarding_spec.md
// Style: parallel match + priority encode + AND-OR MUX
//
// FIX: EX/MEM forwarding now handles JAL/JALR (wb_sel=10 → PC+4)
//   Previously forwarded alu_result even for JAL/JALR, which gives
//   the jump TARGET instead of the LINK ADDRESS (PC+4).
//   This was masked pre-predictor (JAL always flushed, so no
//   dependent instruction could follow in the pipeline).
// ============================================================

module forwarding (
    // Slot 0 ID stage
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // Slot 1 ID stage
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1_addr,
    input  logic [ 4:0] id_s1_rs2_addr,
    input  logic [31:0] rf_s1_rs1_data,
    input  logic [31:0] rf_s1_rs2_data,

    // Slot 0 EX stage
    input  logic        ex_valid,
    input  logic        ex_reg_write,
    input  logic        ex_mem_read,
    input  logic [ 4:0] ex_rd,
    input  logic [31:0] ex_alu_result,
    input  logic [31:0] ex_pc_plus_4,   // pre-computed in EX stage
    input  logic [ 1:0] ex_wb_sel,      // 00=ALU, 01=DRAM, 10=PC+4

    // Slot 1 EX stage
    input  logic        ex_s1_valid,
    input  logic        ex_s1_reg_write,
    input  logic        ex_s1_mem_read,
    input  logic [ 4:0] ex_s1_rd,
    input  logic [31:0] ex_s1_alu_result,
    input  logic [31:0] ex_s1_pc_plus_4,
    input  logic [ 1:0] ex_s1_wb_sel,

    // Slot 0 MEM stage
    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_pc_plus_4,  // pre-computed, registered in EX/MEM
    input  logic [ 1:0] mem_wb_sel,     // 00=ALU, 01=DRAM, 10=PC+4

    // Slot 1 MEM stage
    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write,
    input  logic        mem_s1_is_load,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,
    input  logic [ 1:0] mem_s1_wb_sel,

    // Slot 0 WB stage
    input  logic        wb_valid,
    input  logic        wb_reg_write,
    input  logic [ 4:0] wb_rd,
    input  logic [31:0] wb_write_data,

    // Slot 1 WB stage
    input  logic        wb_s1_valid,
    input  logic        wb_s1_reg_write,
    input  logic [ 4:0] wb_s1_rd,
    input  logic [31:0] wb_s1_write_data,

    // Outputs
    output logic [31:0] id_rs1_data,
    output logic [31:0] id_rs2_data,
    output logic [31:0] id_s1_rs1_data,
    output logic [31:0] id_s1_rs2_data,
    output logic        id_ready_go
);

    // ================================================================
    //  Forwarding value computation
    //  For EX/MEM stages: if wb_sel==10 (JAL/JALR), forward PC+4
    //  For wb_sel==01 (load), value not ready yet → handled by stall
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel     == 2'b10) ? ex_pc_plus_4     : ex_alu_result;
    wire [31:0] ex_s1_fwd_val  = (ex_s1_wb_sel  == 2'b10) ? ex_s1_pc_plus_4  : ex_s1_alu_result;
    wire [31:0] mem_fwd_val    = (mem_wb_sel    == 2'b10) ? mem_pc_plus_4    : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;

`define FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    wire TAG``_s1_ex_hit  = ex_s1_valid  && ex_s1_reg_write  && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit  = ex_valid     && ex_reg_write     && (ex_rd    != 5'd0) && (ex_rd    == SRC_ADDR); \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load && (mem_s1_rd != 5'd0) && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid    && mem_reg_write    && !mem_is_load    && (mem_rd    != 5'd0) && (mem_rd    == SRC_ADDR); \
    wire TAG``_s1_wb_hit  = wb_s1_valid  && wb_s1_reg_write  && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit  = wb_valid     && wb_reg_write     && (wb_rd    != 5'd0) && (wb_rd    == SRC_ADDR); \
    assign OUT_DATA = TAG``_s1_ex_hit  ? ex_s1_fwd_val    : \
                      TAG``_s0_ex_hit  ? ex_fwd_val       : \
                      TAG``_s1_mem_hit ? mem_s1_fwd_val   : \
                      TAG``_s0_mem_hit ? mem_fwd_val      : \
                      TAG``_s1_wb_hit  ? wb_s1_write_data : \
                      TAG``_s0_wb_hit  ? wb_write_data    : \
                                          RF_DATA

    `FWD_MUX(s0_rs1, id_rs1_addr,    rf_rs1_data,    id_rs1_data);
    `FWD_MUX(s0_rs2, id_rs2_addr,    rf_rs2_data,    id_rs2_data);
    `FWD_MUX(s1_rs1, id_s1_rs1_addr, rf_s1_rs1_data, id_s1_rs1_data);
    `FWD_MUX(s1_rs2, id_s1_rs2_addr, rf_s1_rs2_data, id_s1_rs2_data);

`undef FWD_MUX

    // ================================================================
    //  Load-Use Hazard Detection
    // ================================================================

    // Load in EX: data available at WB, still 2 stages away
    wire id_s0_uses_ex_load  = (ex_rd == id_rs1_addr) | (ex_rd == id_rs2_addr);
    wire id_s1_uses_ex_load  = id_s1_valid & ((ex_rd == id_s1_rs1_addr) | (ex_rd == id_s1_rs2_addr));
    wire load_in_ex  = ex_valid  & ex_mem_read & (ex_rd != 5'd0)
                     & (id_s0_uses_ex_load | id_s1_uses_ex_load);

    wire id_s0_uses_s1_ex_load = (ex_s1_rd == id_rs1_addr) | (ex_s1_rd == id_rs2_addr);
    wire id_s1_uses_s1_ex_load = id_s1_valid & ((ex_s1_rd == id_s1_rs1_addr) | (ex_s1_rd == id_s1_rs2_addr));
    wire load_in_s1_ex = ex_s1_valid & ex_s1_mem_read & (ex_s1_rd != 5'd0)
                       & (id_s0_uses_s1_ex_load | id_s1_uses_s1_ex_load);

    // Load in MEM: dram_dout not yet updated, still 1 stage away
    wire id_s0_uses_mem_load = (mem_rd == id_rs1_addr) | (mem_rd == id_rs2_addr);
    wire id_s1_uses_mem_load = id_s1_valid & ((mem_rd == id_s1_rs1_addr) | (mem_rd == id_s1_rs2_addr));
    wire load_in_mem = mem_valid & mem_is_load & (mem_rd != 5'd0)
                     & (id_s0_uses_mem_load | id_s1_uses_mem_load);

    wire id_s0_uses_s1_mem_load = (mem_s1_rd == id_rs1_addr) | (mem_s1_rd == id_rs2_addr);
    wire id_s1_uses_s1_mem_load = id_s1_valid & ((mem_s1_rd == id_s1_rs1_addr) | (mem_s1_rd == id_s1_rs2_addr));
    wire load_in_s1_mem = mem_s1_valid & mem_s1_is_load & (mem_s1_rd != 5'd0)
                        & (id_s0_uses_s1_mem_load | id_s1_uses_s1_mem_load);

    wire load_use_hazard = load_in_ex | load_in_s1_ex | load_in_mem | load_in_s1_mem;
    assign id_ready_go = ~load_use_hazard;

endmodule
