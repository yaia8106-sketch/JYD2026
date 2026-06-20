// ============================================================
// Module: mem_interface
// Description: DRAM access helpers (pure combinational)
//   - Store side (EX stage): WEA generation + store data shift
//   - Load side (WB stage): byte extraction + sign/zero extension
//     Load controls are predecoded in MEM/WB to keep mem_size compare logic
//     out of the WB repair path.
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

    // ---- Load side (used in WB stage) ----
    input  logic [ 4:0] load_shift,        // {addr[1:0], 3'b0}, from MEM/WB
    input  logic        load_byte_signed,
    input  logic        load_byte_unsigned,
    input  logic        load_half_signed,
    input  logic        load_half_unsigned,
    input  logic        load_word,
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
    //  Load side: byte extraction + sign/zero extension
    // ================================================================

    // Step 1: shift dout right to align target bytes to LSB
    wire [31:0] shifted = load_dram_dout >> load_shift;

    // Step 2: extract + extend (AND-OR MUX, no always_comb)
    wire [31:0] byte_signed_ext   = {{24{shifted[7]}},  shifted[7:0]};
    wire [31:0] byte_unsigned_ext = {24'd0, shifted[7:0]};
    wire [31:0] half_signed_ext   = {{16{shifted[15]}}, shifted[15:0]};
    wire [31:0] half_unsigned_ext = {16'd0, shifted[15:0]};

    assign load_data_out = ({32{load_byte_signed}}   & byte_signed_ext)
                         | ({32{load_byte_unsigned}} & byte_unsigned_ext)
                         | ({32{load_half_signed}}   & half_signed_ext)
                         | ({32{load_half_unsigned}} & half_unsigned_ext)
                         | ({32{load_word}}          & shifted);

endmodule
