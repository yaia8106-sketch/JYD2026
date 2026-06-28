`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_student_top_axi
// Description:
//   student_top_axi integration smoke test. It verifies that cacheable DCache
//   misses/stores reach AXI memory while local MMIO stays off AXI.
// ============================================================

module tb_student_top_axi;

    reg clk = 1'b0;
    reg cnt_clk = 1'b0;
    reg rst = 1'b1;

    always #5  clk = ~clk;
    always #10 cnt_clk = ~cnt_clk;

    reg  [ 7:0] virtual_key;
    reg  [63:0] virtual_sw;
    wire [31:0] virtual_led;
    wire [39:0] virtual_seg;

    wire [31:0] m_axi_awaddr;
    wire [ 7:0] m_axi_awlen;
    wire [ 2:0] m_axi_awsize;
    wire [ 1:0] m_axi_awburst;
    wire        m_axi_awlock;
    wire [ 3:0] m_axi_awcache;
    wire [ 2:0] m_axi_awprot;
    wire [ 3:0] m_axi_awqos;
    wire        m_axi_awvalid;
    wire        m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [ 3:0] m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    wire        m_axi_wready;

    wire [ 1:0] m_axi_bresp;
    wire        m_axi_bvalid;
    wire        m_axi_bready;

    wire [31:0] m_axi_araddr;
    wire [ 7:0] m_axi_arlen;
    wire [ 2:0] m_axi_arsize;
    wire [ 1:0] m_axi_arburst;
    wire        m_axi_arlock;
    wire [ 3:0] m_axi_arcache;
    wire [ 2:0] m_axi_arprot;
    wire [ 3:0] m_axi_arqos;
    wire        m_axi_arvalid;
    wire        m_axi_arready;

    wire [31:0] m_axi_rdata;
    wire [ 1:0] m_axi_rresp;
    wire        m_axi_rlast;
    wire        m_axi_rvalid;
    wire        m_axi_rready;

    wire [31:0] axi_read_bursts;
    wire [31:0] axi_write_beats;
    wire        axi_protocol_error;

    integer cycle_cnt;
    integer max_cycles;
    integer led_seen;
    integer mmio_axi_error;
    integer axi_shape_error;
    integer require_axi;
    reg [1023:0] test_name;

    student_top_axi dut (
        .w_cpu_clk     (clk),
        .w_clk_50Mhz   (cnt_clk),
        .w_clk_rst     (rst),
        .virtual_key   (virtual_key),
        .virtual_sw    (virtual_sw),
        .virtual_led   (virtual_led),
        .virtual_seg   (virtual_seg),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );

    axi_ram_model u_axi_ram (
        .clk              (clk),
        .rst_n            (~rst),
        .s_axi_awaddr     (m_axi_awaddr),
        .s_axi_awlen      (m_axi_awlen),
        .s_axi_awsize     (m_axi_awsize),
        .s_axi_awburst    (m_axi_awburst),
        .s_axi_awlock     (m_axi_awlock),
        .s_axi_awcache    (m_axi_awcache),
        .s_axi_awprot     (m_axi_awprot),
        .s_axi_awqos      (m_axi_awqos),
        .s_axi_awvalid    (m_axi_awvalid),
        .s_axi_awready    (m_axi_awready),
        .s_axi_wdata      (m_axi_wdata),
        .s_axi_wstrb      (m_axi_wstrb),
        .s_axi_wlast      (m_axi_wlast),
        .s_axi_wvalid     (m_axi_wvalid),
        .s_axi_wready     (m_axi_wready),
        .s_axi_bresp      (m_axi_bresp),
        .s_axi_bvalid     (m_axi_bvalid),
        .s_axi_bready     (m_axi_bready),
        .s_axi_araddr     (m_axi_araddr),
        .s_axi_arlen      (m_axi_arlen),
        .s_axi_arsize     (m_axi_arsize),
        .s_axi_arburst    (m_axi_arburst),
        .s_axi_arlock     (m_axi_arlock),
        .s_axi_arcache    (m_axi_arcache),
        .s_axi_arprot     (m_axi_arprot),
        .s_axi_arqos      (m_axi_arqos),
        .s_axi_arvalid    (m_axi_arvalid),
        .s_axi_arready    (m_axi_arready),
        .s_axi_rdata      (m_axi_rdata),
        .s_axi_rresp      (m_axi_rresp),
        .s_axi_rlast      (m_axi_rlast),
        .s_axi_rvalid     (m_axi_rvalid),
        .s_axi_rready     (m_axi_rready),
        .read_burst_count (axi_read_bursts),
        .write_beat_count (axi_write_beats),
        .protocol_error   (axi_protocol_error)
    );

    wire axi_aw_fire = m_axi_awvalid & m_axi_awready;
    wire axi_ar_fire = m_axi_arvalid & m_axi_arready;
    wire axi_mmio_aw = axi_aw_fire & (m_axi_awaddr[31:12] == 20'h80200);
    wire axi_mmio_ar = axi_ar_fire & (m_axi_araddr[31:12] == 20'h80200);

    initial begin
        max_cycles = 50000;
        if ($value$plusargs("cycles=%d", max_cycles))
            ;
        if (!$value$plusargs("test=%s", test_name))
            test_name = "student_top_axi";

        require_axi = !$test$plusargs("allow_no_axi");
        virtual_key = 8'd0;
        virtual_sw = 64'h0000_0000_1234_5678;
        cycle_cnt = 0;
        led_seen = 0;
        mmio_axi_error = 0;
        axi_shape_error = 0;

        repeat (8) @(posedge clk);
        rst = 1'b0;

        wait (led_seen || mmio_axi_error || axi_shape_error ||
              axi_protocol_error || cycle_cnt >= max_cycles);

        if (mmio_axi_error) begin
            $display("[FAIL] %0s  local MMIO access reached AXI ar=0x%08x aw=0x%08x",
                     test_name, m_axi_araddr, m_axi_awaddr);
        end else if (axi_shape_error) begin
            $display("[FAIL] %0s  unexpected AXI shape arlen=%0d arsize=%0d arburst=%0d awlen=%0d",
                     test_name, m_axi_arlen, m_axi_arsize, m_axi_arburst, m_axi_awlen);
        end else if (axi_protocol_error) begin
            $display("[FAIL] %0s  AXI RAM model protocol error", test_name);
        end else if (virtual_led == 32'h0000_0001) begin
            // A recent-store hit may legitimately eliminate every AXI read in
            // a store-heavy test. Require observable AXI traffic, while the
            // dedicated backend tests still exercise both channels.
            if (require_axi && (axi_read_bursts == 32'd0 && axi_write_beats == 32'd0)) begin
                $display("[FAIL] %0s  PASS without required AXI traffic reads=%0d writes=%0d cycles=%0d",
                         test_name, axi_read_bursts, axi_write_beats, cycle_cnt);
            end else begin
                $display("[PASS] %0s  led=0x%08x axi_reads=%0d axi_writes=%0d cycles=%0d",
                         test_name, virtual_led, axi_read_bursts, axi_write_beats, cycle_cnt);
            end
        end else if (led_seen) begin
            $display("[FAIL] %0s  led=0x%08x axi_reads=%0d axi_writes=%0d cycles=%0d",
                     test_name, virtual_led, axi_read_bursts, axi_write_beats, cycle_cnt);
        end else begin
            $display("[TIMEOUT] %0s  led=0x%08x axi_reads=%0d axi_writes=%0d cycles=%0d",
                     test_name, virtual_led, axi_read_bursts, axi_write_beats, cycle_cnt);
        end

        $finish;
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_cnt <= 0;
            led_seen <= 0;
            mmio_axi_error <= 0;
            axi_shape_error <= 0;
        end else begin
            cycle_cnt <= cycle_cnt + 1;

            if (virtual_led != 32'd0)
                led_seen <= 1;

            if (axi_mmio_aw || axi_mmio_ar)
                mmio_axi_error <= 1;

            if (axi_ar_fire && (m_axi_arlen != 8'd3 || m_axi_arsize != 3'd2 ||
                                m_axi_arburst != 2'b01))
                axi_shape_error <= 1;
            if (axi_aw_fire && (m_axi_awlen != 8'd0 || m_axi_awsize != 3'd2 ||
                                m_axi_awburst != 2'b01))
                axi_shape_error <= 1;
        end
    end

    // ---- VCD dump (opt-in with +dump) ----
    reg [256*8-1:0] dump_file_r;
    initial begin
        if ($test$plusargs("dump")) begin
            if ($value$plusargs("dump_file=%s", dump_file_r))
                $dumpfile(dump_file_r);
            else
                $dumpfile("student_top_axi.vcd");
            $dumpvars(0, tb_student_top_axi);
            $display("[VCD] Dumping to %0s", dump_file_r);
        end
    end

endmodule
