// Simulation-only NSCSCC performance attribution monitor.
//
// This file is intentionally absent from platform/nscscc/filelist.f.  The
// runner adds it to Verilator as an extra source and binds it to simu_top, so
// none of these counters, hierarchy probes, or finish controls can enter the
// synthesized competition design.

module nscscc_perf_monitor (
    input logic        clk,
    input logic        rst_n,

    input logic        commit0_valid,
    input logic [31:0] commit0_pc,
    input logic [31:0] commit0_inst,
    input logic        commit0_load,
    input logic        commit0_store,
    input logic        commit1_valid,
    input logic [31:0] commit1_pc,
    input logic [31:0] commit1_inst,
    input logic        commit1_load,
    input logic        commit1_store,

    input logic        if_valid,
    input logic        id_valid,
    input logic [31:0] id_pc,
    input logic [31:0] id_inst,
    input logic [25:0] id_issue_hint,
    input logic [25:0] id_issue_hint_reference,
    input logic        ex_valid,
    input logic        mem_valid,
    input logic        wb_valid,
    input logic        ex_s1_valid,
    input logic        mem_s1_valid,
    input logic        wb_s1_valid,
    input logic        redirect,
    input logic        redirect_machine_clear,
    input logic        if_ready_go,
    input logic        id_allowin,
    input logic        id_ready_go,
    input logic        ex_allowin,
    input logic        ex_ready_go,
    input logic        ex_s1_flush,
    input logic        ex_s1_flush_machine_clear,
    input logic        ex_control_repair_valid,
    input logic        ex_control_repair_redirect,
    input logic        mem_allowin,
    input logic        mem_ready_go,
    input logic        wb_allowin,
    input logic        wb_exception,
    input logic        mem_redirect_valid,
    input logic        mem_redirect_machine_clear,
    input logic        muldiv_busy,
    input logic        id_load_hazard,
    input logic        id_load_ex_hazard,
    input logic        id_load_mem_hazard,
    input logic        mem_load_ready_probe,
    input logic        id_non_load_hazard,
    input logic        id_repair_hazard,
    input logic        id_muldiv_raw_hazard,
    input logic        id_mul_launch_raw_hazard,
    input logic        id_serializing_ready,
    input logic        id_barrier_ready,
    input logic        id_muldiv_structure_ready,
    input logic        timer_irq_block,
    input logic        ex_mmio_order_ready,
    input logic        ex_muldiv_ready,
    input logic        ex_priv_ready,
    input logic        mem_backpressure,
    input logic        mem_lsu_active,
    input logic        mem_lsu_uncached,
    input logic [3:0]  ftq_count,
    input logic [3:0]  fq_count,
    input logic        frontend_f0_valid,
    input logic        frontend_f0_response_fire,
    input logic        irom_req_valid,
    input logic        irom_req_ready,
    input logic        irom_resp_valid,
    input logic        pair_candidate,
    input logic        pair_raw_block,
    input logic        pair_frontend_limited,
    input logic        pair_raw_sole_blocker,
    input logic        frontend_single_no_second,
    input logic        frontend_single_noncontiguous,
    input logic        frontend_single_taken,
    input logic        frontend_taken_target_available,
    input logic        frontend_taken_target_pairable,
    input logic        pair_slot0_alu,
    input logic        pair_slot0_lsu,
    input logic        pair_slot0_cfi,
    input logic        pair_slot0_muldiv,
    input logic        pair_slot0_force_single,
    input logic        pair_slot1_alu,
    input logic        pair_slot1_lsu,
    input logic        pair_slot1_cfi,
    input logic        pair_slot1_muldiv,
    input logic        pair_slot1_force_single,

    // Shadow inputs for an ID-address / EX-data DCache prelookup study.
    // They observe the current pipeline without changing any RTL behavior.
    input logic        id_s1_valid_probe,
    input logic        id_to_ex_fire,
    input logic        id_s0_load,
    input logic        id_s0_store,
    input logic        id_s0_alu_only,
    input logic        id_s0_conditional,
    input logic [ 2:0] id_s0_branch_op,
    input logic        id_s0_indirect,
    input logic        id_s0_rs1_used,
    input logic        id_s0_rs2_used,
    input logic [ 4:0] id_s0_rs1_addr,
    input logic [ 4:0] id_s0_rs2_addr,
    input logic        id_s0_rs1_ex_source,
    input logic        id_s0_rs1_load_repair,
    input logic        id_s1_load,
    input logic        id_s1_store,
    input logic        id_s1_alu_only,
    input logic        id_s1_conditional,
    input logic [ 2:0] id_s1_branch_op,
    input logic        id_s1_indirect,
    input logic        id_s1_rs1_used,
    input logic        id_s1_rs2_used,
    input logic [ 4:0] id_s1_rs1_addr,
    input logic [ 4:0] id_s1_rs2_addr,
    input logic        id_s1_rs1_ex_source,
    input logic        id_s1_rs1_load_repair,
    input logic        id_ex_load_hazard,
    input logic        id_mem_load_hazard,
    input logic        ex_s0_load,
    input logic [ 1:0] ex_s0_load_size,
    input logic [ 4:0] ex_s0_rd,
    input logic        ex_s1_load,
    input logic [ 1:0] ex_s1_load_size,
    input logic [ 4:0] ex_s1_rd,
    input logic        ex_store_load_overlap,
    input logic        ex_store_load_same_word,
    input logic        dcache_read_port_internal_busy,

    input logic        pht_update_valid,
    input logic [1:0]  pht_update_counter,
    input logic        pht_update_taken,
    input logic        pred_train_valid,
    input logic        pred_train_conditional,
    input logic        pred_train_direct,
    input logic        pred_train_indirect,
    input logic        abtb_update_valid,
    input logic        abtb_update_hit,

    input logic        icache_busy,
    input logic        icache_miss_wait,
    input logic        icache_req_fire,
    input logic        icache_lookup_valid,
    input logic [27:0] icache_lookup_line_addr,
    input logic        icache_lookup_hit,
    input logic        icache_lookup_refill_hit,
    input logic        icache_lookup_miss,
    input logic        icache_refill_req_fire,
    input logic        icache_refill_data_fire,
    input logic        icache_refill_complete,
    input logic        icache_kill,

    input logic        dcache_busy,
    input logic        dcache_load_hit,
    input logic        dcache_load_miss,
    input logic        dcache_store_hit,
    input logic        dcache_store_miss,
    input logic [31:0] dcache_lookup_addr,
    input logic        dcache_uncached_start,
    input logic        dcache_dirty_victim,
    input logic        dcache_refill_req_fire,
    input logic        dcache_refill_data_fire,
    input logic        dcache_refill_target_fire,
    input logic        dcache_refill_complete,
    input logic        dcache_wb_req_fire,
    input logic        dcache_wb_data_fire,
    input logic        dcache_wb_resp_fire,
    input logic        dcache_refill_wb_overlap,
    input logic        dcache_refill_phase,
    input logic        dcache_writeback_block_phase,
    input logic        dcache_uncached_phase,

    input logic [3:0]  arid,
    input logic        arvalid,
    input logic        arready,
    input logic [3:0]  rid,
    input logic        rvalid,
    input logic        rready,
    input logic        rlast,
    input logic        awvalid,
    input logic        awready,
    input logic        wvalid,
    input logic        wready,
    input logic        bvalid,
    input logic        bready,

    input logic [15:0] led,
    input logic [1:0]  led_rg0,
    input logic [1:0]  led_rg1
);

    logic [31:0] stop_pc;
    logic [31:0] uart_putchar_pc;
    longint unsigned max_sim_cycles;
    longint unsigned simulation_cycles;
    logic measurement_active;
    integer icache_trace_fd;
    string icache_trace_path;
    integer dcache_trace_fd;
    string dcache_trace_path;

    longint unsigned boundaries;
    longint unsigned intervals;
    longint unsigned cycles;
    longint unsigned instructions;
    longint unsigned commit0_only_cycles;
    longint unsigned dual_commit_cycles;
    longint unsigned zero_commit_cycles;
    longint unsigned retired_loads;
    longint unsigned retired_stores;

    longint unsigned cycles_icache_busy;
    longint unsigned cycles_dcache_busy;
    longint unsigned cycles_muldiv_busy;
    longint unsigned cycles_load_hazard;
    longint unsigned cycles_non_load_hazard;
    longint unsigned cycles_mem_backpressure;
    longint unsigned cycles_ftq_empty;
    longint unsigned cycles_fq_empty;
    longint unsigned cycles_ftq_full;
    longint unsigned cycles_fq_full;
    longint unsigned pair_candidate_cycles;
    longint unsigned pair_raw_block_cycles;

    longint unsigned no_commit_redirect;
    longint unsigned no_commit_dcache;
    longint unsigned no_commit_icache;
    longint unsigned no_commit_muldiv;
    longint unsigned no_commit_hazard;
    longint unsigned no_commit_frontend_empty;
    longint unsigned no_commit_other;

    // A snapshot of a stalled machine cannot explain a WB bubble reliably:
    // the event which created that bubble happened several pipeline stages
    // earlier.  Attach a narrow cause tag to every invalid Slot-0 token and
    // move it under the exact same valid/allow/flush rules as the real pipe.
    // These tags and counters exist only in this simulation-only monitor.
    typedef enum logic [4:0] {
        BUBBLE_NONE,
        BUBBLE_PIPE_FILL,
        BUBBLE_REDIRECT,
        BUBBLE_MACHINE_CLEAR,
        BUBBLE_ICACHE_REFILL,
        BUBBLE_FETCH_RESPONSE,
        BUBBLE_FRONTEND_EMPTY,
        BUBBLE_FRONTEND_BLOCKED,
        BUBBLE_FRONTEND_SINGLE,
        BUBBLE_ID_PAIR_RAW,
        BUBBLE_ID_PAIR_POLICY,
        BUBBLE_ID_LOAD_EX_ONLY,
        BUBBLE_ID_LOAD_MEM_READY_ONLY,
        BUBBLE_ID_LOAD_MEM_WAIT_ONLY,
        BUBBLE_ID_LOAD_MULTI_SOURCE,
        BUBBLE_ID_LOAD_OTHER,
        BUBBLE_ID_REPAIR_RAW,
        BUBBLE_ID_MULDIV_RAW,
        BUBBLE_ID_MULDIV_STRUCTURE,
        BUBBLE_ID_SERIAL_DRAIN,
        BUBBLE_ID_SERIAL_BARRIER,
        BUBBLE_ID_TIMER_IRQ,
        BUBBLE_ID_OTHER,
        BUBBLE_EX_MULDIV,
        BUBBLE_EX_MMIO_ORDER,
        BUBBLE_EX_PRIV_DRAIN,
        BUBBLE_EX_OTHER,
        BUBBLE_MEM_DCACHE_LOOKUP,
        BUBBLE_MEM_DCACHE_REFILL,
        BUBBLE_MEM_DCACHE_WRITEBACK,
        BUBBLE_MEM_UNCACHED,
        BUBBLE_MEM_OTHER
    } bubble_cause_t;

    // Standard 3C classification for the configured direct-mapped/2-way,
    // 16-byte-line ICache.  A same-capacity fully-associative LRU shadow
    // separates conflict misses from capacity misses without changing DUT
    // behavior.  OUTSIDE covers the deliberately uncacheable PC window.
    typedef enum logic [2:0] {
        ICACHE_3C_NONE,
        ICACHE_3C_COMPULSORY,
        ICACHE_3C_CONFLICT,
        ICACHE_3C_CAPACITY,
        ICACHE_3C_OUTSIDE
    } icache_3c_class_t;

    bubble_cause_t id_bubble_cause;
    bubble_cause_t ex_bubble_cause;
    bubble_cause_t mem_bubble_cause;
    bubble_cause_t wb_bubble_cause;
    bubble_cause_t id_s1_bubble_cause;
    bubble_cause_t ex_s1_bubble_cause;
    bubble_cause_t mem_s1_bubble_cause;
    bubble_cause_t wb_s1_bubble_cause;
    icache_3c_class_t id_icache_3c_class;
    icache_3c_class_t ex_icache_3c_class;
    icache_3c_class_t mem_icache_3c_class;
    icache_3c_class_t wb_icache_3c_class;
    icache_3c_class_t id_s1_icache_3c_class;
    icache_3c_class_t ex_s1_icache_3c_class;
    icache_3c_class_t mem_s1_icache_3c_class;
    icache_3c_class_t wb_s1_icache_3c_class;

    // Top-down accounting owns both architectural issue slots in every
    // measured cycle.  A valid WB token retires; otherwise its causal bubble
    // tag selects exactly one bound class.  The fifth value is diagnostic and
    // must remain zero in every accepted run.
    typedef enum logic [2:0] {
        TOPDOWN_RETIRING,
        TOPDOWN_BAD_SPECULATION,
        TOPDOWN_FRONTEND_BOUND,
        TOPDOWN_BACKEND_BOUND,
        TOPDOWN_UNCLASSIFIED
    } topdown_class_t;

    longint unsigned topdown_retiring_slots;
    longint unsigned topdown_bad_speculation_slots;
    longint unsigned topdown_frontend_bound_slots;
    longint unsigned topdown_backend_bound_slots;
    longint unsigned topdown_unclassified_slots;

    typedef enum logic [3:0] {
        L2_RETIRING,
        L2_BRANCH_MISPREDICT,
        L2_MACHINE_CLEAR,
        L2_FETCH_LATENCY,
        L2_FETCH_BANDWIDTH,
        L2_CORE_BOUND,
        L2_MEMORY_BOUND,
        L2_UNCLASSIFIED
    } second_level_class_t;

    longint unsigned l2_retiring_slots;
    longint unsigned l2_branch_mispredict_slots;
    longint unsigned l2_machine_clear_slots;
    longint unsigned l2_fetch_latency_slots;
    longint unsigned l2_fetch_bandwidth_slots;
    longint unsigned l2_core_bound_slots;
    longint unsigned l2_memory_bound_slots;
    longint unsigned l2_unclassified_slots;

    // Level 3 drills only into the Level-2 Core Bound parent.  NONE means
    // that the slot belongs to another Level-2 class; UNCLASSIFIED is an
    // error for a Core Bound slot and is kept as a strict coverage check.
    typedef enum logic [2:0] {
        CORE_DETAIL_NONE,
        CORE_DETAIL_LOAD_REPAIR_DEP,
        CORE_DETAIL_PAIR_DEP,
        CORE_DETAIL_PAIR_POLICY,
        CORE_DETAIL_MULDIV,
        CORE_DETAIL_SERIALIZATION,
        CORE_DETAIL_OTHER,
        CORE_DETAIL_UNCLASSIFIED
    } core_detail_class_t;

    longint unsigned l3_load_repair_dependency_slots;
    longint unsigned l3_same_pair_dependency_slots;
    longint unsigned l3_pairing_policy_slots;
    longint unsigned l3_muldiv_slots;
    longint unsigned l3_serialization_slots;
    longint unsigned l3_other_core_slots;
    longint unsigned l3_unclassified_core_slots;

    // A narrow Slot-1 detail tag refines only frontend-single and pairing
    // bubbles.  It follows the same accept/hold/flush path as the causal
    // bubble tag so wrong-path candidates cannot inflate opportunity counts.
    typedef enum logic [4:0] {
        SLOT1_DETAIL_NONE,
        SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE,
        SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED,
        SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE,
        SLOT1_DETAIL_FRONTEND_NO_SECOND,
        SLOT1_DETAIL_FRONTEND_NONCONTIGUOUS,
        SLOT1_DETAIL_RAW_ALU_TO_ALU,
        SLOT1_DETAIL_RAW_ALU_TO_LSU,
        SLOT1_DETAIL_RAW_ALU_TO_CFI,
        SLOT1_DETAIL_RAW_LSU_PRODUCER,
        SLOT1_DETAIL_RAW_MULDIV_PRODUCER,
        SLOT1_DETAIL_RAW_CFI_PRODUCER,
        SLOT1_DETAIL_RAW_OTHER,
        SLOT1_DETAIL_POLICY_FORCE_SINGLE,
        SLOT1_DETAIL_POLICY_DUAL_LSU,
        SLOT1_DETAIL_POLICY_DUAL_CFI,
        SLOT1_DETAIL_POLICY_SLOT0_UNSUPPORTED,
        SLOT1_DETAIL_POLICY_SLOT1_UNSUPPORTED,
        SLOT1_DETAIL_POLICY_OTHER
    } slot1_detail_t;

    slot1_detail_t id_s1_detail;
    slot1_detail_t ex_s1_detail;
    slot1_detail_t mem_s1_detail;
    slot1_detail_t wb_s1_detail;

    longint unsigned l4_fetch_pipe_fill_slots;
    longint unsigned l4_fetch_icache_refill_slots;
    longint unsigned l4_fetch_response_slots;
    longint unsigned l4_fetch_empty_slots;
    longint unsigned l4_fetch_blocked_slots;
    longint unsigned l4_fetch_single_taken_slots;
    longint unsigned l5_fetch_taken_target_pairable_slots;
    longint unsigned l5_fetch_taken_target_available_blocked_slots;
    longint unsigned l5_fetch_taken_target_unavailable_slots;
    longint unsigned l4_fetch_single_no_second_slots;
    longint unsigned l4_fetch_single_noncontiguous_slots;
    longint unsigned l4_fetch_single_unclassified_slots;
    longint unsigned l4_load_raw_slots;
    longint unsigned l4_repair_raw_slots;
    longint unsigned l5_load_ex_only_slots;
    longint unsigned l5_load_mem_ready_only_slots;
    longint unsigned l5_load_mem_wait_only_slots;
    longint unsigned l5_load_multi_source_slots;
    longint unsigned l5_load_other_slots;
    longint unsigned repaired_control_executions;
    longint unsigned repaired_control_redirects;
    longint unsigned l4_pair_raw_alu_to_alu_slots;
    longint unsigned l4_pair_raw_alu_to_lsu_slots;
    longint unsigned l4_pair_raw_alu_to_cfi_slots;
    longint unsigned l4_pair_raw_lsu_producer_slots;
    longint unsigned l4_pair_raw_muldiv_producer_slots;
    longint unsigned l4_pair_raw_cfi_producer_slots;
    longint unsigned l4_pair_raw_other_slots;
    longint unsigned l4_pair_raw_unclassified_slots;
    longint unsigned l4_pair_policy_force_single_slots;
    longint unsigned l4_pair_policy_dual_lsu_slots;
    longint unsigned l4_pair_policy_dual_cfi_slots;
    longint unsigned l4_pair_policy_slot0_unsupported_slots;
    longint unsigned l4_pair_policy_slot1_unsupported_slots;
    longint unsigned l4_pair_policy_other_slots;
    longint unsigned l4_pair_policy_unclassified_slots;

    longint unsigned root_pipe_fill;
    longint unsigned root_redirect;
    longint unsigned root_icache_refill;
    longint unsigned root_fetch_response;
    longint unsigned root_frontend_empty;
    longint unsigned root_frontend_blocked;
    longint unsigned root_id_load_raw;
    longint unsigned root_id_repair_raw;
    longint unsigned root_id_muldiv_raw;
    longint unsigned root_id_muldiv_structure;
    longint unsigned root_id_serial_drain;
    longint unsigned root_id_serial_barrier;
    longint unsigned root_id_timer_irq;
    longint unsigned root_id_other;
    longint unsigned root_ex_muldiv;
    longint unsigned root_ex_mmio_order;
    longint unsigned root_ex_priv_drain;
    longint unsigned root_ex_other;
    longint unsigned root_mem_dcache_lookup;
    longint unsigned root_mem_dcache_refill;
    longint unsigned root_mem_dcache_writeback;
    longint unsigned root_mem_uncached;
    longint unsigned root_mem_other;
    longint unsigned root_exception;
    longint unsigned root_unclassified;

    longint unsigned redirects;
    longint unsigned conditional_updates;
    longint unsigned conditional_wrong;
    longint unsigned direct_controls;
    longint unsigned indirect_controls;
    longint unsigned abtb_updates;
    longint unsigned abtb_hit_updates;
    longint unsigned abtb_allocations;

    longint unsigned icache_requests;
    longint unsigned icache_hits;
    longint unsigned icache_refill_hits;
    longint unsigned icache_misses;
    longint unsigned icache_refill_requests;
    longint unsigned icache_refill_beats;
    longint unsigned icache_refill_completions;
    longint unsigned icache_kills;
    longint unsigned icache_compulsory_misses;
    longint unsigned icache_conflict_misses;
    longint unsigned icache_capacity_misses;
    longint unsigned icache_outside_misses;
    longint unsigned icache_3c_unclassified_misses;
    longint unsigned icache_compulsory_refill_requests;
    longint unsigned icache_conflict_refill_requests;
    longint unsigned icache_capacity_refill_requests;
    longint unsigned icache_outside_refill_requests;
    longint unsigned icache_3c_unclassified_refill_requests;
    longint unsigned icache_compulsory_refill_slots;
    longint unsigned icache_conflict_refill_slots;
    longint unsigned icache_capacity_refill_slots;
    longint unsigned icache_outside_refill_slots;
    longint unsigned icache_3c_unclassified_refill_slots;

    localparam integer ICACHE_PROFILE_BYTES =
