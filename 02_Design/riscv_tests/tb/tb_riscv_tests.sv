`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_riscv_tests
// Description: 自动化 riscv-tests 验证平台
//   - 直接例化 cpu_top + dcache，内联 IROM/DRAM 仿真模型
//   - 通过 $readmemh + plusarg 加载测试程序
//   - 监控 tohost (DRAM[0]) 判定 pass/fail
//
// 用法 (VCS):
//   vcs -full64 -sverilog -top tb_riscv_tests -o simv <rtl_files>
//   ./simv +irom=hex/rv32ui-p-add.irom.hex \
//          +dram=hex/rv32ui-p-add.dram.hex +test=add
//   ./simv +irom_slot0=hex/prog.irom_slot0.hex \
//          +irom_slot1=hex/prog.irom_slot1.hex \
//          +dram=hex/prog.dram.hex +test=prog
// ============================================================

module tb_riscv_tests;

    // ================================================================
    //  Clock & Reset
    // ================================================================
    reg clk = 0;
    reg rst_n = 0;

    always #10 clk = ~clk;   // 50MHz, 20ns period

    // ================================================================
    //  CPU ↔ DCache interface
    // ================================================================
    wire [11:0] irom_addr;
    wire [63:0] irom_data;

    // DCache interface (cpu_top ↔ dcache)
    wire        cache_req;
    wire        cache_wr;
    wire [31:0] cache_addr;
    wire [ 3:0] cache_wea;
    wire [31:0] cache_wdata;
    wire [31:0] cache_rdata;
    wire        cache_ready;
    wire        cache_flush;

    // MMIO interface (for uncacheable accesses — unused in riscv-tests)
    wire [31:0] mmio_addr;
    wire [31:0] mmio_wr_addr;
    wire [ 3:0] mmio_wea;
    wire [31:0] mmio_wdata;
    reg  [31:0] mmio_rdata;
    wire        timer_irq_pending;

    // DCache ↔ DRAM
    wire [15:0] dram_rd_addr;
    wire [31:0] dram_rdata_w;
    wire [15:0] dram_wr_addr;
    wire [ 3:0] dram_wea;
    wire [31:0] dram_wdata;

    // DCache pipeline sync
    wire cache_pipeline_stall;

    // ================================================================
    //  CPU Core
    // ================================================================
    cpu_top u_cpu (
        .clk            (clk),
        .rst_n          (rst_n),
        .irom_addr      (irom_addr),
        .irom_data      (irom_data),
        .cache_req      (cache_req),
        .cache_wr       (cache_wr),
        .cache_addr     (cache_addr),
        .cache_wea      (cache_wea),
        .cache_wdata    (cache_wdata),
        .cache_rdata    (cache_rdata),
        .cache_ready    (cache_ready),
        .cache_flush    (cache_flush),
        .cache_pipeline_stall (cache_pipeline_stall),
        .mmio_addr      (mmio_addr),
        .mmio_wr_addr   (mmio_wr_addr),
        .mmio_wea       (mmio_wea),
        .mmio_wdata     (mmio_wdata),
        .mmio_rdata     (mmio_rdata),
        .timer_irq_pending (timer_irq_pending)
    );

    // ================================================================
    //  DCache
    // ================================================================
    dcache u_dcache (
        .clk         (clk),
        .rst_n       (rst_n),
        .cpu_req     (cache_req),
        .cpu_wr      (cache_wr),
        .cpu_addr    (cache_addr),
        .cpu_wea     (cache_wea),
        .cpu_wdata   (cache_wdata),
        .cpu_rdata   (cache_rdata),
        .cpu_ready   (cache_ready),
        .pipeline_stall (cache_pipeline_stall),
        .flush       (cache_flush),      // pipeline flush → abort refill
        .dram_rd_addr(dram_rd_addr),
        .dram_rdata  (dram_rdata_w),
        .dram_wr_addr(dram_wr_addr),
        .dram_wea    (dram_wea),
        .dram_wdata  (dram_wdata)
    );

    // ================================================================
    //  IROM Model (1-cycle latency, 64-bit aligned blocks)
    //  Address: 0x80000000 ~ 0x80003FFF, 2048 x 64-bit blocks
    // ================================================================
    reg [31:0] irom [0:4095];
    reg [31:0] irom_slot0 [0:4095];
    reg [31:0] irom_slot1 [0:4095];
    reg [63:0] irom_data_r;
    integer    irom_banked_enable = 0;
    wire [12:0] irom_word0_addr = {irom_addr, 1'b0};
    wire [12:0] irom_word1_addr = {irom_addr, 1'b1};

    always @(posedge clk) begin
        if (irom_banked_enable) begin
            irom_data_r <= {irom_slot1[irom_addr], irom_slot0[irom_addr]};
        end else begin
            irom_data_r <= {
                (irom_word1_addr < 13'd4096) ? irom[irom_word1_addr[11:0]] : 32'h00000013,
                (irom_word0_addr < 13'd4096) ? irom[irom_word0_addr[11:0]] : 32'h00000013
            };
        end
    end

    assign irom_data = irom_data_r;

    // ================================================================
    //  DRAM Model — Simple Dual Port, WITH Output Register (DOB_REG=1)
    //   Write port (Port A): dram_wr_addr + dram_wea + dram_wdata
    //   Read port (Port B):  dram_rd_addr → dram_rdata (2 cycle: BRAM + output reg)
    //  65536 x 32-bit words = 256KB
    //  NOTE: Must match actual DRAM4MyOwn IP config (DOB_REG=1, 2-cycle read latency)
    // ================================================================
    reg [31:0] dram [0:65535];
    reg [31:0] dram_dout_raw;       // BRAM read (1st cycle)
    reg [31:0] dram_dout;           // Output register (2nd cycle, matches DOB_REG=1)

    always @(posedge clk) begin
        // Write port (from DCache store buffer drain)
        if (dram_wea[0]) dram[dram_wr_addr][ 7: 0] <= dram_wdata[ 7: 0];
        if (dram_wea[1]) dram[dram_wr_addr][15: 8] <= dram_wdata[15: 8];
        if (dram_wea[2]) dram[dram_wr_addr][23:16] <= dram_wdata[23:16];
        if (dram_wea[3]) dram[dram_wr_addr][31:24] <= dram_wdata[31:24];
        // Read port: 2-cycle latency (BRAM + output register, matches DRAM4MyOwn DOB_REG=1)
        dram_dout_raw <= dram[dram_rd_addr];
        dram_dout     <= dram_dout_raw;
    end

    assign dram_rdata_w = dram_dout;

    // MMIO: In simulation, also map to DRAM for non-cacheable accesses
    // This handles riscv-tests that access addresses outside DRAM range
    // (e.g., stack at sp=0xFFFFFFFC). In real hardware, these would be
    // handled by mmio_bridge; in TB, we route them to DRAM.
    wire [15:0] mmio_rd_word_addr = mmio_addr[17:2];
    wire [15:0] mmio_wr_word_addr = mmio_wr_addr[17:2];
    reg  [31:0] mmio_rd_reg;
    reg  [63:0] tb_mtime;
    reg  [63:0] tb_mtimecmp;

    localparam MTIME_LO_ADDR    = 32'h8020_0070;
    localparam MTIME_HI_ADDR    = 32'h8020_0074;
    localparam MTIMECMP_LO_ADDR = 32'h8020_0078;
    localparam MTIMECMP_HI_ADDR = 32'h8020_007C;

    assign timer_irq_pending = (tb_mtime >= tb_mtimecmp);

    always @(posedge clk) begin
        if (!rst_n) begin
            tb_mtime    <= 64'd0;
            tb_mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            mmio_rd_reg <= 32'd0;
        end else begin
            tb_mtime <= tb_mtime + 64'd1;

            // MMIO read: timer registers or fallback DRAM mirror.
            case (mmio_addr)
                MTIME_LO_ADDR:    mmio_rd_reg <= tb_mtime[31:0];
                MTIME_HI_ADDR:    mmio_rd_reg <= tb_mtime[63:32];
                MTIMECMP_LO_ADDR: mmio_rd_reg <= tb_mtimecmp[31:0];
                MTIMECMP_HI_ADDR: mmio_rd_reg <= tb_mtimecmp[63:32];
                default:          mmio_rd_reg <= dram[mmio_rd_word_addr];
            endcase
        end

        // MMIO write: map to DRAM
        if (mmio_wea[0]) dram[mmio_wr_word_addr][ 7: 0] <= mmio_wdata[ 7: 0];
        if (mmio_wea[1]) dram[mmio_wr_word_addr][15: 8] <= mmio_wdata[15: 8];
        if (mmio_wea[2]) dram[mmio_wr_word_addr][23:16] <= mmio_wdata[23:16];
        if (mmio_wea[3]) dram[mmio_wr_word_addr][31:24] <= mmio_wdata[31:24];

        if (rst_n) begin
            if (mmio_wr_addr == MTIME_LO_ADDR) begin
                if (mmio_wea[0]) tb_mtime[ 7: 0] <= mmio_wdata[ 7: 0];
                if (mmio_wea[1]) tb_mtime[15: 8] <= mmio_wdata[15: 8];
                if (mmio_wea[2]) tb_mtime[23:16] <= mmio_wdata[23:16];
                if (mmio_wea[3]) tb_mtime[31:24] <= mmio_wdata[31:24];
            end
            if (mmio_wr_addr == MTIME_HI_ADDR) begin
                if (mmio_wea[0]) tb_mtime[39:32] <= mmio_wdata[ 7: 0];
                if (mmio_wea[1]) tb_mtime[47:40] <= mmio_wdata[15: 8];
                if (mmio_wea[2]) tb_mtime[55:48] <= mmio_wdata[23:16];
                if (mmio_wea[3]) tb_mtime[63:56] <= mmio_wdata[31:24];
            end
            if (mmio_wr_addr == MTIMECMP_LO_ADDR) begin
                if (mmio_wea[0]) tb_mtimecmp[ 7: 0] <= mmio_wdata[ 7: 0];
                if (mmio_wea[1]) tb_mtimecmp[15: 8] <= mmio_wdata[15: 8];
                if (mmio_wea[2]) tb_mtimecmp[23:16] <= mmio_wdata[23:16];
                if (mmio_wea[3]) tb_mtimecmp[31:24] <= mmio_wdata[31:24];
            end
            if (mmio_wr_addr == MTIMECMP_HI_ADDR) begin
                if (mmio_wea[0]) tb_mtimecmp[39:32] <= mmio_wdata[ 7: 0];
                if (mmio_wea[1]) tb_mtimecmp[47:40] <= mmio_wdata[15: 8];
                if (mmio_wea[2]) tb_mtimecmp[55:48] <= mmio_wdata[23:16];
                if (mmio_wea[3]) tb_mtimecmp[63:56] <= mmio_wdata[31:24];
            end
        end
    end

    assign mmio_rdata = mmio_rd_reg;

    // ================================================================
    //  Result Monitoring
    //  The custom riscv-tests environment reports through LED MMIO:
    //    LED == 1           -> PASS
    //    LED == (n<<1)|1    -> FAIL at test #n
    // ================================================================
    localparam LED_MMIO_ADDR = 32'h8020_0040;

    reg        tohost_detected;
    reg [31:0] tohost_value;
    reg [31:0] last_tohost_value;
    integer    led_write_count;
    integer    led_trace_enable = 0;

    wire led_write = |mmio_wea && mmio_wr_addr == LED_MMIO_ADDR;

    always @(posedge clk) begin
        if (!rst_n) begin
            tohost_detected  <= 1'b0;
            tohost_value     <= 32'd0;
            last_tohost_value <= 32'd0;
            led_write_count  <= 0;
        end else if (!tohost_detected && led_write) begin
            tohost_detected <= 1'b1;
            tohost_value    <= mmio_wdata;
            last_tohost_value <= mmio_wdata;
            led_write_count <= led_write_count + 1;
            if (led_trace_enable)
                $display("[LED] %0s  cycle=%0d mem_pc=0x%08x value=0x%08x writes=%0d",
                         test_name_r, cycle_cnt, u_cpu.mem_pc, mmio_wdata,
                         led_write_count + 1);
        end else if (led_write) begin
            last_tohost_value <= mmio_wdata;
            led_write_count <= led_write_count + 1;
            if (led_trace_enable)
                $display("[LED] %0s  cycle=%0d mem_pc=0x%08x value=0x%08x writes=%0d",
                         test_name_r, cycle_cnt, u_cpu.mem_pc, mmio_wdata,
                         led_write_count + 1);
        end
    end

    // ================================================================
    //  Test Harness
    // ================================================================
    integer cycle_cnt = 0;
    integer max_cycles = 50000;
    integer cycle_timeout_enable = 1;
    integer max_commits = 0;
    integer commit_cnt = 0;
    integer watchdog_cycles = 0;
    integer idle_cycles = 0;
    integer trace_fd = 0;
    integer trace_enable = 0;
    integer pc_guard_enable = 0;
    integer watchdog_fired = 0;
    integer pc_guard_fired = 0;
    integer commit_limit_hit = 0;
    integer stop_pc_enable = 0;
    integer stop_pc_hit = 0;
    reg [31:0] pc_guard_min = 32'h8000_0000;
    reg [31:0] pc_guard_max = 32'h8000_4000;
    reg [31:0] pc_guard_bad_pc = 32'd0;
    reg [31:0] stop_pc = 32'd0;
    reg [31:0] stop_pc_seen = 32'd0;
    reg [31:0] last_wb0_pc = 32'd0;
    reg [31:0] last_wb1_pc = 32'd0;

    // Plusarg strings
    reg [256*8-1:0] irom_file_r;
    reg [256*8-1:0] irom_slot0_file_r;
    reg [256*8-1:0] irom_slot1_file_r;
    reg [256*8-1:0] dram_file_r;
    reg [256*8-1:0] test_name_r;
    reg [256*8-1:0] trace_file_r;

    initial begin
        // ---- Parse plusargs ----
        irom_banked_enable = 0;
        if ($value$plusargs("irom_slot0=%s", irom_slot0_file_r)) begin
            if (!$value$plusargs("irom_slot1=%s", irom_slot1_file_r)) begin
                $display("ERROR: specify both +irom_slot0=<file.hex> and +irom_slot1=<file.hex>");
                $finish;
            end
            irom_banked_enable = 1;
        end else if ($value$plusargs("irom_slot1=%s", irom_slot1_file_r)) begin
            $display("ERROR: specify both +irom_slot0=<file.hex> and +irom_slot1=<file.hex>");
            $finish;
        end else begin
            if (!$value$plusargs("irom=%s", irom_file_r)) begin
                $display("ERROR: specify +irom=<file.hex> or +irom_slot0=<file.hex> +irom_slot1=<file.hex>");
                $finish;
            end
        end
        if (!$value$plusargs("dram=%s", dram_file_r)) begin
            $display("ERROR: specify +dram=<file.hex>");
            $finish;
        end
        if (!$value$plusargs("test=%s", test_name_r))
            test_name_r = "unknown";
        if ($value$plusargs("cycles=%d", max_cycles))
            ; // optional override
        if ($test$plusargs("no_cycle_timeout"))
            cycle_timeout_enable = 0;
        if ($value$plusargs("commits=%d", max_commits))
            ; // optional commit-count stop for differential trace
        if ($value$plusargs("stop_pc=%h", stop_pc))
            stop_pc_enable = 1;
        if ($value$plusargs("watchdog=%d", watchdog_cycles))
            ; // optional idle-cycle watchdog
        led_trace_enable = $test$plusargs("led_trace");
        trace_enable = $test$plusargs("trace");
        if (!$value$plusargs("trace_file=%s", trace_file_r))
            trace_file_r = "riscv_trace.log";
        pc_guard_enable = $test$plusargs("pc_guard");
        if ($value$plusargs("pc_min=%h", pc_guard_min))
            ;
        if ($value$plusargs("pc_max=%h", pc_guard_max))
            ;

        if (trace_enable) begin
            trace_fd = $fopen(trace_file_r, "w");
            if (trace_fd == 0) begin
                $display("ERROR: cannot open trace file: %0s", trace_file_r);
                $finish;
            end
            $fdisplay(trace_fd, "# cycle event pc inst rd data extra");
        end

        // ---- Initialize memories ----
        for (integer i = 0; i < 4096; i = i + 1) begin
            irom[i] = 32'h0000_0013;  // addi x0, x0, 0 (NOP)
            irom_slot0[i] = 32'h0000_0013;
            irom_slot1[i] = 32'h0000_0013;
        end
        for (integer i = 0; i < 65536; i = i + 1)
            dram[i] = 32'h0;

        if (irom_banked_enable) begin
            $readmemh(irom_slot0_file_r, irom_slot0);
            $readmemh(irom_slot1_file_r, irom_slot1);
        end else begin
            $readmemh(irom_file_r, irom);
        end
        $readmemh(dram_file_r, dram);

        // ---- Reset sequence ----
        rst_n = 0;
        #100;
        rst_n = 1;

        // ---- Wait for result or timeout ----
        fork
            begin : wait_tohost
                wait (!stop_pc_enable && tohost_detected);
            end
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

        #40;    // wait 2 more cycles for pipeline drain

        // ---- Report result ----
        if (stop_pc_hit) begin
            $display("[DONE] %0s  reached stop_pc=0x%08x commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, stop_pc_seen, commit_cnt, tohost_value,
                     last_tohost_value, led_write_count, u_cpu.pc,
                     last_wb0_pc, last_wb1_pc, cycle_cnt);
        end else if (!stop_pc_enable && tohost_detected) begin
            if (tohost_value == 32'd1) begin
                $display("[PASS] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                         test_name_r, commit_cnt, tohost_value,
                         last_tohost_value, led_write_count, u_cpu.pc,
                         last_wb0_pc, last_wb1_pc, cycle_cnt);
            end else begin
                $display("[FAIL] %0s  test #%0d failed commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                         test_name_r, tohost_value >> 1, commit_cnt,
                         tohost_value, last_tohost_value, led_write_count,
                         u_cpu.pc, last_wb0_pc, last_wb1_pc, cycle_cnt);
            end
        end else if (pc_guard_fired) begin
            $display("[FAIL] %0s  PC_OUT_OF_RANGE pc=0x%08x allowed=[0x%08x,0x%08x) commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, pc_guard_bad_pc, pc_guard_min, pc_guard_max,
                     commit_cnt, tohost_value, last_tohost_value,
                     led_write_count, last_wb0_pc, last_wb1_pc, cycle_cnt);
        end else if (watchdog_fired) begin
            $display("[TIMEOUT] %0s  no pipeline progress for %0d cycles commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, watchdog_cycles, commit_cnt, tohost_value,
                     last_tohost_value, led_write_count, u_cpu.pc,
                     last_wb0_pc, last_wb1_pc, cycle_cnt);
        end else if (commit_limit_hit) begin
            $display("[DONE] %0s  reached %0d commits first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, commit_cnt, tohost_value, last_tohost_value,
                     led_write_count, u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     cycle_cnt);
        end else begin
            $display("[TIMEOUT] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (>%0d cycles)",
                     test_name_r, commit_cnt, tohost_value, last_tohost_value,
                     led_write_count, u_cpu.pc, last_wb0_pc, last_wb1_pc,
                     max_cycles);
        end

        // ---- Performance report (when +perf is specified) ----
        if ($test$plusargs("perf"))
            u_perf.print_report();

        if (trace_fd != 0)
            $fclose(trace_fd);

        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) cycle_cnt <= cycle_cnt + 1;
    end

    // ================================================================
    //  Optional diagnostic guards
    // ================================================================
    wire sim_progress = u_cpu.wb_valid | u_cpu.wb_s1_valid |
                        u_cpu.id_bp_redirect | u_cpu.branch_flush |
                        u_cpu.mem_branch_flush | (|mmio_wea);

    always @(posedge clk) begin
        if (!rst_n) begin
            idle_cycles     <= 0;
            watchdog_fired  <= 0;
            pc_guard_fired  <= 0;
            commit_cnt      <= 0;
            commit_limit_hit <= 0;
            stop_pc_hit     <= 0;
            pc_guard_bad_pc <= 32'd0;
            stop_pc_seen    <= 32'd0;
            last_wb0_pc     <= 32'd0;
            last_wb1_pc     <= 32'd0;
        end else begin
            commit_cnt <= commit_cnt + (u_cpu.wb_valid ? 1 : 0)
                                     + (u_cpu.wb_s1_valid ? 1 : 0);
            if (u_cpu.wb_valid)
                last_wb0_pc <= u_cpu.wb_pc_plus_4 - 32'd4;
            if (u_cpu.wb_s1_valid)
                last_wb1_pc <= u_cpu.wb_s1_pc;
            if (max_commits != 0 && commit_cnt >= max_commits)
                commit_limit_hit <= 1;

            if (stop_pc_enable && !stop_pc_hit) begin
                if (u_cpu.wb_valid && ((u_cpu.wb_pc_plus_4 - 32'd4) == stop_pc)) begin
                    stop_pc_hit  <= 1;
                    stop_pc_seen <= u_cpu.wb_pc_plus_4 - 32'd4;
                end else if (u_cpu.wb_s1_valid && (u_cpu.wb_s1_pc == stop_pc)) begin
                    stop_pc_hit  <= 1;
                    stop_pc_seen <= u_cpu.wb_s1_pc;
                end
            end

            if (sim_progress)
                idle_cycles <= 0;
            else if (watchdog_cycles != 0 && !watchdog_fired)
                idle_cycles <= idle_cycles + 1;

            if (watchdog_cycles != 0 && idle_cycles >= watchdog_cycles)
                watchdog_fired <= 1;

            if (pc_guard_enable && cycle_cnt > 8 && !pc_guard_fired &&
                (u_cpu.pc < pc_guard_min || u_cpu.pc >= pc_guard_max)) begin
                pc_guard_fired  <= 1;
                pc_guard_bad_pc <= u_cpu.pc;
            end
        end
    end

    // ================================================================
    //  Optional compact trace
    // ================================================================
    always @(posedge clk) begin
        if (rst_n && trace_enable && trace_fd != 0) begin
            if (u_cpu.id_bp_redirect)
                $fdisplay(trace_fd, "%0d ID_REDIRECT pc=%08x target=%08x taken=%0d",
                          cycle_cnt, u_cpu.id_pc, u_cpu.id_redirect_target,
                          u_cpu.id_tournament_taken);
            if (u_cpu.branch_flush)
                $fdisplay(trace_fd, "%0d EX_FLUSH pc=%08x target=%08x actual=%0d pred=%0d",
                          cycle_cnt, u_cpu.ex_pc, u_cpu.branch_target,
                          u_cpu.actual_taken, u_cpu.ex_bp_taken);
            if (u_cpu.mem_branch_flush)
                $fdisplay(trace_fd, "%0d MEM_FLUSH target=%08x",
                          cycle_cnt, u_cpu.mem_branch_target);
            if (u_cpu.wb_valid)
                $fdisplay(trace_fd, "%0d WB0 pc=%08x rd=%0d wen=%0d data=%08x",
                          cycle_cnt, u_cpu.wb_pc_plus_4 - 32'd4, u_cpu.wb_rd,
                          u_cpu.wb_reg_write_en, u_cpu.wb_write_data);
            if (u_cpu.wb_s1_valid)
                $fdisplay(trace_fd, "%0d WB1 pc=%08x rd=%0d wen=%0d data=%08x inst=%08x",
                          cycle_cnt, u_cpu.wb_s1_pc, u_cpu.wb_s1_rd,
                          u_cpu.wb_s1_reg_write_en, u_cpu.wb_s1_write_data,
                          u_cpu.wb_s1_inst);
        end
    end

    // ================================================================
    //  Performance Monitor (non-invasive, via hierarchical refs)
    // ================================================================
    perf_monitor u_perf (
        .clk      (clk),
        .rst_n    (rst_n),
        .sim_done (tohost_detected)
    );

    // ================================================================
    //  Optional: waveform dump (for VCD-based tools)
    // ================================================================
    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("riscv_test.vcd");
            $dumpvars(0, tb_riscv_tests);
        end
    end

endmodule
