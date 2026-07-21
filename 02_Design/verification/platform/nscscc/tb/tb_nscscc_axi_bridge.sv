`timescale 1ns/1ps

module tb_nscscc_axi_bridge;
    logic clk;
    logic rst_n;

    logic        irom_req_valid;
    logic        irom_req_ready;
    logic [31:0] irom_req_addr;
    logic        irom_resp_valid;
    logic [63:0] irom_resp_data;

    logic        dmem_req_valid;
    logic        dmem_req_ready;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [ 7:0] dmem_req_len;
    logic [31:0] dmem_req_wdata;
    logic [ 3:0] dmem_req_wstrb;
    logic        dmem_rd_valid;
    logic        dmem_rd_ready;
    logic [31:0] dmem_rd_data;
    logic        dmem_rd_last;
    logic [ 1:0] dmem_rd_resp;
    logic        dmem_wr_valid;
    logic        dmem_wr_ready;
    logic [ 1:0] dmem_wr_resp;

    logic [ 3:0] arid;
    logic [31:0] araddr;
    logic [ 7:0] arlen;
    logic [ 2:0] arsize;
    logic [ 1:0] arburst;
    logic [ 1:0] arlock;
    logic [ 3:0] arcache;
    logic [ 2:0] arprot;
    logic        arvalid;
    logic        arready;
    logic [ 3:0] rid;
    logic [31:0] rdata;
    logic [ 1:0] rresp;
    logic        rlast;
    logic        rvalid;
    logic        rready;

    logic [ 3:0] awid;
    logic [31:0] awaddr;
    logic [ 7:0] awlen;
    logic [ 2:0] awsize;
    logic [ 1:0] awburst;
    logic [ 1:0] awlock;
    logic [ 3:0] awcache;
    logic [ 2:0] awprot;
    logic        awvalid;
    logic        awready;
    logic [ 3:0] wid;
    logic [31:0] wdata;
    logic [ 3:0] wstrb;
    logic        wlast;
    logic        wvalid;
    logic        wready;
    logic [ 3:0] bid;
    logic [ 1:0] bresp;
    logic        bvalid;
    logic        bready;

    integer errors;
    integer dmem_read_beats;

    nscscc_axi_bridge dut (
        .clk(clk),
        .rst_n(rst_n),
        .irom_req_valid(irom_req_valid),
        .irom_req_ready(irom_req_ready),
        .irom_req_addr(irom_req_addr),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_data(irom_resp_data),
        .dmem_req_valid(dmem_req_valid),
        .dmem_req_ready(dmem_req_ready),
        .dmem_req_write(dmem_req_write),
        .dmem_req_addr(dmem_req_addr),
        .dmem_req_len(dmem_req_len),
        .dmem_req_wdata(dmem_req_wdata),
        .dmem_req_wstrb(dmem_req_wstrb),
        .dmem_rd_valid(dmem_rd_valid),
        .dmem_rd_ready(dmem_rd_ready),
        .dmem_rd_data(dmem_rd_data),
        .dmem_rd_last(dmem_rd_last),
        .dmem_rd_resp(dmem_rd_resp),
        .dmem_rd_cancel(1'b0),
        .dmem_wr_valid(dmem_wr_valid),
        .dmem_wr_ready(dmem_wr_ready),
        .dmem_wr_resp(dmem_wr_resp),
        .arid(arid),
        .araddr(araddr),
        .arlen(arlen),
        .arsize(arsize),
        .arburst(arburst),
        .arlock(arlock),
        .arcache(arcache),
        .arprot(arprot),
        .arvalid(arvalid),
        .arready(arready),
        .rid(rid),
        .rdata(rdata),
        .rresp(rresp),
        .rlast(rlast),
        .rvalid(rvalid),
        .rready(rready),
        .awid(awid),
        .awaddr(awaddr),
        .awlen(awlen),
        .awsize(awsize),
        .awburst(awburst),
        .awlock(awlock),
        .awcache(awcache),
        .awprot(awprot),
        .awvalid(awvalid),
        .awready(awready),
        .wid(wid),
        .wdata(wdata),
        .wstrb(wstrb),
        .wlast(wlast),
        .wvalid(wvalid),
        .wready(wready),
        .bid(bid),
        .bresp(bresp),
        .bvalid(bvalid),
        .bready(bready)
    );

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                errors = errors + 1;
                $display("[FAIL] %s at %0t", message, $time);
            end
        end
    endtask

    task automatic accept_ar(
        input logic [31:0] expected_addr,
        input logic [ 7:0] expected_len
    );
        begin
            while (!arvalid)
                @(posedge clk);
            check(araddr == expected_addr, "ARADDR mismatch");
            check(arlen == expected_len, "ARLEN mismatch");
            check(arsize == 3'd2, "ARSIZE must select 32-bit beats");
            check(arburst == 2'b01, "ARBURST must be INCR");
            check(arlock == 2'b00, "ARLOCK must be normal");
            check(arid == 4'h0, "read ID mismatch");
            @(negedge clk);
            arready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            arready = 1'b0;
        end
    endtask

    task automatic send_r(
        input logic [31:0] data,
        input logic        last
    );
        begin
            @(negedge clk);
            rid = 4'h0;
            rdata = data;
            rresp = 2'b00;
            rlast = last;
            rvalid = 1'b1;
            while (!rready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            rvalid = 1'b0;
            rlast = 1'b0;
        end
    endtask

    task automatic issue_irom(input logic [31:0] addr);
        begin
            @(negedge clk);
            irom_req_addr = addr;
            irom_req_valid = 1'b1;
            do @(posedge clk); while (!irom_req_ready);
            @(negedge clk);
            irom_req_valid = 1'b0;
        end
    endtask

    task automatic issue_dmem(
        input logic        write,
        input logic [31:0] addr,
        input logic [ 7:0] len,
        input logic [31:0] data,
        input logic [ 3:0] strb
    );
        begin
            @(negedge clk);
            dmem_req_write = write;
            dmem_req_addr = addr;
            dmem_req_len = len;
            dmem_req_wdata = data;
            dmem_req_wstrb = strb;
            dmem_req_valid = 1'b1;
            do @(posedge clk); while (!dmem_req_ready);
            @(negedge clk);
            dmem_req_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && dmem_rd_valid && dmem_rd_ready)
            dmem_read_beats <= dmem_read_beats + 1;
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        errors = 0;
        dmem_read_beats = 0;
        irom_req_valid = 1'b0;
        irom_req_addr = 32'd0;
        dmem_req_valid = 1'b0;
        dmem_req_write = 1'b0;
        dmem_req_addr = 32'd0;
        dmem_req_len = 8'd0;
        dmem_req_wdata = 32'd0;
        dmem_req_wstrb = 4'd0;
        dmem_rd_ready = 1'b1;
        dmem_wr_ready = 1'b1;
        arready = 1'b0;
        rid = 4'd0;
        rdata = 32'd0;
        rresp = 2'b00;
        rlast = 1'b0;
        rvalid = 1'b0;
        awready = 1'b0;
        wready = 1'b0;
        bid = 4'h1;
        bresp = 2'b00;
        bvalid = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // IROM uses two 32-bit beats and aligns the request to eight bytes.
        $display("[INFO] IROM two-beat read");
        fork
            issue_irom(32'h1c00_0004);
            begin
                accept_ar(32'h1c00_0000, 8'd1);
                // Hold a DCache miss while IROM owns the AXI transaction.
                @(negedge clk);
                dmem_req_write = 1'b0;
                dmem_req_addr = 32'h1c08_0040;
                dmem_req_len = 8'd3;
                dmem_req_valid = 1'b1;
                check(!dmem_req_ready,
                      "DCache command accepted before IROM burst completed");
                send_r(32'h1122_3344, 1'b0);
                send_r(32'h5566_7788, 1'b1);
            end
        join

        wait (irom_resp_valid);
        check(irom_resp_data == 64'h5566_7788_1122_3344,
              "64-bit IROM response packing mismatch");

        // The held DCache command must run next and preserve response
        // backpressure all the way to AXI RREADY.
        $display("[INFO] held DCache refill and R backpressure");
        while (!dmem_req_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        dmem_req_valid = 1'b0;
        accept_ar(32'h1c08_0040, 8'd3);

        dmem_rd_ready = 1'b0;
        @(negedge clk);
        rid = 4'h0;
        rdata = 32'haaaa_0000;
        rresp = 2'b00;
        rlast = 1'b0;
        rvalid = 1'b1;
        @(posedge clk);
        check(!rready, "AXI RREADY ignored DCache response backpressure");
        check(dmem_rd_valid, "DCache did not see stalled AXI read valid");
        @(negedge clk);
        dmem_rd_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rvalid = 1'b0;
        send_r(32'hbbbb_0001, 1'b0);
        send_r(32'hcccc_0002, 1'b0);
        send_r(32'hdddd_0003, 1'b1);
        repeat (2) @(posedge clk);
        check(dmem_read_beats == 4, "DCache refill did not receive four beats");

        // AXI AW and W may handshake independently; B is backpressured by the
        // DCache response consumer.
        $display("[INFO] DCache write and independent AW/W handshakes");
        fork
            issue_dmem(1'b1, 32'h1faf_fff0, 8'd0,
                       32'hdead_beef, 4'b0101);
            begin
                while (!(awvalid && wvalid))
                    @(posedge clk);
                check(awaddr == 32'h1faf_fff0, "AWADDR mismatch");
                check(awlen == 8'd0, "write must be single-beat");
                check(awsize == 3'd2 && awburst == 2'b01,
                      "write AXI shape mismatch");
                check(awid == 4'h1 && wid == 4'h1,
                      "AXI write IDs mismatch");
                check(wdata == 32'hdead_beef && wstrb == 4'b0101 && wlast,
                      "AXI write payload mismatch");
                @(negedge clk);
                awready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                awready = 1'b0;
                check(!awvalid && wvalid,
                      "AW/W independent handshake state was not retained");
                wready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                wready = 1'b0;
            end
        join

        dmem_wr_ready = 1'b0;
        @(negedge clk);
        bid = 4'h1;
        bresp = 2'b00;
        bvalid = 1'b1;
        @(posedge clk);
        check(dmem_wr_valid, "DCache write response was not routed");
        check(!bready, "AXI BREADY ignored DCache response backpressure");
        dmem_wr_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        bvalid = 1'b0;

        // When both clients request an idle backend, data wins.
        $display("[INFO] simultaneous IROM/DCache arbitration");
        repeat (2) @(posedge clk);
        @(negedge clk);
        irom_req_addr = 32'h1c00_0100;
        irom_req_valid = 1'b1;
        dmem_req_write = 1'b0;
        dmem_req_addr = 32'h1fe0_01e0;
        dmem_req_len = 8'd0;
        dmem_req_valid = 1'b1;
        #1;
        check(dmem_req_ready && !irom_req_ready,
              "simultaneous arbitration did not prioritize DCache");
        @(posedge clk);
        @(negedge clk);
        dmem_req_valid = 1'b0;
        accept_ar(32'h1fe0_01e0, 8'd0);
        send_r(32'h0000_005a, 1'b1);
        wait (irom_req_ready);
        @(posedge clk);
        @(negedge clk);
        irom_req_valid = 1'b0;
        accept_ar(32'h1c00_0100, 8'd1);
        send_r(32'h0102_0304, 1'b0);
        send_r(32'h0506_0708, 1'b1);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h0506_0708_0102_0304,
              "post-arbitration IROM response mismatch");

        repeat (3) @(posedge clk);
        if (errors == 0)
            $display("[PASS] NSCSCC IROM/DCache AXI bridge protocol test");
        else
            $display("[FAIL] NSCSCC IROM/DCache AXI bridge errors=%0d", errors);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "[FAIL] NSCSCC AXI bridge test timeout");
    end

endmodule
