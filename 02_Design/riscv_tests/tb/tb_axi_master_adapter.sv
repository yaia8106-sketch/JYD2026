`timescale 1ns / 1ps
// ============================================================
// Testbench: tb_axi_master_adapter
// Description: Standalone protocol smoke test for axi_master_adapter.
// ============================================================

module tb_axi_master_adapter;

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    always #5 clk = ~clk;

    reg         req_valid;
    wire        req_ready;
    reg         req_write;
    reg  [31:0] req_addr;
    reg  [ 7:0] req_len;
    reg  [31:0] req_wdata;
    reg  [ 3:0] req_wstrb;

    wire        rd_valid;
    reg         rd_ready;
    wire [31:0] rd_data;
    wire        rd_last;
    wire [ 1:0] rd_resp;

    wire        wr_valid;
    reg         wr_ready;
    wire [ 1:0] wr_resp;
    wire        busy;

    wire [31:0] m_axi_awaddr;
    wire [ 7:0] m_axi_awlen;
    wire [ 2:0] m_axi_awsize;
    wire [ 1:0] m_axi_awburst;
    wire        m_axi_awlock;
    wire [ 3:0] m_axi_awcache;
    wire [ 2:0] m_axi_awprot;
    wire [ 3:0] m_axi_awqos;
    wire        m_axi_awvalid;
    reg         m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [ 3:0] m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    reg         m_axi_wready;

    reg  [ 1:0] m_axi_bresp;
    reg         m_axi_bvalid;
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
    reg         m_axi_arready;

    reg  [31:0] m_axi_rdata;
    reg  [ 1:0] m_axi_rresp;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;

    integer read_accepts;
    integer write_accepts;

    axi_master_adapter u_dut (
        .clk           (clk),
        .rst_n         (rst_n),

        .req_valid     (req_valid),
        .req_ready     (req_ready),
        .req_write     (req_write),
        .req_addr      (req_addr),
        .req_len       (req_len),
        .req_wdata     (req_wdata),
        .req_wstrb     (req_wstrb),

        .rd_valid      (rd_valid),
        .rd_ready      (rd_ready),
        .rd_data       (rd_data),
        .rd_last       (rd_last),
        .rd_resp       (rd_resp),

        .wr_valid      (wr_valid),
        .wr_ready      (wr_ready),
        .wr_resp       (wr_resp),
        .busy          (busy),

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

    task fail(input [1023:0] msg);
        begin
            $display("[FAIL] %0s", msg);
            $finish;
        end
    endtask

    task check_cond(input cond, input [1023:0] msg);
        begin
            if (!cond)
                fail(msg);
        end
    endtask

    task issue_read(input [31:0] addr, input [7:0] len);
        begin
            @(negedge clk);
            req_write = 1'b0;
            req_addr = addr;
            req_len = len;
            req_wdata = 32'd0;
            req_wstrb = 4'd0;
            req_valid = 1'b1;
            @(posedge clk);
            check_cond(req_ready, "read command was not accepted from IDLE");
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task issue_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
        begin
            @(negedge clk);
            req_write = 1'b1;
            req_addr = addr;
            req_len = 8'd0;
            req_wdata = data;
            req_wstrb = strb;
            req_valid = 1'b1;
            @(posedge clk);
            check_cond(req_ready, "write command was not accepted from IDLE");
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task send_read_beat(input [31:0] data, input last, input consumer_stall);
        begin
            @(negedge clk);
            m_axi_rdata = data;
            m_axi_rresp = 2'b00;
            m_axi_rlast = last;
            m_axi_rvalid = 1'b1;
            rd_ready = ~consumer_stall;
            @(posedge clk);
            check_cond(rd_valid, "read beat was not visible to internal side");
            check_cond(rd_data == data, "read data mismatch");
            if (consumer_stall) begin
                check_cond(!m_axi_rready, "AXI RREADY asserted while internal read side was stalled");
                @(negedge clk);
                rd_ready = 1'b1;
                @(posedge clk);
                check_cond(m_axi_rready, "AXI RREADY did not recover after internal read side resumed");
            end
            @(negedge clk);
            m_axi_rvalid = 1'b0;
            m_axi_rlast = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            read_accepts <= 0;
            write_accepts <= 0;
        end else begin
            if (rd_valid && rd_ready)
                read_accepts <= read_accepts + 1;
            if (wr_valid && wr_ready)
                write_accepts <= write_accepts + 1;
        end
    end

    initial begin
        req_valid = 1'b0;
        req_write = 1'b0;
        req_addr = 32'd0;
        req_len = 8'd0;
        req_wdata = 32'd0;
        req_wstrb = 4'd0;
        rd_ready = 1'b1;
        wr_ready = 1'b1;

        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;
        m_axi_arready = 1'b0;
        m_axi_rdata = 32'd0;
        m_axi_rresp = 2'b00;
        m_axi_rlast = 1'b0;
        m_axi_rvalid = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        check_cond(req_ready, "adapter not ready after reset");
        check_cond(!busy, "adapter busy after reset");

        issue_read(32'h8000_0040, 8'd3);
        @(posedge clk);
        check_cond(m_axi_arvalid, "ARVALID not asserted for read request");
        check_cond(m_axi_araddr == 32'h8000_0040, "ARADDR mismatch");
        check_cond(m_axi_arlen == 8'd3, "ARLEN mismatch");
        check_cond(m_axi_arsize == 3'd2, "ARSIZE mismatch");
        check_cond(m_axi_arburst == 2'b01, "ARBURST is not INCR");

        @(negedge clk);
        m_axi_arready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_axi_arready = 1'b0;

        send_read_beat(32'h1111_0000, 1'b0, 1'b0);
        send_read_beat(32'h2222_0001, 1'b0, 1'b1);
        send_read_beat(32'h3333_0002, 1'b0, 1'b0);
        send_read_beat(32'h4444_0003, 1'b1, 1'b0);
        repeat (2) @(posedge clk);
        check_cond(read_accepts == 4, "read burst did not accept four beats");
        check_cond(req_ready, "adapter did not return to IDLE after read burst");

        issue_write(32'h8000_0100, 32'hdead_beef, 4'b1111);
        @(posedge clk);
        check_cond(m_axi_awvalid, "AWVALID not asserted for write request");
        check_cond(m_axi_wvalid, "WVALID not asserted for write request");
        check_cond(m_axi_awaddr == 32'h8000_0100, "AWADDR mismatch");
        check_cond(m_axi_awlen == 8'd0, "single-beat write AWLEN mismatch");
        check_cond(m_axi_wdata == 32'hdead_beef, "WDATA mismatch");
        check_cond(m_axi_wstrb == 4'b1111, "WSTRB mismatch");
        check_cond(m_axi_wlast, "single-beat write did not assert WLAST");

        @(negedge clk);
        m_axi_awready = 1'b1;
        m_axi_wready = 1'b0;
        @(posedge clk);
        @(negedge clk);
        m_axi_awready = 1'b0;
        check_cond(!m_axi_awvalid, "AWVALID stayed high after AW handshake");
        check_cond(m_axi_wvalid, "WVALID dropped before W handshake");

        m_axi_wready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        m_axi_wready = 1'b0;

        wr_ready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b1;
        @(posedge clk);
        check_cond(wr_valid, "write response was not visible to internal side");
        check_cond(!m_axi_bready, "BREADY asserted while internal write response was stalled");
        @(negedge clk);
        wr_ready = 1'b1;
        @(posedge clk);
        check_cond(m_axi_bready, "BREADY did not assert when internal write response was ready");
        @(negedge clk);
        m_axi_bvalid = 1'b0;
        repeat (2) @(posedge clk);
        check_cond(write_accepts == 1, "write response was not accepted exactly once");
        check_cond(req_ready, "adapter did not return to IDLE after write response");

        @(negedge clk);
        req_write = 1'b1;
        req_addr = 32'h8000_0200;
        req_len = 8'd1;
        req_wdata = 32'h1234_5678;
        req_wstrb = 4'b1111;
        req_valid = 1'b1;
        @(posedge clk);
        check_cond(!req_ready, "unsupported write burst was accepted");
        @(negedge clk);
        req_valid = 1'b0;
        req_write = 1'b0;
        req_len = 8'd0;
        repeat (2) @(posedge clk);

        $display("[PASS] axi_master_adapter protocol smoke test");
        $finish;
    end

endmodule
