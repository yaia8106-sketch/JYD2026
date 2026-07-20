// ============================================================
// Module: frontend_ftq
// Description: BP0/F0/F1 frontend with packet queue and predecode.
// Domain: frontend.
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
    parameter int FQ_DEPTH  = 8,
    parameter int FQ_PTR_W  = $clog2(FQ_DEPTH)
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
    input  logic [31:0] abtb_bank0_abtb_pred_target,
    input  logic        abtb_bank0_pred_taken,
    input  logic [31:0] abtb_bank0_final_pred_target,
    input  logic        abtb_bank1_lookup_hit,
    input  logic        abtb_bank1_hit,
    input  logic        abtb_bank1_way,
    input  logic [ 1:0] abtb_bank1_cfi_type,
    input  logic [31:0] abtb_bank1_abtb_pred_target,
    input  logic        abtb_bank1_pred_taken,
    input  logic [31:0] abtb_bank1_final_pred_target,

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
    output logic        if_s1_valid,
    output if_id_payload_t if_payload,

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
    localparam logic [FTQ_PTR_W:0] FTQ_DEPTH_COUNT = (FTQ_PTR_W+1)'(FTQ_DEPTH); // FTQ_DEPTH_COUNT = FTQ_DEPTH = 8
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_2 = (FQ_PTR_W+1)'(FQ_DEPTH - 2); // 8 - 2 = 6
    localparam logic [FQ_PTR_W:0]  FQ_DEPTH_MINUS_4 = (FQ_PTR_W+1)'(FQ_DEPTH - 4); // 8 - 4 = 4
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    localparam bit FQ_ABTB_WIDE_META = 1'b1;
`else
    localparam bit FQ_ABTB_WIDE_META = 1'b0;
`endif

    // ================================================================
    //  BP0 / F0 metadata
    // ================================================================
    // BP0 predicts and issues an IROM request. F0 captures the accepted
    // prediction context and later combines it with the synchronous IROM data.
    wire [31:0] fetch_current_pc;
    wire [ 1:0] frontend_epoch;
    wire frontend_f0_state_t f0_state;
    wire frontend_abtb_meta_t bp0_abtb_bank0_meta;
    wire frontend_abtb_meta_t bp0_abtb_bank1_meta;
    wire frontend_abtb_meta_t f0_abtb_bank0_meta;
    wire frontend_abtb_meta_t f0_abtb_bank1_meta;
    wire [FTQ_PTR_W:0] ftq_count;

    // Compatibility aliases for directed tests and performance monitors.
    wire f0_valid_r = f0_state.valid;
    wire [1:0] f0_epoch_r = f0_state.epoch;
    wire [31:0] f0_start_pc_r = f0_state.start_pc;
    wire [1:0] f0_base_mask_r = f0_state.base_mask;
    wire f0_steer_taken_r = f0_state.steer.taken;
    wire f0_steer_source_abtb_r = f0_state.steer.source_abtb;
    wire f0_steer_bank_r = f0_state.steer.bank;
    wire [1:0] f0_steer_cfi_type_r = f0_state.steer.cfi_type;
    wire [31:0] f0_steer_target_r = f0_state.steer.target;
    wire [31:0] f0_steer_next_pc_r = f0_state.steer.next_pc;
    wire f0_stage1_bank0_branch_owned_r =
        f0_state.bank0_meta.branch_owned;
    wire f0_stage1_bank1_branch_owned_r =
        f0_state.bank1_meta.branch_owned;
    wire [7:0] f0_stage1_bank0_pht_index_r =
        f0_state.bank0_meta.pht_index;
    wire [1:0] f0_stage1_bank0_pht_counter_r =
        f0_state.bank0_meta.pht_counter;
    wire [7:0] f0_stage1_bank1_pht_index_r =
        f0_state.bank1_meta.pht_index;
    wire [1:0] f0_stage1_bank1_pht_counter_r =
        f0_state.bank1_meta.pht_counter;
    wire f0_abtb_bank0_hit_r = f0_abtb_bank0_meta.hit;
    wire f0_abtb_bank0_way_r = f0_abtb_bank0_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    wire [1:0] f0_abtb_bank0_cfi_type_r = f0_abtb_bank0_meta.cfi_type;
    wire [31:0] f0_abtb_bank0_target_r = f0_abtb_bank0_meta.target;
    wire f0_abtb_bank0_pred_taken_r = f0_abtb_bank0_meta.pred_taken;
    wire [31:0] f0_abtb_bank0_pred_target_r =
        f0_abtb_bank0_meta.pred_target;
