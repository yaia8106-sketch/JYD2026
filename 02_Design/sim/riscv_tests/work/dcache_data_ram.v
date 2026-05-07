// =============================================================
// dcache_data_ram.v — Behavioral model for iverilog simulation
// Matches blk_mem_gen IP: SDP, 256x32, byte-write enable
// Operating_Mode_B = READ_FIRST (read old value on collision)
// =============================================================
module dcache_data_ram (
    input  wire        clka,
    input  wire [ 3:0] wea,
    input  wire [ 7:0] addra,
    input  wire [31:0] dina,
    input  wire        clkb,
    input  wire [ 7:0] addrb,
    output reg  [31:0] doutb
);

    reg [31:0] mem [0:255];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 32'd0;
    end

    // Port A: Write (byte-enable) — assumed same clock as Port B
    always @(posedge clka) begin
        if (wea[0]) mem[addra][ 7: 0] <= dina[ 7: 0];
        if (wea[1]) mem[addra][15: 8] <= dina[15: 8];
        if (wea[2]) mem[addra][23:16] <= dina[23:16];
        if (wea[3]) mem[addra][31:24] <= dina[31:24];
    end

    // Port B: Read — READ_FIRST mode
    // On collision (same addr, same clock), output is the OLD value
    // (before the write takes effect). This matches Xilinx BRAM behavior.
    always @(posedge clkb) begin
        doutb <= mem[addrb];  // reads BEFORE write (non-blocking)
    end

endmodule
