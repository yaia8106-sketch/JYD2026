// ============================================================
// 中文说明：整理 ALU 的原始结果、快速前递结果和需要写回的最终结果。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：alu_result_datapath
// 说明：生成普通整数运算结果，不包含 LSU 地址加法器。
//
// EX 阶段的每个发射槽各实例化两份：架构结果副本使用 WB 修复后的操作数，
// 输出到 EX/MEM；前递结果副本只使用已经寄存的原始操作数，输出到 ID 的旁路网络。
// 地址加法器放在本模块之外，避免复制一个不参与 EX 前递的 LSU 资源。
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

    // 加法器和减法器共用。SUB、SLT、SLTU 需要对源操作数 2 取反。
    wire negate = alu_op[3] | alu_op[1];
    wire [31:0] sum = alu_src1
                    + (negate ? ~alu_src2 : alu_src2)
                    + {31'b0, negate};
    assign alu_sum = sum;

    // 同号比较使用减法结果的符号位；异号时，有符号和无符号比较
    // 直接选择相应的操作数符号位。
    wire cmp = (alu_src1[31] == alu_src2[31]) ? sum[31]
             : alu_op[0] ? alu_src2[31] : alu_src1[31];

    // 通过右移器和位反转同时实现左右两个方向的移位。
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
