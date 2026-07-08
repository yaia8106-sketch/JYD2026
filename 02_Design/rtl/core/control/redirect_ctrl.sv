// ============================================================
// Module: redirect_ctrl
// Description: EX fast redirect and MEM replay frontend flush control.
// Domain: architectural control.
// ============================================================

module redirect_ctrl (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic [31:0] mem_branch_target,

    input  logic        ex_system_redirect,
    input  logic [31:0] ex_system_target,
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

    // EX redirects may fire only when the instruction can leave EX cleanly.
    assign ex_redirect_fire = ~mem_branch_flush & ex_ready_go & mem_allowin;
    assign ex_fast_redirect = ex_system_redirect | timer_irq_redirect;
    assign ex_fast_redirect_target = timer_irq_redirect ? timer_irq_target
                                                        : ex_system_target;
    // A fast EX redirect suppresses replay of the previous cycle's registered
    // MEM redirect, preventing a stale target from overwriting the newer one.
    assign mem_branch_replay = mem_branch_flush & ~fast_branch_redirect_r;
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