`ifdef NSCSCC_ICACHE_BYTES
        `NSCSCC_ICACHE_BYTES;
`else
        16384;
`endif
    localparam integer ICACHE_SHADOW_LINES = ICACHE_PROFILE_BYTES / 16;
    localparam integer ICACHE_WINDOW_LINES = 65536;
    logic [ICACHE_WINDOW_LINES-1:0] icache_shadow_seen_q;
    logic [ICACHE_WINDOW_LINES-1:0] icache_shadow_valid_q;
    logic [15:0] icache_shadow_prev_q [0:ICACHE_WINDOW_LINES-1];
    logic [15:0] icache_shadow_next_q [0:ICACHE_WINDOW_LINES-1];
    logic [15:0] icache_shadow_head_q;
    logic [15:0] icache_shadow_tail_q;
    logic [$clog2(ICACHE_SHADOW_LINES+1)-1:0] icache_shadow_count_q;
    icache_3c_class_t active_icache_3c_class_q;

    longint unsigned dcache_load_hits;
    longint unsigned dcache_load_misses;
    longint unsigned dcache_store_hits;
    longint unsigned dcache_store_misses;
    longint unsigned dcache_uncached_requests;
    longint unsigned dcache_dirty_victims;
    longint unsigned dcache_refill_requests;
    longint unsigned dcache_refill_beats;
    longint unsigned dcache_refill_target_beats;
    longint unsigned dcache_refill_completions;
    longint unsigned dcache_writeback_requests;
    longint unsigned dcache_writeback_beats;
    longint unsigned dcache_writeback_responses;
    longint unsigned cycles_refill_wb_overlap;

    // ID-address / EX-data DCache prelookup shadow model.  "safe" refuses
    // an address base that currently comes from EX; "aggressive" permits an
    // ordinary EX ALU forward but still refuses a load-repair value that does
    // not exist until the following stage.  Neither model changes the DUT.
    longint unsigned early_accepted_loads;
    longint unsigned early_addr_safe_loads;
    longint unsigned early_addr_aggressive_loads;
    longint unsigned early_addr_ex_forward_loads;
    longint unsigned early_addr_repair_blocked_loads;
    longint unsigned early_grant_safe_loads;
    longint unsigned early_grant_aggressive_loads;
    longint unsigned early_block_internal_safe;
    longint unsigned early_block_internal_aggressive;
    longint unsigned early_block_fallback_safe;
    longint unsigned early_block_fallback_aggressive;
    longint unsigned early_hit_safe_loads;
    longint unsigned early_hit_aggressive_loads;
    longint unsigned early_raw_ex_events;
    longint unsigned early_raw_repairable_events;
    longint unsigned early_raw_role_alu;
    longint unsigned early_raw_role_load_addr;
    longint unsigned early_raw_role_store_addr;
    longint unsigned early_raw_role_store_data;
    longint unsigned early_raw_role_branch;
    longint unsigned early_raw_role_jirl;
    longint unsigned early_raw_role_other;
    longint unsigned early_raw_branch_load_byte;
    longint unsigned early_raw_branch_load_half;
    longint unsigned early_raw_branch_load_word;
    longint unsigned early_raw_branch_op_eq;
    longint unsigned early_raw_branch_op_ne;
    longint unsigned early_raw_branch_op_lt;
    longint unsigned early_raw_branch_op_ge;
    longint unsigned early_raw_branch_op_ltu;
    longint unsigned early_raw_branch_op_geu;
    longint unsigned early_raw_branch_byte_eqne;
    longint unsigned early_raw_branch_half_eqne;
    longint unsigned early_raw_branch_word_eqne;
    longint unsigned early_raw_branch_hit;
    longint unsigned early_raw_branch_byte_eqne_hit;
    longint unsigned early_raw_branch_half_eqne_hit;
    longint unsigned early_raw_branch_word_eqne_hit;
    longint unsigned early_raw_hit_safe_all;
    longint unsigned early_raw_hit_aggressive_all;
    longint unsigned early_raw_hit_safe_all_no_store;
    longint unsigned early_raw_hit_aggressive_all_no_store;
    longint unsigned early_raw_hit_safe_v1;
    longint unsigned early_raw_hit_aggressive_v1;
    longint unsigned early_raw_hit_safe_v1_no_store;
    longint unsigned early_raw_hit_aggressive_v1_no_store;
    longint unsigned early_store_load_overlaps;
    longint unsigned early_store_load_same_word;
    longint unsigned early_store_load_diff_word;
    longint unsigned early_store_same_word_hit_safe;
    longint unsigned early_store_same_word_hit_aggressive;

    logic ex_prelookup_safe;
    logic ex_prelookup_aggressive;
    logic ex_prelookup_measured;
    logic mem_prelookup_safe;
    logic mem_prelookup_aggressive;
    logic mem_prelookup_measured;
    logic mem_raw_event;
    logic mem_raw_repairable;
    logic mem_raw_measured;
    logic mem_raw_branch;
    logic mem_raw_branch_byte_eqne;
    logic mem_raw_branch_half_eqne;
    logic mem_raw_branch_word_eqne;
    logic mem_store_same_word;

    longint unsigned axi_read_requests_i;
    longint unsigned axi_read_requests_d;
    longint unsigned axi_read_requests_other;
    longint unsigned axi_read_beats_i;
    longint unsigned axi_read_beats_d;
    longint unsigned axi_ar_stall_cycles;
    longint unsigned axi_r_gap_cycles;
    longint unsigned axi_both_read_outstanding_cycles;
    longint unsigned axi_write_requests;
    longint unsigned axi_write_beats;
    longint unsigned axi_write_responses;
    longint unsigned axi_i_first_latency_sum;
    longint unsigned axi_i_first_latency_max;
    longint unsigned axi_i_first_latency_samples;
    longint unsigned axi_d_first_latency_sum;
    longint unsigned axi_d_first_latency_max;
    longint unsigned axi_d_first_latency_samples;
    longint unsigned axi_pending_at_interval_end;

    logic read_pending_i;
    logic read_pending_d;
    logic first_pending_i;
    logic first_pending_d;
    longint unsigned read_age_i;
    longint unsigned read_age_d;

    wire id_s0_load_fire = id_to_ex_fire & id_s0_load;
    wire id_s1_load_fire = id_to_ex_fire & id_s1_valid_probe & id_s1_load;
    wire id_any_load_fire = id_s0_load_fire | id_s1_load_fire;
    wire id_s0_addr_safe = ~id_s0_rs1_ex_source
                         & ~id_s0_rs1_load_repair;
    wire id_s1_addr_safe = ~id_s1_rs1_ex_source
                         & ~id_s1_rs1_load_repair;
    wire id_s0_addr_aggressive = ~id_s0_rs1_load_repair;
    wire id_s1_addr_aggressive = ~id_s1_rs1_load_repair;
    wire id_load_addr_safe = (id_s0_load_fire & id_s0_addr_safe)
                           | (id_s1_load_fire & id_s1_addr_safe);
    wire id_load_addr_aggressive =
        (id_s0_load_fire & id_s0_addr_aggressive)
      | (id_s1_load_fire & id_s1_addr_aggressive);
    wire id_load_addr_ex_forward =
        (id_s0_load_fire & id_s0_rs1_ex_source
         & ~id_s0_rs1_load_repair)
      | (id_s1_load_fire & id_s1_rs1_ex_source
         & ~id_s1_rs1_load_repair);
    wire id_load_addr_repair_blocked =
        (id_s0_load_fire & id_s0_rs1_load_repair)
      | (id_s1_load_fire & id_s1_rs1_load_repair);

    wire ex_any_load = (ex_valid & ex_s0_load)
                     | (ex_s1_valid & ex_s1_load);
    wire ex_fallback_safe = ex_any_load & ~ex_prelookup_safe;
    wire ex_fallback_aggressive = ex_any_load & ~ex_prelookup_aggressive;
    wire id_block_internal_safe = id_load_addr_safe
                                & dcache_read_port_internal_busy;
    wire id_block_internal_aggressive = id_load_addr_aggressive
                                      & dcache_read_port_internal_busy;
    wire id_block_fallback_safe = id_load_addr_safe
                                & ~dcache_read_port_internal_busy
                                & ex_fallback_safe;
    wire id_block_fallback_aggressive = id_load_addr_aggressive
                                      & ~dcache_read_port_internal_busy
                                      & ex_fallback_aggressive;
    wire id_prelookup_safe_grant = id_load_addr_safe
                                 & ~dcache_read_port_internal_busy
                                 & ~ex_fallback_safe;
    wire id_prelookup_aggressive_grant = id_load_addr_aggressive
                                       & ~dcache_read_port_internal_busy
                                       & ~ex_fallback_aggressive;

    wire ex_s0_load_producer = ex_valid & ex_s0_load & (ex_s0_rd != 5'd0);
    wire ex_s1_load_producer = ex_s1_valid & ex_s1_load
                             & (ex_s1_rd != 5'd0);
    wire id_s0_rs1_ex_load_dep = id_s0_rs1_used
        & ((ex_s0_load_producer & (id_s0_rs1_addr == ex_s0_rd))
         | (ex_s1_load_producer & (id_s0_rs1_addr == ex_s1_rd)));
    wire id_s0_rs2_ex_load_dep = id_s0_rs2_used
        & ((ex_s0_load_producer & (id_s0_rs2_addr == ex_s0_rd))
         | (ex_s1_load_producer & (id_s0_rs2_addr == ex_s1_rd)));
    wire id_s1_rs1_ex_load_dep = id_s1_valid_probe & id_s1_rs1_used
        & ((ex_s0_load_producer & (id_s1_rs1_addr == ex_s0_rd))
         | (ex_s1_load_producer & (id_s1_rs1_addr == ex_s1_rd)));
    wire id_s1_rs2_ex_load_dep = id_s1_valid_probe & id_s1_rs2_used
        & ((ex_s0_load_producer & (id_s1_rs2_addr == ex_s0_rd))
         | (ex_s1_load_producer & (id_s1_rs2_addr == ex_s1_rd)));
    wire id_s0_ex_load_dep = id_s0_rs1_ex_load_dep
                           | id_s0_rs2_ex_load_dep;
    wire id_s1_ex_load_dep = id_s1_rs1_ex_load_dep
                           | id_s1_rs2_ex_load_dep;
    wire id_s0_repairable_consumer = id_s0_alu_only
                                   | id_s0_load | id_s0_store;
    wire id_s1_repairable_consumer = id_s1_alu_only
                                   | id_s1_load | id_s1_store;
    wire id_raw_has_unrepairable_consumer =
        (id_s0_ex_load_dep & ~id_s0_repairable_consumer)
      | (id_s1_ex_load_dep & ~id_s1_repairable_consumer);

    // Count only a bubble whose remaining issue conditions are already true.
    // An older MEM-load dependency or an unrelated serial/structure hazard
    // would still hold ID even if the EX load result arrived early.
    wire id_raw_ex_event = id_valid & id_ex_load_hazard
                         & ~id_mem_load_hazard
                         & ex_allowin & ~id_non_load_hazard
                         & id_serializing_ready & id_barrier_ready
                         & id_muldiv_structure_ready & ~timer_irq_block;
    wire id_raw_repairable_event = id_raw_ex_event
                                 & ~id_raw_has_unrepairable_consumer;
    wire id_raw_role_alu = id_raw_ex_event
        & ((id_s0_ex_load_dep & id_s0_alu_only)
         | (id_s1_ex_load_dep & id_s1_alu_only));
    wire id_raw_role_load_addr = id_raw_ex_event
        & ((id_s0_rs1_ex_load_dep & id_s0_load)
         | (id_s1_rs1_ex_load_dep & id_s1_load));
    wire id_raw_role_store_addr = id_raw_ex_event
        & ((id_s0_rs1_ex_load_dep & id_s0_store)
         | (id_s1_rs1_ex_load_dep & id_s1_store));
    wire id_raw_role_store_data = id_raw_ex_event
        & ((id_s0_rs2_ex_load_dep & id_s0_store)
         | (id_s1_rs2_ex_load_dep & id_s1_store));
    wire id_raw_role_branch = id_raw_ex_event
        & ((id_s0_ex_load_dep & id_s0_conditional)
         | (id_s1_ex_load_dep & id_s1_conditional));
    wire id_raw_branch_s0 = id_raw_ex_event
                          & id_s0_ex_load_dep & id_s0_conditional;
    wire id_raw_branch_s1 = id_raw_ex_event
                          & id_s1_ex_load_dep & id_s1_conditional;
    wire id_raw_branch_op_eq =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_EQ))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_EQ));
    wire id_raw_branch_op_ne =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_NE))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_NE));
    wire id_raw_branch_op_lt =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_LT))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_LT));
    wire id_raw_branch_op_ge =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_GE))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_GE));
    wire id_raw_branch_op_ltu =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_LTU))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_LTU));
    wire id_raw_branch_op_geu =
        (id_raw_branch_s0 & (id_s0_branch_op == cpu_defs::BR_GEU))
      | (id_raw_branch_s1 & (id_s1_branch_op == cpu_defs::BR_GEU));
    wire ex_raw_load_byte =
        (ex_s0_load_producer & (ex_s0_load_size == cpu_defs::MEM_BYTE))
      | (ex_s1_load_producer & (ex_s1_load_size == cpu_defs::MEM_BYTE));
    wire ex_raw_load_half =
        (ex_s0_load_producer & (ex_s0_load_size == cpu_defs::MEM_HALF))
      | (ex_s1_load_producer & (ex_s1_load_size == cpu_defs::MEM_HALF));
    wire ex_raw_load_word =
        (ex_s0_load_producer & (ex_s0_load_size == cpu_defs::MEM_WORD))
      | (ex_s1_load_producer & (ex_s1_load_size == cpu_defs::MEM_WORD));
    wire id_raw_branch_eqne = id_raw_branch_op_eq | id_raw_branch_op_ne;
    wire id_raw_branch_byte_eqne = id_raw_role_branch
                                  & ex_raw_load_byte & id_raw_branch_eqne;
    wire id_raw_branch_half_eqne = id_raw_role_branch
                                  & ex_raw_load_half & id_raw_branch_eqne;
    wire id_raw_branch_word_eqne = id_raw_role_branch
                                  & ex_raw_load_word & id_raw_branch_eqne;
    wire id_raw_role_jirl = id_raw_ex_event
        & ((id_s0_ex_load_dep & id_s0_indirect)
         | (id_s1_ex_load_dep & id_s1_indirect));
    wire id_raw_role_other = id_raw_ex_event
        & ((id_s0_ex_load_dep
            & ~(id_s0_alu_only | id_s0_load | id_s0_store
                | id_s0_conditional | id_s0_indirect))
         | (id_s1_ex_load_dep
            & ~(id_s1_alu_only | id_s1_load | id_s1_store
                | id_s1_conditional | id_s1_indirect)));

    wire commit0_rdcntvl = commit0_valid
        && (commit0_inst[31:15] == 17'd0)
        && (commit0_inst[14:10] == 5'd24)
        && (commit0_inst[9:5] == 5'd0);
    wire commit1_rdcntvl = commit1_valid
        && (commit1_inst[31:15] == 17'd0)
        && (commit1_inst[14:10] == 5'd24)
        && (commit1_inst[9:5] == 5'd0);
    wire counter_boundary = commit0_rdcntvl | commit1_rdcntvl;
    wire any_commit = commit0_valid | commit1_valid;
    wire dual_commit = commit0_valid & commit1_valid;
    wire ar_fire = arvalid & arready;
    wire r_fire = rvalid & rready;
    wire aw_fire = awvalid & awready;
    wire w_fire = wvalid & wready;
    wire b_fire = bvalid & bready;
    wire benchmark_pass = (led == 16'hffff)
                        && (led_rg0 == 2'd1)
                        && (led_rg1 == 2'd1);

    wire icache_lookup_in_window =
        icache_lookup_line_addr[27:16] == 12'h1c0;
    wire [15:0] icache_lookup_line_key =
        icache_lookup_line_addr[15:0];
    icache_3c_class_t icache_lookup_3c_class;

    always_comb begin
        if (!icache_lookup_in_window)
            icache_lookup_3c_class = ICACHE_3C_OUTSIDE;
        else if (!icache_shadow_seen_q[icache_lookup_line_key])
            icache_lookup_3c_class = ICACHE_3C_COMPULSORY;
        else if (icache_shadow_valid_q[icache_lookup_line_key])
            icache_lookup_3c_class = ICACHE_3C_CONFLICT;
        else
            icache_lookup_3c_class = ICACHE_3C_CAPACITY;
    end

    // Exact O(1) fully-associative LRU shadow for the one-megabyte PC
    // window.  The linked-list arrays are indexed by the 16-bit line number;
    // only valid entries are ever read, so their payload need not be reset.
    // State is warmed before the measured RDCNTVL interval just like the DUT.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            icache_shadow_seen_q <= '0;
            icache_shadow_valid_q <= '0;
            icache_shadow_head_q <= '0;
            icache_shadow_tail_q <= '0;
            icache_shadow_count_q <= '0;
            active_icache_3c_class_q <= ICACHE_3C_NONE;
        end else begin
            if (icache_lookup_miss)
                active_icache_3c_class_q <= icache_lookup_3c_class;

            if (icache_lookup_valid && icache_lookup_in_window) begin
                icache_shadow_seen_q[icache_lookup_line_key] <= 1'b1;
                if (icache_shadow_valid_q[icache_lookup_line_key]) begin
                    // A hit becomes the most-recently-used line.
                    if (icache_lookup_line_key != icache_shadow_tail_q) begin
                        if (icache_lookup_line_key == icache_shadow_head_q) begin
                            icache_shadow_head_q <=
                                icache_shadow_next_q[icache_lookup_line_key];
                            icache_shadow_prev_q[
                                icache_shadow_next_q[icache_lookup_line_key]
                            ] <= icache_shadow_next_q[
                                icache_lookup_line_key
                            ];
                        end else begin
                            icache_shadow_next_q[
                                icache_shadow_prev_q[icache_lookup_line_key]
                            ] <= icache_shadow_next_q[
                                icache_lookup_line_key
                            ];
                            icache_shadow_prev_q[
                                icache_shadow_next_q[icache_lookup_line_key]
                            ] <= icache_shadow_prev_q[
                                icache_lookup_line_key
                            ];
                        end
                        icache_shadow_next_q[icache_shadow_tail_q] <=
                            icache_lookup_line_key;
                        icache_shadow_prev_q[icache_lookup_line_key] <=
                            icache_shadow_tail_q;
                        icache_shadow_next_q[icache_lookup_line_key] <=
                            icache_lookup_line_key;
                        icache_shadow_tail_q <= icache_lookup_line_key;
                    end
                end else begin
                    icache_shadow_valid_q[icache_lookup_line_key] <= 1'b1;
                    if (icache_shadow_count_q == 0) begin
                        icache_shadow_head_q <= icache_lookup_line_key;
                        icache_shadow_tail_q <= icache_lookup_line_key;
                        icache_shadow_prev_q[icache_lookup_line_key] <=
                            icache_lookup_line_key;
                        icache_shadow_next_q[icache_lookup_line_key] <=
                            icache_lookup_line_key;
                        icache_shadow_count_q <= 1;
                    end else if (icache_shadow_count_q
                                 < ICACHE_SHADOW_LINES) begin
                        icache_shadow_next_q[icache_shadow_tail_q] <=
                            icache_lookup_line_key;
                        icache_shadow_prev_q[icache_lookup_line_key] <=
                            icache_shadow_tail_q;
                        icache_shadow_next_q[icache_lookup_line_key] <=
                            icache_lookup_line_key;
                        icache_shadow_tail_q <= icache_lookup_line_key;
                        icache_shadow_count_q <= icache_shadow_count_q + 1;
                    end else begin
                        // Replace the least-recently-used line at the head.
                        icache_shadow_valid_q[icache_shadow_head_q] <= 1'b0;
                        icache_shadow_head_q <=
                            icache_shadow_next_q[icache_shadow_head_q];
                        icache_shadow_prev_q[
                            icache_shadow_next_q[icache_shadow_head_q]
                        ] <= icache_shadow_next_q[icache_shadow_head_q];
                        icache_shadow_next_q[icache_shadow_tail_q] <=
                            icache_lookup_line_key;
                        icache_shadow_prev_q[icache_lookup_line_key] <=
                            icache_shadow_tail_q;
                        icache_shadow_next_q[icache_lookup_line_key] <=
                            icache_lookup_line_key;
                        icache_shadow_tail_q <= icache_lookup_line_key;
                    end
                end
            end
        end
    end

    function automatic bubble_cause_t classify_frontend_bubble();
        begin
            // A killed AXI refill may still be draining while local hits are
            // accepted.  Only an unresolved frontend miss owner is a real
            // refill-latency bubble.
            if (icache_miss_wait)
                classify_frontend_bubble = BUBBLE_ICACHE_REFILL;
            else if ((frontend_f0_valid
                      && (!frontend_f0_response_fire || !irom_resp_valid))
                     || (ftq_count != 0)
                     || (irom_req_valid && !irom_req_ready))
                classify_frontend_bubble = BUBBLE_FETCH_RESPONSE;
            else if ((fq_count == 0) && !if_valid)
                classify_frontend_bubble = BUBBLE_FRONTEND_EMPTY;
            else
                classify_frontend_bubble = BUBBLE_FRONTEND_BLOCKED;
        end
    endfunction

    function automatic bubble_cause_t classify_id_bubble();
        begin
            if (id_load_hazard) begin
                if (id_load_ex_hazard && id_load_mem_hazard)
                    classify_id_bubble = BUBBLE_ID_LOAD_MULTI_SOURCE;
                else if (id_load_ex_hazard)
                    classify_id_bubble = BUBBLE_ID_LOAD_EX_ONLY;
                else if (id_load_mem_hazard && mem_load_ready_probe)
                    classify_id_bubble = BUBBLE_ID_LOAD_MEM_READY_ONLY;
                else if (id_load_mem_hazard)
                    classify_id_bubble = BUBBLE_ID_LOAD_MEM_WAIT_ONLY;
                else
                    classify_id_bubble = BUBBLE_ID_LOAD_OTHER;
            end
            else if (id_repair_hazard)
                classify_id_bubble = BUBBLE_ID_REPAIR_RAW;
            else if (id_muldiv_raw_hazard || id_mul_launch_raw_hazard)
                classify_id_bubble = BUBBLE_ID_MULDIV_RAW;
            else if (timer_irq_block)
                classify_id_bubble = BUBBLE_ID_TIMER_IRQ;
            else if (!id_serializing_ready)
                classify_id_bubble = BUBBLE_ID_SERIAL_DRAIN;
            else if (!id_barrier_ready)
                classify_id_bubble = BUBBLE_ID_SERIAL_BARRIER;
            else if (!id_muldiv_structure_ready)
                classify_id_bubble = BUBBLE_ID_MULDIV_STRUCTURE;
            else
                classify_id_bubble = BUBBLE_ID_OTHER;
        end
    endfunction

    function automatic slot1_detail_t classify_frontend_single_detail();
        begin
            // A predicted-taken Slot 0 makes a sequential Slot 1 unusable
            // even if one is queued, so target-side supply is the fundamental
            // requirement when reasons overlap.
            if (frontend_single_taken) begin
                if (frontend_taken_target_pairable)
                    classify_frontend_single_detail =
                        SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE;
                else if (frontend_taken_target_available)
                    classify_frontend_single_detail =
                        SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED;
                else
                    classify_frontend_single_detail =
                        SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE;
            end
            else if (frontend_single_no_second)
                classify_frontend_single_detail =
                    SLOT1_DETAIL_FRONTEND_NO_SECOND;
            else if (frontend_single_noncontiguous)
                classify_frontend_single_detail =
                    SLOT1_DETAIL_FRONTEND_NONCONTIGUOUS;
            else
                classify_frontend_single_detail = SLOT1_DETAIL_NONE;
        end
    endfunction

    function automatic slot1_detail_t classify_pair_raw_detail();
        begin
            if (pair_slot0_alu) begin
                if (pair_slot1_alu)
                    classify_pair_raw_detail =
                        SLOT1_DETAIL_RAW_ALU_TO_ALU;
                else if (pair_slot1_lsu)
                    classify_pair_raw_detail =
                        SLOT1_DETAIL_RAW_ALU_TO_LSU;
                else if (pair_slot1_cfi)
                    classify_pair_raw_detail =
                        SLOT1_DETAIL_RAW_ALU_TO_CFI;
                else
                    classify_pair_raw_detail = SLOT1_DETAIL_RAW_OTHER;
            end else if (pair_slot0_lsu) begin
                classify_pair_raw_detail =
                    SLOT1_DETAIL_RAW_LSU_PRODUCER;
            end else if (pair_slot0_muldiv) begin
                classify_pair_raw_detail =
                    SLOT1_DETAIL_RAW_MULDIV_PRODUCER;
            end else if (pair_slot0_cfi) begin
                classify_pair_raw_detail =
                    SLOT1_DETAIL_RAW_CFI_PRODUCER;
            end else begin
                classify_pair_raw_detail = SLOT1_DETAIL_RAW_OTHER;
            end
        end
    endfunction

    function automatic slot1_detail_t classify_pair_policy_detail();
        logic slot0_supported;
        logic slot1_supported;
        begin
            slot0_supported = pair_slot0_alu | pair_slot0_lsu
                            | pair_slot0_cfi | pair_slot0_muldiv;
            slot1_supported = pair_slot1_alu | pair_slot1_lsu
                            | pair_slot1_cfi;
            if (pair_slot0_force_single | pair_slot1_force_single)
                classify_pair_policy_detail =
                    SLOT1_DETAIL_POLICY_FORCE_SINGLE;
            else if (pair_slot0_lsu & pair_slot1_lsu)
                classify_pair_policy_detail = SLOT1_DETAIL_POLICY_DUAL_LSU;
            else if (pair_slot0_cfi & pair_slot1_cfi)
                classify_pair_policy_detail = SLOT1_DETAIL_POLICY_DUAL_CFI;
            else if (!slot0_supported)
                classify_pair_policy_detail =
                    SLOT1_DETAIL_POLICY_SLOT0_UNSUPPORTED;
            else if (!slot1_supported | pair_slot1_muldiv)
                classify_pair_policy_detail =
                    SLOT1_DETAIL_POLICY_SLOT1_UNSUPPORTED;
            else
                classify_pair_policy_detail = SLOT1_DETAIL_POLICY_OTHER;
        end
    endfunction

    function automatic bubble_cause_t classify_ex_bubble();
        begin
            if (!ex_muldiv_ready)
                classify_ex_bubble = BUBBLE_EX_MULDIV;
            else if (!ex_mmio_order_ready)
                classify_ex_bubble = BUBBLE_EX_MMIO_ORDER;
            else if (!ex_priv_ready)
                classify_ex_bubble = BUBBLE_EX_PRIV_DRAIN;
            else
                classify_ex_bubble = BUBBLE_EX_OTHER;
        end
    endfunction

    function automatic bubble_cause_t classify_mem_bubble();
        begin
            if (dcache_uncached_phase || mem_lsu_uncached)
                classify_mem_bubble = BUBBLE_MEM_UNCACHED;
            else if (dcache_writeback_block_phase)
                classify_mem_bubble = BUBBLE_MEM_DCACHE_WRITEBACK;
            else if (dcache_refill_phase)
                classify_mem_bubble = BUBBLE_MEM_DCACHE_REFILL;
            else if (dcache_busy || mem_lsu_active)
                classify_mem_bubble = BUBBLE_MEM_DCACHE_LOOKUP;
            else
                classify_mem_bubble = BUBBLE_MEM_OTHER;
        end
    endfunction

    function automatic topdown_class_t classify_topdown_bubble(
        input bubble_cause_t cause
    );
        begin
            case (cause)
                BUBBLE_REDIRECT,
                BUBBLE_MACHINE_CLEAR:
                    classify_topdown_bubble = TOPDOWN_BAD_SPECULATION;

                BUBBLE_PIPE_FILL,
                BUBBLE_ICACHE_REFILL,
                BUBBLE_FETCH_RESPONSE,
                BUBBLE_FRONTEND_EMPTY,
                BUBBLE_FRONTEND_BLOCKED,
                BUBBLE_FRONTEND_SINGLE:
                    classify_topdown_bubble = TOPDOWN_FRONTEND_BOUND;

                BUBBLE_ID_PAIR_RAW,
                BUBBLE_ID_PAIR_POLICY,
                BUBBLE_ID_LOAD_EX_ONLY,
                BUBBLE_ID_LOAD_MEM_READY_ONLY,
                BUBBLE_ID_LOAD_MEM_WAIT_ONLY,
                BUBBLE_ID_LOAD_MULTI_SOURCE,
                BUBBLE_ID_LOAD_OTHER,
                BUBBLE_ID_REPAIR_RAW,
                BUBBLE_ID_MULDIV_RAW,
                BUBBLE_ID_MULDIV_STRUCTURE,
                BUBBLE_ID_SERIAL_DRAIN,
                BUBBLE_ID_SERIAL_BARRIER,
                BUBBLE_ID_TIMER_IRQ,
                BUBBLE_ID_OTHER,
                BUBBLE_EX_MULDIV,
                BUBBLE_EX_MMIO_ORDER,
                BUBBLE_EX_PRIV_DRAIN,
                BUBBLE_EX_OTHER,
                BUBBLE_MEM_DCACHE_LOOKUP,
                BUBBLE_MEM_DCACHE_REFILL,
                BUBBLE_MEM_DCACHE_WRITEBACK,
                BUBBLE_MEM_UNCACHED,
                BUBBLE_MEM_OTHER:
                    classify_topdown_bubble = TOPDOWN_BACKEND_BOUND;

                default:
                    classify_topdown_bubble = TOPDOWN_UNCLASSIFIED;
            endcase
        end
    endfunction

    topdown_class_t slot0_topdown_class;
    topdown_class_t slot1_topdown_class;

    always_comb begin
        if (commit0_valid)
            slot0_topdown_class = TOPDOWN_RETIRING;
        else if (wb_valid && wb_exception)
            // Architectural exceptions are the machine-clear member of the
            // bad-speculation family.  Competition perf normally contributes
            // zero here, but assigning it keeps the four-way partition total.
            slot0_topdown_class = TOPDOWN_BAD_SPECULATION;
        else
            slot0_topdown_class = classify_topdown_bubble(wb_bubble_cause);

        if (commit1_valid)
            slot1_topdown_class = TOPDOWN_RETIRING;
        else
            slot1_topdown_class =
                classify_topdown_bubble(wb_s1_bubble_cause);
    end

    function automatic second_level_class_t classify_second_level_bubble(
        input bubble_cause_t cause
    );
        begin
            case (cause)
                BUBBLE_REDIRECT:
                    classify_second_level_bubble = L2_BRANCH_MISPREDICT;
                BUBBLE_MACHINE_CLEAR:
                    classify_second_level_bubble = L2_MACHINE_CLEAR;

                BUBBLE_PIPE_FILL,
                BUBBLE_ICACHE_REFILL,
                BUBBLE_FETCH_RESPONSE,
                BUBBLE_FRONTEND_EMPTY:
                    classify_second_level_bubble = L2_FETCH_LATENCY;
                BUBBLE_FRONTEND_BLOCKED,
                BUBBLE_FRONTEND_SINGLE:
                    classify_second_level_bubble = L2_FETCH_BANDWIDTH;

                BUBBLE_ID_PAIR_RAW,
                BUBBLE_ID_PAIR_POLICY,
                BUBBLE_ID_LOAD_EX_ONLY,
                BUBBLE_ID_LOAD_MEM_READY_ONLY,
                BUBBLE_ID_LOAD_MEM_WAIT_ONLY,
                BUBBLE_ID_LOAD_MULTI_SOURCE,
                BUBBLE_ID_LOAD_OTHER,
                BUBBLE_ID_REPAIR_RAW,
                BUBBLE_ID_MULDIV_RAW,
                BUBBLE_ID_MULDIV_STRUCTURE,
                BUBBLE_ID_SERIAL_DRAIN,
                BUBBLE_ID_SERIAL_BARRIER,
                BUBBLE_ID_TIMER_IRQ,
                BUBBLE_ID_OTHER,
                BUBBLE_EX_MULDIV,
                BUBBLE_EX_PRIV_DRAIN,
                BUBBLE_EX_OTHER:
                    classify_second_level_bubble = L2_CORE_BOUND;

                BUBBLE_EX_MMIO_ORDER,
                BUBBLE_MEM_DCACHE_LOOKUP,
                BUBBLE_MEM_DCACHE_REFILL,
                BUBBLE_MEM_DCACHE_WRITEBACK,
                BUBBLE_MEM_UNCACHED,
                BUBBLE_MEM_OTHER:
                    classify_second_level_bubble = L2_MEMORY_BOUND;

                default:
                    classify_second_level_bubble = L2_UNCLASSIFIED;
            endcase
        end
    endfunction

    second_level_class_t slot0_second_level_class;
    second_level_class_t slot1_second_level_class;

    always_comb begin
        if (commit0_valid)
            slot0_second_level_class = L2_RETIRING;
        else if (wb_valid && wb_exception)
            slot0_second_level_class = L2_MACHINE_CLEAR;
        else
            slot0_second_level_class =
                classify_second_level_bubble(wb_bubble_cause);

        if (commit1_valid)
            slot1_second_level_class = L2_RETIRING;
        else
            slot1_second_level_class =
                classify_second_level_bubble(wb_s1_bubble_cause);
    end

    function automatic core_detail_class_t classify_core_detail_bubble(
        input bubble_cause_t cause
    );
        begin
            case (cause)
                BUBBLE_ID_LOAD_EX_ONLY,
                BUBBLE_ID_LOAD_MEM_READY_ONLY,
                BUBBLE_ID_LOAD_MEM_WAIT_ONLY,
                BUBBLE_ID_LOAD_MULTI_SOURCE,
                BUBBLE_ID_LOAD_OTHER,
                BUBBLE_ID_REPAIR_RAW:
                    classify_core_detail_bubble =
                        CORE_DETAIL_LOAD_REPAIR_DEP;

                BUBBLE_ID_PAIR_RAW:
                    classify_core_detail_bubble = CORE_DETAIL_PAIR_DEP;

                BUBBLE_ID_PAIR_POLICY:
                    classify_core_detail_bubble = CORE_DETAIL_PAIR_POLICY;

                BUBBLE_ID_MULDIV_RAW,
                BUBBLE_ID_MULDIV_STRUCTURE,
                BUBBLE_EX_MULDIV:
                    classify_core_detail_bubble = CORE_DETAIL_MULDIV;

                BUBBLE_ID_SERIAL_DRAIN,
                BUBBLE_ID_SERIAL_BARRIER,
                BUBBLE_ID_TIMER_IRQ,
                BUBBLE_EX_PRIV_DRAIN:
                    classify_core_detail_bubble =
                        CORE_DETAIL_SERIALIZATION;

                BUBBLE_ID_OTHER,
                BUBBLE_EX_OTHER:
                    classify_core_detail_bubble = CORE_DETAIL_OTHER;

                default:
                    classify_core_detail_bubble =
                        CORE_DETAIL_UNCLASSIFIED;
            endcase
        end
    endfunction

    core_detail_class_t slot0_core_detail_class;
    core_detail_class_t slot1_core_detail_class;

    always_comb begin
        if (slot0_second_level_class == L2_CORE_BOUND)
            slot0_core_detail_class =
                classify_core_detail_bubble(wb_bubble_cause);
        else
            slot0_core_detail_class = CORE_DETAIL_NONE;

        if (slot1_second_level_class == L2_CORE_BOUND)
            slot1_core_detail_class =
                classify_core_detail_bubble(wb_s1_bubble_cause);
        else
            slot1_core_detail_class = CORE_DETAIL_NONE;
    end

    task automatic count_root_cause(input bubble_cause_t cause);
        begin
            case (cause)
                BUBBLE_PIPE_FILL:
                    root_pipe_fill <= root_pipe_fill + 1;
                BUBBLE_REDIRECT:
                    root_redirect <= root_redirect + 1;
                BUBBLE_MACHINE_CLEAR:
                    root_redirect <= root_redirect + 1;
                BUBBLE_ICACHE_REFILL:
                    root_icache_refill <= root_icache_refill + 1;
                BUBBLE_FETCH_RESPONSE:
                    root_fetch_response <= root_fetch_response + 1;
                BUBBLE_FRONTEND_EMPTY:
                    root_frontend_empty <= root_frontend_empty + 1;
                BUBBLE_FRONTEND_BLOCKED:
                    root_frontend_blocked <= root_frontend_blocked + 1;
                BUBBLE_ID_LOAD_EX_ONLY,
                BUBBLE_ID_LOAD_MEM_READY_ONLY,
                BUBBLE_ID_LOAD_MEM_WAIT_ONLY,
                BUBBLE_ID_LOAD_MULTI_SOURCE,
                BUBBLE_ID_LOAD_OTHER:
                    root_id_load_raw <= root_id_load_raw + 1;
                BUBBLE_ID_REPAIR_RAW:
                    root_id_repair_raw <= root_id_repair_raw + 1;
                BUBBLE_ID_MULDIV_RAW:
                    root_id_muldiv_raw <= root_id_muldiv_raw + 1;
                BUBBLE_ID_MULDIV_STRUCTURE:
                    root_id_muldiv_structure <= root_id_muldiv_structure + 1;
                BUBBLE_ID_SERIAL_DRAIN:
                    root_id_serial_drain <= root_id_serial_drain + 1;
                BUBBLE_ID_SERIAL_BARRIER:
                    root_id_serial_barrier <= root_id_serial_barrier + 1;
                BUBBLE_ID_TIMER_IRQ:
                    root_id_timer_irq <= root_id_timer_irq + 1;
                BUBBLE_ID_OTHER:
                    root_id_other <= root_id_other + 1;
                BUBBLE_EX_MULDIV:
                    root_ex_muldiv <= root_ex_muldiv + 1;
                BUBBLE_EX_MMIO_ORDER:
                    root_ex_mmio_order <= root_ex_mmio_order + 1;
                BUBBLE_EX_PRIV_DRAIN:
                    root_ex_priv_drain <= root_ex_priv_drain + 1;
                BUBBLE_EX_OTHER:
                    root_ex_other <= root_ex_other + 1;
                BUBBLE_MEM_DCACHE_LOOKUP:
                    root_mem_dcache_lookup <= root_mem_dcache_lookup + 1;
                BUBBLE_MEM_DCACHE_REFILL:
                    root_mem_dcache_refill <= root_mem_dcache_refill + 1;
                BUBBLE_MEM_DCACHE_WRITEBACK:
                    root_mem_dcache_writeback <=
                        root_mem_dcache_writeback + 1;
                BUBBLE_MEM_UNCACHED:
                    root_mem_uncached <= root_mem_uncached + 1;
                BUBBLE_MEM_OTHER:
                    root_mem_other <= root_mem_other + 1;
                default:
                    root_unclassified <= root_unclassified + 1;
            endcase
        end
    endtask

    initial begin
        stop_pc = 32'h1c00_0200;
        uart_putchar_pc = 32'hffff_ffff;
        max_sim_cycles = 0;
        if (!$value$plusargs("perf_stop_pc=%h", stop_pc)) begin end
        if (!$value$plusargs("perf_uart_putchar_pc=%h", uart_putchar_pc)) begin end
        if (!$value$plusargs("perf_max_cycles=%d", max_sim_cycles)) begin end
        icache_trace_fd = 0;
        if ($value$plusargs("perf_icache_trace=%s", icache_trace_path)) begin
            icache_trace_fd = $fopen(icache_trace_path, "w");
            if (icache_trace_fd == 0)
                $fatal(1, "cannot open ICache trace %s", icache_trace_path);
        end
        dcache_trace_fd = 0;
        if ($value$plusargs("perf_dcache_trace=%s", dcache_trace_path)) begin
            dcache_trace_fd = $fopen(dcache_trace_path, "w");
            if (dcache_trace_fd == 0)
                $fatal(1, "cannot open DCache trace %s", dcache_trace_path);
        end
    end

    // Optional compact trace for the explanatory software cache model. The
    // first column marks the exact performance counter window; the second is
    // the 16-byte line address observed by the real lookup pipeline.
    always_ff @(posedge clk) begin
        if (icache_trace_fd != 0 && icache_lookup_valid)
            $fdisplay(icache_trace_fd, "%0d %07x",
                      measurement_active, icache_lookup_line_addr);
    end

    // Cached loads and stores generate exactly one of the four lookup result
    // pulses.  Record the full byte address and access kind so the software
    // model can vary capacity, associativity and line size without changing
    // the production DCache RTL.
    always_ff @(posedge clk) begin
        if (dcache_trace_fd != 0
            && (dcache_load_hit | dcache_load_miss
                | dcache_store_hit | dcache_store_miss))
            $fdisplay(dcache_trace_fd, "%0d %0d %08x",
                      measurement_active,
                      dcache_store_hit | dcache_store_miss,
                      dcache_lookup_addr);
    end

    task automatic emit_results;
        begin
            $display("NSCSCC_PERF_RESULT,general,cycles=%0d,instructions=%0d,commit0_only_cycles=%0d,dual_commit_cycles=%0d,zero_commit_cycles=%0d,retired_loads=%0d,retired_stores=%0d,intervals=%0d,boundaries=%0d",
                cycles, instructions, commit0_only_cycles,
                dual_commit_cycles, zero_commit_cycles, retired_loads,
                retired_stores, intervals, boundaries);
            $display("NSCSCC_PERF_RESULT,topdown,topdown_retiring_slots=%0d,topdown_bad_speculation_slots=%0d,topdown_frontend_bound_slots=%0d,topdown_backend_bound_slots=%0d,topdown_unclassified_slots=%0d",
                topdown_retiring_slots, topdown_bad_speculation_slots,
                topdown_frontend_bound_slots, topdown_backend_bound_slots,
                topdown_unclassified_slots);
            $display("NSCSCC_PERF_RESULT,second_level,l2_retiring_slots=%0d,l2_branch_mispredict_slots=%0d,l2_machine_clear_slots=%0d,l2_fetch_latency_slots=%0d,l2_fetch_bandwidth_slots=%0d,l2_core_bound_slots=%0d,l2_memory_bound_slots=%0d,l2_unclassified_slots=%0d",
                l2_retiring_slots, l2_branch_mispredict_slots,
                l2_machine_clear_slots, l2_fetch_latency_slots,
                l2_fetch_bandwidth_slots, l2_core_bound_slots,
                l2_memory_bound_slots, l2_unclassified_slots);
            $display("NSCSCC_PERF_RESULT,third_level_core,l3_load_repair_dependency_slots=%0d,l3_same_pair_dependency_slots=%0d,l3_pairing_policy_slots=%0d,l3_muldiv_slots=%0d,l3_serialization_slots=%0d,l3_other_core_slots=%0d,l3_unclassified_core_slots=%0d",
                l3_load_repair_dependency_slots,
                l3_same_pair_dependency_slots,
                l3_pairing_policy_slots, l3_muldiv_slots,
                l3_serialization_slots, l3_other_core_slots,
                l3_unclassified_core_slots);
            $display("NSCSCC_PERF_RESULT,fourth_level_fetch,l4_fetch_pipe_fill_slots=%0d,l4_fetch_icache_refill_slots=%0d,l4_fetch_response_slots=%0d,l4_fetch_empty_slots=%0d,l4_fetch_blocked_slots=%0d,l4_fetch_single_taken_slots=%0d,l4_fetch_single_no_second_slots=%0d,l4_fetch_single_noncontiguous_slots=%0d,l4_fetch_single_unclassified_slots=%0d",
                l4_fetch_pipe_fill_slots,
                l4_fetch_icache_refill_slots,
                l4_fetch_response_slots, l4_fetch_empty_slots,
                l4_fetch_blocked_slots, l4_fetch_single_taken_slots,
                l4_fetch_single_no_second_slots,
                l4_fetch_single_noncontiguous_slots,
                l4_fetch_single_unclassified_slots);
            $display("NSCSCC_PERF_RESULT,fifth_level_taken,l5_fetch_taken_target_pairable_slots=%0d,l5_fetch_taken_target_available_blocked_slots=%0d,l5_fetch_taken_target_unavailable_slots=%0d",
                l5_fetch_taken_target_pairable_slots,
                l5_fetch_taken_target_available_blocked_slots,
                l5_fetch_taken_target_unavailable_slots);
            $display("NSCSCC_PERF_RESULT,fourth_level_load,l4_load_raw_slots=%0d,l4_repair_raw_slots=%0d",
                l4_load_raw_slots, l4_repair_raw_slots);
            $display("NSCSCC_PERF_RESULT,fifth_level_load,l5_load_ex_only_slots=%0d,l5_load_mem_ready_only_slots=%0d,l5_load_mem_wait_only_slots=%0d,l5_load_multi_source_slots=%0d,l5_load_other_slots=%0d",
                l5_load_ex_only_slots,
                l5_load_mem_ready_only_slots,
                l5_load_mem_wait_only_slots,
                l5_load_multi_source_slots, l5_load_other_slots);
            $display("NSCSCC_PERF_RESULT,repaired_control,repaired_control_executions=%0d,repaired_control_redirects=%0d",
                repaired_control_executions,
                repaired_control_redirects);
            $display("NSCSCC_PERF_RESULT,fourth_level_pair_raw,l4_pair_raw_alu_to_alu_slots=%0d,l4_pair_raw_alu_to_lsu_slots=%0d,l4_pair_raw_alu_to_cfi_slots=%0d,l4_pair_raw_lsu_producer_slots=%0d,l4_pair_raw_muldiv_producer_slots=%0d,l4_pair_raw_cfi_producer_slots=%0d,l4_pair_raw_other_slots=%0d,l4_pair_raw_unclassified_slots=%0d",
                l4_pair_raw_alu_to_alu_slots,
                l4_pair_raw_alu_to_lsu_slots,
                l4_pair_raw_alu_to_cfi_slots,
                l4_pair_raw_lsu_producer_slots,
                l4_pair_raw_muldiv_producer_slots,
                l4_pair_raw_cfi_producer_slots,
                l4_pair_raw_other_slots,
                l4_pair_raw_unclassified_slots);
            $display("NSCSCC_PERF_RESULT,fourth_level_pair_policy,l4_pair_policy_force_single_slots=%0d,l4_pair_policy_dual_lsu_slots=%0d,l4_pair_policy_dual_cfi_slots=%0d,l4_pair_policy_slot0_unsupported_slots=%0d,l4_pair_policy_slot1_unsupported_slots=%0d,l4_pair_policy_other_slots=%0d,l4_pair_policy_unclassified_slots=%0d",
                l4_pair_policy_force_single_slots,
                l4_pair_policy_dual_lsu_slots,
                l4_pair_policy_dual_cfi_slots,
                l4_pair_policy_slot0_unsupported_slots,
                l4_pair_policy_slot1_unsupported_slots,
                l4_pair_policy_other_slots,
                l4_pair_policy_unclassified_slots);
            $display("NSCSCC_PERF_RESULT,stalls,cycles_icache_busy=%0d,cycles_dcache_busy=%0d,cycles_muldiv_busy=%0d,cycles_load_hazard=%0d,cycles_non_load_hazard=%0d,cycles_mem_backpressure=%0d,cycles_ftq_empty=%0d,cycles_fq_empty=%0d,cycles_ftq_full=%0d,cycles_fq_full=%0d,pair_candidate_cycles=%0d,pair_raw_block_cycles=%0d",
                cycles_icache_busy, cycles_dcache_busy, cycles_muldiv_busy,
                cycles_load_hazard, cycles_non_load_hazard,
                cycles_mem_backpressure, cycles_ftq_empty, cycles_fq_empty,
                cycles_ftq_full, cycles_fq_full, pair_candidate_cycles,
                pair_raw_block_cycles);
            $display("NSCSCC_PERF_RESULT,no_commit,no_commit_redirect=%0d,no_commit_dcache=%0d,no_commit_icache=%0d,no_commit_muldiv=%0d,no_commit_hazard=%0d,no_commit_frontend_empty=%0d,no_commit_other=%0d",
                no_commit_redirect, no_commit_dcache, no_commit_icache,
                no_commit_muldiv, no_commit_hazard,
                no_commit_frontend_empty, no_commit_other);
            $display("NSCSCC_PERF_RESULT,root_frontend,root_pipe_fill=%0d,root_redirect=%0d,root_icache_refill=%0d,root_fetch_response=%0d,root_frontend_empty=%0d,root_frontend_blocked=%0d",
                root_pipe_fill, root_redirect, root_icache_refill,
                root_fetch_response, root_frontend_empty,
                root_frontend_blocked);
            $display("NSCSCC_PERF_RESULT,root_backend,root_id_load_raw=%0d,root_id_repair_raw=%0d,root_id_muldiv_raw=%0d,root_id_muldiv_structure=%0d,root_id_serial_drain=%0d,root_id_serial_barrier=%0d,root_id_timer_irq=%0d,root_id_other=%0d,root_ex_muldiv=%0d,root_ex_mmio_order=%0d,root_ex_priv_drain=%0d,root_ex_other=%0d,root_mem_dcache_lookup=%0d,root_mem_dcache_refill=%0d,root_mem_dcache_writeback=%0d,root_mem_uncached=%0d,root_mem_other=%0d,root_exception=%0d,root_unclassified=%0d",
                root_id_load_raw, root_id_repair_raw,
                root_id_muldiv_raw, root_id_muldiv_structure,
                root_id_serial_drain, root_id_serial_barrier,
                root_id_timer_irq, root_id_other, root_ex_muldiv,
                root_ex_mmio_order, root_ex_priv_drain, root_ex_other,
                root_mem_dcache_lookup, root_mem_dcache_refill,
                root_mem_dcache_writeback, root_mem_uncached,
                root_mem_other, root_exception, root_unclassified);
            $display("NSCSCC_PERF_RESULT,predictor,redirects=%0d,conditional_updates=%0d,conditional_wrong=%0d,direct_controls=%0d,indirect_controls=%0d,abtb_updates=%0d,abtb_hit_updates=%0d,abtb_allocations=%0d",
                redirects, conditional_updates, conditional_wrong,
                direct_controls, indirect_controls, abtb_updates,
                abtb_hit_updates, abtb_allocations);
            $display("NSCSCC_PERF_RESULT,icache,icache_requests=%0d,icache_hits=%0d,icache_refill_hits=%0d,icache_misses=%0d,icache_refill_requests=%0d,icache_refill_beats=%0d,icache_refill_completions=%0d,icache_kills=%0d",
                icache_requests, icache_hits, icache_refill_hits,
                icache_misses, icache_refill_requests, icache_refill_beats,
                icache_refill_completions, icache_kills);
            $display("NSCSCC_PERF_RESULT,icache_3c,icache_compulsory_misses=%0d,icache_conflict_misses=%0d,icache_capacity_misses=%0d,icache_outside_misses=%0d,icache_3c_unclassified_misses=%0d,icache_compulsory_refill_requests=%0d,icache_conflict_refill_requests=%0d,icache_capacity_refill_requests=%0d,icache_outside_refill_requests=%0d,icache_3c_unclassified_refill_requests=%0d,icache_compulsory_refill_slots=%0d,icache_conflict_refill_slots=%0d,icache_capacity_refill_slots=%0d,icache_outside_refill_slots=%0d,icache_3c_unclassified_refill_slots=%0d",
                icache_compulsory_misses, icache_conflict_misses,
                icache_capacity_misses, icache_outside_misses,
                icache_3c_unclassified_misses,
                icache_compulsory_refill_requests,
                icache_conflict_refill_requests,
                icache_capacity_refill_requests,
                icache_outside_refill_requests,
                icache_3c_unclassified_refill_requests,
                icache_compulsory_refill_slots,
                icache_conflict_refill_slots,
                icache_capacity_refill_slots,
                icache_outside_refill_slots,
                icache_3c_unclassified_refill_slots);
            $display("NSCSCC_PERF_RESULT,dcache,dcache_load_hits=%0d,dcache_load_misses=%0d,dcache_store_hits=%0d,dcache_store_misses=%0d,dcache_uncached_requests=%0d,dcache_dirty_victims=%0d,dcache_refill_requests=%0d,dcache_refill_beats=%0d,dcache_refill_target_beats=%0d,dcache_refill_completions=%0d,dcache_writeback_requests=%0d,dcache_writeback_beats=%0d,dcache_writeback_responses=%0d,cycles_refill_wb_overlap=%0d",
                dcache_load_hits, dcache_load_misses, dcache_store_hits,
                dcache_store_misses, dcache_uncached_requests,
                dcache_dirty_victims, dcache_refill_requests,
                dcache_refill_beats, dcache_refill_target_beats,
                dcache_refill_completions, dcache_writeback_requests,
                dcache_writeback_beats, dcache_writeback_responses,
                cycles_refill_wb_overlap);
            $display("NSCSCC_PERF_RESULT,early_dcache,early_accepted_loads=%0d,early_addr_safe_loads=%0d,early_addr_aggressive_loads=%0d,early_addr_ex_forward_loads=%0d,early_addr_repair_blocked_loads=%0d,early_grant_safe_loads=%0d,early_grant_aggressive_loads=%0d,early_block_internal_safe=%0d,early_block_internal_aggressive=%0d,early_block_fallback_safe=%0d,early_block_fallback_aggressive=%0d,early_hit_safe_loads=%0d,early_hit_aggressive_loads=%0d,early_raw_ex_events=%0d,early_raw_repairable_events=%0d,early_raw_role_alu=%0d,early_raw_role_load_addr=%0d,early_raw_role_store_addr=%0d,early_raw_role_store_data=%0d,early_raw_role_branch=%0d,early_raw_role_jirl=%0d,early_raw_role_other=%0d,early_raw_hit_safe_all=%0d,early_raw_hit_aggressive_all=%0d,early_raw_hit_safe_all_no_store=%0d,early_raw_hit_aggressive_all_no_store=%0d,early_raw_hit_safe_v1=%0d,early_raw_hit_aggressive_v1=%0d,early_raw_hit_safe_v1_no_store=%0d,early_raw_hit_aggressive_v1_no_store=%0d,early_store_load_overlaps=%0d,early_store_load_same_word=%0d,early_store_load_diff_word=%0d,early_store_same_word_hit_safe=%0d,early_store_same_word_hit_aggressive=%0d",
                early_accepted_loads, early_addr_safe_loads,
                early_addr_aggressive_loads,
                early_addr_ex_forward_loads,
                early_addr_repair_blocked_loads,
                early_grant_safe_loads, early_grant_aggressive_loads,
                early_block_internal_safe,
                early_block_internal_aggressive,
                early_block_fallback_safe,
                early_block_fallback_aggressive,
                early_hit_safe_loads, early_hit_aggressive_loads,
                early_raw_ex_events, early_raw_repairable_events,
                early_raw_role_alu, early_raw_role_load_addr,
                early_raw_role_store_addr, early_raw_role_store_data,
                early_raw_role_branch, early_raw_role_jirl,
                early_raw_role_other, early_raw_hit_safe_all,
                early_raw_hit_aggressive_all,
                early_raw_hit_safe_all_no_store,
                early_raw_hit_aggressive_all_no_store,
                early_raw_hit_safe_v1,
                early_raw_hit_aggressive_v1,
                early_raw_hit_safe_v1_no_store,
                early_raw_hit_aggressive_v1_no_store,
                early_store_load_overlaps,
                early_store_load_same_word,
                early_store_load_diff_word,
                early_store_same_word_hit_safe,
                early_store_same_word_hit_aggressive);
            $display("NSCSCC_PERF_RESULT,raw_branch_detail,early_raw_branch_load_byte=%0d,early_raw_branch_load_half=%0d,early_raw_branch_load_word=%0d,early_raw_branch_op_eq=%0d,early_raw_branch_op_ne=%0d,early_raw_branch_op_lt=%0d,early_raw_branch_op_ge=%0d,early_raw_branch_op_ltu=%0d,early_raw_branch_op_geu=%0d,early_raw_branch_byte_eqne=%0d,early_raw_branch_half_eqne=%0d,early_raw_branch_word_eqne=%0d,early_raw_branch_hit=%0d,early_raw_branch_byte_eqne_hit=%0d,early_raw_branch_half_eqne_hit=%0d,early_raw_branch_word_eqne_hit=%0d",
                early_raw_branch_load_byte,
                early_raw_branch_load_half,
                early_raw_branch_load_word,
                early_raw_branch_op_eq,
                early_raw_branch_op_ne,
                early_raw_branch_op_lt,
                early_raw_branch_op_ge,
                early_raw_branch_op_ltu,
                early_raw_branch_op_geu,
                early_raw_branch_byte_eqne,
                early_raw_branch_half_eqne,
                early_raw_branch_word_eqne,
                early_raw_branch_hit,
                early_raw_branch_byte_eqne_hit,
                early_raw_branch_half_eqne_hit,
                early_raw_branch_word_eqne_hit);
            $display("NSCSCC_PERF_RESULT,axi,axi_read_requests_i=%0d,axi_read_requests_d=%0d,axi_read_requests_other=%0d,axi_read_beats_i=%0d,axi_read_beats_d=%0d,axi_ar_stall_cycles=%0d,axi_r_gap_cycles=%0d,axi_both_read_outstanding_cycles=%0d,axi_write_requests=%0d,axi_write_beats=%0d,axi_write_responses=%0d,axi_i_first_latency_sum=%0d,axi_i_first_latency_max=%0d,axi_i_first_latency_samples=%0d,axi_d_first_latency_sum=%0d,axi_d_first_latency_max=%0d,axi_d_first_latency_samples=%0d,axi_pending_at_interval_end=%0d",
                axi_read_requests_i, axi_read_requests_d,
                axi_read_requests_other, axi_read_beats_i, axi_read_beats_d,
                axi_ar_stall_cycles, axi_r_gap_cycles,
                axi_both_read_outstanding_cycles, axi_write_requests,
                axi_write_beats, axi_write_responses,
                axi_i_first_latency_sum, axi_i_first_latency_max,
                axi_i_first_latency_samples, axi_d_first_latency_sum,
                axi_d_first_latency_max, axi_d_first_latency_samples,
                axi_pending_at_interval_end);
            $display("NSCSCC_PERF_DONE,pass=%0d,measurement_active=%0d,stop_pc=%08x,led=%04x,led_rg0=%0d,led_rg1=%0d,simulation_cycles=%0d",
                benchmark_pass, measurement_active, stop_pc, led, led_rg0,
                led_rg1, simulation_cycles);
        end
    endtask

    // Advance the hypothetical prelookup ownership beside the real pipeline.
    // These valid bits are intentionally independent of the measurement
    // counters: an out-of-window token may still occupy the modeled read port,
    // while the measured bit prevents it from contributing a hit later.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_prelookup_safe <= 1'b0;
            ex_prelookup_aggressive <= 1'b0;
            ex_prelookup_measured <= 1'b0;
            mem_prelookup_safe <= 1'b0;
            mem_prelookup_aggressive <= 1'b0;
            mem_prelookup_measured <= 1'b0;
            mem_raw_event <= 1'b0;
            mem_raw_repairable <= 1'b0;
            mem_raw_measured <= 1'b0;
            mem_raw_branch <= 1'b0;
            mem_raw_branch_byte_eqne <= 1'b0;
            mem_raw_branch_half_eqne <= 1'b0;
            mem_raw_branch_word_eqne <= 1'b0;
            mem_store_same_word <= 1'b0;
        end else begin
            if (ex_allowin) begin
                ex_prelookup_safe <= id_prelookup_safe_grant;
                ex_prelookup_aggressive <=
                    id_prelookup_aggressive_grant;
                ex_prelookup_measured <= measurement_active
                                       & id_any_load_fire;
            end
            if (mem_allowin) begin
                mem_prelookup_safe <= ex_any_load & ex_prelookup_safe;
                mem_prelookup_aggressive <=
                    ex_any_load & ex_prelookup_aggressive;
                mem_prelookup_measured <= ex_any_load
                                        & ex_prelookup_measured;
                mem_raw_event <= id_raw_ex_event;
                mem_raw_repairable <= id_raw_repairable_event;
                mem_raw_measured <= measurement_active & id_raw_ex_event;
                mem_raw_branch <= id_raw_role_branch;
                mem_raw_branch_byte_eqne <= id_raw_branch_byte_eqne;
                mem_raw_branch_half_eqne <= id_raw_branch_half_eqne;
                mem_raw_branch_word_eqne <= id_raw_branch_word_eqne;
                mem_store_same_word <= ex_store_load_same_word;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            simulation_cycles <= 0;
            measurement_active <= 1'b0;
            boundaries <= 0;
            intervals <= 0;
            cycles <= 0;
            instructions <= 0;
            commit0_only_cycles <= 0;
            dual_commit_cycles <= 0;
            zero_commit_cycles <= 0;
            retired_loads <= 0;
            retired_stores <= 0;
            cycles_icache_busy <= 0;
            cycles_dcache_busy <= 0;
            cycles_muldiv_busy <= 0;
            cycles_load_hazard <= 0;
            cycles_non_load_hazard <= 0;
            cycles_mem_backpressure <= 0;
            cycles_ftq_empty <= 0;
            cycles_fq_empty <= 0;
            cycles_ftq_full <= 0;
            cycles_fq_full <= 0;
            pair_candidate_cycles <= 0;
            pair_raw_block_cycles <= 0;
            no_commit_redirect <= 0;
            no_commit_dcache <= 0;
            no_commit_icache <= 0;
            no_commit_muldiv <= 0;
            no_commit_hazard <= 0;
            no_commit_frontend_empty <= 0;
            no_commit_other <= 0;
            id_bubble_cause <= BUBBLE_PIPE_FILL;
            ex_bubble_cause <= BUBBLE_PIPE_FILL;
            mem_bubble_cause <= BUBBLE_PIPE_FILL;
            wb_bubble_cause <= BUBBLE_PIPE_FILL;
            id_s1_bubble_cause <= BUBBLE_PIPE_FILL;
            ex_s1_bubble_cause <= BUBBLE_PIPE_FILL;
            mem_s1_bubble_cause <= BUBBLE_PIPE_FILL;
            wb_s1_bubble_cause <= BUBBLE_PIPE_FILL;
            id_icache_3c_class <= ICACHE_3C_NONE;
            ex_icache_3c_class <= ICACHE_3C_NONE;
            mem_icache_3c_class <= ICACHE_3C_NONE;
            wb_icache_3c_class <= ICACHE_3C_NONE;
            id_s1_icache_3c_class <= ICACHE_3C_NONE;
            ex_s1_icache_3c_class <= ICACHE_3C_NONE;
            mem_s1_icache_3c_class <= ICACHE_3C_NONE;
            wb_s1_icache_3c_class <= ICACHE_3C_NONE;
            id_s1_detail <= SLOT1_DETAIL_NONE;
            ex_s1_detail <= SLOT1_DETAIL_NONE;
            mem_s1_detail <= SLOT1_DETAIL_NONE;
            wb_s1_detail <= SLOT1_DETAIL_NONE;
            topdown_retiring_slots <= 0;
            topdown_bad_speculation_slots <= 0;
            topdown_frontend_bound_slots <= 0;
            topdown_backend_bound_slots <= 0;
            topdown_unclassified_slots <= 0;
            l2_retiring_slots <= 0;
            l2_branch_mispredict_slots <= 0;
            l2_machine_clear_slots <= 0;
            l2_fetch_latency_slots <= 0;
            l2_fetch_bandwidth_slots <= 0;
            l2_core_bound_slots <= 0;
            l2_memory_bound_slots <= 0;
            l2_unclassified_slots <= 0;
            l3_load_repair_dependency_slots <= 0;
            l3_same_pair_dependency_slots <= 0;
            l3_pairing_policy_slots <= 0;
            l3_muldiv_slots <= 0;
            l3_serialization_slots <= 0;
            l3_other_core_slots <= 0;
            l3_unclassified_core_slots <= 0;
            l4_fetch_pipe_fill_slots <= 0;
            l4_fetch_icache_refill_slots <= 0;
            l4_fetch_response_slots <= 0;
            l4_fetch_empty_slots <= 0;
            l4_fetch_blocked_slots <= 0;
            l4_fetch_single_taken_slots <= 0;
            l5_fetch_taken_target_pairable_slots <= 0;
            l5_fetch_taken_target_available_blocked_slots <= 0;
            l5_fetch_taken_target_unavailable_slots <= 0;
            l4_fetch_single_no_second_slots <= 0;
            l4_fetch_single_noncontiguous_slots <= 0;
            l4_fetch_single_unclassified_slots <= 0;
            l4_load_raw_slots <= 0;
            l4_repair_raw_slots <= 0;
            l5_load_ex_only_slots <= 0;
            l5_load_mem_ready_only_slots <= 0;
            l5_load_mem_wait_only_slots <= 0;
            l5_load_multi_source_slots <= 0;
            l5_load_other_slots <= 0;
            repaired_control_executions <= 0;
            repaired_control_redirects <= 0;
            l4_pair_raw_alu_to_alu_slots <= 0;
            l4_pair_raw_alu_to_lsu_slots <= 0;
            l4_pair_raw_alu_to_cfi_slots <= 0;
            l4_pair_raw_lsu_producer_slots <= 0;
            l4_pair_raw_muldiv_producer_slots <= 0;
            l4_pair_raw_cfi_producer_slots <= 0;
            l4_pair_raw_other_slots <= 0;
            l4_pair_raw_unclassified_slots <= 0;
            l4_pair_policy_force_single_slots <= 0;
            l4_pair_policy_dual_lsu_slots <= 0;
            l4_pair_policy_dual_cfi_slots <= 0;
            l4_pair_policy_slot0_unsupported_slots <= 0;
            l4_pair_policy_slot1_unsupported_slots <= 0;
            l4_pair_policy_other_slots <= 0;
            l4_pair_policy_unclassified_slots <= 0;
            root_pipe_fill <= 0;
            root_redirect <= 0;
            root_icache_refill <= 0;
            root_fetch_response <= 0;
            root_frontend_empty <= 0;
            root_frontend_blocked <= 0;
            root_id_load_raw <= 0;
            root_id_repair_raw <= 0;
            root_id_muldiv_raw <= 0;
            root_id_muldiv_structure <= 0;
            root_id_serial_drain <= 0;
            root_id_serial_barrier <= 0;
            root_id_timer_irq <= 0;
            root_id_other <= 0;
            root_ex_muldiv <= 0;
            root_ex_mmio_order <= 0;
            root_ex_priv_drain <= 0;
            root_ex_other <= 0;
            root_mem_dcache_lookup <= 0;
            root_mem_dcache_refill <= 0;
            root_mem_dcache_writeback <= 0;
            root_mem_uncached <= 0;
            root_mem_other <= 0;
            root_exception <= 0;
            root_unclassified <= 0;
            redirects <= 0;
            conditional_updates <= 0;
            conditional_wrong <= 0;
            direct_controls <= 0;
            indirect_controls <= 0;
            abtb_updates <= 0;
            abtb_hit_updates <= 0;
            abtb_allocations <= 0;
            icache_requests <= 0;
            icache_hits <= 0;
            icache_refill_hits <= 0;
            icache_misses <= 0;
            icache_refill_requests <= 0;
            icache_refill_beats <= 0;
            icache_refill_completions <= 0;
            icache_kills <= 0;
            icache_compulsory_misses <= 0;
            icache_conflict_misses <= 0;
            icache_capacity_misses <= 0;
            icache_outside_misses <= 0;
            icache_3c_unclassified_misses <= 0;
            icache_compulsory_refill_requests <= 0;
            icache_conflict_refill_requests <= 0;
            icache_capacity_refill_requests <= 0;
            icache_outside_refill_requests <= 0;
            icache_3c_unclassified_refill_requests <= 0;
            icache_compulsory_refill_slots <= 0;
            icache_conflict_refill_slots <= 0;
            icache_capacity_refill_slots <= 0;
            icache_outside_refill_slots <= 0;
            icache_3c_unclassified_refill_slots <= 0;
            dcache_load_hits <= 0;
            dcache_load_misses <= 0;
            dcache_store_hits <= 0;
            dcache_store_misses <= 0;
            dcache_uncached_requests <= 0;
            dcache_dirty_victims <= 0;
            dcache_refill_requests <= 0;
            dcache_refill_beats <= 0;
            dcache_refill_target_beats <= 0;
            dcache_refill_completions <= 0;
            dcache_writeback_requests <= 0;
            dcache_writeback_beats <= 0;
            dcache_writeback_responses <= 0;
            cycles_refill_wb_overlap <= 0;
            early_accepted_loads <= 0;
            early_addr_safe_loads <= 0;
            early_addr_aggressive_loads <= 0;
            early_addr_ex_forward_loads <= 0;
            early_addr_repair_blocked_loads <= 0;
            early_grant_safe_loads <= 0;
            early_grant_aggressive_loads <= 0;
            early_block_internal_safe <= 0;
            early_block_internal_aggressive <= 0;
            early_block_fallback_safe <= 0;
            early_block_fallback_aggressive <= 0;
            early_hit_safe_loads <= 0;
            early_hit_aggressive_loads <= 0;
            early_raw_ex_events <= 0;
            early_raw_repairable_events <= 0;
            early_raw_role_alu <= 0;
            early_raw_role_load_addr <= 0;
            early_raw_role_store_addr <= 0;
            early_raw_role_store_data <= 0;
            early_raw_role_branch <= 0;
            early_raw_role_jirl <= 0;
            early_raw_role_other <= 0;
            early_raw_branch_load_byte <= 0;
            early_raw_branch_load_half <= 0;
            early_raw_branch_load_word <= 0;
            early_raw_branch_op_eq <= 0;
            early_raw_branch_op_ne <= 0;
            early_raw_branch_op_lt <= 0;
            early_raw_branch_op_ge <= 0;
            early_raw_branch_op_ltu <= 0;
            early_raw_branch_op_geu <= 0;
            early_raw_branch_byte_eqne <= 0;
            early_raw_branch_half_eqne <= 0;
            early_raw_branch_word_eqne <= 0;
            early_raw_branch_hit <= 0;
            early_raw_branch_byte_eqne_hit <= 0;
            early_raw_branch_half_eqne_hit <= 0;
            early_raw_branch_word_eqne_hit <= 0;
            early_raw_hit_safe_all <= 0;
            early_raw_hit_aggressive_all <= 0;
            early_raw_hit_safe_all_no_store <= 0;
            early_raw_hit_aggressive_all_no_store <= 0;
            early_raw_hit_safe_v1 <= 0;
            early_raw_hit_aggressive_v1 <= 0;
            early_raw_hit_safe_v1_no_store <= 0;
            early_raw_hit_aggressive_v1_no_store <= 0;
            early_store_load_overlaps <= 0;
            early_store_load_same_word <= 0;
            early_store_load_diff_word <= 0;
            early_store_same_word_hit_safe <= 0;
            early_store_same_word_hit_aggressive <= 0;
            axi_read_requests_i <= 0;
            axi_read_requests_d <= 0;
            axi_read_requests_other <= 0;
            axi_read_beats_i <= 0;
            axi_read_beats_d <= 0;
            axi_ar_stall_cycles <= 0;
            axi_r_gap_cycles <= 0;
            axi_both_read_outstanding_cycles <= 0;
            axi_write_requests <= 0;
            axi_write_beats <= 0;
            axi_write_responses <= 0;
            axi_i_first_latency_sum <= 0;
            axi_i_first_latency_max <= 0;
            axi_i_first_latency_samples <= 0;
            axi_d_first_latency_sum <= 0;
            axi_d_first_latency_max <= 0;
            axi_d_first_latency_samples <= 0;
            axi_pending_at_interval_end <= 0;
            read_pending_i <= 1'b0;
            read_pending_d <= 1'b0;
            first_pending_i <= 1'b0;
            first_pending_d <= 1'b0;
            read_age_i <= 0;
            read_age_d <= 0;
        end else begin
            simulation_cycles <= simulation_cycles + 1;

            // Mirror the Slot-0 valid pipeline.  A valid token carries no
            // bubble; an invalid token carries the reason it was first
            // created, including across later holds and stage transfers.
            if (redirect)
                id_bubble_cause <= redirect_machine_clear
                                 ? BUBBLE_MACHINE_CLEAR
                                 : BUBBLE_REDIRECT;
            else if (id_allowin) begin
                if (if_valid && if_ready_go)
                    id_bubble_cause <= BUBBLE_NONE;
                else
                    id_bubble_cause <= classify_frontend_bubble();
            end

            if (redirect)
                id_s1_bubble_cause <= redirect_machine_clear
                                    ? BUBBLE_MACHINE_CLEAR
                                    : BUBBLE_REDIRECT;
            else if (id_allowin) begin
                if (if_valid && if_ready_go) begin
                    if (pair_candidate)
                        id_s1_bubble_cause <= BUBBLE_NONE;
                    else if (pair_frontend_limited)
                        // The second correct-path instruction was not available
                        // as a contiguous member of this fetch group.
                        id_s1_bubble_cause <= BUBBLE_FRONTEND_SINGLE;
                    else if (pair_raw_sole_blocker)
                        // Removing this RAW restriction alone would make the
                        // already available pair legal.  Keep this separate
                        // from pairs that also violate a class/policy rule.
                        id_s1_bubble_cause <= BUBBLE_ID_PAIR_RAW;
                    else
                        id_s1_bubble_cause <= BUBBLE_ID_PAIR_POLICY;
                end else begin
                    id_s1_bubble_cause <= classify_frontend_bubble();
                end
            end

            if (redirect)
                ex_bubble_cause <= redirect_machine_clear
                                 ? BUBBLE_MACHINE_CLEAR
                                 : BUBBLE_REDIRECT;
            else if (ex_allowin) begin
                if (id_valid && id_ready_go)
                    ex_bubble_cause <= BUBBLE_NONE;
                else if (id_valid)
                    ex_bubble_cause <= classify_id_bubble();
                else
                    ex_bubble_cause <= id_bubble_cause;
            end

            if (redirect)
                ex_s1_bubble_cause <= redirect_machine_clear
                                    ? BUBBLE_MACHINE_CLEAR
                                    : BUBBLE_REDIRECT;
            else if (ex_allowin) begin
                if (id_valid && id_ready_go) begin
                    if (id_s1_valid_probe)
                        ex_s1_bubble_cause <= BUBBLE_NONE;
                    else
                        ex_s1_bubble_cause <= id_s1_bubble_cause;
                end else if (id_valid) begin
                    ex_s1_bubble_cause <= classify_id_bubble();
                end else begin
                    ex_s1_bubble_cause <= id_s1_bubble_cause;
                end
            end

            if (mem_allowin) begin
                if (mem_redirect_valid)
                    mem_bubble_cause <= mem_redirect_machine_clear
                                      ? BUBBLE_MACHINE_CLEAR
                                      : BUBBLE_REDIRECT;
                else if (ex_valid && ex_ready_go)
                    mem_bubble_cause <= BUBBLE_NONE;
                else if (ex_valid)
                    mem_bubble_cause <= classify_ex_bubble();
                else
                    mem_bubble_cause <= ex_bubble_cause;
            end

            if (mem_allowin) begin
                if (ex_s1_flush)
                    mem_s1_bubble_cause <= ex_s1_flush_machine_clear
                                         ? BUBBLE_MACHINE_CLEAR
                                         : BUBBLE_REDIRECT;
                else if (ex_s1_valid && ex_ready_go)
                    mem_s1_bubble_cause <= BUBBLE_NONE;
                else if (ex_valid && !ex_ready_go)
                    mem_s1_bubble_cause <= classify_ex_bubble();
                else
                    mem_s1_bubble_cause <= ex_s1_bubble_cause;
            end

            if (wb_allowin) begin
                if (mem_valid && mem_ready_go)
                    wb_bubble_cause <= BUBBLE_NONE;
                else if (mem_valid)
                    wb_bubble_cause <= classify_mem_bubble();
                else
                    wb_bubble_cause <= mem_bubble_cause;
            end

            if (wb_allowin) begin
                if (mem_valid && mem_ready_go) begin
                    if (mem_s1_valid)
                        wb_s1_bubble_cause <= BUBBLE_NONE;
                    else
                        wb_s1_bubble_cause <= mem_s1_bubble_cause;
                end else if (mem_valid) begin
                    wb_s1_bubble_cause <= classify_mem_bubble();
                end else begin
                    wb_s1_bubble_cause <= mem_s1_bubble_cause;
                end
            end

            // Carry the 3C class only with bubbles created by an active
            // ICache refill.  All valid tokens and bubbles replaced by a
            // later-stage cause clear the detail tag.
            if (redirect) begin
                id_icache_3c_class <= ICACHE_3C_NONE;
                id_s1_icache_3c_class <= ICACHE_3C_NONE;
            end else if (id_allowin) begin
                if (!(if_valid && if_ready_go)
                    && (classify_frontend_bubble()
                        == BUBBLE_ICACHE_REFILL)) begin
                    id_icache_3c_class <= active_icache_3c_class_q;
                    id_s1_icache_3c_class <= active_icache_3c_class_q;
                end else begin
                    id_icache_3c_class <= ICACHE_3C_NONE;
                    id_s1_icache_3c_class <= ICACHE_3C_NONE;
                end
            end

            if (redirect) begin
                ex_icache_3c_class <= ICACHE_3C_NONE;
            end else if (ex_allowin) begin
                if (!id_valid
                    && (id_bubble_cause == BUBBLE_ICACHE_REFILL))
                    ex_icache_3c_class <= id_icache_3c_class;
                else
                    ex_icache_3c_class <= ICACHE_3C_NONE;
            end

            if (redirect) begin
                ex_s1_icache_3c_class <= ICACHE_3C_NONE;
            end else if (ex_allowin) begin
                if (id_valid && id_ready_go) begin
                    if (!id_s1_valid_probe
                        && (id_s1_bubble_cause
                            == BUBBLE_ICACHE_REFILL))
                        ex_s1_icache_3c_class <= id_s1_icache_3c_class;
                    else
                        ex_s1_icache_3c_class <= ICACHE_3C_NONE;
                end else if (id_valid) begin
                    ex_s1_icache_3c_class <= ICACHE_3C_NONE;
                end else if (id_s1_bubble_cause
                             == BUBBLE_ICACHE_REFILL) begin
                    ex_s1_icache_3c_class <= id_s1_icache_3c_class;
                end else begin
                    ex_s1_icache_3c_class <= ICACHE_3C_NONE;
                end
            end

            if (mem_allowin) begin
                if (!mem_redirect_valid && !ex_valid
                    && (ex_bubble_cause == BUBBLE_ICACHE_REFILL))
                    mem_icache_3c_class <= ex_icache_3c_class;
                else
                    mem_icache_3c_class <= ICACHE_3C_NONE;

                if (!ex_s1_flush
                    && !(ex_s1_valid && ex_ready_go)
                    && !(ex_valid && !ex_ready_go)
                    && (ex_s1_bubble_cause == BUBBLE_ICACHE_REFILL))
                    mem_s1_icache_3c_class <= ex_s1_icache_3c_class;
                else
                    mem_s1_icache_3c_class <= ICACHE_3C_NONE;
            end

            if (wb_allowin) begin
                if (!mem_valid
                    && (mem_bubble_cause == BUBBLE_ICACHE_REFILL))
                    wb_icache_3c_class <= mem_icache_3c_class;
                else
                    wb_icache_3c_class <= ICACHE_3C_NONE;

                if (mem_valid && mem_ready_go) begin
                    if (!mem_s1_valid
                        && (mem_s1_bubble_cause
                            == BUBBLE_ICACHE_REFILL))
                        wb_s1_icache_3c_class <=
                            mem_s1_icache_3c_class;
                    else
                        wb_s1_icache_3c_class <= ICACHE_3C_NONE;
                end else if (mem_valid) begin
                    wb_s1_icache_3c_class <= ICACHE_3C_NONE;
                end else if (mem_s1_bubble_cause
                             == BUBBLE_ICACHE_REFILL) begin
                    wb_s1_icache_3c_class <= mem_s1_icache_3c_class;
                end else begin
                    wb_s1_icache_3c_class <= ICACHE_3C_NONE;
                end
            end

            // Mirror the Slot-1 detail only while its owning frontend/pairing
            // bubble survives.  Any later redirect or backend-created bubble
            // clears the detail instead of attributing the wrong root cause.
            if (redirect) begin
                id_s1_detail <= SLOT1_DETAIL_NONE;
            end else if (id_allowin) begin
                if (if_valid && if_ready_go) begin
                    if (pair_candidate)
                        id_s1_detail <= SLOT1_DETAIL_NONE;
                    else if (pair_frontend_limited)
                        id_s1_detail <= classify_frontend_single_detail();
                    else if (pair_raw_sole_blocker)
                        id_s1_detail <= classify_pair_raw_detail();
                    else
                        id_s1_detail <= classify_pair_policy_detail();
                end else begin
                    id_s1_detail <= SLOT1_DETAIL_NONE;
                end
            end

            if (redirect) begin
                ex_s1_detail <= SLOT1_DETAIL_NONE;
            end else if (ex_allowin) begin
                if (id_valid && id_ready_go) begin
                    if (id_s1_valid_probe)
                        ex_s1_detail <= SLOT1_DETAIL_NONE;
                    else
                        ex_s1_detail <= id_s1_detail;
                end else if (id_valid) begin
                    ex_s1_detail <= SLOT1_DETAIL_NONE;
                end else begin
                    ex_s1_detail <= id_s1_detail;
                end
            end

            if (mem_allowin) begin
                if (ex_s1_flush) begin
                    mem_s1_detail <= SLOT1_DETAIL_NONE;
                end else if (ex_s1_valid && ex_ready_go) begin
                    mem_s1_detail <= SLOT1_DETAIL_NONE;
                end else if (ex_valid && !ex_ready_go) begin
                    mem_s1_detail <= SLOT1_DETAIL_NONE;
                end else begin
                    mem_s1_detail <= ex_s1_detail;
                end
            end

            if (wb_allowin) begin
                if (mem_valid && mem_ready_go) begin
                    if (mem_s1_valid)
                        wb_s1_detail <= SLOT1_DETAIL_NONE;
                    else
                        wb_s1_detail <= mem_s1_detail;
                end else if (mem_valid) begin
                    wb_s1_detail <= SLOT1_DETAIL_NONE;
                end else begin
                    wb_s1_detail <= mem_s1_detail;
                end
            end

            if ((max_sim_cycles != 0)
                && (simulation_cycles >= max_sim_cycles)) begin
                $display("NSCSCC_PERF_TIMEOUT,simulation_cycles=%0d,commit0_valid=%0d,commit0_pc=%08x,commit1_valid=%0d,commit1_pc=%08x,boundaries=%0d,measurement_active=%0d",
                         simulation_cycles, commit0_valid, commit0_pc,
                         commit1_valid, commit1_pc, boundaries,
                         measurement_active);
                emit_results();
                $finish;
            end

            if (measurement_active
                && ((commit0_valid && (commit0_pc == uart_putchar_pc))
                 || (commit1_valid && (commit1_pc == uart_putchar_pc)))) begin
                $display("NSCSCC_PERF_INVALID_TIMED_UART,pc=%08x",
                         uart_putchar_pc);
                $finish;
            end

            // Count the closing RDCNTVL commit, matching the architectural
            // trace models; the opening marker only enables the interval.
            if (measurement_active) begin
                cycles <= cycles + 1;
                instructions <= instructions
                              + (commit0_valid ? 1 : 0)
                              + (commit1_valid ? 1 : 0);
                topdown_retiring_slots <= topdown_retiring_slots
                    + ((slot0_topdown_class == TOPDOWN_RETIRING) ? 1 : 0)
                    + ((slot1_topdown_class == TOPDOWN_RETIRING) ? 1 : 0);
                topdown_bad_speculation_slots <=
                    topdown_bad_speculation_slots
                    + ((slot0_topdown_class == TOPDOWN_BAD_SPECULATION)
                       ? 1 : 0)
                    + ((slot1_topdown_class == TOPDOWN_BAD_SPECULATION)
                       ? 1 : 0);
                topdown_frontend_bound_slots <= topdown_frontend_bound_slots
                    + ((slot0_topdown_class == TOPDOWN_FRONTEND_BOUND) ? 1 : 0)
                    + ((slot1_topdown_class == TOPDOWN_FRONTEND_BOUND) ? 1 : 0);
                topdown_backend_bound_slots <= topdown_backend_bound_slots
                    + ((slot0_topdown_class == TOPDOWN_BACKEND_BOUND) ? 1 : 0)
                    + ((slot1_topdown_class == TOPDOWN_BACKEND_BOUND) ? 1 : 0);
                topdown_unclassified_slots <= topdown_unclassified_slots
                    + ((slot0_topdown_class == TOPDOWN_UNCLASSIFIED) ? 1 : 0)
                    + ((slot1_topdown_class == TOPDOWN_UNCLASSIFIED) ? 1 : 0);
                l2_retiring_slots <= l2_retiring_slots
                    + ((slot0_second_level_class == L2_RETIRING) ? 1 : 0)
                    + ((slot1_second_level_class == L2_RETIRING) ? 1 : 0);
                l2_branch_mispredict_slots <= l2_branch_mispredict_slots
                    + ((slot0_second_level_class == L2_BRANCH_MISPREDICT)
                       ? 1 : 0)
                    + ((slot1_second_level_class == L2_BRANCH_MISPREDICT)
                       ? 1 : 0);
                l2_machine_clear_slots <= l2_machine_clear_slots
                    + ((slot0_second_level_class == L2_MACHINE_CLEAR) ? 1 : 0)
                    + ((slot1_second_level_class == L2_MACHINE_CLEAR) ? 1 : 0);
                l2_fetch_latency_slots <= l2_fetch_latency_slots
                    + ((slot0_second_level_class == L2_FETCH_LATENCY) ? 1 : 0)
                    + ((slot1_second_level_class == L2_FETCH_LATENCY) ? 1 : 0);
                l2_fetch_bandwidth_slots <= l2_fetch_bandwidth_slots
                    + ((slot0_second_level_class == L2_FETCH_BANDWIDTH) ? 1 : 0)
                    + ((slot1_second_level_class == L2_FETCH_BANDWIDTH) ? 1 : 0);
                l2_core_bound_slots <= l2_core_bound_slots
                    + ((slot0_second_level_class == L2_CORE_BOUND) ? 1 : 0)
                    + ((slot1_second_level_class == L2_CORE_BOUND) ? 1 : 0);
                l2_memory_bound_slots <= l2_memory_bound_slots
                    + ((slot0_second_level_class == L2_MEMORY_BOUND) ? 1 : 0)
                    + ((slot1_second_level_class == L2_MEMORY_BOUND) ? 1 : 0);
                l2_unclassified_slots <= l2_unclassified_slots
                    + ((slot0_second_level_class == L2_UNCLASSIFIED) ? 1 : 0)
                    + ((slot1_second_level_class == L2_UNCLASSIFIED) ? 1 : 0);
                l3_load_repair_dependency_slots <=
                    l3_load_repair_dependency_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_LOAD_REPAIR_DEP) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_LOAD_REPAIR_DEP) ? 1 : 0);
                l3_same_pair_dependency_slots <=
                    l3_same_pair_dependency_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_PAIR_DEP) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_PAIR_DEP) ? 1 : 0);
                l3_pairing_policy_slots <= l3_pairing_policy_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_PAIR_POLICY) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_PAIR_POLICY) ? 1 : 0);
                l3_muldiv_slots <= l3_muldiv_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_MULDIV) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_MULDIV) ? 1 : 0);
                l3_serialization_slots <= l3_serialization_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_SERIALIZATION) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_SERIALIZATION) ? 1 : 0);
                l3_other_core_slots <= l3_other_core_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_OTHER) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_OTHER) ? 1 : 0);
                l3_unclassified_core_slots <= l3_unclassified_core_slots
                    + ((slot0_core_detail_class
                        == CORE_DETAIL_UNCLASSIFIED) ? 1 : 0)
                    + ((slot1_core_detail_class
                        == CORE_DETAIL_UNCLASSIFIED) ? 1 : 0);
                l4_fetch_pipe_fill_slots <= l4_fetch_pipe_fill_slots
                    + ((wb_bubble_cause == BUBBLE_PIPE_FILL) ? 1 : 0)
                    + ((wb_s1_bubble_cause == BUBBLE_PIPE_FILL) ? 1 : 0);
                l4_fetch_icache_refill_slots <=
                    l4_fetch_icache_refill_slots
                    + ((wb_bubble_cause == BUBBLE_ICACHE_REFILL) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ICACHE_REFILL) ? 1 : 0);
                icache_compulsory_refill_slots <=
                    icache_compulsory_refill_slots
                    + (((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_icache_3c_class
                            == ICACHE_3C_COMPULSORY)) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_s1_icache_3c_class
                            == ICACHE_3C_COMPULSORY)) ? 1 : 0);
                icache_conflict_refill_slots <=
                    icache_conflict_refill_slots
                    + (((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_icache_3c_class
                            == ICACHE_3C_CONFLICT)) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_s1_icache_3c_class
                            == ICACHE_3C_CONFLICT)) ? 1 : 0);
                icache_capacity_refill_slots <=
                    icache_capacity_refill_slots
                    + (((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_icache_3c_class
                            == ICACHE_3C_CAPACITY)) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_s1_icache_3c_class
                            == ICACHE_3C_CAPACITY)) ? 1 : 0);
                icache_outside_refill_slots <=
                    icache_outside_refill_slots
                    + (((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_icache_3c_class
                            == ICACHE_3C_OUTSIDE)) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_s1_icache_3c_class
                            == ICACHE_3C_OUTSIDE)) ? 1 : 0);
                icache_3c_unclassified_refill_slots <=
                    icache_3c_unclassified_refill_slots
                    + (((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_icache_3c_class == ICACHE_3C_NONE)) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                        && (wb_s1_icache_3c_class
                            == ICACHE_3C_NONE)) ? 1 : 0);
                l4_fetch_response_slots <= l4_fetch_response_slots
                    + ((wb_bubble_cause == BUBBLE_FETCH_RESPONSE) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_FETCH_RESPONSE) ? 1 : 0);
                l4_fetch_empty_slots <= l4_fetch_empty_slots
                    + ((wb_bubble_cause == BUBBLE_FRONTEND_EMPTY) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_FRONTEND_EMPTY) ? 1 : 0);
                l4_fetch_blocked_slots <= l4_fetch_blocked_slots
                    + ((wb_bubble_cause == BUBBLE_FRONTEND_BLOCKED) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_FRONTEND_BLOCKED) ? 1 : 0);
                l4_fetch_single_taken_slots <=
                    l4_fetch_single_taken_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && ((wb_s1_detail
                             == SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE)
                            || (wb_s1_detail
                                == SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED)
                            || (wb_s1_detail
                                == SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE)))
                       ? 1 : 0);
                l5_fetch_taken_target_pairable_slots <=
                    l5_fetch_taken_target_pairable_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE))
                       ? 1 : 0);
                l5_fetch_taken_target_available_blocked_slots <=
                    l5_fetch_taken_target_available_blocked_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED))
                       ? 1 : 0);
                l5_fetch_taken_target_unavailable_slots <=
                    l5_fetch_taken_target_unavailable_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE))
                       ? 1 : 0);
                l4_fetch_single_no_second_slots <=
                    l4_fetch_single_no_second_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_FRONTEND_NO_SECOND)) ? 1 : 0);
                l4_fetch_single_noncontiguous_slots <=
                    l4_fetch_single_noncontiguous_slots
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_FRONTEND_NONCONTIGUOUS)) ? 1 : 0);
                l4_fetch_single_unclassified_slots <=
                    l4_fetch_single_unclassified_slots
                    + ((wb_bubble_cause == BUBBLE_FRONTEND_SINGLE) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                        && !((wb_s1_detail
                              == SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_FRONTEND_NO_SECOND)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_FRONTEND_NONCONTIGUOUS)))
                       ? 1 : 0);
                l4_load_raw_slots <= l4_load_raw_slots
                    + (((wb_bubble_cause == BUBBLE_ID_LOAD_EX_ONLY)
                        || (wb_bubble_cause
                            == BUBBLE_ID_LOAD_MEM_READY_ONLY)
                        || (wb_bubble_cause
                            == BUBBLE_ID_LOAD_MEM_WAIT_ONLY)
                        || (wb_bubble_cause
                            == BUBBLE_ID_LOAD_MULTI_SOURCE)
                        || (wb_bubble_cause == BUBBLE_ID_LOAD_OTHER))
                       ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ID_LOAD_EX_ONLY)
                        || (wb_s1_bubble_cause
                            == BUBBLE_ID_LOAD_MEM_READY_ONLY)
                        || (wb_s1_bubble_cause
                            == BUBBLE_ID_LOAD_MEM_WAIT_ONLY)
                        || (wb_s1_bubble_cause
                            == BUBBLE_ID_LOAD_MULTI_SOURCE)
                        || (wb_s1_bubble_cause == BUBBLE_ID_LOAD_OTHER))
                       ? 1 : 0);
                l5_load_ex_only_slots <= l5_load_ex_only_slots
                    + ((wb_bubble_cause == BUBBLE_ID_LOAD_EX_ONLY) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ID_LOAD_EX_ONLY) ? 1 : 0);
                l5_load_mem_ready_only_slots <=
                    l5_load_mem_ready_only_slots
                    + ((wb_bubble_cause
                        == BUBBLE_ID_LOAD_MEM_READY_ONLY) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ID_LOAD_MEM_READY_ONLY) ? 1 : 0);
                l5_load_mem_wait_only_slots <=
                    l5_load_mem_wait_only_slots
                    + ((wb_bubble_cause
                        == BUBBLE_ID_LOAD_MEM_WAIT_ONLY) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ID_LOAD_MEM_WAIT_ONLY) ? 1 : 0);
                l5_load_multi_source_slots <= l5_load_multi_source_slots
                    + ((wb_bubble_cause
                        == BUBBLE_ID_LOAD_MULTI_SOURCE) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ID_LOAD_MULTI_SOURCE) ? 1 : 0);
                l5_load_other_slots <= l5_load_other_slots
                    + ((wb_bubble_cause == BUBBLE_ID_LOAD_OTHER) ? 1 : 0)
                    + ((wb_s1_bubble_cause
                        == BUBBLE_ID_LOAD_OTHER) ? 1 : 0);
                l4_repair_raw_slots <= l4_repair_raw_slots
                    + ((wb_bubble_cause == BUBBLE_ID_REPAIR_RAW) ? 1 : 0)
                    + ((wb_s1_bubble_cause == BUBBLE_ID_REPAIR_RAW) ? 1 : 0);
                l4_pair_raw_alu_to_alu_slots <=
                    l4_pair_raw_alu_to_alu_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_ALU_TO_ALU)) ? 1 : 0);
                l4_pair_raw_alu_to_lsu_slots <=
                    l4_pair_raw_alu_to_lsu_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_ALU_TO_LSU)) ? 1 : 0);
                l4_pair_raw_alu_to_cfi_slots <=
                    l4_pair_raw_alu_to_cfi_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_ALU_TO_CFI)) ? 1 : 0);
                l4_pair_raw_lsu_producer_slots <=
                    l4_pair_raw_lsu_producer_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_LSU_PRODUCER)) ? 1 : 0);
                l4_pair_raw_muldiv_producer_slots <=
                    l4_pair_raw_muldiv_producer_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_MULDIV_PRODUCER)) ? 1 : 0);
                l4_pair_raw_cfi_producer_slots <=
                    l4_pair_raw_cfi_producer_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_RAW_CFI_PRODUCER)) ? 1 : 0);
                l4_pair_raw_other_slots <= l4_pair_raw_other_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && (wb_s1_detail == SLOT1_DETAIL_RAW_OTHER)) ? 1 : 0);
                l4_pair_raw_unclassified_slots <=
                    l4_pair_raw_unclassified_slots
                    + ((wb_bubble_cause == BUBBLE_ID_PAIR_RAW) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && !((wb_s1_detail
                              == SLOT1_DETAIL_RAW_ALU_TO_ALU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_ALU_TO_LSU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_ALU_TO_CFI)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_LSU_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_MULDIV_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_CFI_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_OTHER))) ? 1 : 0);
                l4_pair_policy_force_single_slots <=
                    l4_pair_policy_force_single_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_POLICY_FORCE_SINGLE)) ? 1 : 0);
                l4_pair_policy_dual_lsu_slots <=
                    l4_pair_policy_dual_lsu_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_POLICY_DUAL_LSU)) ? 1 : 0);
                l4_pair_policy_dual_cfi_slots <=
                    l4_pair_policy_dual_cfi_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_POLICY_DUAL_CFI)) ? 1 : 0);
                l4_pair_policy_slot0_unsupported_slots <=
                    l4_pair_policy_slot0_unsupported_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_POLICY_SLOT0_UNSUPPORTED))
                       ? 1 : 0);
                l4_pair_policy_slot1_unsupported_slots <=
                    l4_pair_policy_slot1_unsupported_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail
                            == SLOT1_DETAIL_POLICY_SLOT1_UNSUPPORTED))
                       ? 1 : 0);
                l4_pair_policy_other_slots <= l4_pair_policy_other_slots
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && (wb_s1_detail == SLOT1_DETAIL_POLICY_OTHER))
                       ? 1 : 0);
                l4_pair_policy_unclassified_slots <=
                    l4_pair_policy_unclassified_slots
                    + ((wb_bubble_cause == BUBBLE_ID_PAIR_POLICY) ? 1 : 0)
                    + (((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && !((wb_s1_detail
                              == SLOT1_DETAIL_POLICY_FORCE_SINGLE)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_DUAL_LSU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_DUAL_CFI)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_SLOT0_UNSUPPORTED)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_SLOT1_UNSUPPORTED)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_OTHER))) ? 1 : 0);
                if (dual_commit)
                    dual_commit_cycles <= dual_commit_cycles + 1;
                else if (any_commit)
                    commit0_only_cycles <= commit0_only_cycles + 1;
                else
                    zero_commit_cycles <= zero_commit_cycles + 1;
                retired_loads <= retired_loads
                               + (commit0_valid && commit0_load ? 1 : 0)
                               + (commit1_valid && commit1_load ? 1 : 0);
                retired_stores <= retired_stores
                                + (commit0_valid && commit0_store ? 1 : 0)
                                + (commit1_valid && commit1_store ? 1 : 0);

                if (icache_busy) cycles_icache_busy <= cycles_icache_busy + 1;
                if (dcache_busy) cycles_dcache_busy <= cycles_dcache_busy + 1;
                if (muldiv_busy) cycles_muldiv_busy <= cycles_muldiv_busy + 1;
                if (ex_control_repair_valid)
                    repaired_control_executions <=
                        repaired_control_executions + 1;
                if (ex_control_repair_redirect)
                    repaired_control_redirects <=
                        repaired_control_redirects + 1;
                if (id_load_hazard) cycles_load_hazard <= cycles_load_hazard + 1;
                if (id_non_load_hazard)
                    cycles_non_load_hazard <= cycles_non_load_hazard + 1;
                if (mem_backpressure)
                    cycles_mem_backpressure <= cycles_mem_backpressure + 1;
                if (ftq_count == 0) cycles_ftq_empty <= cycles_ftq_empty + 1;
                if (fq_count == 0) cycles_fq_empty <= cycles_fq_empty + 1;
                if (ftq_count == 8) cycles_ftq_full <= cycles_ftq_full + 1;
                if (fq_count == 8) cycles_fq_full <= cycles_fq_full + 1;
                if (pair_candidate)
                    pair_candidate_cycles <= pair_candidate_cycles + 1;
                if (pair_raw_block)
                    pair_raw_block_cycles <= pair_raw_block_cycles + 1;

                if (!any_commit) begin
                    // Unlike the legacy snapshot buckets below, this is the
                    // causal, pipeline-aligned partition.  An exception owns
                    // a real WB token but is intentionally absent from the
                    // architectural commit trace.
                    if (wb_valid && wb_exception)
                        root_exception <= root_exception + 1;
                    else
                        count_root_cause(wb_bubble_cause);

                    if (redirect)
                        no_commit_redirect <= no_commit_redirect + 1;
                    else if (dcache_busy)
                        no_commit_dcache <= no_commit_dcache + 1;
                    else if (icache_busy)
                        no_commit_icache <= no_commit_icache + 1;
                    else if (muldiv_busy)
                        no_commit_muldiv <= no_commit_muldiv + 1;
                    else if (id_load_hazard | id_non_load_hazard)
                        no_commit_hazard <= no_commit_hazard + 1;
                    else if ((fq_count == 0) | (!if_valid & !id_valid
                             & !ex_valid & !mem_valid & !wb_valid
                             & !ex_s1_valid & !mem_s1_valid & !wb_s1_valid))
                        no_commit_frontend_empty <=
                            no_commit_frontend_empty + 1;
                    else
                        no_commit_other <= no_commit_other + 1;
                end

                if (redirect) redirects <= redirects + 1;
                if (pht_update_valid) begin
                    conditional_updates <= conditional_updates + 1;
                    if (pht_update_counter[1] != pht_update_taken)
                        conditional_wrong <= conditional_wrong + 1;
                end
                if (pred_train_valid && pred_train_direct)
                    direct_controls <= direct_controls + 1;
                if (pred_train_valid && pred_train_indirect)
                    indirect_controls <= indirect_controls + 1;
                if (abtb_update_valid) begin
                    abtb_updates <= abtb_updates + 1;
                    if (abtb_update_hit)
                        abtb_hit_updates <= abtb_hit_updates + 1;
                    else
                        abtb_allocations <= abtb_allocations + 1;
                end

                if (icache_req_fire) icache_requests <= icache_requests + 1;
                if (icache_lookup_hit) icache_hits <= icache_hits + 1;
                if (icache_lookup_hit && icache_lookup_refill_hit)
                    icache_refill_hits <= icache_refill_hits + 1;
                if (icache_lookup_miss) begin
                    icache_misses <= icache_misses + 1;
                    case (icache_lookup_3c_class)
                        ICACHE_3C_COMPULSORY:
                            icache_compulsory_misses <=
                                icache_compulsory_misses + 1;
                        ICACHE_3C_CONFLICT:
                            icache_conflict_misses <=
                                icache_conflict_misses + 1;
                        ICACHE_3C_CAPACITY:
                            icache_capacity_misses <=
                                icache_capacity_misses + 1;
                        ICACHE_3C_OUTSIDE:
                            icache_outside_misses <=
                                icache_outside_misses + 1;
                        default:
                            icache_3c_unclassified_misses <=
                                icache_3c_unclassified_misses + 1;
                    endcase
                end
                if (icache_refill_req_fire) begin
                    icache_refill_requests <= icache_refill_requests + 1;
                    case (active_icache_3c_class_q)
                        ICACHE_3C_COMPULSORY:
                            icache_compulsory_refill_requests <=
                                icache_compulsory_refill_requests + 1;
                        ICACHE_3C_CONFLICT:
                            icache_conflict_refill_requests <=
                                icache_conflict_refill_requests + 1;
                        ICACHE_3C_CAPACITY:
                            icache_capacity_refill_requests <=
                                icache_capacity_refill_requests + 1;
                        ICACHE_3C_OUTSIDE:
                            icache_outside_refill_requests <=
                                icache_outside_refill_requests + 1;
                        default:
                            icache_3c_unclassified_refill_requests <=
                                icache_3c_unclassified_refill_requests + 1;
                    endcase
                end
                if (icache_refill_data_fire)
                    icache_refill_beats <= icache_refill_beats + 1;
                if (icache_refill_complete)
                    icache_refill_completions <=
                        icache_refill_completions + 1;
                if (icache_kill) icache_kills <= icache_kills + 1;

                if (dcache_load_hit) dcache_load_hits <= dcache_load_hits + 1;
                if (dcache_load_miss)
                    dcache_load_misses <= dcache_load_misses + 1;
                if (dcache_store_hit)
                    dcache_store_hits <= dcache_store_hits + 1;
                if (dcache_store_miss)
                    dcache_store_misses <= dcache_store_misses + 1;
                if (dcache_uncached_start)
                    dcache_uncached_requests <= dcache_uncached_requests + 1;
                if (dcache_dirty_victim)
                    dcache_dirty_victims <= dcache_dirty_victims + 1;
                if (dcache_refill_req_fire)
                    dcache_refill_requests <= dcache_refill_requests + 1;
                if (dcache_refill_data_fire)
                    dcache_refill_beats <= dcache_refill_beats + 1;
                if (dcache_refill_target_fire)
                    dcache_refill_target_beats <=
                        dcache_refill_target_beats + 1;
                if (dcache_refill_complete)
                    dcache_refill_completions <=
                        dcache_refill_completions + 1;
                if (dcache_wb_req_fire)
                    dcache_writeback_requests <=
                        dcache_writeback_requests + 1;
                if (dcache_wb_data_fire)
                    dcache_writeback_beats <= dcache_writeback_beats + 1;
                if (dcache_wb_resp_fire)
                    dcache_writeback_responses <=
                        dcache_writeback_responses + 1;
                if (dcache_refill_wb_overlap)
                    cycles_refill_wb_overlap <= cycles_refill_wb_overlap + 1;

                // Prospective ID-address / EX-data DCache lookup.  The two
                // policies share the same one-read-port priority model:
                // victim/replay work, then an EX fallback lookup, then ID.
                if (id_any_load_fire)
                    early_accepted_loads <= early_accepted_loads + 1;
                if (id_load_addr_safe)
                    early_addr_safe_loads <= early_addr_safe_loads + 1;
                if (id_load_addr_aggressive)
                    early_addr_aggressive_loads <=
                        early_addr_aggressive_loads + 1;
                if (id_load_addr_ex_forward)
                    early_addr_ex_forward_loads <=
                        early_addr_ex_forward_loads + 1;
                if (id_load_addr_repair_blocked)
                    early_addr_repair_blocked_loads <=
                        early_addr_repair_blocked_loads + 1;
                if (id_prelookup_safe_grant)
                    early_grant_safe_loads <= early_grant_safe_loads + 1;
                if (id_prelookup_aggressive_grant)
                    early_grant_aggressive_loads <=
                        early_grant_aggressive_loads + 1;
                if (id_block_internal_safe)
                    early_block_internal_safe <=
                        early_block_internal_safe + 1;
                if (id_block_internal_aggressive)
                    early_block_internal_aggressive <=
                        early_block_internal_aggressive + 1;
                if (id_block_fallback_safe)
                    early_block_fallback_safe <=
                        early_block_fallback_safe + 1;
                if (id_block_fallback_aggressive)
                    early_block_fallback_aggressive <=
                        early_block_fallback_aggressive + 1;

                if (id_raw_ex_event) begin
                    early_raw_ex_events <= early_raw_ex_events + 1;
                    if (id_raw_repairable_event)
                        early_raw_repairable_events <=
                            early_raw_repairable_events + 1;
                    if (id_raw_role_alu)
                        early_raw_role_alu <= early_raw_role_alu + 1;
                    if (id_raw_role_load_addr)
                        early_raw_role_load_addr <=
                            early_raw_role_load_addr + 1;
                    if (id_raw_role_store_addr)
                        early_raw_role_store_addr <=
                            early_raw_role_store_addr + 1;
                    if (id_raw_role_store_data)
                        early_raw_role_store_data <=
                            early_raw_role_store_data + 1;
                    if (id_raw_role_branch)
                        early_raw_role_branch <= early_raw_role_branch + 1;
                    if (id_raw_role_branch & ex_raw_load_byte)
                        early_raw_branch_load_byte <=
                            early_raw_branch_load_byte + 1;
                    if (id_raw_role_branch & ex_raw_load_half)
                        early_raw_branch_load_half <=
                            early_raw_branch_load_half + 1;
                    if (id_raw_role_branch & ex_raw_load_word)
                        early_raw_branch_load_word <=
                            early_raw_branch_load_word + 1;
                    if (id_raw_branch_op_eq)
                        early_raw_branch_op_eq <=
                            early_raw_branch_op_eq + 1;
                    if (id_raw_branch_op_ne)
                        early_raw_branch_op_ne <=
                            early_raw_branch_op_ne + 1;
                    if (id_raw_branch_op_lt)
                        early_raw_branch_op_lt <=
                            early_raw_branch_op_lt + 1;
                    if (id_raw_branch_op_ge)
                        early_raw_branch_op_ge <=
                            early_raw_branch_op_ge + 1;
                    if (id_raw_branch_op_ltu)
                        early_raw_branch_op_ltu <=
                            early_raw_branch_op_ltu + 1;
                    if (id_raw_branch_op_geu)
                        early_raw_branch_op_geu <=
                            early_raw_branch_op_geu + 1;
                    if (id_raw_branch_byte_eqne)
                        early_raw_branch_byte_eqne <=
                            early_raw_branch_byte_eqne + 1;
                    if (id_raw_branch_half_eqne)
                        early_raw_branch_half_eqne <=
                            early_raw_branch_half_eqne + 1;
                    if (id_raw_branch_word_eqne)
                        early_raw_branch_word_eqne <=
                            early_raw_branch_word_eqne + 1;
                    if (id_raw_role_jirl)
                        early_raw_role_jirl <= early_raw_role_jirl + 1;
                    if (id_raw_role_other)
                        early_raw_role_other <= early_raw_role_other + 1;
                end

                // store_cache_write is on BRAM Port A and the prospective
                // load is on Port B. Different words are independent; an
                // identical word is the deliberately conservative replay case.
                if (ex_allowin && ex_store_load_overlap) begin
                    early_store_load_overlaps <=
                        early_store_load_overlaps + 1;
                    if (ex_store_load_same_word)
                        early_store_load_same_word <=
                            early_store_load_same_word + 1;
                    else
                        early_store_load_diff_word <=
                            early_store_load_diff_word + 1;
                end

                // The existing DCache hit arrives one stage after the EX RAW
                // event.  Qualifying here excludes misses from the projected
                // one-cycle saving and keeps collision penalties hit-only.
                if (dcache_load_hit && mem_prelookup_measured) begin
                    if (mem_prelookup_safe)
                        early_hit_safe_loads <= early_hit_safe_loads + 1;
                    if (mem_prelookup_aggressive)
                        early_hit_aggressive_loads <=
                            early_hit_aggressive_loads + 1;
                    if (mem_store_same_word && mem_prelookup_safe)
                        early_store_same_word_hit_safe <=
                            early_store_same_word_hit_safe + 1;
                    if (mem_store_same_word && mem_prelookup_aggressive)
                        early_store_same_word_hit_aggressive <=
                            early_store_same_word_hit_aggressive + 1;
                end
                if (dcache_load_hit && mem_raw_measured
                    && mem_raw_event) begin
                    if (mem_raw_branch)
                        early_raw_branch_hit <=
                            early_raw_branch_hit + 1;
                    if (mem_raw_branch_byte_eqne)
                        early_raw_branch_byte_eqne_hit <=
                            early_raw_branch_byte_eqne_hit + 1;
                    if (mem_raw_branch_half_eqne)
                        early_raw_branch_half_eqne_hit <=
                            early_raw_branch_half_eqne_hit + 1;
                    if (mem_raw_branch_word_eqne)
                        early_raw_branch_word_eqne_hit <=
                            early_raw_branch_word_eqne_hit + 1;
                    if (mem_prelookup_safe) begin
                        early_raw_hit_safe_all <=
                            early_raw_hit_safe_all + 1;
                        if (!mem_store_same_word)
                            early_raw_hit_safe_all_no_store <=
                                early_raw_hit_safe_all_no_store + 1;
                    end
                    if (mem_prelookup_aggressive) begin
                        early_raw_hit_aggressive_all <=
                            early_raw_hit_aggressive_all + 1;
                        if (!mem_store_same_word)
                            early_raw_hit_aggressive_all_no_store <=
                                early_raw_hit_aggressive_all_no_store + 1;
                    end
                    if (mem_raw_repairable) begin
                        if (mem_prelookup_safe) begin
                            early_raw_hit_safe_v1 <=
                                early_raw_hit_safe_v1 + 1;
                            if (!mem_store_same_word)
                                early_raw_hit_safe_v1_no_store <=
                                    early_raw_hit_safe_v1_no_store + 1;
                        end
                        if (mem_prelookup_aggressive) begin
                            early_raw_hit_aggressive_v1 <=
                                early_raw_hit_aggressive_v1 + 1;
                            if (!mem_store_same_word)
                                early_raw_hit_aggressive_v1_no_store <=
                                    early_raw_hit_aggressive_v1_no_store + 1;
                        end
                    end
                end

                if (arvalid && !arready)
                    axi_ar_stall_cycles <= axi_ar_stall_cycles + 1;
                if ((read_pending_i | read_pending_d) && !rvalid)
                    axi_r_gap_cycles <= axi_r_gap_cycles + 1;
                if (read_pending_i && read_pending_d)
                    axi_both_read_outstanding_cycles <=
                        axi_both_read_outstanding_cycles + 1;
                if (aw_fire) axi_write_requests <= axi_write_requests + 1;
                if (w_fire) axi_write_beats <= axi_write_beats + 1;
                if (b_fire) axi_write_responses <= axi_write_responses + 1;

                if (read_pending_i) read_age_i <= read_age_i + 1;
                if (read_pending_d) read_age_d <= read_age_d + 1;
                if (ar_fire) begin
                    case (arid)
                        4'h0: begin
                            axi_read_requests_i <= axi_read_requests_i + 1;
                            read_pending_i <= 1'b1;
                            first_pending_i <= 1'b1;
                            read_age_i <= 0;
                        end
                        4'h1: begin
                            axi_read_requests_d <= axi_read_requests_d + 1;
                            read_pending_d <= 1'b1;
                            first_pending_d <= 1'b1;
                            read_age_d <= 0;
                        end
                        default:
                            axi_read_requests_other <=
                                axi_read_requests_other + 1;
                    endcase
                end
                if (r_fire) begin
                    if (rid == 4'h0) begin
                        axi_read_beats_i <= axi_read_beats_i + 1;
                        if (first_pending_i) begin
                            axi_i_first_latency_sum <=
                                axi_i_first_latency_sum + read_age_i + 1;
                            axi_i_first_latency_samples <=
                                axi_i_first_latency_samples + 1;
                            if ((read_age_i + 1) > axi_i_first_latency_max)
                                axi_i_first_latency_max <= read_age_i + 1;
                            first_pending_i <= 1'b0;
                        end
                        if (rlast) begin
                            read_pending_i <= 1'b0;
                            first_pending_i <= 1'b0;
                        end
                    end else if (rid == 4'h1) begin
                        axi_read_beats_d <= axi_read_beats_d + 1;
                        if (first_pending_d) begin
                            axi_d_first_latency_sum <=
                                axi_d_first_latency_sum + read_age_d + 1;
                            axi_d_first_latency_samples <=
                                axi_d_first_latency_samples + 1;
                            if ((read_age_d + 1) > axi_d_first_latency_max)
                                axi_d_first_latency_max <= read_age_d + 1;
                            first_pending_d <= 1'b0;
                        end
                        if (rlast) begin
                            read_pending_d <= 1'b0;
                            first_pending_d <= 1'b0;
                        end
                    end
                end
            end

            if (counter_boundary) begin
                boundaries <= boundaries + 1;
                if (measurement_active) begin
                    measurement_active <= 1'b0;
                    intervals <= intervals + 1;
                    axi_pending_at_interval_end <=
                        axi_pending_at_interval_end
                        + (read_pending_i ? 1 : 0)
                        + (read_pending_d ? 1 : 0);
                end else begin
                    measurement_active <= 1'b1;
                    // Do not attribute a transaction which began in printf or
                    // another unmeasured gap to the next benchmark interval.
                    read_pending_i <= 1'b0;
                    read_pending_d <= 1'b0;
                    first_pending_i <= 1'b0;
                    first_pending_d <= 1'b0;
                    read_age_i <= 0;
                    read_age_d <= 0;
                end
            end

            if ((commit0_valid && (commit0_pc == stop_pc))
                || (commit1_valid && (commit1_pc == stop_pc))) begin
                emit_results();
                if (icache_trace_fd != 0)
                    $fclose(icache_trace_fd);
                if (dcache_trace_fd != 0)
                    $fclose(dcache_trace_fd);
                $finish;
            end
        end
    end

    // Print one half-cycle before cpu_top's assertion so diagnostics survive
    // the assertion's immediate process termination.
    always @(negedge clk) begin
        if (rst_n) begin
            if ((id_bubble_cause == BUBBLE_NONE) !== id_valid)
                $fatal(1, "ID bubble cause lost valid alignment");
            if ((ex_bubble_cause == BUBBLE_NONE) !== ex_valid)
                $fatal(1, "EX bubble cause lost valid alignment");
            if ((mem_bubble_cause == BUBBLE_NONE) !== mem_valid)
                $fatal(1, "MEM bubble cause lost valid alignment");
            if ((wb_bubble_cause == BUBBLE_NONE) !== wb_valid)
                $fatal(1, "WB bubble cause lost valid alignment");
            if ((id_s1_bubble_cause == BUBBLE_NONE) !== id_s1_valid_probe)
                $fatal(1, "ID Slot-1 bubble cause lost valid alignment");
            if ((ex_s1_bubble_cause == BUBBLE_NONE) !== ex_s1_valid)
                $fatal(1, "EX Slot-1 bubble cause lost valid alignment");
            if ((mem_s1_bubble_cause == BUBBLE_NONE) !== mem_s1_valid)
                $fatal(1, "MEM Slot-1 bubble cause lost valid alignment");
            if ((wb_s1_bubble_cause == BUBBLE_NONE) !== wb_s1_valid)
                $fatal(1, "WB Slot-1 bubble cause lost valid alignment");
            if ((id_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (id_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "ID ICache 3C class lost bubble alignment");
            if ((ex_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (ex_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "EX ICache 3C class lost bubble alignment");
            if ((mem_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (mem_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "MEM ICache 3C class lost bubble alignment");
            if ((wb_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (wb_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "WB ICache 3C class lost bubble alignment");
            if ((id_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (id_s1_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "ID Slot-1 ICache 3C class lost alignment");
            if ((ex_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (ex_s1_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "EX Slot-1 ICache 3C class lost alignment");
            if ((mem_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (mem_s1_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "MEM Slot-1 ICache 3C class lost alignment");
            if ((wb_s1_bubble_cause == BUBBLE_ICACHE_REFILL)
                !== (wb_s1_icache_3c_class != ICACHE_3C_NONE))
                $fatal(1, "WB Slot-1 ICache 3C class lost alignment");
            if (measurement_active
                && ((slot0_topdown_class == TOPDOWN_UNCLASSIFIED)
                    || (slot1_topdown_class == TOPDOWN_UNCLASSIFIED)))
                $fatal(1, "Top-down slot classification became unclassified");
            if (measurement_active
                && ((slot0_second_level_class == L2_UNCLASSIFIED)
                    || (slot1_second_level_class == L2_UNCLASSIFIED)))
                $fatal(1, "Second-level slot classification became unclassified");
            if (measurement_active
                && (((slot0_second_level_class == L2_CORE_BOUND)
                     && (slot0_core_detail_class
                         == CORE_DETAIL_UNCLASSIFIED))
                    || ((slot1_second_level_class == L2_CORE_BOUND)
                        && (slot1_core_detail_class
                            == CORE_DETAIL_UNCLASSIFIED))))
                $fatal(1, "Core Bound slot lacked a third-level classification");
            if (measurement_active
                && (((wb_s1_bubble_cause == BUBBLE_FRONTEND_SINGLE)
                     && !((wb_s1_detail
                           == SLOT1_DETAIL_FRONTEND_TAKEN_PAIRABLE)
                          || (wb_s1_detail
                              == SLOT1_DETAIL_FRONTEND_TAKEN_AVAILABLE_BLOCKED)
                          || (wb_s1_detail
                              == SLOT1_DETAIL_FRONTEND_TAKEN_UNAVAILABLE)
                          || (wb_s1_detail
                              == SLOT1_DETAIL_FRONTEND_NO_SECOND)
                          || (wb_s1_detail
                              == SLOT1_DETAIL_FRONTEND_NONCONTIGUOUS)))
                    || ((wb_s1_bubble_cause == BUBBLE_ID_PAIR_RAW)
                        && !((wb_s1_detail
                              == SLOT1_DETAIL_RAW_ALU_TO_ALU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_ALU_TO_LSU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_ALU_TO_CFI)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_LSU_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_MULDIV_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_CFI_PRODUCER)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_RAW_OTHER)))
                    || ((wb_s1_bubble_cause == BUBBLE_ID_PAIR_POLICY)
                        && !((wb_s1_detail
                              == SLOT1_DETAIL_POLICY_FORCE_SINGLE)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_DUAL_LSU)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_DUAL_CFI)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_SLOT0_UNSUPPORTED)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_SLOT1_UNSUPPORTED)
                             || (wb_s1_detail
                                 == SLOT1_DETAIL_POLICY_OTHER)))))
                $fatal(1, "Slot-1 fourth-level detail lost causal alignment");
        end

        if (rst_n && id_valid
            && (id_issue_hint !== id_issue_hint_reference)) begin
            $display("NSCSCC_PERF_DIAG,id_pc=%08x,id_inst=%08x,predecode_hint=%07x,decoder_hint=%07x",
                     id_pc, id_inst, id_issue_hint,
                     id_issue_hint_reference);
            $fflush();
        end
    end

endmodule

// The generic Chiplab Verilator SoC instantiates core_top as soc.cpu.  Keeping
// every hierarchy reference here makes breakage visible at compile time when
// RTL signal names change; production modules remain untouched.
bind simu_top nscscc_perf_monitor u_nscscc_perf_monitor (
    .clk                         (aclk),
    .rst_n                       (soc.cpu.core_rst_n),
    .commit0_valid               (soc.cpu.debug0_wb_valid_i),
    .commit0_pc                  (soc.cpu.debug0_wb_pc),
    .commit0_inst                (soc.cpu.debug0_wb_inst_i),
    .commit0_load                (soc.cpu.debug0_wb_mem_read_i),
    .commit0_store               (soc.cpu.debug0_wb_mem_write_i),
    .commit1_valid               (soc.cpu.debug1_wb_valid_i),
    .commit1_pc                  (soc.cpu.debug1_wb_pc_i),
    .commit1_inst                (soc.cpu.debug1_wb_inst_i),
    .commit1_load                (soc.cpu.debug1_wb_mem_read_i),
    .commit1_store               (soc.cpu.debug1_wb_mem_write_i),
    .if_valid                    (soc.cpu.u_cpu.if_valid),
    .id_valid                    (soc.cpu.u_cpu.id_valid),
    .id_pc                       (soc.cpu.u_cpu.id_pc),
    .id_inst                     (soc.cpu.u_cpu.id_inst),
    .id_issue_hint               (soc.cpu.u_cpu.id_issue_hint),
    .id_issue_hint_reference     (soc.cpu.u_cpu.id_issue_hint_reference),
    .ex_valid                    (soc.cpu.u_cpu.ex_valid),
    .mem_valid                   (soc.cpu.u_cpu.mem_valid),
    .wb_valid                    (soc.cpu.u_cpu.wb_valid),
    .ex_s1_valid                 (soc.cpu.u_cpu.ex_s1_valid),
    .mem_s1_valid                (soc.cpu.u_cpu.mem_s1_valid),
    .wb_s1_valid                 (soc.cpu.u_cpu.wb_s1_valid),
    .redirect                    (soc.cpu.u_cpu.frontend_branch_flush),
    .redirect_machine_clear      (
        soc.cpu.u_cpu.ex_fast_redirect
        | (soc.cpu.u_cpu.mem_branch_replay
           & ((soc.cpu.u_cpu.mem_redirect.source
               == cpu_defs::REDIRECT_PRIVILEGED)
              | (soc.cpu.u_cpu.mem_redirect.source
                 == cpu_defs::REDIRECT_S1_REPLAY)))),
    .if_ready_go                 (soc.cpu.u_cpu.if_ready_go_w),
    .id_allowin                  (soc.cpu.u_cpu.id_allowin),
    .id_ready_go                 (soc.cpu.u_cpu.id_ready_go),
    .ex_allowin                  (soc.cpu.u_cpu.ex_allowin),
    .ex_ready_go                 (soc.cpu.u_cpu.ex_ready_go_w),
    .ex_s1_flush                 (
        soc.cpu.u_cpu.branch_flush | soc.cpu.u_cpu.ex_priv_trap
        | soc.cpu.u_cpu.ex_s1_addr_replay
        | soc.cpu.u_cpu.mem_branch_flush),
    .ex_s1_flush_machine_clear   (
        soc.cpu.u_cpu.ex_priv_trap | soc.cpu.u_cpu.ex_s1_addr_replay
        | (soc.cpu.u_cpu.mem_branch_flush
           & ((soc.cpu.u_cpu.mem_redirect.source
               == cpu_defs::REDIRECT_PRIVILEGED)
              | (soc.cpu.u_cpu.mem_redirect.source
                 == cpu_defs::REDIRECT_S1_REPLAY)))),
    .ex_control_repair_valid     (
        soc.cpu.u_cpu.ex_valid
        & (soc.cpu.u_cpu.ex_control_flow != cpu_defs::CF_NONE)
        & (soc.cpu.u_cpu.ex_rs1_wb_repair
           | soc.cpu.u_cpu.ex_rs2_wb_repair)
        & soc.cpu.u_cpu.ex_ready_go_w
        & soc.cpu.u_cpu.mem_allowin),
    .ex_control_repair_redirect  (
        soc.cpu.u_cpu.ex_valid
        & (soc.cpu.u_cpu.ex_control_flow != cpu_defs::CF_NONE)
        & (soc.cpu.u_cpu.ex_rs1_wb_repair
           | soc.cpu.u_cpu.ex_rs2_wb_repair)
        & soc.cpu.u_cpu.ex_ready_go_w
        & soc.cpu.u_cpu.mem_allowin
        & soc.cpu.u_cpu.branch_flush),
    .mem_allowin                 (soc.cpu.u_cpu.mem_allowin),
    .mem_ready_go                (soc.cpu.u_cpu.mem_ready_go_w),
    .wb_allowin                  (soc.cpu.u_cpu.wb_allowin),
    .wb_exception                (soc.cpu.u_cpu.wb_exception),
    .mem_redirect_valid          (soc.cpu.u_cpu.mem_redirect.valid),
    .mem_redirect_machine_clear  (
        (soc.cpu.u_cpu.mem_redirect.source
         == cpu_defs::REDIRECT_PRIVILEGED)
        | (soc.cpu.u_cpu.mem_redirect.source
           == cpu_defs::REDIRECT_S1_REPLAY)),
    .muldiv_busy                 (soc.cpu.u_cpu.muldiv_busy),
    .id_load_hazard              (soc.cpu.u_cpu.id_valid
                                  & soc.cpu.u_cpu.u_forwarding.load_use_hazard),
    .id_load_ex_hazard           (soc.cpu.u_cpu.id_valid
                                  & (soc.cpu.u_cpu.u_forwarding.load_in_ex
                                     | soc.cpu.u_cpu.u_forwarding.load_in_s1_ex)),
    .id_load_mem_hazard          (soc.cpu.u_cpu.id_valid
                                  & (soc.cpu.u_cpu.u_forwarding.load_in_mem
                                     | soc.cpu.u_cpu.u_forwarding.load_in_s1_mem)),
    .mem_load_ready_probe        (soc.cpu.u_cpu.mem_load_ready),
    .id_non_load_hazard          (soc.cpu.u_cpu.id_valid
                                  & soc.cpu.u_cpu.id_non_load_hazard),
    .id_repair_hazard            (soc.cpu.u_cpu.id_valid
                                  & soc.cpu.u_cpu.u_forwarding.repair_use_hazard),
    .id_muldiv_raw_hazard        (soc.cpu.u_cpu.id_valid
                                  & soc.cpu.u_cpu.u_forwarding.muldiv_use_hazard),
    .id_mul_launch_raw_hazard    (soc.cpu.u_cpu.id_valid
                                  & soc.cpu.u_cpu.u_forwarding.mul_launch_ex_raw_hazard),
    .id_serializing_ready        (soc.cpu.u_cpu.id_serializing_ready),
    .id_barrier_ready            (soc.cpu.u_cpu.id_barrier_ready),
    .id_muldiv_structure_ready   (
        soc.cpu.u_cpu.id_muldiv_unit_ready
        & (soc.cpu.cache_ready
           ? soc.cpu.u_cpu.id_muldiv_done_ready_if_cache_ready
           : (soc.cpu.u_cpu.id_muldiv_owner_ready_if_cache_wait
              & soc.cpu.u_cpu.id_muldiv_done_ready_if_cache_wait))),
    .timer_irq_block             (soc.cpu.u_cpu.timer_irq_block),
    .ex_mmio_order_ready         (~soc.cpu.u_cpu.mmio_st_ld_hazard),
    .ex_muldiv_ready             (soc.cpu.u_cpu.ex_muldiv_ready),
    .ex_priv_ready               (soc.cpu.u_cpu.ex_priv_ready),
    .mem_backpressure            (soc.cpu.cache_pipeline_stall),
    .mem_lsu_active              (
        soc.cpu.cache_req
        | (soc.cpu.u_cpu.mem_valid
           & (soc.cpu.u_cpu.mem_mem_read_en
              | soc.cpu.u_cpu.mem_mem_write_en))
        | (soc.cpu.u_cpu.mem_s1_valid
           & (soc.cpu.u_cpu.mem_s1_mem_read_en
              | soc.cpu.u_cpu.mem_s1_mem_write_en))),
    .mem_lsu_uncached            (
        (soc.cpu.cache_req & soc.cpu.cache_uncached)
        | (soc.cpu.u_cpu.mem_valid
           & (soc.cpu.u_cpu.mem_mem_read_en
              | soc.cpu.u_cpu.mem_mem_write_en)
           & ~soc.cpu.u_cpu.is_cacheable_mem)
        | (soc.cpu.u_cpu.mem_s1_valid
           & (soc.cpu.u_cpu.mem_s1_mem_read_en
              | soc.cpu.u_cpu.mem_s1_mem_write_en)
           & ~soc.cpu.u_cpu.mem_s1_is_cacheable)),
    .ftq_count                   (soc.cpu.u_cpu.u_frontend_ftq.ftq_count),
    .fq_count                    (soc.cpu.u_cpu.u_frontend_ftq.fq_count),
    .frontend_f0_valid           (soc.cpu.u_cpu.u_frontend_ftq.f0_valid_r),
    .frontend_f0_response_fire   (soc.cpu.u_cpu.u_frontend_ftq.f0_response_fire),
    .irom_req_valid              (soc.cpu.irom_req_valid),
    .irom_req_ready              (soc.cpu.irom_req_ready),
    .irom_resp_valid             (soc.cpu.irom_resp_valid),
    .pair_candidate              (soc.cpu.u_cpu.can_dual_issue),
    .pair_raw_block              (soc.cpu.u_cpu.raw_pair_raw),
    .pair_frontend_limited       (
        (soc.cpu.u_cpu.u_frontend_ftq.fq_count < 2)
        | ~soc.cpu.u_cpu.u_frontend_ftq.fq_head_pair_contiguous
        | soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_taken),
    .pair_raw_sole_blocker       (
        soc.cpu.u_cpu.u_frontend_ftq.u_pair_policy_head_probe.blocking_raw_dep
        & soc.cpu.u_cpu.u_frontend_ftq.u_pair_policy_head_probe.pair_supported
        & ~soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.force_single
        & ~soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.force_single),
    .frontend_single_no_second   (
        soc.cpu.u_cpu.u_frontend_ftq.fq_count < 2),
    .frontend_single_noncontiguous(
        ~soc.cpu.u_cpu.u_frontend_ftq.fq_head_pair_contiguous),
    .frontend_single_taken       (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_taken),
    .frontend_taken_target_available(
        (soc.cpu.u_cpu.u_frontend_ftq.fq_count >= 2)
        & soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_taken
        & (soc.cpu.u_cpu.u_frontend_ftq.fq_head1.pc
           == soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_target)),
    .frontend_taken_target_pairable(
        (soc.cpu.u_cpu.u_frontend_ftq.fq_count >= 2)
        & soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_taken
        & (soc.cpu.u_cpu.u_frontend_ftq.fq_head1.pc
           == soc.cpu.u_cpu.u_frontend_ftq.fq_head0.pred_target)
        & soc.cpu.u_cpu.u_frontend_ftq.u_pair_policy_head_probe.pair_supported
        & ~soc.cpu.u_cpu.u_frontend_ftq.u_pair_policy_head_probe.blocking_raw_dep
        & ~soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.force_single
        & ~soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.force_single),
    .pair_slot0_alu              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_alu_type),
    .pair_slot0_lsu              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_lsu),
    .pair_slot0_cfi              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_cfi),
    .pair_slot0_muldiv           (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_muldiv),
    .pair_slot0_force_single     (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head0_pair_meta.force_single),
    .pair_slot1_alu              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_alu_type),
    .pair_slot1_lsu              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_lsu),
    .pair_slot1_cfi              (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_cfi),
    .pair_slot1_muldiv           (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_muldiv),
    .pair_slot1_force_single     (
        soc.cpu.u_cpu.u_frontend_ftq.fq_head1_pair_meta.force_single),
    .id_s1_valid_probe           (soc.cpu.u_cpu.id_s1_valid),
    .id_to_ex_fire               (soc.cpu.u_cpu.id_to_ex_fire),
    .id_s0_load                  (soc.cpu.u_cpu.id_issue_hint.mem_read),
    .id_s0_store                 (soc.cpu.u_cpu.id_issue_hint.mem_write),
    .id_s0_alu_only              (soc.cpu.u_cpu.id_s0_alu_only),
    .id_s0_conditional           (
        soc.cpu.u_cpu.id_issue_hint.conditional_control),
    .id_s0_branch_op             (soc.cpu.u_cpu.dec_uop.branch_op),
    .id_s0_indirect              (
        soc.cpu.u_cpu.id_issue_hint.indirect_control),
    .id_s0_rs1_used              (soc.cpu.u_cpu.id_rs1_used),
    .id_s0_rs2_used              (soc.cpu.u_cpu.id_rs2_used),
    .id_s0_rs1_addr              (soc.cpu.u_cpu.id_rs1_addr),
    .id_s0_rs2_addr              (soc.cpu.u_cpu.id_rs2_addr),
    .id_s0_rs1_ex_source         (
        soc.cpu.u_cpu.u_forwarding.s0_rs1_s1_ex_hit
        | soc.cpu.u_cpu.u_forwarding.s0_rs1_s0_ex_hit),
    .id_s0_rs1_load_repair       (soc.cpu.u_cpu.fwd_rs1_wb_repair),
    .id_s1_load                  (soc.cpu.u_cpu.id_s1_issue_hint.mem_read),
    .id_s1_store                 (soc.cpu.u_cpu.id_s1_issue_hint.mem_write),
    .id_s1_alu_only              (soc.cpu.u_cpu.id_s1_issue_hint.alu_only),
    .id_s1_conditional           (
        soc.cpu.u_cpu.id_s1_issue_hint.conditional_control),
    .id_s1_branch_op             (soc.cpu.u_cpu.dec1_uop.branch_op),
    .id_s1_indirect              (
        soc.cpu.u_cpu.id_s1_issue_hint.indirect_control),
    .id_s1_rs1_used              (soc.cpu.u_cpu.id_s1_rs1_used),
    .id_s1_rs2_used              (soc.cpu.u_cpu.id_s1_rs2_used),
    .id_s1_rs1_addr              (soc.cpu.u_cpu.id_s1_rs1_addr),
    .id_s1_rs2_addr              (soc.cpu.u_cpu.id_s1_rs2_addr),
    .id_s1_rs1_ex_source         (
        soc.cpu.u_cpu.u_forwarding.s1_rs1_s1_ex_hit
        | soc.cpu.u_cpu.u_forwarding.s1_rs1_s0_ex_hit),
    .id_s1_rs1_load_repair       (soc.cpu.u_cpu.fwd_s1_rs1_wb_repair),
    .id_ex_load_hazard           (
        soc.cpu.u_cpu.u_forwarding.load_in_ex
        | soc.cpu.u_cpu.u_forwarding.load_in_s1_ex),
    .id_mem_load_hazard          (
        soc.cpu.u_cpu.u_forwarding.load_in_mem
        | soc.cpu.u_cpu.u_forwarding.load_in_s1_mem),
    .ex_s0_load                  (soc.cpu.u_cpu.ex_mem_read_en),
    .ex_s0_load_size             (soc.cpu.u_cpu.ex_mem_size),
    .ex_s0_rd                    (soc.cpu.u_cpu.ex_rd),
    .ex_s1_load                  (soc.cpu.u_cpu.ex_s1_mem_read_en),
    .ex_s1_load_size             (soc.cpu.u_cpu.ex_s1_mem_size),
    .ex_s1_rd                    (soc.cpu.u_cpu.ex_s1_rd),
    .ex_store_load_overlap       (
        soc.cpu.u_dcache.store_cache_write
        & soc.cpu.cache_req & ~soc.cpu.cache_wr
        & ~soc.cpu.cache_uncached),
    .ex_store_load_same_word     (
        soc.cpu.u_dcache.store_cache_write
        & soc.cpu.cache_req & ~soc.cpu.cache_wr
        & ~soc.cpu.cache_uncached
        & (soc.cpu.u_dcache.mem_addr[31:2]
           == soc.cpu.cache_addr[31:2])),
    .dcache_read_port_internal_busy(
        soc.cpu.u_dcache.wb_read_issue
        | soc.cpu.u_dcache.state_replay),
    .pht_update_valid            (soc.cpu.u_cpu.predictor_pht_update.valid),
    .pht_update_counter          (soc.cpu.u_cpu.predictor_pht_update.counter),
    .pht_update_taken            (soc.cpu.u_cpu.predictor_pht_update.actual_taken),
    .pred_train_valid            (soc.cpu.u_cpu.pred_train_valid),
    .pred_train_conditional      (soc.cpu.u_cpu.pred_train_is_conditional_control),
    .pred_train_direct           (soc.cpu.u_cpu.pred_train_is_direct_control),
    .pred_train_indirect         (soc.cpu.u_cpu.pred_train_is_indirect_control),
    .abtb_update_valid           (soc.cpu.u_cpu.abtb_update_valid),
    .abtb_update_hit             (soc.cpu.u_cpu.abtb_update_hit),
    .icache_busy                 (soc.cpu.u_nscscc_axi_bridge.u_icache.refill_state_q != 0),
    .icache_miss_wait            (
        soc.cpu.u_nscscc_axi_bridge.u_icache.pending_miss_valid_q
        | soc.cpu.u_nscscc_axi_bridge.u_icache.refill_response_needed_q),
    .icache_req_fire             (soc.cpu.u_nscscc_axi_bridge.u_icache.irom_req_fire),
    .icache_lookup_valid         (soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_valid_q),
    .icache_lookup_line_addr     (soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_block_addr_q[28:1]),
    .icache_lookup_hit           (soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_hit),
    .icache_lookup_refill_hit    (
        soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_refill_hit_q
        | soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_commit_hit
    ),
    .icache_lookup_miss          (soc.cpu.u_nscscc_axi_bridge.u_icache.lookup_miss),
    .icache_refill_req_fire      (soc.cpu.u_nscscc_axi_bridge.u_icache.mem_req_fire),
    .icache_refill_data_fire     (soc.cpu.u_nscscc_axi_bridge.u_icache.mem_rd_fire),
    .icache_refill_complete      (soc.cpu.u_nscscc_axi_bridge.u_icache.refill_line_complete),
    .icache_kill                 (soc.cpu.irom_req_kill),
    .dcache_busy                 (~soc.cpu.u_dcache.state_idle),
    .dcache_load_hit             (soc.cpu.u_dcache.idle_load_hit),
    .dcache_load_miss            (soc.cpu.u_dcache.idle_load_miss),
    .dcache_store_hit            (soc.cpu.u_dcache.idle_store_hit),
    .dcache_store_miss           (soc.cpu.u_dcache.idle_store_miss),
    .dcache_lookup_addr          (soc.cpu.u_dcache.mem_addr),
    .dcache_uncached_start       (soc.cpu.u_dcache.idle_uncached_start),
    .dcache_dirty_victim         (soc.cpu.u_dcache.refill_start
                                  & soc.cpu.u_dcache.victim_needs_writeback),
    .dcache_refill_req_fire      (soc.cpu.u_dcache.refill_req_fire),
    .dcache_refill_data_fire     (soc.cpu.u_dcache.refill_data_fire),
    .dcache_refill_target_fire   (soc.cpu.u_dcache.refill_target_fire),
    .dcache_refill_complete      (soc.cpu.u_dcache.refill_complete),
    .dcache_wb_req_fire          (soc.cpu.u_dcache.wb_req_fire),
    .dcache_wb_data_fire         (soc.cpu.u_dcache.wb_data_fire),
    .dcache_wb_resp_fire         (soc.cpu.u_dcache.wb_resp_fire),
    .dcache_refill_wb_overlap    (soc.cpu.u_dcache.state_refill_data
                                  & (soc.cpu.u_dcache.wb_state != 0)),
    .dcache_refill_phase         (
        soc.cpu.u_dcache.state_refill_req
        | soc.cpu.u_dcache.state_refill_data
        | soc.cpu.u_dcache.state_refill_drop
        | soc.cpu.u_dcache.state_done
        | soc.cpu.u_dcache.state_replay),
    .dcache_writeback_block_phase(
        soc.cpu.u_dcache.state_wb_capture
        | soc.cpu.u_dcache.state_wb_req
        | soc.cpu.u_dcache.state_wb_join_done
        | soc.cpu.u_dcache.state_wb_join_idle),
    .dcache_uncached_phase       (
        soc.cpu.u_dcache.state_uc_req
        | soc.cpu.u_dcache.state_uc_read
        | soc.cpu.u_dcache.state_uc_write_data
        | soc.cpu.u_dcache.state_uc_write_resp),
    .arid                        (soc.cpu.arid),
    .arvalid                     (soc.cpu.arvalid),
    .arready                     (soc.cpu.arready),
    .rid                         (soc.cpu.rid),
    .rvalid                      (soc.cpu.rvalid),
    .rready                      (soc.cpu.rready),
    .rlast                       (soc.cpu.rlast),
    .awvalid                     (soc.cpu.awvalid),
    .awready                     (soc.cpu.awready),
    .wvalid                      (soc.cpu.wvalid),
    .wready                      (soc.cpu.wready),
    .bvalid                      (soc.cpu.bvalid),
    .bready                      (soc.cpu.bready),
    .led                         (led),
    .led_rg0                     (led_rg0),
    .led_rg1                     (led_rg1)
);
