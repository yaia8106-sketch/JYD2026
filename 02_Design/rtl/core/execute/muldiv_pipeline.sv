// ============================================================
// 中文说明：为乘法、除法和取余操作提供多周期流水控制及结果保存。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：muldiv_pipeline
// 说明：管理乘除法单元，以及结果在多个流水级之间的有效期。
// 所属阶段：execute，并负责交接到 MEM。
//
// 乘法指令在 ID 被接收后启动，经过 EX 后 DSP 结果才准备好；除法和取余
// 在结果完成前始终由 EX 持有。这个包装模块把这些所有权规则集中在单元旁边，
// 避免分散到 cpu_top 中。
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

    // DIV/REM 一直由 EX 持有，直到结果完成且 EX/MEM 握手都结束。
    // 预启动的 MUL 在对应 MEM token 对齐时释放所有权，但必须先等待更老的
    // DCache 事务结束。
    assign ex_div_consume = ex_valid & ex_is_muldiv & ex_muldiv_op[2]
                          & done & ex_to_mem_allowin
                          & ~mem_redirect_flush;
    assign mem_mul_consume = mem_valid & mem_is_mul
                           & mem_ready & wb_allowin;
    assign consume = ex_div_consume | mem_mul_consume;
    assign flush = frontend_flush | mem_redirect_flush;

    // MUL 的 token 会先于 DSP 结果到达 MEM，因此 MEM/WB payload 必须选择
    // 已寄存的 MulDiv 结果，而不能选择 EX/MEM 中暂存的早期 ALU 占位结果。
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
