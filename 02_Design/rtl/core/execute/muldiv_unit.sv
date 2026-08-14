// ============================================================
// 中文说明：执行 32 位乘法、除法和取余运算，并报告运算是否完成。
// 下面的寄存器和组合逻辑保持现有时序与握手约定；本文件只描述该模块的职责。
// 模块：muldiv_unit
// 说明：执行整数乘法、除法和取余的多周期单元。
// 所属阶段：execute。
//   - MUL/MULH/MULHSU/MULHU 使用能够映射到 DSP 的流水乘法器。
//   - DIV/DIVU/REM/REMU 使用小型 radix-4 迭代除法器。
// ============================================================

module muldiv_unit
    import cpu_defs::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // MUL 在被接收到 ID/EX 的同一个时钟沿启动。宽操作数进入持续运行的
    // 本地输入寄存器；prestart_valid 只建立单元所有权，不控制这些 payload 寄存器。
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

    typedef logic [5:0] state_t;
    localparam state_t S_IDLE       = 6'b00_0001;
    localparam state_t S_MUL_EXEC   = 6'b00_0010;
    localparam state_t S_MUL_DONE   = 6'b00_0100;
    localparam state_t S_DIV_RUN    = 6'b00_1000;
    localparam state_t S_DIV_FINISH = 6'b01_0000;
    localparam state_t S_DONE       = 6'b10_0000;

    // 将本地 FSM 的反馈接到 D 输入。若抽取共享 CE，远端 EX/MEM 的消费条件
    // 会驱动全部六个 one-hot 状态触发器；显式 D 输入功能等价，并可避开较慢的
    // CE 建立时间路径。
    (* fsm_encoding = "none", extract_enable = "no" *) state_t state;
    state_t state_next;

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

    // op[2] 将乘法器类别与 DIV/REM 类别区分开。
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

    // 除法过程使用绝对值，符号只在最终结果阶段处理。
    wire [31:0] req_abs_rs1 = (req_is_signed_div & req_div_rs1[31]) ? (~req_div_rs1 + 32'd1) : req_div_rs1;
    wire [31:0] req_abs_rs2 = (req_is_signed_div & req_div_rs2[31]) ? (~req_div_rs2 + 32'd1) : req_div_rs2;
    wire        req_div_by_zero = (req_div_rs2 == 32'd0);
    wire        req_div_overflow = req_is_signed_div
                                 & (req_div_rs1 == 32'h8000_0000)
                                 & (req_div_rs2 == 32'hffff_ffff);
    wire [31:0] req_special_result = req_div_by_zero ? (req_is_rem ? req_div_rs1 : 32'hffff_ffff) :
                                     req_div_overflow ? (req_is_rem ? 32'd0 : 32'h8000_0000) :
                                                        32'd0;
    // 以前的快速小于比较会等待两个条件取反进位链，然后再经过第二个 32 位
    // 绝对值比较器。现在直接比较原始操作数：同号的有符号绝对值使用原始顺序
    // （负数时反转顺序），异号时只需一个扩展加法结果。所有候选项并行生成，
    // 最后再根据有无符号及符号位选择。
    wire        req_raw_unsigned_lt = req_div_rs1 < req_div_rs2;
    wire        req_raw_unsigned_gt = req_div_rs1 > req_div_rs2;
    wire        req_div_signs_equal = req_div_rs1[31] == req_div_rs2[31];
    wire signed [32:0] req_div_signed_sum =
        $signed({req_div_rs1[31], req_div_rs1})
      + $signed({req_div_rs2[31], req_div_rs2});
    wire        req_div_mixed_pos_neg_lt = req_div_signed_sum[32];
    wire        req_div_mixed_neg_pos_lt = ~req_div_signed_sum[32]
                                               & (|req_div_signed_sum[31:0]);
    wire        req_signed_abs_lt_same_sign = req_div_rs1[31]
                                                ? req_raw_unsigned_gt
                                                : req_raw_unsigned_lt;
    wire        req_signed_abs_lt_mixed_sign = req_div_rs1[31]
                                                ? req_div_mixed_neg_pos_lt
                                                : req_div_mixed_pos_neg_lt;
    wire        req_signed_abs_lt = req_div_signs_equal
                                  ? req_signed_abs_lt_same_sign
                                  : req_signed_abs_lt_mixed_sign;
    wire        req_div_fast_lt = req_is_signed_div
                                ? req_signed_abs_lt
                                : req_raw_unsigned_lt;
    // abs(divisor)==1 可以直接由原始操作数译码得到。
    // 将绝对值取反进位链移出 FSM 的下一状态组合逻辑，不改变快速除法的
    // 适用条件和延迟，同时消除报告中的 ID/EX -> state 路径。
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
    // radix-4 每周期消耗两个商位，方法是把移位后的余数分别与
    // 1 倍、2 倍、3 倍除数候选值比较。
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
    // 符号修正特意基于已经寄存的最终绝对值。
    // 它在最后一次 radix-4 减法之后的 S_DIV_FINISH 中执行，因此同一条时序
    // 路径不会串接两个 32 位进位链。
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

    // payload 与 valid 刻意分离。下面的有符号操作数每个时钟沿都更新，
    // 即使当前 ID 流量不是 MUL 也一样；除非 mul_prestart_valid 更新了较窄的
    // 状态和操作所有权，否则无效或推测数据会被忽略。
    // 这些寄存器不使用复位或 CE，Vivado 可以把它们放在 DSP A/B 输入附近，
    // 避免把 cache-ready 控制信号布到 66 个数据位。
    always_ff @(posedge clk) begin
        mul_a_pipe <= mul_prestart_a;
        mul_b_pipe <= mul_prestart_b;
    end

    // 只有在已寄存的 MUL 所有者执行期间才捕获乘积。
    // 这个由本地状态产生的 CE 可在任意 MEM 反压期间保持完成结果稳定，
    // 同时不依赖同周期消费信号。
    always_ff @(posedge clk) begin
        if (state == S_MUL_EXEC)
            mul_product_r <= mul_product_w;
    end

    // 除法器 payload 只由已寄存的本地状态和 EX 持有的除法请求控制。
    // flush/consume 通过 FSM 使其失效，不直接控制这些宽寄存器。
    always_ff @(posedge clk) begin
        if ((state == S_IDLE) && req_valid && req_op[2]) begin
            // 总是预装迭代除法所需的 payload。快速/特殊除法会忽略它，
            // 但把它们的末级比较移出写使能路径可以保持较浅的 CE 路径。
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
            // 16 次 radix-4 迭代即可生成全部 32 个商位。
            div_remainder <= div_rem_next;
            div_quotient  <= div_quot_next;
            div_count     <= div_count - 6'd1;
        end
    end

    // 让架构上保存的 DIV 结果与 MUL 启动和交接相互独立。
    // 如果放在同一个 FSM 进程中，即使乘法器从不写 result_r，mul_prestart_valid
    // 也会变成 32 个结果位的远端时钟使能输入。flush 会使所有者状态失效，
    // 因此旧 payload 不可见，不需要额外的末级清零输入。
    always_ff @(posedge clk) begin
        if ((state == S_IDLE) && req_valid && req_op[2]) begin
            if (req_div_by_zero | req_div_overflow)
                result_r <= req_special_result;
            else if (req_div_fast_valid)
                result_r <= req_div_fast_result;
        end else if (state == S_DIV_FINISH) begin
            result_r <= op_r[1] ? div_rem_signed : div_quot_signed;
        end
    end

    // 只有较窄的所有权/控制逻辑接收 launch、consume、flush。
    // 同一时钟沿上，年轻的 MUL 预启动优先于释放已经完成的旧所有者。
    // 每个状态位每周期都得到一个 D 值，从而把远端 consume/allowin 逻辑锥
    // 与较慢的 slice CE 建立时间路径隔离开。
    always_comb begin
        state_next = S_IDLE;

        case (state)
            S_IDLE: begin
                state_next = S_IDLE;
                if (mul_prestart_valid) begin
                    state_next = S_MUL_EXEC;
                end else if (req_valid && req_op[2]) begin
                    if (req_div_by_zero | req_div_overflow
                            | req_div_fast_valid)
                        state_next = S_DONE;
                    else
                        state_next = S_DIV_RUN;
                end
            end

            S_MUL_EXEC: begin
                // mul_product_r 在此时钟沿捕获本地输入寄存器的乘积，
                // 随后在整个 S_MUL_DONE 状态期间保持可见。
                state_next = S_MUL_DONE;
            end

            S_MUL_DONE: begin
                state_next = S_MUL_DONE;
                if (mul_prestart_valid)
                    state_next = S_MUL_EXEC;
                else if (consume)
                    state_next = S_IDLE;
            end

            S_DIV_RUN: begin
                state_next = (div_count == 6'd1)
                           ? S_DIV_FINISH
                           : S_DIV_RUN;
            end

            S_DIV_FINISH: begin
                state_next = S_DONE;
            end

            S_DONE: begin
                state_next = S_DONE;
                if (mul_prestart_valid)
                    state_next = S_MUL_EXEC;
                else if (consume)
                    state_next = S_IDLE;
            end

            default: begin
                state_next = S_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n || flush)
            state <= S_IDLE;
        else
            state <= state_next;
    end

    // op_r 是由 FSM 所有的 payload。启动时先建立它，再允许 MUL 或 DIV
    // 结果选择器观察；flush 只使状态失效。
    always_ff @(posedge clk) begin
        if (mul_prestart_valid
            && ((state == S_IDLE) || (state == S_MUL_DONE)
                                  || (state == S_DONE)))
            op_r <= mul_prestart_op;
        else if ((state == S_IDLE) && req_valid && req_op[2])
            op_r <= req_op;
    end

`ifndef SYNTHESIS
    wire req_div_fast_one_reference = req_abs_rs2 == 32'd1;
    wire req_div_fast_lt_reference = req_abs_rs1 < req_abs_rs2;

    // 顺序执行且只有一个 EX 的流水线保证：每条 MUL 都在进入 ID/EX 的时钟沿
    // 预启动，且只有旧的完成所有者被消费时才会发生交接。
    // 这些设计假设不进入综合时序逻辑。
    always_ff @(posedge clk) begin
        if (rst_n && !flush) begin
            if ((state == S_IDLE) && req_valid && req_op[2]
                    && (req_div_fast_one !== req_div_fast_one_reference))
                $fatal(1, "Direct divide-by-one decode disagrees with abs reference");
            if ((state == S_IDLE) && req_valid && req_op[2]
                    && (req_div_fast_lt !== req_div_fast_lt_reference))
                $fatal(1, "Parallel magnitude compare disagrees with abs reference");
            if (mul_prestart_valid
                    && (mul_prestart_op[2]
                        || !((state == S_IDLE)
                             || (((state == S_MUL_DONE) || (state == S_DONE))
                                 && consume))))
                $fatal(1,
                    "Invalid or unserviceable MUL prestart: state=%0d consume=%0b op=%0d",
                    state, consume, mul_prestart_op);
            if ((state == S_IDLE) && req_valid && !req_op[2]
                    && !mul_prestart_valid)
                $fatal(1, "EX MUL reached idle unit without ID prestart");
            if ((state == S_MUL_EXEC)
                    && !(req_valid && !req_op[2]))
                $fatal(1, "Prestarted MUL has no matching EX owner");
                // 已完成的 MUL 由 MEM 而不是 EX 持有。顶层 token 断言会检查这次
                // 会合；本单元刻意不依赖流水线 payload 寄存器。
        end
    end
`endif

endmodule
