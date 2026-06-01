`timescale 1ns / 1ps
// ============================================================
// Lightweight behavioral IP models for student_top COE simulation.
// These models match the ports and latency assumptions used by student_top:
// - IROMEven32/IROMOdd32: 4096x32 synchronous ROM, 1-cycle read.
// - DRAM4MyOwn: 65536x32 SDP RAM with byte writes and 2-cycle read latency.
// ============================================================

module IROMEven32 (
    input  wire        clka,
    input  wire [11:0] addra,
    output reg  [31:0] douta
);
    reg [31:0] mem [0:4095];
    reg [1023:0] file_name;
    integer i;

    initial begin
        for (i = 0; i < 4096; i = i + 1)
            mem[i] = 32'h0000_0013;

        if (!$value$plusargs("irom_slot0=%s", file_name) &&
            !$value$plusargs("irom_even=%s", file_name)) begin
            $display("ERROR: specify +irom_slot0=<hex> for IROMEven32");
            $finish;
        end
        $readmemh(file_name, mem);
    end

    always @(posedge clka) begin
        douta <= mem[addra];
    end
endmodule

module IROMOdd32 (
    input  wire        clka,
    input  wire [11:0] addra,
    output reg  [31:0] douta
);
    reg [31:0] mem [0:4095];
    reg [1023:0] file_name;
    integer i;

    initial begin
        for (i = 0; i < 4096; i = i + 1)
            mem[i] = 32'h0000_0013;

        if (!$value$plusargs("irom_slot1=%s", file_name) &&
            !$value$plusargs("irom_odd=%s", file_name)) begin
            $display("ERROR: specify +irom_slot1=<hex> for IROMOdd32");
            $finish;
        end
        $readmemh(file_name, mem);
    end

    always @(posedge clka) begin
        douta <= mem[addra];
    end
endmodule

module DRAM4MyOwn (
    input  wire        clka,
    input  wire [ 3:0] wea,
    input  wire [15:0] addra,
    input  wire [31:0] dina,
    input  wire        clkb,
    input  wire        enb,
    input  wire [15:0] addrb,
    output reg  [31:0] doutb
);
    reg [31:0] mem [0:65535];
    reg [31:0] dout_raw;
    reg [1023:0] file_name;
    integer i;

    initial begin
        for (i = 0; i < 65536; i = i + 1)
            mem[i] = 32'd0;

        if (!$value$plusargs("dram=%s", file_name)) begin
            $display("ERROR: specify +dram=<hex> for DRAM4MyOwn");
            $finish;
        end
        $readmemh(file_name, mem);
        dout_raw = 32'd0;
        doutb = 32'd0;
    end

    always @(posedge clka) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    always @(posedge clkb) begin
        if (enb) begin
            dout_raw <= mem[addrb];
            doutb    <= dout_raw;
        end
    end
endmodule
