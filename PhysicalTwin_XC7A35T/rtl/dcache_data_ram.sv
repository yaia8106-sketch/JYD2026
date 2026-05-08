`timescale 1ns / 1ps

module dcache_data_ram (
    input  logic        clka,
    input  logic [3:0]  wea,
    input  logic [7:0]  addra,
    input  logic [31:0] dina,

    input  logic        clkb,
    input  logic [7:0]  addrb,
    output logic [31:0] doutb
);

    (* ram_style = "block" *) logic [31:0] mem [0:255];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 32'd0;
    end

    always_ff @(posedge clka) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    always_ff @(posedge clkb) begin
        doutb <= mem[addrb];
    end

endmodule
