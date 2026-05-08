`timescale 1ns / 1ps

`include "physical_mem_paths.vh"

module DRAM4MyOwn #(
    parameter int DEPTH_WORDS = 16384,
    parameter int ADDR_WIDTH  = 14
) (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [15:0] addra,
    input  logic [31:0] dina,

    input  logic        clkb,
    input  logic        enb,
    input  logic [15:0] addrb,
    output logic [31:0] doutb
);

    (* ram_style = "block" *) logic [31:0] mem [0:DEPTH_WORDS-1];

    wire wr_in_range = (addra < DEPTH_WORDS);
    wire rd_in_range = (addrb < DEPTH_WORDS);
    wire [ADDR_WIDTH-1:0] wr_index = addra[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] rd_index = addrb[ADDR_WIDTH-1:0];

    logic [31:0] dout_raw;

    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'd0;
        $readmemh(`PT_DRAM_MEM, mem);
    end

    always_ff @(posedge clka) begin
        if (wr_in_range) begin
            if (wea[0]) mem[wr_index][ 7: 0] <= dina[ 7: 0];
            if (wea[1]) mem[wr_index][15: 8] <= dina[15: 8];
            if (wea[2]) mem[wr_index][23:16] <= dina[23:16];
            if (wea[3]) mem[wr_index][31:24] <= dina[31:24];
        end
    end

    always_ff @(posedge clkb) begin
        if (enb)
            dout_raw <= rd_in_range ? mem[rd_index] : 32'd0;
        doutb <= dout_raw;
    end

endmodule
