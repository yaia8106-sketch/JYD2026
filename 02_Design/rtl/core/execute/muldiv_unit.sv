// ============================================================
// Module: muldiv_unit
// Description: ISA-neutral integer multiply/divide execution unit.
// Domain: execute.
//   - MUL/MULH/MULHSU/MULHU use a pipelined DSP-inferred multiplier.
//   - DIV/DIVU/REM/REMU use a small radix-4 iterative divider.
// ============================================================

module muldiv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // A MUL launches on the same edge that accepts it into ID/EX. The wide
    // operands feed free-running local input registers; prestart_valid only
    // establishes ownership and never gates those payload registers.
    input  logic        mul_prestart_valid,
    input  muldiv_op_t  mul_prestart_op,
    input  logic [31:0] mul_prestart_rs1,
    input  logic [31:0] mul_prestart_rs2,

    input  logic        req_valid,
    input  muldiv_op_t  req_op,
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
        S_DIV_FINISH,
        S_DONE
    } state_t;

    state_t state;

    muldiv_op_t op_r;
    logic signed [32:0] mul_a_pipe;
    logic signed [32:0] mul_b_pipe;
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

    // op[2] separates the multiplier family from DIV/REM operations.
    wire req_is_rem = req_op[1];
    wire req_is_signed_div = (req_op == MULDIV_DIV) | (req_op == MULDIV_REM);

    wire mul_prestart_signed_a = (mul_prestart_op == MULDIV_MULH)
                               | (mul_prestart_op == MULDIV_MULHSU);
    wire mul_prestart_signed_b = (mul_prestart_op == MULDIV_MULH);
    wire signed [32:0] mul_prestart_a = {
        mul_prestart_signed_a & mul_prestart_rs1[31], mul_prestart_rs1
    };
    wire signed [32:0] mul_prestart_b = {
        mul_prestart_signed_b & mul_prestart_rs2[31], mul_prestart_rs2
    };
    (* use_dsp = "yes" *) wire signed [65:0] mul_product_w =
        mul_a_pipe * mul_b_pipe;

    // Division runs on magnitudes and applies signs only to the final result.
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
    // abs(divisor)==1 can be decoded directly from the original operand.
    // Keeping the absolute-value carry chain out of the FSM next-state cone
    // removes the reported ID/EX -> state path without changing fast-DIV
    // eligibility or latency.
    wire        req_div_fast_one = (req_div_rs2 == 32'd1)
                                 | (req_is_signed_div
                                    & (req_div_rs2 == 32'hffff_ffff));
    wire        req_div_fast_valid = req_op[2]
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
    // The radix-4 step consumes two quotient bits per cycle by comparing the
    // shifted remainder against 1x/2x/3x divisor candidates.
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
    // Sign correction is intentionally based on the registered final magnitude.
    // It runs in S_DIV_FINISH, one cycle after the last radix-4 subtract, so two
    // 32-bit carry chains are never serialized in one timing path.
    wire [31:0] div_quot_signed = div_quot_neg
                                ? (~div_quotient + 32'd1)
                                : div_quotient;
    wire [31:0] div_rem_signed = div_rem_neg
                               ? (~div_remainder[31:0] + 32'd1)
                               : div_remainder[31:0];

    function automatic logic [31:0] mul_result_select(
        input muldiv_op_t op,
        input logic signed [65:0] product
    );
        begin
            case (op)
                MULDIV_MUL:    mul_result_select = product[31:0];
                MULDIV_MULH:   mul_result_select = product[63:32];
                MULDIV_MULHSU: mul_result_select = product[63:32];
                MULDIV_MULHU:  mul_result_select = product[63:32];
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

    // Payload and validity are deliberately separated. These signed operands
    // update every edge, even for non-MUL ID traffic. Invalid/speculative data
    // is ignored unless mul_prestart_valid updates the narrow state/op owner.
    // With no reset or CE, Vivado can place/absorb these registers next to the
    // DSP A/B inputs without routing cache-ready control to 66 data bits.
    always_ff @(posedge clk) begin
        mul_a_pipe <= mul_prestart_a;
        mul_b_pipe <= mul_prestart_b;
    end

    // Capture one product only while a registered MUL owner is executing.
    // This local-state CE keeps the completed result stable across arbitrary
    // MEM backpressure while remaining independent of same-cycle consume.
    always_ff @(posedge clk) begin
        if (state == S_MUL_EXEC)
            mul_product_r <= mul_product_w;
    end

    // Divider payload updates depend only on the registered local state and
    // EX-owned divide request. Flush/consume invalidate it through the FSM;
    // they never gate these wide registers directly.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_divisor_1x_r <= 34'd0;
            div_divisor_2x_r <= 34'd0;
            div_divisor_3x_r <= 34'd0;
            div_remainder <= 33'd0;
            div_quotient  <= 32'd0;
            div_count     <= 6'd0;
            div_quot_neg  <= 1'b0;
            div_rem_neg   <= 1'b0;
        end else if ((state == S_IDLE) && req_valid && req_op[2]) begin
            // Always preload the iterative payload. Fast/special divides
            // ignore it, but keeping their late compares off the write enable
            // preserves a shallow CE path.
            div_divisor_1x_r <= req_divisor_1x;
            div_divisor_2x_r <= req_divisor_2x;
            div_divisor_3x_r <= req_divisor_3x;
            div_remainder <= 33'd0;
            div_quotient  <= req_abs_rs1;
            div_count     <= 6'd16;
            div_quot_neg  <= req_is_signed_div
                           & (req_div_rs1[31] ^ req_div_rs2[31]);
            div_rem_neg   <= req_is_signed_div & req_div_rs1[31];
        end else if (state == S_DIV_RUN) begin
            // Sixteen radix-4 iterations produce all 32 quotient bits.
            div_remainder <= div_rem_next;
            div_quotient  <= div_quot_next;
            div_count     <= div_count - 6'd1;
        end
    end

    // Keep the architecturally held DIV result independent from MUL launch and
    // turnover.  In the combined FSM process, mul_prestart_valid otherwise
    // became a remote clock-enable input on all 32 result bits even though a
    // multiplier never writes result_r. Flush invalidates the owner state, so
    // the stale payload is unobservable and does not need a late clear input.
    always_ff @(posedge clk) begin
        if (!rst_n)
            result_r <= 32'd0;
        else if ((state == S_IDLE) && req_valid && req_op[2]) begin
            if (req_div_by_zero | req_div_overflow)
                result_r <= req_special_result;
            else if (req_div_fast_valid)
                result_r <= req_div_fast_result;
        end else if (state == S_DIV_FINISH) begin
            result_r <= op_r[1] ? div_rem_signed : div_quot_signed;
        end
    end

    // Only narrow ownership/control sees launch/consume/flush. A same-edge
    // younger MUL prestart has priority over releasing the old completed owner.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            op_r     <= 3'd0;
        end else if (flush) begin
            state    <= S_IDLE;
            op_r     <= 3'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (mul_prestart_valid) begin
                        op_r <= mul_prestart_op;
                        state <= S_MUL_EXEC;
                    end else if (req_valid && req_op[2]) begin
                        op_r <= req_op;
                        if (req_div_by_zero | req_div_overflow) begin
                            state <= S_DONE;
                        end else if (req_div_fast_valid) begin
                            state <= S_DONE;
                        end else begin
                            state <= S_DIV_RUN;
                        end
                    end
                end

                S_MUL_EXEC: begin
                    // mul_product_r captures the local input-register product
                    // on this edge, then exposes it throughout S_MUL_DONE.
                    state <= S_MUL_DONE;
                end

                S_MUL_DONE: begin
                    if (mul_prestart_valid) begin
                        op_r <= mul_prestart_op;
                        state <= S_MUL_EXEC;
                    end else if (consume) begin
                        state <= S_IDLE;
                    end
                end

                S_DIV_RUN: begin
                    if (div_count == 6'd1)
                        state <= S_DIV_FINISH;
                end

                S_DIV_FINISH: begin
                    state <= S_DONE;
                end

                S_DONE: begin
                    if (mul_prestart_valid) begin
                        op_r <= mul_prestart_op;
                        state <= S_MUL_EXEC;
                    end else if (consume) begin
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    wire req_div_fast_one_reference = req_abs_rs2 == 32'd1;

    // The in-order single-EX pipeline guarantees every MUL was prestarted on
    // its ID/EX acceptance edge and that turnover can occur only while the old
    // done owner is consumed. Keep these assumptions out of synthesis timing.
    always_ff @(posedge clk) begin
        if (rst_n && !flush) begin
            if ((state == S_IDLE) && req_valid && req_op[2]
                    && (req_div_fast_one !== req_div_fast_one_reference))
                $fatal(1, "Direct divide-by-one decode disagrees with abs reference");
            if (mul_prestart_valid
                    && (mul_prestart_op[2]
                        || !((state == S_IDLE)
                             || (((state == S_MUL_DONE) || (state == S_DONE))
                                 && consume))))
                $fatal(1, "Invalid or unserviceable MUL prestart");
            if ((state == S_IDLE) && req_valid && !req_op[2]
                    && !mul_prestart_valid)
                $fatal(1, "EX MUL reached idle unit without ID prestart");
            if ((state == S_MUL_EXEC)
                    && !(req_valid && !req_op[2]))
                $fatal(1, "Prestarted MUL has no matching EX owner");
            // A completed MUL is owned by MEM rather than EX. Top-level token
            // assertions check that rendezvous because this unit intentionally
            // has no dependency on the pipeline payload registers.
        end
    end
`endif

endmodule
