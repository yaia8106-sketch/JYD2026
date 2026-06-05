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

    // -- CPI stack, priority and mutually exclusive by cycle --
    longint unsigned cnt_cpi_retire;
    longint unsigned cnt_cpi_redirect;
    longint unsigned cnt_cpi_dcache;
    longint unsigned cnt_cpi_muldiv;
    longint unsigned cnt_cpi_raw_not_ready;
    longint unsigned cnt_cpi_raw_ready_no_fwd;
    longint unsigned cnt_cpi_frontend_empty;
    longint unsigned cnt_cpi_other_no_commit;

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

    // -- DCache / LSU breakdown --
    longint unsigned cnt_lsu_cache_load;  // completed cacheable loads
    longint unsigned cnt_lsu_cache_store; // completed cacheable stores
    longint unsigned cnt_lsu_mmio_load;   // completed uncacheable/MMIO loads
    longint unsigned cnt_lsu_mmio_store;  // completed uncacheable/MMIO stores
    longint unsigned cnt_dc_req;          // accepted DCache accesses: hits + refill starts
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
    longint unsigned cnt_nlp_redirect;    // NLP L1 redirect (ID)
    longint unsigned cnt_total_branch;    // total branch instructions reaching EX

    // -- Branch predictor breakdown --
    longint unsigned cnt_bp_s0_ctrl;
    longint unsigned cnt_bp_s0_branch;
    longint unsigned cnt_bp_s0_jal;
    longint unsigned cnt_bp_s0_jalr;
    longint unsigned cnt_bp_s1_ctrl;
    longint unsigned cnt_bp_s1_branch;
    longint unsigned cnt_bp_s1_jal;
    longint unsigned cnt_bp_s0_pred_taken;
    longint unsigned cnt_bp_s0_actual_taken;
    longint unsigned cnt_bp_s0_btb_hit;
    longint unsigned cnt_bp_s0_btb_miss;
    longint unsigned cnt_bp_s0_mispredict;
    longint unsigned cnt_bp_s0_dir_to_taken;
    longint unsigned cnt_bp_s0_dir_to_fallthrough;
    longint unsigned cnt_bp_s0_target_wrong;
    longint unsigned cnt_bp_s1_lookup_btb_hit;
    longint unsigned cnt_bp_s1_lookup_taken;
    longint unsigned cnt_bp_s1_actual_taken;
    longint unsigned cnt_bp_s1_dir_wrong;
    longint unsigned cnt_bp_s1_target_wrong;
    longint unsigned cnt_bp_s1_redirect;
    longint unsigned cnt_bp_id_redirect_raw;
    longint unsigned cnt_bp_id_redirect;
    longint unsigned cnt_bp_train_total;
    longint unsigned cnt_bp_train_s0;
    longint unsigned cnt_bp_train_s1;
    longint unsigned cnt_bp_train_branch;
    longint unsigned cnt_bp_train_jal;
    longint unsigned cnt_bp_train_jalr;
    longint unsigned cnt_bp_train_btb_hit;
    longint unsigned cnt_bp_train_btb_miss;
    longint unsigned cnt_bp_train_btb_alloc;
    longint unsigned cnt_bp_btb_write;
    longint unsigned cnt_bp_btb_alloc_write;
    longint unsigned cnt_bp_pht_write;
    longint unsigned cnt_bp_sel_write;
    longint unsigned cnt_bp_ghr_write;
    longint unsigned cnt_bp_ras_push;
    longint unsigned cnt_bp_ras_pop;
    longint unsigned cnt_bp_jalr_side_write;

    // -- Frontend / FTQ breakdown --
    longint unsigned cnt_fe_bp0_fire;
    longint unsigned cnt_fe_bp0_block_ftq_full;
    longint unsigned cnt_fe_bp0_block_fq_credit;
    longint unsigned cnt_fe_redirect_total;
    longint unsigned cnt_fe_redirect_ex;
    longint unsigned cnt_fe_redirect_bp1;
    longint unsigned cnt_fe_f0_valid;
    longint unsigned cnt_fe_f0_accept;
    longint unsigned cnt_fe_f0_epoch_miss;
    longint unsigned cnt_fe_f0_ex_kill;
    longint unsigned cnt_fe_f0_enq0;
    longint unsigned cnt_fe_f0_enq1;
    longint unsigned cnt_fe_f0_enq_none;
    longint unsigned cnt_fe_f0_kill_slot0;
    longint unsigned cnt_fe_bp1_applicable;
    longint unsigned cnt_fe_bp1_override;
    longint unsigned cnt_fe_bp1_to_taken;
    longint unsigned cnt_fe_bp1_to_not_taken;
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
    longint unsigned cnt_not_sequential;  // flush/redirect/bp_taken preventing dual
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
    longint unsigned cnt_skip_and_bp_taken;   // skip_inst0=1 AND bp_taken=1 (would mispredict)
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
    wire        if_ready_go_w   = tb_riscv_tests.u_cpu.if_ready_go_w;
    wire        mem_allowin_w   = tb_riscv_tests.u_cpu.mem_allowin;

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
    wire        muldiv_done_w   = tb_riscv_tests.u_cpu.muldiv_done;

    wire        branch_flush_w  = tb_riscv_tests.u_cpu.branch_flush;
    wire        mem_branch_flush_w = tb_riscv_tests.u_cpu.mem_branch_flush;
    wire        frontend_branch_flush_w = tb_riscv_tests.u_cpu.frontend_branch_flush;
    wire        id_bp_redirect_w = tb_riscv_tests.u_cpu.id_bp_redirect;
    wire        id_bp_redirect_raw_w = tb_riscv_tests.u_cpu.id_bp_redirect_raw;
    wire        ex_is_branch    = tb_riscv_tests.u_cpu.ex_is_branch;
    wire        ex_is_jal       = tb_riscv_tests.u_cpu.ex_is_jal;
    wire        ex_is_jalr      = tb_riscv_tests.u_cpu.ex_is_jalr;
    wire        ex_bp_taken_w   = tb_riscv_tests.u_cpu.ex_bp_taken;
    wire [31:0] ex_bp_target_w  = tb_riscv_tests.u_cpu.ex_bp_target;
    wire        ex_bp_btb_hit_w = tb_riscv_tests.u_cpu.ex_bp_btb_hit;
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
    wire bp_taken_w     = tb_riscv_tests.u_cpu.if_bp_taken_out;
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
    wire       id_s1_squash_raw_w = tb_riscv_tests.u_cpu.id_s1_squash_raw;
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
    wire       ex_s1_bp_taken_w  = tb_riscv_tests.u_cpu.ex_s1_bp_taken;
    wire [31:0] ex_s1_bp_target_w = tb_riscv_tests.u_cpu.ex_s1_bp_target;
    wire       ex_s1_bp_btb_hit_w = tb_riscv_tests.u_cpu.ex_s1_bp_btb_hit;
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
    wire dc_miss_start_w = tb_riscv_tests.u_dcache.state_idle
                         & tb_riscv_tests.u_dcache.mem_req
                         & ~tb_riscv_tests.u_dcache.cache_hit
                         & ~tb_riscv_tests.u_dcache.sb_valid;
    wire dc_load_hit_w   = dc_hit_accept_w & ~tb_riscv_tests.u_dcache.mem_wr;
    wire dc_store_hit_w  = dc_hit_accept_w &  tb_riscv_tests.u_dcache.mem_wr;
    wire dc_load_miss_w  = dc_miss_start_w & ~tb_riscv_tests.u_dcache.mem_wr;
    wire dc_store_miss_w = dc_miss_start_w &  tb_riscv_tests.u_dcache.mem_wr;
    wire dc_sb_drain_w   = |tb_riscv_tests.u_dcache.dram_wea;
    wire dc_refill_cycle_w = ~tb_riscv_tests.u_dcache.state_idle & ~dc_sb_drain_w;
    wire dc_refill_abort_w = tb_riscv_tests.u_dcache.flush & dc_refill_cycle_w;
    wire dc_sb_block_w = tb_riscv_tests.u_dcache.state_idle
                       & tb_riscv_tests.u_dcache.mem_req
                       & tb_riscv_tests.u_dcache.sb_valid;
    wire dc_store_forward_hit_w = dc_hit_accept_w
                                & ~tb_riscv_tests.u_dcache.mem_wr
                                & (tb_riscv_tests.u_dcache.fwd_hit_w0
                                 | tb_riscv_tests.u_dcache.fwd_hit_w1);

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

    wire id_s1_valid_eff = id_s1_valid & ~id_s1_squash_raw_w;
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

    wire bp_s0_ctrl_event = ex_valid & (ex_is_branch | ex_is_jal | ex_is_jalr);
    wire bp_s0_dir_to_taken_event = branch_flush_w & actual_taken_w & ~ex_bp_taken_w;
    wire bp_s0_dir_to_fallthrough_event = branch_flush_w & ~actual_taken_w & ex_bp_taken_w;
    wire bp_s0_target_wrong_event = branch_flush_w & actual_taken_w & ex_bp_taken_w
                                  & (actual_target_w != ex_bp_target_w);
    wire bp_s1_ctrl_event = ex_s1_valid & (ex_s1_is_branch_w | ex_s1_is_jal_w)
                          & ex_ready_go_w & mem_allowin_w;
    wire bp_s1_dir_wrong_event = bp_s1_ctrl_event & ex_s1_is_branch_w
                               & (ex_s1_bp_taken_w != ex_s1_actual_taken_w);
    wire bp_s1_target_wrong_event = bp_s1_ctrl_event
                                  & ex_s1_bp_taken_w & ex_s1_actual_taken_w
                                  & (ex_s1_bp_target_w != ex_s1_branch_target_w);

    // Frontend/FTQ profiling taps. These observe the local frontend state
    // without feeding back into the DUT.
    wire        fe_bp0_fire_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp0_fire;
    wire        fe_ftq_alloc_ready_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ftq_alloc_ready;
    wire        fe_fq_credit_for_bp0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_credit_for_bp0;
    wire        fe_redirect_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.redirect_valid;
    wire        fe_ex_redirect_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ex_redirect_valid;
    wire        fe_bp1_redirect_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp1_redirect_valid;
    wire        fe_f0_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_valid_r;
    wire        fe_f0_epoch_match_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_epoch_match;
    wire        fe_f0_accept_base_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_accept_base;
    wire        fe_f0_enq0_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq0_valid;
    wire        fe_f0_enq1_valid_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq1_valid;
    wire        fe_f0_enq_none_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_enq_none;
    wire        fe_f0_kill_after_slot0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.f0_kill_after_slot0;
    wire        fe_bp1_applicable_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp1_applicable;
    wire        fe_bp1_override_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp1_override;
    wire        fe_bp1_tournament_taken_w = tb_riscv_tests.u_cpu.u_frontend_ftq.bp1_tournament_taken;
    wire        fe_if_accept_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept;
    wire        fe_if_accept_dual_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept_dual;
    wire        fe_if_accept_single_w = tb_riscv_tests.u_cpu.u_frontend_ftq.if_accept_single;
    wire        fe_fq_has_slot0_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_has_slot0;
    wire        fe_fq_has_slot1_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_has_slot1;
    wire [31:0] fe_fq_count_w = tb_riscv_tests.u_cpu.u_frontend_ftq.fq_count;
    wire [31:0] fe_ftq_count_w = tb_riscv_tests.u_cpu.u_frontend_ftq.ftq_count;

    wire fe_bp0_block_ftq_full_w = ~fe_redirect_valid_w & ~fe_ftq_alloc_ready_w;
    wire fe_bp0_block_fq_credit_w = ~fe_redirect_valid_w & fe_ftq_alloc_ready_w
                                  & ~fe_fq_credit_for_bp0_w;
    wire cpi_redirect_event = frontend_branch_flush_w | mem_branch_flush_w
                            | branch_flush_w | id_bp_redirect_w
                            | fe_bp1_redirect_valid_w;
    wire cpi_dcache_event = mem_valid & ~mem_ready_go_w;
    wire cpi_muldiv_event = ex_valid & ex_is_muldiv_w & ~muldiv_done_w;
    wire cpi_raw_not_ready_event = raw_nr_ex_load_event | raw_nr_mem_load_wait_event
                                 | raw_nr_muldiv_event;
    wire cpi_raw_ready_no_fwd_event = raw_ready_mem_load_no_fwd_event
                                    | raw_ready_repair_event
                                    | raw_ready_branch_ex_event
                                    | raw_ready_jalr_ex_event
                                    | raw_ready_other_event;
    wire cpi_frontend_empty_event = ~if_valid;
    wire cpi_retire_event = wb_valid | wb_s1_valid;

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
            cnt_cpi_retire     <= 0;
            cnt_cpi_redirect   <= 0;
            cnt_cpi_dcache     <= 0;
            cnt_cpi_muldiv     <= 0;
            cnt_cpi_raw_not_ready <= 0;
            cnt_cpi_raw_ready_no_fwd <= 0;
            cnt_cpi_frontend_empty <= 0;
            cnt_cpi_other_no_commit <= 0;
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
            cnt_nlp_redirect   <= 0;
            cnt_total_branch   <= 0;
            cnt_bp_s0_ctrl <= 0;
            cnt_bp_s0_branch <= 0;
            cnt_bp_s0_jal <= 0;
            cnt_bp_s0_jalr <= 0;
            cnt_bp_s1_ctrl <= 0;
            cnt_bp_s1_branch <= 0;
            cnt_bp_s1_jal <= 0;
            cnt_bp_s0_pred_taken <= 0;
            cnt_bp_s0_actual_taken <= 0;
            cnt_bp_s0_btb_hit <= 0;
            cnt_bp_s0_btb_miss <= 0;
            cnt_bp_s0_mispredict <= 0;
            cnt_bp_s0_dir_to_taken <= 0;
            cnt_bp_s0_dir_to_fallthrough <= 0;
            cnt_bp_s0_target_wrong <= 0;
            cnt_bp_s1_lookup_btb_hit <= 0;
            cnt_bp_s1_lookup_taken <= 0;
            cnt_bp_s1_actual_taken <= 0;
            cnt_bp_s1_dir_wrong <= 0;
            cnt_bp_s1_target_wrong <= 0;
            cnt_bp_s1_redirect <= 0;
            cnt_bp_id_redirect_raw <= 0;
            cnt_bp_id_redirect <= 0;
            cnt_bp_train_total <= 0;
            cnt_bp_train_s0 <= 0;
            cnt_bp_train_s1 <= 0;
            cnt_bp_train_branch <= 0;
            cnt_bp_train_jal <= 0;
            cnt_bp_train_jalr <= 0;
            cnt_bp_train_btb_hit <= 0;
            cnt_bp_train_btb_miss <= 0;
            cnt_bp_train_btb_alloc <= 0;
            cnt_bp_btb_write <= 0;
            cnt_bp_btb_alloc_write <= 0;
            cnt_bp_pht_write <= 0;
            cnt_bp_sel_write <= 0;
            cnt_bp_ghr_write <= 0;
            cnt_bp_ras_push <= 0;
            cnt_bp_ras_pop <= 0;
            cnt_bp_jalr_side_write <= 0;
            cnt_fe_bp0_fire <= 0;
            cnt_fe_bp0_block_ftq_full <= 0;
            cnt_fe_bp0_block_fq_credit <= 0;
            cnt_fe_redirect_total <= 0;
            cnt_fe_redirect_ex <= 0;
            cnt_fe_redirect_bp1 <= 0;
            cnt_fe_f0_valid <= 0;
            cnt_fe_f0_accept <= 0;
            cnt_fe_f0_epoch_miss <= 0;
            cnt_fe_f0_ex_kill <= 0;
            cnt_fe_f0_enq0 <= 0;
            cnt_fe_f0_enq1 <= 0;
            cnt_fe_f0_enq_none <= 0;
            cnt_fe_f0_kill_slot0 <= 0;
            cnt_fe_bp1_applicable <= 0;
            cnt_fe_bp1_override <= 0;
            cnt_fe_bp1_to_taken <= 0;
            cnt_fe_bp1_to_not_taken <= 0;
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
            cnt_fwd_s1_ex      <= 0;
            cnt_fwd_s0_ex      <= 0;
            cnt_fwd_s1_mem     <= 0;
            cnt_fwd_s0_mem     <= 0;
            cnt_fwd_s1_wb      <= 0;
            cnt_fwd_s0_wb      <= 0;
            cnt_fwd_rf         <= 0;
            cnt_skip_inst0     <= 0;
            cnt_skip_and_bp_taken <= 0;
            cnt_predict_dual_err <= 0;
        end else begin
            cnt_cycles <= cnt_cycles + 1;

            // Commit
            if (wb_valid)    cnt_s0_commit <= cnt_s0_commit + 1;
            if (wb_s1_valid) cnt_s1_commit <= cnt_s1_commit + 1;

            // Priority CPI stack. Each cycle is assigned to exactly one bucket.
            if (cpi_redirect_event)
                cnt_cpi_redirect <= cnt_cpi_redirect + 1;
            else if (cpi_dcache_event)
                cnt_cpi_dcache <= cnt_cpi_dcache + 1;
            else if (cpi_muldiv_event)
                cnt_cpi_muldiv <= cnt_cpi_muldiv + 1;
            else if (cpi_raw_not_ready_event)
                cnt_cpi_raw_not_ready <= cnt_cpi_raw_not_ready + 1;
            else if (cpi_raw_ready_no_fwd_event)
                cnt_cpi_raw_ready_no_fwd <= cnt_cpi_raw_ready_no_fwd + 1;
            else if (cpi_frontend_empty_event)
                cnt_cpi_frontend_empty <= cnt_cpi_frontend_empty + 1;
            else if (!cpi_retire_event)
                cnt_cpi_other_no_commit <= cnt_cpi_other_no_commit + 1;
            else
                cnt_cpi_retire <= cnt_cpi_retire + 1;

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
            if (tb_riscv_tests.u_dcache.refill_wr) cnt_dc_refill_words <= cnt_dc_refill_words + 1;
            if (dc_refill_abort_w)                 cnt_dc_refill_aborts <= cnt_dc_refill_aborts + 1;
            if (tb_riscv_tests.u_dcache.doing_store) cnt_dc_sb_enqueue <= cnt_dc_sb_enqueue + 1;
            if (dc_sb_drain_w)                     cnt_dc_sb_drain <= cnt_dc_sb_drain + 1;
            if (dc_sb_block_w)                     cnt_dc_sb_block_cycles <= cnt_dc_sb_block_cycles + 1;
            if (tb_riscv_tests.u_dcache.sb_conflict) cnt_dc_sb_conflicts <= cnt_dc_sb_conflicts + 1;
            if (dc_store_forward_hit_w)            cnt_dc_store_forward_hits <= cnt_dc_store_forward_hits + 1;

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
            if (branch_flush_w & ex_valid)   cnt_branch_flush  <= cnt_branch_flush + 1;
            if (id_bp_redirect_w)            cnt_nlp_redirect  <= cnt_nlp_redirect + 1;
            if (ex_valid & (ex_is_branch | ex_is_jal | ex_is_jalr))
                cnt_total_branch <= cnt_total_branch + 1;

            if (bp_s0_ctrl_event) begin
                cnt_bp_s0_ctrl <= cnt_bp_s0_ctrl + 1;
                if (ex_is_branch) cnt_bp_s0_branch <= cnt_bp_s0_branch + 1;
                if (ex_is_jal)    cnt_bp_s0_jal <= cnt_bp_s0_jal + 1;
                if (ex_is_jalr)   cnt_bp_s0_jalr <= cnt_bp_s0_jalr + 1;
                if (ex_bp_taken_w)   cnt_bp_s0_pred_taken <= cnt_bp_s0_pred_taken + 1;
                if (actual_taken_w)  cnt_bp_s0_actual_taken <= cnt_bp_s0_actual_taken + 1;
                if (ex_bp_btb_hit_w) cnt_bp_s0_btb_hit <= cnt_bp_s0_btb_hit + 1;
                else                 cnt_bp_s0_btb_miss <= cnt_bp_s0_btb_miss + 1;
            end
            if (branch_flush_w) cnt_bp_s0_mispredict <= cnt_bp_s0_mispredict + 1;
            if (bp_s0_dir_to_taken_event)
                cnt_bp_s0_dir_to_taken <= cnt_bp_s0_dir_to_taken + 1;
            if (bp_s0_dir_to_fallthrough_event)
                cnt_bp_s0_dir_to_fallthrough <= cnt_bp_s0_dir_to_fallthrough + 1;
            if (bp_s0_target_wrong_event)
                cnt_bp_s0_target_wrong <= cnt_bp_s0_target_wrong + 1;

            if (bp_s1_ctrl_event) begin
                cnt_bp_s1_ctrl <= cnt_bp_s1_ctrl + 1;
                if (ex_s1_is_branch_w) cnt_bp_s1_branch <= cnt_bp_s1_branch + 1;
                if (ex_s1_is_jal_w)    cnt_bp_s1_jal <= cnt_bp_s1_jal + 1;
                if (ex_s1_bp_btb_hit_w) cnt_bp_s1_lookup_btb_hit <= cnt_bp_s1_lookup_btb_hit + 1;
                if (ex_s1_bp_taken_w) cnt_bp_s1_lookup_taken <= cnt_bp_s1_lookup_taken + 1;
                if (ex_s1_actual_taken_w) cnt_bp_s1_actual_taken <= cnt_bp_s1_actual_taken + 1;
            end
            if (bp_s1_dir_wrong_event) cnt_bp_s1_dir_wrong <= cnt_bp_s1_dir_wrong + 1;
            if (bp_s1_target_wrong_event) cnt_bp_s1_target_wrong <= cnt_bp_s1_target_wrong + 1;
            if (ex_s1_branch_redirect_w) cnt_bp_s1_redirect <= cnt_bp_s1_redirect + 1;

            if (id_bp_redirect_raw_w) cnt_bp_id_redirect_raw <= cnt_bp_id_redirect_raw + 1;
            if (id_bp_redirect_w)     cnt_bp_id_redirect <= cnt_bp_id_redirect + 1;

            if (tb_riscv_tests.u_cpu.bp_train_valid) begin
                cnt_bp_train_total <= cnt_bp_train_total + 1;
                if (tb_riscv_tests.u_cpu.bp_train_from_s1)
                    cnt_bp_train_s1 <= cnt_bp_train_s1 + 1;
                else
                    cnt_bp_train_s0 <= cnt_bp_train_s0 + 1;
                if (tb_riscv_tests.u_cpu.bp_train_is_branch)
                    cnt_bp_train_branch <= cnt_bp_train_branch + 1;
                if (tb_riscv_tests.u_cpu.bp_train_is_jal)
                    cnt_bp_train_jal <= cnt_bp_train_jal + 1;
                if (tb_riscv_tests.u_cpu.bp_train_is_jalr)
                    cnt_bp_train_jalr <= cnt_bp_train_jalr + 1;
                if (tb_riscv_tests.u_cpu.bp_train_btb_hit)
                    cnt_bp_train_btb_hit <= cnt_bp_train_btb_hit + 1;
                else
                    cnt_bp_train_btb_miss <= cnt_bp_train_btb_miss + 1;
                if (tb_riscv_tests.u_cpu.bp_train_btb_allocate)
                    cnt_bp_train_btb_alloc <= cnt_bp_train_btb_alloc + 1;
            end
            if (tb_riscv_tests.u_cpu.u_bp.ex_btb_write)
                cnt_bp_btb_write <= cnt_bp_btb_write + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_btb_write_alloc_taken)
                cnt_bp_btb_alloc_write <= cnt_bp_btb_alloc_write + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_pht_write)
                cnt_bp_pht_write <= cnt_bp_pht_write + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_sel_write)
                cnt_bp_sel_write <= cnt_bp_sel_write + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_ghr_write)
                cnt_bp_ghr_write <= cnt_bp_ghr_write + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_ras_push)
                cnt_bp_ras_push <= cnt_bp_ras_push + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_ras_pop)
                cnt_bp_ras_pop <= cnt_bp_ras_pop + 1;
            if (tb_riscv_tests.u_cpu.u_bp.ex_jalr_side_write)
                cnt_bp_jalr_side_write <= cnt_bp_jalr_side_write + 1;

            if (fe_bp0_fire_w) cnt_fe_bp0_fire <= cnt_fe_bp0_fire + 1;
            if (fe_bp0_block_ftq_full_w)
                cnt_fe_bp0_block_ftq_full <= cnt_fe_bp0_block_ftq_full + 1;
            if (fe_bp0_block_fq_credit_w)
                cnt_fe_bp0_block_fq_credit <= cnt_fe_bp0_block_fq_credit + 1;
            if (fe_redirect_valid_w) cnt_fe_redirect_total <= cnt_fe_redirect_total + 1;
            if (fe_ex_redirect_valid_w) cnt_fe_redirect_ex <= cnt_fe_redirect_ex + 1;
            if (fe_bp1_redirect_valid_w) cnt_fe_redirect_bp1 <= cnt_fe_redirect_bp1 + 1;
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
            if (fe_bp1_applicable_w) cnt_fe_bp1_applicable <= cnt_fe_bp1_applicable + 1;
            if (fe_bp1_override_w) cnt_fe_bp1_override <= cnt_fe_bp1_override + 1;
            if (fe_bp1_override_w & fe_bp1_tournament_taken_w)
                cnt_fe_bp1_to_taken <= cnt_fe_bp1_to_taken + 1;
            if (fe_bp1_override_w & ~fe_bp1_tournament_taken_w)
                cnt_fe_bp1_to_not_taken <= cnt_fe_bp1_to_not_taken + 1;
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
                end
            end
            if (id_s1_valid)  cnt_id_s1_seen  <= cnt_id_s1_seen + 1;
            if (ex_s1_valid)  cnt_ex_s1_seen  <= cnt_ex_s1_seen + 1;
            if (mem_s1_valid) cnt_mem_s1_seen <= cnt_mem_s1_seen + 1;

            // skip_inst0 analysis
            if (skip_inst0_w)                     cnt_skip_inst0     <= cnt_skip_inst0 + 1;
            if (skip_inst0_w & bp_taken_w)        cnt_skip_and_bp_taken <= cnt_skip_and_bp_taken + 1;
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
        real cpi, dual_rate, mispredict_rate, dc_hit_rate, dc_miss_rate;
        real fe_fq_avg, fe_ftq_avg;
        begin
            total_insts = cnt_s0_commit + cnt_s1_commit;
            total_fwd = cnt_fwd_s1_ex + cnt_fwd_s0_ex + cnt_fwd_s1_mem
                       + cnt_fwd_s0_mem + cnt_fwd_s1_wb + cnt_fwd_s0_wb + cnt_fwd_rf;
            cpi_stack_total = cnt_cpi_retire + cnt_cpi_redirect + cnt_cpi_dcache
                            + cnt_cpi_muldiv + cnt_cpi_raw_not_ready
                            + cnt_cpi_raw_ready_no_fwd + cnt_cpi_frontend_empty
                            + cnt_cpi_other_no_commit;

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

            if (cnt_dc_req > 0) begin
                dc_hit_rate = 100.0 * cnt_dc_hit / cnt_dc_req;
                dc_miss_rate = 100.0 * cnt_dc_miss / cnt_dc_req;
            end else begin
                dc_hit_rate = 0.0;
                dc_miss_rate = 0.0;
            end

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
            $display("[PERF]");
            $display("[PERF]  --- CPI Stack (priority cycles) ---");
            $display("[PERF]  CPI stack:     retire=%0d redirect=%0d dcache=%0d muldiv=%0d raw_not_ready=%0d raw_ready_no_fwd=%0d frontend_empty=%0d other_no_commit=%0d total=%0d",
                     cnt_cpi_retire, cnt_cpi_redirect, cnt_cpi_dcache,
                     cnt_cpi_muldiv, cnt_cpi_raw_not_ready,
                     cnt_cpi_raw_ready_no_fwd, cnt_cpi_frontend_empty,
                     cnt_cpi_other_no_commit, cpi_stack_total);
            $display("[PERF]");
            $display("[PERF]  --- Stall Breakdown (cycles) ---");
            $display("[PERF]  Load-use:      %0d", cnt_load_use_stall);
            $display("[PERF]    EX load:     %0d", cnt_load_use_ex);
            $display("[PERF]    MEM only:    %0d", cnt_load_use_mem);
            $display("[PERF]      MEM ready: %0d", cnt_load_use_mem_ready);
            $display("[PERF]      MEM block: %0d", cnt_load_use_mem_blocked);
            $display("[PERF]    S0 consumer: %0d", cnt_load_use_s0);
            $display("[PERF]    S1 consumer: %0d", cnt_load_use_s1);
            $display("[PERF]    S0 role hits:");
            $display("[PERF]      ALU:        %0d", cnt_lu_s0_alu);
            $display("[PERF]      branch:     %0d", cnt_lu_s0_branch);
            $display("[PERF]      JALR:       %0d", cnt_lu_s0_jalr);
            $display("[PERF]      load addr:  %0d", cnt_lu_s0_load_addr);
            $display("[PERF]      store addr: %0d", cnt_lu_s0_store_addr);
            $display("[PERF]      store data: %0d", cnt_lu_s0_store_data);
            $display("[PERF]      other:      %0d", cnt_lu_s0_other);
            $display("[PERF]    MEM-ready S0 role hits:");
            $display("[PERF]      ALU:        %0d", cnt_lu_mem_ready_s0_alu);
            $display("[PERF]      branch:     %0d", cnt_lu_mem_ready_s0_branch);
            $display("[PERF]      JALR:       %0d", cnt_lu_mem_ready_s0_jalr);
            $display("[PERF]      load addr:  %0d", cnt_lu_mem_ready_s0_load_addr);
            $display("[PERF]      store addr: %0d", cnt_lu_mem_ready_s0_store_addr);
            $display("[PERF]      store data: %0d", cnt_lu_mem_ready_s0_store_data);
            $display("[PERF]      other:      %0d", cnt_lu_mem_ready_s0_other);
            $display("[PERF]  Repair wait:    %0d", cnt_repair_wait);
            $display("[PERF]  JALR EX wait:   %0d", cnt_jalr_ex_wait);
            $display("[PERF]  S1-WB wait:    %0d", cnt_s1_wb_wait);
            $display("[PERF]  DCache miss:   %0d", cnt_dcache_stall);
            $display("[PERF]  MMIO hazard:   %0d", cnt_mmio_stall);
            $display("[PERF]  MUL/DIV wait:  %0d", cnt_muldiv_stall);
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
            $display("[PERF]  Store buffer:  enq=%0d drain=%0d block=%0d conflict=%0d fwd=%0d",
                     cnt_dc_sb_enqueue, cnt_dc_sb_drain, cnt_dc_sb_block_cycles,
                     cnt_dc_sb_conflicts, cnt_dc_store_forward_hits);
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
            $display("[PERF]  Unclassified ID RAW stalls:   %0d", cnt_raw_unclassified_stall);
            $display("[PERF]  Same-pair RAW lost slots:     %0d  rs1=%0d rs2=%0d",
                     cnt_if_block_raw, cnt_if_block_raw_rs1, cnt_if_block_raw_rs2);
            $display("[PERF]");
            $display("[PERF]  --- Branch ---");
            $display("[PERF]  Total branch:  %0d", cnt_total_branch);
            $display("[PERF]  Mispredicts:   %0d  (%0.1f%%)", cnt_branch_flush, mispredict_rate);
            $display("[PERF]  NLP redirects: %0d", cnt_nlp_redirect);
            $display("[PERF]");
            $display("[PERF]  --- Branch Predictor Detailed ---");
            $display("[PERF]  BP resolved:   s0=%0d branch=%0d jal=%0d jalr=%0d s1=%0d s1_branch=%0d s1_jal=%0d",
                     cnt_bp_s0_ctrl, cnt_bp_s0_branch, cnt_bp_s0_jal,
                     cnt_bp_s0_jalr, cnt_bp_s1_ctrl, cnt_bp_s1_branch,
                     cnt_bp_s1_jal);
            $display("[PERF]  BP s0 pred:    pred_taken=%0d actual_taken=%0d btb_hit=%0d btb_miss=%0d",
                     cnt_bp_s0_pred_taken, cnt_bp_s0_actual_taken,
                     cnt_bp_s0_btb_hit, cnt_bp_s0_btb_miss);
            $display("[PERF]  BP s0 miss:    total=%0d dir_to_taken=%0d dir_to_fallthrough=%0d target=%0d",
                     cnt_bp_s0_mispredict, cnt_bp_s0_dir_to_taken,
                     cnt_bp_s0_dir_to_fallthrough, cnt_bp_s0_target_wrong);
            $display("[PERF]  BP s1 lookup:  btb_hit=%0d lookup_taken=%0d actual_taken=%0d dir_wrong=%0d target_wrong=%0d redirect=%0d",
                     cnt_bp_s1_lookup_btb_hit, cnt_bp_s1_lookup_taken,
                     cnt_bp_s1_actual_taken, cnt_bp_s1_dir_wrong,
                     cnt_bp_s1_target_wrong, cnt_bp_s1_redirect);
            $display("[PERF]  BP ID redirect: raw=%0d valid=%0d",
                     cnt_bp_id_redirect_raw, cnt_bp_id_redirect);
            $display("[PERF]  BP training:   total=%0d s0=%0d s1=%0d branch=%0d jal=%0d jalr=%0d btb_hit=%0d btb_miss=%0d alloc=%0d",
                     cnt_bp_train_total, cnt_bp_train_s0, cnt_bp_train_s1,
                     cnt_bp_train_branch, cnt_bp_train_jal, cnt_bp_train_jalr,
                     cnt_bp_train_btb_hit, cnt_bp_train_btb_miss,
                     cnt_bp_train_btb_alloc);
            $display("[PERF]  BP writes:     btb=%0d btb_alloc=%0d pht=%0d selector=%0d ghr=%0d ras_push=%0d ras_pop=%0d jalr_side=%0d",
                     cnt_bp_btb_write, cnt_bp_btb_alloc_write, cnt_bp_pht_write,
                     cnt_bp_sel_write, cnt_bp_ghr_write, cnt_bp_ras_push,
                     cnt_bp_ras_pop, cnt_bp_jalr_side_write);
            $display("[PERF]");
            $display("[PERF]  --- Frontend / FTQ Detailed ---");
            $display("[PERF]  FE BP0:        fire=%0d ftq_full=%0d fq_credit_block=%0d",
                     cnt_fe_bp0_fire, cnt_fe_bp0_block_ftq_full,
                     cnt_fe_bp0_block_fq_credit);
            $display("[PERF]  FE redirect:   total=%0d ex=%0d bp1=%0d",
                     cnt_fe_redirect_total, cnt_fe_redirect_ex,
                     cnt_fe_redirect_bp1);
            $display("[PERF]  FE F0:         valid=%0d accept=%0d epoch_miss=%0d ex_kill=%0d enq0=%0d enq1=%0d enq_none=%0d kill_slot0=%0d",
                     cnt_fe_f0_valid, cnt_fe_f0_accept, cnt_fe_f0_epoch_miss,
                     cnt_fe_f0_ex_kill, cnt_fe_f0_enq0, cnt_fe_f0_enq1,
                     cnt_fe_f0_enq_none, cnt_fe_f0_kill_slot0);
            $display("[PERF]  FE BP1:        applicable=%0d override=%0d to_taken=%0d to_not_taken=%0d",
                     cnt_fe_bp1_applicable, cnt_fe_bp1_override,
                     cnt_fe_bp1_to_taken, cnt_fe_bp1_to_not_taken);
            $display("[PERF]  FE IF:         accept=%0d dual=%0d single=%0d empty=%0d fq_nonempty=%0d fq_pair_ready=%0d",
                     cnt_fe_if_accept, cnt_fe_if_accept_dual,
                     cnt_fe_if_accept_single, cnt_fe_if_empty,
                     cnt_fe_fq_nonempty_cycles, cnt_fe_fq_pair_ready_cycles);
            $display("[PERF]  FE occupancy:  fq_avg=%0.2f ftq_avg=%0.2f fq_sum=%0d ftq_sum=%0d",
                     fe_fq_avg, fe_ftq_avg,
                     cnt_fe_fq_occupancy_sum, cnt_fe_ftq_occupancy_sum);
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
            $display("[PERF]  skip+bp_taken:       %0d  (%0.2f%% of cycles)", cnt_skip_and_bp_taken, 100.0*cnt_skip_and_bp_taken/cnt_cycles);
            $display("[PERF]  predict_dual errors: %0d  (%0.2f%% of fetches)", cnt_predict_dual_err, cnt_fetch_valid > 0 ? 100.0*cnt_predict_dual_err/cnt_fetch_valid : 0.0);
            $display("[PERF] ================================================");
        end
    endtask

endmodule
