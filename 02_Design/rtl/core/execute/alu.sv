// ============================================================
// 中文说明：执行加减、逻辑、移位和比较等普通整数 ALU 操作。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：alu
// 说明：生成架构整数结果，并独立计算 LSU 访存地址。
// 所属阶段：execute。
// 规格说明：02_Design/spec/alu_spec.md。
// 运算编码：具体含义由 cpu_defs::alu_op_t 定义。
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
    output logic [31:0] alu_sum,
    output logic [31:0] alu_addr
);

    alu_result_datapath u_result_datapath (
        .alu_op     (alu_op),
        .alu_src1   (alu_src1),
        .alu_src2   (alu_src2),
        .shift_amount(alu_src2[4:0]),
        .alu_result (alu_result),
        .alu_sum    (alu_sum)
    );

    // LSU 地址计算不放入复制的前递数据通路；它的操作数仍遵循 WB 修复规则。
    assign alu_addr = alu_addr_src1 + alu_addr_src2;

endmodule
