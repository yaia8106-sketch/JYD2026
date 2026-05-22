`timescale 1ns / 1ps

`include "physical_mem_paths.vh"

module DRAM4MyOwn (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [15:0] addra,
    input  logic [31:0] dina,

    input  logic        clkb,
    input  logic        enb,
    input  logic [15:0] addrb,
    output logic [31:0] doutb
);

    localparam int DEPTH_WORDS = 65536;

    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH_WORDS-1];
    logic [31:0] dout_raw;

    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'd0;
        $readmemh(`PT_DRAM_MEM, mem);
    end

    always_ff @(posedge clka) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    // Match the original DRAM IP model used by the CPU/DCache: BRAM read plus
    // one output register, for two-cycle read latency at the module boundary.
    always_ff @(posedge clkb) begin
        if (enb) begin
            dout_raw <= mem[addrb];
            doutb    <= dout_raw;
        end
    end

endmodule

