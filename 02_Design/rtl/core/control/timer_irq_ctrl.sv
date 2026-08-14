// ============================================================
// 中文说明：管理定时器中断的计数、请求生成和进入中断前的边界条件。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：timer_irq_ctrl。
// 说明：在流水线排空期间保持定时器中断请求。
// 所属部分：架构控制。
// ============================================================

module timer_irq_ctrl (
    input  logic clk,
    input  logic rst_n,

    input  logic timer_irq_request,
    input  logic id_valid,
    input  logic frontend_flush,

    input  logic ex_valid,
    input  logic mem_valid,
    input  logic wb_valid,
    input  logic ex_s1_valid,
    input  logic mem_s1_valid,
    input  logic wb_s1_valid,

    output logic timer_irq_hold,
    output logic pipeline_empty,
    output logic timer_irq_take
);

    // 定时器中断只在指令边界进入，并且必须等所有更老的在途指令排空。
    assign pipeline_empty = ~ex_valid
                          & ~mem_valid
                          & ~wb_valid
                          & ~ex_s1_valid
                          & ~mem_s1_valid
                          & ~wb_s1_valid;
    assign timer_irq_take = timer_irq_hold & id_valid & pipeline_empty;

    // ID 观察到请求后将其保持；发生重定向时取消尚未处理的保持请求。
    always_ff @(posedge clk) begin
        if (!rst_n)
            timer_irq_hold <= 1'b0;
        else if (timer_irq_take)
            timer_irq_hold <= 1'b0;
        else if (frontend_flush)
            timer_irq_hold <= 1'b0;
        else if (timer_irq_request & id_valid)
            timer_irq_hold <= 1'b1;
    end

endmodule
