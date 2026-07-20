`timescale 1ns / 1ps

module tb_dram_ip_latency;
    logic        clk = 1'b0;
    logic [ 3:0] wea = 4'd0;
    logic [15:0] wr_addr = 16'd0;
    logic [31:0] wr_data = 32'd0;
    logic        rd_en = 1'b0;
    logic [15:0] rd_addr = 16'd0;
    wire  [31:0] rd_data;

    always #5 clk = ~clk;

    DRAM4MyOwn dut (
        .clka  (clk),
        .wea   (wea),
        .addra (wr_addr),
        .dina  (wr_data),
        .clkb  (clk),
        .enb   (rd_en),
        .addrb (rd_addr),
        .doutb (rd_data)
    );

    task automatic write_word (
        input logic [15:0] addr,
        input logic [31:0] data
    );
        begin
            @(negedge clk);
            wr_addr = addr;
            wr_data = data;
            wea = 4'hf;
            @(posedge clk);
            #1;
            wea = 4'd0;
        end
    endtask

    initial begin
        write_word(16'h0010, 32'h1122_3344);
        write_word(16'h0011, 32'haabb_ccdd);

        @(negedge clk);
        rd_en = 1'b1;
        rd_addr = 16'h0010;
        @(posedge clk);
        #1;
        if (rd_data === 32'h1122_3344) begin
            $error("DRAM unexpectedly returned data after only one clock");
            $fatal(1);
        end

        @(posedge clk);
        #1;
        if (rd_data !== 32'h1122_3344) begin
            $error("DRAM two-cycle response mismatch: response=%08x", rd_data);
            $fatal(1);
        end

        @(negedge clk);
        rd_addr = 16'h0011;
        @(posedge clk);
        #1;
        @(posedge clk);
        #1;
        if (rd_data !== 32'haabb_ccdd) begin
            $error("DRAM consecutive two-cycle read mismatch: response=%08x", rd_data);
            $fatal(1);
        end

        @(negedge clk);
        rd_en = 1'b0;
        rd_addr = 16'h0010;
        @(posedge clk);
        #1;
        if (rd_data !== 32'haabb_ccdd) begin
            $error("DRAM ENB hold behavior mismatch: response=%08x", rd_data);
            $fatal(1);
        end

        $display("[PASS] DRAM4MyOwn IP two-cycle latency and ENB behavior");
        $finish;
    end
endmodule
