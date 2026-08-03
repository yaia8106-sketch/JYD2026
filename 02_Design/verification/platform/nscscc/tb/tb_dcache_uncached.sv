`timescale 1ns/1ps

module tb_dcache_uncached;
    logic clk;
    logic rst_n;
    logic cpu_req;
    logic cpu_wr;
    logic [31:0] cpu_addr;
    logic [ 3:0] cpu_wea;
    logic [31:0] cpu_wdata;
    logic [ 1:0] cpu_load_size;
    logic        cpu_load_unsigned;
    logic cpu_uncached;
    logic [31:0] cpu_rdata;
    logic cpu_ready;
    logic flush;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [31:0] mem_req_addr;
    logic [ 7:0] mem_req_len;
    logic [ 1:0] mem_req_burst;
    logic mem_w_valid;
    logic mem_w_ready;
    logic [31:0] mem_w_data;
    logic [ 3:0] mem_w_strb;
    logic mem_w_last;
    logic mem_rd_valid;
    logic mem_rd_ready;
    logic [31:0] mem_rd_data;
    logic mem_rd_last;
    logic [ 1:0] mem_rd_resp;
    logic mem_wr_valid;
    logic mem_wr_ready;
    logic [ 1:0] mem_wr_resp;
    integer errors;

    wire pipeline_stall = ~cpu_ready;

    dcache dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_req(cpu_req),
        .cpu_wr(cpu_wr),
        .cpu_addr(cpu_addr),
        .cpu_lookup_addr(cpu_addr[10:2]),
        .cpu_wea(cpu_wea),
        .cpu_wdata(cpu_wdata),
        .cpu_load_size(cpu_load_size),
        .cpu_load_unsigned(cpu_load_unsigned),
        .cpu_uncached(cpu_uncached),
        .cpu_rdata(cpu_rdata),
        .cpu_ready(cpu_ready),
        .pipeline_stall(pipeline_stall),
        .flush(flush),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_len(mem_req_len),
        .mem_req_burst(mem_req_burst),
        .mem_w_valid(mem_w_valid),
        .mem_w_ready(mem_w_ready),
        .mem_w_data(mem_w_data),
        .mem_w_strb(mem_w_strb),
        .mem_w_last(mem_w_last),
        .mem_rd_valid(mem_rd_valid),
        .mem_rd_ready(mem_rd_ready),
        .mem_rd_data(mem_rd_data),
        .mem_rd_last(mem_rd_last),
        .mem_rd_resp(mem_rd_resp),
        .mem_rd_cancel(),
        .mem_wr_valid(mem_wr_valid),
        .mem_wr_ready(mem_wr_ready),
        .mem_wr_resp(mem_wr_resp)
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

    task automatic launch_cpu(
        input logic        write,
        input logic        uncached,
        input logic [31:0] addr,
        input logic [ 3:0] wea,
        input logic [31:0] wdata
    );
        begin
            @(negedge clk);
            cpu_wr = write;
            cpu_uncached = uncached;
            cpu_addr = addr;
            cpu_wea = wea;
            cpu_wdata = wdata;
            cpu_req = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cpu_req = 1'b0;
        end
    endtask

    task automatic accept_command;
        begin
            wait (mem_req_valid);
            @(negedge clk);
            mem_req_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mem_req_ready = 1'b0;
        end
    endtask

    task automatic return_read(
        input logic [31:0] data,
        input logic        last,
        input logic [31:0] expected_cpu_data
    );
        begin
            wait (mem_rd_ready);
            @(negedge clk);
            mem_rd_data = data;
            mem_rd_last = last;
            mem_rd_resp = 2'b00;
            mem_rd_valid = 1'b1;
            #1;
            if (cpu_uncached || dut.mem_uncached) begin
                check(cpu_ready, "uncached read response did not release CPU");
                check(cpu_rdata == expected_cpu_data,
                      "uncached formatted read data mismatch");
            end
            @(posedge clk);
            @(negedge clk);
            mem_rd_valid = 1'b0;
            mem_rd_last = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cpu_req = 1'b0;
        cpu_wr = 1'b0;
        cpu_addr = 32'd0;
        cpu_wea = 4'd0;
        cpu_wdata = 32'd0;
        cpu_load_size = 2'b10;
        cpu_load_unsigned = 1'b0;
        cpu_uncached = 1'b0;
        flush = 1'b0;
        mem_req_ready = 1'b0;
        mem_w_ready = 1'b0;
        mem_rd_valid = 1'b0;
        mem_rd_data = 32'd0;
        mem_rd_last = 1'b0;
        mem_rd_resp = 2'b00;
        mem_wr_valid = 1'b0;
        mem_wr_resp = 2'b00;
        errors = 0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // An uncached peripheral read is a single aligned AXI word and must
        // not allocate a DCache line.
        cpu_load_size = 2'b01;
        cpu_load_unsigned = 1'b1;
        launch_cpu(1'b0, 1'b1, 32'h1fe0_01e2, 4'd0, 32'd0);
        wait (mem_req_valid);
        #1;
        check(!mem_req_write, "uncached load emitted a write command");
        check(mem_req_addr == 32'h1fe0_01e0,
              "uncached load address was not word-aligned");
        check(mem_req_len == 8'd0, "uncached load was not single-beat");
        check(mem_req_burst == 2'b01,
              "uncached load did not use an INCR burst");
        accept_command();
        return_read(32'h89ab_cdef, 1'b1, 32'h0000_89ab);
        repeat (2) @(posedge clk);

        // Back-to-back uncached accesses prove that size/sign controls are
        // captured with each request rather than leaking from the previous
        // transaction into the shared special-response formatter.
        cpu_load_size = 2'b00;
        cpu_load_unsigned = 1'b0;
        launch_cpu(1'b0, 1'b1, 32'h1fe0_01e3, 4'd0, 32'd0);
        wait (mem_req_valid);
        check(mem_req_addr == 32'h1fe0_01e0,
              "uncached signed-byte address was not word-aligned");
        accept_command();
        return_read(32'h80ff_7f01, 1'b1, 32'hffff_ff80);
        repeat (2) @(posedge clk);

        cpu_load_size = 2'b00;
        cpu_load_unsigned = 1'b1;
        launch_cpu(1'b0, 1'b1, 32'h1fe0_01e1, 4'd0, 32'd0);
        wait (mem_req_valid);
        check(mem_req_addr == 32'h1fe0_01e0,
              "uncached unsigned-byte address was not word-aligned");
        accept_command();
        return_read(32'h80ff_7f01, 1'b1, 32'h0000_007f);
        repeat (2) @(posedge clk);

        // The same address marked cacheable must still miss and request a
        // four-beat line, proving the previous uncached read did not allocate.
        cpu_load_size = 2'b10;
        cpu_load_unsigned = 1'b0;
        launch_cpu(1'b0, 1'b0, 32'h1fe0_01e0, 4'd0, 32'd0);
        wait (mem_req_valid);
        check(!mem_req_write && mem_req_len == 8'd3,
              "cacheable load did not request a four-beat refill");
        check(mem_req_burst == 2'b10,
              "cacheable refill did not use a WRAP burst");
        accept_command();
        return_read(32'h0000_0001, 1'b0, 32'h0000_0001);
        return_read(32'h0000_0002, 1'b0, 32'h0000_0002);
        return_read(32'h0000_0003, 1'b0, 32'h0000_0003);
        return_read(32'h0000_0004, 1'b1, 32'h0000_0004);
        repeat (3) @(posedge clk);

        // Uncached stores retain byte lanes and do not retire until the AXI
        // write response is accepted.
        launch_cpu(1'b1, 1'b1, 32'h1faf_fff1, 4'b0010, 32'h0000_005a);
        wait (mem_req_valid);
        #1;
        check(mem_req_write, "uncached store emitted a read command");
        check(mem_req_addr == 32'h1faf_fff0,
              "uncached store address was not word-aligned");
        check(mem_req_len == 8'd0, "uncached store was not single-beat");
        check(mem_req_burst == 2'b01,
              "uncached store did not use an INCR burst");
        accept_command();
        wait (mem_w_valid);
        check(mem_w_strb == 4'b0010,
              "uncached store byte strobe mismatch");
        check(mem_w_data == 32'h0000_5a00,
              "uncached store data alignment mismatch");
        check(mem_w_last, "uncached store did not mark its only data beat last");
        @(negedge clk);
        mem_w_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        mem_w_ready = 1'b0;
        wait (mem_wr_ready);
        check(!cpu_ready, "uncached store retired before AXI B response");
        @(negedge clk);
        mem_wr_resp = 2'b00;
        mem_wr_valid = 1'b1;
        #1;
        check(cpu_ready, "uncached store response did not release CPU");
        @(posedge clk);
        @(negedge clk);
        mem_wr_valid = 1'b0;
        repeat (3) @(posedge clk);

        if (errors == 0)
            $display("[PASS] NSCSCC DCache uncached AXI path test");
        else
            $display("[FAIL] NSCSCC DCache uncached path errors=%0d", errors);
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "[FAIL] DCache uncached path timeout");
    end

endmodule
