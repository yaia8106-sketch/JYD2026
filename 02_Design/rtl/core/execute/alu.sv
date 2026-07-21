// ============================================================
// Module: alu
// Description: 32-bit ALU with hardware-shared adder, comparator, and shifter
// Domain: execute.
// Spec: 02_Design/spec/alu_spec.md
// Encoding: semantic values are defined by cpu_defs::alu_op_t.
// ============================================================

module alu
    import cpu_defs::*;
(
    input  logic [ 3:0] alu_op,
    input  logic [31:0] alu_src1,
    input  logic [31:0] alu_src2,
    input  logic [31:0] alu_addr_src1,
    input  logic [31:0] alu_addr_src2,
    output logic [31:0] alu_result,
    output logic [31:0] alu_sum,       // Raw shared adder output, before result MUX
    output logic [31:0] alu_addr       // Independent address adder, does not depend on alu_op
);


    // Pure src1+src2 adder for load/store address calculation. This bypasses
    // the subtract/compare negate logic and removes alu_op from the address path.
    assign alu_addr = alu_addr_src1 + alu_addr_src2;

    // ---- 3.1 Shared adder/subtractor ----
    // negate src2 for SUB(1_000), SLT(0_010), SLTU(0_011)
    wire negate = alu_op[3] | alu_op[1];
    wire [31:0] sum = alu_src1 + (negate ? ~alu_src2 : alu_src2) + {31'b0, negate};
    assign alu_sum = sum;

    // ---- 3.2 Unified comparator ----
    // Same sign: check subtraction result sign bit
    // Different sign: signed -> src1[31], unsigned -> src2[31]
    wire cmp = (alu_src1[31] == alu_src2[31]) ? sum[31]
             : alu_op[0] ? alu_src2[31] : alu_src1[31];

    // ---- 3.3 Bit-reversal shifter ----
    // A right shifter plus bit reversal implements both left and right shifts.
    wire [4:0]  shamt  = alu_src2[4:0];
    wire [31:0] shin   = alu_op[2] ? alu_src1 : bit_reverse(alu_src1);
    wire [32:0] shift  = {alu_op[3] & shin[31], shin};
    wire [32:0] shiftt = $signed(shift) >>> shamt;
    wire [31:0] shiftr = shiftt[31:0];
    wire [31:0] shiftl = bit_reverse(shiftr);

    // ---- 3.4 Output selection (parallel AND-OR) ----
    // Decode by funct3 (alu_op[2:0]), using bit-level grouping
    wire sel_add = (alu_op[2:0] == 3'b000);  // ADD / SUB
    wire sel_sll = (alu_op[2:0] == 3'b001);  // SLL
    wire sel_cmp = (alu_op[1]  & ~alu_op[2]); // SLT(010) / SLTU(011)
    wire sel_xor = (alu_op[2:0] == 3'b100);  // XOR
    wire sel_shr = (alu_op[2:0] == 3'b101);  // SRL / SRA
    wire sel_or  = (alu_op == ALU_OR);       // OR
    wire sel_nor = (alu_op == ALU_NOR);      // NOR
    wire sel_and = (alu_op[2:0] == 3'b111);  // AND

    assign alu_result = ({32{sel_add}} & sum)
                      | ({32{sel_sll}} & shiftl)
                      | ({32{sel_cmp}} & {31'b0, cmp})
                      | ({32{sel_xor}} & (alu_src1 ^ alu_src2))
                      | ({32{sel_shr}} & shiftr)
                      | ({32{sel_or}}  & (alu_src1 | alu_src2))
                      | ({32{sel_nor}} & ~(alu_src1 | alu_src2))
                      | ({32{sel_and}} & (alu_src1 & alu_src2));

    // ---- Bit-reverse function ----
    function automatic logic [31:0] bit_reverse(input logic [31:0] in);
        for (int i = 0; i < 32; i++) begin
            bit_reverse[i] = in[31-i];
        end
    endfunction

endmodule
