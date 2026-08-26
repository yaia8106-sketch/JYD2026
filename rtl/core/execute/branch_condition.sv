// ============================================================
// 中文说明：根据条件分支的两个操作数计算是否满足跳转条件。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：branch_condition
// 说明：比较条件分支的两个操作数，得到是否满足跳转条件。
// 所属阶段：execute。
// ============================================================

module branch_condition
    import cpu_defs::*;
(
    input  logic [31:0] src0_data,
    input  logic [31:0] src1_data,
    input  branch_op_t  branch_op,
    output logic        taken
);

    // 相等判断与大小关系无关。BEQ/BNE 不经过减法进位链，显式构造归约树：
    // 第一级每组可放入一个 LUT6，之后接一个六输入 OR。
    // keep 属性防止这些分组被串行吸收到预测器更新使能逻辑中。
    wire [31:0] mismatch_bits = src0_data ^ src1_data;
    (* keep = "true" *) wire neq_group0 = |mismatch_bits[ 5: 0];
    (* keep = "true" *) wire neq_group1 = |mismatch_bits[11: 6];
    (* keep = "true" *) wire neq_group2 = |mismatch_bits[17:12];
    (* keep = "true" *) wire neq_group3 = |mismatch_bits[23:18];
    (* keep = "true" *) wire neq_group4 = |mismatch_bits[29:24];
    (* keep = "true" *) wire neq_group5 = |mismatch_bits[31:30];
    wire neq = neq_group0 | neq_group1 | neq_group2
             | neq_group3 | neq_group4 | neq_group5;

    // 减法通路只用于有符号或无符号的大小关系比较。
    wire [31:0] diff = src0_data - src1_data;
    wire is_unsigned = (branch_op == BR_LTU) | (branch_op == BR_GEU);
    wire cmp = (src0_data[31] == src1_data[31]) ? diff[31] :
               is_unsigned ? src1_data[31] : src0_data[31];

    // 无效的 branch funct3 不会选中任何条件，因此按“不跳转”处理。
    wire sel_eq = branch_op == BR_EQ;
    wire sel_ne = branch_op == BR_NE;
    wire sel_lt = (branch_op == BR_LT) | (branch_op == BR_LTU);
    wire sel_ge = (branch_op == BR_GE) | (branch_op == BR_GEU);
    wire sel_always = branch_op == BR_ALWAYS;

    assign taken = sel_always
                 | (sel_eq & ~neq)
                 | (sel_ne &  neq)
                 | (sel_lt &  cmp)
                 | (sel_ge & ~cmp);

endmodule
