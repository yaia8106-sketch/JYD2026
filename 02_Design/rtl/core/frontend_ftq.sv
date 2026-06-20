// ============================================================
// Module: frontend_ftq
// Description: BP0/F0/F1 frontend with packet queue and predecode.
//   BP0: current PC prediction, packet allocation, IROM request
//   F0 : 64-bit IROM response alignment, predecode, enqueue
//   F1 : fetch-queue head pair selection for the existing ID stage
// ============================================================

`ifdef SYNTHESIS
`ifdef ABTB_MEASUREMENT
`define FRONTEND_FTQ_ABTB_WIDE_META
`endif
`else
`define FRONTEND_FTQ_ABTB_WIDE_META
`endif

module frontend_ftq
    import cpu_defs::*;
#(
    parameter int FTQ_DEPTH = 8,
    parameter int FTQ_PTR_W = 3,
    parameter int FQ_DEPTH  = 16,
    parameter int FQ_PTR_W  = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // Downstream IF/ID handshake.
    input  logic        id_allowin,

    // Registered backend redirect. Highest priority.
    input  logic        ex_redirect_valid,
    input  logic [31:0] ex_redirect_target,

    // Single 64-bit synchronous IROM.
    output logic [11:0] irom_addr,
    input  logic [63:0] irom_data,

    // Shadow ABTB metadata for the physical fetch-block banks. These fields
    // are captured only when abtb_lookup_accept is asserted.
    input  logic        abtb_bank0_lookup_hit,
    input  logic        abtb_bank0_hit,
    input  logic        abtb_bank0_way,
    input  logic [ 1:0] abtb_bank0_cfi_type,
    input  logic [31:0] abtb_bank0_target,
    input  logic        abtb_bank0_pred_taken,
    input  logic [31:0] abtb_bank0_pred_target,
    input  logic        abtb_bank1_lookup_hit,
    input  logic        abtb_bank1_hit,
    input  logic        abtb_bank1_way,
    input  logic [ 1:0] abtb_bank1_cfi_type,
    input  logic [31:0] abtb_bank1_target,
    input  logic        abtb_bank1_pred_taken,
    input  logic [31:0] abtb_bank1_pred_target,

    // Stage-1 direction metadata is queried in parallel with ABTB and captured
    // with the accepted prediction block. ABTB/PHT branch steering is the
    // default Stage-1 behavior.
    input  logic [ 7:0] stage1_bank0_pht_index,
    input  logic [ 1:0] stage1_bank0_pht_counter,
    input  logic [ 7:0] stage1_bank1_pht_index,
    input  logic [ 1:0] stage1_bank1_pht_counter,

    // F1 output to IF/ID.
    output logic        if_valid,
    output logic        if_ready_go,
    output logic [31:0] if_pc,
    output logic [31:0] if_inst0,
    output logic [31:0] if_inst1,
    output logic        if_s1_valid,
    output logic        if_pred_taken,
    output logic [31:0] if_pred_target,
    output logic        if_pred_source_abtb,
    output logic        if_stage1_branch_owned,
    output logic        if_s1_pred_taken,
    output logic [31:0] if_s1_pred_target,
    output logic        if_s1_pred_source_abtb,
    output logic        if_s1_stage1_branch_owned,
    output logic        if_abtb_hit,
    output logic        if_abtb_way,
    output logic [ 1:0] if_abtb_cfi_type,
    output logic [31:0] if_abtb_target,
    output logic        if_abtb_pred_taken,
    output logic [31:0] if_abtb_pred_target,
    output logic        if_s1_abtb_hit,
    output logic        if_s1_abtb_way,
    output logic [ 1:0] if_s1_abtb_cfi_type,
    output logic [31:0] if_s1_abtb_target,
    output logic        if_s1_abtb_pred_taken,
    output logic [31:0] if_s1_abtb_pred_target,
    output logic [ 7:0] if_stage1_pht_index,
    output logic [ 1:0] if_stage1_pht_counter,
    output logic [ 7:0] if_s1_stage1_pht_index,
    output logic [ 1:0] if_s1_stage1_pht_counter,

    // Compatibility/debug signals used by existing performance monitors.
    output logic [31:0] current_pc,
    output logic        abtb_lookup_accept,
    output logic        stage1_steer_valid,
    output logic        stage1_steer_source_abtb,
    output logic        stage1_steer_branch_owned,
    output logic        stage1_steer_branch_owned_nt,
    output logic        stage1_steer_taken,
    output logic        stage1_steer_bank,
    output logic [ 1:0] stage1_steer_cfi_type,
    output logic [31:0] stage1_steer_target,
    output logic [31:0] stage1_steer_next_pc,
    output logic        can_dual_issue,
    output logic        raw_pair_raw,
    output logic        predict_dual,
    output logic        irom_held_valid,
    output logic        if_skip_out
);

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [6:0]  OP_FENCE = 7'b0001111;
    localparam logic [1:0]  ABTB_TYPE_JAL    = 2'b00;
    localparam logic [1:0]  ABTB_TYPE_CALL   = 2'b01;
    localparam logic [1:0]  ABTB_TYPE_BRANCH = 2'b10;
    localparam logic [FTQ_PTR_W:0] FTQ_DEPTH_COUNT = (FTQ_PTR_W+1)'(FTQ_DEPTH);
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_2 = (FQ_PTR_W+1)'(FQ_DEPTH - 2);
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_4 = (FQ_PTR_W+1)'(FQ_DEPTH - 4);

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;

        logic        pred_taken;
        logic [31:0] pred_target;
        logic        pred_source_abtb;
        logic        stage1_branch_owned;
        logic [ 1:0] pred_cfi_type;
        logic [ 7:0] stage1_pht_index;
        logic [ 1:0] stage1_pht_counter;

        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        is_system;
        logic        is_fence;
        logic        is_illegal;
        logic        is_muldiv;
        logic        is_load;
        logic        is_store;
        logic        is_alu_type;
        logic        writes_rd;
        logic        uses_rs1;
        logic        uses_rs2;
        logic        is_jump;
        logic        is_control;
        logic        is_lsu;
        logic        force_single;
    } fq_entry_t;

    typedef struct packed {
        logic        is_branch;
        logic        is_jal;
        logic        is_jalr;
        logic        is_system;
        logic        is_fence;
        logic        is_illegal;
        logic        is_muldiv;
        logic        is_load;
        logic        is_store;
        logic        is_alu_type;
        logic        writes_rd;
        logic        uses_rs1;
        logic        uses_rs2;
        logic        is_jump;
        logic        is_control;
        logic        is_lsu;
        logic        is_cfi;
        logic        force_single_slot0;
        logic        force_single_slot1;
    } f0_predecode_t;

    typedef struct packed {
        logic        hit;
        logic        way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
        logic [ 1:0] cfi_type;
        logic [31:0] target;
        logic        pred_taken;
        logic [31:0] pred_target;
`endif
    } abtb_meta_t;

    typedef struct packed {
        logic        pred_taken;
        logic        force_single;
        logic        is_alu_type;
        logic        is_lsu;
        logic        is_cfi;
        logic        writes_rd;
        logic        uses_rs1;
        logic        uses_rs2;
        logic [ 4:0] rd;
        logic [ 4:0] rs1;
        logic [ 4:0] rs2;
    } fq_pair_meta_t;

    function automatic logic fq_raw_dep(input fq_pair_meta_t head0,
                                        input fq_pair_meta_t head1);
        begin
            fq_raw_dep = head0.writes_rd && (head0.rd != 5'd0)
                       && ((head1.uses_rs1 && (head1.rs1 == head0.rd))
                        || (head1.uses_rs2 && (head1.rs2 == head0.rd)));
        end
    endfunction

    function automatic logic fq_pair_supported(input fq_pair_meta_t head0,
                                               input fq_pair_meta_t head1);
        logic head0_supported;
        logic head1_supported;
        logic both_lsu;
        logic both_cfi;
        begin
            head0_supported = head0.is_alu_type | head0.is_lsu
                            | head0.is_cfi;
            head1_supported = head1.is_alu_type | head1.is_lsu
                            | head1.is_cfi;
            both_lsu = head0.is_lsu & head1.is_lsu;
            both_cfi = head0.is_cfi & head1.is_cfi;

            // ALU has no extra exclusion. LSU conflicts only with LSU; CFI
            // conflicts only with CFI.
            fq_pair_supported = head0_supported
                              & head1_supported
                              & ~both_lsu
                              & ~both_cfi;
        end
    endfunction

    function automatic logic fq_pair_payload_ok(
        input logic      contiguous,
        input logic      head0_valid,
        input logic      head1_valid,
        input fq_pair_meta_t head0,
        input fq_pair_meta_t head1
    );
        begin
            fq_pair_payload_ok = head0_valid
                               && head1_valid
                               && contiguous
                               && !head0.pred_taken
                               && !head0.force_single
                               && !head1.force_single
                               && !fq_raw_dep(head0, head1)
                               && fq_pair_supported(head0, head1);
        end
    endfunction

    // ================================================================
    //  Small predecode helpers
    // ================================================================
    function automatic logic inst_is_branch(input logic [31:0] inst);
        inst_is_branch = (inst[6:0] == OP_BRANCH);
    endfunction

    function automatic logic inst_is_jal(input logic [31:0] inst);
        inst_is_jal = (inst[6:0] == OP_JAL);
    endfunction

    function automatic logic inst_is_jalr(input logic [31:0] inst);
        inst_is_jalr = (inst[6:0] == OP_JALR);
    endfunction

    function automatic logic inst_is_system(input logic [31:0] inst);
        inst_is_system = (inst[6:0] == OP_SYSTEM);
    endfunction

    function automatic logic inst_is_fence(input logic [31:0] inst);
        inst_is_fence = (inst[6:0] == OP_FENCE);
    endfunction

    function automatic logic inst_is_muldiv(input logic [31:0] inst);
        inst_is_muldiv = (inst[6:0] == OP_R_TYPE) && (inst[31:25] == MULDIV_FUNCT7);
    endfunction

    function automatic logic inst_is_illegal(input logic [31:0] inst);
        inst_is_illegal = (inst[1:0] != 2'b11);
    endfunction

    function automatic logic inst_is_load(input logic [31:0] inst);
        inst_is_load = (inst[6:0] == OP_LOAD);
    endfunction

    function automatic logic inst_is_store(input logic [31:0] inst);
        inst_is_store = (inst[6:0] == OP_STORE);
    endfunction

    function automatic logic inst_is_alu_type(input logic [31:0] inst);
        logic is_muldiv;
        begin
            is_muldiv = inst_is_muldiv(inst);
            inst_is_alu_type = ((inst[6:0] == OP_R_TYPE) && !is_muldiv)
                             || (inst[6:0] == OP_I_ALU)
                             || (inst[6:0] == OP_LUI)
                             || (inst[6:0] == OP_AUIPC);
        end
    endfunction

    function automatic logic inst_writes_rd(input logic [31:0] inst);
        logic [6:0] op;
        begin
            op = inst[6:0];
            inst_writes_rd = (op == OP_R_TYPE)
                           || (op == OP_I_ALU)
                           || (op == OP_LOAD)
                           || (op == OP_LUI)
                           || (op == OP_AUIPC)
                           || (op == OP_JAL)
                           || (op == OP_JALR)
                           || (op == OP_SYSTEM);
        end
    endfunction

    function automatic logic inst_uses_rs1(input logic [31:0] inst);
        logic [6:0] op;
        begin
            op = inst[6:0];
            inst_uses_rs1 = (op == OP_R_TYPE)
                          || (op == OP_I_ALU)
                          || (op == OP_LOAD)
                          || (op == OP_STORE)
                          || (op == OP_BRANCH)
                          || (op == OP_JALR);
        end
    endfunction

    function automatic logic inst_uses_rs2(input logic [31:0] inst);
        logic [6:0] op;
        begin
            op = inst[6:0];
            inst_uses_rs2 = (op == OP_R_TYPE)
                          || (op == OP_STORE)
                          || (op == OP_BRANCH);
        end
    endfunction

    function automatic f0_predecode_t f0_predecode_inst(input logic [31:0] inst);
        begin
            f0_predecode_inst = '0;
            f0_predecode_inst.is_branch = inst_is_branch(inst);
            f0_predecode_inst.is_jal = inst_is_jal(inst);
            f0_predecode_inst.is_jalr = inst_is_jalr(inst);
            f0_predecode_inst.is_system = inst_is_system(inst);
            f0_predecode_inst.is_fence = inst_is_fence(inst);
            f0_predecode_inst.is_illegal = inst_is_illegal(inst);
            f0_predecode_inst.is_muldiv = inst_is_muldiv(inst);
            f0_predecode_inst.is_load = inst_is_load(inst);
            f0_predecode_inst.is_store = inst_is_store(inst);
            f0_predecode_inst.is_alu_type = inst_is_alu_type(inst);
            f0_predecode_inst.writes_rd = inst_writes_rd(inst);
            f0_predecode_inst.uses_rs1 = inst_uses_rs1(inst);
            f0_predecode_inst.uses_rs2 = inst_uses_rs2(inst);
            f0_predecode_inst.is_jump = f0_predecode_inst.is_jal
                                      | f0_predecode_inst.is_jalr
                                      | f0_predecode_inst.is_system;
            f0_predecode_inst.is_control = f0_predecode_inst.is_branch
                                         | f0_predecode_inst.is_jal
                                         | f0_predecode_inst.is_jalr
                                         | f0_predecode_inst.is_system;
            f0_predecode_inst.is_lsu = f0_predecode_inst.is_load
                                     | f0_predecode_inst.is_store;
            f0_predecode_inst.is_cfi = f0_predecode_inst.is_branch
                                     | f0_predecode_inst.is_jal
                                     | f0_predecode_inst.is_jalr;
            f0_predecode_inst.force_single_slot0 =
                f0_predecode_inst.is_jalr
                | f0_predecode_inst.is_system
                | f0_predecode_inst.is_fence
                | f0_predecode_inst.is_illegal
                | f0_predecode_inst.is_muldiv;
            f0_predecode_inst.force_single_slot1 =
                f0_predecode_inst.is_system
                | f0_predecode_inst.is_fence
                | f0_predecode_inst.is_illegal
                | f0_predecode_inst.is_muldiv;
        end
    endfunction

    function automatic fq_entry_t f0_make_entry(
        input logic          valid,
        input logic [31:0]   pc,
        input logic [31:0]   inst,
        input f0_predecode_t dec,
        input logic          force_single,
        input logic          pred_taken,
        input logic [31:0]   pred_target,
        input logic          pred_source_abtb,
        input logic          stage1_branch_owned,
        input logic [ 1:0]   final_cfi_type,
        input logic [ 7:0]   stage1_pht_index,
        input logic [ 1:0]   stage1_pht_counter
    );
        begin
            f0_make_entry = '0;
            f0_make_entry.valid = valid;
            f0_make_entry.pc = pc;
            f0_make_entry.inst = inst;
            f0_make_entry.pred_taken = pred_taken;
            f0_make_entry.pred_target = pred_target;
            f0_make_entry.pred_source_abtb = pred_source_abtb;
            f0_make_entry.stage1_branch_owned = stage1_branch_owned;
            f0_make_entry.pred_cfi_type = stage1_branch_owned
                                        ? ABTB_TYPE_BRANCH
                                        : pred_taken
                                        ? final_cfi_type
                                        : 2'd0;
            f0_make_entry.stage1_pht_index = stage1_pht_index;
            f0_make_entry.stage1_pht_counter = stage1_pht_counter;
            f0_make_entry.is_branch = dec.is_branch;
            f0_make_entry.is_jal = dec.is_jal;
            f0_make_entry.is_jalr = dec.is_jalr;
            f0_make_entry.is_system = dec.is_system;
            f0_make_entry.is_fence = dec.is_fence;
            f0_make_entry.is_illegal = dec.is_illegal;
            f0_make_entry.is_muldiv = dec.is_muldiv;
            f0_make_entry.is_load = dec.is_load;
            f0_make_entry.is_store = dec.is_store;
            f0_make_entry.is_alu_type = dec.is_alu_type;
            f0_make_entry.writes_rd = dec.writes_rd;
            f0_make_entry.uses_rs1 = dec.uses_rs1;
            f0_make_entry.uses_rs2 = dec.uses_rs2;
            f0_make_entry.is_jump = dec.is_jump;
            f0_make_entry.is_control = dec.is_control;
            f0_make_entry.is_lsu = dec.is_lsu;
            f0_make_entry.force_single = force_single;
        end
    endfunction

    function automatic fq_pair_meta_t f0_make_pair_meta(
        input logic [31:0]   inst,
        input f0_predecode_t dec,
        input logic          pred_taken,
        input logic          force_single
    );
        begin
            f0_make_pair_meta = '0;
            f0_make_pair_meta.pred_taken = pred_taken;
            f0_make_pair_meta.force_single = force_single;
            f0_make_pair_meta.is_alu_type = dec.is_alu_type;
            f0_make_pair_meta.is_lsu = dec.is_lsu;
            f0_make_pair_meta.is_cfi = dec.is_cfi;
            f0_make_pair_meta.writes_rd = dec.writes_rd;
            f0_make_pair_meta.uses_rs1 = dec.uses_rs1;
            f0_make_pair_meta.uses_rs2 = dec.uses_rs2;
            f0_make_pair_meta.rd = inst[11:7];
            f0_make_pair_meta.rs1 = inst[19:15];
            f0_make_pair_meta.rs2 = inst[24:20];
        end
    endfunction

    // ================================================================
    //  BP0 / F0 metadata
    // ================================================================
    logic [1:0] frontend_epoch;

    logic       f0_valid_r;
    logic [1:0] f0_epoch_r;
    logic [31:0] f0_start_pc_r;
    logic [1:0]  f0_base_mask_r;
    logic        f0_steer_taken_r;
    logic        f0_steer_source_abtb_r;
    logic        f0_steer_bank_r;
    logic [ 1:0] f0_steer_cfi_type_r;
    logic [31:0] f0_steer_target_r;
    logic [31:0] f0_steer_next_pc_r;
    // The accepted canonical result is the sole F0 prediction source.
    logic        f0_stage1_bank0_branch_owned_r;
    logic        f0_stage1_bank1_branch_owned_r;
    logic [ 7:0] f0_stage1_bank0_pht_index_r;
    logic [ 1:0] f0_stage1_bank0_pht_counter_r;
    logic [ 7:0] f0_stage1_bank1_pht_index_r;
    logic [ 1:0] f0_stage1_bank1_pht_counter_r;
    logic        f0_abtb_bank0_hit_r;
    logic        f0_abtb_bank0_way_r;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    logic [ 1:0] f0_abtb_bank0_cfi_type_r;
    logic [31:0] f0_abtb_bank0_target_r;
    logic        f0_abtb_bank0_pred_taken_r;
    logic [31:0] f0_abtb_bank0_pred_target_r;
`endif
    logic        f0_abtb_bank1_hit_r;
    logic        f0_abtb_bank1_way_r;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    logic [ 1:0] f0_abtb_bank1_cfi_type_r;
    logic [31:0] f0_abtb_bank1_target_r;
    logic        f0_abtb_bank1_pred_taken_r;
    logic [31:0] f0_abtb_bank1_pred_target_r;
`endif
    // Outstanding fetch-packet count used for allocation throttling and perf taps.
    logic [FTQ_PTR_W:0]   ftq_count;

    wire bp0_fire;
    wire [31:0] bp0_seq_next_pc = current_pc + (current_pc[2] ? 32'd4 : 32'd8);
    wire [1:0]  bp0_base_mask = current_pc[2] ? 2'b01 : 2'b11;

    // Direct J/CALL direction is intrinsic to the CFI type. Branch ownership
    // is independent from taken steering so an ABTB/PHT not-taken decision can
    // remain authoritative for that instruction.
    wire abtb_bank0_direct_lookup =
        abtb_bank0_lookup_hit
        && ((abtb_bank0_cfi_type == ABTB_TYPE_JAL)
            || (abtb_bank0_cfi_type == ABTB_TYPE_CALL));
    wire abtb_bank1_direct_lookup =
        abtb_bank1_lookup_hit
        && ((abtb_bank1_cfi_type == ABTB_TYPE_JAL)
            || (abtb_bank1_cfi_type == ABTB_TYPE_CALL));

    wire abtb_bank0_direct_candidate = abtb_bank0_direct_lookup;
    wire abtb_bank1_direct_candidate = abtb_bank1_direct_lookup;

    wire abtb_bank0_branch_owned =
        abtb_bank0_lookup_hit
        && (abtb_bank0_cfi_type == ABTB_TYPE_BRANCH);
    wire abtb_bank1_branch_owned =
        abtb_bank1_lookup_hit
        && (abtb_bank1_cfi_type == ABTB_TYPE_BRANCH);

    wire abtb_bank0_stage1_valid =
        abtb_bank0_direct_candidate || abtb_bank0_branch_owned;
    wire abtb_bank1_stage1_valid =
        abtb_bank1_direct_candidate || abtb_bank1_branch_owned;
    wire abtb_bank0_stage1_taken =
        abtb_bank0_direct_candidate
        || (abtb_bank0_branch_owned && abtb_bank0_pred_taken);
    wire abtb_bank1_stage1_taken =
        abtb_bank1_direct_candidate
        || (abtb_bank1_branch_owned && abtb_bank1_pred_taken);

    wire bp0_first_abtb_valid = current_pc[2]
                              ? abtb_bank1_stage1_valid
                              : abtb_bank0_stage1_valid;
    wire bp0_first_abtb_taken = current_pc[2]
                              ? abtb_bank1_stage1_taken
                              : abtb_bank0_stage1_taken;
    wire bp0_first_abtb_bank = current_pc[2];
    wire [1:0] bp0_first_abtb_cfi_type = current_pc[2]
                                               ? abtb_bank1_cfi_type
                                               : abtb_bank0_cfi_type;
    wire [31:0] bp0_first_abtb_target = current_pc[2]
                                              ? abtb_bank1_target
                                              : abtb_bank0_target;
    wire bp0_second_abtb_valid = !current_pc[2]
                               && abtb_bank1_stage1_valid;
    wire bp0_second_abtb_taken = bp0_second_abtb_valid
                               && abtb_bank1_stage1_taken;
    wire [1:0] bp0_second_abtb_cfi_type = abtb_bank1_cfi_type;
    wire [31:0] bp0_second_abtb_target = abtb_bank1_target;

    always_comb begin
        stage1_steer_valid = bp0_fire;
        stage1_steer_source_abtb = 1'b0;
        stage1_steer_branch_owned = 1'b0;
        stage1_steer_branch_owned_nt = 1'b0;
        stage1_steer_taken = 1'b0;
        stage1_steer_bank = current_pc[2];
        stage1_steer_cfi_type = 2'd0;
        stage1_steer_target = bp0_seq_next_pc;
        stage1_steer_next_pc = bp0_seq_next_pc;

        // An ABTB-owned first instruction is authoritative even when its PHT
        // direction is not-taken. In that case arbitration continues only to
        // the younger bank1 candidate, never back to legacy for the same PC.
        if (bp0_first_abtb_valid) begin
            stage1_steer_source_abtb = bp0_first_abtb_taken;
            stage1_steer_branch_owned =
                (bp0_first_abtb_cfi_type == ABTB_TYPE_BRANCH);
            stage1_steer_branch_owned_nt =
                (bp0_first_abtb_cfi_type == ABTB_TYPE_BRANCH)
                && !bp0_first_abtb_taken;
            stage1_steer_taken = bp0_first_abtb_taken;
            stage1_steer_bank = bp0_first_abtb_bank;
            stage1_steer_cfi_type = bp0_first_abtb_cfi_type;
            stage1_steer_target = bp0_first_abtb_target;
            stage1_steer_next_pc = bp0_first_abtb_taken
                                 ? bp0_first_abtb_target
                                 : bp0_seq_next_pc;
            if (!bp0_first_abtb_taken && bp0_second_abtb_taken) begin
                stage1_steer_source_abtb = 1'b1;
                stage1_steer_taken = 1'b1;
                stage1_steer_bank = 1'b1;
                stage1_steer_cfi_type = bp0_second_abtb_cfi_type;
                stage1_steer_target = bp0_second_abtb_target;
                stage1_steer_next_pc = bp0_second_abtb_target;
            end
        end else if (bp0_second_abtb_taken) begin
            stage1_steer_source_abtb = 1'b1;
            stage1_steer_taken = 1'b1;
            stage1_steer_bank = 1'b1;
            stage1_steer_cfi_type = bp0_second_abtb_cfi_type;
            stage1_steer_target = bp0_second_abtb_target;
            stage1_steer_next_pc = bp0_second_abtb_target;
        end
    end

    assign irom_addr = {1'b0, current_pc[13:3]};

    // ================================================================
    //  F0 alignment and enqueue preparation
    // ================================================================
    wire f0_epoch_match = (f0_epoch_r == frontend_epoch);
    wire f0_accept_base = f0_valid_r
                        && f0_epoch_match
                        && !ex_redirect_valid;

    wire [31:0] f0_slot0_inst = f0_start_pc_r[2] ? irom_data[63:32]
                                                  : irom_data[31:0];
    wire [31:0] f0_slot1_inst = f0_start_pc_r[2] ? 32'h0000_0013
                                                  : irom_data[63:32];
    wire [31:0] f0_slot0_pc = f0_start_pc_r;
    wire [31:0] f0_slot1_pc = f0_start_pc_r + 32'd4;

    wire f0_predecode_t f0_slot0_dec = f0_predecode_inst(f0_slot0_inst);
    wire f0_predecode_t f0_slot1_dec = f0_predecode_inst(f0_slot1_inst);
    // Compatibility aliases for existing directed-test hierarchy probes.
    wire f0_slot0_branch = f0_slot0_dec.is_branch;
    wire f0_slot0_jal = f0_slot0_dec.is_jal;
    wire f0_slot0_jalr = f0_slot0_dec.is_jalr;
    wire f0_slot0_force_single = f0_slot0_dec.force_single_slot0;
    wire f0_slot1_force_single = f0_slot1_dec.force_single_slot1;
    wire f0_slot0_system_redirect =
        f0_slot0_dec.is_system && (f0_slot0_inst[14:12] == 3'b000);

    wire f0_slot0_stage1_branch_owned =
        f0_slot0_dec.is_branch
        && (f0_start_pc_r[2] ? f0_stage1_bank1_branch_owned_r
                             : f0_stage1_bank0_branch_owned_r);
    wire f0_slot1_stage1_branch_owned =
        f0_slot1_dec.is_branch
        && !f0_start_pc_r[2]
        && f0_stage1_bank1_branch_owned_r;

    logic        f0_final_taken;
    logic        f0_final_source_abtb;
    logic        f0_final_bank;
    logic [ 1:0] f0_final_cfi_type;
    logic [31:0] f0_final_target;
    logic [31:0] f0_final_next_pc;
    logic        f0_slot0_pred_taken;
    logic [31:0] f0_slot0_pred_target;
    logic        f0_slot0_pred_source_abtb;
    logic        f0_slot1_pred_taken;
    logic [31:0] f0_slot1_pred_target;
    logic        f0_slot1_pred_source_abtb;
    logic [ 7:0] f0_slot0_stage1_pht_index;
    logic [ 1:0] f0_slot0_stage1_pht_counter;
    logic [ 7:0] f0_slot1_stage1_pht_index;
    logic [ 1:0] f0_slot1_stage1_pht_counter;

    always_comb begin
        // F0 consumes the exact canonical result accepted at BP0.
        f0_final_taken = f0_steer_taken_r;
        f0_final_source_abtb = f0_steer_source_abtb_r;
        f0_final_bank = f0_steer_bank_r;
        f0_final_cfi_type = f0_steer_cfi_type_r;
        f0_final_target = f0_steer_target_r;
        f0_final_next_pc = f0_steer_next_pc_r;

        f0_slot0_pred_taken = f0_final_taken
                            && (f0_final_bank == f0_start_pc_r[2]);
        f0_slot0_pred_target = f0_slot0_pred_taken ? f0_final_target
                                                   : (f0_slot0_pc + 32'd4);
        f0_slot0_pred_source_abtb =
            f0_slot0_pred_taken && f0_final_source_abtb;
        f0_slot1_pred_taken = f0_final_taken
                            && !f0_start_pc_r[2]
                            && f0_final_bank;
        f0_slot1_pred_target = f0_slot1_pred_taken ? f0_final_target : 32'd0;
        f0_slot1_pred_source_abtb =
            f0_slot1_pred_taken && f0_final_source_abtb;

        if (f0_start_pc_r[2]) begin
            f0_slot0_stage1_pht_index = f0_stage1_bank1_pht_index_r;
            f0_slot0_stage1_pht_counter = f0_stage1_bank1_pht_counter_r;
        end else begin
            f0_slot0_stage1_pht_index = f0_stage1_bank0_pht_index_r;
            f0_slot0_stage1_pht_counter = f0_stage1_bank0_pht_counter_r;
        end
        f0_slot1_stage1_pht_index = f0_stage1_bank1_pht_index_r;
        f0_slot1_stage1_pht_counter = f0_stage1_bank1_pht_counter_r;
    end

    wire redirect_valid = ex_redirect_valid;
    wire [31:0] redirect_target = ex_redirect_target;

    wire f0_kill_after_slot0 = f0_slot0_dec.is_jal
                             || f0_slot0_dec.is_jalr
                             || f0_slot0_system_redirect
                             || f0_slot0_pred_taken;
    wire f0_enq0_payload = f0_accept_base && f0_base_mask_r[0];
    wire f0_enq1_payload = f0_accept_base && f0_base_mask_r[1];
    wire f0_enq0_valid = f0_enq0_payload;
    wire f0_enq1_valid = f0_enq1_payload && !f0_kill_after_slot0;
    wire f0_enq_two  = f0_enq1_valid;
    wire f0_enq_one  = f0_enq0_valid && !f0_enq1_valid;
    wire f0_enq_none = !f0_enq0_valid;

    fq_entry_t f0_entry0;
    fq_entry_t f0_entry1;
    fq_pair_meta_t f0_pair_meta0;
    fq_pair_meta_t f0_pair_meta1;

    always @* begin
        f0_entry0 = f0_make_entry(
            f0_enq0_valid,
            f0_slot0_pc,
            f0_slot0_inst,
            f0_slot0_dec,
            f0_slot0_force_single,
            f0_slot0_pred_taken,
            f0_slot0_pred_target,
            f0_slot0_pred_source_abtb,
            f0_slot0_stage1_branch_owned,
            f0_final_cfi_type,
            f0_slot0_stage1_pht_index,
            f0_slot0_stage1_pht_counter
        );

        f0_entry1 = f0_make_entry(
            f0_enq1_valid,
            f0_slot1_pc,
            f0_slot1_inst,
            f0_slot1_dec,
            f0_slot1_force_single,
            f0_slot1_pred_taken,
            f0_slot1_pred_target,
            f0_slot1_pred_source_abtb,
            f0_slot1_stage1_branch_owned,
            f0_final_cfi_type,
            f0_slot1_stage1_pht_index,
            f0_slot1_stage1_pht_counter
        );
    end

    always_comb begin
        f0_pair_meta0 = f0_make_pair_meta(
            f0_slot0_inst,
            f0_slot0_dec,
            f0_slot0_pred_taken,
            f0_slot0_force_single
        );

        // A taken slot1 may issue as this pair's follower, but it cannot lead a
        // later cross-packet pair.
        f0_pair_meta1 = f0_make_pair_meta(
            f0_slot1_inst,
            f0_slot1_dec,
            f0_slot1_pred_taken,
            f0_slot1_force_single
        );
    end

    // ================================================================
    //  Instruction-granular fetch queue
    // ================================================================
    fq_entry_t fq_mem [0:FQ_DEPTH-1];
    fq_pair_meta_t fq_pair_meta [0:FQ_DEPTH-1];
    logic      fq_pair_ok [0:FQ_DEPTH-1];
    logic [FQ_PTR_W-1:0] fq_head;
    logic [FQ_PTR_W-1:0] fq_tail;
    logic [FQ_PTR_W:0]   fq_count;
    logic [31:0] fq_tail_next_pc;

    wire [FQ_PTR_W-1:0] fq_head_p1 = fq_head + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    wire [FQ_PTR_W-1:0] fq_head_p2 = fq_head + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] fq_tail_p1 = fq_tail + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    wire [FQ_PTR_W-1:0] fq_tail_p2 = fq_tail + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] fq_tail_m1 = fq_tail - {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    fq_entry_t fq_head0;
    fq_entry_t fq_head1;
    fq_entry_t fq_tail_prev;
    fq_pair_meta_t fq_head0_pair_meta;
    fq_pair_meta_t fq_head1_pair_meta;
    fq_pair_meta_t fq_tail_prev_pair_meta;
    abtb_meta_t f0_abtb_meta0;
    abtb_meta_t f0_abtb_meta1;
    abtb_meta_t fq_abtb_even_read;
    abtb_meta_t fq_abtb_odd_read;
    abtb_meta_t fq_head0_abtb_meta;
    abtb_meta_t fq_head1_abtb_meta;

    // ABTB payload is a sidecar to the valid-controlled FQ. Banking by entry
    // parity permits two consecutive writes and two consecutive reads with one
    // port per bank, while avoiding reset and flush muxes on the wide payload.
    (* ram_style = "distributed" *)
    logic fq_abtb_even_hit [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic fq_abtb_even_way [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic fq_abtb_odd_hit [0:(FQ_DEPTH/2)-1];
    (* ram_style = "distributed" *)
    logic fq_abtb_odd_way [0:(FQ_DEPTH/2)-1];
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    abtb_meta_t fq_abtb_even_dbg [0:(FQ_DEPTH/2)-1];
    abtb_meta_t fq_abtb_odd_dbg [0:(FQ_DEPTH/2)-1];
`endif

    assign fq_head0 = fq_mem[fq_head];
    assign fq_head1 = fq_mem[fq_head_p1];
    assign fq_tail_prev = fq_mem[fq_tail_m1];
    assign fq_head0_pair_meta = fq_pair_meta[fq_head];
    assign fq_head1_pair_meta = fq_pair_meta[fq_head_p1];
    assign fq_tail_prev_pair_meta = fq_pair_meta[fq_tail_m1];

    always_comb begin
        // A fetch beginning at block_pc+4 presents physical bank1 as the first
        // instruction. Keep metadata bound to the instruction PC.
        if (f0_start_pc_r[2]) begin
            f0_abtb_meta0.hit = f0_abtb_bank1_hit_r;
            f0_abtb_meta0.way = f0_abtb_bank1_way_r;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
            f0_abtb_meta0.cfi_type = f0_abtb_bank1_cfi_type_r;
            f0_abtb_meta0.target = f0_abtb_bank1_target_r;
            f0_abtb_meta0.pred_taken = f0_abtb_bank1_pred_taken_r;
            f0_abtb_meta0.pred_target = f0_abtb_bank1_pred_target_r;
`endif
        end else begin
            f0_abtb_meta0.hit = f0_abtb_bank0_hit_r;
            f0_abtb_meta0.way = f0_abtb_bank0_way_r;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
            f0_abtb_meta0.cfi_type = f0_abtb_bank0_cfi_type_r;
            f0_abtb_meta0.target = f0_abtb_bank0_target_r;
            f0_abtb_meta0.pred_taken = f0_abtb_bank0_pred_taken_r;
            f0_abtb_meta0.pred_target = f0_abtb_bank0_pred_target_r;
`endif
        end

        f0_abtb_meta1.hit = f0_abtb_bank1_hit_r;
        f0_abtb_meta1.way = f0_abtb_bank1_way_r;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
        f0_abtb_meta1.cfi_type = f0_abtb_bank1_cfi_type_r;
        f0_abtb_meta1.target = f0_abtb_bank1_target_r;
        f0_abtb_meta1.pred_taken = f0_abtb_bank1_pred_taken_r;
        f0_abtb_meta1.pred_target = f0_abtb_bank1_pred_target_r;
`endif
    end

    wire [FQ_PTR_W-2:0] fq_abtb_even_read_row =
        fq_head[0] ? fq_head_p1[FQ_PTR_W-1:1] : fq_head[FQ_PTR_W-1:1];
    wire [FQ_PTR_W-2:0] fq_abtb_odd_read_row = fq_head[FQ_PTR_W-1:1];

    always_comb begin
        fq_abtb_even_read = '0;
        fq_abtb_odd_read = '0;

        fq_abtb_even_read.hit = fq_abtb_even_hit[fq_abtb_even_read_row];
        fq_abtb_even_read.way = fq_abtb_even_way[fq_abtb_even_read_row];
        fq_abtb_odd_read.hit = fq_abtb_odd_hit[fq_abtb_odd_read_row];
        fq_abtb_odd_read.way = fq_abtb_odd_way[fq_abtb_odd_read_row];
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
        fq_abtb_even_read.cfi_type =
            fq_abtb_even_dbg[fq_abtb_even_read_row].cfi_type;
        fq_abtb_even_read.target =
            fq_abtb_even_dbg[fq_abtb_even_read_row].target;
        fq_abtb_even_read.pred_taken =
            fq_abtb_even_dbg[fq_abtb_even_read_row].pred_taken;
        fq_abtb_even_read.pred_target =
            fq_abtb_even_dbg[fq_abtb_even_read_row].pred_target;
        fq_abtb_odd_read.cfi_type =
            fq_abtb_odd_dbg[fq_abtb_odd_read_row].cfi_type;
        fq_abtb_odd_read.target =
            fq_abtb_odd_dbg[fq_abtb_odd_read_row].target;
        fq_abtb_odd_read.pred_taken =
            fq_abtb_odd_dbg[fq_abtb_odd_read_row].pred_taken;
        fq_abtb_odd_read.pred_target =
            fq_abtb_odd_dbg[fq_abtb_odd_read_row].pred_target;
`endif
    end

`ifdef ABTB_TB_FAULT_DEQUEUE_SELECT
    assign fq_head0_abtb_meta = fq_head[0] ? fq_abtb_even_read
                                           : fq_abtb_odd_read;
    assign fq_head1_abtb_meta = fq_head[0] ? fq_abtb_odd_read
                                           : fq_abtb_even_read;
`else
    assign fq_head0_abtb_meta = fq_head[0] ? fq_abtb_odd_read
                                           : fq_abtb_even_read;
    assign fq_head1_abtb_meta = fq_head[0] ? fq_abtb_even_read
                                           : fq_abtb_odd_read;
`endif

    wire fq_has_slot0 = (fq_count != 0);
    wire fq_has_slot1 = (fq_count >= 2);
    wire fq_tail_has_prev = (fq_count != 0);
    wire fq_prev_tail_next_contiguous =
        fq_tail_has_prev && (fq_tail_next_pc == f0_slot0_pc);

    wire fq_prev_tail_pair_ok =
        fq_pair_payload_ok(fq_prev_tail_next_contiguous,
                           fq_tail_has_prev,
                           f0_enq0_valid,
                           fq_tail_prev_pair_meta,
                           f0_pair_meta0);
    wire f0_entry0_pair_ok =
        fq_pair_payload_ok(1'b1,
                           f0_enq0_valid,
                           f0_enq1_valid,
                           f0_pair_meta0,
                           f0_pair_meta1);

    assign raw_pair_raw = fq_raw_dep(fq_head0_pair_meta, fq_head1_pair_meta);

    wire pair_policy_ok = fq_has_slot1 && fq_pair_ok[fq_head];

    assign can_dual_issue = pair_policy_ok;
    assign predict_dual = pair_policy_ok;
    assign if_s1_valid = pair_policy_ok;
    assign if_valid = fq_has_slot0 && fq_head0.valid;
    assign if_ready_go = 1'b1;

    assign if_pc    = fq_head0.pc;
    assign if_inst0 = fq_head0.inst;
    assign if_inst1 = fq_head1.inst;
    assign if_pred_taken    = fq_head0.pred_taken;
    assign if_pred_target   = fq_head0.pred_target;
    assign if_pred_source_abtb = fq_head0.pred_source_abtb;
    assign if_stage1_branch_owned = fq_head0.stage1_branch_owned;
    assign if_s1_pred_taken    = fq_head1.pred_taken;
    assign if_s1_pred_target   = fq_head1.pred_target;
    assign if_s1_pred_source_abtb = fq_head1.pred_source_abtb;
    assign if_s1_stage1_branch_owned = fq_head1.stage1_branch_owned;
    assign if_stage1_pht_index = fq_head0.stage1_pht_index;
    assign if_stage1_pht_counter = fq_head0.stage1_pht_counter;
    assign if_s1_stage1_pht_index = fq_head1.stage1_pht_index;
    assign if_s1_stage1_pht_counter = fq_head1.stage1_pht_counter;
    assign if_abtb_hit         = fq_head0_abtb_meta.hit;
    assign if_abtb_way         = fq_head0_abtb_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    assign if_abtb_cfi_type    = fq_head0_abtb_meta.cfi_type;
    assign if_abtb_target      = fq_head0_abtb_meta.target;
    assign if_abtb_pred_taken  = fq_head0_abtb_meta.pred_taken;
    assign if_abtb_pred_target = fq_head0_abtb_meta.pred_target;
`else
    assign if_abtb_cfi_type    = 2'd0;
    assign if_abtb_target      = 32'd0;
    assign if_abtb_pred_taken  = 1'b0;
    assign if_abtb_pred_target = 32'd0;
`endif
    assign if_s1_abtb_hit         = fq_head1_abtb_meta.hit;
    assign if_s1_abtb_way         = fq_head1_abtb_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    assign if_s1_abtb_cfi_type    = fq_head1_abtb_meta.cfi_type;
    assign if_s1_abtb_target      = fq_head1_abtb_meta.target;
    assign if_s1_abtb_pred_taken  = fq_head1_abtb_meta.pred_taken;
    assign if_s1_abtb_pred_target = fq_head1_abtb_meta.pred_target;
`else
    assign if_s1_abtb_cfi_type    = 2'd0;
    assign if_s1_abtb_target      = 32'd0;
    assign if_s1_abtb_pred_taken  = 1'b0;
    assign if_s1_abtb_pred_target = 32'd0;
`endif

    wire if_accept = if_valid && if_ready_go && id_allowin;

    wire [FQ_PTR_W:0] fq_count_p2 = fq_count + {{(FQ_PTR_W-1){1'b0}}, 2'd2};
    wire [FQ_PTR_W:0] fq_count_p1 = fq_count + {{FQ_PTR_W{1'b0}}, 1'b1};
    wire [FQ_PTR_W:0] fq_count_m1 = fq_count - {{FQ_PTR_W{1'b0}}, 1'b1};
    wire [FQ_PTR_W:0] fq_count_m2 = fq_count - {{(FQ_PTR_W-1){1'b0}}, 2'd2};

    wire if_accept_dual = if_accept & can_dual_issue;
    wire if_accept_single = if_accept & ~can_dual_issue;
    wire if_accept_none = ~if_accept;

    wire [FQ_PTR_W-1:0] fq_head_next =
        ({FQ_PTR_W{if_accept_dual}}   & fq_head_p2) |
        ({FQ_PTR_W{if_accept_single}} & fq_head_p1) |
        ({FQ_PTR_W{~if_accept}}       & fq_head);

    wire [FQ_PTR_W-1:0] fq_tail_next =
        ({FQ_PTR_W{f0_enq_two}}  & fq_tail_p2) |
        ({FQ_PTR_W{f0_enq_one}}  & fq_tail_p1) |
        ({FQ_PTR_W{f0_enq_none}} & fq_tail);
    wire [31:0] f0_enq_last_next_pc =
        f0_enq_two ? (f0_slot1_pc + 32'd4) : (f0_slot0_pc + 32'd4);
    wire [31:0] fq_tail_next_pc_next =
        f0_enq0_valid ? f0_enq_last_next_pc : fq_tail_next_pc;

`ifdef ABTB_TB_FAULT_KILLED_SLOT1_WRITE
    wire fq_abtb_slot1_write_valid = f0_enq1_payload;
`else
    wire fq_abtb_slot1_write_valid = f0_enq1_valid;
`endif
`ifdef ABTB_TB_FAULT_SLOT1_ROW
    wire [FQ_PTR_W-1:0] fq_abtb_entry1_ptr =
        fq_tail_p1 ^ {{(FQ_PTR_W-2){1'b0}}, 2'b10};
`else
    wire [FQ_PTR_W-1:0] fq_abtb_entry1_ptr = fq_tail_p1;
`endif
    abtb_meta_t f0_abtb_meta1_write_data;

    always_comb begin
        f0_abtb_meta1_write_data = f0_abtb_meta1;
`ifdef ABTB_TB_FAULT_SLOT1_DATA
        f0_abtb_meta1_write_data.hit = !f0_abtb_meta1.hit;
`endif
    end

    wire fq_abtb_even_write_entry0 = f0_enq0_valid && !fq_tail[0];
    wire fq_abtb_even_write_entry1 =
        fq_abtb_slot1_write_valid && !fq_tail_p1[0];
    wire fq_abtb_odd_write_entry0 = f0_enq0_valid && fq_tail[0];
    wire fq_abtb_odd_write_entry1 =
        fq_abtb_slot1_write_valid && fq_tail_p1[0];
    wire fq_abtb_even_write =
        fq_abtb_even_write_entry0 || fq_abtb_even_write_entry1;
    wire fq_abtb_odd_write =
        fq_abtb_odd_write_entry0 || fq_abtb_odd_write_entry1;
    wire [FQ_PTR_W-2:0] fq_abtb_even_write_row =
        fq_abtb_even_write_entry0 ? fq_tail[FQ_PTR_W-1:1]
                                  : fq_abtb_entry1_ptr[FQ_PTR_W-1:1];
    wire [FQ_PTR_W-2:0] fq_abtb_odd_write_row =
        fq_abtb_odd_write_entry0 ? fq_tail[FQ_PTR_W-1:1]
                                 : fq_abtb_entry1_ptr[FQ_PTR_W-1:1];
    wire abtb_meta_t fq_abtb_even_write_data =
        fq_abtb_even_write_entry0 ? f0_abtb_meta0
                                  : f0_abtb_meta1_write_data;
    wire abtb_meta_t fq_abtb_odd_write_data =
        fq_abtb_odd_write_entry0 ? f0_abtb_meta0
                                 : f0_abtb_meta1_write_data;

    wire fq_count_inc2 = f0_enq_two & if_accept_none;
    wire fq_count_inc1 = (f0_enq_two & if_accept_single)
                       | (f0_enq_one & if_accept_none);
    wire fq_count_dec1 = (f0_enq_one & if_accept_dual)
                       | (f0_enq_none & if_accept_single);
    wire fq_count_dec2 = f0_enq_none & if_accept_dual;
    wire fq_count_hold = ~(fq_count_inc2 | fq_count_inc1
                         | fq_count_dec1 | fq_count_dec2);

    wire [FQ_PTR_W:0] fq_count_next =
        ({(FQ_PTR_W+1){fq_count_inc2}} & fq_count_p2) |
        ({(FQ_PTR_W+1){fq_count_inc1}} & fq_count_p1) |
        ({(FQ_PTR_W+1){fq_count_hold}} & fq_count) |
        ({(FQ_PTR_W+1){fq_count_dec1}} & fq_count_m1) |
        ({(FQ_PTR_W+1){fq_count_dec2}} & fq_count_m2);

    wire ftq_alloc_ready = (ftq_count < FTQ_DEPTH_COUNT);
    wire fq_credit_for_bp0 = f0_valid_r ? (fq_count <= FQ_DEPTH_MINUS_4)
                                        : (fq_count <= FQ_DEPTH_MINUS_2);
    assign bp0_fire = ftq_alloc_ready && fq_credit_for_bp0 && !redirect_valid;
    assign abtb_lookup_accept = bp0_fire;

    // Existing perf monitor expects these names to exist; the new queue removes
    // the old hold/skip machinery.
    assign irom_held_valid = 1'b0;
    assign if_skip_out = 1'b0;

    // ================================================================
    //  Sequential state
    // ================================================================
    integer fq_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_pc <= RESET_PC;
            frontend_epoch <= 2'd0;
        end else if (redirect_valid) begin
            current_pc <= redirect_target;
            frontend_epoch <= frontend_epoch + 2'd1;
        end else if (bp0_fire) begin
            current_pc <= stage1_steer_next_pc;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f0_valid_r <= 1'b0;
            f0_epoch_r <= 2'd0;
            f0_start_pc_r <= 32'd0;
            f0_base_mask_r <= 2'd0;
            f0_steer_taken_r <= 1'b0;
            f0_steer_source_abtb_r <= 1'b0;
            f0_steer_bank_r <= 1'b0;
            f0_steer_cfi_type_r <= 2'd0;
            f0_steer_target_r <= 32'd0;
            f0_steer_next_pc_r <= 32'd0;
            f0_stage1_bank0_branch_owned_r <= 1'b0;
            f0_stage1_bank1_branch_owned_r <= 1'b0;
            f0_stage1_bank0_pht_index_r <= 8'd0;
            f0_stage1_bank0_pht_counter_r <= 2'b01;
            f0_stage1_bank1_pht_index_r <= 8'd0;
            f0_stage1_bank1_pht_counter_r <= 2'b01;
            f0_abtb_bank0_hit_r <= 1'b0;
            f0_abtb_bank0_way_r <= 1'b0;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
            f0_abtb_bank0_cfi_type_r <= 2'd0;
            f0_abtb_bank0_target_r <= 32'd0;
            f0_abtb_bank0_pred_taken_r <= 1'b0;
            f0_abtb_bank0_pred_target_r <= 32'd0;
`endif
            f0_abtb_bank1_hit_r <= 1'b0;
            f0_abtb_bank1_way_r <= 1'b0;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
            f0_abtb_bank1_cfi_type_r <= 2'd0;
            f0_abtb_bank1_target_r <= 32'd0;
            f0_abtb_bank1_pred_taken_r <= 1'b0;
            f0_abtb_bank1_pred_target_r <= 32'd0;
`endif
        end else if (redirect_valid) begin
            f0_valid_r <= 1'b0;
        end else begin
            f0_valid_r <= bp0_fire;
            if (bp0_fire) begin
                f0_epoch_r <= frontend_epoch;
                f0_start_pc_r <= current_pc;
                f0_base_mask_r <= bp0_base_mask;
                f0_steer_taken_r <= stage1_steer_taken;
                f0_steer_source_abtb_r <= stage1_steer_source_abtb;
                f0_steer_bank_r <= stage1_steer_bank;
                f0_steer_cfi_type_r <= stage1_steer_cfi_type;
                f0_steer_target_r <= stage1_steer_target;
                f0_steer_next_pc_r <= stage1_steer_next_pc;
                f0_stage1_bank0_branch_owned_r <=
                    abtb_bank0_branch_owned;
                f0_stage1_bank1_branch_owned_r <=
                    abtb_bank1_branch_owned;
                f0_stage1_bank0_pht_index_r <= stage1_bank0_pht_index;
                f0_stage1_bank0_pht_counter_r <= stage1_bank0_pht_counter;
                f0_stage1_bank1_pht_index_r <= stage1_bank1_pht_index;
                f0_stage1_bank1_pht_counter_r <= stage1_bank1_pht_counter;
                f0_abtb_bank0_hit_r <= abtb_bank0_hit;
                f0_abtb_bank0_way_r <= abtb_bank0_way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
                f0_abtb_bank0_cfi_type_r <= abtb_bank0_cfi_type;
                f0_abtb_bank0_target_r <= abtb_bank0_target;
                f0_abtb_bank0_pred_taken_r <= abtb_bank0_pred_taken;
                f0_abtb_bank0_pred_target_r <= abtb_bank0_pred_target;
`endif
                f0_abtb_bank1_hit_r <= abtb_bank1_hit;
                f0_abtb_bank1_way_r <= abtb_bank1_way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
                f0_abtb_bank1_cfi_type_r <= abtb_bank1_cfi_type;
                f0_abtb_bank1_target_r <= abtb_bank1_target;
                f0_abtb_bank1_pred_taken_r <= abtb_bank1_pred_taken;
                f0_abtb_bank1_pred_target_r <= abtb_bank1_pred_target;
`endif
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ftq_count <= '0;
        end else if (ex_redirect_valid) begin
            ftq_count <= '0;
        end else begin
            case ({bp0_fire, f0_valid_r})
                2'b10: ftq_count <= ftq_count + {{FTQ_PTR_W{1'b0}}, 1'b1};
                2'b01: ftq_count <= ftq_count - {{FTQ_PTR_W{1'b0}}, 1'b1};
                default: ftq_count <= ftq_count;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fq_head <= '0;
            fq_tail <= '0;
            fq_count <= '0;
            fq_tail_next_pc <= 32'd0;
            for (fq_i = 0; fq_i < FQ_DEPTH; fq_i = fq_i + 1) begin
                fq_mem[fq_i] <= '0;
                fq_pair_meta[fq_i] <= '0;
                fq_pair_ok[fq_i] <= 1'b0;
            end
        end else if (ex_redirect_valid) begin
            fq_head <= '0;
            fq_tail <= '0;
            fq_count <= '0;
            fq_tail_next_pc <= 32'd0;
            for (fq_i = 0; fq_i < FQ_DEPTH; fq_i = fq_i + 1)
                fq_pair_ok[fq_i] <= 1'b0;
        end else begin
            // pair_ok payload may be written speculatively; fq_count and later
            // cross-packet overwrite prevent an invalid follower from being used.
            if (f0_enq0_payload && fq_tail_has_prev)
                fq_pair_ok[fq_tail_m1] <= fq_prev_tail_pair_ok;
            if (f0_enq0_payload) begin
                fq_mem[fq_tail] <= f0_entry0;
                fq_pair_meta[fq_tail] <= f0_pair_meta0;
                fq_pair_ok[fq_tail] <= f0_entry0_pair_ok;
            end
            if (f0_enq1_payload) begin
                fq_mem[fq_tail_p1] <= f0_entry1;
                fq_pair_meta[fq_tail_p1] <= f0_pair_meta1;
                fq_pair_ok[fq_tail_p1] <= 1'b0;
            end

            fq_head <= fq_head_next;
            fq_tail <= fq_tail_next;
            fq_count <= fq_count_next;
            fq_tail_next_pc <= fq_tail_next_pc_next;
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && !ex_redirect_valid) begin
            if (fq_abtb_even_write) begin
                fq_abtb_even_hit[fq_abtb_even_write_row]
                    <= fq_abtb_even_write_data.hit;
                fq_abtb_even_way[fq_abtb_even_write_row]
                    <= fq_abtb_even_write_data.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
                fq_abtb_even_dbg[fq_abtb_even_write_row]
                    <= fq_abtb_even_write_data;
`endif
            end
            if (fq_abtb_odd_write) begin
                fq_abtb_odd_hit[fq_abtb_odd_write_row]
                    <= fq_abtb_odd_write_data.hit;
                fq_abtb_odd_way[fq_abtb_odd_write_row]
                    <= fq_abtb_odd_write_data.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
                fq_abtb_odd_dbg[fq_abtb_odd_write_row]
                    <= fq_abtb_odd_write_data;
`endif
            end
        end
    end

endmodule

`ifdef FRONTEND_FTQ_ABTB_WIDE_META
`undef FRONTEND_FTQ_ABTB_WIDE_META
`endif
