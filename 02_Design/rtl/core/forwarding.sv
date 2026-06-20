// ============================================================
// Module: forwarding
// Description: Forwarding MUX (slot0/slot1 rs1/rs2) + ID hazard detection
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
    input  logic        id_rs1_used,
    input  logic        id_rs2_used,
    input  logic        id_s0_alu_only,
    input  logic        id_s0_jalr,
    input  logic        id_s0_branch,
    input  logic        id_s0_mem_read,
    input  logic        id_s0_mem_write,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // Slot 1 ID stage
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1_addr,
    input  logic [ 4:0] id_s1_rs2_addr,
    input  logic        id_s1_rs1_used,
    input  logic        id_s1_rs2_used,
    input  logic        id_s1_repair_ok,
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
    input  logic        mem_load_ready,
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
    output logic [31:0] id_branch_rs1_data,
    output logic [31:0] id_branch_rs2_data,
    output logic [31:0] id_rs1_jalr_data,
    output logic [31:0] id_s1_rs1_data,
    output logic [31:0] id_s1_rs2_data,
    output logic        id_rs1_wb_repair,
    output logic        id_rs2_wb_repair,
    output logic        id_rs1_wb_repair_s1,
    output logic        id_rs2_wb_repair_s1,
    output logic        id_s1_rs1_wb_repair,
    output logic        id_s1_rs2_wb_repair,
    output logic        id_s1_rs1_wb_repair_s1,
    output logic        id_s1_rs2_wb_repair_s1,
    output logic        id_ready_go
);

    // Timing experiment: disable the MEM-ready load -> EX WB-repair fast path.
    // Ordinary WB forwarding remains enabled; consumers wait one cycle until
    // the load reaches WB, then take the value through the normal WB path.
    localparam logic ENABLE_MEM_LOAD_WB_REPAIR = 1'b0;

    // ================================================================
    //  Forwarding value computation
    //  For EX/MEM stages: if wb_sel==10 (JAL/JALR), forward PC+4
    //  For wb_sel==01 (load), value not ready yet → handled by stall.
    //  Repaired EX results are valid forwarding sources now that branch/JALR
    //  target work no longer sits in ID.
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel     == 2'b10) ? ex_pc_plus_4     : ex_alu_result;
    wire [31:0] ex_s1_fwd_val  = (ex_s1_wb_sel  == 2'b10) ? ex_s1_pc_plus_4  : ex_s1_alu_result;
    wire [31:0] mem_fwd_val    = (mem_wb_sel    == 2'b10) ? mem_pc_plus_4    : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;

`define FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    wire TAG``_s1_ex_hit  = ex_s1_valid  && ex_s1_reg_write  && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit  = ex_valid     && ex_reg_write     && (ex_rd != 5'd0) && (ex_rd == SRC_ADDR); \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load && (mem_s1_rd != 5'd0) && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid    && mem_reg_write    && !mem_is_load    && (mem_rd    != 5'd0) && (mem_rd    == SRC_ADDR); \
    wire TAG``_s1_wb_hit  = wb_s1_valid  && wb_s1_reg_write  && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit  = wb_valid     && wb_reg_write     && (wb_rd    != 5'd0) && (wb_rd    == SRC_ADDR); \
    wire TAG``_s1_ex_oh   = TAG``_s1_ex_hit; \
    wire TAG``_s0_ex_oh   = ~TAG``_s1_ex_hit & TAG``_s0_ex_hit; \
    wire TAG``_s1_mem_oh  = ~TAG``_s1_ex_hit & ~TAG``_s0_ex_hit & TAG``_s1_mem_hit; \
    wire TAG``_s0_mem_oh  = ~TAG``_s1_ex_hit & ~TAG``_s0_ex_hit & ~TAG``_s1_mem_hit & TAG``_s0_mem_hit; \
    wire TAG``_s1_wb_oh   = ~TAG``_s1_ex_hit & ~TAG``_s0_ex_hit & ~TAG``_s1_mem_hit & ~TAG``_s0_mem_hit & TAG``_s1_wb_hit; \
    wire TAG``_s0_wb_oh   = ~TAG``_s1_ex_hit & ~TAG``_s0_ex_hit & ~TAG``_s1_mem_hit & ~TAG``_s0_mem_hit & ~TAG``_s1_wb_hit & TAG``_s0_wb_hit; \
    wire TAG``_rf_oh      = ~TAG``_s1_ex_hit & ~TAG``_s0_ex_hit & ~TAG``_s1_mem_hit & ~TAG``_s0_mem_hit & ~TAG``_s1_wb_hit & ~TAG``_s0_wb_hit; \
    assign OUT_DATA = ({32{TAG``_s1_ex_oh}}  & ex_s1_fwd_val)    | \
                      ({32{TAG``_s0_ex_oh}}  & ex_fwd_val)       | \
                      ({32{TAG``_s1_mem_oh}} & mem_s1_fwd_val)   | \
                      ({32{TAG``_s0_mem_oh}} & mem_fwd_val)      | \
                      ({32{TAG``_s1_wb_oh}}  & wb_s1_write_data) | \
                      ({32{TAG``_s0_wb_oh}}  & wb_write_data)    | \
                      ({32{TAG``_rf_oh}}     & RF_DATA)

    `FWD_MUX(s0_rs1, id_rs1_addr,    rf_rs1_data,    id_rs1_data);
    `FWD_MUX(s0_rs2, id_rs2_addr,    rf_rs2_data,    id_rs2_data);
    `FWD_MUX(s1_rs1, id_s1_rs1_addr, rf_s1_rs1_data, id_s1_rs1_data);
    `FWD_MUX(s1_rs2, id_s1_rs2_addr, rf_s1_rs2_data, id_s1_rs2_data);

`undef FWD_MUX

    // Branch compare and JALR target are now resolved in EX, so the old
    // branch/JALR-only ID forwarding paths collapse to the ordinary operands.
    assign id_branch_rs1_data = id_rs1_data;
    assign id_branch_rs2_data = id_rs2_data;
    assign id_rs1_jalr_data   = id_rs1_data;

    wire id_s0_repair_ok = id_s0_alu_only
                          | id_s0_branch
                          | id_s0_jalr
                          | id_s0_mem_read
                          | id_s0_mem_write;

    wire mem_s0_load_pending = mem_valid & mem_is_load & (mem_rd != 5'd0);
    wire mem_s1_load_pending = mem_s1_valid & mem_s1_is_load
                             & (mem_s1_rd != 5'd0);
    wire mem_s0_load_repair_source = mem_s0_load_pending & mem_reg_write
                                   & mem_load_ready;
    wire mem_s1_load_repair_source = mem_s1_load_pending & mem_s1_reg_write
                                   & mem_load_ready;
    wire id_s0_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s0_repair_ok;
    wire id_s1_has_mem_load_repair_path =
        ENABLE_MEM_LOAD_WB_REPAIR & id_s1_valid & id_s1_repair_ok;
    wire id_s0_can_repair_mem_load = id_s0_has_mem_load_repair_path
                                    & mem_load_ready;
    wire id_s1_can_repair_mem_load = id_s1_has_mem_load_repair_path
                                    & mem_load_ready;

    wire s0_rs1_uses_s0_mem_load = id_rs1_used
                                 & (mem_rd == id_rs1_addr);
    wire s0_rs2_uses_s0_mem_load = id_rs2_used
                                 & (mem_rd == id_rs2_addr);
    wire s1_rs1_uses_s0_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s0_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_rd == id_s1_rs2_addr);

    wire s0_rs1_uses_s1_mem_load = id_rs1_used
                                 & (mem_s1_rd == id_rs1_addr);
    wire s0_rs2_uses_s1_mem_load = id_rs2_used
                                 & (mem_s1_rd == id_rs2_addr);
    wire s1_rs1_uses_s1_mem_load = id_s1_valid & id_s1_rs1_used
                                 & (mem_s1_rd == id_s1_rs1_addr);
    wire s1_rs2_uses_s1_mem_load = id_s1_valid & id_s1_rs2_used
                                 & (mem_s1_rd == id_s1_rs2_addr);

    wire s0_rs1_blocks_s0_mem_repair = s0_rs1_s1_ex_hit
                                     | s0_rs1_s0_ex_hit
                                     | s0_rs1_s1_mem_hit;
    wire s0_rs2_blocks_s0_mem_repair = s0_rs2_s1_ex_hit
                                     | s0_rs2_s0_ex_hit
                                     | s0_rs2_s1_mem_hit;
    wire s1_rs1_blocks_s0_mem_repair = s1_rs1_s1_ex_hit
                                     | s1_rs1_s0_ex_hit
                                     | s1_rs1_s1_mem_hit;
    wire s1_rs2_blocks_s0_mem_repair = s1_rs2_s1_ex_hit
                                     | s1_rs2_s0_ex_hit
                                     | s1_rs2_s1_mem_hit;

    wire s0_rs1_blocks_s1_mem_repair = s0_rs1_s1_ex_hit
                                     | s0_rs1_s0_ex_hit;
    wire s0_rs2_blocks_s1_mem_repair = s0_rs2_s1_ex_hit
                                     | s0_rs2_s0_ex_hit;
    wire s1_rs1_blocks_s1_mem_repair = s1_rs1_s1_ex_hit
                                     | s1_rs1_s0_ex_hit;
    wire s1_rs2_blocks_s1_mem_repair = s1_rs2_s1_ex_hit
                                     | s1_rs2_s0_ex_hit;

    wire id_rs1_wb_repair_s0_w = mem_s0_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs1_uses_s0_mem_load
                                & ~s0_rs1_blocks_s0_mem_repair;
    wire id_rs2_wb_repair_s0_w = mem_s0_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs2_uses_s0_mem_load
                                & ~s0_rs2_blocks_s0_mem_repair;
    wire id_s1_rs1_wb_repair_s0_w = mem_s0_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs1_uses_s0_mem_load
                                   & ~s1_rs1_blocks_s0_mem_repair;
    wire id_s1_rs2_wb_repair_s0_w = mem_s0_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs2_uses_s0_mem_load
                                   & ~s1_rs2_blocks_s0_mem_repair;

    wire id_rs1_wb_repair_s1_w = mem_s1_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs1_uses_s1_mem_load
                                & ~s0_rs1_blocks_s1_mem_repair;
    wire id_rs2_wb_repair_s1_w = mem_s1_load_repair_source
                                & id_s0_has_mem_load_repair_path
                                & s0_rs2_uses_s1_mem_load
                                & ~s0_rs2_blocks_s1_mem_repair;
    wire id_s1_rs1_wb_repair_s1_w = mem_s1_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs1_uses_s1_mem_load
                                   & ~s1_rs1_blocks_s1_mem_repair;
    wire id_s1_rs2_wb_repair_s1_w = mem_s1_load_repair_source
                                   & id_s1_has_mem_load_repair_path
                                   & s1_rs2_uses_s1_mem_load
                                   & ~s1_rs2_blocks_s1_mem_repair;

    assign id_rs1_wb_repair = id_rs1_wb_repair_s0_w | id_rs1_wb_repair_s1_w;
    assign id_rs2_wb_repair = id_rs2_wb_repair_s0_w | id_rs2_wb_repair_s1_w;
    assign id_rs1_wb_repair_s1 = id_rs1_wb_repair_s1_w;
    assign id_rs2_wb_repair_s1 = id_rs2_wb_repair_s1_w;
    assign id_s1_rs1_wb_repair = id_s1_rs1_wb_repair_s0_w
                                | id_s1_rs1_wb_repair_s1_w;
    assign id_s1_rs2_wb_repair = id_s1_rs2_wb_repair_s0_w
                                | id_s1_rs2_wb_repair_s1_w;
    assign id_s1_rs1_wb_repair_s1 = id_s1_rs1_wb_repair_s1_w;
    assign id_s1_rs2_wb_repair_s1 = id_s1_rs2_wb_repair_s1_w;

    // ================================================================
    //  Load-Use Hazard Detection
    // ================================================================

    // Load in EX: data available at WB, still 2 stages away
    wire id_s0_uses_ex_load  = (id_rs1_used & (ex_rd == id_rs1_addr))
                              | (id_rs2_used & (ex_rd == id_rs2_addr));
    wire id_s1_uses_ex_load  = id_s1_valid
                              & ((id_s1_rs1_used & (ex_rd == id_s1_rs1_addr))
                               | (id_s1_rs2_used & (ex_rd == id_s1_rs2_addr)));
    wire load_in_ex  = ex_valid  & ex_mem_read & (ex_rd != 5'd0)
                     & (id_s0_uses_ex_load | id_s1_uses_ex_load);

    wire id_s0_uses_s1_ex_load = (id_rs1_used & (ex_s1_rd == id_rs1_addr))
                                | (id_rs2_used & (ex_s1_rd == id_rs2_addr));
    wire id_s1_uses_s1_ex_load = id_s1_valid
                                & ((id_s1_rs1_used & (ex_s1_rd == id_s1_rs1_addr))
                                 | (id_s1_rs2_used & (ex_s1_rd == id_s1_rs2_addr)));
    wire load_in_s1_ex = ex_s1_valid & ex_s1_mem_read & (ex_s1_rd != 5'd0)
                       & (id_s0_uses_s1_ex_load | id_s1_uses_s1_ex_load);

    // Load in MEM: data is one cycle away. With MEM-load WB repair disabled,
    // consumers wait until the load reaches WB and use ordinary WB forwarding.
    wire id_s0_uses_s0_mem_load = s0_rs1_uses_s0_mem_load
                                | s0_rs2_uses_s0_mem_load;
    wire id_s1_uses_s0_mem_load = s1_rs1_uses_s0_mem_load
                                | s1_rs2_uses_s0_mem_load;
    wire id_s0_uses_mem_load = id_s0_uses_s0_mem_load;
    wire id_s1_uses_mem_load = id_s1_uses_s0_mem_load;
    wire id_s0_uses_s1_mem_load = s0_rs1_uses_s1_mem_load
                                | s0_rs2_uses_s1_mem_load;
    wire id_s1_uses_s1_mem_load = s1_rs1_uses_s1_mem_load
                                | s1_rs2_uses_s1_mem_load;

    wire id_s0_waits_s0_mem_load = mem_s0_load_pending
                                  & id_s0_uses_s0_mem_load
                                  & ~id_s0_can_repair_mem_load;
    wire id_s1_waits_s0_mem_load = mem_s0_load_pending
                                  & id_s1_uses_s0_mem_load
                                  & ~id_s1_can_repair_mem_load;
    wire id_s0_waits_s1_mem_load = mem_s1_load_pending
                                  & id_s0_uses_s1_mem_load
                                  & ~id_s0_can_repair_mem_load;
    wire id_s1_waits_s1_mem_load = mem_s1_load_pending
                                  & id_s1_uses_s1_mem_load
                                  & ~id_s1_can_repair_mem_load;

    wire load_in_mem = id_s0_waits_s0_mem_load
                     | id_s1_waits_s0_mem_load;
    wire load_in_s1_mem = id_s0_waits_s1_mem_load
                        | id_s1_waits_s1_mem_load;

    wire load_use_hazard = load_in_ex | load_in_s1_ex | load_in_mem | load_in_s1_mem;

    // Repaired S0 EX results are valid ID forwarding sources. Keep this named
    // wire for the perf monitor; it now reports actual wait cycles, expected 0.
    wire repair_use_hazard = 1'b0;

    // Kept as named monitor wires. EX-produced branch/JALR operands now use
    // the ordinary ID operand path and resolve control flow in EX.
    wire jalr_ex_wait_hazard = 1'b0;
    wire branch_ex_wait_hazard = 1'b0;

    // S1_WB is forwarded above. Keep this named wire for the perf monitor;
    // it now reports actual wait cycles, which should be zero for S1_WB hits.
    wire s1_wb_wait_hazard = 1'b0;

    wire id_hazard = load_use_hazard | repair_use_hazard;
    assign id_ready_go = ~id_hazard;

endmodule
