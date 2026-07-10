// ============================================================
// Module: bitmanip_unit
// Description: Single-request RV32 bit-manipulation execution controller.
// Domain: execute.
//   - Non-CLMUL operations first latch repaired operands, then register a
//     parallel-computed result in a separate execution cycle.
//   - CLMUL variants share a radix-4 (two multiplier bits/cycle) GF(2) unit.
// ============================================================

module bitmanip_unit
    import cpu_defs::*;
(
    input  logic         clk,
    input  logic         rst_n,
    input  logic         req_valid,
    input  bitmanip_op_t req_op,
    input  logic [31:0]  req_rs1,
    input  logic [31:0]  req_rs2,
    input  logic         consume,
    input  logic         flush,
    output logic         busy,
    output logic         done,
    output logic [31:0]  result
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_FAST_EXEC,
        S_CLMUL_RUN,
        S_DONE
    } state_t;

    state_t state;
    bitmanip_op_t op_r;
    logic [31:0] fast_rs1_r;
    logic [31:0] fast_rs2_r;
    logic [31:0] result_r;
    logic [63:0] clmul_accum_r;
    logic [63:0] clmul_multiplicand_r;
    logic [31:0] clmul_multiplier_r;
    logic [ 4:0] clmul_count_r;

    wire req_is_clmul = (req_op == BM_CLMUL)
                      | (req_op == BM_CLMULR)
                      | (req_op == BM_CLMULH);

    wire [31:0] fast_result;
    bitmanip_fast_unit u_bitmanip_fast_unit (
        .op    (op_r),
        .rs1   (fast_rs1_r),
        .rs2   (fast_rs2_r),
        .result(fast_result)
    );

    // Two GF(2) multiplier bits are accumulated per cycle. The independent
    // partial-product candidates are formed in parallel before the final XOR.
    wire [63:0] clmul_partial_0 =
        {64{clmul_multiplier_r[0]}} & clmul_multiplicand_r;
    wire [63:0] clmul_partial_1 =
        {64{clmul_multiplier_r[1]}} &
        {clmul_multiplicand_r[62:0], 1'b0};
    wire [63:0] clmul_accum_next = clmul_accum_r
                                  ^ clmul_partial_0
                                  ^ clmul_partial_1;

    function automatic logic [31:0] clmul_result_select(
        input bitmanip_op_t op,
        input logic [63:0] product
    );
        begin
            case (op)
                BM_CLMUL:  clmul_result_select = product[31:0];
                BM_CLMULR: clmul_result_select = product[62:31];
                BM_CLMULH: clmul_result_select = product[63:32];
                default:   clmul_result_select = 32'd0;
            endcase
        end
    endfunction

    assign busy = (state != S_IDLE) & (state != S_DONE);
    assign done = state == S_DONE;
    assign result = result_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                   <= S_IDLE;
            op_r                    <= BM_NONE;
            fast_rs1_r              <= 32'd0;
            fast_rs2_r              <= 32'd0;
            result_r                <= 32'd0;
            clmul_accum_r           <= 64'd0;
            clmul_multiplicand_r    <= 64'd0;
            clmul_multiplier_r      <= 32'd0;
            clmul_count_r           <= 5'd0;
        end else if (flush) begin
            // Once state returns to IDLE, every datapath register is
            // architecturally unobservable.  Keep flush off the wide operand,
            // result, and CLMUL register banks to avoid a global reset sink.
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        op_r <= req_op;
                        if (req_is_clmul) begin
                            clmul_accum_r        <= 64'd0;
                            clmul_multiplicand_r <= {32'd0, req_rs1};
                            clmul_multiplier_r   <= req_rs2;
                            clmul_count_r        <= 5'd16;
                            state                <= S_CLMUL_RUN;
                        end else begin
                            fast_rs1_r <= req_rs1;
                            fast_rs2_r <= req_rs2;
                            state      <= S_FAST_EXEC;
                        end
                    end
                end

                S_FAST_EXEC: begin
                    result_r <= fast_result;
                    state    <= S_DONE;
                end

                S_CLMUL_RUN: begin
                    clmul_accum_r        <= clmul_accum_next;
                    clmul_multiplicand_r <= clmul_multiplicand_r << 2;
                    clmul_multiplier_r   <= clmul_multiplier_r >> 2;
                    clmul_count_r        <= clmul_count_r - 5'd1;
                    if (clmul_count_r == 5'd1) begin
                        result_r <= clmul_result_select(op_r,
                                                       clmul_accum_next);
                        state <= S_DONE;
                    end
                end

                S_DONE: begin
                    if (consume | !req_valid)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
