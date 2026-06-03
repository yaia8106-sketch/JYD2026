`timescale 1ns / 1ps
// ============================================================
// Lightweight behavioral IP models for student_top COE simulation.
// These models match the ports and latency assumptions used by student_top:
// - IROM64: 2048x64 synchronous ROM, 1-cycle read.
// - IROMEven32/IROMOdd32: legacy 4096x32 synchronous ROMs.
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

module IROM64 (
    input  wire        clka,
    input  wire [11:0] addra,
    output reg  [63:0] douta
);
    reg [31:0] flat_words [0:4095];
    reg [31:0] slot0_words [0:4095];
    reg [31:0] slot1_words [0:4095];
    reg [1023:0] flat_file;
    reg [1023:0] slot0_file;
    reg [1023:0] slot1_file;
    integer i;
    integer banked_enable;
    wire [12:0] flat_word0_addr = {addra, 1'b0};
    wire [12:0] flat_word1_addr = {addra, 1'b1};

    initial begin
        for (i = 0; i < 4096; i = i + 1) begin
            flat_words[i] = 32'h0000_0013;
            slot0_words[i] = 32'h0000_0013;
            slot1_words[i] = 32'h0000_0013;
        end

        banked_enable = 0;
        if ($value$plusargs("irom_slot0=%s", slot0_file)) begin
            if (!$value$plusargs("irom_slot1=%s", slot1_file)) begin
                $display("ERROR: specify both +irom_slot0=<hex> and +irom_slot1=<hex> for IROM64");
                $finish;
            end
            banked_enable = 1;
            $readmemh(slot0_file, slot0_words);
            $readmemh(slot1_file, slot1_words);
        end else begin
            if (!$value$plusargs("irom=%s", flat_file)) begin
                $display("ERROR: specify +irom=<hex> or +irom_slot0=<hex> +irom_slot1=<hex> for IROM64");
                $finish;
            end
            $readmemh(flat_file, flat_words);
        end
    end

    always @(posedge clka) begin
        if (banked_enable)
            douta <= {slot1_words[addra], slot0_words[addra]};
        else
            douta <= {
                (flat_word1_addr < 13'd4096) ? flat_words[flat_word1_addr[11:0]] : 32'h0000_0013,
                (flat_word0_addr < 13'd4096) ? flat_words[flat_word0_addr[11:0]] : 32'h0000_0013
            };
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
