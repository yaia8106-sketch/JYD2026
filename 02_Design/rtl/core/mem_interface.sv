// ============================================================
// Module: mem_interface
// Description: DRAM access helpers (pure combinational)
//   - Store side (EX stage): WEA generation + store data shift
//   - Load side (MEM stage): byte extraction + sign/zero extension
//     Address candidates are computed in parallel before a late lane select.
// Spec: 02_Design/spec/mem_interface_spec.md
// ============================================================

module mem_interface (
    // ---- Store side (used in EX stage) ----
    input  logic        store_valid,       // ex_valid
    input  logic        store_en,          // ex_mem_write_en
    input  logic [ 1:0] store_addr_low,    // ALU_result[1:0]
    input  logic [ 1:0] store_mem_size,    // 00=B, 01=H, 10=W
    input  logic [31:0] store_data_in,     // rs2_data (raw)
    output logic [ 3:0] store_wea,         // BRAM byte write enable (gated)
    output logic [31:0] store_data_out,    // shifted data to BRAM din

    // ---- Load side (used in MEM stage) ----
    input  logic        load_en,
    input  logic [ 1:0] load_addr_low,
    input  logic [ 1:0] load_mem_size,     // 00=B, 01=H, 10=W
    input  logic        load_unsigned,
    input  logic [31:0] load_dram_dout,    // raw 32-bit BRAM output
    output wire  [31:0] load_data_out      // extracted + extended result
);

    // ================================================================
    //  Store side: WEA + data shift
    // ================================================================

    // WEA: which bytes to write (gated by valid & enable)
    wire st_byte = (store_mem_size == 2'b00);
    wire st_half = (store_mem_size == 2'b01);
    wire st_word = (store_mem_size == 2'b10);

    wire [3:0] wea_raw = ({4{st_byte}} & (4'b0001 << store_addr_low))
                       | ({4{st_half}} & (4'b0011 << store_addr_low))
                       | ({4{st_word}} & 4'b1111);

    assign store_wea = (store_valid & store_en) ? wea_raw : 4'b0000;

    // Data shift: move rs2 data to correct byte lane
    assign store_data_out = store_data_in << {store_addr_low, 3'b0};

    // ================================================================
    //  Load side: parallel byte extraction + sign/zero extension
    // ================================================================

    wire load_byte_signed   = load_en & (load_mem_size == 2'b00) & ~load_unsigned;
    wire load_byte_unsigned = load_en & (load_mem_size == 2'b00) &  load_unsigned;
    wire load_half_signed   = load_en & (load_mem_size == 2'b01) & ~load_unsigned;
    wire load_half_unsigned = load_en & (load_mem_size == 2'b01) &  load_unsigned;
    wire load_word          = load_en & (load_mem_size == 2'b10);

    function automatic logic [31:0] format_load_candidate(
        input logic [31:0] shifted,
        input logic        byte_signed,
        input logic        byte_unsigned,
        input logic        half_signed,
        input logic        half_unsigned,
        input logic        word
    );
        logic [31:0] byte_signed_ext;
        logic [31:0] byte_unsigned_ext;
        logic [31:0] half_signed_ext;
        logic [31:0] half_unsigned_ext;
        begin
            byte_signed_ext   = {{24{shifted[7]}},  shifted[7:0]};
            byte_unsigned_ext = {24'd0, shifted[7:0]};
            half_signed_ext   = {{16{shifted[15]}}, shifted[15:0]};
            half_unsigned_ext = {16'd0, shifted[15:0]};
            format_load_candidate =
                ({32{byte_signed}}   & byte_signed_ext)
              | ({32{byte_unsigned}} & byte_unsigned_ext)
              | ({32{half_signed}}   & half_signed_ext)
              | ({32{half_unsigned}} & half_unsigned_ext)
              | ({32{word}}          & shifted);
        end
    endfunction

    // These candidates exactly match a logical right shift by addr_low * 8,
    // including the zero fill used for misaligned accesses.
    wire [31:0] shifted_addr0 = load_dram_dout;
    wire [31:0] shifted_addr1 = { 8'd0, load_dram_dout[31:8]};
    wire [31:0] shifted_addr2 = {16'd0, load_dram_dout[31:16]};
    wire [31:0] shifted_addr3 = {24'd0, load_dram_dout[31:24]};

    wire [31:0] load_addr0_candidate = format_load_candidate(
        shifted_addr0, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr1_candidate = format_load_candidate(
        shifted_addr1, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr2_candidate = format_load_candidate(
        shifted_addr2, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );
    wire [31:0] load_addr3_candidate = format_load_candidate(
        shifted_addr3, load_byte_signed, load_byte_unsigned,
        load_half_signed, load_half_unsigned, load_word
    );

    assign load_data_out = ({32{load_addr_low == 2'd0}} & load_addr0_candidate)
                         | ({32{load_addr_low == 2'd1}} & load_addr1_candidate)
                         | ({32{load_addr_low == 2'd2}} & load_addr2_candidate)
                         | ({32{load_addr_low == 2'd3}} & load_addr3_candidate);

endmodule
