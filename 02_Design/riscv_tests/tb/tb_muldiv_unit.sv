`timescale 1ns / 1ps

module tb_muldiv_unit;
    import cpu_defs::*;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        mul_prestart_valid = 1'b0;
    logic [ 2:0] mul_prestart_op = 3'd0;
    logic [31:0] mul_prestart_rs1 = 32'd0;
    logic [31:0] mul_prestart_rs2 = 32'd0;
    logic        req_valid = 1'b0;
    logic [ 2:0] req_op = 3'd0;
    logic [31:0] req_rs1 = 32'd0;
    logic [31:0] req_rs2 = 32'd0;
    logic        consume = 1'b0;
    logic        flush = 1'b0;
    wire         busy;
    wire         done;
    wire [31:0]  result;

    integer cases = 0;
    integer seed = 32'h4d44_4956;

    always #5 clk = ~clk;

    muldiv_unit dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .mul_prestart_valid (mul_prestart_valid),
        .mul_prestart_op    (mul_prestart_op),
        .mul_prestart_rs1   (mul_prestart_rs1),
        .mul_prestart_rs2   (mul_prestart_rs2),
        .req_valid          (req_valid),
        .req_op             (req_op),
        .req_div_rs1        (req_rs1),
        .req_div_rs2        (req_rs2),
        .consume            (consume),
        .flush              (flush),
        .busy               (busy),
        .done               (done),
        .result             (result)
    );

    function automatic logic [31:0] expected_result (
        input logic [ 2:0] op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic signed [32:0] mul_a;
        logic signed [32:0] mul_b;
        logic signed [65:0] product;
        logic signed [31:0] signed_a;
        logic signed [31:0] signed_b;
        begin
            mul_a = {
                ((op == M_OP_MULH) | (op == M_OP_MULHSU)) ? a[31] : 1'b0,
                a
            };
            mul_b = {(op == M_OP_MULH) ? b[31] : 1'b0, b};
            product = mul_a * mul_b;
            signed_a = a;
            signed_b = b;

            case (op)
                M_OP_MUL:    expected_result = product[31:0];
                M_OP_MULH,
                M_OP_MULHSU,
                M_OP_MULHU:  expected_result = product[63:32];
                M_OP_DIV: begin
                    if (b == 0)
                        expected_result = 32'hffff_ffff;
                    else if ((a == 32'h8000_0000)
                             && (b == 32'hffff_ffff))
                        expected_result = 32'h8000_0000;
                    else
                        expected_result = signed_a / signed_b;
                end
                M_OP_DIVU:
                    expected_result = (b == 0) ? 32'hffff_ffff : a / b;
                M_OP_REM: begin
                    if (b == 0)
                        expected_result = a;
                    else if ((a == 32'h8000_0000)
                             && (b == 32'hffff_ffff))
                        expected_result = 32'd0;
                    else
                        expected_result = signed_a % signed_b;
                end
                M_OP_REMU:
                    expected_result = (b == 0) ? a : a % b;
                default:
                    expected_result = 32'd0;
            endcase
        end
    endfunction

    task automatic wait_and_check (
        input logic [ 2:0] op,
        input logic [31:0] a,
        input logic [31:0] b,
        output integer wait_cycles
    );
        logic [31:0] expected;
        begin
            expected = expected_result(op, a, b);
            wait_cycles = 0;
            while (!done && (wait_cycles < 24)) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (!done) begin
                $error("timeout op=%0d a=%08x b=%08x", op, a, b);
                $fatal(1);
            end
            if (result !== expected) begin
                $error("mismatch op=%0d a=%08x b=%08x got=%08x expected=%08x",
                       op, a, b, result, expected);
                $fatal(1);
            end
        end
    endtask

    task automatic start_mul (
        input logic [ 2:0] op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            @(negedge clk);
            mul_prestart_valid = 1'b1;
            mul_prestart_op = op;
            mul_prestart_rs1 = a;
            mul_prestart_rs2 = b;
            req_valid = 1'b0;
            consume = 1'b0;
            flush = 1'b0;

            // After this edge the local DSP inputs and S_MUL_EXEC owner are
            // registered; the matching EX request appears for the next edge.
            @(negedge clk);
            mul_prestart_valid = 1'b0;
            req_op = op;
            req_rs1 = a;
            req_rs2 = b;
            req_valid = 1'b1;
        end
    endtask

    task automatic consume_and_idle;
        begin
            consume = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;
            consume = 1'b0;
            mul_prestart_valid = 1'b0;
            if (busy || done) begin
                $error("consume did not return MulDiv unit to idle");
                $fatal(1);
            end
        end
    endtask

    task automatic run_case (
        input logic [ 2:0] op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        integer wait_cycles;
        begin
            if (!op[2]) begin
                start_mul(op, a, b);
                wait_and_check(op, a, b, wait_cycles);
                if (wait_cycles != 1) begin
                    $error("prestarted MUL EX-wait latency changed: op=%0d cycles=%0d",
                           op, wait_cycles);
                    $fatal(1);
                end
            end else begin
                @(negedge clk);
                mul_prestart_valid = 1'b0;
                req_op = op;
                req_rs1 = a;
                req_rs2 = b;
                req_valid = 1'b1;
                consume = 1'b0;
                flush = 1'b0;
                wait_and_check(op, a, b, wait_cycles);
            end

            consume_and_idle();
            cases = cases + 1;
        end
    endtask

    task automatic run_operand_set (
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            for (int op = 0; op < 8; op++)
                run_case(op[2:0], a, b);
        end
    endtask

    task automatic run_mul_turnover (
        input logic [ 2:0] first_op,
        input logic [31:0] first_a,
        input logic [31:0] first_b,
        input logic [ 2:0] second_op,
        input logic [31:0] second_a,
        input logic [31:0] second_b
    );
        integer wait_cycles;
        begin
            start_mul(first_op, first_a, first_b);
            wait_and_check(first_op, first_a, first_b, wait_cycles);
            if (wait_cycles != 1) begin
                $error("first turnover MUL latency=%0d", wait_cycles);
                $fatal(1);
            end

            // Consume the old EX owner and prestart the younger MUL on the
            // same edge. Keep req_op naming the old owner until the edge passes.
            mul_prestart_valid = 1'b1;
            mul_prestart_op = second_op;
            mul_prestart_rs1 = second_a;
            mul_prestart_rs2 = second_b;
            consume = 1'b1;
            @(negedge clk);
            mul_prestart_valid = 1'b0;
            consume = 1'b0;
            req_op = second_op;
            req_rs1 = second_a;
            req_rs2 = second_b;
            req_valid = 1'b1;

            wait_and_check(second_op, second_a, second_b, wait_cycles);
            if (wait_cycles != 1) begin
                $error("second turnover MUL latency=%0d", wait_cycles);
                $fatal(1);
            end

            consume_and_idle();
            cases = cases + 2;
        end
    endtask

    task automatic run_mul_done_hold;
        logic [31:0] expected;
        integer wait_cycles;
        begin
            expected = expected_result(M_OP_MULHU,
                                       32'hffff_ffff, 32'hffff_ffff);
            start_mul(M_OP_MULHU, 32'hffff_ffff, 32'hffff_ffff);
            wait_and_check(M_OP_MULHU,
                           32'hffff_ffff, 32'hffff_ffff, wait_cycles);

            // Deliberately overwrite the free-running local input payload with
            // unrelated values. The locally enabled product register must hold
            // the completed architectural result while MEM is blocked.
            repeat (3) begin
                mul_prestart_valid = 1'b0;
                mul_prestart_op = M_OP_MUL;
                mul_prestart_rs1 = $urandom(seed);
                mul_prestart_rs2 = $urandom(seed);
                @(negedge clk);
                if (!done || busy || (result !== expected)) begin
                    $error("held MUL result changed with free-running inputs");
                    $fatal(1);
                end
            end

            consume_and_idle();
            cases = cases + 1;
        end
    endtask

    task automatic run_div_to_mul_turnover;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_op = M_OP_DIVU;
            req_rs1 = 32'd100;
            req_rs2 = 32'd7;
            req_valid = 1'b1;
            consume = 1'b0;
            wait_and_check(M_OP_DIVU, 32'd100, 32'd7, wait_cycles);

            mul_prestart_valid = 1'b1;
            mul_prestart_op = M_OP_MUL;
            mul_prestart_rs1 = result;
            mul_prestart_rs2 = 32'd3;
            consume = 1'b1;
            @(negedge clk);
            mul_prestart_valid = 1'b0;
            consume = 1'b0;
            req_op = M_OP_MUL;
            req_rs1 = 32'd14;
            req_rs2 = 32'd3;
            req_valid = 1'b1;

            wait_and_check(M_OP_MUL, 32'd14, 32'd3, wait_cycles);
            if (wait_cycles != 1) begin
                $error("DIV-to-MUL turnover latency=%0d", wait_cycles);
                $fatal(1);
            end

            consume_and_idle();
            cases = cases + 2;
        end
    endtask

    task automatic run_mul_to_div_turnover;
        integer wait_cycles;
        begin
            start_mul(M_OP_MUL, 32'd9, 32'd11);
            wait_and_check(M_OP_MUL, 32'd9, 32'd11, wait_cycles);

            // The younger DIV has no prestart. The old done owner must clear
            // to idle on consume so its result cannot be mistaken for the DIV.
            consume = 1'b1;
            @(negedge clk);
            consume = 1'b0;
            req_op = M_OP_DIVU;
            req_rs1 = 32'd1000;
            req_rs2 = 32'd9;
            req_valid = 1'b1;
            wait_and_check(M_OP_DIVU, 32'd1000, 32'd9, wait_cycles);

            consume_and_idle();
            cases = cases + 2;
        end
    endtask

    task automatic run_div_to_div_turnover;
        integer wait_cycles;
        begin
            @(negedge clk);
            req_op = M_OP_REMU;
            req_rs1 = 32'd1000;
            req_rs2 = 32'd33;
            req_valid = 1'b1;
            consume = 1'b0;
            wait_and_check(M_OP_REMU, 32'd1000, 32'd33, wait_cycles);

            consume = 1'b1;
            @(negedge clk);
            consume = 1'b0;
            req_op = M_OP_DIV;
            req_rs1 = 32'hffff_ff9c;
            req_rs2 = 32'd7;
            req_valid = 1'b1;
            wait_and_check(M_OP_DIV, 32'hffff_ff9c, 32'd7, wait_cycles);

            consume_and_idle();
            cases = cases + 2;
        end
    endtask

    task automatic flush_mul_at_prestart;
        begin
            @(negedge clk);
            mul_prestart_valid = 1'b1;
            mul_prestart_op = M_OP_MUL;
            mul_prestart_rs1 = 32'h1234_5678;
            mul_prestart_rs2 = 32'h0000_1000;
            req_valid = 1'b0;
            consume = 1'b0;
            flush = 1'b1;

            @(negedge clk);
            mul_prestart_valid = 1'b0;
            flush = 1'b0;
            if (busy || done) begin
                $error("flush did not cancel MUL on its prestart edge");
                $fatal(1);
            end
        end
    endtask

    task automatic flush_mul_at_exec;
        begin
            @(negedge clk);
            mul_prestart_valid = 1'b1;
            mul_prestart_op = M_OP_MUL;
            mul_prestart_rs1 = 32'd37;
            mul_prestart_rs2 = 32'd41;
            req_valid = 1'b0;
            consume = 1'b0;

            @(negedge clk);
            mul_prestart_valid = 1'b0;
            req_op = M_OP_MUL;
            req_valid = 1'b1;
            flush = 1'b1;

            @(negedge clk);
            flush = 1'b0;
            req_valid = 1'b0;
            if (busy || done) begin
                $error("flush did not cancel executing MUL");
                $fatal(1);
            end
        end
    endtask

    task automatic flush_completed_mul;
        integer wait_cycles;
        begin
            start_mul(M_OP_MUL, 32'd37, 32'd41);
            wait_and_check(M_OP_MUL, 32'd37, 32'd41, wait_cycles);

            flush = 1'b1;
            @(negedge clk);
            flush = 1'b0;
            req_valid = 1'b0;
            if (busy || done) begin
                $error("flush did not discard completed MUL");
                $fatal(1);
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        run_operand_set(32'd0, 32'd0);
        run_operand_set(32'd1, 32'd1);
        run_operand_set(32'hffff_ffff, 32'hffff_ffff);
        run_operand_set(32'h8000_0000, 32'hffff_ffff);
        run_operand_set(32'h8000_0000, 32'd1);
        run_operand_set(32'h7fff_ffff, 32'h8000_0000);
        run_operand_set(32'hffff_ffff, 32'd2);
        run_operand_set(32'h8000_0001, 32'h7fff_ffff);

        // Exercise sign extension and carries around DSP limb boundaries.
        run_operand_set(32'h0001_ffff, 32'h0002_0000);
        run_operand_set(32'h0002_0001, 32'h0001_ffff);
        run_operand_set(32'hfffe_0000, 32'h0001_ffff);
        run_operand_set(32'h8001_ffff, 32'hfffe_0001);

        run_mul_turnover(M_OP_MUL, 32'd6, 32'd7,
                         M_OP_MUL, 32'd42, 32'd5);
        run_mul_turnover(M_OP_MULH, 32'h8000_0000, 32'd2,
                         M_OP_MULHU, 32'hffff_ffff, 32'hffff_ffff);
        run_mul_done_hold();
        run_div_to_mul_turnover();
        run_mul_to_div_turnover();
        run_div_to_div_turnover();
        flush_mul_at_prestart();
        run_case(M_OP_MUL, 32'h1234_5678, 32'h0000_1000);
        flush_mul_at_exec();
        run_case(M_OP_MUL, 32'd37, 32'd41);
        flush_completed_mul();
        run_case(M_OP_MUL, 32'd37, 32'd41);

        for (int n = 0; n < 1000; n++)
            run_operand_set($urandom(seed), $urandom(seed));

        // Abort an in-flight divide and verify that the next request is clean.
        @(negedge clk);
        req_op = M_OP_DIVU;
        req_rs1 = 32'hfedc_ba98;
        req_rs2 = 32'h0000_0123;
        req_valid = 1'b1;
        repeat (4) @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        req_valid = 1'b0;
        if (busy || done) begin
            $error("flush did not return MulDiv unit to idle");
            $fatal(1);
        end
        run_case(M_OP_DIVU, 32'hfedc_ba98, 32'h0000_0123);

        $display("[PASS] muldiv unit randomized test (%0d cases)", cases);
        $finish;
    end
endmodule
