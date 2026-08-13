// ============================================================
// Module: dcache_data_format
// Description: DCache byte merge and architectural load formatting.
// Domain: NSCSCC data cache.
//
// Hit data, refill/uncached data, and refill-store data are transformed in
// parallel. The DCache top keeps only source ownership and response selection.
// ============================================================

module dcache_data_format (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        check_valid,

    input  logic [31:0] refill_base_data,
    input  logic [31:0] refill_store_data,
    input  logic [ 3:0] refill_store_wea,
    output logic [31:0] refill_write_data,

    input  logic [31:0] cache_base_data,
    input  logic [31:0] cache_bypass_data,
    input  logic [ 3:0] cache_bypass_mask,
    output logic [31:0] cache_read_data,

    input  logic [31:0] special_read_data,
    input  logic [ 1:0] load_addr_low,
    input  logic [ 1:0] load_size,
    input  logic        load_unsigned,
    output logic [31:0] formatted_hit,
    output logic [31:0] formatted_special
);

    function automatic logic [31:0] merge_bytes(
        input logic [31:0] base,
        input logic [31:0] overlay,
        input logic [ 3:0] strobe
    );
        begin
            merge_bytes[ 7: 0] = strobe[0] ? overlay[ 7: 0] : base[ 7: 0];
            merge_bytes[15: 8] = strobe[1] ? overlay[15: 8] : base[15: 8];
            merge_bytes[23:16] = strobe[2] ? overlay[23:16] : base[23:16];
            merge_bytes[31:24] = strobe[3] ? overlay[31:24] : base[31:24];
        end
    endfunction

    function automatic logic [31:0] format_load(
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] size,
        input logic        unsigned_load
    );
        begin
            // Address and size select together, avoiding a serial variable
            // shift followed by size selection and sign extension.
            case ({size, addr_low})
                4'b00_00: format_load = {
                    {24{raw_data[7] & ~unsigned_load}}, raw_data[7:0]
                };
                4'b00_01: format_load = {
                    {24{raw_data[15] & ~unsigned_load}}, raw_data[15:8]
                };
                4'b00_10: format_load = {
                    {24{raw_data[23] & ~unsigned_load}}, raw_data[23:16]
                };
                4'b00_11: format_load = {
                    {24{raw_data[31] & ~unsigned_load}}, raw_data[31:24]
                };
                4'b01_00: format_load = {
                    {16{raw_data[15] & ~unsigned_load}}, raw_data[15:0]
                };
                4'b01_01: format_load = {
                    {16{raw_data[23] & ~unsigned_load}}, raw_data[23:8]
                };
                4'b01_10: format_load = {
                    {16{raw_data[31] & ~unsigned_load}}, raw_data[31:16]
                };
                // The historical logical shift by 24 zeros shifted[15:8].
                4'b01_11: format_load = {24'd0, raw_data[31:24]};
                4'b10_00: format_load = raw_data;
                4'b10_01: format_load = {8'd0, raw_data[31:8]};
                4'b10_10: format_load = {16'd0, raw_data[31:16]};
                4'b10_11: format_load = {24'd0, raw_data[31:24]};
                default:  format_load = 32'd0;
            endcase
        end
    endfunction

    assign refill_write_data = merge_bytes(
        refill_base_data, refill_store_data, refill_store_wea
    );
    assign cache_read_data = merge_bytes(
        cache_base_data, cache_bypass_data, cache_bypass_mask
    );
    assign formatted_hit = format_load(
        cache_read_data, load_addr_low, load_size, load_unsigned
    );
    assign formatted_special = format_load(
        special_read_data, load_addr_low, load_size, load_unsigned
    );

`ifndef SYNTHESIS
    function automatic logic [31:0] format_load_reference(
        input logic [31:0] raw_data,
        input logic [ 1:0] addr_low,
        input logic [ 1:0] size,
        input logic        unsigned_load
    );
        logic [31:0] shifted;
        begin
            case (addr_low)
                2'd0: shifted = raw_data;
                2'd1: shifted = { 8'd0, raw_data[31:8]};
                2'd2: shifted = {16'd0, raw_data[31:16]};
                default: shifted = {24'd0, raw_data[31:24]};
            endcase
            case (size)
                2'b00: format_load_reference = {
                    {24{shifted[7] & ~unsigned_load}}, shifted[7:0]
                };
                2'b01: format_load_reference = {
                    {16{shifted[15] & ~unsigned_load}}, shifted[15:0]
                };
                2'b10: format_load_reference = shifted;
                default: format_load_reference = 32'd0;
            endcase
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst_n && check_valid) begin
            if (formatted_hit !== format_load_reference(
                    cache_read_data, load_addr_low, load_size, load_unsigned))
                $fatal(1, "DCache hit load formatter changed behavior");
            if (formatted_special !== format_load_reference(
                    special_read_data, load_addr_low,
                    load_size, load_unsigned))
                $fatal(1, "DCache special load formatter changed behavior");
        end
    end
`endif

endmodule