`endif
    wire f0_abtb_bank1_hit_r = f0_abtb_bank1_meta.hit;
    wire f0_abtb_bank1_way_r = f0_abtb_bank1_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    wire [1:0] f0_abtb_bank1_cfi_type_r = f0_abtb_bank1_meta.cfi_type;
    wire [31:0] f0_abtb_bank1_target_r = f0_abtb_bank1_meta.target;
    wire f0_abtb_bank1_pred_taken_r = f0_abtb_bank1_meta.pred_taken;
    wire [31:0] f0_abtb_bank1_pred_target_r =
        f0_abtb_bank1_meta.pred_target;
`endif

    assign current_pc = fetch_current_pc;

    wire bp0_fire;
    wire [1:0]  bp0_base_mask = current_pc[2] ? 2'b01 : 2'b11;
    wire frontend_steer_bank_t bp0_steer_bank0;
    wire frontend_steer_bank_t bp0_steer_bank1;
    wire frontend_steer_result_t bp0_steer_result;
    wire abtb_bank0_branch_owned;
    wire abtb_bank1_branch_owned;
    wire frontend_f0_bank_meta_t bp0_f0_bank0_meta;
    wire frontend_f0_bank_meta_t bp0_f0_bank1_meta;

    // Convert ABTB/PHT outputs into the canonical steering input record.
    assign bp0_steer_bank0.lookup_hit = abtb_bank0_lookup_hit;
    assign bp0_steer_bank0.cfi_type = abtb_bank0_cfi_type;
    assign bp0_steer_bank0.target = abtb_bank0_abtb_pred_target;
    assign bp0_steer_bank0.pred_taken = abtb_bank0_pred_taken;
    assign bp0_steer_bank1.lookup_hit = abtb_bank1_lookup_hit;
    assign bp0_steer_bank1.cfi_type = abtb_bank1_cfi_type;
    assign bp0_steer_bank1.target = abtb_bank1_abtb_pred_target;
    assign bp0_steer_bank1.pred_taken = abtb_bank1_pred_taken;

    assign bp0_f0_bank0_meta.branch_owned = abtb_bank0_branch_owned;
    assign bp0_f0_bank0_meta.pht_index = stage1_bank0_pht_index;
    assign bp0_f0_bank0_meta.pht_counter = stage1_bank0_pht_counter;
    assign bp0_f0_bank1_meta.branch_owned = abtb_bank1_branch_owned;
    assign bp0_f0_bank1_meta.pht_index = stage1_bank1_pht_index;
    assign bp0_f0_bank1_meta.pht_counter = stage1_bank1_pht_counter;

    assign bp0_abtb_bank0_meta.hit = abtb_bank0_hit;
    assign bp0_abtb_bank0_meta.way = abtb_bank0_way;
    assign bp0_abtb_bank0_meta.cfi_type = abtb_bank0_cfi_type;
    assign bp0_abtb_bank0_meta.target = abtb_bank0_abtb_pred_target;
    assign bp0_abtb_bank0_meta.pred_taken = abtb_bank0_pred_taken;
    assign bp0_abtb_bank0_meta.pred_target = abtb_bank0_final_pred_target;
    assign bp0_abtb_bank1_meta.hit = abtb_bank1_hit;
    assign bp0_abtb_bank1_meta.way = abtb_bank1_way;
    assign bp0_abtb_bank1_meta.cfi_type = abtb_bank1_cfi_type;
    assign bp0_abtb_bank1_meta.target = abtb_bank1_abtb_pred_target;
    assign bp0_abtb_bank1_meta.pred_taken = abtb_bank1_pred_taken;
    assign bp0_abtb_bank1_meta.pred_target = abtb_bank1_final_pred_target;

    assign stage1_steer_valid = bp0_steer_result.valid;
    assign stage1_steer_source_abtb = bp0_steer_result.source_abtb;
    assign stage1_steer_branch_owned = bp0_steer_result.branch_owned;
    assign stage1_steer_branch_owned_nt = bp0_steer_result.branch_owned_nt;
    assign stage1_steer_taken = bp0_steer_result.taken;
    assign stage1_steer_bank = bp0_steer_result.bank;
    assign stage1_steer_cfi_type = bp0_steer_result.cfi_type;
    assign stage1_steer_target = bp0_steer_result.target;
    assign stage1_steer_next_pc = bp0_steer_result.next_pc;

    frontend_stage1_steer_ctrl u_frontend_stage1_steer_ctrl (
        .lookup_valid       (bp0_fire),
        .current_pc         (current_pc),
        .bank0              (bp0_steer_bank0),
        .bank1              (bp0_steer_bank1),
        .bank0_branch_owned (abtb_bank0_branch_owned),
        .bank1_branch_owned (abtb_bank1_branch_owned),
        .steer              (bp0_steer_result)
    );

    frontend_fetch_state #(
        .FTQ_PTR_W      (FTQ_PTR_W),
        .WIDE_ABTB_META (FQ_ABTB_WIDE_META),
        .RESET_PC       (RESET_PC)
    ) u_frontend_fetch_state (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .redirect_valid         (ex_redirect_valid),
        .redirect_target        (ex_redirect_target),
        .accept                 (bp0_fire),
        .accept_base_mask       (bp0_base_mask),
        .accept_steer           (bp0_steer_result),
        .accept_bank0_meta      (bp0_f0_bank0_meta),
        .accept_bank1_meta      (bp0_f0_bank1_meta),
        .accept_abtb_bank0_meta (bp0_abtb_bank0_meta),
        .accept_abtb_bank1_meta (bp0_abtb_bank1_meta),
        .current_pc             (fetch_current_pc),
        .frontend_epoch         (frontend_epoch),
        .f0_state               (f0_state),
        .f0_abtb_bank0_meta     (f0_abtb_bank0_meta),
        .f0_abtb_bank1_meta     (f0_abtb_bank1_meta),
        .outstanding_count      (ftq_count)
    );

    // IROM is addressed by aligned 64-bit fetch block.
    assign irom_addr = {1'b0, current_pc[13:3]};

    // ================================================================
    //  F0 alignment and enqueue preparation
    // ================================================================
    // Epoch matching drops stale IROM responses produced before a redirect.
    wire f0_epoch_match = (f0_epoch_r == frontend_epoch);
    wire f0_accept_base = f0_valid_r
                        && f0_epoch_match
                        && !ex_redirect_valid;

    wire redirect_valid = ex_redirect_valid;
    wire [31:0] redirect_target = ex_redirect_target;

    wire frontend_f0_bank_meta_t f0_builder_bank0_meta;
    wire frontend_f0_bank_meta_t f0_builder_bank1_meta;
    wire frontend_fq_entry_t f0_entry0;
    wire frontend_fq_entry_t f0_entry1;
    wire frontend_pair_meta_t f0_pair_meta0;
    wire frontend_pair_meta_t f0_pair_meta1;
    wire f0_enq0_payload;
    wire f0_enq1_payload;
    wire f0_enq0_valid;
    wire f0_enq1_valid;
    wire f0_kill_after_slot0;

    assign f0_builder_bank0_meta.branch_owned =
        f0_stage1_bank0_branch_owned_r;
    assign f0_builder_bank0_meta.pht_index =
        f0_stage1_bank0_pht_index_r;
    assign f0_builder_bank0_meta.pht_counter =
        f0_stage1_bank0_pht_counter_r;
    assign f0_builder_bank1_meta.branch_owned =
        f0_stage1_bank1_branch_owned_r;
    assign f0_builder_bank1_meta.pht_index =
        f0_stage1_bank1_pht_index_r;
    assign f0_builder_bank1_meta.pht_counter =
        f0_stage1_bank1_pht_counter_r;

    frontend_f0_packet_builder u_frontend_f0_packet_builder (
        .accept_base       (f0_accept_base),
        .start_pc          (f0_start_pc_r),
        .base_mask         (f0_base_mask_r),
        .irom_data         (irom_data),
        .steer_taken       (f0_steer_taken_r),
        .steer_source_abtb (f0_steer_source_abtb_r),
        .steer_bank        (f0_steer_bank_r),
        .steer_cfi_type    (f0_steer_cfi_type_r),
        .steer_target      (f0_steer_target_r),
        .bank0_meta        (f0_builder_bank0_meta),
        .bank1_meta        (f0_builder_bank1_meta),
        .enq0_payload      (f0_enq0_payload),
        .enq1_payload      (f0_enq1_payload),
        .enq0_valid        (f0_enq0_valid),
        .enq1_valid        (f0_enq1_valid),
        .kill_after_slot0  (f0_kill_after_slot0),
        .entry0            (f0_entry0),
        .entry1            (f0_entry1),
        .pair_meta0        (f0_pair_meta0),
        .pair_meta1        (f0_pair_meta1)
    );

    // Compatibility aliases for directed tests and performance monitors.
    wire [31:0] f0_slot0_inst = f0_entry0.inst;
    wire [31:0] f0_slot1_inst = f0_entry1.inst;
    wire [31:0] f0_slot0_pc = f0_entry0.pc;
    wire [31:0] f0_slot1_pc = f0_entry1.pc;
    wire f0_slot0_conditional_control = f0_entry0.is_conditional_branch;
    wire f0_slot0_direct_control = f0_entry0.is_direct_jump;
    wire f0_slot0_indirect_control = f0_entry0.is_indirect_jump;
    wire f0_slot0_force_single = f0_entry0.force_single;
    wire f0_slot1_force_single = f0_entry1.force_single;
    wire f0_slot0_system_redirect =
        f0_entry0.is_privileged_flow;
    wire f0_slot0_stage1_branch_owned =
        f0_entry0.stage1_branch_owned;
    wire f0_slot1_stage1_branch_owned =
        f0_entry1.stage1_branch_owned;
    wire f0_final_taken = f0_steer_taken_r;
    wire f0_final_source_abtb = f0_steer_source_abtb_r;
    wire f0_final_bank = f0_steer_bank_r;
    wire [ 1:0] f0_final_cfi_type = f0_steer_cfi_type_r;
    wire [31:0] f0_final_target = f0_steer_target_r;
    wire [31:0] f0_final_next_pc = f0_steer_next_pc_r;
    wire f0_slot0_pred_taken = f0_entry0.pred_taken;
    wire [31:0] f0_slot0_pred_target = f0_entry0.pred_target;
    wire f0_slot0_pred_source_abtb = f0_entry0.pred_source_abtb;
    wire f0_slot1_pred_taken = f0_entry1.pred_taken;
    wire [31:0] f0_slot1_pred_target = f0_entry1.pred_target;
    wire f0_slot1_pred_source_abtb = f0_entry1.pred_source_abtb;
    wire [ 7:0] f0_slot0_stage1_pht_index =
        f0_entry0.stage1_pht_index;
    wire [ 1:0] f0_slot0_stage1_pht_counter =
        f0_entry0.stage1_pht_counter;
    wire [ 7:0] f0_slot1_stage1_pht_index =
        f0_entry1.stage1_pht_index;
    wire [ 1:0] f0_slot1_stage1_pht_counter =
        f0_entry1.stage1_pht_counter;

    wire f0_enq_two  = f0_enq1_valid;
    wire f0_enq_one  = f0_enq0_valid && !f0_enq1_valid;
    wire f0_enq_none = !f0_enq0_valid;

    // ================================================================
    //  Instruction-granular fetch queue
    // ================================================================
    wire [FQ_PTR_W-1:0] fq_head;
    wire [FQ_PTR_W-1:0] fq_head_p1;
    wire [FQ_PTR_W-1:0] fq_tail;
    wire [FQ_PTR_W-1:0] fq_tail_p1;
    wire [FQ_PTR_W:0] fq_count;
    wire [31:0] fq_tail_next_pc;

    wire frontend_fq_entry_t fq_head0;
    wire frontend_fq_entry_t fq_head1;
    wire frontend_fq_entry_t fq_tail_prev;
    wire frontend_pair_meta_t fq_head0_pair_meta;
    wire frontend_pair_meta_t fq_head1_pair_meta;
    wire frontend_pair_meta_t fq_tail_prev_pair_meta;
    wire fq_head_pair_ok;
    wire frontend_abtb_meta_t f0_abtb_meta0;
    wire frontend_abtb_meta_t f0_abtb_meta1;
    wire frontend_abtb_meta_t fq_abtb_even_read;
    wire frontend_abtb_meta_t fq_abtb_odd_read;
    wire frontend_abtb_meta_t fq_head0_abtb_meta;
    wire frontend_abtb_meta_t fq_head1_abtb_meta;
    wire fq_abtb_slot1_write_valid;
    wire [FQ_PTR_W-1:0] fq_abtb_entry1_ptr;
    wire frontend_abtb_meta_t f0_abtb_meta1_write_data;
    wire fq_abtb_even_write_entry0;
    wire fq_abtb_even_write_entry1;
    wire fq_abtb_odd_write_entry0;
    wire fq_abtb_odd_write_entry1;
    wire fq_abtb_even_write;
    wire fq_abtb_odd_write;
    wire [FQ_PTR_W-2:0] fq_abtb_even_read_row;
    wire [FQ_PTR_W-2:0] fq_abtb_odd_read_row;
    wire [FQ_PTR_W-2:0] fq_abtb_even_write_row;
    wire [FQ_PTR_W-2:0] fq_abtb_odd_write_row;
    wire frontend_abtb_meta_t fq_abtb_even_write_data;
    wire frontend_abtb_meta_t fq_abtb_odd_write_data;

    frontend_abtb_sidecar #(
        .FQ_DEPTH  (FQ_DEPTH),
        .FQ_PTR_W  (FQ_PTR_W),
        .WIDE_META (FQ_ABTB_WIDE_META)
    ) u_frontend_abtb_sidecar (
        .clk                (clk),
        .rst_n              (rst_n),
        .redirect_valid     (ex_redirect_valid),
        .f0_start_pc        (f0_start_pc_r),
        .f0_bank0_meta      (f0_abtb_bank0_meta),
        .f0_bank1_meta      (f0_abtb_bank1_meta),
        .fq_head            (fq_head),
        .fq_head_p1         (fq_head_p1),
        .fq_tail            (fq_tail),
        .fq_tail_p1         (fq_tail_p1),
        .enq0_valid         (f0_enq0_valid),
        .enq1_payload       (f0_enq1_payload),
        .enq1_valid         (f0_enq1_valid),
        .f0_meta0           (f0_abtb_meta0),
        .f0_meta1           (f0_abtb_meta1),
        .even_read_data     (fq_abtb_even_read),
        .odd_read_data      (fq_abtb_odd_read),
        .head0_meta         (fq_head0_abtb_meta),
        .head1_meta         (fq_head1_abtb_meta),
        .slot1_write_valid  (fq_abtb_slot1_write_valid),
        .entry1_ptr         (fq_abtb_entry1_ptr),
        .meta1_write_data   (f0_abtb_meta1_write_data),
        .even_write_entry0  (fq_abtb_even_write_entry0),
        .even_write_entry1  (fq_abtb_even_write_entry1),
        .odd_write_entry0   (fq_abtb_odd_write_entry0),
        .odd_write_entry1   (fq_abtb_odd_write_entry1),
        .even_write         (fq_abtb_even_write),
        .odd_write          (fq_abtb_odd_write),
        .even_read_row      (fq_abtb_even_read_row),
        .odd_read_row       (fq_abtb_odd_read_row),
        .even_write_row     (fq_abtb_even_write_row),
        .odd_write_row      (fq_abtb_odd_write_row),
        .even_write_data    (fq_abtb_even_write_data),
        .odd_write_data     (fq_abtb_odd_write_data)
    );

    // F1 exposes the queue head to IF/ID. Pairing has already been precomputed
    // at enqueue time, so dequeue only checks availability and stored policy.
    wire fq_has_slot0 = (fq_count != 0);
    wire fq_has_slot1 = (fq_count >= 2);
    wire fq_tail_has_prev = (fq_count != 0);
    wire fq_prev_tail_next_contiguous =
        fq_tail_has_prev && (fq_tail_next_pc == f0_slot0_pc);

    wire fq_prev_tail_pair_ok;
    wire f0_entry0_pair_ok;
    wire fq_head_raw_dep;

    frontend_pair_policy u_pair_policy_cross_packet (
        .contiguous    (fq_prev_tail_next_contiguous),
        .slot0_valid   (fq_tail_has_prev),
        .slot1_valid   (f0_enq0_valid),
        .slot0_meta    (fq_tail_prev_pair_meta),
        .slot1_meta    (f0_pair_meta0),
        .raw_dep       (),
        .pair_supported(),
        .pair_ok       (fq_prev_tail_pair_ok)
    );

    frontend_pair_policy u_pair_policy_same_packet (
        .contiguous    (1'b1),
        .slot0_valid   (f0_enq0_valid),
        .slot1_valid   (f0_enq1_valid),
        .slot0_meta    (f0_pair_meta0),
        .slot1_meta    (f0_pair_meta1),
        .raw_dep       (),
        .pair_supported(),
        .pair_ok       (f0_entry0_pair_ok)
    );

    frontend_pair_policy u_pair_policy_head_probe (
        .contiguous    (1'b1),
        .slot0_valid   (fq_has_slot0),
        .slot1_valid   (fq_has_slot1),
        .slot0_meta    (fq_head0_pair_meta),
        .slot1_meta    (fq_head1_pair_meta),
        .raw_dep       (fq_head_raw_dep),
        .pair_supported(),
        .pair_ok       ()
    );

    assign raw_pair_raw = fq_head_raw_dep;

    wire pair_policy_ok = fq_has_slot1 && fq_head_pair_ok;

    assign can_dual_issue = pair_policy_ok;
    assign predict_dual = pair_policy_ok;
    assign if_s1_valid = pair_policy_ok;
    assign if_valid = fq_has_slot0 && fq_head0.valid;
    assign if_ready_go = 1'b1;

    assign if_payload.pc = fq_head0.pc;
    assign if_payload.slot0.inst = fq_head0.inst;
    assign if_payload.slot1.inst = fq_head1.inst;
    assign if_payload.slot0.prediction.taken = fq_head0.pred_taken;
    assign if_payload.slot0.prediction.target = fq_head0.pred_target;
    assign if_payload.slot0.prediction.source_abtb = fq_head0.pred_source_abtb;
    assign if_payload.slot0.prediction.stage1_branch_owned =
        fq_head0.stage1_branch_owned;
    assign if_payload.slot1.prediction.taken = fq_head1.pred_taken;
    assign if_payload.slot1.prediction.target = fq_head1.pred_target;
    assign if_payload.slot1.prediction.source_abtb = fq_head1.pred_source_abtb;
    assign if_payload.slot1.prediction.stage1_branch_owned =
        fq_head1.stage1_branch_owned;
    assign if_payload.slot0.prediction.stage1_pht_index =
        fq_head0.stage1_pht_index;
    assign if_payload.slot0.prediction.stage1_pht_counter =
        fq_head0.stage1_pht_counter;
    assign if_payload.slot1.prediction.stage1_pht_index =
        fq_head1.stage1_pht_index;
    assign if_payload.slot1.prediction.stage1_pht_counter =
        fq_head1.stage1_pht_counter;
    assign if_payload.slot0.prediction.abtb_hit = fq_head0_abtb_meta.hit;
    assign if_payload.slot0.prediction.abtb_way = fq_head0_abtb_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    assign if_payload.slot0.prediction.abtb_cfi_type =
        fq_head0_abtb_meta.cfi_type;
    assign if_payload.slot0.prediction.abtb_target = fq_head0_abtb_meta.target;
    assign if_payload.slot0.prediction.abtb_pred_taken =
        fq_head0_abtb_meta.pred_taken;
    assign if_payload.slot0.prediction.abtb_pred_target =
        fq_head0_abtb_meta.pred_target;
`else
    assign if_payload.slot0.prediction.abtb_cfi_type = 2'd0;
    assign if_payload.slot0.prediction.abtb_target = 32'd0;
    assign if_payload.slot0.prediction.abtb_pred_taken = 1'b0;
    assign if_payload.slot0.prediction.abtb_pred_target = 32'd0;
`endif
    assign if_payload.slot1.prediction.abtb_hit = fq_head1_abtb_meta.hit;
    assign if_payload.slot1.prediction.abtb_way = fq_head1_abtb_meta.way;
`ifdef FRONTEND_FTQ_ABTB_WIDE_META
    assign if_payload.slot1.prediction.abtb_cfi_type =
        fq_head1_abtb_meta.cfi_type;
    assign if_payload.slot1.prediction.abtb_target = fq_head1_abtb_meta.target;
    assign if_payload.slot1.prediction.abtb_pred_taken =
        fq_head1_abtb_meta.pred_taken;
    assign if_payload.slot1.prediction.abtb_pred_target =
        fq_head1_abtb_meta.pred_target;
`else
    assign if_payload.slot1.prediction.abtb_cfi_type = 2'd0;
    assign if_payload.slot1.prediction.abtb_target = 32'd0;
    assign if_payload.slot1.prediction.abtb_pred_taken = 1'b0;
    assign if_payload.slot1.prediction.abtb_pred_target = 32'd0;
`endif

    wire if_accept = if_valid && if_ready_go && id_allowin;
    wire if_accept_dual = if_accept & can_dual_issue;
    wire if_accept_single = if_accept & ~can_dual_issue;

    frontend_fetch_queue #(
        .FQ_DEPTH (FQ_DEPTH),
        .FQ_PTR_W (FQ_PTR_W)
    ) u_frontend_fetch_queue (
        .clk                  (clk),
        .rst_n                (rst_n),
        .flush                (ex_redirect_valid),
        .enq0_payload         (f0_enq0_payload),
        .enq1_payload         (f0_enq1_payload),
        .enq0_valid           (f0_enq0_valid),
        .enq1_valid           (f0_enq1_valid),
        .enq_entry0           (f0_entry0),
        .enq_entry1           (f0_entry1),
        .enq_pair_meta0       (f0_pair_meta0),
        .enq_pair_meta1       (f0_pair_meta1),
        .enq_entry0_pair_ok   (f0_entry0_pair_ok),
        .prev_tail_pair_ok    (fq_prev_tail_pair_ok),
        .deq_single           (if_accept_single),
        .deq_dual             (if_accept_dual),
        .head                 (fq_head),
        .head_p1              (fq_head_p1),
        .tail                 (fq_tail),
        .tail_p1              (fq_tail_p1),
        .count                (fq_count),
        .tail_next_pc         (fq_tail_next_pc),
        .head0_entry          (fq_head0),
        .head1_entry          (fq_head1),
        .tail_prev_entry      (fq_tail_prev),
        .head0_pair_meta      (fq_head0_pair_meta),
        .head1_pair_meta      (fq_head1_pair_meta),
        .tail_prev_pair_meta  (fq_tail_prev_pair_meta),
        .head_pair_ok         (fq_head_pair_ok)
    );

    // Leave enough fetch-queue credit for the in-flight F0 response and a new
    // two-instruction BP0 packet.
    wire ftq_alloc_ready = (ftq_count < FTQ_DEPTH_COUNT);
    wire fq_credit_for_bp0 = f0_valid_r ? (fq_count <= FQ_DEPTH_MINUS_4)
                                        : (fq_count <= FQ_DEPTH_MINUS_2);
    assign bp0_fire = ftq_alloc_ready && fq_credit_for_bp0 && !redirect_valid;
    assign abtb_lookup_accept = bp0_fire;

    // Existing perf monitor expects these names to exist; the new queue removes
    // the old hold/skip machinery.
    assign irom_held_valid = 1'b0;
    assign if_skip_out = 1'b0;

endmodule

`ifdef FRONTEND_FTQ_ABTB_WIDE_META
`undef FRONTEND_FTQ_ABTB_WIDE_META
`endif
