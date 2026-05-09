`timescale 1ns / 1ps

`include "physical_mem_paths.vh"

module IROMEven32 (
    input  logic        clka,
    input  logic [11:0] addra,
    output logic [31:0] douta
);

    localparam int DEPTH_WORDS = 1024;

    (* rom_style = "distributed" *) logic [31:0] mem [0:DEPTH_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH_WORDS; i = i + 1)
            mem[i] = 32'h0000_0013;
        $readmemh(`PT_IROM_SLOT0_MEM, mem);
    end

    always_ff @(posedge clka) begin
        douta <= (addra < DEPTH_WORDS) ? mem[addra[9:0]] : 32'h0000_0013;
    end

endmodule
