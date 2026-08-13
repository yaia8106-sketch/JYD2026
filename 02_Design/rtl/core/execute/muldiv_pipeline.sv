// ============================================================
// Module: muldiv_pipeline
// Description: Own the MulDiv unit and its cross-stage result lifetime.
// Domain: execute and MEM handoff.
//
// Multiplication starts from an accepted ID instruction and advances through
// EX before the DSP result is ready. Division and remainder remain in EX until
// completion. This wrapper keeps those ownership rules beside the unit instead
// of spreading them across cpu_top.
// ============================================================

module muldiv_pipeline
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        id_mul_prestart,
    input  muldiv_op_t  id_muldiv_op,
    input  logic [31:0] id_mul_rs1,
    input  logic [31:0] id_mul_rs2,

    input  logic        ex_valid,
    input  logic        ex_is_muldiv,
    input  muldiv_op_t  ex_muldiv_op,
    input  logic [31:0] ex_div_rs1,
    input  logic [31:0] ex_div_rs2,
    input  logic        ex_to_mem_allowin,

    input  logic        mem_valid,
    input  logic        mem_is_mul,
    input  logic [31:0] mem_alu_result,
    input  logic        mem_ready,
    input  logic        wb_allowin,

    input  logic        frontend_flush,
    input  logic        mem_redirect_flush,

    output logic        busy,
    output logic        done,
    output logic [31:0] result,
    output logic        consume,
    output logic [31:0] mem_writeback_result
);

    logic ex_request;
    logic ex_div_consume;
    logic mem_mul_consume;
    logic flush;

    assign ex_request = ex_valid & ex_is_muldiv & ~mem_redirect_flush;

    // DIV/REM retain the EX owner until the result and EX/MEM handshakes are
    // both complete. A prestarted MUL releases its owner with the aligned MEM
    // token, after any older DCache transaction has finished.
    assign ex_div_consume = ex_valid & ex_is_muldiv & ex_muldiv_op[2]
                          & done & ex_to_mem_allowin
                          & ~mem_redirect_flush;
    assign mem_mul_consume = mem_valid & mem_is_mul
                           & mem_ready & wb_allowin;
    assign consume = ex_div_consume | mem_mul_consume;
    assign flush = frontend_flush | mem_redirect_flush;

    // A MUL token reaches MEM before its DSP result. The MEM/WB payload must
    // therefore select the registered MulDiv result rather than the early ALU
    // placeholder carried by EX/MEM.
    assign mem_writeback_result =
        ({32{mem_is_mul}}  & result)
      | ({32{~mem_is_mul}} & mem_alu_result);

    muldiv_unit u_muldiv_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        .mul_prestart_valid (id_mul_prestart),
        .mul_prestart_op    (id_muldiv_op),
        .mul_prestart_rs1   (id_mul_rs1),
        .mul_prestart_rs2   (id_mul_rs2),
        .req_valid          (ex_request),
        .req_op             (ex_muldiv_op),
        .req_div_rs1        (ex_div_rs1),
        .req_div_rs2        (ex_div_rs2),
        .consume            (consume),
        .flush              (flush),
        .busy               (busy),
        .done               (done),
        .result             (result)
    );

endmodule
