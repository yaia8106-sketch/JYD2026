// ============================================================
// 中文说明：产生分支、异常、特权返回等控制流恢复请求，并确定恢复请求的优先级。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：redirect_ctrl。
// 说明：生成 EX 快速重定向和 MEM 重放用的前端冲刷控制。
// 普通 CFI 和 ISA 特权流使用已寄存的 MEM 重定向；定时器中断使用 EX 快速路径。
// 所属部分：架构控制。
// ============================================================

module redirect_ctrl (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,  // 已寄存的 MEM 阶段重定向
    input  logic [31:0] mem_branch_target,

    input  logic        ex_priv_redirect,
    input  logic [31:0] ex_priv_target,
    input  logic        timer_irq_redirect,
    input  logic [31:0] timer_irq_target,

    output logic        ex_redirect_fire,
    output logic        ex_fast_redirect,
    output logic [31:0] ex_fast_redirect_target,
    output logic        mem_branch_replay,
    output logic        frontend_branch_flush,
    output logic [31:0] frontend_branch_target
);

    logic fast_branch_redirect_r;

    // 只有指令可以正常离开 EX 时，EX 重定向才允许生效。
    assign ex_redirect_fire = ~mem_branch_flush & ex_ready_go & mem_allowin;
    // 同步特权流已经进入寄存的 EX/MEM 重定向 payload，不要再送入前端快速路径；
    // 否则 DCache mem_allowin 会被带到取指 PC。定时器中断仍保持快速，因为
    // timer_irq_take 已经是寄存的、且流水线为空的事件。
    assign ex_fast_redirect = timer_irq_redirect;
    assign ex_fast_redirect_target = timer_irq_target;
    // EX 快速重定向会抑制上一周期的 MEM 重定向重放，防止旧目标覆盖新目标。
    assign mem_branch_replay = mem_branch_flush & ~fast_branch_redirect_r;
    // 任一路有效都会冲刷前端；若两路同时出现，更老的 MEM redirect 优先。
    assign frontend_branch_flush = mem_branch_replay | ex_fast_redirect;
    assign frontend_branch_target = mem_branch_replay ? mem_branch_target
                                                      : ex_fast_redirect_target;

    always_ff @(posedge clk) begin
        if (!rst_n)
            fast_branch_redirect_r <= 1'b0;
        else
            fast_branch_redirect_r <= ex_fast_redirect;
    end

endmodule
