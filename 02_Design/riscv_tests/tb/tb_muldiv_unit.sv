`timescale 1ns / 1ps

module tb_muldiv_unit;
    import cpu_defs::*;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
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
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (req_valid),
        .req_op     (req_op),
        .req_mul_rs1(req_rs1),
        .req_mul_rs2(req_rs2),
        .req_div_rs1(req_rs1),
        .req_div_rs2(req_rs2),
        .consume    (consume),
        .flush      (flush),
        .busy       (busy),
        .done       (done),
        .result     (result)
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
            mul_a = {(op == M_OP_MULH) | (op == M_OP_MULHSU) ? a[31] : 1'b0, a};
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
                    else if ((a == 32'h8000_0000) && (b == 32'hffff_ffff))
                        expected_result = 32'h8000_0000;
                    else
                        expected_result = signed_a / signed_b;
                end
                M_OP_DIVU:
                    expected_result = (b == 0) ? 32'hffff_ffff : a / b;
                M_OP_REM: begin
                    if (b == 0)
                        expected_result = a;
                    else if ((a == 32'h8000_0000) && (b == 32'hffff_ffff))
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

    task automatic run_case (
        input logic [ 2:0] op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic [31:0] expected;
        integer wait_cycles;
        begin
            expected = expected_result(op, a, b);
            @(negedge clk);
            req_op = op;
            req_rs1 = a;
            req_rs2 = b;
            req_valid = 1'b1;
            consume = 1'b0;

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

            consume = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;
            consume = 1'b0;
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

        // Exercise carries and signs exactly around the multiplier's 17-bit
        // low-limb boundary used by the parallel partial-product RTL.
        run_operand_set(32'h0001_ffff, 32'h0002_0000);
        run_operand_set(32'h0002_0001, 32'h0001_ffff);
        run_operand_set(32'hfffe_0000, 32'h0001_ffff);
        run_operand_set(32'h8001_ffff, 32'hfffe_0001);

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
            $error("flush did not return muldiv unit to idle");
            $fatal(1);
        end
        run_case(M_OP_DIVU, 32'hfedc_ba98, 32'h0000_0123);

        $display("[PASS] muldiv unit randomized test (%0d cases)", cases);
        $finish;
    end
endmodule
