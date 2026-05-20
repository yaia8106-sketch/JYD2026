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
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // Slot 1 ID stage
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1_addr,
    input  logic [ 4:0] id_s1_rs2_addr,
    input  logic        id_s1_rs1_used,
    input  logic        id_s1_rs2_used,
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
    input  logic        ex_wb_repair, // EX result depends on a late operand; do not forward to ID

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
    output logic        id_ready_go
);

    // ================================================================
    //  Forwarding value computation
    //  For EX/MEM stages: if wb_sel==10 (JAL/JALR), forward PC+4
    //  For wb_sel==01 (load), value not ready yet → handled by stall.
    //  S0 ordinary ALU consumers may pass a ready MEM load and repair from
    //  WB in EX; the repaired EX result is not forwarded to ID in the same
    //  cycle, keeping the late WB path out of the frontend.
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel     == 2'b10) ? ex_pc_plus_4     : ex_alu_result;
    wire [31:0] ex_s1_fwd_val  = (ex_s1_wb_sel  == 2'b10) ? ex_s1_pc_plus_4  : ex_s1_alu_result;
    wire [31:0] mem_fwd_val    = (mem_wb_sel    == 2'b10) ? mem_pc_plus_4    : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;

`define FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    wire TAG``_s1_ex_hit  = ex_s1_valid  && ex_s1_reg_write  && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit  = ex_valid     && ex_reg_write     && !ex_wb_repair && (ex_rd != 5'd0) && (ex_rd == SRC_ADDR); \
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

    // Branch compare is precomputed in ID and then registered into EX. Keep
    // EX-stage producer results out of that compare; a matching EX producer
    // stalls for one cycle and is consumed from MEM instead. Use priority
    // one-hot selects so this path does not synthesize as a long mux chain
    // before the branch comparator.
`define FWD_BRANCH_MUX(TAG, RF_DATA, OUT_DATA) \
    wire TAG``_br_s1_mem = TAG``_s1_mem_hit; \
    wire TAG``_br_s0_mem = ~TAG``_br_s1_mem & TAG``_s0_mem_hit; \
    wire TAG``_br_s1_wb  = ~TAG``_br_s1_mem & ~TAG``_br_s0_mem & TAG``_s1_wb_hit; \
    wire TAG``_br_s0_wb  = ~TAG``_br_s1_mem & ~TAG``_br_s0_mem & ~TAG``_br_s1_wb & TAG``_s0_wb_hit; \
    wire TAG``_br_rf     = ~TAG``_br_s1_mem & ~TAG``_br_s0_mem & ~TAG``_br_s1_wb & ~TAG``_br_s0_wb; \
    assign OUT_DATA = ({32{TAG``_br_s1_mem}} & mem_s1_fwd_val)   | \
                      ({32{TAG``_br_s0_mem}} & mem_fwd_val)      | \
                      ({32{TAG``_br_s1_wb }} & wb_s1_write_data) | \
                      ({32{TAG``_br_s0_wb }} & wb_write_data)    | \
                      ({32{TAG``_br_rf    }} & RF_DATA)

    `FWD_BRANCH_MUX(s0_rs1, rf_rs1_data, id_branch_rs1_data);
    `FWD_BRANCH_MUX(s0_rs2, rf_rs2_data, id_branch_rs2_data);

`undef FWD_BRANCH_MUX

    assign id_rs1_jalr_data = s0_rs1_s1_mem_hit ? mem_s1_fwd_val   :
                              s0_rs1_s0_mem_hit ? mem_fwd_val      :
                              s0_rs1_s1_wb_hit  ? wb_s1_write_data :
                              s0_rs1_s0_wb_hit  ? wb_write_data    :
                                                   rf_rs1_data;

    wire mem_load_ready_base = mem_valid & mem_reg_write & mem_is_load
                             & mem_load_ready & (mem_rd != 5'd0) & id_s0_alu_only;

    assign id_rs1_wb_repair = mem_load_ready_base & id_rs1_used
                            & (mem_rd == id_rs1_addr)
                            & !(s0_rs1_s1_ex_hit | s0_rs1_s0_ex_hit | s0_rs1_s1_mem_hit);
    assign id_rs2_wb_repair = mem_load_ready_base & id_rs2_used
                            & (mem_rd == id_rs2_addr)
                            & !(s0_rs2_s1_ex_hit | s0_rs2_s0_ex_hit | s0_rs2_s1_mem_hit);

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

    // Load in MEM: dram_dout not yet updated, still 1 stage away. A ready
    // load may release an ordinary S0 ALU consumer; other consumers still
    // stall because they feed redirect, DCache address/data, or JALR target.
    wire id_s0_uses_mem_load = (id_rs1_used & (mem_rd == id_rs1_addr))
                              | (id_rs2_used & (mem_rd == id_rs2_addr));
    wire id_s1_uses_mem_load = id_s1_valid
                              & ((id_s1_rs1_used & (mem_rd == id_s1_rs1_addr))
                               | (id_s1_rs2_used & (mem_rd == id_s1_rs2_addr)));
    wire load_in_mem = mem_valid & mem_is_load & (mem_rd != 5'd0)
                     & ((id_s0_uses_mem_load & ~(id_s0_alu_only & mem_load_ready))
                      |  id_s1_uses_mem_load);

    wire id_s0_uses_s1_mem_load = (id_rs1_used & (mem_s1_rd == id_rs1_addr))
                                 | (id_rs2_used & (mem_s1_rd == id_rs2_addr));
    wire id_s1_uses_s1_mem_load = id_s1_valid
                                 & ((id_s1_rs1_used & (mem_s1_rd == id_s1_rs1_addr))
                                  | (id_s1_rs2_used & (mem_s1_rd == id_s1_rs2_addr)));
    wire load_in_s1_mem = mem_s1_valid & mem_s1_is_load & (mem_s1_rd != 5'd0)
                        & (id_s0_uses_s1_mem_load | id_s1_uses_s1_mem_load);

    wire load_use_hazard = load_in_ex | load_in_s1_ex | load_in_mem | load_in_s1_mem;

    // If the S0 EX result depends on a late operand, do not forward that
    // result back into ID in the same cycle. S0 ALU consumers may still enter
    // EX and consume the registered MEM result via the EX-stage bypass.
    wire repair_s0_use_hazard = id_s0_uses_ex_load & ~id_s0_alu_only;
    wire repair_s1_use_hazard = id_s1_uses_ex_load;
    wire repair_use_hazard = ex_valid & ex_wb_repair & ex_reg_write
                           & (ex_rd != 5'd0)
                           & (repair_s0_use_hazard | repair_s1_use_hazard);

    // S0 JALR target is precomputed in ID.  Do not form an EX/S1_EX result
    // -> ID JALR target -> ID/EX timing path; wait one cycle and use MEM/WB.
    wire jalr_ex_wait_hazard = id_s0_jalr & id_rs1_used & (id_rs1_addr != 5'd0)
                             & ((ex_valid & ex_reg_write & (ex_rd == id_rs1_addr))
                              |  (ex_s1_valid & ex_s1_reg_write & (ex_s1_rd == id_rs1_addr)));

    wire branch_ex_wait_hazard = id_s0_branch
                               & ((id_rs1_used & (s0_rs1_s0_ex_hit | s0_rs1_s1_ex_hit))
                                |  (id_rs2_used & (s0_rs2_s0_ex_hit | s0_rs2_s1_ex_hit)));

    // S1_WB is forwarded above. Keep this named wire for the perf monitor;
    // it now reports actual wait cycles, which should be zero for S1_WB hits.
    wire s1_wb_wait_hazard = 1'b0;

    wire id_hazard = load_use_hazard | repair_use_hazard
                   | jalr_ex_wait_hazard | branch_ex_wait_hazard;
    assign id_ready_go = ~id_hazard;

endmodule
