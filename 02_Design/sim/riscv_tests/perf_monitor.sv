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
    integer cnt_cycles;
    integer cnt_s0_commit;       // slot0 instructions committed (wb_valid)
    integer cnt_s1_commit;       // slot1 instructions committed (wb_s1_valid)

    // -- Stall breakdown --
    integer cnt_load_use_stall;  // load_use_hazard & id_valid
    integer cnt_load_use_ex;     // load-use caused by load in EX
    integer cnt_load_use_mem;    // load-use caused only by load in MEM
    integer cnt_load_use_mem_ready;   // MEM-only load-use while MEM can advance
    integer cnt_load_use_mem_blocked; // MEM-only load-use hidden by DCache/MEM stall
    integer cnt_load_use_s0;     // slot0 consumer participates in load-use
    integer cnt_load_use_s1;     // slot1 consumer participates in load-use
    integer cnt_lu_s0_alu;       // S0 load-use where consumer is ordinary ALU
    integer cnt_lu_s0_branch;    // S0 load-use where consumer is branch compare
    integer cnt_lu_s0_jalr;      // S0 load-use where consumer is JALR target
    integer cnt_lu_s0_load_addr; // S0 load-use on load address rs1
    integer cnt_lu_s0_store_addr;// S0 load-use on store address rs1
    integer cnt_lu_s0_store_data;// S0 load-use on store data rs2
    integer cnt_lu_s0_other;     // S0 load-use that did not fit the above
    integer cnt_lu_mem_ready_s0_alu;
    integer cnt_lu_mem_ready_s0_branch;
    integer cnt_lu_mem_ready_s0_jalr;
    integer cnt_lu_mem_ready_s0_load_addr;
    integer cnt_lu_mem_ready_s0_store_addr;
    integer cnt_lu_mem_ready_s0_store_data;
    integer cnt_lu_mem_ready_s0_other;
    integer cnt_repair_wait;     // younger consumer waiting for repaired EX ALU result
    integer cnt_jalr_ex_wait;    // JALR waits for EX/S1_EX producer to reach MEM
    integer cnt_s1_wb_wait;      // pruned S1_WB forwarding path wait
    integer cnt_dcache_stall;    // ~mem_ready_go & mem_valid
    integer cnt_mmio_stall;      // ~ex_ready_go & ex_valid

    // -- Flush --
    integer cnt_branch_flush;    // branch misprediction (EX)
    integer cnt_nlp_redirect;    // NLP L1 redirect (ID)
    integer cnt_total_branch;    // total branch instructions reaching EX

    // -- Dual-issue opportunity loss --
    integer cnt_fetch_valid;     // if_valid cycles (fetch active)
    integer cnt_pc2_fetch;       // PC[2]=1 fetch cycles (no longer blocks dual)
    integer cnt_raw_block;       // same-pair RAW dependency
    integer cnt_inst1_not_alu;   // slot1 not ALU type
    integer cnt_inst0_jump;      // slot0 is JAL/JALR
    integer cnt_not_sequential;  // flush/redirect/bp_taken preventing dual
    integer cnt_dual_issued;     // actually dual-issued

    // -- Forwarding source distribution (slot0 rs1 as representative) --
    integer cnt_fwd_s1_ex;
    integer cnt_fwd_s0_ex;
    integer cnt_fwd_s1_mem;
    integer cnt_fwd_s0_mem;
    integer cnt_fwd_s1_wb;
    integer cnt_fwd_s0_wb;
    integer cnt_fwd_rf;

    // -- skip_inst0 timing fix analysis --
    integer cnt_skip_inst0;          // cycles where skip_inst0_valid=1
    integer cnt_skip_and_bp_taken;   // skip_inst0=1 AND bp_taken=1 (would mispredict)
    integer cnt_predict_dual_err;    // predict_dual != can_dual (misprediction events)

    // ================================================================
    //  Signal taps (hierarchical references into cpu_top)
    // ================================================================

    // Access signals through the testbench hierarchy
    wire        wb_valid        = tb_riscv_tests.u_cpu.wb_valid;
    wire        wb_s1_valid     = tb_riscv_tests.u_cpu.wb_s1_valid;
    wire        id_valid        = tb_riscv_tests.u_cpu.id_valid;
    wire        ex_valid        = tb_riscv_tests.u_cpu.ex_valid;
    wire        mem_valid       = tb_riscv_tests.u_cpu.mem_valid;
    wire        if_valid        = tb_riscv_tests.u_cpu.if_valid;

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
    wire        s1_wb_wait_hazard_w = tb_riscv_tests.u_cpu.u_forwarding.s1_wb_wait_hazard;
    wire        ex_ready_go_w   = tb_riscv_tests.u_cpu.ex_ready_go_w;
    wire        mem_ready_go_w  = tb_riscv_tests.u_cpu.mem_ready_go_w;

    wire        branch_flush_w  = tb_riscv_tests.u_cpu.branch_flush;
    wire        mem_branch_flush_w = tb_riscv_tests.u_cpu.mem_branch_flush;
    wire        id_bp_redirect_w = tb_riscv_tests.u_cpu.id_bp_redirect;
    wire        ex_is_branch    = tb_riscv_tests.u_cpu.ex_is_branch;
    wire        ex_is_jal       = tb_riscv_tests.u_cpu.ex_is_jal;
    wire        ex_is_jalr      = tb_riscv_tests.u_cpu.ex_is_jalr;

    wire [31:0] pc              = tb_riscv_tests.u_cpu.pc;
    wire        can_dual_w      = tb_riscv_tests.u_cpu.can_dual_issue;
    wire        if_seq_fetch    = tb_riscv_tests.u_cpu.if_sequential_fetch;
    wire        raw_pair_raw_w  = tb_riscv_tests.u_cpu.raw_pair_raw;
    wire        raw_inst1_alu   = tb_riscv_tests.u_cpu.raw_inst1_is_alu_type;
    wire        raw_inst0_jump  = tb_riscv_tests.u_cpu.raw_inst0_is_jump;
    wire        irom_held_valid = tb_riscv_tests.u_cpu.irom_held_valid;

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

    // S0 load-use role classification. These mirrors are simulation-only and
    // intentionally separate rs1/rs2 so store address/data can be distinguished.
    wire [4:0] id_rs1_addr_w = tb_riscv_tests.u_cpu.id_rs1_addr;
    wire [4:0] id_rs2_addr_w = tb_riscv_tests.u_cpu.id_rs2_addr;
    wire       id_rs1_used_w = tb_riscv_tests.u_cpu.id_rs1_used;
    wire       id_rs2_used_w = tb_riscv_tests.u_cpu.id_rs2_used;
    wire [4:0] ex_rd_w       = tb_riscv_tests.u_cpu.ex_rd;
    wire [4:0] ex_s1_rd_w    = tb_riscv_tests.u_cpu.ex_s1_rd;
    wire [4:0] mem_rd_w      = tb_riscv_tests.u_cpu.mem_rd;
    wire       ex_mem_read_w    = tb_riscv_tests.u_cpu.ex_mem_read_en;
    wire       ex_s1_mem_read_w = tb_riscv_tests.u_cpu.ex_s1_mem_read_en;
    wire       mem_mem_read_w   = tb_riscv_tests.u_cpu.mem_mem_read_en;

    wire       dec_reg_write_w = tb_riscv_tests.u_cpu.dec_reg_write_en;
    wire [1:0] dec_wb_sel_w    = tb_riscv_tests.u_cpu.dec_wb_sel;
    wire       dec_mem_read_w  = tb_riscv_tests.u_cpu.dec_mem_read_en;
    wire       dec_mem_write_w = tb_riscv_tests.u_cpu.dec_mem_write_en;
    wire       dec_is_branch_w = tb_riscv_tests.u_cpu.dec_is_branch;
    wire       dec_is_jal_w    = tb_riscv_tests.u_cpu.dec_is_jal;
    wire       dec_is_jalr_w   = tb_riscv_tests.u_cpu.dec_is_jalr;

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

    // ================================================================
    //  Counting logic
    // ================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_cycles         <= 0;
            cnt_s0_commit      <= 0;
            cnt_s1_commit      <= 0;
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
            cnt_branch_flush   <= 0;
            cnt_nlp_redirect   <= 0;
            cnt_total_branch   <= 0;
            cnt_fetch_valid    <= 0;
            cnt_pc2_fetch      <= 0;
            cnt_raw_block      <= 0;
            cnt_inst1_not_alu  <= 0;
            cnt_inst0_jump     <= 0;
            cnt_not_sequential <= 0;
            cnt_dual_issued    <= 0;
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
            if (ex_valid & !ex_ready_go_w)   cnt_mmio_stall     <= cnt_mmio_stall + 1;

            // Flush
            if (branch_flush_w & ex_valid)   cnt_branch_flush  <= cnt_branch_flush + 1;
            if (id_bp_redirect_w)            cnt_nlp_redirect  <= cnt_nlp_redirect + 1;
            if (ex_valid & (ex_is_branch | ex_is_jal | ex_is_jalr))
                cnt_total_branch <= cnt_total_branch + 1;

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
        integer total_insts, total_fwd;
        real cpi, dual_rate, mispredict_rate;
        begin
            total_insts = cnt_s0_commit + cnt_s1_commit;
            total_fwd = cnt_fwd_s1_ex + cnt_fwd_s0_ex + cnt_fwd_s1_mem
                       + cnt_fwd_s0_mem + cnt_fwd_s1_wb + cnt_fwd_s0_wb + cnt_fwd_rf;

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

            $display("");
            $display("[PERF] ============ Performance Report ============");
            $display("[PERF]  Cycles:        %0d", cnt_cycles);
            $display("[PERF]  S0 commits:    %0d", cnt_s0_commit);
            $display("[PERF]  S1 commits:    %0d", cnt_s1_commit);
            $display("[PERF]  Total insts:   %0d", total_insts);
            $display("[PERF]  CPI:           %0.3f", cpi);
            $display("[PERF]  Dual-issue %%:  %0.1f%%", dual_rate);
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
            $display("[PERF]");
            $display("[PERF]  --- Branch ---");
            $display("[PERF]  Total branch:  %0d", cnt_total_branch);
            $display("[PERF]  Mispredicts:   %0d  (%0.1f%%)", cnt_branch_flush, mispredict_rate);
            $display("[PERF]  NLP redirects: %0d", cnt_nlp_redirect);
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
