// ============================================================
// Module: lsu_address_prepare
// Description:
//   Computes the DCache lookup address and byte-alignment address for one EX
//   lane. The two-bit modulo sum is intentionally independent of the 19-bit
//   lookup adder so alignment does not inherit the DCache address carry chain.
// ============================================================

module lsu_address_prepare (
    input  logic [31:0] base_operand,
    input  logic [31:0] repaired_base_operand,
    input  logic [31:0] offset_operand,
    input  logic        use_repaired_base,
    output logic [18:0] lookup_addr_low,
    output logic [ 1:0] align_addr_low
);

    logic [18:0] raw_lookup_addr_low;
    logic [18:0] repaired_lookup_addr_low;
    logic [ 1:0] raw_align_addr_low;
    logic [ 1:0] repaired_align_addr_low;

    assign raw_lookup_addr_low = base_operand[18:0]
                               + offset_operand[18:0];
    assign repaired_lookup_addr_low = repaired_base_operand[18:0]
                                    + offset_operand[18:0];

    assign raw_align_addr_low[0] =
        base_operand[0] ^ offset_operand[0];
    assign raw_align_addr_low[1] =
        base_operand[1] ^ offset_operand[1]
        ^ (base_operand[0] & offset_operand[0]);

    assign repaired_align_addr_low[0] =
        repaired_base_operand[0] ^ offset_operand[0];
    assign repaired_align_addr_low[1] =
        repaired_base_operand[1] ^ offset_operand[1]
        ^ (repaired_base_operand[0] & offset_operand[0]);

    assign lookup_addr_low = use_repaired_base
                           ? repaired_lookup_addr_low
                           : raw_lookup_addr_low;
    assign align_addr_low = use_repaired_base
                          ? repaired_align_addr_low
                          : raw_align_addr_low;

endmodule
