// NSCSCC/chiplab build: infer the direct-mapped 16384x32 DCache data bank
// instead of
// depending on the JYD Vivado project-specific dcache_data_ram IP.
module dcache_data_ram (
    input  logic        clka,
    input  logic [ 3:0] wea,
    input  logic [13:0] addra,
    input  logic [31:0] dina,
    input  logic        clkb,
    input  logic        enb,
    input  logic [13:0] addrb,
    output logic [31:0] doutb
);
    // At a depth of 16K, describing one 32-bit array with four byte enables
    // makes Vivado synthesize a wide write-enable steering network. Four
    // independent byte banks express the physical structure directly: each
    // bank owns one write enable and their registered outputs concatenate.
    (* ram_style = "block" *) logic [7:0] mem_byte0 [0:16383];
    (* ram_style = "block" *) logic [7:0] mem_byte1 [0:16383];
    (* ram_style = "block" *) logic [7:0] mem_byte2 [0:16383];
    (* ram_style = "block" *) logic [7:0] mem_byte3 [0:16383];

    always_ff @(posedge clka) begin
        if (wea[0]) mem_byte0[addra] <= dina[ 7: 0];
        if (wea[1]) mem_byte1[addra] <= dina[15: 8];
        if (wea[2]) mem_byte2[addra] <= dina[23:16];
        if (wea[3]) mem_byte3[addra] <= dina[31:24];
    end

    always_ff @(posedge clkb) begin
        if (enb) begin
            doutb[ 7: 0] <= mem_byte0[addrb];
            doutb[15: 8] <= mem_byte1[addrb];
            doutb[23:16] <= mem_byte2[addrb];
            doutb[31:24] <= mem_byte3[addrb];
        end
    end

endmodule
