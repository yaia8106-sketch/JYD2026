// ============================================================
// Module: timer_irq_ctrl
// Description: Hold a timer interrupt request while the pipeline drains.
// Domain: architectural control.
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

    assign pipeline_empty = ~ex_valid
                          & ~mem_valid
                          & ~wb_valid
                          & ~ex_s1_valid
                          & ~mem_s1_valid
                          & ~wb_s1_valid;
    assign timer_irq_take = timer_irq_hold & id_valid & pipeline_empty;

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
