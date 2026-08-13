// ============================================================
// Module: alu_result_datapath
// Description: Ordinary integer-result logic without the LSU address adder.
//
// The execute stage instantiates this block twice per issue lane: the
// architectural copy consumes WB-repaired operands and terminates at EX/MEM,
// while the forwarding copy consumes only registered raw operands and
// terminates at the ID bypass network. Keeping the address adder outside this
// block avoids duplicating an LSU resource that is not part of EX forwarding.
// ============================================================

module alu_result_datapath
    import cpu_defs::*;
(
    input  logic [ 3:0] alu_op,
    input  logic [31:0] alu_src1,
    input  logic [31:0] alu_src2,
    input  logic [ 4:0] shift_amount,
    output logic [31:0] alu_result,
    output logic [31:0] alu_sum
);

    // Shared adder/subtractor. SUB, SLT and SLTU negate source 2.
    wire negate = alu_op[3] | alu_op[1];
    wire [31:0] sum = alu_src1
                    + (negate ? ~alu_src2 : alu_src2)
                    + {31'b0, negate};
    assign alu_sum = sum;

    // Same-sign comparisons use the subtraction sign. Different-sign signed
    // and unsigned comparisons select the appropriate operand sign directly.
    wire cmp = (alu_src1[31] == alu_src2[31]) ? sum[31]
             : alu_op[0] ? alu_src2[31] : alu_src1[31];

    // A right shifter plus bit reversal implements both shift directions.
    wire [31:0] shift_input = alu_op[2]
                            ? alu_src1 : bit_reverse(alu_src1);
    wire [32:0] signed_shift_input = {
        alu_op[3] & shift_input[31], shift_input
    };
    wire [32:0] shifted = $signed(signed_shift_input) >>> shift_amount;
    wire [31:0] shift_right_result = shifted[31:0];
    wire [31:0] shift_left_result = bit_reverse(shift_right_result);

    wire select_add = alu_op[2:0] == 3'b000;
    wire select_shift_left = alu_op[2:0] == 3'b001;
    wire select_compare = alu_op[1] & ~alu_op[2];
    wire select_xor = alu_op[2:0] == 3'b100;
    wire select_shift_right = alu_op[2:0] == 3'b101;
    wire select_or = alu_op == ALU_OR;
    wire select_nor = alu_op == ALU_NOR;
    wire select_and = alu_op[2:0] == 3'b111;

    wire [31:0] logical_shift_result =
        ({32{select_shift_left}}  & shift_left_result)
      | ({32{select_xor}}         & (alu_src1 ^ alu_src2))
      | ({32{select_shift_right}} & shift_right_result)
      | ({32{select_or}}          & (alu_src1 | alu_src2))
      | ({32{select_nor}}         & ~(alu_src1 | alu_src2))
      | ({32{select_and}}         & (alu_src1 & alu_src2));

    wire [1:0] result_select = select_add ? 2'b00
                             : select_compare ? 2'b01
                                              : 2'b10;

    function automatic logic [31:0] select_result(
        input logic [ 1:0] select,
        input logic [31:0] sum_candidate,
        input logic        compare_candidate,
        input logic [31:0] logical_shift_candidate
    );
        case (select)
            2'b00:   select_result = sum_candidate;
            2'b01:   select_result = {31'b0, compare_candidate};
            default: select_result = logical_shift_candidate;
        endcase
    endfunction

    assign alu_result = select_result(
        result_select, sum, cmp, logical_shift_result
    );

    function automatic logic [31:0] bit_reverse(input logic [31:0] in);
        for (int i = 0; i < 32; i++) begin
            bit_reverse[i] = in[31-i];
        end
    endfunction

endmodule
