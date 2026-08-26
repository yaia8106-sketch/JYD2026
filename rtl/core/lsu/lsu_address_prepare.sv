// ============================================================
// 中文说明：整理 LSU 使用的有效地址、地址低位、缓存属性和异常检查输入。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：lsu_address_prepare。
// 说明：为一个 EX 槽位计算 DCache 查询地址和字节对齐所需地址。
// 两位模加法器与 19 位查询加法器刻意独立，使对齐判断不继承 DCache 地址
// 加法器的进位链。
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
