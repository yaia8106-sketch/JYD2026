`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_student_top_smoke
// Description:
//   Short student_top-level correctness smoke.
//   It keeps the real student_top/mmio_bridge path and replaces only the
//   Vivado BRAM IPs with lightweight behavioral models.
// ============================================================

module tb_student_top_smoke;
    reg w_cpu_clk = 1'b0;
    reg w_clk_50Mhz = 1'b0;
    reg w_clk_rst = 1'b1;

    wire [31:0] virtual_led;
    wire [39:0] virtual_seg;
    reg  [63:0] virtual_sw = 64'd0;
    reg  [ 7:0] virtual_key = 8'd0;

    always #2.5 w_cpu_clk = ~w_cpu_clk;      // 200 MHz
    always #10  w_clk_50Mhz = ~w_clk_50Mhz;  // 50 MHz

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
    integer max_cycles = 50000;
    integer watchdog_cycles = 5000;
    integer idle_cycles = 0;
    integer commit_cnt = 0;
    integer led_write_count = 0;
    integer led_trace_enable = 0;
    integer pc_guard_enable = 0;
    integer watchdog_fired = 0;
    integer pc_guard_fired = 0;
    integer tohost_detected = 0;
    integer cycle_timeout_fired = 0;

    reg [31:0] pc_guard_min = 32'h8000_0000;
    reg [31:0] pc_guard_max = 32'h8000_4000;
    reg [31:0] pc_guard_bad_pc = 32'd0;
    reg [31:0] tohost_value = 32'd0;
    reg [31:0] first_led = 32'd0;
    reg [31:0] last_led = 32'd0;
    reg [31:0] last_wb0_pc = 32'd0;
    reg [31:0] last_wb1_pc = 32'd0;

    reg [256*8-1:0] test_name_r;

    wire led_write = (|dut.u_mmio.wea) && (dut.u_mmio.wr_addr == LED_MMIO_ADDR);
    wire sim_progress = dut.u_cpu.wb_valid | dut.u_cpu.wb_s1_valid |
                        dut.u_cpu.id_bp_redirect | dut.u_cpu.branch_flush |
                        dut.u_cpu.mem_branch_flush | led_write;

    initial begin
        if (!$value$plusargs("test=%s", test_name_r))
            test_name_r = "student_top_smoke";
        if ($value$plusargs("cycles=%d", max_cycles))
            ;
        if ($value$plusargs("watchdog=%d", watchdog_cycles))
            ;
        if ($value$plusargs("pc_min=%h", pc_guard_min))
            ;
        if ($value$plusargs("pc_max=%h", pc_guard_max))
            ;

        led_trace_enable = $test$plusargs("led_trace");
        pc_guard_enable = $test$plusargs("pc_guard");

        w_clk_rst = 1'b1;
        #203;
        w_clk_rst = 1'b0;

        fork
            begin : wait_tohost
                wait (tohost_detected);
            end
            begin : wait_timeout
                wait (cycle_timeout_fired);
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

        if (tohost_detected) begin
            if (tohost_value == 32'd1) begin
                $display("[PASS] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                         test_name_r, commit_cnt, first_led, last_led,
                         led_write_count, dut.u_cpu.pc, last_wb0_pc,
                         last_wb1_pc, cycle_cnt);
            end else begin
                $display("[FAIL] %0s  test #%0d failed commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                         test_name_r, tohost_value >> 1, commit_cnt, first_led,
                         last_led, led_write_count, dut.u_cpu.pc, last_wb0_pc,
                         last_wb1_pc, cycle_cnt);
            end
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
        end else begin
            $display("[TIMEOUT] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (>%0d cycles)",
                     test_name_r, commit_cnt, first_led, last_led,
                     led_write_count, dut.u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     max_cycles);
        end

        $finish;
    end

    always @(posedge w_cpu_clk) begin
        if (w_clk_rst) begin
            cycle_cnt <= 0;
            idle_cycles <= 0;
            commit_cnt <= 0;
            led_write_count <= 0;
            watchdog_fired <= 0;
            pc_guard_fired <= 0;
            tohost_detected <= 0;
            cycle_timeout_fired <= 0;
            pc_guard_bad_pc <= 32'd0;
            tohost_value <= 32'd0;
            first_led <= 32'd0;
            last_led <= 32'd0;
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

            if (cycle_cnt >= max_cycles)
                cycle_timeout_fired <= 1;

            if (led_write) begin
                if (led_write_count == 0)
                    first_led <= dut.u_mmio.wdata;
                last_led <= dut.u_mmio.wdata;
                led_write_count <= led_write_count + 1;

                if (dut.u_mmio.wdata != 32'd0 && !tohost_detected) begin
                    tohost_detected <= 1;
                    tohost_value <= dut.u_mmio.wdata;
                end

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
endmodule
