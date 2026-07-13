// ============================================================
// Module: redirect_ctrl
// Description: 跳转共有三种：
// unpri： cfi ins
// pri： 中断(由外部事件触发），例外(由指令触发)
// Domain: architectural control.
// ============================================================

module redirect_ctrl (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush, // from mem stage
    input  logic [31:0] mem_branch_target, // from mem stage

    input  logic        ex_system_redirect,
    input  logic [31:0] ex_system_target,
    input  logic        timer_irq_redirect,
    input  logic [31:0] timer_irq_target,

    output logic        ex_redirect_fire,
    output logic        ex_fast_redirect, // 外部悬空 timer导致的redirect
    output logic [31:0] ex_fast_redirect_target, // 外部悬空
    output logic        mem_branch_replay, // 外部悬空 包含 unpri cfi指令的redirect和ecall/mret的redirect
    output logic        frontend_branch_flush,
    output logic [31:0] frontend_branch_target
);

    logic fast_branch_redirect_r;

    //
    assign ex_redirect_fire = ~mem_branch_flush & ex_ready_go & mem_allowin;
    // timer中断在EX发生redirect
    assign ex_fast_redirect = timer_irq_redirect;
    assign ex_fast_redirect_target = timer_irq_target;

    // 防止EX冲刷后MEM二次冲刷
    assign mem_branch_replay = mem_branch_flush & ~fast_branch_redirect_r;
    // 正常flush || timer导致的中断
    assign frontend_branch_flush = mem_branch_replay | ex_fast_redirect;
    // MEM的旧指令跳转优先于EX的新指令
    assign frontend_branch_target = mem_branch_replay ? mem_branch_target
                                                      : ex_fast_redirect_target;
    // 打一拍，防止ex冲刷后mem二次冲刷
    always_ff @(posedge clk) begin
        if (!rst_n)
            fast_branch_redirect_r <= 1'b0;
        else
            fast_branch_redirect_r <= ex_fast_redirect;
    end

endmodule
