`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_riscv_tests
// Description: 自动化 riscv-tests 验证平台
//   - 直接例化 cpu_top，内联 IROM/DRAM 仿真模型
//   - 通过 $readmemh + plusarg 加载测试程序
//   - 监控 tohost (DRAM[0]) 判定 pass/fail
//
// 用法 (Vivado xsim):
//   xelab tb_riscv_tests -prj <prj>
//   xsim tb_riscv_tests -testplusarg "irom=hex/rv32ui-p-add.irom.hex" \
//                       -testplusarg "dram=hex/rv32ui-p-add.dram.hex" \
//                       -testplusarg "test=add"
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
    //  CPU ↔ Memory interfaces
    // ================================================================
    wire [31:0] irom_addr;
    reg  [31:0] irom_data;

    wire [31:0] perip_addr;
    wire [31:0] perip_addr_sum;
    wire [3:0]  perip_wea;
    wire [31:0] perip_wdata;
    wire [31:0] perip_rdata;

    // ================================================================
    //  CPU Core
    // ================================================================
    cpu_top u_cpu (
        .clk            (clk),
        .rst_n          (rst_n),
        .irom_addr      (irom_addr),
        .irom_data      (irom_data),
        .perip_addr     (perip_addr),
        .perip_addr_sum (perip_addr_sum),
        .perip_wea      (perip_wea),
        .perip_wdata    (perip_wdata),
        .perip_rdata    (perip_rdata)
    );

    // ================================================================
    //  IROM Model (1-cycle latency: BRAM primitive register only)
    //  cpu_top 使用 irom_addr = next_pc 预取，补偿 1 cycle 延迟
    //  Address: 0x80000000 ~ 0x80003FFF, 4096 x 32-bit words
    //  Word address = irom_addr[13:2]
    // ================================================================
    reg [31:0] irom [0:4095];

    always @(posedge clk) begin
        irom_data <= irom[irom_addr[13:2]];   // 1-cycle: addr → data
    end

    // ================================================================
    //  DRAM Model (1-cycle latency: no output register)
    //  Address: 0x80100000 ~ 0x8013FFFF, 65536 x 32-bit words
    //  Word address = perip_addr[17:2]
    //  Byte write enable (4-bit WEA)
    // ================================================================
    reg [31:0] dram [0:65535];
    reg [31:0] dram_dout;

    // Address decode (matching perip_bridge.sv)
    wire is_dram = (perip_addr_sum[31:18] == 14'b1000_0000_0001_00);
    wire [15:0] dram_word_addr = perip_addr[17:2];
    wire [3:0]  dram_wea = {4{is_dram}} & perip_wea;

    always @(posedge clk) begin
        if (dram_wea[0]) dram[dram_word_addr][ 7: 0] <= perip_wdata[ 7: 0];
        if (dram_wea[1]) dram[dram_word_addr][15: 8] <= perip_wdata[15: 8];
        if (dram_wea[2]) dram[dram_word_addr][23:16] <= perip_wdata[23:16];
        if (dram_wea[3]) dram[dram_word_addr][31:24] <= perip_wdata[31:24];
        dram_dout <= dram[dram_word_addr];
    end

    // Read data MUX (simplified: for riscv-tests, only DRAM is accessed)
    reg mem_is_dram;
    always @(posedge clk) mem_is_dram <= is_dram;

    assign perip_rdata = dram_dout;

    // ================================================================
    //  tohost Monitoring
    //  tohost symbol is at DRAM offset 0 (address 0x80100000)
    //  Protocol:
    //    tohost == 1           → PASS
    //    tohost == (n<<1)|1    → FAIL at test #n
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
                     dram_word_addr == TOHOST_WORD_ADDR) begin
            tohost_detected <= 1'b1;
            tohost_value    <= perip_wdata;
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
