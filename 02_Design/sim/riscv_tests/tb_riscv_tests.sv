`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_riscv_tests
// Description: 自动化 riscv-tests 验证平台
//   - 直接例化 cpu_top + dcache，内联 IROM/DRAM 仿真模型
//   - 通过 $readmemh + plusarg 加载测试程序
//   - 监控 tohost (DRAM[0]) 判定 pass/fail
//
// 用法 (iverilog):
//   iverilog -g2012 -o sim tb_riscv_tests.sv <rtl_files>
//   vvp sim +irom=hex/rv32ui-p-add.irom.hex \
//           +dram=hex/rv32ui-p-add.dram.hex +test=add
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
    wire [31:0] irom_addr;
    reg  [31:0] irom_data;

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
        .mmio_rdata     (mmio_rdata)
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
    //  IROM Model (1-cycle latency, same as real BRAM)
    //  Address: 0x80000000 ~ 0x80003FFF, 4096 x 32-bit words
    //  Word address = irom_addr[13:2]
    // ================================================================
    reg [31:0] irom [0:4095];

    always @(posedge clk) begin
        irom_data <= irom[irom_addr[13:2]];
    end

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

    always @(posedge clk) begin
        // MMIO read: map to DRAM
        mmio_rd_reg <= dram[mmio_rd_word_addr];
        // MMIO write: map to DRAM
        if (mmio_wea[0]) dram[mmio_wr_word_addr][ 7: 0] <= mmio_wdata[ 7: 0];
        if (mmio_wea[1]) dram[mmio_wr_word_addr][15: 8] <= mmio_wdata[15: 8];
        if (mmio_wea[2]) dram[mmio_wr_word_addr][23:16] <= mmio_wdata[23:16];
        if (mmio_wea[3]) dram[mmio_wr_word_addr][31:24] <= mmio_wdata[31:24];
    end

    assign mmio_rdata = mmio_rd_reg;

    // ================================================================
    //  tohost Monitoring
    //  tohost symbol is at DRAM offset 0 (address 0x80100000)
    //  Protocol:
    //    tohost == 1           → PASS
    //    tohost == (n<<1)|1    → FAIL at test #n
    //
    //  Detection: watch for DRAM writes to word address 0.
    //  With DCache (WT+WA): stores go through cache → store buffer → DRAM.
    //  So we monitor the DRAM write port from dcache.
    // ================================================================
    localparam TOHOST_WORD_ADDR = 16'd0;

    reg        tohost_detected;
    reg [31:0] tohost_value;

    always @(posedge clk) begin
        if (!rst_n) begin
            tohost_detected <= 1'b0;
            tohost_value    <= 32'd0;
        end else if (!tohost_detected &&
                     |dram_wea &&
                     dram_wr_addr == TOHOST_WORD_ADDR) begin
            tohost_detected <= 1'b1;
            tohost_value    <= dram_wdata;
        end
    end

    // ================================================================
    //  Test Harness
    // ================================================================
    integer cycle_cnt = 0;
    integer max_cycles = 50000;

    // Plusarg strings
    reg [256*8-1:0] irom_file_r;
    reg [256*8-1:0] dram_file_r;
    reg [256*8-1:0] test_name_r;

    initial begin
        // ---- Parse plusargs ----
        if (!$value$plusargs("irom=%s", irom_file_r)) begin
            $display("ERROR: specify +irom=<file.hex>");
            $finish;
        end
        if (!$value$plusargs("dram=%s", dram_file_r)) begin
            $display("ERROR: specify +dram=<file.hex>");
            $finish;
        end
        if (!$value$plusargs("test=%s", test_name_r))
            test_name_r = "unknown";
        if ($value$plusargs("cycles=%d", max_cycles))
            ; // optional override

        // ---- Initialize memories ----
        for (integer i = 0; i < 4096; i = i + 1)
            irom[i] = 32'h0000_0013;  // addi x0, x0, 0 (NOP)
        for (integer i = 0; i < 65536; i = i + 1)
            dram[i] = 32'h0;

        $readmemh(irom_file_r, irom);
        $readmemh(dram_file_r, dram);

        // ---- Reset sequence ----
        rst_n = 0;
        #100;
        rst_n = 1;

        // ---- Wait for result or timeout ----
        fork
            begin : wait_tohost
                wait (tohost_detected);
            end
            begin : wait_timeout
                wait (cycle_cnt >= max_cycles);
            end
        join_any
        disable fork;

        #40;    // wait 2 more cycles for pipeline drain

        // ---- Report result ----
        if (tohost_detected) begin
            if (tohost_value == 32'd1) begin
                $display("[PASS] %0s  (%0d cycles)", test_name_r, cycle_cnt);
            end else begin
                $display("[FAIL] %0s  test #%0d failed  (%0d cycles)",
                         test_name_r, tohost_value >> 1, cycle_cnt);
            end
        end else begin
            $display("[TIMEOUT] %0s  (>%0d cycles)", test_name_r, max_cycles);
        end

        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) cycle_cnt <= cycle_cnt + 1;
    end

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
