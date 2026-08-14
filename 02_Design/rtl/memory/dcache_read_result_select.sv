// ============================================================
// 中文说明：从 DCache 的命中、refill、写回旁路和未缓存返回中选择最终读结果。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：dcache_read_result_select。
// 说明：在布局局部选择 DCache 的最终读结果。
// 所属部分：数据 Cache 响应。
// 两个保留层次的实例防止综合合并相距较远的响应消费者；只复制末级 MUX，
// BRAM 查询、字节提取和符号扩展仍然共享。
// ============================================================

(* keep_hierarchy = "yes" *)
module dcache_read_result_select (
    input  logic        special_valid,
    input  logic [31:0] formatted_hit,
    input  logic [31:0] formatted_special,
    (* keep = "true" *) output logic [31:0] selected_data
);

    always_comb begin
        if (special_valid)
            selected_data = formatted_special;
        else
            selected_data = formatted_hit;
    end

endmodule
