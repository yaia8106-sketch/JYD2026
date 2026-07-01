// ============================================================
// Module: muldiv_unit
// Description: RV32M multi-cycle execution unit.
// Domain: execute.
//   - MUL/MULH/MULHSU/MULHU use a pipelined DSP-inferred multiplier.
//   - DIV/DIVU/REM/REMU use a small radix-2 iterative divider.
// ============================================================

module muldiv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req_valid,
    input  logic [ 2:0] req_op,
    input  logic [31:0] req_mul_rs1,
    input  logic [31:0] req_mul_rs2,
    input  logic [31:0] req_div_rs1,
    input  logic [31:0] req_div_rs2,
    input  logic        consume,
    input  logic        flush,

    output logic        busy,
    output logic        done,
    output logic [31:0] result
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_MUL_EXEC,
        S_MUL_DONE,
        S_DIV_RUN,
        S_DONE
    } state_t;

    state_t state;

    logic [ 2:0] op_r;
    logic signed [32:0] mul_a_r;
    logic signed [32:0] mul_b_r;
    (* use_dsp = "yes" *) logic signed [65:0] mul_product_r;
    logic [31:0] result_r;

    logic [33:0] div_divisor_1x_r;
    logic [33:0] div_divisor_2x_r;
    logic [33:0] div_divisor_3x_r;
    logic [32:0] div_remainder;
    logic [31:0] div_quotient;
    logic [ 5:0] div_count;
    logic        div_quot_neg;
    logic        div_rem_neg;

    wire req_is_mul = ~req_op[2];
    wire req_is_rem = req_op[1];
    wire req_is_signed_div = (req_op == M_OP_DIV) | (req_op == M_OP_REM);

    wire mul_signed_a = (req_op == M_OP_MULH) | (req_op == M_OP_MULHSU);
    wire mul_signed_b = (req_op == M_OP_MULH);
    wire signed [32:0] mul_a = {mul_signed_a & req_mul_rs1[31], req_mul_rs1};
    wire signed [32:0] mul_b = {mul_signed_b & req_mul_rs2[31], req_mul_rs2};
    (* use_dsp = "yes" *) wire signed [65:0] mul_product_w = mul_a_r * mul_b_r;

    wire [31:0] req_abs_rs1 = (req_is_signed_div & req_div_rs1[31]) ? (~req_div_rs1 + 32'd1) : req_div_rs1;
    wire [31:0] req_abs_rs2 = (req_is_signed_div & req_div_rs2[31]) ? (~req_div_rs2 + 32'd1) : req_div_rs2;
    wire        req_div_by_zero = (req_div_rs2 == 32'd0);
    wire        req_div_overflow = req_is_signed_div
                                 & (req_div_rs1 == 32'h8000_0000)
                                 & (req_div_rs2 == 32'hffff_ffff);
    wire [31:0] req_special_result = req_div_by_zero ? (req_is_rem ? req_div_rs1 : 32'hffff_ffff) :
                                     req_div_overflow ? (req_is_rem ? 32'd0 : 32'h8000_0000) :
                                                        32'd0;
    wire        req_div_fast_lt = (req_abs_rs1 < req_abs_rs2);
    wire        req_div_fast_one = (req_abs_rs2 == 32'd1);
    wire        req_div_fast_valid = ~req_is_mul
                                   & ~req_div_by_zero
                                   & ~req_div_overflow
                                   & (req_div_fast_lt | req_div_fast_one);
    wire [31:0] req_div_fast_quot_one = (req_is_signed_div
                                      & (req_div_rs1[31] ^ req_div_rs2[31]))
                                      ? (~req_abs_rs1 + 32'd1)
                                      : req_abs_rs1;
    wire [31:0] req_div_fast_quot = req_div_fast_one
                                  ? req_div_fast_quot_one
                                  : 32'd0;
    wire [31:0] req_div_fast_rem = req_div_fast_one
                                 ? 32'd0
                                 : req_div_rs1;
    wire [31:0] req_div_fast_result = req_is_rem
                                    ? req_div_fast_rem
                                    : req_div_fast_quot;

    wire [33:0] req_divisor_1x = {2'b00, req_abs_rs2};
    wire [33:0] req_divisor_2x = {1'b0, req_abs_rs2, 1'b0};
    wire [33:0] req_divisor_3x = req_divisor_1x + req_divisor_2x;
    wire [33:0] div_rem_shift = {div_remainder[31:0], div_quotient[31:30]};
    wire [34:0] div_rem_sub_1x = {1'b0, div_rem_shift} - {1'b0, div_divisor_1x_r};
    wire [34:0] div_rem_sub_2x = {1'b0, div_rem_shift} - {1'b0, div_divisor_2x_r};
    wire [34:0] div_rem_sub_3x = {1'b0, div_rem_shift} - {1'b0, div_divisor_3x_r};
    wire        div_ge_1x = ~div_rem_sub_1x[34];
    wire        div_ge_2x = ~div_rem_sub_2x[34];
    wire        div_ge_3x = ~div_rem_sub_3x[34];
    wire [ 1:0] div_quot_digit = div_ge_3x ? 2'd3 :
                                  div_ge_2x ? 2'd2 :
                                  div_ge_1x ? 2'd1 :
                                              2'd0;
    wire [33:0] div_rem_next_wide = div_ge_3x ? div_rem_sub_3x[33:0] :
                                     div_ge_2x ? div_rem_sub_2x[33:0] :
                                     div_ge_1x ? div_rem_sub_1x[33:0] :
                                                 div_rem_shift;
    wire [32:0] div_rem_next = div_rem_next_wide[32:0];
    wire [31:0] div_quot_next = {div_quotient[29:0], div_quot_digit};
    wire [31:0] div_quot_signed_next = div_quot_neg ? (~div_quot_next + 32'd1)
                                                     : div_quot_next;
    wire [31:0] div_rem_signed_next = div_rem_neg ? (~div_rem_next[31:0] + 32'd1)
                                                   : div_rem_next[31:0];

    function automatic logic [31:0] mul_result_select(
        input logic [2:0] op,
        input logic signed [65:0] product
    );
        begin
            case (op)
                M_OP_MUL:    mul_result_select = product[31:0];
                M_OP_MULH:   mul_result_select = product[63:32];
                M_OP_MULHSU: mul_result_select = product[63:32];
                M_OP_MULHU:  mul_result_select = product[63:32];
                default:     mul_result_select = product[31:0];
            endcase
        end
    endfunction

    wire        mul_done_w = (state == S_MUL_DONE);
    wire        done_w = (state == S_DONE) | mul_done_w;
    wire [31:0] mul_result_w = mul_result_select(op_r, mul_product_r);

    assign busy = (state != S_IDLE) & ~done_w;
    assign done = done_w;
    assign result = mul_done_w ? mul_result_w : result_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            op_r          <= 3'd0;
            mul_a_r       <= 33'd0;
            mul_b_r       <= 33'd0;
            mul_product_r <= '0;
            result_r      <= 32'd0;
            div_divisor_1x_r <= 34'd0;
            div_divisor_2x_r <= 34'd0;
            div_divisor_3x_r <= 34'd0;
            div_remainder <= 33'd0;
            div_quotient  <= 32'd0;
            div_count     <= 6'd0;
            div_quot_neg  <= 1'b0;
            div_rem_neg   <= 1'b0;
        end else if (flush) begin
            state         <= S_IDLE;
            op_r          <= 3'd0;
            mul_a_r       <= 33'd0;
            mul_b_r       <= 33'd0;
            result_r      <= 32'd0;
            div_count     <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        op_r <= req_op;
                        if (req_is_mul) begin
                            mul_a_r <= mul_a;
                            mul_b_r <= mul_b;
                            state <= S_MUL_EXEC;
                        end else begin
                            // Preload the iterative-divider payload for every
                            // divide request. Fast/special requests transition
                            // directly to S_DONE, so this payload is ignored;
                            // keeping its write enable independent of the late
                            // fast-path compare shortens the register CE path.
                            div_divisor_1x_r <= req_divisor_1x;
                            div_divisor_2x_r <= req_divisor_2x;
                            div_divisor_3x_r <= req_divisor_3x;
                            div_remainder <= 33'd0;
                            div_quotient  <= req_abs_rs1;
                            div_count     <= 6'd16;
                            div_quot_neg  <= req_is_signed_div & (req_div_rs1[31] ^ req_div_rs2[31]);
                            div_rem_neg   <= req_is_signed_div & req_div_rs1[31];

                            if (req_div_by_zero | req_div_overflow) begin
                                result_r <= req_special_result;
                                state <= S_DONE;
                            end else if (req_div_fast_valid) begin
                                result_r <= req_div_fast_result;
                                state <= S_DONE;
                            end else begin
                                state <= S_DIV_RUN;
                            end
                        end
                    end
                end

                S_MUL_EXEC: begin
                    mul_product_r <= mul_product_w;
                    state <= S_MUL_DONE;
                end

                S_MUL_DONE: begin
                    if (consume | !req_valid)
                        state <= S_IDLE;
                end

                S_DIV_RUN: begin
                    div_remainder <= div_rem_next;
                    div_quotient  <= div_quot_next;
                    div_count     <= div_count - 6'd1;
                    if (div_count == 6'd1) begin
                        result_r <= op_r[1] ? div_rem_signed_next : div_quot_signed_next;
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (consume | !req_valid)
                        state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
