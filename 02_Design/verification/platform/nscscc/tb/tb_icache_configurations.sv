`timescale 1ns / 1ps

module tb_icache_configurations;
`ifdef TEST_ICACHE_BYTES
    localparam integer CACHE_BYTES = `TEST_ICACHE_BYTES;
`else
    localparam integer CACHE_BYTES = 16384;
`endif
`ifdef TEST_ICACHE_WAYS
    localparam integer WAYS = `TEST_ICACHE_WAYS;
`else
    localparam integer WAYS = 1;
`endif
    localparam integer WAY_SPAN_BYTES = CACHE_BYTES / WAYS;

    logic clk;
    logic rst_n;
    logic irom_req_valid;
    logic irom_req_ready;
    logic [31:0] irom_req_addr;
    logic irom_req_kill;
    logic irom_resp_valid;
    logic [63:0] irom_resp_data;
    logic [13:0] irom_resp_predecode;
    logic [1:0] irom_resp_resp;
    logic mem_req_valid;
    logic mem_req_ready;
    logic [31:0] mem_req_addr;
    logic [7:0] mem_req_len;
    logic [1:0] mem_req_burst;
    logic mem_rd_valid;
    logic mem_rd_ready;
    logic [31:0] mem_rd_data;
    logic mem_rd_last;
    logic [1:0] mem_rd_resp;

    integer errors;
    logic expect_fast_refill_request;

    icache #(
        .CACHE_BYTES(CACHE_BYTES),
        .WAYS(WAYS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .irom_req_valid(irom_req_valid),
        .irom_req_ready(irom_req_ready),
        .irom_req_addr(irom_req_addr),
        .irom_req_kill(irom_req_kill),
        .irom_resp_valid(irom_resp_valid),
        .irom_resp_data(irom_resp_data),
        .irom_resp_predecode(irom_resp_predecode),
        .irom_resp_resp(irom_resp_resp),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr),
        .mem_req_len(mem_req_len),
        .mem_req_burst(mem_req_burst),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_data(mem_rd_data),
        .mem_rd_last(mem_rd_last),
        .mem_rd_resp(mem_rd_resp)
    );

    always #5 clk = ~clk;

    // An idle-cache lookup miss must expose its refill request in the very
    // next cycle.  This guards against accidentally restoring the old
    // lookup_miss -> pending_miss -> REFILL_REQ bubble.
    always @(posedge clk) begin
        if (!rst_n) begin
            expect_fast_refill_request <= 1'b0;
        end else begin
            if (expect_fast_refill_request)
                check(mem_req_valid,
                      "idle lookup miss did not start refill next cycle");
            expect_fast_refill_request <=
                !irom_req_kill
                && (dut.refill_state_q == 2'd0)
                && !dut.pending_miss_valid_q
                && dut.lookup_miss;
        end
    end

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) begin
            errors = errors + 1;
            $display("[FAIL] %s at %0t", message, $time);
        end
    endtask

    task automatic issue_request(input logic [31:0] addr);
        integer guard;
        begin
            @(negedge clk);
            irom_req_addr = addr;
            irom_req_valid = 1'b1;
            guard = 0;
            do begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 40)
                    $fatal(1, "request timeout addr=%08x", addr);
            end while (!irom_req_ready);
            @(negedge clk);
            irom_req_valid = 1'b0;
        end
    endtask

    task automatic accept_refill(input logic [31:0] addr);
        integer guard;
        begin
            guard = 0;
            while (!mem_req_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 40)
                    $fatal(1, "refill timeout addr=%08x", addr);
            end
            #1;
            check(mem_req_addr == addr, "critical refill address mismatch");
            check(mem_req_len == 8'd3, "refill length mismatch");
            check(mem_req_burst == 2'b10, "refill was not WRAP");
            mem_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_req_ready = 1'b0;
        end
    endtask

    task automatic send_beat(
        input logic [31:0] data,
        input logic last
    );
        begin
            @(negedge clk);
            mem_rd_data = data;
            mem_rd_last = last;
            mem_rd_valid = 1'b1;
            do @(posedge clk); while (!mem_rd_ready);
            @(negedge clk);
            mem_rd_valid = 1'b0;
            mem_rd_last = 1'b0;
        end
    endtask

    task automatic expect_data(
        input logic [63:0] expected,
        input string name
    );
        integer guard;
        begin
            guard = 0;
            while (!irom_resp_valid) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 20)
                    $fatal(1, "response timeout: %s", name);
            end
            #1;
            check(irom_resp_data === expected,
                  $sformatf("%s data mismatch", name));
            check(irom_resp_resp == 2'b00,
                  $sformatf("%s response code", name));
        end
    endtask

    task automatic fill_line(
        input logic [31:0] addr,
        input logic [31:0] word_base,
        input string name
    );
        begin
            fork
                issue_request(addr);
                accept_refill(addr);
            join
            send_beat(word_base + 0, 1'b0);
            send_beat(word_base + 1, 1'b0);
            expect_data({word_base + 1, word_base + 0},
                        $sformatf("%s critical", name));
            send_beat(word_base + 2, 1'b0);
            send_beat(word_base + 3, 1'b1);
            // Delayed tag publication occurs on the following edge.
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic expect_hit(
        input logic [31:0] addr,
        input logic [31:0] word_base,
        input string name
    );
        begin
            issue_request(addr);
            #1;
            check(irom_resp_valid,
                  $sformatf("%s was not a one-cycle hit", name));
            check(!mem_req_valid,
                  $sformatf("%s unexpectedly requested refill", name));
            if (irom_resp_valid)
                expect_data({word_base + 1, word_base + 0}, name);
        end
    endtask

    task automatic exercise_arriving_block_bypass;
        logic [31:0] addr;
        logic [31:0] word_base;
        begin
            addr = 32'h1c00_3a00;
            word_base = 32'h5000_0000;
            fork
                issue_request(addr);
                accept_refill(addr);
            join
            send_beat(word_base + 0, 1'b0);
            send_beat(word_base + 1, 1'b0);
            expect_data({word_base + 1, word_base + 0},
                        "arrival-bypass critical response");
            send_beat(word_base + 2, 1'b0);
            // The upper-block lookup is accepted on the same edge as its
            // final word. It must consume the arriving refill block instead
            // of launching a duplicate refill into another way.
            fork
                issue_request(addr + 8);
                send_beat(word_base + 3, 1'b1);
            join
            expect_data({word_base + 3, word_base + 2},
                        "arrival-bypass upper response");
            repeat (2) @(posedge clk);
            expect_hit(addr + 8, word_base + 2,
                       "arrival-bypass committed hit");
        end
    endtask

    initial begin
        logic [31:0] addr_a;
        logic [31:0] addr_b;
        logic [31:0] addr_c;

        clk = 1'b0;
        rst_n = 1'b0;
        irom_req_valid = 1'b0;
        irom_req_addr = 32'h1c00_0000;
        irom_req_kill = 1'b0;
        mem_req_ready = 1'b0;
        mem_rd_valid = 1'b0;
        mem_rd_data = 32'd0;
        mem_rd_last = 1'b0;
        mem_rd_resp = 2'b00;
        errors = 0;

        addr_a = 32'h1c00_1000;
        addr_b = addr_a + WAY_SPAN_BYTES;
        addr_c = addr_b + WAY_SPAN_BYTES;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        exercise_arriving_block_bypass();

        fill_line(addr_a, 32'h1000_0000, "line A");
        expect_hit(addr_a, 32'h1000_0000, "line A initial hit");
        fill_line(addr_b, 32'h2000_0000, "line B");
        expect_hit(addr_b, 32'h2000_0000, "line B hit");

        if (WAYS == 1) begin
            // Same-set B must evict A in a direct-mapped cache.
            fill_line(addr_a, 32'h3000_0000, "line A direct-map reload");
            expect_hit(addr_a, 32'h3000_0000, "line A reloaded hit");
        end else begin
            // A and B coexist. Touch A so B becomes LRU, then allocate C.
            expect_hit(addr_a, 32'h1000_0000, "line A second-way hit");
            fill_line(addr_c, 32'h3000_0000, "line C replacement");
            expect_hit(addr_a, 32'h1000_0000, "MRU line A survived");
            fill_line(addr_b, 32'h4000_0000, "LRU line B reload");
            expect_hit(addr_b, 32'h4000_0000, "line B reloaded hit");
        end

        if (errors == 0)
            $display("[PASS] ICache config bytes=%0d ways=%0d", CACHE_BYTES,
                     WAYS);
        else
            $fatal(1, "[FAIL] ICache config errors=%0d", errors);
        $finish;
    end

endmodule
