`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_student_top_coe
// Description:
//   student_top-level COE simulation for board-program triage.
//   This keeps the real student_top/mmio_bridge path and replaces only the
//   Vivado BRAM IPs with lightweight behavioral models.
// ============================================================

module tb_student_top_coe;
    reg w_cpu_clk = 1'b0;
    reg w_clk_50Mhz = 1'b0;
    reg w_clk_rst = 1'b1;  // active high, same polarity as student_top input

    wire [31:0] virtual_led;
    wire [39:0] virtual_seg;
    reg  [63:0] virtual_sw = 64'd0;
    reg  [ 7:0] virtual_key = 8'd0;

    always #2.5 w_cpu_clk = ~w_cpu_clk;   // 200 MHz
    always #10  w_clk_50Mhz = ~w_clk_50Mhz; // 50 MHz

    student_top dut (
        .w_cpu_clk   (w_cpu_clk),
        .w_clk_50Mhz (w_clk_50Mhz),
        .w_clk_rst   (w_clk_rst),
        .virtual_key (virtual_key),
        .virtual_sw  (virtual_sw),
        .virtual_seg (virtual_seg),
        .virtual_led (virtual_led)
    );

    localparam LED_MMIO_ADDR = 32'h8020_0040;

    integer cycle_cnt = 0;
    integer max_cycles = 5_000_000;
    integer cycle_timeout_enable = 1;
    integer max_commits = 0;
    integer commit_cnt = 0;
    integer watchdog_cycles = 0;
    integer idle_cycles = 0;
    integer trace_fd = 0;
    integer trace_enable = 0;
    integer led_trace_enable = 0;
    integer pc_guard_enable = 0;
    integer watchdog_fired = 0;
    integer pc_guard_fired = 0;
    integer commit_limit_hit = 0;
    integer stop_pc_enable = 0;
    integer stop_pc_hit = 0;
    integer led_write_count = 0;
    reg [31:0] pc_guard_min = 32'h8000_0000;
    reg [31:0] pc_guard_max = 32'h8000_4000;
    reg [31:0] pc_guard_bad_pc = 32'd0;
    reg [31:0] stop_pc = 32'd0;
    reg [31:0] stop_pc_seen = 32'd0;
    reg [31:0] first_led = 32'd0;
    reg [31:0] last_led = 32'd0;
    reg [31:0] last_wb0_pc = 32'd0;
    reg [31:0] last_wb1_pc = 32'd0;

    reg [256*8-1:0] test_name_r;
    reg [256*8-1:0] trace_file_r;

    wire led_write = (|dut.u_mmio.wea) && (dut.u_mmio.wr_addr == LED_MMIO_ADDR);
    wire sim_progress = dut.u_cpu.wb_valid | dut.u_cpu.wb_s1_valid |
                        dut.u_cpu.id_bp_redirect | dut.u_cpu.branch_flush |
                        dut.u_cpu.mem_branch_flush | led_write;

    initial begin
        if (!$value$plusargs("test=%s", test_name_r))
            test_name_r = "student_top_coe";
        if ($value$plusargs("cycles=%d", max_cycles))
            ;
        if ($test$plusargs("no_cycle_timeout"))
            cycle_timeout_enable = 0;
        if ($value$plusargs("commits=%d", max_commits))
            ;
        if ($value$plusargs("stop_pc=%h", stop_pc))
            stop_pc_enable = 1;
        if ($value$plusargs("watchdog=%d", watchdog_cycles))
            ;
        if ($value$plusargs("pc_min=%h", pc_guard_min))
            ;
        if ($value$plusargs("pc_max=%h", pc_guard_max))
            ;

        trace_enable = $test$plusargs("trace");
        led_trace_enable = $test$plusargs("led_trace");
        pc_guard_enable = $test$plusargs("pc_guard");
        if (!$value$plusargs("trace_file=%s", trace_file_r))
            trace_file_r = "student_top_trace.log";

        if (trace_enable) begin
            trace_fd = $fopen(trace_file_r, "w");
            if (trace_fd == 0) begin
                $display("ERROR: cannot open trace file: %0s", trace_file_r);
                $finish;
            end
            $fdisplay(trace_fd, "# cycle event pc inst rd data extra");
        end

        // Board-like reset: asserted during clock startup, then released.
        w_clk_rst = 1'b1;
        #203;
        w_clk_rst = 1'b0;

        fork
            begin : wait_timeout
                wait (cycle_timeout_enable && (cycle_cnt >= max_cycles));
            end
            begin : wait_stop_pc
                wait (stop_pc_hit);
            end
            begin : wait_commit_limit
                wait (commit_limit_hit);
            end
            begin : wait_watchdog
                wait (watchdog_fired);
            end
            begin : wait_pc_guard
                wait (pc_guard_fired);
            end
        join_any
        disable fork;

        #20;

        if (stop_pc_hit) begin
            $display("[DONE] %0s  reached stop_pc=0x%08x commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, stop_pc_seen, commit_cnt, first_led, last_led,
                     led_write_count, dut.u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     cycle_cnt);
        end else if (pc_guard_fired) begin
            $display("[FAIL] %0s  PC_OUT_OF_RANGE pc=0x%08x allowed=[0x%08x,0x%08x) commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, pc_guard_bad_pc, pc_guard_min, pc_guard_max,
                     commit_cnt, first_led, last_led, led_write_count,
                     last_wb0_pc, last_wb1_pc, cycle_cnt);
        end else if (watchdog_fired) begin
            $display("[TIMEOUT] %0s  no pipeline progress for %0d cycles commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, watchdog_cycles, commit_cnt, first_led,
                     last_led, led_write_count, dut.u_cpu.pc, last_wb0_pc,
                     last_wb1_pc, cycle_cnt);
        end else if (commit_limit_hit) begin
            $display("[DONE] %0s  reached %0d commits first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, commit_cnt, first_led, last_led,
                     led_write_count, dut.u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     cycle_cnt);
        end else begin
            $display("[TIMEOUT] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (>%0d cycles)",
                     test_name_r, commit_cnt, first_led, last_led,
                     led_write_count, dut.u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     max_cycles);
        end

        if (trace_fd != 0)
            $fclose(trace_fd);
        $finish;
    end

    always @(posedge w_cpu_clk) begin
        if (w_clk_rst) begin
            cycle_cnt <= 0;
            idle_cycles <= 0;
            commit_cnt <= 0;
            commit_limit_hit <= 0;
            stop_pc_hit <= 0;
            watchdog_fired <= 0;
            pc_guard_fired <= 0;
            pc_guard_bad_pc <= 32'd0;
            stop_pc_seen <= 32'd0;
            first_led <= 32'd0;
            last_led <= 32'd0;
            led_write_count <= 0;
            last_wb0_pc <= 32'd0;
            last_wb1_pc <= 32'd0;
        end else begin
            cycle_cnt <= cycle_cnt + 1;
            commit_cnt <= commit_cnt + (dut.u_cpu.wb_valid ? 1 : 0)
                                     + (dut.u_cpu.wb_s1_valid ? 1 : 0);

            if (dut.u_cpu.wb_valid)
                last_wb0_pc <= dut.u_cpu.wb_pc_plus_4 - 32'd4;
            if (dut.u_cpu.wb_s1_valid)
                last_wb1_pc <= dut.u_cpu.wb_s1_pc;

            if (max_commits != 0 && commit_cnt >= max_commits)
                commit_limit_hit <= 1;

            if (stop_pc_enable && !stop_pc_hit) begin
                if (dut.u_cpu.wb_valid &&
                    ((dut.u_cpu.wb_pc_plus_4 - 32'd4) == stop_pc)) begin
                    stop_pc_hit <= 1;
                    stop_pc_seen <= dut.u_cpu.wb_pc_plus_4 - 32'd4;
                end else if (dut.u_cpu.wb_s1_valid &&
                             (dut.u_cpu.wb_s1_pc == stop_pc)) begin
                    stop_pc_hit <= 1;
                    stop_pc_seen <= dut.u_cpu.wb_s1_pc;
                end
            end

            if (led_write) begin
                if (led_write_count == 0)
                    first_led <= dut.u_mmio.wdata;
                last_led <= dut.u_mmio.wdata;
                led_write_count <= led_write_count + 1;
                if (led_trace_enable)
                    $display("[LED] %0s  cycle=%0d mem_pc=0x%08x value=0x%08x writes=%0d",
                             test_name_r, cycle_cnt, dut.u_cpu.mem_pc,
                             dut.u_mmio.wdata, led_write_count + 1);
            end

            if (sim_progress)
                idle_cycles <= 0;
            else if (watchdog_cycles != 0 && !watchdog_fired)
                idle_cycles <= idle_cycles + 1;

            if (watchdog_cycles != 0 && idle_cycles >= watchdog_cycles)
                watchdog_fired <= 1;

            if (pc_guard_enable && cycle_cnt > 8 && !pc_guard_fired &&
                (dut.u_cpu.pc < pc_guard_min || dut.u_cpu.pc >= pc_guard_max)) begin
                pc_guard_fired <= 1;
                pc_guard_bad_pc <= dut.u_cpu.pc;
            end
        end
    end

    always @(posedge w_cpu_clk) begin
        if (!w_clk_rst && trace_enable && trace_fd != 0) begin
            if (dut.u_cpu.id_bp_redirect)
                $fdisplay(trace_fd, "%0d ID_REDIRECT pc=%08x target=%08x taken=%0d",
                          cycle_cnt, dut.u_cpu.id_pc, dut.u_cpu.id_redirect_target,
                          dut.u_cpu.id_tournament_taken);
            if (dut.u_cpu.branch_flush)
                $fdisplay(trace_fd, "%0d EX_FLUSH pc=%08x target=%08x actual=%0d pred=%0d",
                          cycle_cnt, dut.u_cpu.ex_pc, dut.u_cpu.branch_target,
                          dut.u_cpu.actual_taken, dut.u_cpu.ex_bp_taken);
            if (dut.u_cpu.mem_branch_flush)
                $fdisplay(trace_fd, "%0d MEM_FLUSH target=%08x",
                          cycle_cnt, dut.u_cpu.mem_branch_target);
            if (dut.u_cpu.wb_valid)
                $fdisplay(trace_fd, "%0d WB0 pc=%08x rd=%0d wen=%0d data=%08x",
                          cycle_cnt, dut.u_cpu.wb_pc_plus_4 - 32'd4,
                          dut.u_cpu.wb_rd, dut.u_cpu.wb_reg_write_en,
                          dut.u_cpu.wb_write_data);
            if (dut.u_cpu.wb_s1_valid)
                $fdisplay(trace_fd, "%0d WB1 pc=%08x rd=%0d wen=%0d data=%08x inst=%08x",
                          cycle_cnt, dut.u_cpu.wb_s1_pc, dut.u_cpu.wb_s1_rd,
                          dut.u_cpu.wb_s1_reg_write_en, dut.u_cpu.wb_s1_write_data,
                          dut.u_cpu.wb_s1_inst);
        end
    end
endmodule
