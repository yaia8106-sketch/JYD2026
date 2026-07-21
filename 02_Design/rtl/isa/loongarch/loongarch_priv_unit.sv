// ============================================================
// Module: loongarch_priv_unit
// Description: Explicit phase-2 placeholder for the common core interface.
//
// Privileged instructions, exceptions, interrupts, CSRs and ERTN are outside
// the ordinary-integer decoder scope. The selected LoongArch filelist still
// supplies this side-effect-free module so cpu_top can be elaborated without
// borrowing any RISC-V privileged behavior.
// ============================================================

module loongarch_priv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_src0_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  logic        timer_irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,
    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata
);

    assign ex_priv_flow = 1'b0;
    assign ex_priv_redirect = 1'b0;
    assign ex_priv_target = 32'd0;
    assign timer_irq_request = 1'b0;
    assign timer_irq_redirect = 1'b0;
    assign timer_irq_target = 32'd0;
    assign ex_priv_rdata = 32'd0;

endmodule

module isa_priv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ex_valid,
    input  logic        ex_ready_go,
    input  logic        mem_allowin,
    input  logic        mem_branch_flush,
    input  logic        ex_redirect_fire,
    input  logic [31:0] ex_pc,
    input  logic [31:0] ex_src0_data,
    input  priv_op_t    ex_priv_op,
    input  logic        ex_priv_uses_imm,
    input  priv_cmd_t   ex_priv_cmd,
    input  logic [PRIV_ADDR_W-1:0] ex_priv_addr,
    input  logic [ 4:0] ex_priv_imm,
    input  logic        timer_irq_pending,
    input  logic        timer_irq_take,
    input  logic [31:0] timer_irq_mepc,
    output logic        ex_priv_flow,
    output logic        ex_priv_redirect,
    output logic [31:0] ex_priv_target,
    output logic        timer_irq_request,
    output logic        timer_irq_redirect,
    output logic [31:0] timer_irq_target,
    output logic [31:0] ex_priv_rdata
);
    loongarch_priv_unit u_impl (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ex_valid             (ex_valid),
        .ex_ready_go          (ex_ready_go),
        .mem_allowin          (mem_allowin),
        .mem_branch_flush     (mem_branch_flush),
        .ex_redirect_fire     (ex_redirect_fire),
        .ex_pc                (ex_pc),
        .ex_src0_data         (ex_src0_data),
        .ex_priv_op           (ex_priv_op),
        .ex_priv_uses_imm     (ex_priv_uses_imm),
        .ex_priv_cmd          (ex_priv_cmd),
        .ex_priv_addr         (ex_priv_addr),
        .ex_priv_imm          (ex_priv_imm),
        .timer_irq_pending    (timer_irq_pending),
        .timer_irq_take       (timer_irq_take),
        .timer_irq_mepc       (timer_irq_mepc),
        .ex_priv_flow         (ex_priv_flow),
        .ex_priv_redirect     (ex_priv_redirect),
        .ex_priv_target       (ex_priv_target),
        .timer_irq_request    (timer_irq_request),
        .timer_irq_redirect   (timer_irq_redirect),
        .timer_irq_target     (timer_irq_target),
        .ex_priv_rdata        (ex_priv_rdata)
    );
endmodule
