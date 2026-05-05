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
    integer cnt_load_use_stall;  // ~id_ready_go & id_valid
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

    // Forwarding hit signals (slot0 rs1)
    wire fwd_s1_ex  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_ex_hit;
    wire fwd_s0_ex  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_ex_hit;
    wire fwd_s1_mem = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_mem_hit;
    wire fwd_s0_mem = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_mem_hit;
    wire fwd_s1_wb  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s1_wb_hit;
    wire fwd_s0_wb  = tb_riscv_tests.u_cpu.u_forwarding.s0_rs1_s0_wb_hit;

    // ================================================================
    //  Counting logic
    // ================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cnt_cycles         <= 0;
            cnt_s0_commit      <= 0;
            cnt_s1_commit      <= 0;
            cnt_load_use_stall <= 0;
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
        end else begin
            cnt_cycles <= cnt_cycles + 1;

            // Commit
            if (wb_valid)    cnt_s0_commit <= cnt_s0_commit + 1;
            if (wb_s1_valid) cnt_s1_commit <= cnt_s1_commit + 1;

            // Stall
            if (id_valid & !id_ready_go_w)  cnt_load_use_stall <= cnt_load_use_stall + 1;
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
            $display("[PERF] ================================================");
        end
    endtask

endmodule
