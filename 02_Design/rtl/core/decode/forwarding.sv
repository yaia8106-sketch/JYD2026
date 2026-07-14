// ============================================================
// Module: forwarding
// Description: Operand forwarding network and load-hazard integration shell.
// Domain: decode and issue.
// Spec: 02_Design/spec/forwarding_spec.md
// Style: parallel match + per-stage preselect + encoded 4-way group MUX
//
// FIX: EX/MEM forwarding now handles JAL/JALR (wb_sel=10 -> PC+4)
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
    input  logic        ex_is_bitmanip,
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

    // ================================================================
    //  Forwarding value computation
    //  For EX/MEM stages: if wb_sel==10 (JAL/JALR), forward PC+4
    //  For wb_sel==01 (load), value not ready yet -> handled by stall.
    //  Repaired EX results are valid forwarding sources now that branch/JALR
    //  target work no longer sits in ID.
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel     == 2'b10) ? ex_pc_plus_4     : ex_alu_result;
    wire [31:0] ex_s1_fwd_val  = (ex_s1_wb_sel  == 2'b10) ? ex_s1_pc_plus_4  : ex_s1_alu_result;
    wire [31:0] mem_fwd_val    = (mem_wb_sel    == 2'b10) ? mem_pc_plus_4    : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10) ? mem_s1_pc_plus_4 : mem_s1_alu_result;

    // The select encoding is computed independently of the 32-bit payloads:
    //   00 = EX, 01 = MEM, 10 = WB, 11 = register file.
    // On a 6-input LUT FPGA, one output bit of this 4-way mux can map to one
    // LUT after the S1/S0 data for each pipeline stage has been preselected.
    function automatic logic [31:0] select_forward_group(
        input logic [ 1:0] group_select,
        input logic [31:0] ex_data,
        input logic [31:0] mem_data,
        input logic [31:0] wb_data,
        input logic [31:0] rf_data
    );
        case (group_select)
            2'b00: select_forward_group = ex_data;
            2'b01: select_forward_group = mem_data;
            2'b10: select_forward_group = wb_data;
            default: select_forward_group = rf_data;
        endcase
    endfunction

`define FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    /* Build match bits for one ID operand. Younger pipeline stages have */ \
    /* priority over older ones; within a stage Slot 1 is younger than Slot 0. */ \
    wire TAG``_s1_ex_hit  = ex_s1_valid  && ex_s1_reg_write  && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit  = ex_valid     && ex_reg_write     && !ex_is_bitmanip && (ex_rd != 5'd0) && (ex_rd == SRC_ADDR); \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load && (mem_s1_rd != 5'd0) && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid    && mem_reg_write    && !mem_is_load    && (mem_rd    != 5'd0) && (mem_rd    == SRC_ADDR); \
    wire TAG``_s1_wb_hit  = wb_s1_valid  && wb_s1_reg_write  && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit  = wb_valid     && wb_reg_write     && (wb_rd    != 5'd0) && (wb_rd    == SRC_ADDR); \
    wire TAG``_ex_group_hit  = TAG``_s1_ex_hit  | TAG``_s0_ex_hit; \
    wire TAG``_mem_group_hit = TAG``_s1_mem_hit | TAG``_s0_mem_hit; \
    wire TAG``_wb_group_hit  = TAG``_s1_wb_hit  | TAG``_s0_wb_hit; \
    wire [31:0] TAG``_ex_group_data = \
        TAG``_s1_ex_hit ? ex_s1_fwd_val : ex_fwd_val; \
    wire [31:0] TAG``_mem_group_data = \
        TAG``_s1_mem_hit ? mem_s1_fwd_val : mem_fwd_val; \
    wire [31:0] TAG``_wb_group_data = \
        TAG``_s1_wb_hit ? wb_s1_write_data : wb_write_data; \
    wire [1:0] TAG``_group_select = { \
        ~TAG``_ex_group_hit & ~TAG``_mem_group_hit, \
        ~TAG``_ex_group_hit & (TAG``_mem_group_hit | ~TAG``_wb_group_hit) \
    }; \
    assign OUT_DATA = select_forward_group( \
        TAG``_group_select, \
        TAG``_ex_group_data, \
        TAG``_mem_group_data, \
        TAG``_wb_group_data, \
        RF_DATA \
    )

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

    // ================================================================
    //  Load hazard / WB repair policy
    // ================================================================
    // Repair is a one-cycle promise: the consumer moves to EX now and will
    // substitute WB load data there on the next cycle.
    wire id_s0_repair_ok = id_s0_alu_only
                         | id_s0_branch
                         | id_s0_jalr
                         | id_s0_mem_read
                         | id_s0_mem_write;

    // A repair tag is valid only when no younger producer has priority over
    // the candidate MEM load in the forwarding network above.
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

    wire id_s0_uses_ex_load;
    wire id_s1_uses_ex_load;
    wire id_s0_uses_s1_ex_load;
    wire id_s1_uses_s1_ex_load;
    wire id_s0_uses_mem_load;
    wire id_s1_uses_mem_load;
    wire id_s0_uses_s1_mem_load;
    wire id_s1_uses_s1_mem_load;
    wire load_in_ex;
    wire load_in_s1_ex;
    wire load_in_mem;
    wire load_in_s1_mem;
    wire load_use_hazard;

    load_hazard_ctrl u_load_hazard_ctrl (
        .id_rs1_addr                    (id_rs1_addr),
        .id_rs2_addr                    (id_rs2_addr),
        .id_rs1_used                    (id_rs1_used),
        .id_rs2_used                    (id_rs2_used),
        .id_s0_repair_ok                (id_s0_repair_ok),
        .id_s1_valid                    (id_s1_valid),
        .id_s1_rs1_addr                 (id_s1_rs1_addr),
        .id_s1_rs2_addr                 (id_s1_rs2_addr),
        .id_s1_rs1_used                 (id_s1_rs1_used),
        .id_s1_rs2_used                 (id_s1_rs2_used),
        .id_s1_repair_ok                (id_s1_repair_ok),
        .ex_valid                       (ex_valid),
        .ex_mem_read                    (ex_mem_read),
        .ex_rd                          (ex_rd),
        .ex_s1_valid                    (ex_s1_valid),
        .ex_s1_mem_read                 (ex_s1_mem_read),
        .ex_s1_rd                       (ex_s1_rd),
        .mem_valid                      (mem_valid),
        .mem_reg_write                  (mem_reg_write),
        .mem_is_load                    (mem_is_load),
        .mem_rd                         (mem_rd),
        .mem_s1_valid                   (mem_s1_valid),
        .mem_s1_reg_write               (mem_s1_reg_write),
        .mem_s1_is_load                 (mem_s1_is_load),
        .mem_s1_rd                      (mem_s1_rd),
        .mem_load_ready                 (mem_load_ready),
        .s0_rs1_blocks_s0_mem_repair    (s0_rs1_blocks_s0_mem_repair),
        .s0_rs2_blocks_s0_mem_repair    (s0_rs2_blocks_s0_mem_repair),
        .s1_rs1_blocks_s0_mem_repair    (s1_rs1_blocks_s0_mem_repair),
        .s1_rs2_blocks_s0_mem_repair    (s1_rs2_blocks_s0_mem_repair),
        .s0_rs1_blocks_s1_mem_repair    (s0_rs1_blocks_s1_mem_repair),
        .s0_rs2_blocks_s1_mem_repair    (s0_rs2_blocks_s1_mem_repair),
        .s1_rs1_blocks_s1_mem_repair    (s1_rs1_blocks_s1_mem_repair),
        .s1_rs2_blocks_s1_mem_repair    (s1_rs2_blocks_s1_mem_repair),
        .id_rs1_wb_repair               (id_rs1_wb_repair),
        .id_rs2_wb_repair               (id_rs2_wb_repair),
        .id_rs1_wb_repair_s1            (id_rs1_wb_repair_s1),
        .id_rs2_wb_repair_s1            (id_rs2_wb_repair_s1),
        .id_s1_rs1_wb_repair            (id_s1_rs1_wb_repair),
        .id_s1_rs2_wb_repair            (id_s1_rs2_wb_repair),
        .id_s1_rs1_wb_repair_s1         (id_s1_rs1_wb_repair_s1),
        .id_s1_rs2_wb_repair_s1         (id_s1_rs2_wb_repair_s1),
        .id_s0_uses_ex_load             (id_s0_uses_ex_load),
        .id_s1_uses_ex_load             (id_s1_uses_ex_load),
        .id_s0_uses_s1_ex_load          (id_s0_uses_s1_ex_load),
        .id_s1_uses_s1_ex_load          (id_s1_uses_s1_ex_load),
        .id_s0_uses_mem_load            (id_s0_uses_mem_load),
        .id_s1_uses_mem_load            (id_s1_uses_mem_load),
        .id_s0_uses_s1_mem_load         (id_s0_uses_s1_mem_load),
        .id_s1_uses_s1_mem_load         (id_s1_uses_s1_mem_load),
        .load_in_ex                     (load_in_ex),
        .load_in_s1_ex                  (load_in_s1_ex),
        .load_in_mem                    (load_in_mem),
        .load_in_s1_mem                 (load_in_s1_mem),
        .load_use_hazard                (load_use_hazard)
    );

    // Repaired S0 EX results are valid ID forwarding sources. Keep this named
    // wire for the perf monitor; it now reports actual wait cycles, expected 0.
    wire repair_use_hazard = 1'b0;

    // B results do not participate in the EX forwarding payload mux.  While a
    // completed B producer is still resident in EX, hold any matching ID
    // consumer for one cycle; the result is forwardable from MEM afterwards.
    wire id_s0_uses_ex_bitmanip =
        (id_rs1_used & (ex_rd == id_rs1_addr))
      | (id_rs2_used & (ex_rd == id_rs2_addr));
    wire id_s1_uses_ex_bitmanip = id_s1_valid
        & ((id_s1_rs1_used & (ex_rd == id_s1_rs1_addr))
         | (id_s1_rs2_used & (ex_rd == id_s1_rs2_addr)));
    wire bitmanip_use_hazard = ex_valid & ex_reg_write & ex_is_bitmanip
                             & (ex_rd != 5'd0)
                             & (id_s0_uses_ex_bitmanip
                                | id_s1_uses_ex_bitmanip);

    // Kept as named monitor wires. EX-produced branch/JALR operands now use
    // the ordinary ID operand path and resolve control flow in EX.
    wire jalr_ex_wait_hazard = 1'b0;
    wire branch_ex_wait_hazard = 1'b0;

    // S1_WB is forwarded above. Keep this named wire for the perf monitor;
    // it now reports actual wait cycles, which should be zero for S1_WB hits.
    wire s1_wb_wait_hazard = 1'b0;

    wire id_hazard = load_use_hazard | repair_use_hazard
                   | bitmanip_use_hazard;
    assign id_ready_go = ~id_hazard;

endmodule

// ============================================================
// Module: mul_operand_forwarding
// Description: Physically independent Slot 0 MUL operand forwarding.
// Domain: decode and issue.
//
// The ordinary forwarding outputs terminate at the ID/EX registers.  Driving
// the distant DSP inputs from those same muxes pulled their placement in two
// directions.  This copy preserves the identical architectural priority but
// gives normal EX ALU results a one-selector fast path to the DSP input regs.
// ============================================================

(* keep_hierarchy = "yes" *) module mul_operand_forwarding (
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    input  logic        ex_valid,
    input  logic        ex_reg_write,
    input  logic        ex_is_bitmanip,
    input  logic        ex_fast_alu,
    input  logic [ 4:0] ex_rd,
    input  logic [31:0] ex_alu_result,
    input  logic [31:0] ex_special_result,
    input  logic [31:0] ex_pc_plus_4,
    input  logic [ 1:0] ex_wb_sel,

    input  logic        ex_s1_valid,
    input  logic        ex_s1_reg_write,
    input  logic [ 4:0] ex_s1_rd,
    input  logic [31:0] ex_s1_alu_result,
    input  logic [31:0] ex_s1_pc_plus_4,
    input  logic [ 1:0] ex_s1_wb_sel,

    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_pc_plus_4,
    input  logic [ 1:0] mem_wb_sel,

    input  logic        mem_s1_valid,
    input  logic        mem_s1_reg_write,
    input  logic        mem_s1_is_load,
    input  logic [ 4:0] mem_s1_rd,
    input  logic [31:0] mem_s1_alu_result,
    input  logic [31:0] mem_s1_pc_plus_4,
    input  logic [ 1:0] mem_s1_wb_sel,

    input  logic        wb_valid,
    input  logic        wb_reg_write,
    input  logic [ 4:0] wb_rd,
    input  logic [31:0] wb_write_data,

    input  logic        wb_s1_valid,
    input  logic        wb_s1_reg_write,
    input  logic [ 4:0] wb_s1_rd,
    input  logic [31:0] wb_s1_write_data,

    output logic [31:0] mul_rs1_data,
    output logic [31:0] mul_rs2_data
);

    wire [31:0] mem_fwd_val = (mem_wb_sel == 2'b10)
                            ? mem_pc_plus_4 : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10)
                               ? mem_s1_pc_plus_4 : mem_s1_alu_result;

    function automatic logic [31:0] select_fallback_group(
        input logic [ 1:0] group_select,
        input logic [31:0] ex_data,
        input logic [31:0] mem_data,
        input logic [31:0] wb_data,
        input logic [31:0] rf_data
    );
        case (group_select)
            2'b00: select_fallback_group = ex_data;
            2'b01: select_fallback_group = mem_data;
            2'b10: select_fallback_group = wb_data;
            default: select_fallback_group = rf_data;
        endcase
    endfunction

`define MUL_FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    /* Match controls are computed in parallel with every payload candidate. */ \
    wire TAG``_s1_ex_hit = ex_s1_valid && ex_s1_reg_write \
                         && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit = ex_valid && ex_reg_write && !ex_is_bitmanip \
                         && (ex_rd != 5'd0) && (ex_rd == SRC_ADDR); \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write \
                          && !mem_s1_is_load && (mem_s1_rd != 5'd0) \
                          && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid && mem_reg_write && !mem_is_load \
                          && (mem_rd != 5'd0) && (mem_rd == SRC_ADDR); \
    wire TAG``_s1_wb_hit = wb_s1_valid && wb_s1_reg_write \
                         && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit = wb_valid && wb_reg_write \
                         && (wb_rd != 5'd0) && (wb_rd == SRC_ADDR); \
    /* Ordinary EX ALU data bypasses the generic special/link/group muxes. */ \
    wire TAG``_s1_fast_select = TAG``_s1_ex_hit \
                              && (ex_s1_wb_sel != 2'b10); \
    wire TAG``_s0_fast_select = !TAG``_s1_ex_hit && TAG``_s0_ex_hit \
                              && ex_fast_alu; \
    /* The fallback EX candidate contains no ordinary ALU payload, so STA */ \
    /* cannot rediscover the long ALU path through this slower branch. */ \
    wire TAG``_s1_slow_ex_hit = TAG``_s1_ex_hit \
                              && !TAG``_s1_fast_select; \
    wire TAG``_s0_slow_ex_hit = !TAG``_s1_ex_hit && TAG``_s0_ex_hit \
                              && !TAG``_s0_fast_select; \
    wire TAG``_slow_ex_hit = TAG``_s1_slow_ex_hit \
                           | TAG``_s0_slow_ex_hit; \
    wire [31:0] TAG``_s0_slow_ex_data = (ex_wb_sel == 2'b10) \
                                       ? ex_pc_plus_4 \
                                       : ex_special_result; \
    wire [31:0] TAG``_slow_ex_data = TAG``_s1_slow_ex_hit \
                                    ? ex_s1_pc_plus_4 \
                                    : TAG``_s0_slow_ex_data; \
    wire TAG``_mem_group_hit = TAG``_s1_mem_hit | TAG``_s0_mem_hit; \
    wire TAG``_wb_group_hit = TAG``_s1_wb_hit | TAG``_s0_wb_hit; \
    wire [31:0] TAG``_mem_group_data = TAG``_s1_mem_hit \
                                      ? mem_s1_fwd_val : mem_fwd_val; \
    wire [31:0] TAG``_wb_group_data = TAG``_s1_wb_hit \
                                     ? wb_s1_write_data : wb_write_data; \
    wire [1:0] TAG``_fallback_select = { \
        ~TAG``_slow_ex_hit & ~TAG``_mem_group_hit, \
        ~TAG``_slow_ex_hit \
            & (TAG``_mem_group_hit | ~TAG``_wb_group_hit) \
    }; \
    wire [31:0] TAG``_fallback_data = select_fallback_group( \
        TAG``_fallback_select, TAG``_slow_ex_data, \
        TAG``_mem_group_data, TAG``_wb_group_data, RF_DATA \
    ); \
    /* The raw S1 ALU, raw S0 ALU, and precomputed fallback are mutually */ \
    /* exclusive. This late selector is the only LUT after a fast EX ALU. */ \
    assign OUT_DATA = ({32{TAG``_s1_fast_select}} & ex_s1_alu_result) \
                    | ({32{TAG``_s0_fast_select}} & ex_alu_result) \
                    | ({32{~TAG``_s1_fast_select \
                            & ~TAG``_s0_fast_select}} \
                       & TAG``_fallback_data)

    `MUL_FWD_MUX(rs1, id_rs1_addr, rf_rs1_data, mul_rs1_data);
    `MUL_FWD_MUX(rs2, id_rs2_addr, rf_rs2_data, mul_rs2_data);

`undef MUL_FWD_MUX

endmodule
