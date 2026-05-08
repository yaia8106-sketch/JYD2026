`timescale 1ns / 1ps

`include "physical_mem_paths.vh"

module IROMOdd32 (
    input  logic        clka,
    input  logic [11:0] addra,
    output logic [31:0] douta
);

    (* rom_style = "block" *) logic [31:0] mem [0:4095];

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            mem[i] = 32'h0000_0013;
        $readmemh(`PT_IROM_SLOT1_MEM, mem);
    end

    always_ff @(posedge clka) begin
        douta <= mem[addra];
    end

endmodule
