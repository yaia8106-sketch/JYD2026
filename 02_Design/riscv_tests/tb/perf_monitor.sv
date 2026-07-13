// ============================================================
// Module: perf_monitor
// Description: Non-invasive performance profiling for cpu_top
//   Monitors internal signals via hierarchical references.
//   Prints summary table at end of simulation.
//
// Usage: Instantiate in TB, call print_report() before $finish.
//   perf_monitor #(.CPU_PATH("u_cpu")) u_perf (
//       .clk(clk), .rst_n(rst_n), .sim_done(tohost_detected)
//   );
// ============================================================

module perf_monitor (
    input  logic clk,
    input  logic rst_n,
    input  logic sim_done
);

    // ================================================================
    //  Counters
    // ================================================================

    // -- Overall --
    longint unsigned cnt_cycles;
    longint unsigned cnt_s0_commit;       // slot0 instructions committed (wb_valid)
    longint unsigned cnt_s1_commit;       // slot1 instructions committed (wb_s1_valid)
    longint unsigned cnt_commit0_cycles;  // cycles with no committed instruction
    longint unsigned cnt_commit1_cycles;  // cycles with exactly one committed instruction
    longint unsigned cnt_commit2_cycles;  // cycles with two committed instructions

    // -- CPI stack, priority and mutually exclusive by cycle --
    longint unsigned cnt_cpi_retire;
    longint unsigned cnt_cpi_redirect;
    longint unsigned cnt_cpi_dcache;
    longint unsigned cnt_cpi_muldiv;
    longint unsigned cnt_cpi_bitmanip;
    longint unsigned cnt_cpi_raw_not_ready;
    longint unsigned cnt_cpi_raw_ready_no_fwd;
    longint unsigned cnt_cpi_frontend_empty;
    longint unsigned cnt_cpi_other_no_commit;

    // -- Strict cycle-loss stack --
    // Unlike the legacy priority CPI stack above, a cycle with either WB slot
    // committing is always productive here.  The remaining buckets therefore
    // form a mutually-exclusive attribution of commit0 cycles and are safe to
    // rank as direct performance loss.
    longint unsigned cnt_loss_productive;
    longint unsigned cnt_loss_redirect;
    longint unsigned cnt_loss_dcache;
    longint unsigned cnt_loss_muldiv;
    longint unsigned cnt_loss_bitmanip;
    longint unsigned cnt_loss_raw_not_ready;
    longint unsigned cnt_loss_raw_ready_no_fwd;
    longint unsigned cnt_loss_frontend_empty;
    longint unsigned cnt_loss_other;
    longint unsigned cnt_loss_redirect_recovery;
    longint unsigned cnt_loss_dcache_recovery;
    longint unsigned cnt_loss_muldiv_recovery;
    longint unsigned cnt_loss_bitmanip_recovery;
    logic            dcache_loss_recovery_pending;
    logic            muldiv_loss_tail_pending;
    logic            bitmanip_loss_tail_pending;

    // -- Other no-commit breakdown, sampled only inside cnt_cpi_other_no_commit --
    longint unsigned cnt_other_id_not_ready;
    longint unsigned cnt_other_id_downstream;
    longint unsigned cnt_other_ex_not_ready;
    longint unsigned cnt_other_ex_downstream;
    longint unsigned cnt_other_mem_not_ready;
    longint unsigned cnt_other_mem_downstream;
    longint unsigned cnt_other_flush_recovery;
    longint unsigned cnt_other_frontend_backpressure;
    longint unsigned cnt_other_pipeline_fill_drain;
    longint unsigned cnt_other_unknown;
    longint unsigned cnt_other_occ [0:15];
    logic [2:0] redirect_recovery_shreg;
    integer other_occ_i;

    // -- Stall breakdown --
    longint unsigned cnt_load_use_stall;  // load_use_hazard & id_valid
    longint unsigned cnt_load_use_ex;     // load-use caused by load in EX
    longint unsigned cnt_load_use_mem;    // load-use caused only by load in MEM
    longint unsigned cnt_load_use_mem_ready;   // MEM-only load-use while MEM can advance
    longint unsigned cnt_load_use_mem_blocked; // MEM-only load-use hidden by DCache/MEM stall
    longint unsigned cnt_load_use_s0;     // slot0 consumer participates in load-use
    longint unsigned cnt_load_use_s1;     // slot1 consumer participates in load-use
    longint unsigned cnt_lu_s0_alu;       // S0 load-use where consumer is ordinary ALU
    longint unsigned cnt_lu_s0_branch;    // S0 load-use where consumer is branch compare
    longint unsigned cnt_lu_s0_jalr;      // S0 load-use where consumer is JALR target
    longint unsigned cnt_lu_s0_load_addr; // S0 load-use on load address rs1
    longint unsigned cnt_lu_s0_store_addr;// S0 load-use on store address rs1
    longint unsigned cnt_lu_s0_store_data;// S0 load-use on store data rs2
    longint unsigned cnt_lu_s0_other;     // S0 load-use that did not fit the above
    longint unsigned cnt_lu_mem_ready_s0_alu;
    longint unsigned cnt_lu_mem_ready_s0_branch;
    longint unsigned cnt_lu_mem_ready_s0_jalr;
    longint unsigned cnt_lu_mem_ready_s0_load_addr;
    longint unsigned cnt_lu_mem_ready_s0_store_addr;
    longint unsigned cnt_lu_mem_ready_s0_store_data;
    longint unsigned cnt_lu_mem_ready_s0_other;
    longint unsigned cnt_repair_wait;     // younger consumer waiting for repaired EX ALU result
    longint unsigned cnt_jalr_ex_wait;    // JALR waits for EX/S1_EX producer to reach MEM
    longint unsigned cnt_s1_wb_wait;      // pruned S1_WB forwarding path wait
    longint unsigned cnt_dcache_stall;    // ~mem_ready_go & mem_valid
    longint unsigned cnt_mmio_stall;      // ~ex_ready_go & ex_valid
    longint unsigned cnt_muldiv_stall;    // RV32M multi-cycle EX wait
    longint unsigned cnt_bitmanip_stall;  // Bitmanip multi-cycle EX wait

    // -- DCache / LSU breakdown --
    longint unsigned cnt_lsu_cache_load;  // completed cacheable loads
    longint unsigned cnt_lsu_cache_store; // completed cacheable stores
    longint unsigned cnt_lsu_mmio_load;   // completed uncacheable/MMIO loads
    longint unsigned cnt_lsu_mmio_store;  // completed uncacheable/MMIO stores
    longint unsigned cnt_dc_req;          // accepted DCache accesses: hits + accepted misses
    longint unsigned cnt_dc_load_req;
    longint unsigned cnt_dc_store_req;
    longint unsigned cnt_dc_hit;
    longint unsigned cnt_dc_load_hit;
    longint unsigned cnt_dc_store_hit;
    longint unsigned cnt_dc_miss;
    longint unsigned cnt_dc_load_miss;
    longint unsigned cnt_dc_store_miss;
    longint unsigned cnt_dc_refill_cycles;
    longint unsigned cnt_dc_refill_words;
    longint unsigned cnt_dc_refill_aborts;
    longint unsigned cnt_dc_sb_enqueue;
    longint unsigned cnt_dc_sb_drain;
    longint unsigned cnt_dc_sb_block_cycles;
    longint unsigned cnt_dc_sb_conflicts;
    longint unsigned cnt_dc_store_forward_hits;
    longint unsigned cnt_dc_miss_buffer_hits;
    longint unsigned cnt_dc_primary_refill_starts;
    longint unsigned cnt_dc_primary_refill_completes;
    longint unsigned cnt_dc_primary_refill_aborts;
    longint unsigned cnt_dc_primary_refill_stall_cycles;
    longint unsigned cnt_dc_primary_refill_lat1;
    longint unsigned cnt_dc_primary_refill_lat2;
    longint unsigned cnt_dc_primary_refill_lat3;
    longint unsigned cnt_dc_primary_refill_lat4plus;
    logic            dc_primary_refill_waiting;
    logic [15:0]     dc_primary_refill_latency;

    // Direct-BRAM store-buffer drain profiling. Separate state occupancy
    // from actual pipeline stalls and probe independent-drain concurrency.
    longint unsigned cnt_dc_drain_req_cycles;
    longint unsigned cnt_dc_drain_resp_cycles;
    longint unsigned cnt_dc_drain_req_stall;
    longint unsigned cnt_dc_drain_resp_stall;
    longint unsigned cnt_dc_drain_stall_load;
    longint unsigned cnt_dc_drain_stall_store;
    longint unsigned cnt_dc_drain_stall_other;
    longint unsigned cnt_dc_drain_pending_cycles;
    longint unsigned cnt_dc_drain_read_overlap;
    longint unsigned cnt_dc_drain_read_collision;
    longint unsigned cnt_dc_drain_push_overlap;

    // DCache stall attribution.  State counters are mutually exclusive;
    // request/tag/SB counters are orthogonal views of the same stall cycles.
    longint unsigned cnt_dc_stall_state_idle;
    longint unsigned cnt_dc_stall_state_refill_req;
    longint unsigned cnt_dc_stall_state_refill_data;
    longint unsigned cnt_dc_stall_state_refill_drop;
    longint unsigned cnt_dc_stall_state_done;
    longint unsigned cnt_dc_stall_state_sb_req;
    longint unsigned cnt_dc_stall_state_sb_resp;
    longint unsigned cnt_dc_stall_state_other;
    longint unsigned cnt_dc_stall_req_load;
    longint unsigned cnt_dc_stall_req_store;
    longint unsigned cnt_dc_stall_req_other;
    longint unsigned cnt_dc_stall_tag_hit;
    longint unsigned cnt_dc_stall_tag_miss;
    longint unsigned cnt_dc_stall_sb_occ0;
    longint unsigned cnt_dc_stall_sb_occ1;
    longint unsigned cnt_dc_stall_sb_occ2;

    // RV32M requests and wait cycles split by operation. A request is counted
    // once when the unit accepts it from ID/EX; wait counters retain the
    // existing definition (EX valid and result not done).
    longint unsigned cnt_muldiv_issue [0:7];
    longint unsigned cnt_muldiv_wait_op [0:7];
    longint unsigned cnt_muldiv_complete;
    longint unsigned cnt_muldiv_abort;
    longint unsigned cnt_muldiv_lat1;
    longint unsigned cnt_muldiv_lat2;
    longint unsigned cnt_muldiv_lat3_4;
    longint unsigned cnt_muldiv_lat5_8;
    longint unsigned cnt_muldiv_lat9_16;
    longint unsigned cnt_muldiv_lat17plus;
    logic            muldiv_profile_active;
    logic [7:0]      muldiv_profile_latency;
    integer          muldiv_op_i;

    // Bitmanip requests, wait cycles, and accepted-request latency.  Fast and
    // CLMUL classes have materially different execution costs.
    longint unsigned cnt_bitmanip_issue;
    longint unsigned cnt_bitmanip_issue_fast;
    longint unsigned cnt_bitmanip_issue_clmul;
    longint unsigned cnt_bitmanip_complete;
    longint unsigned cnt_bitmanip_abort;
    longint unsigned cnt_bitmanip_lat1;
    longint unsigned cnt_bitmanip_lat2;
    longint unsigned cnt_bitmanip_lat3_4;
    longint unsigned cnt_bitmanip_lat5_8;
    longint unsigned cnt_bitmanip_lat9_16;
    longint unsigned cnt_bitmanip_lat17plus;
    logic            bitmanip_profile_active;
    logic [7:0]      bitmanip_profile_latency;

    // -- RAW stall readiness breakdown --
    longint unsigned cnt_raw_id_stall;
    longint unsigned cnt_raw_not_ready_total;
    longint unsigned cnt_raw_not_ready_ex_load;
    longint unsigned cnt_raw_not_ready_mem_load_wait;
    longint unsigned cnt_raw_not_ready_muldiv_dep;
    longint unsigned cnt_raw_ready_no_fwd_total;
    longint unsigned cnt_raw_ready_mem_load_no_fwd;
    longint unsigned cnt_raw_ready_mem_load_s0_branch;
    longint unsigned cnt_raw_ready_mem_load_s0_jalr;
    longint unsigned cnt_raw_ready_mem_load_s0_load_addr;
    longint unsigned cnt_raw_ready_mem_load_s0_store_addr;
    longint unsigned cnt_raw_ready_mem_load_s0_store_data;
    longint unsigned cnt_raw_ready_mem_load_s1;
    longint unsigned cnt_raw_ready_repair_chain;
    longint unsigned cnt_raw_ready_repair_rs1;
    longint unsigned cnt_raw_ready_repair_rs2;
    longint unsigned cnt_raw_ready_branch_ex_no_fwd;
    longint unsigned cnt_raw_ready_branch_ex_rs1;
    longint unsigned cnt_raw_ready_branch_ex_rs2;
    longint unsigned cnt_raw_ready_branch_ex_s0_prod;
    longint unsigned cnt_raw_ready_branch_ex_s1_prod;
    longint unsigned cnt_raw_ready_jalr_ex_no_fwd;
    longint unsigned cnt_raw_ready_jalr_ex_s0_prod;
    longint unsigned cnt_raw_ready_jalr_ex_s1_prod;
    longint unsigned cnt_raw_ready_other_no_fwd;
    longint unsigned cnt_raw_unclassified_stall;

    // -- Flush --
    longint unsigned cnt_branch_flush;    // branch misprediction (EX)
    longint unsigned cnt_total_branch;    // total branch instructions reaching EX
    longint unsigned cnt_jcall_redirect;  // JAL/JALR redirect from either slot

    // -- Stage-1 prediction breakdown --
    longint unsigned cnt_pred_s0_ctrl;
    longint unsigned cnt_pred_s0_branch;
    longint unsigned cnt_pred_s0_jal;
    longint unsigned cnt_pred_s0_jalr;
    longint unsigned cnt_pred_s1_ctrl;
    longint unsigned cnt_pred_s1_branch;
    longint unsigned cnt_pred_s1_jal;
    longint unsigned cnt_pred_s1_jalr;
    longint unsigned cnt_pred_s0_pred_taken;
    longint unsigned cnt_pred_s0_actual_taken;
    longint unsigned cnt_pred_s0_mispredict;
    longint unsigned cnt_pred_s0_dir_to_taken;
    longint unsigned cnt_pred_s0_dir_to_fallthrough;
    longint unsigned cnt_pred_s0_target_wrong;
    longint unsigned cnt_pred_s1_pred_taken;
    longint unsigned cnt_pred_s1_actual_taken;
    longint unsigned cnt_pred_s1_dir_wrong;
    longint unsigned cnt_pred_s1_target_wrong;
    longint unsigned cnt_pred_s1_redirect;
    longint unsigned cnt_pred_train_total;
    longint unsigned cnt_pred_train_s0;
    longint unsigned cnt_pred_train_s1;
    longint unsigned cnt_pred_train_branch;
    longint unsigned cnt_pred_train_jal;
    longint unsigned cnt_pred_train_jalr;

    // Mispredicts split by architectural control-flow class and slot.  The
    // existing cnt_branch_flush remains a Slot-0 compatibility counter.
    longint unsigned cnt_ctrl_miss_s0_branch;
    longint unsigned cnt_ctrl_miss_s0_jal;
    longint unsigned cnt_ctrl_miss_s0_jalr;
    longint unsigned cnt_ctrl_miss_s1_branch;
    longint unsigned cnt_ctrl_miss_s1_jal;
    longint unsigned cnt_ctrl_miss_s1_jalr;

    // -- Accepted architectural instruction mix --
    // Count at the EX->MEM acceptance boundary so an EX hold is counted once
    // and a younger Slot 1 killed by a Slot 0 redirect is not counted.
    longint unsigned cnt_mix_s0_accept;
    longint unsigned cnt_mix_s1_accept;
    longint unsigned cnt_mix_alu;
    longint unsigned cnt_mix_load;
    longint unsigned cnt_mix_store;
    longint unsigned cnt_mix_branch;
    longint unsigned cnt_mix_jal;
    longint unsigned cnt_mix_jalr;
    longint unsigned cnt_mix_muldiv;
    longint unsigned cnt_mix_system;
    longint unsigned cnt_mix_bitmanip;
    longint unsigned cnt_mix_other;

    // -- Frontend / FTQ breakdown --
    longint unsigned cnt_fe_bp0_fire;
    longint unsigned cnt_fe_bp0_block_ftq_full;
    longint unsigned cnt_fe_bp0_block_fq_credit;
    longint unsigned cnt_fe_redirect_total;
    longint unsigned cnt_fe_redirect_ex;
    longint unsigned cnt_fe_f0_valid;
    longint unsigned cnt_fe_f0_accept;
    longint unsigned cnt_fe_f0_epoch_miss;
    longint unsigned cnt_fe_f0_ex_kill;
    longint unsigned cnt_fe_f0_enq0;
    longint unsigned cnt_fe_f0_enq1;
    longint unsigned cnt_fe_f0_enq_none;
    longint unsigned cnt_fe_f0_kill_slot0;
    longint unsigned cnt_fe_if_accept;
    longint unsigned cnt_fe_if_accept_dual;
    longint unsigned cnt_fe_if_accept_single;
    longint unsigned cnt_fe_if_empty;
    longint unsigned cnt_fe_fq_nonempty_cycles;
    longint unsigned cnt_fe_fq_pair_ready_cycles;
    longint unsigned cnt_fe_fq_occupancy_sum;
    longint unsigned cnt_fe_ftq_occupancy_sum;

    // -- Dual-issue opportunity loss --
    longint unsigned cnt_fetch_valid;     // if_valid cycles (fetch active)
    longint unsigned cnt_pc2_fetch;       // PC[2]=1 fetch cycles (no longer blocks dual)
    longint unsigned cnt_raw_block;       // same-pair RAW dependency
    longint unsigned cnt_inst1_not_alu;   // slot1 not ALU type
    longint unsigned cnt_inst0_jump;      // slot0 is JAL/JALR
    longint unsigned cnt_not_sequential;  // flush/redirect/pred_taken preventing dual
    longint unsigned cnt_dual_issued;     // actually dual-issued

    // -- Precise IF-accept dual issue diagnosis --
    longint unsigned cnt_if_accept;             // IF candidate accepted by IF/ID
    longint unsigned cnt_if_s1_accept;          // accepted candidates carrying slot1
    longint unsigned cnt_if_s1_block;           // accepted candidates without slot1
    longint unsigned cnt_if_block_not_seq;
    longint unsigned cnt_if_block_raw;
    longint unsigned cnt_if_block_raw_rs1;
    longint unsigned cnt_if_block_raw_rs2;
    longint unsigned cnt_if_block_s0_muldiv;
    longint unsigned cnt_if_block_s0_jump;
    longint unsigned cnt_if_block_s1_branch_s0;
    longint unsigned cnt_if_block_s1_unsupported;
    longint unsigned cnt_if_block_other;
    longint unsigned cnt_if_s1_alu_accept;
    longint unsigned cnt_if_s1_branch_accept;
    longint unsigned cnt_if_s1_load_accept;
    longint unsigned cnt_if_s1_store_accept;
    longint unsigned cnt_if_s1_jal_accept;
    longint unsigned cnt_if_s1_unsup_load;
    longint unsigned cnt_if_s1_unsup_store;
    longint unsigned cnt_if_s1_unsup_muldiv;
    longint unsigned cnt_if_s1_unsup_jal;
    longint unsigned cnt_if_s1_unsup_jalr;
    longint unsigned cnt_if_s1_unsup_system;
    longint unsigned cnt_if_s1_unsup_other;
    longint unsigned cnt_if_s0_muldiv_seen;
    longint unsigned cnt_if_s0_load_seen;
    longint unsigned cnt_if_s0_store_seen;
    longint unsigned cnt_if_s0_control_seen;
    longint unsigned cnt_if_s0_alu_seen;
    longint unsigned cnt_id_s1_seen;
    longint unsigned cnt_ex_s1_seen;
    longint unsigned cnt_mem_s1_seen;

    // Exact head-pair rejection reasons, derived from the same FQ metadata as
    // frontend_pair_policy. These replace opcode-based guesses for diagnosis.
    longint unsigned cnt_pair_block_no_candidate;
    longint unsigned cnt_pair_block_noncontiguous;
    longint unsigned cnt_pair_block_s0_pred_taken;
    longint unsigned cnt_pair_block_s0_force_single;
    longint unsigned cnt_pair_block_s1_force_single;
    longint unsigned cnt_pair_block_s0_unsupported;
    longint unsigned cnt_pair_block_s1_unsupported_exact;
    longint unsigned cnt_pair_block_both_lsu;
    longint unsigned cnt_pair_block_both_cfi;
    longint unsigned cnt_pair_block_stored_other;

    // Same-pair RAW producer/consumer matrix. Operand-role counters are hits,
    // so rs1 and rs2 may both increment for one rejected pair.
    longint unsigned cnt_pair_raw_prod_alu;
    longint unsigned cnt_pair_raw_prod_load;
    longint unsigned cnt_pair_raw_prod_cfi;
    longint unsigned cnt_pair_raw_prod_other;
    longint unsigned cnt_pair_raw_cons_alu;
    longint unsigned cnt_pair_raw_cons_load;
    longint unsigned cnt_pair_raw_cons_store;
    longint unsigned cnt_pair_raw_cons_branch;
    longint unsigned cnt_pair_raw_cons_jalr;
    longint unsigned cnt_pair_raw_cons_other;
    longint unsigned cnt_pair_raw_alu_to_alu;
    longint unsigned cnt_pair_raw_alu_to_load;
    longint unsigned cnt_pair_raw_alu_to_store;
    longint unsigned cnt_pair_raw_alu_to_branch;
    longint unsigned cnt_pair_raw_alu_to_jalr;
    longint unsigned cnt_pair_raw_alu_to_other;
    longint unsigned cnt_pair_raw_load_to_alu;
    longint unsigned cnt_pair_raw_load_to_load;
    longint unsigned cnt_pair_raw_load_to_store;
    longint unsigned cnt_pair_raw_load_to_branch;
    longint unsigned cnt_pair_raw_load_to_jalr;
    longint unsigned cnt_pair_raw_load_to_other;
    longint unsigned cnt_pair_raw_store_addr;
    longint unsigned cnt_pair_raw_store_data;
    longint unsigned cnt_pair_raw_alu_to_store_addr;
    longint unsigned cnt_pair_raw_alu_to_store_data;
    longint unsigned cnt_pair_bypass_alu_to_store_data;

    // -- Forwarding source distribution (slot0 rs1 as representative) --
    longint unsigned cnt_fwd_s1_ex;
    longint unsigned cnt_fwd_s0_ex;
    longint unsigned cnt_fwd_s1_mem;
    longint unsigned cnt_fwd_s0_mem;
    longint unsigned cnt_fwd_s1_wb;
    longint unsigned cnt_fwd_s0_wb;
    longint unsigned cnt_fwd_rf;

    // -- skip_inst0 timing fix analysis --
    longint unsigned cnt_skip_inst0;          // cycles where skip_inst0_valid=1
    longint unsigned cnt_skip_and_pred_taken; // skip_inst0=1 AND pred_taken=1 (would mispredict)
    longint unsigned cnt_predict_dual_err;    // predict_dual != can_dual (misprediction events)

    // ================================================================
    //  Signal taps (hierarchical references into cpu_top)
    // ================================================================

    // Access signals through the testbench hierarchy
    wire        wb_valid        = tb_riscv_tests.u_cpu.wb_valid;
    wire        wb_s1_valid     = tb_riscv_tests.u_cpu.wb_s1_valid;
    wire        id_valid        = tb_riscv_tests.u_cpu.id_valid;
    wire        id_s1_valid     = tb_riscv_tests.u_cpu.id_s1_valid;
    wire        id_flush_w      = tb_riscv_tests.u_cpu.id_flush;
    wire        ex_valid        = tb_riscv_tests.u_cpu.ex_valid;
    wire        ex_s1_valid     = tb_riscv_tests.u_cpu.ex_s1_valid;
    wire        mem_valid       = tb_riscv_tests.u_cpu.mem_valid;
    wire        mem_s1_valid    = tb_riscv_tests.u_cpu.mem_s1_valid;
    wire        if_valid        = tb_riscv_tests.u_cpu.if_valid;
    wire        id_allowin_w    = tb_riscv_tests.u_cpu.id_allowin;
    wire        ex_allowin_w    = tb_riscv_tests.u_cpu.ex_allowin;
    wire        if_ready_go_w   = tb_riscv_tests.u_cpu.if_ready_go_w;
    wire        mem_allowin_w   = tb_riscv_tests.u_cpu.mem_allowin;
    wire        wb_allowin_w    = tb_riscv_tests.u_cpu.wb_allowin;

    wire        id_ready_go_w   = tb_riscv_tests.u_cpu.u_forwarding.id_ready_go;
    wire        load_use_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.load_use_hazard;
    wire        load_in_ex_w    = tb_riscv_tests.u_cpu.u_forwarding.load_in_ex;
    wire        load_in_s1_ex_w = tb_riscv_tests.u_cpu.u_forwarding.load_in_s1_ex;
    wire        load_in_mem_w   = tb_riscv_tests.u_cpu.u_forwarding.load_in_mem;
    wire        load_in_s1_mem_w = tb_riscv_tests.u_cpu.u_forwarding.load_in_s1_mem;
    wire        id_s0_uses_ex_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s0_uses_ex_load;
    wire        id_s0_uses_s1_ex_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s0_uses_s1_ex_load;
    wire        id_s0_uses_mem_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s0_uses_mem_load;
    wire        id_s0_uses_s1_mem_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s0_uses_s1_mem_load;
    wire        id_s1_uses_ex_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s1_uses_ex_load;
    wire        id_s1_uses_s1_ex_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s1_uses_s1_ex_load;
    wire        id_s1_uses_mem_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s1_uses_mem_load;
    wire        id_s1_uses_s1_mem_load_w = tb_riscv_tests.u_cpu.u_forwarding.id_s1_uses_s1_mem_load;
    wire        repair_use_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.repair_use_hazard;
    wire        jalr_ex_wait_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.jalr_ex_wait_hazard;
    wire        branch_ex_wait_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.branch_ex_wait_hazard;
    wire        s1_wb_wait_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.s1_wb_wait_hazard;
    wire        ex_ready_go_w   = tb_riscv_tests.u_cpu.ex_ready_go_w;
    wire        mem_ready_go_w  = tb_riscv_tests.u_cpu.mem_ready_go_w;
    wire        mem_load_ready_w = tb_riscv_tests.u_cpu.mem_load_ready;
    wire        mmio_st_ld_hazard_w = tb_riscv_tests.u_cpu.mmio_st_ld_hazard;
    wire        ex_is_muldiv_w  = tb_riscv_tests.u_cpu.ex_is_muldiv;
    wire [ 2:0] ex_muldiv_op_w  = tb_riscv_tests.u_cpu.ex_muldiv_op;
    wire        ex_muldiv_req_w = tb_riscv_tests.u_cpu.ex_muldiv_req;
    wire        muldiv_done_w   = tb_riscv_tests.u_cpu.muldiv_done;
    wire        muldiv_busy_w   = tb_riscv_tests.u_cpu.muldiv_busy;
    wire        id_mul_prestart_w = tb_riscv_tests.u_cpu.id_mul_prestart;
    wire [ 2:0] id_mul_prestart_op_w = tb_riscv_tests.u_cpu.id_inst[14:12];
    // MUL is accepted one stage earlier than DIV. Count the architectural
    // launch exactly once at its real interface and preserve EX-start timing
    // for DIV/REM.
    wire        muldiv_ex_start_event = ex_muldiv_req_w & ex_muldiv_op_w[2]
                                      & ~muldiv_busy_w & ~muldiv_done_w;
    wire        muldiv_start_event = id_mul_prestart_w
                                   | muldiv_ex_start_event;
    wire [ 2:0] muldiv_start_op_w = id_mul_prestart_w
                                  ? id_mul_prestart_op_w : ex_muldiv_op_w;
    wire        ex_bitmanip_req_w = tb_riscv_tests.u_cpu.ex_bitmanip_req;
    wire        bitmanip_done_w = tb_riscv_tests.u_cpu.bitmanip_done;
    wire        bitmanip_busy_w = tb_riscv_tests.u_cpu.bitmanip_busy;
    wire cpu_defs::bitmanip_op_t ex_bitmanip_op_w =
        tb_riscv_tests.u_cpu.ex_bitmanip_op;
    wire bitmanip_is_clmul_w = (ex_bitmanip_op_w == cpu_defs::BM_CLMUL)
                             | (ex_bitmanip_op_w == cpu_defs::BM_CLMULR)
                             | (ex_bitmanip_op_w == cpu_defs::BM_CLMULH);
    wire bitmanip_start_event = ex_bitmanip_req_w
                              & ~bitmanip_busy_w & ~bitmanip_done_w;

    wire        branch_flush_w  = tb_riscv_tests.u_cpu.branch_flush;
    wire        mem_branch_flush_w = tb_riscv_tests.u_cpu.mem_branch_flush;
    wire        frontend_branch_flush_w = tb_riscv_tests.u_cpu.frontend_branch_flush;
    wire pair_bypass_alu_to_store_data_w = ex_valid & ex_s1_valid
        & tb_riscv_tests.u_cpu.ex_s0_alu_store_data_bypass_r
        & ex_ready_go_w & mem_allowin_w & ~mem_branch_flush_w;
    wire        muldiv_profile_abort_event = muldiv_profile_active
                                           & (frontend_branch_flush_w
                                              | mem_branch_flush_w);
    wire        bitmanip_profile_abort_event = bitmanip_profile_active
                                             & (frontend_branch_flush_w
                                                | mem_branch_flush_w);
    wire        ex_is_branch    = tb_riscv_tests.u_cpu.ex_is_branch;
    wire        ex_is_jal       = tb_riscv_tests.u_cpu.ex_is_jal;
    wire        ex_is_jalr      = tb_riscv_tests.u_cpu.ex_is_jalr;
    wire        ex_is_csr_w     = tb_riscv_tests.u_cpu.ex_is_csr;
    wire        ex_is_ecall_w   = tb_riscv_tests.u_cpu.ex_is_ecall;
    wire        ex_is_mret_w    = tb_riscv_tests.u_cpu.ex_is_mret;
    wire        ex_is_bitmanip_w = tb_riscv_tests.u_cpu.ex_is_bitmanip;
    wire        ex_mem_write_w  = tb_riscv_tests.u_cpu.ex_mem_write_en;
    wire        ex_pred_taken_w   = tb_riscv_tests.u_cpu.ex_pred_taken;
    wire [31:0] ex_pred_target_w  = tb_riscv_tests.u_cpu.ex_pred_target;
    wire        actual_taken_w  = tb_riscv_tests.u_cpu.actual_taken;
    wire [31:0] actual_target_w = tb_riscv_tests.u_cpu.actual_target;

    wire [31:0] pc              = tb_riscv_tests.u_cpu.pc;
    wire        can_dual_w      = tb_riscv_tests.u_cpu.can_dual_issue;
    wire        if_seq_fetch    = tb_riscv_tests.u_cpu.if_sequential_fetch;
    wire        raw_pair_raw_w  = tb_riscv_tests.u_cpu.raw_pair_raw;
    wire        raw_inst1_alu   = tb_riscv_tests.u_cpu.raw_inst1_is_alu_type;
    wire        raw_inst0_jump  = tb_riscv_tests.u_cpu.raw_inst0_is_jump;
    wire        irom_held_valid = tb_riscv_tests.u_cpu.irom_held_valid;
    wire        if_s1_valid_w   = tb_riscv_tests.u_cpu.if_s1_valid;
    wire        if_skip_out_w   = tb_riscv_tests.u_cpu.if_skip_out;
    wire [31:0] if_pc_out_w     = tb_riscv_tests.u_cpu.if_pc_out;
    wire [31:0] if_inst0_out_w  = tb_riscv_tests.u_cpu.if_inst0_out;
    wire [31:0] if_inst1_out_w  = tb_riscv_tests.u_cpu.if_inst1_out;

    // skip_inst0 analysis
    wire skip_inst0_w   = tb_riscv_tests.u_cpu.skip_inst0_valid;
    wire pred_taken_w     = tb_riscv_tests.u_cpu.if_pred_taken_out;
    wire predict_dual_w = tb_riscv_tests.u_cpu.predict_dual;

    // Forwarding hit signals (slot0 rs1)
    wire fwd_s1_ex  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_ex_hit;
    wire fwd_s0_ex  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_ex_hit;
    wire fwd_s1_mem = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_mem_hit;
    wire fwd_s0_mem = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_mem_hit;
    wire fwd_s1_wb  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_wb_hit;
    wire fwd_s0_wb  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_wb_hit;
    wire s0_rs1_s1_ex_hit_w = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_ex_hit;
    wire s0_rs1_s0_ex_hit_w = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_ex_hit;
    wire s0_rs2_s1_ex_hit_w = tb_riscv_tests.u_cpu.u_forwarding.s0_rs2_s1_ex_hit;
    wire s0_rs2_s0_ex_hit_w = tb_riscv_tests.u_cpu.u_forwarding.s0_rs2_s0_ex_hit;

    // S0 load-use role classification. These mirrors are simulation-only and
    // intentionally separate rs1/rs2 so store address/data can be distinguished.
    wire [4:0] id_rs1_addr_w = tb_riscv_tests.u_cpu.id_rs1_addr;
    wire [4:0] id_rs2_addr_w = tb_riscv_tests.u_cpu.id_rs2_addr;
    wire       id_rs1_used_w = tb_riscv_tests.u_cpu.id_rs1_used;
    wire       id_rs2_used_w = tb_riscv_tests.u_cpu.id_rs2_used;
    wire [4:0] id_s1_rs1_addr_w = tb_riscv_tests.u_cpu.id_s1_rs1_addr;
    wire [4:0] id_s1_rs2_addr_w = tb_riscv_tests.u_cpu.id_s1_rs2_addr;
    wire       id_s1_rs1_used_w = tb_riscv_tests.u_cpu.id_s1_rs1_used;
    wire       id_s1_rs2_used_w = tb_riscv_tests.u_cpu.id_s1_rs2_used;
    wire [4:0] ex_rd_w       = tb_riscv_tests.u_cpu.ex_rd;
    wire [4:0] ex_s1_rd_w    = tb_riscv_tests.u_cpu.ex_s1_rd;
    wire [4:0] mem_rd_w      = tb_riscv_tests.u_cpu.mem_rd;
    wire       ex_reg_write_en_w = tb_riscv_tests.u_cpu.ex_reg_write_en;
    wire       ex_mem_read_w    = tb_riscv_tests.u_cpu.ex_mem_read_en;
    wire       ex_s1_mem_read_w = tb_riscv_tests.u_cpu.ex_s1_mem_read_en;
    wire       mem_mem_read_w   = tb_riscv_tests.u_cpu.mem_mem_read_en;
    wire [3:0] mem_store_wea_w  = tb_riscv_tests.u_cpu.mem_store_wea;
    wire       mem_s1_mem_read_w = tb_riscv_tests.u_cpu.mem_s1_mem_read_en;
    wire       mem_s1_mem_write_w = tb_riscv_tests.u_cpu.mem_s1_mem_write_en;
    wire [3:0] mem_s1_store_wea_w = tb_riscv_tests.u_cpu.mem_s1_store_wea;
    wire       is_cacheable_mem_w = tb_riscv_tests.u_cpu.is_cacheable_mem;
    wire       mem_s1_is_cacheable_w = tb_riscv_tests.u_cpu.mem_s1_is_cacheable;
    wire       ex_s1_is_branch_w = tb_riscv_tests.u_cpu.ex_s1_is_branch;
    wire       ex_s1_is_jal_w    = tb_riscv_tests.u_cpu.ex_s1_is_jal;
    wire       ex_s1_is_jalr_w   = tb_riscv_tests.u_cpu.ex_s1_is_jalr;
    wire       ex_s1_mem_write_w = tb_riscv_tests.u_cpu.ex_s1_mem_write_en;
    wire [31:0] ex_s1_inst_w     = tb_riscv_tests.u_cpu.ex_s1_inst;
    wire       ex_s1_pred_taken_w  = tb_riscv_tests.u_cpu.ex_s1_pred_taken;
    wire [31:0] ex_s1_pred_target_w = tb_riscv_tests.u_cpu.ex_s1_pred_target;
    wire       ex_s1_actual_taken_w = tb_riscv_tests.u_cpu.ex_s1_actual_taken;
    wire [31:0] ex_s1_branch_target_w = tb_riscv_tests.u_cpu.ex_s1_branch_target;
    wire       ex_s1_branch_redirect_w = tb_riscv_tests.u_cpu.ex_s1_branch_redirect;

    wire       dec_reg_write_w = tb_riscv_tests.u_cpu.dec_reg_write_en;
    wire [1:0] dec_wb_sel_w    = tb_riscv_tests.u_cpu.dec_wb_sel;
    wire       dec_mem_read_w  = tb_riscv_tests.u_cpu.dec_mem_read_en;
    wire       dec_mem_write_w = tb_riscv_tests.u_cpu.dec_mem_write_en;
    wire       dec_is_branch_w = tb_riscv_tests.u_cpu.dec_is_branch;
    wire       dec_is_jal_w    = tb_riscv_tests.u_cpu.dec_is_jal;
    wire       dec_is_jalr_w   = tb_riscv_tests.u_cpu.dec_is_jalr;

    localparam [6:0] OP_R_TYPE = 7'b0110011;
    localparam [6:0] OP_I_ALU  = 7'b0010011;
    localparam [6:0] OP_LOAD   = 7'b0000011;
    localparam [6:0] OP_STORE  = 7'b0100011;
    localparam [6:0] OP_BRANCH = 7'b1100011;
    localparam [6:0] OP_JAL    = 7'b1101111;
    localparam [6:0] OP_JALR   = 7'b1100111;
    localparam [6:0] OP_LUI    = 7'b0110111;
    localparam [6:0] OP_AUIPC  = 7'b0010111;
    localparam [6:0] OP_SYSTEM = 7'b1110011;
    localparam [6:0] MULDIV_FUNCT7 = 7'b0000001;

    wire        if_accept_w = if_valid & if_ready_go_w & id_allowin_w & ~id_flush_w;
    wire [6:0] if_s0_opcode = if_inst0_out_w[6:0];
    wire [6:0] if_s1_opcode = if_inst1_out_w[6:0];
    wire [6:0] if_s0_funct7 = if_inst0_out_w[31:25];
    wire [6:0] if_s1_funct7 = if_inst1_out_w[31:25];
    wire [4:0] if_s0_rd     = if_inst0_out_w[11:7];
    wire [4:0] if_s1_rs1    = if_inst1_out_w[19:15];
    wire [4:0] if_s1_rs2    = if_inst1_out_w[24:20];

    wire if_s0_is_muldiv = (if_s0_opcode == OP_R_TYPE) & (if_s0_funct7 == MULDIV_FUNCT7);
    wire if_s1_is_muldiv = (if_s1_opcode == OP_R_TYPE) & (if_s1_funct7 == MULDIV_FUNCT7);
    wire if_s0_is_load   = (if_s0_opcode == OP_LOAD);
    wire if_s0_is_store  = (if_s0_opcode == OP_STORE);
    wire if_s0_is_branch = (if_s0_opcode == OP_BRANCH);
    wire if_s0_is_jal    = (if_s0_opcode == OP_JAL);
    wire if_s0_is_jalr   = (if_s0_opcode == OP_JALR);
    wire if_s0_is_system = (if_s0_opcode == OP_SYSTEM);
    wire if_s0_is_control = if_s0_is_branch | if_s0_is_jal | if_s0_is_jalr | if_s0_is_system;
    wire if_s0_is_lsu     = if_s0_is_load | if_s0_is_store;
    wire if_s0_is_jump    = if_s0_is_jal | if_s0_is_jalr | if_s0_is_system;
    wire if_s0_is_alu_type = ((if_s0_opcode == OP_R_TYPE) & ~if_s0_is_muldiv)
                           | (if_s0_opcode == OP_I_ALU)
                           | (if_s0_opcode == OP_LUI)
                           | (if_s0_opcode == OP_AUIPC);
    wire if_s0_writes_rd = (if_s0_opcode == OP_R_TYPE)
                         | (if_s0_opcode == OP_I_ALU)
                         | (if_s0_opcode == OP_LOAD)
                         | (if_s0_opcode == OP_LUI)
                         | (if_s0_opcode == OP_AUIPC)
                         | if_s0_is_jump;

    wire if_s1_is_alu_type = ((if_s1_opcode == OP_R_TYPE) & ~if_s1_is_muldiv)
                           | (if_s1_opcode == OP_I_ALU)
                           | (if_s1_opcode == OP_LUI)
                           | (if_s1_opcode == OP_AUIPC);
    wire if_s1_is_branch = (if_s1_opcode == OP_BRANCH);
    wire if_s1_is_load   = (if_s1_opcode == OP_LOAD);
    wire if_s1_is_store  = (if_s1_opcode == OP_STORE);
    wire if_s1_is_jal    = (if_s1_opcode == OP_JAL);
    wire if_s1_is_jalr   = (if_s1_opcode == OP_JALR);
    wire if_s1_is_system = (if_s1_opcode == OP_SYSTEM);
    wire if_s1_uses_rs1  = (if_s1_opcode == OP_R_TYPE)
                         | (if_s1_opcode == OP_I_ALU)
                         | if_s1_is_load
                         | if_s1_is_store
                         | if_s1_is_branch;
    wire if_s1_uses_rs2  = (if_s1_opcode == OP_R_TYPE)
                         | if_s1_is_store
                         | if_s1_is_branch;
    wire if_pair_raw_rs1 = if_s0_writes_rd & (if_s0_rd != 5'd0)
                         & if_s1_uses_rs1 & (if_s1_rs1 == if_s0_rd);
    wire if_pair_raw_rs2 = if_s0_writes_rd & (if_s0_rd != 5'd0)
                         & if_s1_uses_rs2 & (if_s1_rs2 == if_s0_rd);
    wire if_pair_raw = if_pair_raw_rs1 | if_pair_raw_rs2;
    wire if_s1_unsupported = ~(if_s1_is_alu_type | if_s1_is_branch | if_s1_is_load
                              | if_s1_is_store | if_s1_is_jal);
    wire if_s1_s0_policy_blocked = (if_s1_is_branch & (if_s0_is_control | if_s0_is_lsu))
                                 | ((if_s1_is_load | if_s1_is_store | if_s1_is_jal)
                                  & ~if_s0_is_alu_type);
    wire if_s1_blocked = if_accept_w & ~if_s1_valid_w;
    wire if_s1_unsup_reason = if_s1_blocked & if_seq_fetch & ~if_skip_out_w
                            & (if_pc_out_w != 32'h7FFF_FFFC)
                            & ~if_pair_raw & ~if_s0_is_muldiv
                            & if_s1_unsupported;

    wire s0_rs1_ex_load_dep = id_rs1_used_w & ex_valid & ex_mem_read_w
                            & (ex_rd_w != 5'd0) & (ex_rd_w == id_rs1_addr_w);
    wire s0_rs2_ex_load_dep = id_rs2_used_w & ex_valid & ex_mem_read_w
                            & (ex_rd_w != 5'd0) & (ex_rd_w == id_rs2_addr_w);
    wire s0_rs1_s1_ex_load_dep = id_rs1_used_w & tb_riscv_tests.u_cpu.ex_s1_valid & ex_s1_mem_read_w
                               & (ex_s1_rd_w != 5'd0) & (ex_s1_rd_w == id_rs1_addr_w);
    wire s0_rs2_s1_ex_load_dep = id_rs2_used_w & tb_riscv_tests.u_cpu.ex_s1_valid & ex_s1_mem_read_w
                               & (ex_s1_rd_w != 5'd0) & (ex_s1_rd_w == id_rs2_addr_w);
    wire s0_rs1_mem_load_dep = id_rs1_used_w & mem_valid & mem_mem_read_w
                             & (mem_rd_w != 5'd0) & (mem_rd_w == id_rs1_addr_w);
    wire s0_rs2_mem_load_dep = id_rs2_used_w & mem_valid & mem_mem_read_w
                             & (mem_rd_w != 5'd0) & (mem_rd_w == id_rs2_addr_w);

    wire s0_rs1_load_dep = s0_rs1_ex_load_dep | s0_rs1_s1_ex_load_dep | s0_rs1_mem_load_dep;
    wire s0_rs2_load_dep = s0_rs2_ex_load_dep | s0_rs2_s1_ex_load_dep | s0_rs2_mem_load_dep;
    wire s0_load_dep = s0_rs1_load_dep | s0_rs2_load_dep;
    wire s0_mem_load_dep = s0_rs1_mem_load_dep | s0_rs2_mem_load_dep;
    wire s0_load_use_event = id_valid & load_use_hazard_w & s0_load_dep;
    wire s0_mem_ready_event = id_valid & ~(load_in_ex_w | load_in_s1_ex_w)
                            & s0_mem_load_dep & mem_ready_go_w;

    wire dec_is_ordinary_alu = dec_reg_write_w & (dec_wb_sel_w == 2'b00)
                             & ~dec_mem_read_w & ~dec_mem_write_w
                             & ~dec_is_branch_w & ~dec_is_jal_w & ~dec_is_jalr_w;

    // DCache/LSU profiling taps. These are testbench-only hierarchical reads.
    wire dc_hit_accept_w = tb_riscv_tests.u_dcache.state_idle
                         & tb_riscv_tests.u_dcache.mem_req
                         & tb_riscv_tests.u_dcache.cache_hit
                         & ~tb_riscv_tests.u_dcache.sb_conflict;
    wire dc_load_hit_w   = dc_hit_accept_w & ~tb_riscv_tests.u_dcache.mem_wr;
    wire dc_store_hit_w  = dc_hit_accept_w &  tb_riscv_tests.u_dcache.mem_wr;
    wire dc_load_miss_w  = tb_riscv_tests.u_dcache.state_idle
                         & tb_riscv_tests.u_dcache.mem_req
                         & ~tb_riscv_tests.u_dcache.mem_wr
                         & ~tb_riscv_tests.u_dcache.cache_hit;
    wire dc_store_miss_w = tb_riscv_tests.u_dcache.store_miss_accept;
    wire dc_miss_start_w = dc_load_miss_w | dc_store_miss_w;
    wire dc_sb_drain_w   = tb_riscv_tests.u_dcache.sb_pop;
    wire dc_refill_cycle_w = ~tb_riscv_tests.u_dcache.state_idle
                           & ~tb_riscv_tests.u_dcache.mem_req_write
                           & ~tb_riscv_tests.u_dcache.mem_wr_ready;
    wire dc_refill_abort_w = tb_riscv_tests.u_dcache.flush & dc_refill_cycle_w;
    wire dc_sb_block_w = tb_riscv_tests.u_dcache.state_idle
                       & tb_riscv_tests.u_dcache.mem_req
                       & tb_riscv_tests.u_dcache.mem_wr
                       & tb_riscv_tests.u_dcache.sb_full;
    wire dc_store_forward_hit_w = dc_hit_accept_w
                                & ~tb_riscv_tests.u_dcache.mem_wr
                                & (tb_riscv_tests.u_dcache.store_fwd_hit_w0
                                 | tb_riscv_tests.u_dcache.store_fwd_hit_w1);
    wire dc_miss_buffer_hit_w = tb_riscv_tests.u_dcache.miss_buffer_hit;
    wire dc_primary_refill_start_w = tb_riscv_tests.u_dcache.idle_refill_start;
    wire dc_primary_refill_ready_w = tb_riscv_tests.u_dcache.refill_cpu_ready;
    wire dc_primary_refill_cancel_w = tb_riscv_tests.u_dcache.refill_cancel;
    wire dc_state_idle_w = tb_riscv_tests.u_dcache.state_idle;
    wire dc_state_refill_req_w = tb_riscv_tests.u_dcache.state_refill_req;
    wire dc_state_refill_data_w = tb_riscv_tests.u_dcache.state_refill_data;
    wire dc_state_refill_drop_w = tb_riscv_tests.u_dcache.state_refill_drop;
    wire dc_state_done_w = tb_riscv_tests.u_dcache.state_done;
    wire dc_state_sb_req_w = tb_riscv_tests.u_dcache.state_sb_drain_req;
    wire dc_state_sb_resp_w = tb_riscv_tests.u_dcache.state_sb_drain_resp;
    wire dc_mem_req_w = tb_riscv_tests.u_dcache.mem_req;
    wire dc_mem_wr_w = tb_riscv_tests.u_dcache.mem_wr;
    wire dc_tag_hit_w = tb_riscv_tests.u_dcache.cache_hit;
    wire [1:0] dc_sb_pending_w = tb_riscv_tests.u_dcache.sb_pending_q;
    wire dc_stall_event = mem_valid & ~mem_ready_go_w;
    wire dc_drain_state_w = dc_state_sb_req_w | dc_state_sb_resp_w;
    wire dc_drain_stall_w = dc_drain_state_w & dc_stall_event;
    wire dc_pending_w = tb_riscv_tests.u_dcache.sb_any_valid;
    wire dc_bram_read_w = tb_riscv_tests.u_dcache.bram_rd_en;
    wire dc_drain_read_overlap_w = dc_pending_w & dc_bram_read_w;
    wire dc_drain_read_collision_w = dc_drain_read_overlap_w
                                    & (tb_riscv_tests.u_dcache.sb_head_addr[17:2]
                                       == tb_riscv_tests.u_dcache.bram_rd_addr);
    // Count actual simultaneous queue state updates. Merely enqueueing while
    // an older entry is pending is not necessarily a push/pop overlap when a
    // same-word BRAM read blocks the drain.
    wire dc_drain_push_overlap_w = dc_sb_drain_w
                                  & tb_riscv_tests.u_dcache.sb_store_enqueue;

    wire lsu_s0_load_done = mem_valid & mem_ready_go_w & mem_mem_read_w;
    wire lsu_s0_store_done = mem_valid & mem_ready_go_w & (|mem_store_wea_w);
    wire lsu_s1_load_done = mem_s1_valid & mem_ready_go_w & mem_s1_mem_read_w;
    wire lsu_s1_store_done = mem_s1_valid & mem_ready_go_w
                            & mem_s1_mem_write_w & (|mem_s1_store_wea_w);

    wire s0_lu_alu        = s0_load_use_event & dec_is_ordinary_alu;
    wire s0_lu_branch     = s0_load_use_event & dec_is_branch_w;
    wire s0_lu_jalr       = s0_load_use_event & dec_is_jalr_w;
    wire s0_lu_load_addr  = s0_load_use_event & dec_mem_read_w  & s0_rs1_load_dep;
    wire s0_lu_store_addr = s0_load_use_event & dec_mem_write_w & s0_rs1_load_dep;
    wire s0_lu_store_data = s0_load_use_event & dec_mem_write_w & s0_rs2_load_dep;
    wire s0_lu_known      = s0_lu_alu | s0_lu_branch | s0_lu_jalr
                          | s0_lu_load_addr | s0_lu_store_addr | s0_lu_store_data;
    wire s0_lu_other      = s0_load_use_event & ~s0_lu_known;

    wire s0_mem_ready_alu        = s0_mem_ready_event & dec_is_ordinary_alu;
    wire s0_mem_ready_branch     = s0_mem_ready_event & dec_is_branch_w;
    wire s0_mem_ready_jalr       = s0_mem_ready_event & dec_is_jalr_w;
    wire s0_mem_ready_load_addr  = s0_mem_ready_event & dec_mem_read_w  & s0_rs1_mem_load_dep;
    wire s0_mem_ready_store_addr = s0_mem_ready_event & dec_mem_write_w & s0_rs1_mem_load_dep;
    wire s0_mem_ready_store_data = s0_mem_ready_event & dec_mem_write_w & s0_rs2_mem_load_dep;
    wire s0_mem_ready_known      = s0_mem_ready_alu | s0_mem_ready_branch
                                 | s0_mem_ready_jalr | s0_mem_ready_load_addr
                                 | s0_mem_ready_store_addr | s0_mem_ready_store_data;
    wire s0_mem_ready_other      = s0_mem_ready_event & ~s0_mem_ready_known;

    wire id_s1_valid_eff = id_s1_valid;
    wire id_s0_uses_ex_muldiv = ex_valid & ex_is_muldiv_w & ~muldiv_done_w
                               & ex_reg_write_en_w & (ex_rd_w != 5'd0)
                               & ((id_rs1_used_w & (id_rs1_addr_w == ex_rd_w))
                                |  (id_rs2_used_w & (id_rs2_addr_w == ex_rd_w)));
    wire id_s1_uses_ex_muldiv = id_s1_valid_eff & ex_valid & ex_is_muldiv_w & ~muldiv_done_w
                               & ex_reg_write_en_w & (ex_rd_w != 5'd0)
                               & ((id_s1_rs1_used_w & (id_s1_rs1_addr_w == ex_rd_w))
                                |  (id_s1_rs2_used_w & (id_s1_rs2_addr_w == ex_rd_w)));

    wire raw_id_stall_event = id_valid & ~id_ready_go_w;
    wire raw_nr_ex_load_event = raw_id_stall_event & (load_in_ex_w | load_in_s1_ex_w);
    wire raw_nr_mem_load_wait_event = raw_id_stall_event
                                    & ~raw_nr_ex_load_event
                                    & (load_in_mem_w | load_in_s1_mem_w)
                                    & ~mem_load_ready_w;
    wire raw_nr_muldiv_event = id_valid & (id_s0_uses_ex_muldiv | id_s1_uses_ex_muldiv);

    wire raw_ready_mem_load_no_fwd_event = raw_id_stall_event
                                         & ~raw_nr_ex_load_event
                                         & ~raw_nr_mem_load_wait_event
                                         & (load_in_mem_w | load_in_s1_mem_w)
                                         & mem_load_ready_w;
    wire raw_ready_repair_event = raw_id_stall_event
                                & ~raw_nr_ex_load_event
                                & ~raw_nr_mem_load_wait_event
                                & ~raw_ready_mem_load_no_fwd_event
                                & repair_use_hazard_w;
    wire raw_ready_branch_ex_event = raw_id_stall_event
                                   & ~raw_nr_ex_load_event
                                   & ~raw_nr_mem_load_wait_event
                                   & ~raw_ready_mem_load_no_fwd_event
                                   & ~raw_ready_repair_event
                                   & branch_ex_wait_hazard_w;
    wire raw_ready_jalr_ex_event = raw_id_stall_event
                                 & ~raw_nr_ex_load_event
                                 & ~raw_nr_mem_load_wait_event
                                 & ~raw_ready_mem_load_no_fwd_event
                                 & ~raw_ready_repair_event
                                 & ~raw_ready_branch_ex_event
                                 & jalr_ex_wait_hazard_w;
    wire raw_ready_other_event = raw_id_stall_event
                               & ~raw_nr_ex_load_event
                               & ~raw_nr_mem_load_wait_event
                               & ~raw_ready_mem_load_no_fwd_event
                               & ~raw_ready_repair_event
                               & ~raw_ready_branch_ex_event
                               & ~raw_ready_jalr_ex_event
                               & (s1_wb_wait_hazard_w | load_use_hazard_w
                                | repair_use_hazard_w | jalr_ex_wait_hazard_w
                                | branch_ex_wait_hazard_w);
    wire raw_classified_id_stall = raw_nr_ex_load_event | raw_nr_mem_load_wait_event
                                 | raw_ready_mem_load_no_fwd_event | raw_ready_repair_event
                                 | raw_ready_branch_ex_event | raw_ready_jalr_ex_event
                                 | raw_ready_other_event;

    wire ex_s0_accept_event = ex_valid & ex_ready_go_w & mem_allowin_w
                            & ~mem_branch_flush_w;
    wire ex_s1_accept_event = ex_s1_valid & ex_ready_go_w & mem_allowin_w
                            & ~mem_branch_flush_w & ~branch_flush_w;
    wire pred_s0_ctrl_event = ex_s0_accept_event
                            & (ex_is_branch | ex_is_jal | ex_is_jalr);
    wire pred_s0_mispredict_event = pred_s0_ctrl_event & branch_flush_w;
    wire pred_s0_dir_to_taken_event = pred_s0_mispredict_event
                                    & actual_taken_w & ~ex_pred_taken_w;
    wire pred_s0_dir_to_fallthrough_event = pred_s0_mispredict_event
                                          & ~actual_taken_w & ex_pred_taken_w;
    wire pred_s0_target_wrong_event = pred_s0_mispredict_event
                                  & actual_taken_w & ex_pred_taken_w
                                  & (actual_target_w != ex_pred_target_w);
    wire pred_s1_ctrl_event = ex_s1_accept_event
                          & (ex_s1_is_branch_w | ex_s1_is_jal_w | ex_s1_is_jalr_w)
                          & ex_ready_go_w & mem_allowin_w;
    wire pred_s1_dir_wrong_event = pred_s1_ctrl_event & ex_s1_is_branch_w
                               & (ex_s1_pred_taken_w != ex_s1_actual_taken_w);
    wire pred_s1_target_wrong_event = pred_s1_ctrl_event
                                  & ex_s1_pred_taken_w & ex_s1_actual_taken_w
                                  & (ex_s1_pred_target_w != ex_s1_branch_target_w);

    // Frontend/FTQ profiling taps. These observe the local frontend state
    // without feeding back into the DUT.
    wire        fe_bp0_fire_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp0_fire;
    wire        fe_ftq_alloc_ready_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ftq_alloc_ready;
    wire        fe_fq_credit_for_bp0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_credit_for_bp0;
    wire        fe_redirect_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.redirect_valid;
    wire        fe_ex_redirect_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ex_redirect_valid;
    wire        fe_f0_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_valid_r;
    wire        fe_f0_epoch_match_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_epoch_match;
    wire        fe_f0_accept_base_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_accept_base;
    wire        fe_f0_enq0_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq0_valid;
    wire        fe_f0_enq1_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq1_valid;
    wire        fe_f0_enq_none_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq_none;
    wire        fe_f0_kill_after_slot0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_kill_after_slot0;
    wire        fe_if_accept_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept;
    wire        fe_if_accept_dual_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept_dual;
    wire        fe_if_accept_single_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept_single;
    wire        fe_fq_has_slot0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_has_slot0;
    wire        fe_fq_has_slot1_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_has_slot1;
    wire [31:0] fe_fq_count_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_count;
    wire [31:0] fe_ftq_count_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ftq_count;

    // Exact FQ-head pair-policy inputs.  Reading these existing internal nets
    // keeps profiling non-invasive and avoids changing timing-sensitive RTL.
    wire [31:0] pair_head0_pc_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0.pc;
    wire [31:0] pair_head1_pc_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.pc;
    wire pair_head0_pred_taken_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.pred_taken;
    wire pair_head0_force_single_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.force_single;
    wire pair_head1_force_single_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.force_single;
    wire pair_head0_is_alu_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0.is_alu_type;
    wire pair_head0_is_load_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0.is_load;
    wire pair_head0_is_cfi_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_cfi;
    wire pair_head0_is_lsu_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_lsu;
    wire pair_head1_is_alu_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.is_alu_type;
    wire pair_head1_is_load_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.is_load;
    wire pair_head1_is_store_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.is_store;
    wire pair_head1_is_branch_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.is_branch;
    wire pair_head1_is_jalr_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1.is_jalr;
    wire pair_head1_is_cfi_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_cfi;
    wire pair_head1_is_lsu_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_lsu;
    wire pair_head0_supported_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.is_alu_type
      | pair_head0_is_lsu_w | pair_head0_is_cfi_w;
    wire pair_head1_supported_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.is_alu_type
      | pair_head1_is_lsu_w | pair_head1_is_cfi_w;
    wire pair_head_contiguous_w = pair_head1_pc_w == (pair_head0_pc_w + 32'd4);
    wire pair_head_raw_rs1_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.writes_rd
      & (tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.rd != 5'd0)
      & tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.uses_rs1
      & (tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.rs1
         == tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.rd);
    wire pair_head_raw_rs2_w =
        tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.writes_rd
      & (tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.rd != 5'd0)
      & tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.uses_rs2
      & (tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head1_pair_meta.rs2
         == tb_riscv_tests.u_cpu.u_frontend_ftq.fq_head0_pair_meta.rd);
    wire pair_head_raw_w = pair_head_raw_rs1_w | pair_head_raw_rs2_w;
    wire pair_exact_block_event = if_accept_w & ~if_s1_valid_w;

    wire fe_bp0_block_ftq_full_w = ~fe_redirect_valid_w & ~fe_ftq_alloc_ready_w;
    wire fe_bp0_block_fq_credit_w = ~fe_redirect_valid_w & fe_ftq_alloc_ready_w
                                  & ~fe_fq_credit_for_bp0_w;
    // Detect/replay phases are both real redirect work, but a combinational
    // Slot-0 miss is included only when EX can actually advance.  This avoids
    // multiplying one miss across every cycle of an unrelated MEM hold.
    wire cpi_redirect_event = frontend_branch_flush_w | mem_branch_flush_w
                            | pred_s0_mispredict_event
                            | ex_s1_branch_redirect_w;
    wire cpi_dcache_event = mem_valid & ~mem_ready_go_w;
    wire cpi_muldiv_event = ex_valid & ex_is_muldiv_w & ~muldiv_done_w;
    wire cpi_bitmanip_event = ex_valid & ex_is_bitmanip_w
                            & ~bitmanip_done_w;
    wire cpi_raw_not_ready_event = raw_nr_ex_load_event | raw_nr_mem_load_wait_event
                                 | raw_nr_muldiv_event;
    wire cpi_raw_ready_no_fwd_event = raw_ready_mem_load_no_fwd_event
                                    | raw_ready_repair_event
                                    | raw_ready_branch_ex_event
                                    | raw_ready_jalr_ex_event
                                    | raw_ready_other_event;
    wire cpi_frontend_empty_event = ~if_valid;
    wire cpi_retire_event = wb_valid | wb_s1_valid;
    wire cpi_other_no_commit_event = ~cpi_redirect_event
                                   & ~cpi_dcache_event
                                   & ~cpi_muldiv_event
                                   & ~cpi_bitmanip_event
                                   & ~cpi_raw_not_ready_event
                                   & ~cpi_raw_ready_no_fwd_event
                                   & ~cpi_frontend_empty_event
                                   & ~cpi_retire_event;
    wire redirect_recovery_window = |redirect_recovery_shreg;
    // A blocking backend resource can leave one or two empty WB cycles after
    // the live wait ends. Attribute those causal refill tails to the resource
    // that drained the pipe, while retaining separate recovery counters.
    wire dcache_loss_recovery_event = dcache_loss_recovery_pending
                                    & mem_valid & mem_ready_go_w;
    wire muldiv_complete_accept_event = ex_s0_accept_event
                                      & ex_is_muldiv_w & muldiv_done_w;
    wire muldiv_loss_recovery_event = muldiv_complete_accept_event
                                    | muldiv_loss_tail_pending;
    wire bitmanip_complete_accept_event = ex_s0_accept_event
                                        & ex_is_bitmanip_w & bitmanip_done_w;
    wire bitmanip_loss_recovery_event = bitmanip_complete_accept_event
                                      | bitmanip_loss_tail_pending;
    wire loss_other_event = ~cpi_retire_event
                          & ~(cpi_redirect_event | redirect_recovery_window)
                          & ~(cpi_dcache_event | dcache_loss_recovery_event)
                          & ~(cpi_muldiv_event | muldiv_loss_recovery_event)
                          & ~(cpi_bitmanip_event
                              | bitmanip_loss_recovery_event)
                          & ~cpi_raw_not_ready_event
                          & ~cpi_raw_ready_no_fwd_event
                          & ~cpi_frontend_empty_event;
    wire pipe_ex_any_valid = ex_valid | ex_s1_valid;
    wire pipe_mem_any_valid = mem_valid | mem_s1_valid;
    wire pipe_non_wb_active = if_valid | id_valid | pipe_ex_any_valid
                            | pipe_mem_any_valid;
    wire [3:0] other_occ_index = {if_valid, id_valid, pipe_ex_any_valid,
                                  pipe_mem_any_valid};

    wire mix_s0_system = ex_is_csr_w | ex_is_ecall_w | ex_is_mret_w;
    wire mix_s0_alu = ~(ex_is_branch | ex_is_jal | ex_is_jalr
                      | ex_mem_read_w | ex_mem_write_w | ex_is_muldiv_w
                      | mix_s0_system | ex_is_bitmanip_w);
    wire [6:0] mix_s1_opcode = ex_s1_inst_w[6:0];
    wire mix_s1_muldiv = (mix_s1_opcode == OP_R_TYPE)
                       & (ex_s1_inst_w[31:25] == MULDIV_FUNCT7);
    wire mix_s1_system = (mix_s1_opcode == OP_SYSTEM);
    wire mix_s1_known = ex_s1_is_branch_w | ex_s1_is_jal_w | ex_s1_is_jalr_w
                      | ex_s1_mem_read_w | ex_s1_mem_write_w
                      | mix_s1_muldiv | mix_s1_system
                      | (mix_s1_opcode == OP_R_TYPE)
                      | (mix_s1_opcode == OP_I_ALU)
                      | (mix_s1_opcode == OP_LUI)
                      | (mix_s1_opcode == OP_AUIPC);
    wire mix_s1_alu = mix_s1_known & ~(ex_s1_is_branch_w | ex_s1_is_jal_w
                     | ex_s1_is_jalr_w | ex_s1_mem_read_w
                     | ex_s1_mem_write_w | mix_s1_muldiv | mix_s1_system);

    wire repair_rs1_dep = repair_use_hazard_w
                        & ((id_rs1_used_w & (id_rs1_addr_w == ex_rd_w))
                         |  (id_s1_valid_eff & id_s1_rs1_used_w & (id_s1_rs1_addr_w == ex_rd_w)));
    wire repair_rs2_dep = repair_use_hazard_w
                        & ((id_rs2_used_w & (id_rs2_addr_w == ex_rd_w))
                         |  (id_s1_valid_eff & id_s1_rs2_used_w & (id_s1_rs2_addr_w == ex_rd_w)));
    wire branch_ex_rs1_dep = branch_ex_wait_hazard_w & id_rs1_used_w
                           & (s0_rs1_s0_ex_hit_w | s0_rs1_s1_ex_hit_w);
    wire branch_ex_rs2_dep = branch_ex_wait_hazard_w & id_rs2_used_w
                           & (s0_rs2_s0_ex_hit_w | s0_rs2_s1_ex_hit_w);
    wire branch_ex_s0_prod = branch_ex_wait_hazard_w
                           & ((id_rs1_used_w & s0_rs1_s0_ex_hit_w)
                            |  (id_rs2_used_w & s0_rs2_s0_ex_hit_w));
    wire branch_ex_s1_prod = branch_ex_wait_hazard_w
                           & ((id_rs1_used_w & s0_rs1_s1_ex_hit_w)
                            |  (id_rs2_used_w & s0_rs2_s1_ex_hit_w));

    // ================================================================
    //  Counting logic
    // ================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_cycles         <= 0;
            cnt_s0_commit      <= 0;
            cnt_s1_commit      <= 0;
            cnt_commit0_cycles <= 0;
            cnt_commit1_cycles <= 0;
            cnt_commit2_cycles <= 0;
            cnt_cpi_retire     <= 0;
            cnt_cpi_redirect   <= 0;
            cnt_cpi_dcache     <= 0;
            cnt_cpi_muldiv     <= 0;
            cnt_cpi_bitmanip   <= 0;
            cnt_cpi_raw_not_ready <= 0;
            cnt_cpi_raw_ready_no_fwd <= 0;
            cnt_cpi_frontend_empty <= 0;
            cnt_cpi_other_no_commit <= 0;
            cnt_loss_productive <= 0;
            cnt_loss_redirect <= 0;
            cnt_loss_dcache <= 0;
            cnt_loss_muldiv <= 0;
            cnt_loss_bitmanip <= 0;
            cnt_loss_raw_not_ready <= 0;
            cnt_loss_raw_ready_no_fwd <= 0;
            cnt_loss_frontend_empty <= 0;
            cnt_loss_other <= 0;
            cnt_loss_redirect_recovery <= 0;
            cnt_loss_dcache_recovery <= 0;
            cnt_loss_muldiv_recovery <= 0;
            cnt_loss_bitmanip_recovery <= 0;
            dcache_loss_recovery_pending <= 1'b0;
            muldiv_loss_tail_pending <= 1'b0;
            bitmanip_loss_tail_pending <= 1'b0;
            cnt_other_id_not_ready <= 0;
            cnt_other_id_downstream <= 0;
            cnt_other_ex_not_ready <= 0;
            cnt_other_ex_downstream <= 0;
            cnt_other_mem_not_ready <= 0;
            cnt_other_mem_downstream <= 0;
            cnt_other_flush_recovery <= 0;
            cnt_other_frontend_backpressure <= 0;
            cnt_other_pipeline_fill_drain <= 0;
            cnt_other_unknown <= 0;
            redirect_recovery_shreg <= 3'b000;
            for (other_occ_i = 0; other_occ_i < 16; other_occ_i = other_occ_i + 1)
                cnt_other_occ[other_occ_i] <= 0;
            cnt_load_use_stall <= 0;
            cnt_load_use_ex    <= 0;
            cnt_load_use_mem   <= 0;
            cnt_load_use_mem_ready <= 0;
            cnt_load_use_mem_blocked <= 0;
            cnt_load_use_s0    <= 0;
            cnt_load_use_s1    <= 0;
            cnt_lu_s0_alu      <= 0;
            cnt_lu_s0_branch   <= 0;
            cnt_lu_s0_jalr     <= 0;
            cnt_lu_s0_load_addr <= 0;
            cnt_lu_s0_store_addr <= 0;
            cnt_lu_s0_store_data <= 0;
            cnt_lu_s0_other    <= 0;
            cnt_lu_mem_ready_s0_alu <= 0;
            cnt_lu_mem_ready_s0_branch <= 0;
            cnt_lu_mem_ready_s0_jalr <= 0;
            cnt_lu_mem_ready_s0_load_addr <= 0;
            cnt_lu_mem_ready_s0_store_addr <= 0;
            cnt_lu_mem_ready_s0_store_data <= 0;
            cnt_lu_mem_ready_s0_other <= 0;
            cnt_repair_wait    <= 0;
            cnt_jalr_ex_wait   <= 0;
            cnt_s1_wb_wait     <= 0;
            cnt_dcache_stall   <= 0;
            cnt_mmio_stall     <= 0;
            cnt_muldiv_stall   <= 0;
            cnt_bitmanip_stall <= 0;
            cnt_lsu_cache_load <= 0;
            cnt_lsu_cache_store <= 0;
            cnt_lsu_mmio_load <= 0;
            cnt_lsu_mmio_store <= 0;
            cnt_dc_req <= 0;
            cnt_dc_load_req <= 0;
            cnt_dc_store_req <= 0;
            cnt_dc_hit <= 0;
            cnt_dc_load_hit <= 0;
            cnt_dc_store_hit <= 0;
            cnt_dc_miss <= 0;
            cnt_dc_load_miss <= 0;
            cnt_dc_store_miss <= 0;
            cnt_dc_refill_cycles <= 0;
            cnt_dc_refill_words <= 0;
            cnt_dc_refill_aborts <= 0;
            cnt_dc_sb_enqueue <= 0;
            cnt_dc_sb_drain <= 0;
            cnt_dc_sb_block_cycles <= 0;
            cnt_dc_sb_conflicts <= 0;
            cnt_dc_store_forward_hits <= 0;
            cnt_dc_miss_buffer_hits <= 0;
            cnt_dc_primary_refill_starts <= 0;
            cnt_dc_primary_refill_completes <= 0;
            cnt_dc_primary_refill_aborts <= 0;
            cnt_dc_primary_refill_stall_cycles <= 0;
            cnt_dc_primary_refill_lat1 <= 0;
            cnt_dc_primary_refill_lat2 <= 0;
            cnt_dc_primary_refill_lat3 <= 0;
            cnt_dc_primary_refill_lat4plus <= 0;
            dc_primary_refill_waiting <= 1'b0;
            dc_primary_refill_latency <= 16'd0;
            cnt_dc_drain_req_cycles <= 0;
            cnt_dc_drain_resp_cycles <= 0;
            cnt_dc_drain_req_stall <= 0;
            cnt_dc_drain_resp_stall <= 0;
            cnt_dc_drain_stall_load <= 0;
            cnt_dc_drain_stall_store <= 0;
            cnt_dc_drain_stall_other <= 0;
            cnt_dc_drain_pending_cycles <= 0;
            cnt_dc_drain_read_overlap <= 0;
            cnt_dc_drain_read_collision <= 0;
            cnt_dc_drain_push_overlap <= 0;
            cnt_dc_stall_state_idle <= 0;
            cnt_dc_stall_state_refill_req <= 0;
            cnt_dc_stall_state_refill_data <= 0;
            cnt_dc_stall_state_refill_drop <= 0;
            cnt_dc_stall_state_done <= 0;
            cnt_dc_stall_state_sb_req <= 0;
            cnt_dc_stall_state_sb_resp <= 0;
            cnt_dc_stall_state_other <= 0;
            cnt_dc_stall_req_load <= 0;
            cnt_dc_stall_req_store <= 0;
            cnt_dc_stall_req_other <= 0;
            cnt_dc_stall_tag_hit <= 0;
            cnt_dc_stall_tag_miss <= 0;
            cnt_dc_stall_sb_occ0 <= 0;
            cnt_dc_stall_sb_occ1 <= 0;
            cnt_dc_stall_sb_occ2 <= 0;
            for (muldiv_op_i = 0; muldiv_op_i < 8; muldiv_op_i = muldiv_op_i + 1) begin
                cnt_muldiv_issue[muldiv_op_i] <= 0;
                cnt_muldiv_wait_op[muldiv_op_i] <= 0;
            end
            cnt_muldiv_complete <= 0;
            cnt_muldiv_abort <= 0;
            cnt_muldiv_lat1 <= 0;
            cnt_muldiv_lat2 <= 0;
            cnt_muldiv_lat3_4 <= 0;
            cnt_muldiv_lat5_8 <= 0;
            cnt_muldiv_lat9_16 <= 0;
            cnt_muldiv_lat17plus <= 0;
            muldiv_profile_active <= 1'b0;
            muldiv_profile_latency <= 8'd0;
            cnt_bitmanip_issue <= 0;
            cnt_bitmanip_issue_fast <= 0;
            cnt_bitmanip_issue_clmul <= 0;
            cnt_bitmanip_complete <= 0;
            cnt_bitmanip_abort <= 0;
            cnt_bitmanip_lat1 <= 0;
            cnt_bitmanip_lat2 <= 0;
            cnt_bitmanip_lat3_4 <= 0;
            cnt_bitmanip_lat5_8 <= 0;
            cnt_bitmanip_lat9_16 <= 0;
            cnt_bitmanip_lat17plus <= 0;
            bitmanip_profile_active <= 1'b0;
            bitmanip_profile_latency <= 8'd0;
            cnt_raw_id_stall   <= 0;
            cnt_raw_not_ready_total <= 0;
            cnt_raw_not_ready_ex_load <= 0;
            cnt_raw_not_ready_mem_load_wait <= 0;
            cnt_raw_not_ready_muldiv_dep <= 0;
            cnt_raw_ready_no_fwd_total <= 0;
            cnt_raw_ready_mem_load_no_fwd <= 0;
            cnt_raw_ready_mem_load_s0_branch <= 0;
            cnt_raw_ready_mem_load_s0_jalr <= 0;
            cnt_raw_ready_mem_load_s0_load_addr <= 0;
            cnt_raw_ready_mem_load_s0_store_addr <= 0;
            cnt_raw_ready_mem_load_s0_store_data <= 0;
            cnt_raw_ready_mem_load_s1 <= 0;
            cnt_raw_ready_repair_chain <= 0;
            cnt_raw_ready_repair_rs1 <= 0;
            cnt_raw_ready_repair_rs2 <= 0;
            cnt_raw_ready_branch_ex_no_fwd <= 0;
            cnt_raw_ready_branch_ex_rs1 <= 0;
            cnt_raw_ready_branch_ex_rs2 <= 0;
            cnt_raw_ready_branch_ex_s0_prod <= 0;
            cnt_raw_ready_branch_ex_s1_prod <= 0;
            cnt_raw_ready_jalr_ex_no_fwd <= 0;
            cnt_raw_ready_jalr_ex_s0_prod <= 0;
            cnt_raw_ready_jalr_ex_s1_prod <= 0;
            cnt_raw_ready_other_no_fwd <= 0;
            cnt_raw_unclassified_stall <= 0;
            cnt_branch_flush   <= 0;
            cnt_total_branch   <= 0;
            cnt_jcall_redirect <= 0;
            cnt_pred_s0_ctrl <= 0;
            cnt_pred_s0_branch <= 0;
            cnt_pred_s0_jal <= 0;
            cnt_pred_s0_jalr <= 0;
            cnt_pred_s1_ctrl <= 0;
            cnt_pred_s1_branch <= 0;
            cnt_pred_s1_jal <= 0;
            cnt_pred_s1_jalr <= 0;
            cnt_pred_s0_pred_taken <= 0;
            cnt_pred_s0_actual_taken <= 0;
            cnt_pred_s0_mispredict <= 0;
            cnt_pred_s0_dir_to_taken <= 0;
            cnt_pred_s0_dir_to_fallthrough <= 0;
            cnt_pred_s0_target_wrong <= 0;
            cnt_pred_s1_pred_taken <= 0;
            cnt_pred_s1_actual_taken <= 0;
            cnt_pred_s1_dir_wrong <= 0;
            cnt_pred_s1_target_wrong <= 0;
            cnt_pred_s1_redirect <= 0;
            cnt_pred_train_total <= 0;
            cnt_pred_train_s0 <= 0;
            cnt_pred_train_s1 <= 0;
            cnt_pred_train_branch <= 0;
            cnt_pred_train_jal <= 0;
            cnt_pred_train_jalr <= 0;
            cnt_ctrl_miss_s0_branch <= 0;
            cnt_ctrl_miss_s0_jal <= 0;
            cnt_ctrl_miss_s0_jalr <= 0;
            cnt_ctrl_miss_s1_branch <= 0;
            cnt_ctrl_miss_s1_jal <= 0;
            cnt_ctrl_miss_s1_jalr <= 0;
            cnt_mix_s0_accept <= 0;
            cnt_mix_s1_accept <= 0;
            cnt_mix_alu <= 0;
            cnt_mix_load <= 0;
            cnt_mix_store <= 0;
            cnt_mix_branch <= 0;
            cnt_mix_jal <= 0;
            cnt_mix_jalr <= 0;
            cnt_mix_muldiv <= 0;
            cnt_mix_system <= 0;
            cnt_mix_bitmanip <= 0;
            cnt_mix_other <= 0;
            cnt_fe_bp0_fire <= 0;
            cnt_fe_bp0_block_ftq_full <= 0;
            cnt_fe_bp0_block_fq_credit <= 0;
            cnt_fe_redirect_total <= 0;
            cnt_fe_redirect_ex <= 0;
            cnt_fe_f0_valid <= 0;
            cnt_fe_f0_accept <= 0;
            cnt_fe_f0_epoch_miss <= 0;
            cnt_fe_f0_ex_kill <= 0;
            cnt_fe_f0_enq0 <= 0;
            cnt_fe_f0_enq1 <= 0;
            cnt_fe_f0_enq_none <= 0;
            cnt_fe_f0_kill_slot0 <= 0;
            cnt_fe_if_accept <= 0;
            cnt_fe_if_accept_dual <= 0;
            cnt_fe_if_accept_single <= 0;
            cnt_fe_if_empty <= 0;
            cnt_fe_fq_nonempty_cycles <= 0;
            cnt_fe_fq_pair_ready_cycles <= 0;
            cnt_fe_fq_occupancy_sum <= 0;
            cnt_fe_ftq_occupancy_sum <= 0;
            cnt_fetch_valid    <= 0;
            cnt_pc2_fetch      <= 0;
            cnt_raw_block      <= 0;
            cnt_inst1_not_alu  <= 0;
            cnt_inst0_jump     <= 0;
            cnt_not_sequential <= 0;
            cnt_dual_issued    <= 0;
            cnt_if_accept      <= 0;
            cnt_if_s1_accept   <= 0;
            cnt_if_s1_block    <= 0;
            cnt_if_block_not_seq <= 0;
            cnt_if_block_raw   <= 0;
            cnt_if_block_raw_rs1 <= 0;
            cnt_if_block_raw_rs2 <= 0;
            cnt_if_block_s0_muldiv <= 0;
            cnt_if_block_s0_jump <= 0;
            cnt_if_block_s1_branch_s0 <= 0;
            cnt_if_block_s1_unsupported <= 0;
            cnt_if_block_other <= 0;
            cnt_if_s1_alu_accept <= 0;
            cnt_if_s1_branch_accept <= 0;
            cnt_if_s1_load_accept <= 0;
            cnt_if_s1_store_accept <= 0;
            cnt_if_s1_jal_accept <= 0;
            cnt_if_s1_unsup_load <= 0;
            cnt_if_s1_unsup_store <= 0;
            cnt_if_s1_unsup_muldiv <= 0;
            cnt_if_s1_unsup_jal <= 0;
            cnt_if_s1_unsup_jalr <= 0;
            cnt_if_s1_unsup_system <= 0;
            cnt_if_s1_unsup_other <= 0;
            cnt_if_s0_muldiv_seen <= 0;
            cnt_if_s0_load_seen <= 0;
            cnt_if_s0_store_seen <= 0;
            cnt_if_s0_control_seen <= 0;
            cnt_if_s0_alu_seen <= 0;
            cnt_id_s1_seen <= 0;
            cnt_ex_s1_seen <= 0;
            cnt_mem_s1_seen <= 0;
            cnt_pair_block_no_candidate <= 0;
            cnt_pair_block_noncontiguous <= 0;
            cnt_pair_block_s0_pred_taken <= 0;
            cnt_pair_block_s0_force_single <= 0;
            cnt_pair_block_s1_force_single <= 0;
            cnt_pair_block_s0_unsupported <= 0;
            cnt_pair_block_s1_unsupported_exact <= 0;
            cnt_pair_block_both_lsu <= 0;
            cnt_pair_block_both_cfi <= 0;
            cnt_pair_block_stored_other <= 0;
            cnt_pair_raw_prod_alu <= 0;
            cnt_pair_raw_prod_load <= 0;
            cnt_pair_raw_prod_cfi <= 0;
            cnt_pair_raw_prod_other <= 0;
            cnt_pair_raw_cons_alu <= 0;
            cnt_pair_raw_cons_load <= 0;
            cnt_pair_raw_cons_store <= 0;
            cnt_pair_raw_cons_branch <= 0;
            cnt_pair_raw_cons_jalr <= 0;
            cnt_pair_raw_cons_other <= 0;
            cnt_pair_raw_alu_to_alu <= 0;
            cnt_pair_raw_alu_to_load <= 0;
            cnt_pair_raw_alu_to_store <= 0;
            cnt_pair_raw_alu_to_branch <= 0;
            cnt_pair_raw_alu_to_jalr <= 0;
            cnt_pair_raw_alu_to_other <= 0;
            cnt_pair_raw_load_to_alu <= 0;
            cnt_pair_raw_load_to_load <= 0;
            cnt_pair_raw_load_to_store <= 0;
            cnt_pair_raw_load_to_branch <= 0;
            cnt_pair_raw_load_to_jalr <= 0;
            cnt_pair_raw_load_to_other <= 0;
            cnt_pair_raw_store_addr <= 0;
            cnt_pair_raw_store_data <= 0;
            cnt_pair_raw_alu_to_store_addr <= 0;
            cnt_pair_raw_alu_to_store_data <= 0;
            cnt_pair_bypass_alu_to_store_data <= 0;
            cnt_fwd_s1_ex      <= 0;
            cnt_fwd_s0_ex      <= 0;
            cnt_fwd_s1_mem     <= 0;
            cnt_fwd_s0_mem     <= 0;
            cnt_fwd_s1_wb      <= 0;
            cnt_fwd_s0_wb      <= 0;
            cnt_fwd_rf         <= 0;
            cnt_skip_inst0     <= 0;
            cnt_skip_and_pred_taken <= 0;
            cnt_predict_dual_err <= 0;
        end else begin
            cnt_cycles <= cnt_cycles + 1;

            // Commit
            if (wb_valid)    cnt_s0_commit <= cnt_s0_commit + 1;
            if (wb_s1_valid) cnt_s1_commit <= cnt_s1_commit + 1;
            if (wb_valid & wb_s1_valid)
                cnt_commit2_cycles <= cnt_commit2_cycles + 1;
            else if (wb_valid | wb_s1_valid)
                cnt_commit1_cycles <= cnt_commit1_cycles + 1;
            else
                cnt_commit0_cycles <= cnt_commit0_cycles + 1;

            // Priority CPI stack. Each cycle is assigned to exactly one bucket.
            if (cpi_redirect_event)
                cnt_cpi_redirect <= cnt_cpi_redirect + 1;
            else if (cpi_dcache_event)
                cnt_cpi_dcache <= cnt_cpi_dcache + 1;
            else if (cpi_muldiv_event)
                cnt_cpi_muldiv <= cnt_cpi_muldiv + 1;
            else if (cpi_bitmanip_event)
                cnt_cpi_bitmanip <= cnt_cpi_bitmanip + 1;
            else if (cpi_raw_not_ready_event)
                cnt_cpi_raw_not_ready <= cnt_cpi_raw_not_ready + 1;
            else if (cpi_raw_ready_no_fwd_event)
                cnt_cpi_raw_ready_no_fwd <= cnt_cpi_raw_ready_no_fwd + 1;
            else if (cpi_frontend_empty_event)
                cnt_cpi_frontend_empty <= cnt_cpi_frontend_empty + 1;
            else if (cpi_other_no_commit_event)
                cnt_cpi_other_no_commit <= cnt_cpi_other_no_commit + 1;
            else
                cnt_cpi_retire <= cnt_cpi_retire + 1;

            // Strict loss stack: productive cycles win over all coincident
            // backpressure.  Every remaining bucket is a true commit0 cycle.
            if (cpi_retire_event)
                cnt_loss_productive <= cnt_loss_productive + 1;
            else if (cpi_redirect_event | redirect_recovery_window) begin
                cnt_loss_redirect <= cnt_loss_redirect + 1;
                if (~cpi_redirect_event & redirect_recovery_window)
                    cnt_loss_redirect_recovery
                        <= cnt_loss_redirect_recovery + 1;
            end else if (cpi_dcache_event | dcache_loss_recovery_event) begin
                cnt_loss_dcache <= cnt_loss_dcache + 1;
                if (~cpi_dcache_event & dcache_loss_recovery_event)
                    cnt_loss_dcache_recovery
                        <= cnt_loss_dcache_recovery + 1;
            end else if (cpi_muldiv_event | muldiv_loss_recovery_event) begin
                cnt_loss_muldiv <= cnt_loss_muldiv + 1;
                if (~cpi_muldiv_event & muldiv_loss_recovery_event)
                    cnt_loss_muldiv_recovery
                        <= cnt_loss_muldiv_recovery + 1;
            end else if (cpi_bitmanip_event
                       | bitmanip_loss_recovery_event) begin
                cnt_loss_bitmanip <= cnt_loss_bitmanip + 1;
                if (~cpi_bitmanip_event & bitmanip_loss_recovery_event)
                    cnt_loss_bitmanip_recovery
                        <= cnt_loss_bitmanip_recovery + 1;
            end else if (cpi_raw_not_ready_event)
                cnt_loss_raw_not_ready <= cnt_loss_raw_not_ready + 1;
            else if (cpi_raw_ready_no_fwd_event)
                cnt_loss_raw_ready_no_fwd <= cnt_loss_raw_ready_no_fwd + 1;
            else if (cpi_frontend_empty_event)
                cnt_loss_frontend_empty <= cnt_loss_frontend_empty + 1;
            else
                cnt_loss_other <= cnt_loss_other + 1;

            // Start the fixed recovery window from the frontend-visible flush,
            // not from a held combinational EX mismatch.
            if (frontend_branch_flush_w)
                redirect_recovery_shreg <= 3'b111;
            else
                redirect_recovery_shreg <= {1'b0, redirect_recovery_shreg[2:1]};

            if (mem_branch_flush_w)
                dcache_loss_recovery_pending <= 1'b0;
            else if (cpi_dcache_event)
                dcache_loss_recovery_pending <= 1'b1;
            else if (dcache_loss_recovery_event)
                dcache_loss_recovery_pending <= 1'b0;

            if (frontend_branch_flush_w | mem_branch_flush_w) begin
                muldiv_loss_tail_pending <= 1'b0;
                bitmanip_loss_tail_pending <= 1'b0;
            end else begin
                // The completion/accept cycle is the first recovery cycle;
                // retain one more cycle for EX->MEM->WB refill.
                muldiv_loss_tail_pending <= muldiv_complete_accept_event;
                bitmanip_loss_tail_pending
                    <= bitmanip_complete_accept_event;
            end

            if (loss_other_event) begin
                cnt_other_occ[other_occ_index] <= cnt_other_occ[other_occ_index] + 1;
                if (id_valid & ~id_ready_go_w)
                    cnt_other_id_not_ready <= cnt_other_id_not_ready + 1;
                else if (id_valid & id_ready_go_w & ~ex_allowin_w)
                    cnt_other_id_downstream <= cnt_other_id_downstream + 1;
                else if (pipe_ex_any_valid & ~ex_ready_go_w)
                    cnt_other_ex_not_ready <= cnt_other_ex_not_ready + 1;
                else if (pipe_ex_any_valid & ex_ready_go_w & ~mem_allowin_w)
                    cnt_other_ex_downstream <= cnt_other_ex_downstream + 1;
                else if (pipe_mem_any_valid & ~mem_ready_go_w)
                    cnt_other_mem_not_ready <= cnt_other_mem_not_ready + 1;
                else if (pipe_mem_any_valid & mem_ready_go_w & ~wb_allowin_w)
                    cnt_other_mem_downstream <= cnt_other_mem_downstream + 1;
                else if (redirect_recovery_window)
                    cnt_other_flush_recovery <= cnt_other_flush_recovery + 1;
                else if (if_valid & ~id_allowin_w)
                    cnt_other_frontend_backpressure <= cnt_other_frontend_backpressure + 1;
                else if (pipe_non_wb_active)
                    cnt_other_pipeline_fill_drain <= cnt_other_pipeline_fill_drain + 1;
                else
                    cnt_other_unknown <= cnt_other_unknown + 1;
            end

            // Stall
            if (id_valid & load_use_hazard_w)       cnt_load_use_stall <= cnt_load_use_stall + 1;
            if (id_valid & (load_in_ex_w | load_in_s1_ex_w))
                cnt_load_use_ex <= cnt_load_use_ex + 1;
            if (id_valid & ~(load_in_ex_w | load_in_s1_ex_w) & (load_in_mem_w | load_in_s1_mem_w))
                cnt_load_use_mem <= cnt_load_use_mem + 1;
            if (id_valid & ~(load_in_ex_w | load_in_s1_ex_w) & (load_in_mem_w | load_in_s1_mem_w) & mem_ready_go_w)
                cnt_load_use_mem_ready <= cnt_load_use_mem_ready + 1;
            if (id_valid & ~(load_in_ex_w | load_in_s1_ex_w) & (load_in_mem_w | load_in_s1_mem_w) & ~mem_ready_go_w)
                cnt_load_use_mem_blocked <= cnt_load_use_mem_blocked + 1;
            if (id_valid & ((load_in_ex_w & id_s0_uses_ex_load_w)
                          | (load_in_s1_ex_w & id_s0_uses_s1_ex_load_w)
                          | (load_in_mem_w & id_s0_uses_mem_load_w)
                          | (load_in_s1_mem_w & id_s0_uses_s1_mem_load_w)))
                cnt_load_use_s0 <= cnt_load_use_s0 + 1;
            if (id_valid & ((load_in_ex_w & id_s1_uses_ex_load_w)
                          | (load_in_s1_ex_w & id_s1_uses_s1_ex_load_w)
                          | (load_in_mem_w & id_s1_uses_mem_load_w)
                          | (load_in_s1_mem_w & id_s1_uses_s1_mem_load_w)))
                cnt_load_use_s1 <= cnt_load_use_s1 + 1;
            if (s0_lu_alu)        cnt_lu_s0_alu        <= cnt_lu_s0_alu + 1;
            if (s0_lu_branch)     cnt_lu_s0_branch     <= cnt_lu_s0_branch + 1;
            if (s0_lu_jalr)       cnt_lu_s0_jalr       <= cnt_lu_s0_jalr + 1;
            if (s0_lu_load_addr)  cnt_lu_s0_load_addr  <= cnt_lu_s0_load_addr + 1;
            if (s0_lu_store_addr) cnt_lu_s0_store_addr <= cnt_lu_s0_store_addr + 1;
            if (s0_lu_store_data) cnt_lu_s0_store_data <= cnt_lu_s0_store_data + 1;
            if (s0_lu_other)      cnt_lu_s0_other      <= cnt_lu_s0_other + 1;
            if (s0_mem_ready_alu)        cnt_lu_mem_ready_s0_alu        <= cnt_lu_mem_ready_s0_alu + 1;
            if (s0_mem_ready_branch)     cnt_lu_mem_ready_s0_branch     <= cnt_lu_mem_ready_s0_branch + 1;
            if (s0_mem_ready_jalr)       cnt_lu_mem_ready_s0_jalr       <= cnt_lu_mem_ready_s0_jalr + 1;
            if (s0_mem_ready_load_addr)  cnt_lu_mem_ready_s0_load_addr  <= cnt_lu_mem_ready_s0_load_addr + 1;
            if (s0_mem_ready_store_addr) cnt_lu_mem_ready_s0_store_addr <= cnt_lu_mem_ready_s0_store_addr + 1;
            if (s0_mem_ready_store_data) cnt_lu_mem_ready_s0_store_data <= cnt_lu_mem_ready_s0_store_data + 1;
            if (s0_mem_ready_other)      cnt_lu_mem_ready_s0_other      <= cnt_lu_mem_ready_s0_other + 1;
            if (id_valid & repair_use_hazard_w) cnt_repair_wait <= cnt_repair_wait + 1;
            if (id_valid & jalr_ex_wait_hazard_w) cnt_jalr_ex_wait <= cnt_jalr_ex_wait + 1;
            if (id_valid & s1_wb_wait_hazard_w)     cnt_s1_wb_wait     <= cnt_s1_wb_wait + 1;
            if (mem_valid & !mem_ready_go_w) cnt_dcache_stall   <= cnt_dcache_stall + 1;
            if (ex_valid & mmio_st_ld_hazard_w) cnt_mmio_stall  <= cnt_mmio_stall + 1;
            if (ex_valid & ex_is_muldiv_w & !muldiv_done_w)
                cnt_muldiv_stall <= cnt_muldiv_stall + 1;
            if (cpi_bitmanip_event)
                cnt_bitmanip_stall <= cnt_bitmanip_stall + 1;

            // Attribute every DCache-induced pipeline stall to the active FSM
            // state and, independently, to the blocked request and SB depth.
            if (dc_stall_event) begin
                if (dc_state_idle_w)
                    cnt_dc_stall_state_idle <= cnt_dc_stall_state_idle + 1;
                else if (dc_state_refill_req_w)
                    cnt_dc_stall_state_refill_req <= cnt_dc_stall_state_refill_req + 1;
                else if (dc_state_refill_data_w)
                    cnt_dc_stall_state_refill_data <= cnt_dc_stall_state_refill_data + 1;
                else if (dc_state_refill_drop_w)
                    cnt_dc_stall_state_refill_drop <= cnt_dc_stall_state_refill_drop + 1;
                else if (dc_state_done_w)
                    cnt_dc_stall_state_done <= cnt_dc_stall_state_done + 1;
                else if (dc_state_sb_req_w)
                    cnt_dc_stall_state_sb_req <= cnt_dc_stall_state_sb_req + 1;
                else if (dc_state_sb_resp_w)
                    cnt_dc_stall_state_sb_resp <= cnt_dc_stall_state_sb_resp + 1;
                else
                    cnt_dc_stall_state_other <= cnt_dc_stall_state_other + 1;

                if (dc_mem_req_w & dc_mem_wr_w)
                    cnt_dc_stall_req_store <= cnt_dc_stall_req_store + 1;
                else if (dc_mem_req_w)
                    cnt_dc_stall_req_load <= cnt_dc_stall_req_load + 1;
                else
                    cnt_dc_stall_req_other <= cnt_dc_stall_req_other + 1;

                if (dc_mem_req_w & dc_tag_hit_w)
                    cnt_dc_stall_tag_hit <= cnt_dc_stall_tag_hit + 1;
                else if (dc_mem_req_w)
                    cnt_dc_stall_tag_miss <= cnt_dc_stall_tag_miss + 1;

                case (dc_sb_pending_w)
                    2'b00: cnt_dc_stall_sb_occ0 <= cnt_dc_stall_sb_occ0 + 1;
                    2'b11: cnt_dc_stall_sb_occ2 <= cnt_dc_stall_sb_occ2 + 1;
                    default: cnt_dc_stall_sb_occ1 <= cnt_dc_stall_sb_occ1 + 1;
                endcase
            end

            // Count one RV32M request at unit entry, while retaining wait
            // cycles per op for direct average-latency calculation.
            if (muldiv_start_event)
                cnt_muldiv_issue[muldiv_start_op_w]
                    <= cnt_muldiv_issue[muldiv_start_op_w] + 1;
            if (cpi_muldiv_event)
                cnt_muldiv_wait_op[ex_muldiv_op_w]
                    <= cnt_muldiv_wait_op[ex_muldiv_op_w] + 1;

            if (muldiv_profile_active) begin
                if (muldiv_profile_abort_event) begin
                    cnt_muldiv_abort <= cnt_muldiv_abort + 1;
                    muldiv_profile_active <= 1'b0;
                    muldiv_profile_latency <= 8'd0;
                end else if (muldiv_done_w) begin
                    cnt_muldiv_complete <= cnt_muldiv_complete + 1;
                    if (muldiv_profile_latency <= 8'd1)
                        cnt_muldiv_lat1 <= cnt_muldiv_lat1 + 1;
                    else if (muldiv_profile_latency == 8'd2)
                        cnt_muldiv_lat2 <= cnt_muldiv_lat2 + 1;
                    else if (muldiv_profile_latency <= 8'd4)
                        cnt_muldiv_lat3_4 <= cnt_muldiv_lat3_4 + 1;
                    else if (muldiv_profile_latency <= 8'd8)
                        cnt_muldiv_lat5_8 <= cnt_muldiv_lat5_8 + 1;
                    else if (muldiv_profile_latency <= 8'd16)
                        cnt_muldiv_lat9_16 <= cnt_muldiv_lat9_16 + 1;
                    else
                        cnt_muldiv_lat17plus <= cnt_muldiv_lat17plus + 1;
                    // Same-edge consume/prestart completes the old request and
                    // immediately begins profiling the younger MUL.
                    if (muldiv_start_event) begin
                        muldiv_profile_active <= 1'b1;
                        muldiv_profile_latency <= 8'd1;
                    end else begin
                        muldiv_profile_active <= 1'b0;
                        muldiv_profile_latency <= 8'd0;
                    end
                end else if (&muldiv_profile_latency) begin
                    muldiv_profile_latency <= muldiv_profile_latency;
                end else begin
                    muldiv_profile_latency <= muldiv_profile_latency + 1'b1;
                end
            end else if (muldiv_start_event) begin
                muldiv_profile_active <= 1'b1;
                muldiv_profile_latency <= 8'd1;
            end

            if (bitmanip_start_event) begin
                cnt_bitmanip_issue <= cnt_bitmanip_issue + 1;
                if (bitmanip_is_clmul_w)
                    cnt_bitmanip_issue_clmul <= cnt_bitmanip_issue_clmul + 1;
                else
                    cnt_bitmanip_issue_fast <= cnt_bitmanip_issue_fast + 1;
                bitmanip_profile_active <= 1'b1;
                bitmanip_profile_latency <= 8'd1;
            end else if (bitmanip_profile_active) begin
                if (bitmanip_profile_abort_event) begin
                    cnt_bitmanip_abort <= cnt_bitmanip_abort + 1;
                    bitmanip_profile_active <= 1'b0;
                    bitmanip_profile_latency <= 8'd0;
                end else if (bitmanip_done_w) begin
                    cnt_bitmanip_complete <= cnt_bitmanip_complete + 1;
                    if (bitmanip_profile_latency <= 8'd1)
                        cnt_bitmanip_lat1 <= cnt_bitmanip_lat1 + 1;
                    else if (bitmanip_profile_latency == 8'd2)
                        cnt_bitmanip_lat2 <= cnt_bitmanip_lat2 + 1;
                    else if (bitmanip_profile_latency <= 8'd4)
                        cnt_bitmanip_lat3_4 <= cnt_bitmanip_lat3_4 + 1;
                    else if (bitmanip_profile_latency <= 8'd8)
                        cnt_bitmanip_lat5_8 <= cnt_bitmanip_lat5_8 + 1;
                    else if (bitmanip_profile_latency <= 8'd16)
                        cnt_bitmanip_lat9_16 <= cnt_bitmanip_lat9_16 + 1;
                    else
                        cnt_bitmanip_lat17plus <= cnt_bitmanip_lat17plus + 1;
                    bitmanip_profile_active <= 1'b0;
                    bitmanip_profile_latency <= 8'd0;
                end else if (&bitmanip_profile_latency) begin
                    bitmanip_profile_latency <= bitmanip_profile_latency;
                end else begin
                    bitmanip_profile_latency
                        <= bitmanip_profile_latency + 1'b1;
                end
            end

            cnt_lsu_cache_load <= cnt_lsu_cache_load
                                + (lsu_s0_load_done & is_cacheable_mem_w)
                                + (lsu_s1_load_done & mem_s1_is_cacheable_w);
            cnt_lsu_mmio_load <= cnt_lsu_mmio_load
                               + (lsu_s0_load_done & ~is_cacheable_mem_w)
                               + (lsu_s1_load_done & ~mem_s1_is_cacheable_w);
            cnt_lsu_cache_store <= cnt_lsu_cache_store
                                 + (lsu_s0_store_done & is_cacheable_mem_w)
                                 + (lsu_s1_store_done & mem_s1_is_cacheable_w);
            cnt_lsu_mmio_store <= cnt_lsu_mmio_store
                                + (lsu_s0_store_done & ~is_cacheable_mem_w)
                                + (lsu_s1_store_done & ~mem_s1_is_cacheable_w);

            if (dc_hit_accept_w | dc_miss_start_w) cnt_dc_req <= cnt_dc_req + 1;
            if (dc_load_hit_w | dc_load_miss_w)    cnt_dc_load_req <= cnt_dc_load_req + 1;
            if (dc_store_hit_w | dc_store_miss_w)  cnt_dc_store_req <= cnt_dc_store_req + 1;
            if (dc_hit_accept_w)                   cnt_dc_hit <= cnt_dc_hit + 1;
            if (dc_load_hit_w)                     cnt_dc_load_hit <= cnt_dc_load_hit + 1;
            if (dc_store_hit_w)                    cnt_dc_store_hit <= cnt_dc_store_hit + 1;
            if (dc_miss_start_w)                   cnt_dc_miss <= cnt_dc_miss + 1;
            if (dc_load_miss_w)                    cnt_dc_load_miss <= cnt_dc_load_miss + 1;
            if (dc_store_miss_w)                   cnt_dc_store_miss <= cnt_dc_store_miss + 1;
            if (dc_refill_cycle_w)                 cnt_dc_refill_cycles <= cnt_dc_refill_cycles + 1;
            if (tb_riscv_tests.u_dcache.refill_cache_write) cnt_dc_refill_words <= cnt_dc_refill_words + 1;
            if (dc_refill_abort_w)                 cnt_dc_refill_aborts <= cnt_dc_refill_aborts + 1;
            if (tb_riscv_tests.u_dcache.sb_store_enqueue) cnt_dc_sb_enqueue <= cnt_dc_sb_enqueue + 1;
            if (dc_sb_drain_w)                     cnt_dc_sb_drain <= cnt_dc_sb_drain + 1;
            if (dc_sb_block_w)                     cnt_dc_sb_block_cycles <= cnt_dc_sb_block_cycles + 1;
            if (tb_riscv_tests.u_dcache.sb_conflict) cnt_dc_sb_conflicts <= cnt_dc_sb_conflicts + 1;
            if (dc_store_forward_hit_w)            cnt_dc_store_forward_hits <= cnt_dc_store_forward_hits + 1;
            if (dc_miss_buffer_hit_w)               cnt_dc_miss_buffer_hits <= cnt_dc_miss_buffer_hits + 1;

            if (dc_state_sb_req_w)
                cnt_dc_drain_req_cycles <= cnt_dc_drain_req_cycles + 1;
            if (dc_state_sb_resp_w)
                cnt_dc_drain_resp_cycles <= cnt_dc_drain_resp_cycles + 1;
            if (dc_state_sb_req_w & dc_stall_event)
                cnt_dc_drain_req_stall <= cnt_dc_drain_req_stall + 1;
            if (dc_state_sb_resp_w & dc_stall_event)
                cnt_dc_drain_resp_stall <= cnt_dc_drain_resp_stall + 1;
            if (dc_drain_stall_w) begin
                if (dc_mem_req_w & dc_mem_wr_w)
                    cnt_dc_drain_stall_store <= cnt_dc_drain_stall_store + 1;
                else if (dc_mem_req_w)
                    cnt_dc_drain_stall_load <= cnt_dc_drain_stall_load + 1;
                else
                    cnt_dc_drain_stall_other <= cnt_dc_drain_stall_other + 1;
            end
            if (dc_pending_w)
                cnt_dc_drain_pending_cycles <= cnt_dc_drain_pending_cycles + 1;
            if (dc_drain_read_overlap_w)
                cnt_dc_drain_read_overlap <= cnt_dc_drain_read_overlap + 1;
            if (dc_drain_read_collision_w)
                cnt_dc_drain_read_collision <= cnt_dc_drain_read_collision + 1;
            if (dc_drain_push_overlap_w)
                cnt_dc_drain_push_overlap <= cnt_dc_drain_push_overlap + 1;

            // Measure only the initiating load's cpu_ready=0 cycles. Remaining
            // line-fill activity and younger memory requests are excluded.
            if (dc_primary_refill_start_w) begin
                cnt_dc_primary_refill_starts <= cnt_dc_primary_refill_starts + 1;
                dc_primary_refill_waiting <= 1'b1;
                dc_primary_refill_latency <= 16'd1;
            end else if (dc_primary_refill_waiting) begin
                if (dc_primary_refill_ready_w) begin
                    cnt_dc_primary_refill_completes <= cnt_dc_primary_refill_completes + 1;
                    cnt_dc_primary_refill_stall_cycles
                        <= cnt_dc_primary_refill_stall_cycles
                         + dc_primary_refill_latency;
                    case (dc_primary_refill_latency)
                        16'd1: cnt_dc_primary_refill_lat1 <= cnt_dc_primary_refill_lat1 + 1;
                        16'd2: cnt_dc_primary_refill_lat2 <= cnt_dc_primary_refill_lat2 + 1;
                        16'd3: cnt_dc_primary_refill_lat3 <= cnt_dc_primary_refill_lat3 + 1;
                        default:
                            cnt_dc_primary_refill_lat4plus <= cnt_dc_primary_refill_lat4plus + 1;
                    endcase
                    dc_primary_refill_waiting <= 1'b0;
                    dc_primary_refill_latency <= 16'd0;
                end else if (dc_primary_refill_cancel_w) begin
                    cnt_dc_primary_refill_aborts <= cnt_dc_primary_refill_aborts + 1;
                    dc_primary_refill_waiting <= 1'b0;
                    dc_primary_refill_latency <= 16'd0;
                end else begin
                    dc_primary_refill_latency <= dc_primary_refill_latency + 1'b1;
                end
            end

            if (raw_id_stall_event) cnt_raw_id_stall <= cnt_raw_id_stall + 1;
            if (raw_nr_ex_load_event | raw_nr_mem_load_wait_event | raw_nr_muldiv_event)
                cnt_raw_not_ready_total <= cnt_raw_not_ready_total + 1;
            if (raw_nr_ex_load_event) cnt_raw_not_ready_ex_load <= cnt_raw_not_ready_ex_load + 1;
            if (raw_nr_mem_load_wait_event) cnt_raw_not_ready_mem_load_wait <= cnt_raw_not_ready_mem_load_wait + 1;
            if (raw_nr_muldiv_event) cnt_raw_not_ready_muldiv_dep <= cnt_raw_not_ready_muldiv_dep + 1;

            if (raw_ready_mem_load_no_fwd_event | raw_ready_repair_event
              | raw_ready_branch_ex_event | raw_ready_jalr_ex_event | raw_ready_other_event)
                cnt_raw_ready_no_fwd_total <= cnt_raw_ready_no_fwd_total + 1;
            if (raw_ready_mem_load_no_fwd_event) begin
                cnt_raw_ready_mem_load_no_fwd <= cnt_raw_ready_mem_load_no_fwd + 1;
                if (s0_mem_ready_branch)     cnt_raw_ready_mem_load_s0_branch <= cnt_raw_ready_mem_load_s0_branch + 1;
                if (s0_mem_ready_jalr)       cnt_raw_ready_mem_load_s0_jalr <= cnt_raw_ready_mem_load_s0_jalr + 1;
                if (s0_mem_ready_load_addr)  cnt_raw_ready_mem_load_s0_load_addr <= cnt_raw_ready_mem_load_s0_load_addr + 1;
                if (s0_mem_ready_store_addr) cnt_raw_ready_mem_load_s0_store_addr <= cnt_raw_ready_mem_load_s0_store_addr + 1;
                if (s0_mem_ready_store_data) cnt_raw_ready_mem_load_s0_store_data <= cnt_raw_ready_mem_load_s0_store_data + 1;
                if (id_s1_uses_mem_load_w | id_s1_uses_s1_mem_load_w)
                    cnt_raw_ready_mem_load_s1 <= cnt_raw_ready_mem_load_s1 + 1;
            end
            if (raw_ready_repair_event) begin
                cnt_raw_ready_repair_chain <= cnt_raw_ready_repair_chain + 1;
                if (repair_rs1_dep) cnt_raw_ready_repair_rs1 <= cnt_raw_ready_repair_rs1 + 1;
                if (repair_rs2_dep) cnt_raw_ready_repair_rs2 <= cnt_raw_ready_repair_rs2 + 1;
            end
            if (raw_ready_branch_ex_event) begin
                cnt_raw_ready_branch_ex_no_fwd <= cnt_raw_ready_branch_ex_no_fwd + 1;
                if (branch_ex_rs1_dep) cnt_raw_ready_branch_ex_rs1 <= cnt_raw_ready_branch_ex_rs1 + 1;
                if (branch_ex_rs2_dep) cnt_raw_ready_branch_ex_rs2 <= cnt_raw_ready_branch_ex_rs2 + 1;
                if (branch_ex_s0_prod) cnt_raw_ready_branch_ex_s0_prod <= cnt_raw_ready_branch_ex_s0_prod + 1;
                if (branch_ex_s1_prod) cnt_raw_ready_branch_ex_s1_prod <= cnt_raw_ready_branch_ex_s1_prod + 1;
            end
            if (raw_ready_jalr_ex_event) begin
                cnt_raw_ready_jalr_ex_no_fwd <= cnt_raw_ready_jalr_ex_no_fwd + 1;
                if (s0_rs1_s0_ex_hit_w) cnt_raw_ready_jalr_ex_s0_prod <= cnt_raw_ready_jalr_ex_s0_prod + 1;
                if (s0_rs1_s1_ex_hit_w) cnt_raw_ready_jalr_ex_s1_prod <= cnt_raw_ready_jalr_ex_s1_prod + 1;
            end
            if (raw_ready_other_event) cnt_raw_ready_other_no_fwd <= cnt_raw_ready_other_no_fwd + 1;
            if (raw_id_stall_event & ~raw_classified_id_stall)
                cnt_raw_unclassified_stall <= cnt_raw_unclassified_stall + 1;

            // Flush
            if (pred_s0_mispredict_event) cnt_branch_flush <= cnt_branch_flush + 1;
            if (pred_s0_ctrl_event)
                cnt_total_branch <= cnt_total_branch + 1;
            if ((pred_s0_mispredict_event & (ex_is_jal | ex_is_jalr))
                | (ex_s1_branch_redirect_w & ex_s1_valid & ex_s1_is_jal_w))
                cnt_jcall_redirect <= cnt_jcall_redirect + 1;

            if (pred_s0_ctrl_event) begin
                cnt_pred_s0_ctrl <= cnt_pred_s0_ctrl + 1;
                if (ex_is_branch) cnt_pred_s0_branch <= cnt_pred_s0_branch + 1;
                if (ex_is_jal)    cnt_pred_s0_jal <= cnt_pred_s0_jal + 1;
                if (ex_is_jalr)   cnt_pred_s0_jalr <= cnt_pred_s0_jalr + 1;
                if (ex_pred_taken_w)   cnt_pred_s0_pred_taken <= cnt_pred_s0_pred_taken + 1;
                if (actual_taken_w)  cnt_pred_s0_actual_taken <= cnt_pred_s0_actual_taken + 1;
            end
            if (pred_s0_mispredict_event)
                cnt_pred_s0_mispredict <= cnt_pred_s0_mispredict + 1;
            if (pred_s0_dir_to_taken_event)
                cnt_pred_s0_dir_to_taken <= cnt_pred_s0_dir_to_taken + 1;
            if (pred_s0_dir_to_fallthrough_event)
                cnt_pred_s0_dir_to_fallthrough <= cnt_pred_s0_dir_to_fallthrough + 1;
            if (pred_s0_target_wrong_event)
                cnt_pred_s0_target_wrong <= cnt_pred_s0_target_wrong + 1;

            if (pred_s1_ctrl_event) begin
                cnt_pred_s1_ctrl <= cnt_pred_s1_ctrl + 1;
                if (ex_s1_is_branch_w) cnt_pred_s1_branch <= cnt_pred_s1_branch + 1;
                if (ex_s1_is_jal_w)    cnt_pred_s1_jal <= cnt_pred_s1_jal + 1;
                if (ex_s1_is_jalr_w)   cnt_pred_s1_jalr <= cnt_pred_s1_jalr + 1;
                if (ex_s1_pred_taken_w) cnt_pred_s1_pred_taken <= cnt_pred_s1_pred_taken + 1;
                if (ex_s1_actual_taken_w) cnt_pred_s1_actual_taken <= cnt_pred_s1_actual_taken + 1;
            end
            if (pred_s1_dir_wrong_event) cnt_pred_s1_dir_wrong <= cnt_pred_s1_dir_wrong + 1;
            if (pred_s1_target_wrong_event) cnt_pred_s1_target_wrong <= cnt_pred_s1_target_wrong + 1;
            if (ex_s1_branch_redirect_w) cnt_pred_s1_redirect <= cnt_pred_s1_redirect + 1;

            if (pred_s0_mispredict_event & ex_is_branch)
                cnt_ctrl_miss_s0_branch <= cnt_ctrl_miss_s0_branch + 1;
            if (pred_s0_mispredict_event & ex_is_jal)
                cnt_ctrl_miss_s0_jal <= cnt_ctrl_miss_s0_jal + 1;
            if (pred_s0_mispredict_event & ex_is_jalr)
                cnt_ctrl_miss_s0_jalr <= cnt_ctrl_miss_s0_jalr + 1;
            if (ex_s1_branch_redirect_w & ex_s1_is_branch_w)
                cnt_ctrl_miss_s1_branch <= cnt_ctrl_miss_s1_branch + 1;
            if (ex_s1_branch_redirect_w & ex_s1_is_jal_w)
                cnt_ctrl_miss_s1_jal <= cnt_ctrl_miss_s1_jal + 1;
            if (ex_s1_branch_redirect_w & ex_s1_is_jalr_w)
                cnt_ctrl_miss_s1_jalr <= cnt_ctrl_miss_s1_jalr + 1;

            if (ex_s0_accept_event) cnt_mix_s0_accept <= cnt_mix_s0_accept + 1;
            if (ex_s1_accept_event) cnt_mix_s1_accept <= cnt_mix_s1_accept + 1;
            cnt_mix_alu <= cnt_mix_alu
                         + (ex_s0_accept_event & mix_s0_alu)
                         + (ex_s1_accept_event & mix_s1_alu);
            cnt_mix_load <= cnt_mix_load
                          + (ex_s0_accept_event & ex_mem_read_w)
                          + (ex_s1_accept_event & ex_s1_mem_read_w);
            cnt_mix_store <= cnt_mix_store
                           + (ex_s0_accept_event & ex_mem_write_w)
                           + (ex_s1_accept_event & ex_s1_mem_write_w);
            cnt_mix_branch <= cnt_mix_branch
                            + (ex_s0_accept_event & ex_is_branch)
                            + (ex_s1_accept_event & ex_s1_is_branch_w);
            cnt_mix_jal <= cnt_mix_jal
                         + (ex_s0_accept_event & ex_is_jal)
                         + (ex_s1_accept_event & ex_s1_is_jal_w);
            cnt_mix_jalr <= cnt_mix_jalr
                          + (ex_s0_accept_event & ex_is_jalr)
                          + (ex_s1_accept_event & ex_s1_is_jalr_w);
            cnt_mix_muldiv <= cnt_mix_muldiv
                            + (ex_s0_accept_event & ex_is_muldiv_w)
                            + (ex_s1_accept_event & mix_s1_muldiv);
            cnt_mix_system <= cnt_mix_system
                            + (ex_s0_accept_event & mix_s0_system)
                            + (ex_s1_accept_event & mix_s1_system);
            if (ex_s0_accept_event & ex_is_bitmanip_w)
                cnt_mix_bitmanip <= cnt_mix_bitmanip + 1;
            if (ex_s1_accept_event & ~mix_s1_known)
                cnt_mix_other <= cnt_mix_other + 1;

            if (tb_riscv_tests.u_cpu.pred_train_valid) begin
                cnt_pred_train_total <= cnt_pred_train_total + 1;
                if (tb_riscv_tests.u_cpu.pred_train_from_s1)
                    cnt_pred_train_s1 <= cnt_pred_train_s1 + 1;
                else
                    cnt_pred_train_s0 <= cnt_pred_train_s0 + 1;
                if (tb_riscv_tests.u_cpu.pred_train_is_branch)
                    cnt_pred_train_branch <= cnt_pred_train_branch + 1;
                if (tb_riscv_tests.u_cpu.pred_train_is_jal)
                    cnt_pred_train_jal <= cnt_pred_train_jal + 1;
                if (tb_riscv_tests.u_cpu.pred_train_is_jalr)
                    cnt_pred_train_jalr <= cnt_pred_train_jalr + 1;
            end

            if (fe_bp0_fire_w) cnt_fe_bp0_fire <= cnt_fe_bp0_fire + 1;
            if (fe_bp0_block_ftq_full_w)
                cnt_fe_bp0_block_ftq_full <= cnt_fe_bp0_block_ftq_full + 1;
            if (fe_bp0_block_fq_credit_w)
                cnt_fe_bp0_block_fq_credit <= cnt_fe_bp0_block_fq_credit + 1;
            if (fe_redirect_valid_w) cnt_fe_redirect_total <= cnt_fe_redirect_total + 1;
            if (fe_ex_redirect_valid_w) cnt_fe_redirect_ex <= cnt_fe_redirect_ex + 1;
            if (fe_f0_valid_w) cnt_fe_f0_valid <= cnt_fe_f0_valid + 1;
            if (fe_f0_accept_base_w) cnt_fe_f0_accept <= cnt_fe_f0_accept + 1;
            if (fe_f0_valid_w & ~fe_f0_epoch_match_w & ~fe_ex_redirect_valid_w)
                cnt_fe_f0_epoch_miss <= cnt_fe_f0_epoch_miss + 1;
            if (fe_f0_valid_w & fe_ex_redirect_valid_w)
                cnt_fe_f0_ex_kill <= cnt_fe_f0_ex_kill + 1;
            if (fe_f0_enq0_valid_w) cnt_fe_f0_enq0 <= cnt_fe_f0_enq0 + 1;
            if (fe_f0_enq1_valid_w) cnt_fe_f0_enq1 <= cnt_fe_f0_enq1 + 1;
            if (fe_f0_accept_base_w & fe_f0_enq_none_w)
                cnt_fe_f0_enq_none <= cnt_fe_f0_enq_none + 1;
            if (fe_f0_enq0_valid_w & fe_f0_kill_after_slot0_w)
                cnt_fe_f0_kill_slot0 <= cnt_fe_f0_kill_slot0 + 1;
            if (fe_if_accept_w) cnt_fe_if_accept <= cnt_fe_if_accept + 1;
            if (fe_if_accept_dual_w) cnt_fe_if_accept_dual <= cnt_fe_if_accept_dual + 1;
            if (fe_if_accept_single_w) cnt_fe_if_accept_single <= cnt_fe_if_accept_single + 1;
            if (!fe_fq_has_slot0_w) cnt_fe_if_empty <= cnt_fe_if_empty + 1;
            if (fe_fq_has_slot0_w) cnt_fe_fq_nonempty_cycles <= cnt_fe_fq_nonempty_cycles + 1;
            if (fe_fq_has_slot1_w & tb_riscv_tests.u_cpu.u_frontend_ftq.can_dual_issue)
                cnt_fe_fq_pair_ready_cycles <= cnt_fe_fq_pair_ready_cycles + 1;
            cnt_fe_fq_occupancy_sum <= cnt_fe_fq_occupancy_sum + fe_fq_count_w;
            cnt_fe_ftq_occupancy_sum <= cnt_fe_ftq_occupancy_sum + fe_ftq_count_w;

            // Dual-issue analysis (only on raw path, when not held)
            if (if_valid & !irom_held_valid) begin
                cnt_fetch_valid <= cnt_fetch_valid + 1;
                if (pc[2])             cnt_pc2_fetch      <= cnt_pc2_fetch + 1;
                if (!if_seq_fetch)       cnt_not_sequential <= cnt_not_sequential + 1;
                else if (!raw_inst1_alu) cnt_inst1_not_alu  <= cnt_inst1_not_alu + 1;
                else if (raw_pair_raw_w) cnt_raw_block      <= cnt_raw_block + 1;
                else if (raw_inst0_jump) cnt_inst0_jump     <= cnt_inst0_jump + 1;
            end
            if (can_dual_w & if_valid) cnt_dual_issued <= cnt_dual_issued + 1;

            // Precise IF-accept view. This counts each instruction pair once
            // when it enters IF/ID, so stalls do not repeatedly inflate blockers.
            if (if_accept_w) begin
                cnt_if_accept <= cnt_if_accept + 1;

                if (if_s0_is_muldiv) cnt_if_s0_muldiv_seen <= cnt_if_s0_muldiv_seen + 1;
                else if (if_s0_is_load) cnt_if_s0_load_seen <= cnt_if_s0_load_seen + 1;
                else if (if_s0_is_store) cnt_if_s0_store_seen <= cnt_if_s0_store_seen + 1;
                else if (if_s0_is_control) cnt_if_s0_control_seen <= cnt_if_s0_control_seen + 1;
                else if (if_s0_is_alu_type) cnt_if_s0_alu_seen <= cnt_if_s0_alu_seen + 1;

                if (if_s1_valid_w) begin
                    cnt_if_s1_accept <= cnt_if_s1_accept + 1;
                    if (if_s1_is_alu_type) cnt_if_s1_alu_accept <= cnt_if_s1_alu_accept + 1;
                    else if (if_s1_is_branch) cnt_if_s1_branch_accept <= cnt_if_s1_branch_accept + 1;
                    else if (if_s1_is_load) cnt_if_s1_load_accept <= cnt_if_s1_load_accept + 1;
                    else if (if_s1_is_store) cnt_if_s1_store_accept <= cnt_if_s1_store_accept + 1;
                    else if (if_s1_is_jal) cnt_if_s1_jal_accept <= cnt_if_s1_jal_accept + 1;
                end else begin
                    cnt_if_s1_block <= cnt_if_s1_block + 1;
                    if (!if_seq_fetch) begin
                        cnt_if_block_not_seq <= cnt_if_block_not_seq + 1;
                    end else if (if_skip_out_w | (if_pc_out_w == 32'h7FFF_FFFC)) begin
                        cnt_if_block_other <= cnt_if_block_other + 1;
                    end else if (if_pair_raw) begin
                        cnt_if_block_raw <= cnt_if_block_raw + 1;
                        if (if_pair_raw_rs1) cnt_if_block_raw_rs1 <= cnt_if_block_raw_rs1 + 1;
                        if (if_pair_raw_rs2) cnt_if_block_raw_rs2 <= cnt_if_block_raw_rs2 + 1;
                    end else if (if_s0_is_muldiv) begin
                        cnt_if_block_s0_muldiv <= cnt_if_block_s0_muldiv + 1;
                    end else if (if_s1_is_alu_type & if_s0_is_jump) begin
                        cnt_if_block_s0_jump <= cnt_if_block_s0_jump + 1;
                    end else if (if_s1_s0_policy_blocked) begin
                        cnt_if_block_s1_branch_s0 <= cnt_if_block_s1_branch_s0 + 1;
                    end else if (if_s1_unsupported) begin
                        cnt_if_block_s1_unsupported <= cnt_if_block_s1_unsupported + 1;
                    end else begin
                        cnt_if_block_other <= cnt_if_block_other + 1;
                    end

                    if (if_s1_unsup_reason) begin
                        if (if_s1_is_load) cnt_if_s1_unsup_load <= cnt_if_s1_unsup_load + 1;
                        else if (if_s1_is_store) cnt_if_s1_unsup_store <= cnt_if_s1_unsup_store + 1;
                        else if (if_s1_is_muldiv) cnt_if_s1_unsup_muldiv <= cnt_if_s1_unsup_muldiv + 1;
                        else if (if_s1_is_jal) cnt_if_s1_unsup_jal <= cnt_if_s1_unsup_jal + 1;
                        else if (if_s1_is_jalr) cnt_if_s1_unsup_jalr <= cnt_if_s1_unsup_jalr + 1;
                        else if (if_s1_is_system) cnt_if_s1_unsup_system <= cnt_if_s1_unsup_system + 1;
                        else cnt_if_s1_unsup_other <= cnt_if_s1_unsup_other + 1;
                    end

                    // Exact, mutually-exclusive rejection reason. The old
                    // opcode heuristic above is retained for log compatibility.
                    if (!fe_fq_has_slot1_w) begin
                        cnt_pair_block_no_candidate <= cnt_pair_block_no_candidate + 1;
                    end else if (!pair_head_contiguous_w) begin
                        cnt_pair_block_noncontiguous <= cnt_pair_block_noncontiguous + 1;
                    end else if (pair_head0_pred_taken_w) begin
                        cnt_pair_block_s0_pred_taken <= cnt_pair_block_s0_pred_taken + 1;
                    end else if (pair_head0_force_single_w) begin
                        cnt_pair_block_s0_force_single <= cnt_pair_block_s0_force_single + 1;
                    end else if (pair_head1_force_single_w) begin
                        cnt_pair_block_s1_force_single <= cnt_pair_block_s1_force_single + 1;
                    end else if (pair_head_raw_w) begin
                        if (pair_head0_is_alu_w)
                            cnt_pair_raw_prod_alu <= cnt_pair_raw_prod_alu + 1;
                        else if (pair_head0_is_load_w)
                            cnt_pair_raw_prod_load <= cnt_pair_raw_prod_load + 1;
                        else if (pair_head0_is_cfi_w)
                            cnt_pair_raw_prod_cfi <= cnt_pair_raw_prod_cfi + 1;
                        else
                            cnt_pair_raw_prod_other <= cnt_pair_raw_prod_other + 1;

                        if (pair_head1_is_alu_w)
                            cnt_pair_raw_cons_alu <= cnt_pair_raw_cons_alu + 1;
                        else if (pair_head1_is_load_w)
                            cnt_pair_raw_cons_load <= cnt_pair_raw_cons_load + 1;
                        else if (pair_head1_is_store_w)
                            cnt_pair_raw_cons_store <= cnt_pair_raw_cons_store + 1;
                        else if (pair_head1_is_branch_w)
                            cnt_pair_raw_cons_branch <= cnt_pair_raw_cons_branch + 1;
                        else if (pair_head1_is_jalr_w)
                            cnt_pair_raw_cons_jalr <= cnt_pair_raw_cons_jalr + 1;
                        else
                            cnt_pair_raw_cons_other <= cnt_pair_raw_cons_other + 1;

                        if (pair_head0_is_alu_w) begin
                            if (pair_head1_is_alu_w)
                                cnt_pair_raw_alu_to_alu <= cnt_pair_raw_alu_to_alu + 1;
                            else if (pair_head1_is_load_w)
                                cnt_pair_raw_alu_to_load <= cnt_pair_raw_alu_to_load + 1;
                            else if (pair_head1_is_store_w)
                                cnt_pair_raw_alu_to_store <= cnt_pair_raw_alu_to_store + 1;
                            else if (pair_head1_is_branch_w)
                                cnt_pair_raw_alu_to_branch <= cnt_pair_raw_alu_to_branch + 1;
                            else if (pair_head1_is_jalr_w)
                                cnt_pair_raw_alu_to_jalr <= cnt_pair_raw_alu_to_jalr + 1;
                            else
                                cnt_pair_raw_alu_to_other <= cnt_pair_raw_alu_to_other + 1;
                        end else if (pair_head0_is_load_w) begin
                            if (pair_head1_is_alu_w)
                                cnt_pair_raw_load_to_alu <= cnt_pair_raw_load_to_alu + 1;
                            else if (pair_head1_is_load_w)
                                cnt_pair_raw_load_to_load <= cnt_pair_raw_load_to_load + 1;
                            else if (pair_head1_is_store_w)
                                cnt_pair_raw_load_to_store <= cnt_pair_raw_load_to_store + 1;
                            else if (pair_head1_is_branch_w)
                                cnt_pair_raw_load_to_branch <= cnt_pair_raw_load_to_branch + 1;
                            else if (pair_head1_is_jalr_w)
                                cnt_pair_raw_load_to_jalr <= cnt_pair_raw_load_to_jalr + 1;
                            else
                                cnt_pair_raw_load_to_other <= cnt_pair_raw_load_to_other + 1;
                        end

                        if (pair_head1_is_store_w & pair_head_raw_rs1_w)
                            cnt_pair_raw_store_addr <= cnt_pair_raw_store_addr + 1;
                        if (pair_head1_is_store_w & pair_head_raw_rs2_w)
                            cnt_pair_raw_store_data <= cnt_pair_raw_store_data + 1;
                        if (pair_head0_is_alu_w & pair_head1_is_store_w
                            & pair_head_raw_rs1_w)
                            cnt_pair_raw_alu_to_store_addr
                                <= cnt_pair_raw_alu_to_store_addr + 1;
                        if (pair_head0_is_alu_w & pair_head1_is_store_w
                            & pair_head_raw_rs2_w)
                            cnt_pair_raw_alu_to_store_data
                                <= cnt_pair_raw_alu_to_store_data + 1;
                    end else if (!pair_head0_supported_w) begin
                        cnt_pair_block_s0_unsupported <= cnt_pair_block_s0_unsupported + 1;
                    end else if (!pair_head1_supported_w) begin
                        cnt_pair_block_s1_unsupported_exact
                            <= cnt_pair_block_s1_unsupported_exact + 1;
                    end else if (pair_head0_is_lsu_w & pair_head1_is_lsu_w) begin
                        cnt_pair_block_both_lsu <= cnt_pair_block_both_lsu + 1;
                    end else if (pair_head0_is_cfi_w & pair_head1_is_cfi_w) begin
                        cnt_pair_block_both_cfi <= cnt_pair_block_both_cfi + 1;
                    end else begin
                        // Captures stored pair-policy mismatches or a future
                        // frontend rule not represented by the current metadata.
                        cnt_pair_block_stored_other <= cnt_pair_block_stored_other + 1;
                    end
                end
            end
            if (id_s1_valid)  cnt_id_s1_seen  <= cnt_id_s1_seen + 1;
            if (ex_s1_valid)  cnt_ex_s1_seen  <= cnt_ex_s1_seen + 1;
            if (pair_bypass_alu_to_store_data_w)
                cnt_pair_bypass_alu_to_store_data
                    <= cnt_pair_bypass_alu_to_store_data + 1;
            if (mem_s1_valid) cnt_mem_s1_seen <= cnt_mem_s1_seen + 1;

            // skip_inst0 analysis
            if (skip_inst0_w)                     cnt_skip_inst0     <= cnt_skip_inst0 + 1;
            if (skip_inst0_w & pred_taken_w)        cnt_skip_and_pred_taken <= cnt_skip_and_pred_taken + 1;
            if (if_valid & !irom_held_valid & (predict_dual_w != can_dual_w))
                cnt_predict_dual_err <= cnt_predict_dual_err + 1;

            // Forwarding (sample when ID valid)
            if (id_valid & id_ready_go_w) begin
                if      (fwd_s1_ex)  cnt_fwd_s1_ex  <= cnt_fwd_s1_ex + 1;
                else if (fwd_s0_ex)  cnt_fwd_s0_ex  <= cnt_fwd_s0_ex + 1;
                else if (fwd_s1_mem) cnt_fwd_s1_mem <= cnt_fwd_s1_mem + 1;
                else if (fwd_s0_mem) cnt_fwd_s0_mem <= cnt_fwd_s0_mem + 1;
                else if (fwd_s1_wb)  cnt_fwd_s1_wb  <= cnt_fwd_s1_wb + 1;
                else if (fwd_s0_wb)  cnt_fwd_s0_wb  <= cnt_fwd_s0_wb + 1;
                else                 cnt_fwd_rf     <= cnt_fwd_rf + 1;
            end
        end
    end

    // ================================================================
    //  Report (called from TB)
    // ================================================================
    task print_report;
        longint unsigned total_insts, total_fwd, cpi_stack_total;
        longint unsigned commit_cycle_total, ideal_slots, retired_slots;
        longint unsigned lost_slots, lost_no_commit_slots, lost_single_issue_slots;
        longint unsigned loss_no_commit_total, loss_stack_total;
        longint signed loss_stack_mismatch, loss_no_commit_mismatch;
        longint unsigned mix_accept_total, mix_classified_total;
        longint signed mix_classification_mismatch, mix_commit_delta;
        longint unsigned ctrl_resolved_total, ctrl_miss_total;
        longint unsigned ctrl_branch_total, ctrl_jal_total, ctrl_jalr_total;
        longint unsigned ctrl_branch_miss, ctrl_jal_miss, ctrl_jalr_miss;
        longint signed ctrl_miss_mismatch;
        longint unsigned other_breakdown_total;
        longint signed other_breakdown_mismatch;
        longint unsigned dc_stall_state_total, dc_stall_req_total;
        longint signed dc_stall_state_mismatch, dc_stall_req_mismatch;
        longint unsigned dc_drain_state_cycles, dc_drain_stall_cycles;
        longint unsigned dc_drain_hidden_cycles, dc_drain_stall_kind_total;
        longint signed dc_drain_stall_kind_mismatch;
        longint unsigned muldiv_issue_total, muldiv_wait_op_total;
        longint signed muldiv_wait_op_mismatch;
        longint unsigned bitmanip_issue_class_total;
        longint unsigned bitmanip_latency_total;
        longint signed bitmanip_issue_class_mismatch;
        longint signed bitmanip_latency_mismatch;
        longint unsigned pair_raw_exact_total, pair_block_exact_total;
        longint signed pair_block_exact_mismatch;
        real cpi, dual_rate, mispredict_rate, control_mispredict_rate;
        real dc_hit_rate, dc_miss_rate;
        real dc_primary_refill_avg;
        real fe_fq_avg, fe_ftq_avg;
        begin
            total_insts = cnt_s0_commit + cnt_s1_commit;
            commit_cycle_total = cnt_commit0_cycles + cnt_commit1_cycles
                               + cnt_commit2_cycles;
            ideal_slots = cnt_cycles << 1;
            retired_slots = total_insts;
            if (ideal_slots >= retired_slots)
                lost_slots = ideal_slots - retired_slots;
            else
                lost_slots = 0;
            lost_no_commit_slots = cnt_commit0_cycles << 1;
            lost_single_issue_slots = cnt_commit1_cycles;
            loss_no_commit_total = cnt_loss_redirect + cnt_loss_dcache
                                 + cnt_loss_muldiv + cnt_loss_bitmanip
                                 + cnt_loss_raw_not_ready
                                 + cnt_loss_raw_ready_no_fwd
                                 + cnt_loss_frontend_empty + cnt_loss_other;
            loss_stack_total = cnt_loss_productive + loss_no_commit_total;
            loss_stack_mismatch = $signed(loss_stack_total)
                                - $signed(cnt_cycles);
            loss_no_commit_mismatch = $signed(loss_no_commit_total)
                                    - $signed(cnt_commit0_cycles);
            mix_accept_total = cnt_mix_s0_accept + cnt_mix_s1_accept;
            mix_classified_total = cnt_mix_alu + cnt_mix_load + cnt_mix_store
                                 + cnt_mix_branch + cnt_mix_jal + cnt_mix_jalr
                                 + cnt_mix_muldiv + cnt_mix_system
                                 + cnt_mix_bitmanip + cnt_mix_other;
            mix_classification_mismatch = $signed(mix_classified_total)
                                        - $signed(mix_accept_total);
            mix_commit_delta = $signed(mix_accept_total) - $signed(total_insts);
            ctrl_resolved_total = cnt_pred_s0_ctrl + cnt_pred_s1_ctrl;
            ctrl_branch_total = cnt_pred_s0_branch + cnt_pred_s1_branch;
            ctrl_jal_total = cnt_pred_s0_jal + cnt_pred_s1_jal;
            ctrl_jalr_total = cnt_pred_s0_jalr + cnt_pred_s1_jalr;
            ctrl_branch_miss = cnt_ctrl_miss_s0_branch
                             + cnt_ctrl_miss_s1_branch;
            ctrl_jal_miss = cnt_ctrl_miss_s0_jal + cnt_ctrl_miss_s1_jal;
            ctrl_jalr_miss = cnt_ctrl_miss_s0_jalr + cnt_ctrl_miss_s1_jalr;
            ctrl_miss_total = ctrl_branch_miss + ctrl_jal_miss
                            + ctrl_jalr_miss;
            ctrl_miss_mismatch = $signed(ctrl_miss_total)
                               - $signed(cnt_pred_s0_mispredict
                                       + cnt_pred_s1_redirect);
            total_fwd = cnt_fwd_s1_ex + cnt_fwd_s0_ex + cnt_fwd_s1_mem
                       + cnt_fwd_s0_mem + cnt_fwd_s1_wb + cnt_fwd_s0_wb + cnt_fwd_rf;
            muldiv_issue_total = cnt_muldiv_issue[0] + cnt_muldiv_issue[1]
                               + cnt_muldiv_issue[2] + cnt_muldiv_issue[3]
                               + cnt_muldiv_issue[4] + cnt_muldiv_issue[5]
                               + cnt_muldiv_issue[6] + cnt_muldiv_issue[7];
            muldiv_wait_op_total = cnt_muldiv_wait_op[0] + cnt_muldiv_wait_op[1]
                                 + cnt_muldiv_wait_op[2] + cnt_muldiv_wait_op[3]
                                 + cnt_muldiv_wait_op[4] + cnt_muldiv_wait_op[5]
                                 + cnt_muldiv_wait_op[6] + cnt_muldiv_wait_op[7];
            muldiv_wait_op_mismatch = $signed(muldiv_wait_op_total)
                                    - $signed(cnt_muldiv_stall);
            bitmanip_issue_class_total = cnt_bitmanip_issue_fast
                                       + cnt_bitmanip_issue_clmul;
            bitmanip_issue_class_mismatch =
                $signed(bitmanip_issue_class_total)
              - $signed(cnt_bitmanip_issue);
            bitmanip_latency_total = cnt_bitmanip_lat1
                                   + cnt_bitmanip_lat2
                                   + cnt_bitmanip_lat3_4
                                   + cnt_bitmanip_lat5_8
                                   + cnt_bitmanip_lat9_16
                                   + cnt_bitmanip_lat17plus;
            bitmanip_latency_mismatch = $signed(bitmanip_latency_total)
                                      - $signed(cnt_bitmanip_complete);
            dc_stall_state_total = cnt_dc_stall_state_idle
                                 + cnt_dc_stall_state_refill_req
                                 + cnt_dc_stall_state_refill_data
                                 + cnt_dc_stall_state_refill_drop
                                 + cnt_dc_stall_state_done
                                 + cnt_dc_stall_state_sb_req
                                 + cnt_dc_stall_state_sb_resp
                                 + cnt_dc_stall_state_other;
            dc_stall_req_total = cnt_dc_stall_req_load
                               + cnt_dc_stall_req_store
                               + cnt_dc_stall_req_other;
            dc_stall_state_mismatch = $signed(dc_stall_state_total)
                                    - $signed(cnt_dcache_stall);
            dc_stall_req_mismatch = $signed(dc_stall_req_total)
                                  - $signed(cnt_dcache_stall);
            dc_drain_state_cycles = cnt_dc_drain_req_cycles
                                  + cnt_dc_drain_resp_cycles;
            dc_drain_stall_cycles = cnt_dc_drain_req_stall
                                  + cnt_dc_drain_resp_stall;
            dc_drain_hidden_cycles = dc_drain_state_cycles
                                   - dc_drain_stall_cycles;
            dc_drain_stall_kind_total = cnt_dc_drain_stall_load
                                      + cnt_dc_drain_stall_store
                                      + cnt_dc_drain_stall_other;
            dc_drain_stall_kind_mismatch =
                $signed(dc_drain_stall_kind_total)
              - $signed(dc_drain_stall_cycles);
            pair_raw_exact_total = cnt_pair_raw_prod_alu
                                 + cnt_pair_raw_prod_load
                                 + cnt_pair_raw_prod_cfi
                                 + cnt_pair_raw_prod_other;
            pair_block_exact_total = cnt_pair_block_no_candidate
                                   + cnt_pair_block_noncontiguous
                                   + cnt_pair_block_s0_pred_taken
                                   + cnt_pair_block_s0_force_single
                                   + cnt_pair_block_s1_force_single
                                   + pair_raw_exact_total
                                   + cnt_pair_block_s0_unsupported
                                   + cnt_pair_block_s1_unsupported_exact
                                   + cnt_pair_block_both_lsu
                                   + cnt_pair_block_both_cfi
                                   + cnt_pair_block_stored_other;
            pair_block_exact_mismatch = $signed(pair_block_exact_total)
                                      - $signed(cnt_if_s1_block);
            cpi_stack_total = cnt_cpi_retire + cnt_cpi_redirect + cnt_cpi_dcache
                            + cnt_cpi_muldiv + cnt_cpi_bitmanip
                            + cnt_cpi_raw_not_ready
                            + cnt_cpi_raw_ready_no_fwd + cnt_cpi_frontend_empty
                            + cnt_cpi_other_no_commit;
            other_breakdown_total = cnt_other_id_not_ready
                                  + cnt_other_id_downstream
                                  + cnt_other_ex_not_ready
                                  + cnt_other_ex_downstream
                                  + cnt_other_mem_not_ready
                                  + cnt_other_mem_downstream
                                  + cnt_other_flush_recovery
                                  + cnt_other_frontend_backpressure
                                  + cnt_other_pipeline_fill_drain
                                  + cnt_other_unknown;
            other_breakdown_mismatch = $signed(cnt_loss_other)
                                     - $signed(other_breakdown_total);

            if (total_insts > 0)
                cpi = 1.0 * cnt_cycles / total_insts;
            else
                cpi = 0.0;

            if (cnt_s0_commit > 0)
                dual_rate = 100.0 * cnt_s1_commit / cnt_s0_commit;
            else
                dual_rate = 0.0;

            if (cnt_total_branch > 0)
                mispredict_rate = 100.0 * cnt_branch_flush / cnt_total_branch;
            else
                mispredict_rate = 0.0;

            if (ctrl_resolved_total > 0)
                control_mispredict_rate =
                    100.0 * ctrl_miss_total / ctrl_resolved_total;
            else
                control_mispredict_rate = 0.0;

            if (cnt_dc_req > 0) begin
                dc_hit_rate = 100.0 * cnt_dc_hit / cnt_dc_req;
                dc_miss_rate = 100.0 * cnt_dc_miss / cnt_dc_req;
            end else begin
                dc_hit_rate = 0.0;
                dc_miss_rate = 0.0;
            end

            if (cnt_dc_primary_refill_completes > 0)
                dc_primary_refill_avg =
                    1.0 * cnt_dc_primary_refill_stall_cycles
                        / cnt_dc_primary_refill_completes;
            else
                dc_primary_refill_avg = 0.0;

            if (cnt_cycles > 0) begin
                fe_fq_avg = 1.0 * cnt_fe_fq_occupancy_sum / cnt_cycles;
                fe_ftq_avg = 1.0 * cnt_fe_ftq_occupancy_sum / cnt_cycles;
            end else begin
                fe_fq_avg = 0.0;
                fe_ftq_avg = 0.0;
            end

            $display("");
            $display("[PERF] ============ Performance Report ============");
            $display("[PERF]  Cycles:        %0d", cnt_cycles);
            $display("[PERF]  S0 commits:    %0d", cnt_s0_commit);
            $display("[PERF]  S1 commits:    %0d", cnt_s1_commit);
            $display("[PERF]  Total insts:   %0d", total_insts);
            $display("[PERF]  CPI:           %0.3f", cpi);
            $display("[PERF]  Dual-issue %%:  %0.1f%%", dual_rate);
            $display("[PERF]  Commit cycles: commit0=%0d commit1=%0d commit2=%0d total=%0d",
                     cnt_commit0_cycles, cnt_commit1_cycles,
                     cnt_commit2_cycles, commit_cycle_total);
            $display("[PERF]  Issue slots:   ideal=%0d retired=%0d lost=%0d no_commit_lost=%0d single_issue_lost=%0d",
                     ideal_slots, retired_slots, lost_slots,
                     lost_no_commit_slots, lost_single_issue_slots);
            $display("[PERF]  Accepted mix:  s0=%0d s1=%0d total=%0d alu=%0d load=%0d store=%0d branch=%0d jal=%0d jalr=%0d muldiv=%0d system=%0d bitmanip=%0d other=%0d classified=%0d mismatch=%0d commit_delta=%0d",
                     cnt_mix_s0_accept, cnt_mix_s1_accept, mix_accept_total,
                     cnt_mix_alu, cnt_mix_load, cnt_mix_store,
                     cnt_mix_branch, cnt_mix_jal, cnt_mix_jalr,
                     cnt_mix_muldiv, cnt_mix_system, cnt_mix_bitmanip,
                     cnt_mix_other, mix_classified_total,
                     mix_classification_mismatch, mix_commit_delta);
            $display("[PERF]");
            $display("[PERF]  --- CPI Stack (priority cycles) ---");
            $display("[PERF]  CPI stack:     retire=%0d redirect=%0d dcache=%0d muldiv=%0d bitmanip=%0d raw_not_ready=%0d raw_ready_no_fwd=%0d frontend_empty=%0d other_no_commit=%0d total=%0d",
                     cnt_cpi_retire, cnt_cpi_redirect, cnt_cpi_dcache,
                     cnt_cpi_muldiv, cnt_cpi_bitmanip,
                     cnt_cpi_raw_not_ready,
                     cnt_cpi_raw_ready_no_fwd, cnt_cpi_frontend_empty,
                     cnt_cpi_other_no_commit, cpi_stack_total);
            $display("[PERF]");
            $display("[PERF]  --- Strict No-Commit Loss Stack ---");
            $display("[PERF]  Loss stack:    productive=%0d redirect=%0d dcache=%0d muldiv=%0d bitmanip=%0d raw_not_ready=%0d raw_ready_no_fwd=%0d frontend_empty=%0d other=%0d no_commit=%0d total=%0d cycles=%0d mismatch=%0d no_commit_mismatch=%0d",
                     cnt_loss_productive, cnt_loss_redirect, cnt_loss_dcache,
                     cnt_loss_muldiv, cnt_loss_bitmanip,
                     cnt_loss_raw_not_ready,
                     cnt_loss_raw_ready_no_fwd, cnt_loss_frontend_empty,
                     cnt_loss_other, loss_no_commit_total, loss_stack_total,
                     cnt_cycles, loss_stack_mismatch,
                     loss_no_commit_mismatch);
            $display("[PERF]  Loss recovery: redirect=%0d dcache=%0d muldiv=%0d bitmanip=%0d",
                     cnt_loss_redirect_recovery,
                     cnt_loss_dcache_recovery,
                     cnt_loss_muldiv_recovery,
                     cnt_loss_bitmanip_recovery);
            $display("[PERF]");
            $display("[PERF]  --- Other No-Commit Breakdown ---");
            $display("[PERF]  Other no-commit: id_not_ready=%0d id_downstream=%0d ex_not_ready=%0d ex_downstream=%0d mem_not_ready=%0d mem_downstream=%0d flush_recovery=%0d frontend_backpressure=%0d pipeline_fill_drain=%0d unknown=%0d total=%0d original=%0d mismatch=%0d",
                     cnt_other_id_not_ready, cnt_other_id_downstream,
                     cnt_other_ex_not_ready, cnt_other_ex_downstream,
                     cnt_other_mem_not_ready, cnt_other_mem_downstream,
                     cnt_other_flush_recovery,
                     cnt_other_frontend_backpressure,
                     cnt_other_pipeline_fill_drain, cnt_other_unknown,
                     other_breakdown_total, cnt_loss_other,
                     other_breakdown_mismatch);
            $display("[PERF]  Other occupancy: 0000=%0d 0001=%0d 0010=%0d 0011=%0d 0100=%0d 0101=%0d 0110=%0d 0111=%0d 1000=%0d 1001=%0d 1010=%0d 1011=%0d 1100=%0d 1101=%0d 1110=%0d 1111=%0d",
                     cnt_other_occ[0], cnt_other_occ[1],
                     cnt_other_occ[2], cnt_other_occ[3],
                     cnt_other_occ[4], cnt_other_occ[5],
                     cnt_other_occ[6], cnt_other_occ[7],
                     cnt_other_occ[8], cnt_other_occ[9],
                     cnt_other_occ[10], cnt_other_occ[11],
                     cnt_other_occ[12], cnt_other_occ[13],
                     cnt_other_occ[14], cnt_other_occ[15]);
            $display("[PERF]");
            $display("[PERF]  --- Stall Breakdown (cycles) ---");
            $display("[PERF]  Load-use:      %0d", cnt_load_use_stall);
            $display("[PERF]    EX load:     %0d", cnt_load_use_ex);
            $display("[PERF]    MEM only:    %0d", cnt_load_use_mem);
            $display("[PERF]      MEM ready: %0d", cnt_load_use_mem_ready);
            $display("[PERF]      MEM block: %0d", cnt_load_use_mem_blocked);
            $display("[PERF]    S0 consumer: %0d", cnt_load_use_s0);
            $display("[PERF]    S1 consumer: %0d", cnt_load_use_s1);
            $display("[PERF]  Load-use source: ex=%0d mem_only=%0d mem_ready=%0d mem_blocked=%0d s0_consumer=%0d s1_consumer=%0d",
                     cnt_load_use_ex, cnt_load_use_mem,
                     cnt_load_use_mem_ready, cnt_load_use_mem_blocked,
                     cnt_load_use_s0, cnt_load_use_s1);
            $display("[PERF]    S0 role hits:");
            $display("[PERF]      ALU:        %0d", cnt_lu_s0_alu);
            $display("[PERF]      branch:     %0d", cnt_lu_s0_branch);
            $display("[PERF]      JALR:       %0d", cnt_lu_s0_jalr);
            $display("[PERF]      load addr:  %0d", cnt_lu_s0_load_addr);
            $display("[PERF]      store addr: %0d", cnt_lu_s0_store_addr);
            $display("[PERF]      store data: %0d", cnt_lu_s0_store_data);
            $display("[PERF]      other:      %0d", cnt_lu_s0_other);
            $display("[PERF]  Load-use S0 roles: alu=%0d branch=%0d jalr=%0d load_addr=%0d store_addr=%0d store_data=%0d other=%0d",
                     cnt_lu_s0_alu, cnt_lu_s0_branch, cnt_lu_s0_jalr,
                     cnt_lu_s0_load_addr, cnt_lu_s0_store_addr,
                     cnt_lu_s0_store_data, cnt_lu_s0_other);
            $display("[PERF]    MEM-ready S0 role hits:");
            $display("[PERF]      ALU:        %0d", cnt_lu_mem_ready_s0_alu);
            $display("[PERF]      branch:     %0d", cnt_lu_mem_ready_s0_branch);
            $display("[PERF]      JALR:       %0d", cnt_lu_mem_ready_s0_jalr);
            $display("[PERF]      load addr:  %0d", cnt_lu_mem_ready_s0_load_addr);
            $display("[PERF]      store addr: %0d", cnt_lu_mem_ready_s0_store_addr);
            $display("[PERF]      store data: %0d", cnt_lu_mem_ready_s0_store_data);
            $display("[PERF]      other:      %0d", cnt_lu_mem_ready_s0_other);
            $display("[PERF]  Load-use MEM-ready roles: alu=%0d branch=%0d jalr=%0d load_addr=%0d store_addr=%0d store_data=%0d other=%0d",
                     cnt_lu_mem_ready_s0_alu,
                     cnt_lu_mem_ready_s0_branch,
                     cnt_lu_mem_ready_s0_jalr,
                     cnt_lu_mem_ready_s0_load_addr,
                     cnt_lu_mem_ready_s0_store_addr,
                     cnt_lu_mem_ready_s0_store_data,
                     cnt_lu_mem_ready_s0_other);
            $display("[PERF]  Repair wait:    %0d", cnt_repair_wait);
            $display("[PERF]  JALR EX wait:   %0d", cnt_jalr_ex_wait);
            $display("[PERF]  S1-WB wait:    %0d", cnt_s1_wb_wait);
            $display("[PERF]  DCache miss:   %0d", cnt_dcache_stall);
            $display("[PERF]  MMIO hazard:   %0d", cnt_mmio_stall);
            $display("[PERF]  MUL/DIV wait:  %0d", cnt_muldiv_stall);
            $display("[PERF]  Bitmanip wait: %0d", cnt_bitmanip_stall);
            $display("[PERF]  MULDIV issued: mul=%0d mulh=%0d mulhsu=%0d mulhu=%0d div=%0d divu=%0d rem=%0d remu=%0d total=%0d",
                     cnt_muldiv_issue[0], cnt_muldiv_issue[1],
                     cnt_muldiv_issue[2], cnt_muldiv_issue[3],
                     cnt_muldiv_issue[4], cnt_muldiv_issue[5],
                     cnt_muldiv_issue[6], cnt_muldiv_issue[7],
                     muldiv_issue_total);
            $display("[PERF]  MULDIV wait ops: mul=%0d mulh=%0d mulhsu=%0d mulhu=%0d div=%0d divu=%0d rem=%0d remu=%0d total=%0d original=%0d mismatch=%0d",
                     cnt_muldiv_wait_op[0], cnt_muldiv_wait_op[1],
                     cnt_muldiv_wait_op[2], cnt_muldiv_wait_op[3],
                     cnt_muldiv_wait_op[4], cnt_muldiv_wait_op[5],
                     cnt_muldiv_wait_op[6], cnt_muldiv_wait_op[7],
                     muldiv_wait_op_total, cnt_muldiv_stall,
                     muldiv_wait_op_mismatch);
            $display("[PERF]  MULDIV latency: complete=%0d abort=%0d lat1=%0d lat2=%0d lat3_4=%0d lat5_8=%0d lat9_16=%0d lat17plus=%0d",
                     cnt_muldiv_complete, cnt_muldiv_abort,
                     cnt_muldiv_lat1, cnt_muldiv_lat2,
                     cnt_muldiv_lat3_4, cnt_muldiv_lat5_8,
                     cnt_muldiv_lat9_16, cnt_muldiv_lat17plus);
            $display("[PERF]  Bitmanip profile: issued=%0d fast=%0d clmul=%0d issue_classified=%0d issue_mismatch=%0d wait=%0d complete=%0d abort=%0d lat1=%0d lat2=%0d lat3_4=%0d lat5_8=%0d lat9_16=%0d lat17plus=%0d latency_total=%0d latency_mismatch=%0d",
                     cnt_bitmanip_issue, cnt_bitmanip_issue_fast,
                     cnt_bitmanip_issue_clmul,
                     bitmanip_issue_class_total,
                     bitmanip_issue_class_mismatch,
                     cnt_bitmanip_stall, cnt_bitmanip_complete,
                     cnt_bitmanip_abort, cnt_bitmanip_lat1,
                     cnt_bitmanip_lat2, cnt_bitmanip_lat3_4,
                     cnt_bitmanip_lat5_8, cnt_bitmanip_lat9_16,
                     cnt_bitmanip_lat17plus, bitmanip_latency_total,
                     bitmanip_latency_mismatch);
            $display("[PERF]");
            $display("[PERF]  --- DCache Detailed ---");
            $display("[PERF]  Requests:      %0d loads=%0d stores=%0d",
                     cnt_dc_req, cnt_dc_load_req, cnt_dc_store_req);
            $display("[PERF]  Hits:          %0d load=%0d store=%0d (%0.1f%%)",
                     cnt_dc_hit, cnt_dc_load_hit, cnt_dc_store_hit, dc_hit_rate);
            $display("[PERF]  Misses:        %0d load=%0d store=%0d (%0.1f%%)",
                     cnt_dc_miss, cnt_dc_load_miss, cnt_dc_store_miss, dc_miss_rate);
            $display("[PERF]  Refill cycles: %0d words=%0d aborts=%0d",
                     cnt_dc_refill_cycles, cnt_dc_refill_words, cnt_dc_refill_aborts);
            $display("[PERF]  Primary refill: starts=%0d completes=%0d aborts=%0d stall=%0d avg=%0.3f lat1=%0d lat2=%0d lat3=%0d lat4plus=%0d",
                     cnt_dc_primary_refill_starts,
                     cnt_dc_primary_refill_completes,
                     cnt_dc_primary_refill_aborts,
                     cnt_dc_primary_refill_stall_cycles,
                     dc_primary_refill_avg,
                     cnt_dc_primary_refill_lat1,
                     cnt_dc_primary_refill_lat2,
                     cnt_dc_primary_refill_lat3,
                     cnt_dc_primary_refill_lat4plus);
            $display("[PERF]  Store buffer:  enq=%0d drain=%0d block=%0d conflict=%0d fwd=%0d missbuf=%0d",
                     cnt_dc_sb_enqueue, cnt_dc_sb_drain, cnt_dc_sb_block_cycles,
                     cnt_dc_sb_conflicts, cnt_dc_store_forward_hits,
                     cnt_dc_miss_buffer_hits);
            $display("[PERF]  Direct drain impact: req_cycles=%0d resp_cycles=%0d req_stall=%0d resp_stall=%0d stall_total=%0d hidden=%0d load=%0d store=%0d other=%0d kind_total=%0d mismatch=%0d",
                     cnt_dc_drain_req_cycles, cnt_dc_drain_resp_cycles,
                     cnt_dc_drain_req_stall, cnt_dc_drain_resp_stall,
                     dc_drain_stall_cycles, dc_drain_hidden_cycles,
                     cnt_dc_drain_stall_load, cnt_dc_drain_stall_store,
                     cnt_dc_drain_stall_other, dc_drain_stall_kind_total,
                     dc_drain_stall_kind_mismatch);
            $display("[PERF]  Direct drain probe: pending=%0d read_overlap=%0d same_word=%0d push_overlap=%0d",
                     cnt_dc_drain_pending_cycles, cnt_dc_drain_read_overlap,
                     cnt_dc_drain_read_collision, cnt_dc_drain_push_overlap);
            $display("[PERF]  DCache stall state: idle=%0d refill_req=%0d refill_data=%0d refill_drop=%0d done=%0d sb_req=%0d sb_resp=%0d other=%0d total=%0d original=%0d mismatch=%0d",
                     cnt_dc_stall_state_idle,
                     cnt_dc_stall_state_refill_req,
                     cnt_dc_stall_state_refill_data,
                     cnt_dc_stall_state_refill_drop,
                     cnt_dc_stall_state_done,
                     cnt_dc_stall_state_sb_req,
                     cnt_dc_stall_state_sb_resp,
                     cnt_dc_stall_state_other, dc_stall_state_total,
                     cnt_dcache_stall, dc_stall_state_mismatch);
            $display("[PERF]  DCache stall request: load=%0d store=%0d other=%0d tag_hit=%0d tag_miss=%0d sb_occ0=%0d sb_occ1=%0d sb_occ2=%0d total=%0d original=%0d mismatch=%0d",
                     cnt_dc_stall_req_load, cnt_dc_stall_req_store,
                     cnt_dc_stall_req_other,
                     cnt_dc_stall_tag_hit, cnt_dc_stall_tag_miss,
                     cnt_dc_stall_sb_occ0, cnt_dc_stall_sb_occ1,
                     cnt_dc_stall_sb_occ2, dc_stall_req_total,
                     cnt_dcache_stall, dc_stall_req_mismatch);
            $display("[PERF]  LSU complete:  cache_load=%0d cache_store=%0d mmio_load=%0d mmio_store=%0d",
                     cnt_lsu_cache_load, cnt_lsu_cache_store,
                     cnt_lsu_mmio_load, cnt_lsu_mmio_store);
            $display("[PERF]");
            $display("[PERF]  --- RAW Stall Readiness Breakdown ---");
            $display("[PERF]  ID RAW stall cycles:          %0d", cnt_raw_id_stall);
            $display("[PERF]  Not-ready RAW cycles:         %0d  (%0.2f%% of cycles)",
                     cnt_raw_not_ready_total,
                     cnt_cycles > 0 ? 100.0*cnt_raw_not_ready_total/cnt_cycles : 0.0);
            $display("[PERF]    EX load pending:            %0d", cnt_raw_not_ready_ex_load);
            $display("[PERF]    MEM load blocked/not ready: %0d", cnt_raw_not_ready_mem_load_wait);
            $display("[PERF]    MULDIV pending dependency:  %0d", cnt_raw_not_ready_muldiv_dep);
            $display("[PERF]  RAW not-ready detail: ex_load=%0d mem_load_wait=%0d muldiv_dep=%0d",
                     cnt_raw_not_ready_ex_load,
                     cnt_raw_not_ready_mem_load_wait,
                     cnt_raw_not_ready_muldiv_dep);
            $display("[PERF]  Ready-no-forward RAW cycles:  %0d  (%0.1f%% of ID RAW stalls)",
                     cnt_raw_ready_no_fwd_total,
                     cnt_raw_id_stall > 0 ? 100.0*cnt_raw_ready_no_fwd_total/cnt_raw_id_stall : 0.0);
            $display("[PERF]    MEM-ready load no fwd:      %0d", cnt_raw_ready_mem_load_no_fwd);
            $display("[PERF]      S0 branch compare:        %0d", cnt_raw_ready_mem_load_s0_branch);
            $display("[PERF]      S0 JALR target:           %0d", cnt_raw_ready_mem_load_s0_jalr);
            $display("[PERF]      S0 load address:          %0d", cnt_raw_ready_mem_load_s0_load_addr);
            $display("[PERF]      S0 store address:         %0d", cnt_raw_ready_mem_load_s0_store_addr);
            $display("[PERF]      S0 store data:            %0d", cnt_raw_ready_mem_load_s0_store_data);
            $display("[PERF]      S1 consumer:              %0d", cnt_raw_ready_mem_load_s1);
            $display("[PERF]    Repaired EX chain no fwd:   %0d  rs1=%0d rs2=%0d",
                     cnt_raw_ready_repair_chain,
                     cnt_raw_ready_repair_rs1, cnt_raw_ready_repair_rs2);
            $display("[PERF]    Branch EX no fwd:           %0d  rs1=%0d rs2=%0d s0_prod=%0d s1_prod=%0d",
                     cnt_raw_ready_branch_ex_no_fwd,
                     cnt_raw_ready_branch_ex_rs1, cnt_raw_ready_branch_ex_rs2,
                     cnt_raw_ready_branch_ex_s0_prod, cnt_raw_ready_branch_ex_s1_prod);
            $display("[PERF]    JALR EX no fwd:             %0d  s0_prod=%0d s1_prod=%0d",
                     cnt_raw_ready_jalr_ex_no_fwd,
                     cnt_raw_ready_jalr_ex_s0_prod, cnt_raw_ready_jalr_ex_s1_prod);
            $display("[PERF]    Other ready-no-fwd:         %0d", cnt_raw_ready_other_no_fwd);
            $display("[PERF]  RAW ready-no-fwd detail: mem_load=%0d mem_s0_branch=%0d mem_s0_jalr=%0d mem_s0_load_addr=%0d mem_s0_store_addr=%0d mem_s0_store_data=%0d mem_s1=%0d repair=%0d branch_ex=%0d jalr_ex=%0d other=%0d",
                     cnt_raw_ready_mem_load_no_fwd,
                     cnt_raw_ready_mem_load_s0_branch,
                     cnt_raw_ready_mem_load_s0_jalr,
                     cnt_raw_ready_mem_load_s0_load_addr,
                     cnt_raw_ready_mem_load_s0_store_addr,
                     cnt_raw_ready_mem_load_s0_store_data,
                     cnt_raw_ready_mem_load_s1,
                     cnt_raw_ready_repair_chain,
                     cnt_raw_ready_branch_ex_no_fwd,
                     cnt_raw_ready_jalr_ex_no_fwd,
                     cnt_raw_ready_other_no_fwd);
            $display("[PERF]  Unclassified ID RAW stalls:   %0d", cnt_raw_unclassified_stall);
            $display("[PERF]  Same-pair RAW lost slots:     %0d  rs1=%0d rs2=%0d",
                     cnt_if_block_raw, cnt_if_block_raw_rs1, cnt_if_block_raw_rs2);
            $display("[PERF]");
            $display("[PERF]  --- Branch ---");
            $display("[PERF]  Total branch:  %0d", cnt_total_branch);
            $display("[PERF]  Mispredicts:   %0d  (%0.1f%%)", cnt_branch_flush, mispredict_rate);
            $display("[PERF]  J/CALL redirects: %0d", cnt_jcall_redirect);
            $display("[PERF]  Control prediction: resolved=%0d s0=%0d s1=%0d branch=%0d jal=%0d jalr=%0d misses=%0d s0_miss=%0d s1_miss=%0d branch_miss=%0d jal_miss=%0d jalr_miss=%0d rate_milli_pct=%0d mismatch=%0d",
                     ctrl_resolved_total, cnt_pred_s0_ctrl, cnt_pred_s1_ctrl,
                     ctrl_branch_total, ctrl_jal_total, ctrl_jalr_total,
                     ctrl_miss_total, cnt_pred_s0_mispredict,
                     cnt_pred_s1_redirect, ctrl_branch_miss, ctrl_jal_miss,
                     ctrl_jalr_miss, $rtoi(control_mispredict_rate * 1000.0),
                     ctrl_miss_mismatch);
            $display("[PERF]");
            $display("[PERF]  --- Stage-1 Prediction Detailed ---");
            $display("[PERF]  Pred resolved: s0=%0d branch=%0d jal=%0d jalr=%0d s1=%0d s1_branch=%0d s1_jal=%0d s1_jalr=%0d",
                     cnt_pred_s0_ctrl, cnt_pred_s0_branch, cnt_pred_s0_jal,
                     cnt_pred_s0_jalr, cnt_pred_s1_ctrl, cnt_pred_s1_branch,
                     cnt_pred_s1_jal, cnt_pred_s1_jalr);
            $display("[PERF]  Pred s0 pred:  pred_taken=%0d actual_taken=%0d",
                     cnt_pred_s0_pred_taken, cnt_pred_s0_actual_taken);
            $display("[PERF]  Pred s0 miss:  total=%0d dir_to_taken=%0d dir_to_fallthrough=%0d target=%0d",
                     cnt_pred_s0_mispredict, cnt_pred_s0_dir_to_taken,
                     cnt_pred_s0_dir_to_fallthrough, cnt_pred_s0_target_wrong);
            $display("[PERF]  Pred s1 pred:  pred_taken=%0d actual_taken=%0d dir_wrong=%0d target_wrong=%0d redirect=%0d",
                     cnt_pred_s1_pred_taken,
                     cnt_pred_s1_actual_taken, cnt_pred_s1_dir_wrong,
                     cnt_pred_s1_target_wrong, cnt_pred_s1_redirect);
            $display("[PERF]  Pred training: total=%0d s0=%0d s1=%0d branch=%0d jal=%0d jalr=%0d",
                     cnt_pred_train_total, cnt_pred_train_s0, cnt_pred_train_s1,
                     cnt_pred_train_branch, cnt_pred_train_jal, cnt_pred_train_jalr);
            $display("[PERF]");
            $display("[PERF]  --- Frontend / FTQ Detailed ---");
            $display("[PERF]  FE BP0:        fire=%0d ftq_full=%0d fq_credit_block=%0d",
                     cnt_fe_bp0_fire, cnt_fe_bp0_block_ftq_full,
                     cnt_fe_bp0_block_fq_credit);
            $display("[PERF]  FE redirect:   total=%0d ex=%0d",
                     cnt_fe_redirect_total, cnt_fe_redirect_ex);
            $display("[PERF]  FE F0:         valid=%0d accept=%0d epoch_miss=%0d ex_kill=%0d enq0=%0d enq1=%0d enq_none=%0d kill_slot0=%0d",
                     cnt_fe_f0_valid, cnt_fe_f0_accept, cnt_fe_f0_epoch_miss,
                     cnt_fe_f0_ex_kill, cnt_fe_f0_enq0, cnt_fe_f0_enq1,
                     cnt_fe_f0_enq_none, cnt_fe_f0_kill_slot0);
            $display("[PERF]  FE IF:         accept=%0d dual=%0d single=%0d empty=%0d fq_nonempty=%0d fq_pair_ready=%0d",
                     cnt_fe_if_accept, cnt_fe_if_accept_dual,
                     cnt_fe_if_accept_single, cnt_fe_if_empty,
                     cnt_fe_fq_nonempty_cycles, cnt_fe_fq_pair_ready_cycles);
            $display("[PERF]  FE occupancy:  fq_avg=%0.2f ftq_avg=%0.2f fq_sum=%0d ftq_sum=%0d",
                     fe_fq_avg, fe_ftq_avg,
                     cnt_fe_fq_occupancy_sum, cnt_fe_ftq_occupancy_sum);
            $display("[PERF]  ABTB direct:   lookup=%0d steer=%0d bank0=%0d bank1=%0d correct=%0d redirect=%0d target_miss=%0d stage1_sequential=%0d stage1_owned=%0d owned_nt=%0d",
                     tb_riscv_tests.u_cpu.abtb_direct_lookup_count,
                     tb_riscv_tests.u_cpu.abtb_direct_steer_count,
                     tb_riscv_tests.u_cpu.abtb_direct_bank0_count,
                     tb_riscv_tests.u_cpu.abtb_direct_bank1_count,
                     tb_riscv_tests.u_cpu.abtb_direct_correct_count,
                     tb_riscv_tests.u_cpu.abtb_direct_redirect_count,
                     tb_riscv_tests.u_cpu.abtb_direct_target_miss_count,
                     tb_riscv_tests.u_cpu.stage1_sequential_count,
                     tb_riscv_tests.u_cpu.stage1_abtb_owned_count,
                     tb_riscv_tests.u_cpu.stage1_branch_owned_nt_count);
            $display("[PERF]  Stage1 PHT:    confirmed=%0d abtb_branch_hit=%0d pred_taken=%0d pred_nt=%0d correct=%0d wrong=%0d bank0=%0d bank1=%0d",
                     tb_riscv_tests.u_cpu.stage1_confirmed_branch_count,
                     tb_riscv_tests.u_cpu.stage1_abtb_branch_hit_count,
                     tb_riscv_tests.u_cpu.stage1_pht_taken_count,
                     tb_riscv_tests.u_cpu.stage1_pht_not_taken_count,
                     tb_riscv_tests.u_cpu.stage1_pht_correct_count,
                     tb_riscv_tests.u_cpu.stage1_pht_wrong_count,
                     tb_riscv_tests.u_cpu.stage1_bank0_branch_lookup_count,
                     tb_riscv_tests.u_cpu.stage1_bank1_branch_lookup_count);
            $display("[PERF]");
            $display("[PERF]  --- Fetch Mix / Dual-issue Loss (excl. held) ---");
            $display("[PERF]  Fetch valid:   %0d", cnt_fetch_valid);
            $display("[PERF]  PC[2]=1 fetch: %0d", cnt_pc2_fetch);
            $display("[PERF]  RAW dep:       %0d", cnt_raw_block);
            $display("[PERF]  inst1 not ALU: %0d", cnt_inst1_not_alu);
            $display("[PERF]  inst0 JAL/JR:  %0d", cnt_inst0_jump);
            $display("[PERF]  Not seq fetch: %0d", cnt_not_sequential);
            $display("[PERF]  Dual issued:   %0d", cnt_dual_issued);
            $display("[PERF]");
            $display("[PERF]  --- IF Accept Dual-issue Diagnosis ---");
            $display("[PERF]  IF accepts:    %0d", cnt_if_accept);
            $display("[PERF]  S1 accepted:   %0d  (%0.1f%% of IF accepts)",
                     cnt_if_s1_accept,
                     cnt_if_accept > 0 ? 100.0*cnt_if_s1_accept/cnt_if_accept : 0.0);
            $display("[PERF]  S1 committed:  %0d  (%0.1f%% of S1 accepts)",
                     cnt_s1_commit,
                     cnt_if_s1_accept > 0 ? 100.0*cnt_s1_commit/cnt_if_s1_accept : 0.0);
            $display("[PERF]  S1 blocked:    %0d", cnt_if_s1_block);
            $display("[PERF]    not seq:     %0d  (%0.1f%% of blocks)",
                     cnt_if_block_not_seq,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_not_seq/cnt_if_s1_block : 0.0);
            $display("[PERF]    RAW:         %0d  (%0.1f%% of blocks)  rs1=%0d rs2=%0d",
                     cnt_if_block_raw,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_raw/cnt_if_s1_block : 0.0,
                     cnt_if_block_raw_rs1, cnt_if_block_raw_rs2);
            $display("[PERF]    S0 MULDIV:   %0d  (%0.1f%% of blocks)",
                     cnt_if_block_s0_muldiv,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_s0_muldiv/cnt_if_s1_block : 0.0);
            $display("[PERF]    S0 jump/sys: %0d  (%0.1f%% of blocks)",
                     cnt_if_block_s0_jump,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_s0_jump/cnt_if_s1_block : 0.0);
            $display("[PERF]    S1 LSU/branch/JAL blocked by S0 policy: %0d  (%0.1f%% of blocks)",
                     cnt_if_block_s1_branch_s0,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_s1_branch_s0/cnt_if_s1_block : 0.0);
            $display("[PERF]    S1 unsupported: %0d  (%0.1f%% of blocks)",
                     cnt_if_block_s1_unsupported,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_s1_unsupported/cnt_if_s1_block : 0.0);
            $display("[PERF]      load=%0d store=%0d muldiv=%0d jal=%0d jalr=%0d system=%0d other=%0d",
                     cnt_if_s1_unsup_load, cnt_if_s1_unsup_store,
                     cnt_if_s1_unsup_muldiv, cnt_if_s1_unsup_jal,
                     cnt_if_s1_unsup_jalr, cnt_if_s1_unsup_system,
                     cnt_if_s1_unsup_other);
            $display("[PERF]    other:       %0d  (%0.1f%% of blocks)",
                     cnt_if_block_other,
                     cnt_if_s1_block > 0 ? 100.0*cnt_if_block_other/cnt_if_s1_block : 0.0);
            $display("[PERF]  IF block heuristic: not_seq=%0d raw=%0d s0_muldiv=%0d s0_jump=%0d s1_policy=%0d s1_unsupported=%0d other=%0d total=%0d",
                     cnt_if_block_not_seq, cnt_if_block_raw,
                     cnt_if_block_s0_muldiv, cnt_if_block_s0_jump,
                     cnt_if_block_s1_branch_s0,
                     cnt_if_block_s1_unsupported, cnt_if_block_other,
                     cnt_if_s1_block);
            $display("[PERF]  S1 unsupported type: load=%0d store=%0d muldiv=%0d jal=%0d jalr=%0d system=%0d other=%0d",
                     cnt_if_s1_unsup_load, cnt_if_s1_unsup_store,
                     cnt_if_s1_unsup_muldiv, cnt_if_s1_unsup_jal,
                     cnt_if_s1_unsup_jalr, cnt_if_s1_unsup_system,
                     cnt_if_s1_unsup_other);
            $display("[PERF]  Pair block exact: no_candidate=%0d noncontiguous=%0d s0_pred_taken=%0d s0_force_single=%0d s1_force_single=%0d raw=%0d s0_unsupported=%0d s1_unsupported=%0d both_lsu=%0d both_cfi=%0d stored_other=%0d total=%0d original=%0d mismatch=%0d",
                     cnt_pair_block_no_candidate,
                     cnt_pair_block_noncontiguous,
                     cnt_pair_block_s0_pred_taken,
                     cnt_pair_block_s0_force_single,
                     cnt_pair_block_s1_force_single,
                     pair_raw_exact_total,
                     cnt_pair_block_s0_unsupported,
                     cnt_pair_block_s1_unsupported_exact,
                     cnt_pair_block_both_lsu,
                     cnt_pair_block_both_cfi,
                     cnt_pair_block_stored_other,
                     pair_block_exact_total, cnt_if_s1_block,
                     pair_block_exact_mismatch);
            $display("[PERF]  Pair RAW producer: alu=%0d load=%0d cfi=%0d other=%0d total=%0d",
                     cnt_pair_raw_prod_alu, cnt_pair_raw_prod_load,
                     cnt_pair_raw_prod_cfi, cnt_pair_raw_prod_other,
                     pair_raw_exact_total);
            $display("[PERF]  Pair RAW consumer: alu=%0d load=%0d store=%0d branch=%0d jalr=%0d other=%0d",
                     cnt_pair_raw_cons_alu, cnt_pair_raw_cons_load,
                     cnt_pair_raw_cons_store, cnt_pair_raw_cons_branch,
                     cnt_pair_raw_cons_jalr, cnt_pair_raw_cons_other);
            $display("[PERF]  Pair RAW ALU matrix: alu=%0d load=%0d store=%0d branch=%0d jalr=%0d other=%0d",
                     cnt_pair_raw_alu_to_alu, cnt_pair_raw_alu_to_load,
                     cnt_pair_raw_alu_to_store, cnt_pair_raw_alu_to_branch,
                     cnt_pair_raw_alu_to_jalr, cnt_pair_raw_alu_to_other);
            $display("[PERF]  Pair RAW load matrix: alu=%0d load=%0d store=%0d branch=%0d jalr=%0d other=%0d",
                     cnt_pair_raw_load_to_alu, cnt_pair_raw_load_to_load,
                     cnt_pair_raw_load_to_store, cnt_pair_raw_load_to_branch,
                     cnt_pair_raw_load_to_jalr, cnt_pair_raw_load_to_other);
            $display("[PERF]  Pair RAW store roles: addr=%0d data=%0d alu_addr=%0d alu_data=%0d",
                     cnt_pair_raw_store_addr, cnt_pair_raw_store_data,
                     cnt_pair_raw_alu_to_store_addr,
                     cnt_pair_raw_alu_to_store_data);
            $display("[PERF]  Pair RAW bypass: alu_to_store_data=%0d",
                     cnt_pair_bypass_alu_to_store_data);
            $display("[PERF]  S1 accepted type: ALU=%0d branch=%0d load=%0d store=%0d jal=%0d",
                     cnt_if_s1_alu_accept, cnt_if_s1_branch_accept,
                     cnt_if_s1_load_accept, cnt_if_s1_store_accept,
                     cnt_if_s1_jal_accept);
            $display("[PERF]  S0 IF-accept mix: ALU=%0d load=%0d store=%0d control=%0d muldiv=%0d",
                     cnt_if_s0_alu_seen, cnt_if_s0_load_seen,
                     cnt_if_s0_store_seen, cnt_if_s0_control_seen,
                     cnt_if_s0_muldiv_seen);
            $display("[PERF]  S1 valid cycles: ID=%0d EX=%0d MEM=%0d WB(commits)=%0d",
                     cnt_id_s1_seen, cnt_ex_s1_seen, cnt_mem_s1_seen,
                     cnt_s1_commit);
            $display("[PERF]");
            if (total_fwd > 0) begin
                $display("[PERF]  --- Forwarding Source (S0-rs1, %0d samples) ---", total_fwd);
                $display("[PERF]  Forwarding source: s1_ex=%0d s0_ex=%0d s1_mem=%0d s0_mem=%0d s1_wb=%0d s0_wb=%0d rf=%0d total=%0d",
                         cnt_fwd_s1_ex, cnt_fwd_s0_ex, cnt_fwd_s1_mem,
                         cnt_fwd_s0_mem, cnt_fwd_s1_wb, cnt_fwd_s0_wb,
                         cnt_fwd_rf, total_fwd);
                $display("[PERF]  S1_EX:  %0d (%0.1f%%)", cnt_fwd_s1_ex,  100.0*cnt_fwd_s1_ex/total_fwd);
                $display("[PERF]  S0_EX:  %0d (%0.1f%%)", cnt_fwd_s0_ex,  100.0*cnt_fwd_s0_ex/total_fwd);
                $display("[PERF]  S1_MEM: %0d (%0.1f%%)", cnt_fwd_s1_mem, 100.0*cnt_fwd_s1_mem/total_fwd);
                $display("[PERF]  S0_MEM: %0d (%0.1f%%)", cnt_fwd_s0_mem, 100.0*cnt_fwd_s0_mem/total_fwd);
                $display("[PERF]  S1_WB:  %0d (%0.1f%%)", cnt_fwd_s1_wb,  100.0*cnt_fwd_s1_wb/total_fwd);
                $display("[PERF]  S0_WB:  %0d (%0.1f%%)", cnt_fwd_s0_wb,  100.0*cnt_fwd_s0_wb/total_fwd);
                $display("[PERF]  RF:     %0d (%0.1f%%)", cnt_fwd_rf,     100.0*cnt_fwd_rf/total_fwd);
            end
            $display("[PERF]");
            $display("[PERF]  --- skip_inst0 Timing Fix Analysis ---");
            $display("[PERF]  skip_inst0=1:        %0d  (%0.2f%% of cycles)", cnt_skip_inst0, 100.0*cnt_skip_inst0/cnt_cycles);
            $display("[PERF]  skip+pred_taken:     %0d  (%0.2f%% of cycles)", cnt_skip_and_pred_taken, 100.0*cnt_skip_and_pred_taken/cnt_cycles);
            $display("[PERF]  predict_dual errors: %0d  (%0.2f%% of fetches)", cnt_predict_dual_err, cnt_fetch_valid > 0 ? 100.0*cnt_predict_dual_err/cnt_fetch_valid : 0.0);
            $display("[PERF] ================================================");
        end
    endtask

endmodule
