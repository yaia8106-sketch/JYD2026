// ============================================================
// 中文说明：统计双发射及提交相关事件，用于观察处理器实际的发射和执行效率。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：dual_issue_counter。
// 说明：统计已提交的 Slot1 指令数量。
// ============================================================

module dual_issue_counter (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wb_s1_valid,
    output logic [31:0] dual_issue_count
);

    // WB 阶段 Slot1 有效，等价于一次双发射组中的第二条指令已提交。
    always_ff @(posedge clk) begin
        if (!rst_n)
            dual_issue_count <= 32'd0;
        else if (wb_s1_valid)
            dual_issue_count <= dual_issue_count + 32'd1;
    end

endmodule
