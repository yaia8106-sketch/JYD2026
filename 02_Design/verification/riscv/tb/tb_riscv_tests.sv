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
    wire [ 3:0] cache_load_mask;
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

    // DCache ↔ memory backend
    wire        dmem_req_valid;
    wire        dmem_req_ready;
    wire        dmem_req_write;
    wire [31:0] dmem_req_addr;
    wire [ 7:0] dmem_req_len;
    wire [31:0] dmem_req_wdata;
    wire [ 3:0] dmem_req_wstrb;
    wire        dmem_rd_valid;
    wire        dmem_rd_ready;
    wire [31:0] dmem_rd_data;
    wire        dmem_rd_last;
    wire [ 1:0] dmem_rd_resp;
    wire        dmem_rd_cancel;
    wire        dmem_wr_valid;
    wire        dmem_wr_ready;
    wire [ 1:0] dmem_wr_resp;

    // Direct DCache BRAM interface ↔ DRAM
    wire        dram_rd_en;
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
        .cache_load_mask(cache_load_mask),
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
    dcache #(
        .BACKEND_CANCEL       (1'b1),
        .DIRECT_BRAM          (1'b1),
        .CRITICAL_WORD_FIRST  (1'b1)
    ) u_dcache (
        .clk         (clk),
        .rst_n       (rst_n),
        .cpu_req     (cache_req),
        .cpu_wr      (cache_wr),
        .cpu_addr    (cache_addr),
        .cpu_wea     (cache_wea),
        .cpu_wdata   (cache_wdata),
        .cpu_load_mask (cache_load_mask),
        .cpu_rdata   (cache_rdata),
        .cpu_ready   (cache_ready),
        .pipeline_stall (cache_pipeline_stall),
        .flush       (cache_flush),      // pipeline flush → abort refill
        .mem_req_valid (dmem_req_valid),
        .mem_req_ready (1'b0),
        .mem_req_write (dmem_req_write),
        .mem_req_addr  (dmem_req_addr),
        .mem_req_len   (dmem_req_len),
        .mem_req_wdata (dmem_req_wdata),
        .mem_req_wstrb (dmem_req_wstrb),
        .mem_rd_valid  (1'b0),
        .mem_rd_ready  (dmem_rd_ready),
        .mem_rd_data   (32'd0),
        .mem_rd_last   (1'b0),
        .mem_rd_resp   (2'b00),
        .mem_rd_cancel (dmem_rd_cancel),
        .mem_wr_valid  (1'b0),
        .mem_wr_ready  (dmem_wr_ready),
        .mem_wr_resp   (2'b00),
        .bram_rd_en    (dram_rd_en),
        .bram_rd_addr  (dram_rd_addr),
        .bram_rd_data  (dram_rdata_w),
        .bram_wr_addr  (dram_wr_addr),
        .bram_wea      (dram_wea),
        .bram_wdata    (dram_wdata)
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
    //  DRAM Model — Simple Dual Port with primitive output register
    //   Write port (Port A): dram_wr_addr + dram_wea + dram_wdata
    //   Read port (Port B):  dram_rd_addr -> dram_rdata (2-cycle sync read)
    //  65536 x 32-bit words = 256KB
    //  NOTE: Must match actual DRAM4MyOwn IP config (primitive output reg).
    // ================================================================
    reg [31:0] dram [0:65535];
    reg [31:0] dram_dout_mem;
    reg [31:0] dram_dout;

    always @(posedge clk) begin
        // Write port (from DCache store buffer drain)
        if (dram_wea[0]) dram[dram_wr_addr][ 7: 0] <= dram_wdata[ 7: 0];
        if (dram_wea[1]) dram[dram_wr_addr][15: 8] <= dram_wdata[15: 8];
        if (dram_wea[2]) dram[dram_wr_addr][23:16] <= dram_wdata[23:16];
        if (dram_wea[3]) dram[dram_wr_addr][31:24] <= dram_wdata[31:24];
        // Read port: memory array followed by the primitive output register.
        if (dram_rd_en) begin
            dram_dout_mem <= dram[dram_rd_addr];
            dram_dout <= dram_dout_mem;
        end
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
    integer cycle_limit_done = 0;
    integer max_commits = 0;
    integer commit_cnt = 0;
    integer watchdog_cycles = 0;
    integer progress_cycles = 0;
    integer idle_cycles = 0;
    integer trace_fd = 0;
    integer trace_enable = 0;
    integer pc_guard_enable = 0;
    integer watchdog_fired = 0;
    integer pc_guard_fired = 0;
    integer commit_limit_hit = 0;
    integer stop_pc_enable = 0;
    integer stop_pc_hit = 0;
    integer miss_buffer_hit_count = 0;
    integer direct_drain_push_pop_count = 0;
    integer direct_drain_read_parallel_count = 0;
    integer direct_drain_collision_block_count = 0;
    integer same_pair_store_data_bypass_count = 0;
    integer refill_early_discarded_spec_reads = 0;
    reg [3:0] miss_buffer_pending_seen = 4'b0000;
    reg [1:0] direct_drain_collision_sel_seen = 2'b00;
    reg [1:0] direct_drain_fire_sel_seen = 2'b00;
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
    wire miss_buffer_directed_test = (test_name_r == "dcache_miss_buffer");
    wire miss_buffer_coverage_failed = miss_buffer_directed_test
                                     & (((miss_buffer_pending_seen & 4'b0111)
                                         != 4'b0111)
                                        | (miss_buffer_hit_count < 4)
                                        | (u_perf.cnt_dc_drain_read_collision < 1)
                                        | (direct_drain_collision_sel_seen != 2'b11)
                                        | (direct_drain_fire_sel_seen != 2'b11)
                                        | (direct_drain_push_pop_count < 1)
                                        | (direct_drain_read_parallel_count < 1)
                                        | (direct_drain_collision_block_count < 1)
                                        | u_dcache.sb_any_valid
                                        | (u_perf.cnt_dc_sb_enqueue
                                           != u_perf.cnt_dc_sb_drain)
                                        | (u_perf.cnt_dc_drain_req_cycles != 0)
                                        | (u_perf.cnt_dc_drain_resp_cycles != 0));
    wire refill_early_directed_test = (test_name_r == "dcache_refill_early");
    wire refill_early_coverage_failed = refill_early_directed_test
                                      & ((u_perf.cnt_dc_primary_refill_starts != 4)
                                         | (u_perf.cnt_dc_primary_refill_completes != 4)
                                         | (u_perf.cnt_dc_primary_refill_aborts != 0)
                                         | (u_perf.cnt_dc_primary_refill_lat1 != 0)
                                         | (u_perf.cnt_dc_primary_refill_lat2 != 4)
                                         | (u_perf.cnt_dc_primary_refill_lat3 != 0)
                                         | (u_perf.cnt_dc_primary_refill_lat4plus != 0)
                                         | (refill_early_discarded_spec_reads < 2));
    wire slot1_store_directed_test = (test_name_r == "slot1_store");
    wire slot1_store_coverage_failed = slot1_store_directed_test
                                     & (same_pair_store_data_bypass_count < 4);

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
        cycle_limit_done = $test$plusargs("cycle_limit_done");
        if ($value$plusargs("commits=%d", max_commits))
            ; // optional commit-count stop for differential trace
        if ($value$plusargs("stop_pc=%h", stop_pc))
            stop_pc_enable = 1;
        if ($value$plusargs("watchdog=%d", watchdog_cycles))
            ; // optional idle-cycle watchdog
        if ($value$plusargs("progress_cycles=%d", progress_cycles))
            ; // optional periodic status print interval
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
                if (miss_buffer_coverage_failed) begin
                    $display("[FAIL] %0s  miss-buffer/direct-drain coverage incomplete hits=%0d pending_seen=%04b collisions=%0d collision_sel=%02b drain_sel=%02b push_pop=%0d read_parallel=%0d collision_block=%0d pending_final=%02b enq=%0d drain=%0d req_cycles=%0d resp_cycles=%0d",
                             test_name_r, miss_buffer_hit_count,
                             miss_buffer_pending_seen,
                             u_perf.cnt_dc_drain_read_collision,
                             direct_drain_collision_sel_seen,
                             direct_drain_fire_sel_seen,
                             direct_drain_push_pop_count,
                             direct_drain_read_parallel_count,
                             direct_drain_collision_block_count,
                             u_dcache.sb_pending_q,
                             u_perf.cnt_dc_sb_enqueue,
                             u_perf.cnt_dc_sb_drain,
                             u_perf.cnt_dc_drain_req_cycles,
                             u_perf.cnt_dc_drain_resp_cycles);
                end else if (refill_early_coverage_failed) begin
                    $display("[FAIL] %0s  early-refill coverage mismatch starts=%0d completes=%0d aborts=%0d lat1=%0d lat2=%0d lat3=%0d lat4plus=%0d discarded_spec=%0d",
                             test_name_r,
                             u_perf.cnt_dc_primary_refill_starts,
                             u_perf.cnt_dc_primary_refill_completes,
                             u_perf.cnt_dc_primary_refill_aborts,
                             u_perf.cnt_dc_primary_refill_lat1,
                             u_perf.cnt_dc_primary_refill_lat2,
                             u_perf.cnt_dc_primary_refill_lat3,
                             u_perf.cnt_dc_primary_refill_lat4plus,
                             refill_early_discarded_spec_reads);
                end else if (slot1_store_coverage_failed) begin
                    $display("[FAIL] %0s  same-pair ALU-to-store-data bypass coverage incomplete hits=%0d expected_at_least=4",
                             test_name_r,
                             same_pair_store_data_bypass_count);
                end else begin
                    $display("[PASS] %0s  commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                             test_name_r, commit_cnt, tohost_value,
                             last_tohost_value, led_write_count, u_cpu.pc,
                             last_wb0_pc, last_wb1_pc, cycle_cnt);
                end
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
        end else if (cycle_limit_done && cycle_timeout_enable && cycle_cnt >= max_cycles) begin
            $display("[SAMPLED] %0s  reached cycle_limit=%0d commits=%0d first_led=0x%08x last_led=0x%08x led_writes=%0d pc=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x  (%0d cycles)",
                     test_name_r, max_cycles, commit_cnt, tohost_value,
                     last_tohost_value, led_write_count, u_cpu.pc,
                     last_wb0_pc, last_wb1_pc, cycle_cnt);
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

    always @(posedge clk) begin
        if (!rst_n)
            same_pair_store_data_bypass_count <= 0;
        else if (u_cpu.ex_valid && u_cpu.ex_s1_valid
                 && u_cpu.ex_s0_alu_store_data_bypass_r
                 && u_cpu.ex_ready_go_w && u_cpu.mem_allowin
                 && !u_cpu.mem_branch_flush)
            same_pair_store_data_bypass_count
                <= same_pair_store_data_bypass_count + 1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            miss_buffer_hit_count <= 0;
            miss_buffer_pending_seen <= 4'b0000;
            direct_drain_push_pop_count <= 0;
            direct_drain_read_parallel_count <= 0;
            direct_drain_collision_block_count <= 0;
            direct_drain_collision_sel_seen <= 2'b00;
            direct_drain_fire_sel_seen <= 2'b00;
            refill_early_discarded_spec_reads <= 0;
        end else begin
            if (u_dcache.miss_buffer_hit) begin
                miss_buffer_hit_count <= miss_buffer_hit_count + 1;
                case (u_dcache.sb_pending_q)
                    2'b00: miss_buffer_pending_seen[0] <= 1'b1;
                    2'b01: miss_buffer_pending_seen[1] <= 1'b1;
                    2'b10: miss_buffer_pending_seen[2] <= 1'b1;
                    2'b11: miss_buffer_pending_seen[3] <= 1'b1;
                    default: ;
                endcase
            end

            if (u_dcache.direct_sb_drain_fire) begin
                direct_drain_fire_sel_seen[u_dcache.sb_drain_sel] <= 1'b1;
                if (u_dcache.sb_store_enqueue)
                    direct_drain_push_pop_count
                        <= direct_drain_push_pop_count + 1;
                if (u_dcache.bram_rd_en)
                    direct_drain_read_parallel_count
                        <= direct_drain_read_parallel_count + 1;
            end

            if (u_dcache.direct_sb_read_collision) begin
                direct_drain_collision_sel_seen[u_dcache.sb_drain_sel] <= 1'b1;
                direct_drain_collision_block_count
                    <= direct_drain_collision_block_count + 1;
                if (u_dcache.direct_sb_drain_fire | u_dcache.sb_pop
                    | (|u_dcache.bram_wea))
                    $error("Direct drain collision did not suppress write/pop");
            end
        end

        if (rst_n && u_dcache.direct_idle_spec_read
                  && !u_dcache.direct_start_issue)
            refill_early_discarded_spec_reads
                <= refill_early_discarded_spec_reads + 1;
    end

    always @(posedge clk) begin
        if (rst_n && progress_cycles > 0 && cycle_cnt > 0 &&
            ((cycle_cnt % progress_cycles) == 0)) begin
            $display("[PROGRESS] %0s  cycle=%0d commits=%0d pc=0x%08x idle=%0d led_writes=%0d first_led=0x%08x last_led=0x%08x last_wb0_pc=0x%08x last_wb1_pc=0x%08x",
                     test_name_r, cycle_cnt, commit_cnt, u_cpu.pc,
                     idle_cycles, led_write_count, tohost_value,
                     last_tohost_value, last_wb0_pc, last_wb1_pc);
        end
    end

    // ================================================================
    //  Optional diagnostic guards
    // ================================================================
    wire sim_progress = u_cpu.wb_valid | u_cpu.wb_s1_valid |
                        u_cpu.branch_flush |
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
            if (u_cpu.branch_flush)
                $fdisplay(trace_fd, "%0d EX_FLUSH pc=%08x target=%08x actual=%0d pred=%0d",
                          cycle_cnt, u_cpu.ex_pc, u_cpu.branch_target,
                          u_cpu.actual_taken, u_cpu.ex_pred_taken);
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
    //  Usage:
    //    ./simv +dump                    → riscv_test.vcd, full hierarchy
    //    ./simv +dump +dump_file=add.vcd → custom filename
    //    ./simv +dump +dump_scope=1      → depth 1 (this module + 1 level down)
    //    ./simv +dump +dump_scope=0      → full (default)
    // ================================================================
    reg [256*8-1:0] dump_file_r;
    integer         dump_scope = 0;
    initial begin
        if ($test$plusargs("dump")) begin
            if ($value$plusargs("dump_file=%s", dump_file_r))
                $dumpfile(dump_file_r);
            else
                $dumpfile("riscv_test.vcd");
            if (!$value$plusargs("dump_scope=%d", dump_scope))
                dump_scope = 0;
            // VCS requires the hierarchy-depth argument to be a compile-time
            // constant.  Keep the runtime option by selecting among explicit
            // constant calls instead of passing the plusarg directly.
            case (dump_scope)
                0: $dumpvars(0, tb_riscv_tests);
                1: $dumpvars(1, tb_riscv_tests);
                2: $dumpvars(2, tb_riscv_tests);
                3: $dumpvars(3, tb_riscv_tests);
                4: $dumpvars(4, tb_riscv_tests);
                default: begin
                    $display("[VCD] Unsupported dump_scope=%0d; using full hierarchy",
                             dump_scope);
                    dump_scope = 0;
                    $dumpvars(0, tb_riscv_tests);
                end
            endcase
            $display("[VCD] Dumping to %0s (scope=%0d)", dump_file_r, dump_scope);
        end
    end

endmodule
