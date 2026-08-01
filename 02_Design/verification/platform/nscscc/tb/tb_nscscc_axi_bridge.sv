`timescale 1ns/1ps

module tb_nscscc_axi_bridge;
    logic clk;
    logic rst_n;

    logic        irom_req_valid;
    logic        irom_req_ready;
    logic [31:0] irom_req_addr;
    logic        irom_req_kill;
    logic        irom_resp_valid;
    logic [63:0] irom_resp_data;
    logic [ 7:0] irom_resp_predecode;
    logic [ 7:0] expected_irom_predecode;

    logic        dmem_req_valid;
    logic        dmem_req_ready;
    logic        dmem_req_write;
    logic [31:0] dmem_req_addr;
    logic [ 7:0] dmem_req_len;
    logic [ 1:0] dmem_req_burst;
    logic        dmem_w_valid;
    logic        dmem_w_ready;
    logic [31:0] dmem_w_data;
    logic [ 3:0] dmem_w_strb;
    logic        dmem_w_last;
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
        .irom_req_kill(irom_req_kill),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_data(irom_resp_data),
        .irom_resp_predecode(irom_resp_predecode),
        .dmem_req_valid(dmem_req_valid),
        .dmem_req_ready(dmem_req_ready),
        .dmem_req_write(dmem_req_write),
        .dmem_req_addr(dmem_req_addr),
        .dmem_req_len(dmem_req_len),
        .dmem_req_burst(dmem_req_burst),
        .dmem_w_valid(dmem_w_valid),
        .dmem_w_ready(dmem_w_ready),
        .dmem_w_data(dmem_w_data),
        .dmem_w_strb(dmem_w_strb),
        .dmem_w_last(dmem_w_last),
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

    loongarch_icache_block_predecode u_expected_irom_predecode (
        .block_data     (irom_resp_data),
        .block_metadata (expected_irom_predecode)
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

    always @(negedge clk) begin
        if (rst_n && irom_resp_valid)
            check(irom_resp_predecode === expected_irom_predecode,
                  "ICache response predecode did not match response data");
    end

    task automatic accept_ar(
        input logic [31:0] expected_addr,
        input logic [ 7:0] expected_len,
        input logic [ 1:0] expected_burst,
        input logic [ 3:0] expected_id
    );
        begin
            while (!arvalid)
                @(posedge clk);
            check(araddr == expected_addr, "ARADDR mismatch");
            check(arlen == expected_len, "ARLEN mismatch");
            check(arsize == 3'd2, "ARSIZE must select 32-bit beats");
            check(arburst == expected_burst, "ARBURST mismatch");
            check(arlock == 2'b00, "ARLOCK must be normal");
            check(arid == expected_id, "read ID mismatch");
            @(negedge clk);
            arready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            arready = 1'b0;
        end
    endtask

    task automatic send_r(
        input logic [ 3:0] response_id,
        input logic [31:0] data,
        input logic        last
    );
        begin
            @(negedge clk);
            rid = response_id;
            rdata = data;
            rresp = 2'b00;
            rlast = last;
            rvalid = 1'b1;
            do @(posedge clk); while (!rready);
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

    task automatic kill_irom_request;
        begin
            @(negedge clk);
            irom_req_kill = 1'b1;
            @(posedge clk);
            @(negedge clk);
            irom_req_kill = 1'b0;
        end
    endtask

    task automatic issue_dmem(
        input logic        write,
        input logic [31:0] addr,
        input logic [ 7:0] len,
        input logic [ 1:0] burst,
        input logic [31:0] data,
        input logic [ 3:0] strb
    );
        begin
            @(negedge clk);
            dmem_req_write = write;
            dmem_req_addr = addr;
            dmem_req_len = len;
            dmem_req_burst = burst;
            dmem_req_valid = 1'b1;
            do @(posedge clk); while (!dmem_req_ready);
            @(negedge clk);
            dmem_req_valid = 1'b0;
            if (write) begin
                dmem_w_data = data;
                dmem_w_strb = strb;
                dmem_w_last = 1'b1;
                dmem_w_valid = 1'b1;
                do @(posedge clk); while (!dmem_w_ready);
                @(negedge clk);
                dmem_w_valid = 1'b0;
                dmem_w_last = 1'b0;
            end
        end
    endtask

    task automatic issue_dmem_write_burst(
        input logic [31:0] addr,
        input logic [31:0] word0,
        input logic [31:0] word1,
        input logic [31:0] word2,
        input logic [31:0] word3
    );
        logic [31:0] payload;
        begin
            @(negedge clk);
            dmem_req_write = 1'b1;
            dmem_req_addr = addr;
            dmem_req_len = 8'd3;
            dmem_req_burst = 2'b01;
            dmem_req_valid = 1'b1;
            do @(posedge clk); while (!dmem_req_ready);
            @(negedge clk);
            dmem_req_valid = 1'b0;

            for (int beat = 0; beat < 4; beat++) begin
                case (beat)
                    0: payload = word0;
                    1: payload = word1;
                    2: payload = word2;
                    default: payload = word3;
                endcase
                dmem_w_data = payload;
                dmem_w_strb = 4'b1111;
                dmem_w_last = beat == 3;
                dmem_w_valid = 1'b1;
                do @(posedge clk); while (!dmem_w_ready);
                @(negedge clk);
                dmem_w_valid = 1'b0;
            end
            dmem_w_last = 1'b0;
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
        irom_req_kill = 1'b0;
        dmem_req_valid = 1'b0;
        dmem_req_write = 1'b0;
        dmem_req_addr = 32'd0;
        dmem_req_len = 8'd0;
        dmem_req_burst = 2'b01;
        dmem_w_valid = 1'b0;
        dmem_w_data = 32'd0;
        dmem_w_strb = 4'd0;
        dmem_w_last = 1'b0;
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
        bid = 4'h2;
        bresp = 2'b00;
        bvalid = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // One ICache and one DCache read may be outstanding together. Their
        // responses may be interleaved and must be routed by RID.
        $display("[INFO] two outstanding WRAP reads with interleaved RIDs");
        fork
            issue_irom(32'h1c00_0000);
            accept_ar(32'h1c00_0000, 8'd3, 2'b10, 4'h0);
        join

        fork
            issue_dmem(
                1'b0, 32'h1c08_0040, 8'd3, 2'b10, 32'd0, 4'd0
            );
            accept_ar(32'h1c08_0040, 8'd3, 2'b10, 4'h1);
        join

        check(dut.u_memory_backend_arbiter.i_read_active_q
              && dut.u_memory_backend_arbiter.d_read_active_q,
              "I/D reads were not outstanding at the same time");

        // Backpressure only the DCache RID. The ICache read remains active
        // and is still able to consume its own response beats.
        dmem_rd_ready = 1'b0;
        @(negedge clk);
        rid = 4'h1;
        rdata = 32'haaaa_0000;
        rresp = 2'b00;
        rlast = 1'b0;
        rvalid = 1'b1;
        @(posedge clk);
        #1;
        check(!rready, "AXI RREADY ignored DCache response backpressure");
        check(dmem_rd_valid, "DCache did not see stalled AXI read valid");
        check(!dut.imem_rd_valid,
              "DCache RID was incorrectly routed to the ICache");
        @(negedge clk);
        dmem_rd_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rvalid = 1'b0;

        // Interleave the two bursts. The ICache returns its critical 64-bit
        // block after its first two beats, before either complete line has
        // necessarily reached RLAST.
        send_r(4'h0, 32'h1122_3344, 1'b0);
        send_r(4'h1, 32'hbbbb_0001, 1'b0);
        send_r(4'h0, 32'h5566_7788, 1'b0);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h5566_7788_1122_3344,
              "critical ICache response packing mismatch");

        send_r(4'h0, 32'h99aa_bbcc, 1'b0);
        send_r(4'h1, 32'hcccc_0002, 1'b0);
        send_r(4'h1, 32'hdddd_0003, 1'b1);
        check(dut.u_memory_backend_arbiter.i_read_active_q,
              "DCache RLAST incorrectly completed the ICache read");
        send_r(4'h0, 32'hddee_ff00, 1'b1);
        repeat (2) @(posedge clk);
        check(dmem_read_beats == 4, "DCache refill did not receive four beats");

        // A completed line must return from the local RAM without AXI traffic.
        // Keep request valid and replace the first hit lookup with the second
        // block at the exact edge that the first response is consumed.
        $display("[INFO] back-to-back ICache local hits");
        @(negedge clk);
        irom_req_addr = 32'h1c00_0000;
        irom_req_valid = 1'b1;
        check(irom_req_ready, "ICache did not accept the first local hit");
        @(posedge clk);
        @(negedge clk);
        #1;
        check(irom_resp_valid,
              "first ICache hit did not respond after one cycle");
        check(irom_resp_data == 64'h5566_7788_1122_3344,
              "first ICache hit returned incorrect data");
        check(irom_req_ready,
              "ICache could not replace a responding hit lookup");
        check(!arvalid, "first ICache hit unexpectedly issued an AXI read");
        irom_req_addr = 32'h1c00_0008;
        @(posedge clk);
        @(negedge clk);
        #1;
        check(irom_resp_valid,
              "second back-to-back ICache hit inserted a bubble");
        check(irom_resp_data == 64'hddee_ff00_99aa_bbcc,
              "second ICache hit returned incorrect data");
        check(irom_req_ready,
              "second responding ICache hit did not expose a ready slot");
        check(!arvalid, "second ICache hit unexpectedly issued an AXI read");
        irom_req_valid = 1'b0;
        @(posedge clk);
        @(negedge clk);

        // Reads may overlap reads, but writes are deliberately serialized
        // against both read IDs. Hold a DCache write behind an ICache refill,
        // then verify independent AW/W handshakes after the I RLAST.
        $display("[INFO] read/write serialization and independent AW/W");
        fork
            issue_irom(32'h1c00_0080);
            accept_ar(32'h1c00_0080, 8'd3, 2'b10, 4'h0);
        join
        fork
            issue_dmem(1'b1, 32'h1faf_fff0, 8'd0, 2'b01,
                       32'hdead_beef, 4'b0101);
            begin
                wait (dmem_req_valid);
                #1;
                check(!dmem_req_ready && !awvalid,
                      "DCache write overlapped an outstanding ICache read");
                send_r(4'h0, 32'h8182_8384, 1'b0);
                send_r(4'h0, 32'h8586_8788, 1'b0);
                send_r(4'h0, 32'h898a_8b8c, 1'b0);
                send_r(4'h0, 32'h8d8e_8f90, 1'b1);
                while (!(awvalid && wvalid))
                    @(posedge clk);
                check(awaddr == 32'h1faf_fff0, "AWADDR mismatch");
                check(awlen == 8'd0, "write must be single-beat");
                check(awsize == 3'd2 && awburst == 2'b01,
                      "write AXI shape mismatch");
                check(awid == 4'h2 && wid == 4'h2,
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
        bid = 4'h2;
        bresp = 2'b00;
        bvalid = 1'b1;
        @(posedge clk);
        check(dmem_wr_valid, "DCache write response was not routed");
        check(!bready, "AXI BREADY ignored DCache response backpressure");
        dmem_wr_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        bvalid = 1'b0;

        // A dirty cache line uses the same command channel but streams four
        // independently backpressured W beats. Delay AW while accepting W to
        // prove that the two AXI channels retain independent state.
        $display("[INFO] DCache four-beat writeback burst");
        fork
            issue_dmem_write_burst(
                32'h1c08_0400,
                32'h1111_0000, 32'h2222_0001,
                32'h3333_0002, 32'h4444_0003
            );
            begin
                while (!awvalid)
                    @(negedge clk);
                check(awaddr == 32'h1c08_0400,
                      "writeback AWADDR mismatch");
                check(awlen == 8'd3,
                      "writeback AWLEN did not encode four beats");
                check(awburst == 2'b01,
                      "writeback AWBURST must be INCR");
                check(awid == 4'h2 && wid == 4'h2,
                      "writeback AXI IDs mismatch");

                // Accept all W beats before AW. AXI permits this and the
                // adapter must wait for both channel completions before B.
                for (int beat = 0; beat < 4; beat++) begin
                    while (!wvalid)
                        @(negedge clk);
                    case (beat)
                        0: check(wdata == 32'h1111_0000,
                                 "writeback beat 0 mismatch");
                        1: check(wdata == 32'h2222_0001,
                                 "writeback beat 1 mismatch");
                        2: check(wdata == 32'h3333_0002,
                                 "writeback beat 2 mismatch");
                        3: check(wdata == 32'h4444_0003,
                                 "writeback beat 3 mismatch");
                    endcase
                    check(wstrb == 4'b1111,
                          "writeback strobe mismatch");
                    check(wlast == (beat == 3),
                          "writeback WLAST mismatch");
                    @(negedge clk);
                    wready = 1'b1;
                    @(posedge clk);
                    @(negedge clk);
                    wready = 1'b0;
                end

                check(awvalid,
                      "delayed writeback AW was not retained");
                awready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                awready = 1'b0;
            end
        join

        check(!bready || !bvalid,
              "adapter entered B response before AW completed");
        @(negedge clk);
        bid = 4'h2;
        bresp = 2'b00;
        bvalid = 1'b1;
        while (!bready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        bvalid = 1'b0;

        // The ICache lookup is independent of AXI arbitration. Once that
        // lookup misses, a simultaneous backend command still gives DCache
        // priority.
        $display("[INFO] simultaneous ICache/DCache backend arbitration");
        repeat (2) @(posedge clk);
        issue_irom(32'h1c00_0100);
        wait (dut.imem_req_valid);
        @(negedge clk);
        dmem_req_write = 1'b0;
        dmem_req_addr = 32'h1fe0_01e0;
        dmem_req_len = 8'd0;
        dmem_req_burst = 2'b01;
        dmem_req_valid = 1'b1;
        #1;
        check(dmem_req_ready && !dut.imem_req_ready,
              "simultaneous arbitration did not prioritize DCache");
        @(posedge clk);
        @(negedge clk);
        dmem_req_valid = 1'b0;
        accept_ar(32'h1fe0_01e0, 8'd0, 2'b01, 4'h1);
        // The pending ICache command is launched before the DCache read
        // completes, proving that priority does not collapse outstanding=2.
        accept_ar(32'h1c00_0100, 8'd3, 2'b10, 4'h0);
        send_r(4'h1, 32'h0000_005a, 1'b1);
        send_r(4'h0, 32'h0102_0304, 1'b0);
        send_r(4'h0, 32'h0506_0708, 1'b0);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h0506_0708_0102_0304,
              "post-arbitration IROM response mismatch");
        send_r(4'h0, 32'h1112_1314, 1'b0);
        send_r(4'h0, 32'h1516_1718, 1'b1);

        // A miss in the upper half of a line starts one WRAP burst at the
        // critical block and then wraps to the lower half.
        $display("[INFO] ICache upper critical block first");
        issue_irom(32'h1c00_0308);
        accept_ar(32'h1c00_0308, 8'd3, 2'b10, 4'h0);
        send_r(4'h0, 32'h4142_4344, 1'b0);
        send_r(4'h0, 32'h4546_4748, 1'b0);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h4546_4748_4142_4344,
              "upper critical block response mismatch");
        send_r(4'h0, 32'h5152_5354, 1'b0);
        send_r(4'h0, 32'h5556_5758, 1'b1);
        repeat (2) @(posedge clk);
        issue_irom(32'h1c00_0300);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h5556_5758_5152_5354,
              "lower block hit after reverse refill mismatch");

        // Killing an accepted miss must drain the old AXI request without
        // blocking an unrelated local hit. Re-requesting the killed line is
        // retained as one pending miss and starts only after the drain.
        $display("[INFO] redirect kill, hit-under-drain, and pending miss");
        issue_irom(32'h1c00_0200);
        accept_ar(32'h1c00_0200, 8'd3, 2'b10, 4'h0);
        kill_irom_request();

        issue_irom(32'h1c00_0000);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h5566_7788_1122_3344,
              "cached hit was blocked or corrupted by stale AXI drain");

        issue_irom(32'h1c00_0200);
        repeat (2) begin
            @(posedge clk);
            check(!irom_resp_valid,
                  "killed refill produced a stale frontend response");
        end

        send_r(4'h0, 32'hdead_0001, 1'b0);
        send_r(4'h0, 32'hdead_0002, 1'b0);
        send_r(4'h0, 32'hdead_0003, 1'b0);
        send_r(4'h0, 32'hdead_0004, 1'b1);
        accept_ar(32'h1c00_0200, 8'd3, 2'b10, 4'h0);
        send_r(4'h0, 32'h2122_2324, 1'b0);
        send_r(4'h0, 32'h2526_2728, 1'b0);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h2526_2728_2122_2324,
              "pending miss reused data from the killed refill");
        send_r(4'h0, 32'h3132_3334, 1'b0);
        send_r(4'h0, 32'h3536_3738, 1'b1);

        // A redirect may coincide with an accepted middle R beat. The killed
        // refill must drain by the AXI RLAST itself; its stale local beat
        // position must not leave the ICache waiting for a fifth beat.
        $display("[INFO] redirect kill coincident with a middle refill beat");
        issue_irom(32'h1c00_0400);
        accept_ar(32'h1c00_0400, 8'd3, 2'b10, 4'h0);
        send_r(4'h0, 32'hdead_1001, 1'b0);
        fork
            send_r(4'h0, 32'hdead_1002, 1'b0);
            kill_irom_request();
        join
        send_r(4'h0, 32'hdead_1003, 1'b0);
        send_r(4'h0, 32'hdead_1004, 1'b1);

        issue_irom(32'h1c00_0400);
        accept_ar(32'h1c00_0400, 8'd3, 2'b10, 4'h0);
        send_r(4'h0, 32'h6162_6364, 1'b0);
        send_r(4'h0, 32'h6566_6768, 1'b0);
        wait (irom_resp_valid);
        check(irom_resp_data == 64'h6566_6768_6162_6364,
              "post-kill refill did not return the critical block");
        send_r(4'h0, 32'h7172_7374, 1'b0);
        send_r(4'h0, 32'h7576_7778, 1'b1);

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
