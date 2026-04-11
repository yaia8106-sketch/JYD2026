// ============================================================
// Module: mem_interface
// Description: DRAM access helpers (pure combinational)
//   - Store side (EX stage): WEA generation + store data shift
//   - Load side (WB stage): byte extraction + sign/zero extension
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
    input  logic [ 1:0] load_addr_low,     // addr[1:0] from MEM/WB_reg
    input  logic [ 1:0] load_mem_size,     // 00=B, 01=H, 10=W
    input  logic        load_unsigned,     // 0=sign-ext, 1=zero-ext
    input  logic [31:0] load_dram_dout,    // raw 32-bit BRAM output
    output logic [31:0] load_data_out      // extracted + extended result
);

    // ================================================================
    //  Store side: WEA + data shift
    // ================================================================

    // WEA: which bytes to write (gated by valid & enable)
    logic [3:0] wea_raw;
    always_comb begin
        case (store_mem_size)
            2'b00:   wea_raw = 4'b0001 << store_addr_low;       // SB
            2'b01:   wea_raw = 4'b0011 << store_addr_low;       // SH
            2'b10:   wea_raw = 4'b1111;                          // SW
            default: wea_raw = 4'b0000;
        endcase
    end

    assign store_wea = (store_valid & store_en) ? wea_raw : 4'b0000;

    // Data shift: move rs2 data to correct byte lane
    assign store_data_out = store_data_in << {store_addr_low, 3'b0};

    // ================================================================
    //  Load side: byte extraction + sign/zero extension
    // ================================================================

    // Step 1: shift dout right to align target bytes to LSB
    wire [31:0] shifted = load_dram_dout >> {load_addr_low, 3'b0};

    // Step 2: extract + extend
    always_comb begin
        case (load_mem_size)
            2'b00:   // LB / LBU
                load_data_out = load_unsigned ? {24'd0, shifted[7:0]}
                                              : {{24{shifted[7]}}, shifted[7:0]};
            2'b01:   // LH / LHU
                load_data_out = load_unsigned ? {16'd0, shifted[15:0]}
                                              : {{16{shifted[15]}}, shifted[15:0]};
            2'b10:   // LW
                load_data_out = shifted;
            default:
                load_data_out = 32'd0;
        endcase
    end

endmodule
