// ============================================================
// Module: frontend_ftq
// Description: BP0/F0/F1 frontend with packet queue, predecode, and ID verification.
//   BP0: current PC prediction, packet allocation, IROM request
//   F0 : 64-bit IROM response alignment, predecode, BP1 check, enqueue
//   F1 : fetch-queue head pair selection for the existing ID stage
// ============================================================

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

    // BP0 lookup and result.
    input  logic        bp_taken,
    input  logic [31:0] bp_target,
    input  logic [ 7:0] bp_ghr_snap,
    input  logic        bp_btb_hit,
    input  logic [ 1:0] bp_btb_type,
    input  logic [ 1:0] bp_btb_bht,
    input  logic [ 1:0] bp_pht_cnt,
    input  logic [ 1:0] bp_sel_cnt,
    input  logic        bp_s1_taken,
    input  logic [31:0] bp_s1_target,
    input  logic [ 7:0] bp_s1_ghr_snap,
    input  logic        bp_s1_btb_hit,
    input  logic [ 1:0] bp_s1_btb_type,
    input  logic [ 1:0] bp_s1_btb_bht,
    input  logic [ 1:0] bp_s1_pht_cnt,
    input  logic [ 1:0] bp_s1_sel_cnt,

    // F1 output to IF/ID.
    output logic        if_valid,
    output logic        if_ready_go,
    output logic [31:0] if_pc,
    output logic [31:0] if_inst0,
    output logic [31:0] if_inst1,
    output logic        if_s1_valid,
    output logic        if_bp_taken,
    output logic [31:0] if_bp_target,
    output logic [ 7:0] if_bp_ghr_snap,
    output logic        if_bp_btb_hit,
    output logic [ 1:0] if_bp_btb_type,
    output logic [ 1:0] if_bp_btb_bht,
    output logic [ 1:0] if_bp_pht_cnt,
    output logic [ 1:0] if_bp_sel_cnt,
    output logic        if_bp_verified,
    output logic        if_s1_bp_taken,
    output logic [31:0] if_s1_bp_target,
    output logic [ 7:0] if_s1_bp_ghr_snap,
    output logic        if_s1_bp_btb_hit,
    output logic [ 1:0] if_s1_bp_btb_type,
    output logic [ 1:0] if_s1_bp_btb_bht,
    output logic [ 1:0] if_s1_bp_pht_cnt,
    output logic [ 1:0] if_s1_bp_sel_cnt,

    // Compatibility/debug signals used by existing performance monitors.
    output logic [31:0] current_pc,
    output logic        can_dual_issue,
    output logic        raw_pair_raw,
    output logic        predict_dual,
    output logic        irom_held_valid,
    output logic        if_skip_out
);

    localparam logic [31:0] RESET_PC = 32'h8000_0000;
    localparam logic [6:0]  OP_FENCE = 7'b0001111;
    localparam logic [1:0]  BTB_TYPE_BRANCH = 2'b10;
    localparam logic [FTQ_PTR_W:0] FTQ_DEPTH_COUNT = (FTQ_PTR_W+1)'(FTQ_DEPTH);
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_2 = (FQ_PTR_W+1)'(FQ_DEPTH - 2);
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_4 = (FQ_PTR_W+1)'(FQ_DEPTH - 4);

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] inst;

        logic        pred_taken;
        logic [31:0] pred_target;
        logic        lookup_taken;
        logic [31:0] lookup_target;
        logic [ 7:0] bp_ghr_snap;
        logic        bp_btb_hit;
        logic [ 1:0] bp_btb_type;
        logic [ 1:0] bp_btb_bht;
        logic [ 1:0] bp_pht_cnt;
        logic [ 1:0] bp_sel_cnt;
        logic        bp_verified;

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

    function automatic logic fq_raw_dep(input fq_entry_t head0, input fq_entry_t head1);
        logic [4:0] head0_rd;
        logic [4:0] head1_rs1;
        logic [4:0] head1_rs2;
        begin
            head0_rd = head0.inst[11:7];
            head1_rs1 = head1.inst[19:15];
            head1_rs2 = head1.inst[24:20];
            fq_raw_dep = head0.writes_rd && (head0_rd != 5'd0)
                       && ((head1.uses_rs1 && (head1_rs1 == head0_rd))
                        || (head1.uses_rs2 && (head1_rs2 == head0_rd)));
        end
    endfunction

    function automatic logic fq_pair_supported(input fq_entry_t head0, input fq_entry_t head1);
        begin
            fq_pair_supported = (head1.is_alu_type && !head0.is_jump)
                              || (head1.is_load && head0.is_alu_type)
                              || (head1.is_store && head0.is_alu_type)
                              || (head1.is_jal && head0.is_alu_type)
                              || (head1.is_branch && !head0.is_control && !head0.is_lsu);
        end
    endfunction

    function automatic logic fq_pair_payload_ok(
        input logic      contiguous,
        input fq_entry_t head0,
        input fq_entry_t head1
    );
        begin
            fq_pair_payload_ok = contiguous
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

    // ================================================================
    //  BP0 / F0 metadata
    // ================================================================
    logic [1:0] frontend_epoch;

    logic       f0_valid_r;
    logic [1:0] f0_epoch_r;
    logic [31:0] f0_start_pc_r;
    logic [1:0]  f0_base_mask_r;
    logic        f0_bp0_taken_r;
    logic [31:0] f0_bp0_target_r;
    logic [ 7:0] f0_bp_ghr_snap_r;
    logic        f0_bp_btb_hit_r;
    logic [ 1:0] f0_bp_btb_type_r;
    logic [ 1:0] f0_bp_btb_bht_r;
    logic [ 1:0] f0_bp_pht_cnt_r;
    logic [ 1:0] f0_bp_sel_cnt_r;
    logic        f0_s1_bp_taken_r;
    logic [31:0] f0_s1_bp_target_r;
    logic [ 7:0] f0_s1_bp_ghr_snap_r;
    logic        f0_s1_bp_btb_hit_r;
    logic [ 1:0] f0_s1_bp_btb_type_r;
    logic [ 1:0] f0_s1_bp_btb_bht_r;
    logic [ 1:0] f0_s1_bp_pht_cnt_r;
    logic [ 1:0] f0_s1_bp_sel_cnt_r;
    // Outstanding fetch-packet count used for allocation throttling and perf taps.
    logic [FTQ_PTR_W:0]   ftq_count;

    wire [31:0] bp0_seq_next_pc = current_pc + (current_pc[2] ? 32'd4 : 32'd8);
    wire [31:0] bp0_next_pc = bp_taken ? bp_target : bp0_seq_next_pc;
    wire [1:0]  bp0_base_mask = current_pc[2] ? 2'b01 : 2'b11;

    assign irom_addr = {1'b0, current_pc[13:3]};

    // ================================================================
    //  F0 alignment, BP1, and enqueue preparation
    // ================================================================
    wire f0_epoch_match = (f0_epoch_r == frontend_epoch);
    wire f0_accept_base = f0_valid_r && f0_epoch_match && !ex_redirect_valid;

    wire [31:0] f0_slot0_inst = f0_start_pc_r[2] ? irom_data[63:32]
                                                  : irom_data[31:0];
    wire [31:0] f0_slot1_inst = f0_start_pc_r[2] ? 32'h0000_0013
                                                  : irom_data[63:32];
    wire [31:0] f0_slot0_pc = f0_start_pc_r;
    wire [31:0] f0_slot1_pc = f0_start_pc_r + 32'd4;

    wire f0_slot0_branch = inst_is_branch(f0_slot0_inst);
    wire f0_slot0_jal    = inst_is_jal(f0_slot0_inst);
    wire f0_slot0_jalr   = inst_is_jalr(f0_slot0_inst);
    wire f0_slot0_system = inst_is_system(f0_slot0_inst);
    wire f0_slot0_fence  = inst_is_fence(f0_slot0_inst);
    wire f0_slot0_illegal = inst_is_illegal(f0_slot0_inst);
    wire f0_slot0_muldiv = inst_is_muldiv(f0_slot0_inst);
    wire f0_slot0_load = inst_is_load(f0_slot0_inst);
    wire f0_slot0_store = inst_is_store(f0_slot0_inst);
    wire f0_slot0_alu_type = inst_is_alu_type(f0_slot0_inst);
    wire f0_slot0_writes_rd = inst_writes_rd(f0_slot0_inst);
    wire f0_slot0_uses_rs1 = inst_uses_rs1(f0_slot0_inst);
    wire f0_slot0_uses_rs2 = inst_uses_rs2(f0_slot0_inst);
    wire f0_slot0_jump = f0_slot0_jal || f0_slot0_jalr || f0_slot0_system;
    wire f0_slot0_control = f0_slot0_branch || f0_slot0_jal
                           || f0_slot0_jalr || f0_slot0_system;
    wire f0_slot0_lsu = f0_slot0_load || f0_slot0_store;
    wire f0_slot0_force_single = f0_slot0_jalr
                                || f0_slot0_system
                                || f0_slot0_fence
                                || f0_slot0_illegal
                                || f0_slot0_muldiv;
    wire f0_slot0_system_redirect = f0_slot0_system && (f0_slot0_inst[14:12] == 3'b000);

    wire f0_slot1_branch = inst_is_branch(f0_slot1_inst);
    wire f0_slot1_jal    = inst_is_jal(f0_slot1_inst);
    wire f0_slot1_jalr   = inst_is_jalr(f0_slot1_inst);
    wire f0_slot1_system = inst_is_system(f0_slot1_inst);
    wire f0_slot1_fence  = inst_is_fence(f0_slot1_inst);
    wire f0_slot1_illegal = inst_is_illegal(f0_slot1_inst);
    wire f0_slot1_muldiv = inst_is_muldiv(f0_slot1_inst);
    wire f0_slot1_load = inst_is_load(f0_slot1_inst);
    wire f0_slot1_store = inst_is_store(f0_slot1_inst);
    wire f0_slot1_alu_type = inst_is_alu_type(f0_slot1_inst);
    wire f0_slot1_writes_rd = inst_writes_rd(f0_slot1_inst);
    wire f0_slot1_uses_rs1 = inst_uses_rs1(f0_slot1_inst);
    wire f0_slot1_uses_rs2 = inst_uses_rs2(f0_slot1_inst);
    wire f0_slot1_jump = f0_slot1_jal || f0_slot1_jalr || f0_slot1_system;
    wire f0_slot1_control = f0_slot1_branch || f0_slot1_jal
                           || f0_slot1_jalr || f0_slot1_system;
    wire f0_slot1_lsu = f0_slot1_load || f0_slot1_store;
    wire f0_slot1_force_single = f0_slot1_jalr
                                || f0_slot1_system
                                || f0_slot1_fence
                                || f0_slot1_illegal
                                || f0_slot1_muldiv;

    wire bp1_applicable = f0_accept_base
                        && f0_bp_btb_hit_r
                        && (f0_bp_btb_type_r == BTB_TYPE_BRANCH);
    wire bp1_bimodal_taken = f0_bp_btb_bht_r[1];
    wire bp1_gshare_taken  = (f0_bp_pht_cnt_r >= 2'd2);
    wire bp1_use_bimodal   = (f0_bp_sel_cnt_r >= 2'd2);
    wire bp1_tournament_taken = bp1_use_bimodal ? bp1_bimodal_taken
                                                : bp1_gshare_taken;
    wire bp1_override = bp1_applicable
                      && (bp1_bimodal_taken != bp1_tournament_taken);
    wire bp1_final_taken = bp1_override ? bp1_tournament_taken
                                        : f0_bp0_taken_r;
    wire [31:0] bp1_final_target = bp1_override
                                 ? (bp1_tournament_taken ? f0_bp0_target_r
                                                         : (f0_start_pc_r + 32'd4))
                                 : f0_bp0_target_r;
    wire [31:0] bp1_not_taken_next_pc = f0_start_pc_r + (f0_base_mask_r[1] ? 32'd8 : 32'd4);
    wire bp1_redirect_valid = bp1_override;
    wire [31:0] bp1_redirect_target = bp1_final_taken ? bp1_final_target
                                                       : bp1_not_taken_next_pc;

    wire redirect_valid = ex_redirect_valid || bp1_redirect_valid;
    wire [31:0] redirect_target = ex_redirect_valid ? ex_redirect_target
                                                    : bp1_redirect_target;

    wire f0_kill_after_slot0 = f0_slot0_jal
                             || f0_slot0_jalr
                             || f0_slot0_system_redirect
                             || bp1_final_taken;
    wire f0_enq0_payload = f0_accept_base && f0_base_mask_r[0];
    wire f0_enq1_payload = f0_accept_base && f0_base_mask_r[1];
    wire f0_enq0_valid = f0_enq0_payload;
    wire f0_enq1_valid = f0_enq1_payload && !f0_kill_after_slot0;
    wire f0_enq_two  = f0_enq1_valid;
    wire f0_enq_one  = f0_enq0_valid && !f0_enq1_valid;
    wire f0_enq_none = !f0_enq0_valid;

    fq_entry_t f0_entry0;
    fq_entry_t f0_entry1;

    always @* begin
        f0_entry0 = '0;
        f0_entry0.valid = f0_enq0_valid;
        f0_entry0.pc = f0_slot0_pc;
        f0_entry0.inst = f0_slot0_inst;
        f0_entry0.pred_taken = bp1_final_taken;
        f0_entry0.pred_target = bp1_final_target;
        f0_entry0.lookup_taken = bp1_final_taken;
        f0_entry0.lookup_target = bp1_final_target;
        f0_entry0.bp_ghr_snap = f0_bp_ghr_snap_r;
        f0_entry0.bp_btb_hit = f0_bp_btb_hit_r;
        f0_entry0.bp_btb_type = f0_bp_btb_type_r;
        f0_entry0.bp_btb_bht = f0_bp_btb_bht_r;
        f0_entry0.bp_pht_cnt = f0_bp_pht_cnt_r;
        f0_entry0.bp_sel_cnt = f0_bp_sel_cnt_r;
        f0_entry0.bp_verified = bp1_applicable;
        f0_entry0.is_branch = f0_slot0_branch;
        f0_entry0.is_jal = f0_slot0_jal;
        f0_entry0.is_jalr = f0_slot0_jalr;
        f0_entry0.is_system = f0_slot0_system;
        f0_entry0.is_fence = f0_slot0_fence;
        f0_entry0.is_illegal = f0_slot0_illegal;
        f0_entry0.is_muldiv = f0_slot0_muldiv;
        f0_entry0.is_load = f0_slot0_load;
        f0_entry0.is_store = f0_slot0_store;
        f0_entry0.is_alu_type = f0_slot0_alu_type;
        f0_entry0.writes_rd = f0_slot0_writes_rd;
        f0_entry0.uses_rs1 = f0_slot0_uses_rs1;
        f0_entry0.uses_rs2 = f0_slot0_uses_rs2;
        f0_entry0.is_jump = f0_slot0_jump;
        f0_entry0.is_control = f0_slot0_control;
        f0_entry0.is_lsu = f0_slot0_lsu;
        f0_entry0.force_single = f0_slot0_force_single;

        f0_entry1 = '0;
        f0_entry1.valid = f0_enq1_valid;
        f0_entry1.pc = f0_slot1_pc;
        f0_entry1.inst = f0_slot1_inst;
        // Slot1 lookup is not used to steer fetch.  Keep branch-unit visible
        // prediction false if this instruction later issues as slot0.
        f0_entry1.pred_taken = 1'b0;
        f0_entry1.pred_target = 32'd0;
        f0_entry1.lookup_taken = f0_s1_bp_taken_r;
        f0_entry1.lookup_target = f0_s1_bp_target_r;
        f0_entry1.bp_ghr_snap = f0_s1_bp_ghr_snap_r;
        f0_entry1.bp_btb_hit = f0_s1_bp_btb_hit_r;
        f0_entry1.bp_btb_type = f0_s1_bp_btb_type_r;
        f0_entry1.bp_btb_bht = f0_s1_bp_btb_bht_r;
        f0_entry1.bp_pht_cnt = f0_s1_bp_pht_cnt_r;
        f0_entry1.bp_sel_cnt = f0_s1_bp_sel_cnt_r;
        // Slot1 metadata is carried for training only, so suppress ID correction.
        f0_entry1.bp_verified = 1'b1;
        f0_entry1.is_branch = f0_slot1_branch;
        f0_entry1.is_jal = f0_slot1_jal;
        f0_entry1.is_jalr = f0_slot1_jalr;
        f0_entry1.is_system = f0_slot1_system;
        f0_entry1.is_fence = f0_slot1_fence;
        f0_entry1.is_illegal = f0_slot1_illegal;
        f0_entry1.is_muldiv = f0_slot1_muldiv;
        f0_entry1.is_load = f0_slot1_load;
        f0_entry1.is_store = f0_slot1_store;
        f0_entry1.is_alu_type = f0_slot1_alu_type;
        f0_entry1.writes_rd = f0_slot1_writes_rd;
        f0_entry1.uses_rs1 = f0_slot1_uses_rs1;
        f0_entry1.uses_rs2 = f0_slot1_uses_rs2;
        f0_entry1.is_jump = f0_slot1_jump;
        f0_entry1.is_control = f0_slot1_control;
        f0_entry1.is_lsu = f0_slot1_lsu;
        f0_entry1.force_single = f0_slot1_force_single;
    end

    // ================================================================
    //  Instruction-granular fetch queue
    // ================================================================
    fq_entry_t fq_mem [0:FQ_DEPTH-1];
    logic      fq_pair_ok [0:FQ_DEPTH-1];
    logic [FQ_PTR_W-1:0] fq_head;
    logic [FQ_PTR_W-1:0] fq_tail;
    logic [FQ_PTR_W:0]   fq_count;

    wire [FQ_PTR_W-1:0] fq_head_p1 = fq_head + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    wire [FQ_PTR_W-1:0] fq_head_p2 = fq_head + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] fq_tail_p1 = fq_tail + {{(FQ_PTR_W-1){1'b0}}, 1'b1};
    wire [FQ_PTR_W-1:0] fq_tail_p2 = fq_tail + {{(FQ_PTR_W-2){1'b0}}, 2'd2};
    wire [FQ_PTR_W-1:0] fq_tail_m1 = fq_tail - {{(FQ_PTR_W-1){1'b0}}, 1'b1};

    fq_entry_t fq_head0;
    fq_entry_t fq_head1;
    fq_entry_t fq_tail_prev;

    assign fq_head0 = fq_mem[fq_head];
    assign fq_head1 = fq_mem[fq_head_p1];
    assign fq_tail_prev = fq_mem[fq_tail_m1];

    wire fq_has_slot0 = (fq_count != 0);
    wire fq_has_slot1 = (fq_count >= 2);
    wire fq_tail_has_prev = (fq_count != 0);
    wire fq_prev_tail_next_contiguous =
        fq_tail_has_prev && (fq_tail_prev.pc + 32'd4 == f0_slot0_pc);

    wire fq_prev_tail_pair_ok =
        f0_entry0.valid
        && fq_pair_payload_ok(fq_prev_tail_next_contiguous, fq_tail_prev, f0_entry0);
    wire f0_entry0_pair_ok =
        f0_entry1.valid
        && fq_pair_payload_ok(1'b1, f0_entry0, f0_entry1);

    assign raw_pair_raw = fq_raw_dep(fq_head0, fq_head1);

    wire pair_policy_ok = fq_has_slot1 && fq_pair_ok[fq_head];

    assign can_dual_issue = pair_policy_ok;
    assign predict_dual = pair_policy_ok;
    assign if_s1_valid = pair_policy_ok;
    assign if_valid = fq_has_slot0 && fq_head0.valid;
    assign if_ready_go = 1'b1;

    assign if_pc    = fq_head0.pc;
    assign if_inst0 = fq_head0.inst;
    assign if_inst1 = fq_head1.inst;
    assign if_bp_taken    = fq_head0.pred_taken;
    assign if_bp_target   = fq_head0.pred_target;
    assign if_bp_ghr_snap = fq_head0.bp_ghr_snap;
    assign if_bp_btb_hit  = fq_head0.bp_btb_hit;
    assign if_bp_btb_type = fq_head0.bp_btb_type;
    assign if_bp_btb_bht  = fq_head0.bp_btb_bht;
    assign if_bp_pht_cnt  = fq_head0.bp_pht_cnt;
    assign if_bp_sel_cnt  = fq_head0.bp_sel_cnt;
    assign if_bp_verified = fq_head0.bp_verified;
    assign if_s1_bp_taken    = fq_head1.lookup_taken;
    assign if_s1_bp_target   = fq_head1.lookup_target;
    assign if_s1_bp_ghr_snap = fq_head1.bp_ghr_snap;
    assign if_s1_bp_btb_hit  = fq_head1.bp_btb_hit;
    assign if_s1_bp_btb_type = fq_head1.bp_btb_type;
    assign if_s1_bp_btb_bht  = fq_head1.bp_btb_bht;
    assign if_s1_bp_pht_cnt  = fq_head1.bp_pht_cnt;
    assign if_s1_bp_sel_cnt  = fq_head1.bp_sel_cnt;

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
    wire bp0_fire = ftq_alloc_ready && fq_credit_for_bp0 && !redirect_valid;

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
            current_pc <= bp0_next_pc;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f0_valid_r <= 1'b0;
            f0_epoch_r <= 2'd0;
            f0_start_pc_r <= 32'd0;
            f0_base_mask_r <= 2'd0;
            f0_bp0_taken_r <= 1'b0;
            f0_bp0_target_r <= 32'd0;
            f0_bp_ghr_snap_r <= 8'd0;
            f0_bp_btb_hit_r <= 1'b0;
            f0_bp_btb_type_r <= 2'd0;
            f0_bp_btb_bht_r <= 2'd0;
            f0_bp_pht_cnt_r <= 2'd0;
            f0_bp_sel_cnt_r <= 2'd0;
            f0_s1_bp_taken_r <= 1'b0;
            f0_s1_bp_target_r <= 32'd0;
            f0_s1_bp_ghr_snap_r <= 8'd0;
            f0_s1_bp_btb_hit_r <= 1'b0;
            f0_s1_bp_btb_type_r <= 2'd0;
            f0_s1_bp_btb_bht_r <= 2'd0;
            f0_s1_bp_pht_cnt_r <= 2'd0;
            f0_s1_bp_sel_cnt_r <= 2'd0;
        end else if (redirect_valid) begin
            f0_valid_r <= 1'b0;
        end else begin
            f0_valid_r <= bp0_fire;
            if (bp0_fire) begin
                f0_epoch_r <= frontend_epoch;
                f0_start_pc_r <= current_pc;
                f0_base_mask_r <= bp0_base_mask;
                f0_bp0_taken_r <= bp_taken;
                f0_bp0_target_r <= bp_target;
                f0_bp_ghr_snap_r <= bp_ghr_snap;
                f0_bp_btb_hit_r <= bp_btb_hit;
                f0_bp_btb_type_r <= bp_btb_type;
                f0_bp_btb_bht_r <= bp_btb_bht;
                f0_bp_pht_cnt_r <= bp_pht_cnt;
                f0_bp_sel_cnt_r <= bp_sel_cnt;
                f0_s1_bp_taken_r <= bp_s1_taken;
                f0_s1_bp_target_r <= bp_s1_target;
                f0_s1_bp_ghr_snap_r <= bp_s1_ghr_snap;
                f0_s1_bp_btb_hit_r <= bp_s1_btb_hit;
                f0_s1_bp_btb_type_r <= bp_s1_btb_type;
                f0_s1_bp_btb_bht_r <= bp_s1_btb_bht;
                f0_s1_bp_pht_cnt_r <= bp_s1_pht_cnt;
                f0_s1_bp_sel_cnt_r <= bp_s1_sel_cnt;
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
            for (fq_i = 0; fq_i < FQ_DEPTH; fq_i = fq_i + 1) begin
                fq_mem[fq_i] <= '0;
                fq_pair_ok[fq_i] <= 1'b0;
            end
        end else if (ex_redirect_valid) begin
            fq_head <= '0;
            fq_tail <= '0;
            fq_count <= '0;
            for (fq_i = 0; fq_i < FQ_DEPTH; fq_i = fq_i + 1)
                fq_pair_ok[fq_i] <= 1'b0;
        end else begin
            // pair_ok payload may be written speculatively; fq_count and later
            // cross-packet overwrite prevent an invalid follower from being used.
            if (f0_enq0_payload && fq_tail_has_prev)
                fq_pair_ok[fq_tail_m1] <= fq_prev_tail_pair_ok;
            if (f0_enq0_payload) begin
                fq_mem[fq_tail] <= f0_entry0;
                fq_pair_ok[fq_tail] <= f0_entry0_pair_ok;
            end
            if (f0_enq1_payload) begin
                fq_mem[fq_tail_p1] <= f0_entry1;
                fq_pair_ok[fq_tail_p1] <= 1'b0;
            end

            fq_head <= fq_head_next;
            fq_tail <= fq_tail_next;
            fq_count <= fq_count_next;
        end
    end

endmodule
