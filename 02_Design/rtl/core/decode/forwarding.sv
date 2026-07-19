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
    input  logic        id_s0_is_mul,
    input  logic [31:0] id_s0_pc,
    input  logic [31:0] id_s0_imm,
    input  logic [ 1:0] id_s0_alu_src1_sel,
    input  logic        id_s0_alu_src2_sel,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    // Slot 1 ID stage
    input  logic        id_s1_valid,
    input  logic [ 4:0] id_s1_rs1_addr,
    input  logic [ 4:0] id_s1_rs2_addr,
    input  logic        id_s1_rs1_used,
    input  logic        id_s1_rs2_used,
    input  logic        id_s1_repair_ok,
    input  logic [31:0] id_s1_pc,
    input  logic [31:0] id_s1_imm,
    input  logic [ 1:0] id_s1_alu_src1_sel,
    input  logic        id_s1_alu_src2_sel,
    input  logic [31:0] rf_s1_rs1_data,
    input  logic [31:0] rf_s1_rs2_data,

    // Slot 0 EX stage
    input  logic        ex_valid,
    input  logic        ex_reg_write,
    input  logic        ex_is_muldiv,
    input  logic        ex_mem_read,
    input  logic [ 4:0] ex_rd,
    input  logic [31:0] ex_alu_result,
    input  logic        ex_fast_alu,
    input  logic [31:0] ex_fast_alu_result,
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
    input  logic        mem_is_mul,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_mul_result,
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
    output logic [31:0] id_s0_alu_src1,
    output logic [31:0] id_s0_alu_src2,
    output logic [31:0] id_s1_alu_src1,
    output logic [31:0] id_s1_alu_src2,
    output logic        id_rs1_wb_repair,
    output logic        id_rs2_wb_repair,
    output logic        id_rs1_wb_repair_s1,
    output logic        id_rs2_wb_repair_s1,
    output logic        id_s1_rs1_wb_repair,
    output logic        id_s1_rs2_wb_repair,
    output logic        id_s1_rs1_wb_repair_s1,
    output logic        id_s1_rs2_wb_repair_s1,
    output logic        id_ready_go,
    output logic        id_ready_go_if_mem_ready,
    output logic        id_ready_go_if_mem_wait
);

    // ================================================================
    //  Forwarding value computation
    //  For EX/MEM stages: if wb_sel==10 (JAL/JALR), forward PC+4
    //  For wb_sel==01 (load), value not ready yet -> handled by stall.
    //  Repaired EX results are valid forwarding sources now that branch/JALR
    //  target work no longer sits in ID.
    // ================================================================
    wire [31:0] ex_fwd_val     = (ex_wb_sel == 2'b10)
                               ? ex_pc_plus_4 : ex_alu_result;
    wire mem_select_pc4 = mem_wb_sel == 2'b10;
    wire [31:0] mem_nonmul_fwd_val = mem_select_pc4
                                   ? mem_pc_plus_4 : mem_alu_result;
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

    // Fold the two inner EX choices into one LUT-sized 4-way selection:
    //   00 = Slot 1 ALU, 01 = Slot 1 PC+4,
    //   10 = Slot 0 ordinary ALU fast path, 11 = Slot 0 special/PC+4.
    // The final EX/MEM/WB/RF selector remains unchanged, so older-stage paths
    // do not gain an extra data-mux level.
    function automatic logic [31:0] select_ex_group_data(
        input logic [ 1:0] select,
        input logic [31:0] s1_alu_data,
        input logic [31:0] s1_pc4_data,
        input logic [31:0] s0_fast_data,
        input logic [31:0] s0_fallback_data
    );
        case (select)
            2'b00: select_ex_group_data = s1_alu_data;
            2'b01: select_ex_group_data = s1_pc4_data;
            2'b10: select_ex_group_data = s0_fast_data;
            default: select_ex_group_data = s0_fallback_data;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src1(
        input logic [ 1:0] source_select,
        input logic [31:0] rs1_candidate,
        input logic [31:0] pc_candidate
    );
        case (source_select)
            2'b00:   preselect_alu_src1 = rs1_candidate;
            2'b01:   preselect_alu_src1 = pc_candidate;
            default: preselect_alu_src1 = 32'd0;
        endcase
    endfunction

    function automatic logic [31:0] preselect_alu_src2(
        input logic        source_select,
        input logic [31:0] rs2_candidate,
        input logic [31:0] imm_candidate
    );
        preselect_alu_src2 = source_select ? imm_candidate
                                           : rs2_candidate;
    endfunction

`define FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    /* Build match bits for one ID operand. Younger pipeline stages have */ \
    /* priority over older ones; within a stage Slot 1 is younger than Slot 0. */ \
    wire TAG``_s1_ex_hit  = ex_s1_valid  && ex_s1_reg_write  && (ex_s1_rd != 5'd0) && (ex_s1_rd == SRC_ADDR); \
    wire TAG``_s0_ex_hit  = ex_valid     && ex_reg_write     && (ex_rd != 5'd0) && (ex_rd == SRC_ADDR); \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write && !mem_s1_is_load && (mem_s1_rd != 5'd0) && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid    && mem_reg_write    && !mem_is_load    && (mem_rd    != 5'd0) && (mem_rd    == SRC_ADDR); \
    wire TAG``_s1_wb_hit  = wb_s1_valid  && wb_s1_reg_write  && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit  = wb_valid     && wb_reg_write     && (wb_rd    != 5'd0) && (wb_rd    == SRC_ADDR); \
    wire TAG``_ex_group_hit  = TAG``_s1_ex_hit | TAG``_s0_ex_hit; \
    wire TAG``_s0_mem_nonmul_hit = TAG``_s0_mem_hit \
                                 && (!mem_is_mul || mem_select_pc4); \
    wire TAG``_mem_group_hit = TAG``_s1_mem_hit \
                             | TAG``_s0_mem_nonmul_hit; \
    wire TAG``_wb_group_hit = TAG``_s1_wb_hit | TAG``_s0_wb_hit; \
    /* Encode a selected MEM multiplier as the otherwise-idle RF group. */ \
    /* This removes one data mux from the registered product path while */ \
    /* preserving EX > S1 MEM > S0 MEM > WB > RF priority. */ \
    wire TAG``_mem_mul_select = !TAG``_ex_group_hit \
                              && !TAG``_s1_mem_hit \
                              && TAG``_s0_mem_hit && mem_is_mul \
                              && !mem_select_pc4; \
    wire TAG``_wb_select_hit = TAG``_wb_group_hit \
                             && !TAG``_mem_mul_select; \
    wire [1:0] TAG``_ex_data_select = TAG``_s1_ex_hit \
        ? {1'b0, ex_s1_wb_sel == 2'b10} \
        : {1'b1, ~ex_fast_alu}; \
    wire [31:0] TAG``_ex_group_data = select_ex_group_data( \
        TAG``_ex_data_select, ex_s1_alu_result, ex_s1_pc_plus_4, \
        ex_fast_alu_result, ex_fwd_val); \
    wire [31:0] TAG``_mem_group_data = \
        TAG``_s1_mem_hit ? mem_s1_fwd_val : mem_nonmul_fwd_val; \
    wire [31:0] TAG``_wb_group_data = \
        TAG``_s1_wb_hit ? wb_s1_write_data : wb_write_data; \
    wire [31:0] TAG``_rf_or_mul_data = TAG``_mem_mul_select \
                                      ? mem_mul_result : RF_DATA; \
    wire [1:0] TAG``_group_select = { \
        ~TAG``_ex_group_hit & ~TAG``_mem_group_hit, \
        ~TAG``_ex_group_hit \
            & (TAG``_mem_group_hit | ~TAG``_wb_select_hit) \
    }; \
    assign OUT_DATA = select_forward_group( \
        TAG``_group_select, \
        TAG``_ex_group_data, \
        TAG``_mem_group_data, \
        TAG``_wb_group_data, \
        TAG``_rf_or_mul_data \
    )

    `FWD_MUX(s0_rs1, id_rs1_addr,    rf_rs1_data,    id_rs1_data);
    `FWD_MUX(s0_rs2, id_rs2_addr,    rf_rs2_data,    id_rs2_data);
    `FWD_MUX(s1_rs1, id_s1_rs1_addr, rf_s1_rs1_data, id_s1_rs1_data);
    `FWD_MUX(s1_rs2, id_s1_rs2_addr, rf_s1_rs2_data, id_s1_rs2_data);

`undef FWD_MUX

    // ALU source selection used to sit after the complete forwarding mux.  A
    // MEM/EX match control therefore traversed both the group selector and the
    // alu_src mux before reaching ID/EX.  Apply the source transform to every
    // already-preselected payload in parallel, then reuse the same final group
    // selector. KEEP on the reported Slot-1 src2 family prevents synthesis from
    // factoring its immediate term back behind the forwarding mux; the other
    // source cones retain the same expression without forced duplication.
    wire [31:0] s0_alu_src1_ex_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_ex_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_mem_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_mem_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_wb_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_wb_group_data, id_s0_pc);
    wire [31:0] s0_alu_src1_rf_candidate =
        preselect_alu_src1(id_s0_alu_src1_sel,
                           s0_rs1_rf_or_mul_data, id_s0_pc);

    wire [31:0] s0_alu_src2_ex_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_ex_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_mem_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_mem_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_wb_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_wb_group_data, id_s0_imm);
    wire [31:0] s0_alu_src2_rf_candidate =
        preselect_alu_src2(id_s0_alu_src2_sel,
                           s0_rs2_rf_or_mul_data, id_s0_imm);

    wire [31:0] s1_alu_src1_ex_candidate =
        preselect_alu_src1(id_s1_alu_src1_sel,
                           s1_rs1_ex_group_data, id_s1_pc);
    wire [31:0] s1_alu_src1_mem_candidate =
        preselect_alu_src1(id_s1_alu_src1_sel,
                           s1_rs1_mem_group_data, id_s1_pc);
    wire [31:0] s1_alu_src1_wb_candidate =
        preselect_alu_src1(id_s1_alu_src1_sel,
                           s1_rs1_wb_group_data, id_s1_pc);
    wire [31:0] s1_alu_src1_rf_candidate =
        preselect_alu_src1(id_s1_alu_src1_sel,
                           s1_rs1_rf_or_mul_data, id_s1_pc);

    (* keep = "true" *) wire [31:0] s1_alu_src2_ex_candidate =
        preselect_alu_src2(id_s1_alu_src2_sel,
                           s1_rs2_ex_group_data, id_s1_imm);
    (* keep = "true" *) wire [31:0] s1_alu_src2_mem_candidate =
        preselect_alu_src2(id_s1_alu_src2_sel,
                           s1_rs2_mem_group_data, id_s1_imm);
    (* keep = "true" *) wire [31:0] s1_alu_src2_wb_candidate =
        preselect_alu_src2(id_s1_alu_src2_sel,
                           s1_rs2_wb_group_data, id_s1_imm);
    (* keep = "true" *) wire [31:0] s1_alu_src2_rf_candidate =
        preselect_alu_src2(id_s1_alu_src2_sel,
                           s1_rs2_rf_or_mul_data, id_s1_imm);

    assign id_s0_alu_src1 = select_forward_group(
        s0_rs1_group_select,
        s0_alu_src1_ex_candidate, s0_alu_src1_mem_candidate,
        s0_alu_src1_wb_candidate, s0_alu_src1_rf_candidate
    );
    assign id_s0_alu_src2 = select_forward_group(
        s0_rs2_group_select,
        s0_alu_src2_ex_candidate, s0_alu_src2_mem_candidate,
        s0_alu_src2_wb_candidate, s0_alu_src2_rf_candidate
    );
    assign id_s1_alu_src1 = select_forward_group(
        s1_rs1_group_select,
        s1_alu_src1_ex_candidate, s1_alu_src1_mem_candidate,
        s1_alu_src1_wb_candidate, s1_alu_src1_rf_candidate
    );
    assign id_s1_alu_src2 = select_forward_group(
        s1_rs2_group_select,
        s1_alu_src2_ex_candidate, s1_alu_src2_mem_candidate,
        s1_alu_src2_wb_candidate, s1_alu_src2_rf_candidate
    );

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
    wire load_use_hazard_if_mem_ready;
    wire load_use_hazard_if_mem_wait;

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
        .load_use_hazard                (load_use_hazard),
        .load_use_hazard_if_mem_ready   (load_use_hazard_if_mem_ready),
        .load_use_hazard_if_mem_wait    (load_use_hazard_if_mem_wait)
    );

    // Repaired S0 EX results are valid ID forwarding sources. Keep this named
    // wire for the perf monitor; it now reports actual wait cycles, expected 0.
    wire repair_use_hazard = 1'b0;

    // A multiplier leaves EX before its registered result is visible. Hold
    // only matching consumers for that cycle; in the following cycle the
    // producer is selected by the ordinary MEM forwarding group. DIV/REM also
    // satisfy this predicate while running, but their EX backpressure remains
    // the primary blocker and preserves the existing serial behavior.
    wire id_s0_uses_ex_muldiv =
        (id_rs1_used & (ex_rd == id_rs1_addr))
      | (id_rs2_used & (ex_rd == id_rs2_addr));
    wire id_s1_uses_ex_muldiv = id_s1_valid
        & ((id_s1_rs1_used & (ex_rd == id_s1_rs1_addr))
         | (id_s1_rs2_used & (ex_rd == id_s1_rs2_addr)));
    wire muldiv_use_hazard = ex_valid & ex_is_muldiv & (ex_rd != 5'd0)
                           & (id_s0_uses_ex_muldiv
                              | id_s1_uses_ex_muldiv);

    // A prestarted multiplier samples its DSP input registers on the same edge
    // that it enters EX. Do not serialize a complete EX result cone in front of
    // those registers. Only a Slot-0 MUL with a true EX RAW dependency waits;
    // one cycle later the producer is registered in MEM and is selected by the
    // normal MEM forwarding priority. Independent MUL and non-MUL traffic keep
    // the existing acceptance behavior.
    wire id_mul_uses_s0_ex_writer =
        (id_rs1_used & (ex_rd == id_rs1_addr))
      | (id_rs2_used & (ex_rd == id_rs2_addr));
    wire id_mul_uses_s1_ex_writer =
        (id_rs1_used & (ex_s1_rd == id_rs1_addr))
      | (id_rs2_used & (ex_s1_rd == id_rs2_addr));
    wire mul_launch_ex_raw_hazard = id_s0_is_mul
        & ((ex_valid & ex_reg_write & (ex_rd != 5'd0)
            & id_mul_uses_s0_ex_writer)
         | (ex_s1_valid & ex_s1_reg_write & (ex_s1_rd != 5'd0)
            & id_mul_uses_s1_ex_writer));

    // Kept as named monitor wires. EX-produced branch/JALR operands now use
    // the ordinary ID operand path and resolve control flow in EX.
    wire jalr_ex_wait_hazard = 1'b0;
    wire branch_ex_wait_hazard = 1'b0;

    // S1_WB is forwarded above. Keep this named wire for the perf monitor;
    // it now reports actual wait cycles, which should be zero for S1_WB hits.
    wire s1_wb_wait_hazard = 1'b0;

    wire non_load_hazard = repair_use_hazard | muldiv_use_hazard
                         | mul_launch_ex_raw_hazard;
    wire id_hazard_if_mem_ready = load_use_hazard_if_mem_ready
                                | non_load_hazard;
    wire id_hazard_if_mem_wait = load_use_hazard_if_mem_wait
                               | non_load_hazard;

    // Expose both readiness candidates so the integrated pipeline can keep
    // DCache ready out of the hazard tree and use it only as a late selector.
    assign id_ready_go_if_mem_ready = ~id_hazard_if_mem_ready;
    assign id_ready_go_if_mem_wait = ~id_hazard_if_mem_wait;
    assign id_ready_go = mem_load_ready ? id_ready_go_if_mem_ready
                                        : id_ready_go_if_mem_wait;

endmodule

// ============================================================
// Module: mul_operand_forwarding
// Description: Physically independent Slot 0 MUL operand forwarding.
// Domain: decode and issue.
//
// The ordinary forwarding outputs terminate at the ID/EX registers. Driving
// the distant DSP inputs from those same muxes pulled their placement in two
// directions. A MUL with an EX RAW dependency is now held until that producer
// reaches MEM, so this physical copy only needs registered MEM/WB/RF payloads.
// The registered MEM multiplier result retains a direct final-selector path.
// ============================================================

(* keep_hierarchy = "yes" *) module mul_operand_forwarding (
    input  logic [ 4:0] id_rs1_addr,
    input  logic [ 4:0] id_rs2_addr,
    input  logic [31:0] rf_rs1_data,
    input  logic [31:0] rf_rs2_data,

    input  logic        mem_valid,
    input  logic        mem_reg_write,
    input  logic        mem_is_load,
    input  logic        mem_is_mul,
    input  logic [ 4:0] mem_rd,
    input  logic [31:0] mem_alu_result,
    input  logic [31:0] mem_mul_result,
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

    wire mem_select_pc4 = mem_wb_sel == 2'b10;
    wire [31:0] mem_nonmul_fwd_val = mem_select_pc4
                                   ? mem_pc_plus_4 : mem_alu_result;
    wire [31:0] mem_s1_fwd_val = (mem_s1_wb_sel == 2'b10)
                               ? mem_s1_pc_plus_4 : mem_s1_alu_result;

    function automatic logic [31:0] select_registered_group(
        input logic [ 1:0] group_select,
        input logic [31:0] mem_data,
        input logic [31:0] wb_data,
        input logic [31:0] rf_data
    );
        case (group_select)
            2'b00:   select_registered_group = mem_data;
            2'b01:   select_registered_group = wb_data;
            default: select_registered_group = rf_data;
        endcase
    endfunction

`define MUL_FWD_MUX(TAG, SRC_ADDR, RF_DATA, OUT_DATA) \
    /* Match controls are computed in parallel with every payload candidate. */ \
    wire TAG``_s1_mem_hit = mem_s1_valid && mem_s1_reg_write \
                          && !mem_s1_is_load && (mem_s1_rd != 5'd0) \
                          && (mem_s1_rd == SRC_ADDR); \
    wire TAG``_s0_mem_hit = mem_valid && mem_reg_write && !mem_is_load \
                          && (mem_rd != 5'd0) && (mem_rd == SRC_ADDR); \
    wire TAG``_s1_wb_hit = wb_s1_valid && wb_s1_reg_write \
                         && (wb_s1_rd != 5'd0) && (wb_s1_rd == SRC_ADDR); \
    wire TAG``_s0_wb_hit = wb_valid && wb_reg_write \
                         && (wb_rd != 5'd0) && (wb_rd == SRC_ADDR); \
    /* A registered MEM multiplier result is a latency-sensitive candidate */ \
    /* for a dependent younger MUL. Give it a direct final-selector input */ \
    /* while retaining younger Slot-1 MEM priority. */ \
    wire TAG``_s0_mem_mul_fast_select = !TAG``_s1_mem_hit \
                                      && TAG``_s0_mem_hit \
                                      && mem_is_mul \
                                      && !mem_select_pc4; \
    wire TAG``_s0_mem_fallback_hit = TAG``_s0_mem_hit \
                                   && (!mem_is_mul || mem_select_pc4); \
    wire TAG``_mem_group_hit = TAG``_s1_mem_hit \
                             | TAG``_s0_mem_fallback_hit; \
    wire TAG``_wb_group_hit = TAG``_s1_wb_hit | TAG``_s0_wb_hit; \
    wire [31:0] TAG``_mem_group_data = TAG``_s1_mem_hit \
                                      ? mem_s1_fwd_val \
                                      : mem_nonmul_fwd_val; \
    wire [31:0] TAG``_wb_group_data = TAG``_s1_wb_hit \
                                     ? wb_s1_write_data : wb_write_data; \
    wire [1:0] TAG``_registered_select = { \
        ~TAG``_mem_group_hit & ~TAG``_wb_group_hit, \
        ~TAG``_mem_group_hit & TAG``_wb_group_hit \
    }; \
    wire [31:0] TAG``_registered_data = select_registered_group( \
        TAG``_registered_select, TAG``_mem_group_data, \
        TAG``_wb_group_data, RF_DATA \
    ); \
    assign OUT_DATA = TAG``_s0_mem_mul_fast_select \
                    ? mem_mul_result : TAG``_registered_data

    `MUL_FWD_MUX(rs1, id_rs1_addr, rf_rs1_data, mul_rs1_data);
    `MUL_FWD_MUX(rs2, id_rs2_addr, rf_rs2_data, mul_rs2_data);

`undef MUL_FWD_MUX

endmodule
