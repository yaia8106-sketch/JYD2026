`timescale 1ns / 1ps

module tb_bitmanip_unit;
    import cpu_defs::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic req_valid = 1'b0;
    bitmanip_op_t req_op = BM_NONE;
    logic [31:0] req_rs1 = 32'd0;
    logic [31:0] req_rs2 = 32'd0;
    logic consume = 1'b0;
    logic flush = 1'b0;
    wire busy;
    wire done;
    wire [31:0] result;

    logic [31:0] inst = 32'd0;
    wire is_bitmanip;
    bitmanip_op_t decoded_op;
    frontend_predecode_t frontend_decoded;

    integer cases = 0;
    integer decode_cases = 0;
    integer seed = 32'h4249_544d;

    always #5 clk = ~clk;

    bitmanip_decoder u_decoder (
        .inst        (inst),
        .is_bitmanip (is_bitmanip),
        .bitmanip_op (decoded_op)
    );

    frontend_predecode u_frontend_predecode (
        .inst   (inst),
        .decoded(frontend_decoded)
    );

    bitmanip_unit dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .req_valid(req_valid),
        .req_op   (req_op),
        .req_rs1  (req_rs1),
        .req_rs2  (req_rs2),
        .consume  (consume),
        .flush    (flush),
        .busy     (busy),
        .done     (done),
        .result   (result)
    );

    function automatic logic [31:0] make_r_inst(
        input logic [6:0] funct7,
        input logic [4:0] rs2,
        input logic [2:0] funct3
    );
        make_r_inst = {funct7, rs2, 5'd1, funct3, 5'd3, OP_R_TYPE};
    endfunction

    function automatic logic [31:0] make_i_inst(
        input logic [11:0] imm12,
        input logic [2:0] funct3
    );
        make_i_inst = {imm12, 5'd1, funct3, 5'd3, OP_I_ALU};
    endfunction

    task automatic check_decode(
        input logic [31:0] encoded,
        input bitmanip_op_t expected_op
    );
        begin
            inst = encoded;
            #1;
            if (!is_bitmanip || (decoded_op != expected_op)) begin
                $error("decode mismatch inst=%08x got_valid=%0d got_op=%0d expected_op=%0d",
                       encoded, is_bitmanip, decoded_op, expected_op);
                $fatal(1);
            end
            if (!frontend_decoded.force_single_slot0
                || !frontend_decoded.force_single_slot1) begin
                $error("B instruction was not forced single inst=%08x", encoded);
                $fatal(1);
            end
            decode_cases = decode_cases + 1;
        end
    endtask

    task automatic check_frontend_single_policy(
        input logic [31:0] encoded,
        input logic expected_force_single
    );
        begin
            inst = encoded;
            #1;
            if ((frontend_decoded.force_single_slot0
                 !== expected_force_single)
                || (frontend_decoded.force_single_slot1
                    !== expected_force_single)) begin
                $error("frontend single-issue mismatch inst=%08x got_s0=%0d got_s1=%0d expected=%0d",
                       encoded, frontend_decoded.force_single_slot0,
                       frontend_decoded.force_single_slot1,
                       expected_force_single);
                $fatal(1);
            end
        end
    endtask

    function automatic logic [31:0] ref_clz(input logic [31:0] value);
        integer i;
        logic found;
        begin
            ref_clz = 32'd32;
            found = 1'b0;
            for (i = 31; i >= 0; i = i - 1) begin
                if (!found && value[i]) begin
                    ref_clz = 31 - i;
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [31:0] ref_ctz(input logic [31:0] value);
        integer i;
        logic found;
        begin
            ref_ctz = 32'd32;
            found = 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                if (!found && value[i]) begin
                    ref_ctz = i;
                    found = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [31:0] ref_cpop(input logic [31:0] value);
        integer i;
        begin
            ref_cpop = 32'd0;
            for (i = 0; i < 32; i = i + 1)
                ref_cpop = ref_cpop + value[i];
        end
    endfunction

    function automatic logic [7:0] ref_reverse8(input logic [7:0] value);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1)
                ref_reverse8[i] = value[7-i];
        end
    endfunction

    function automatic logic [63:0] ref_clmul_full(
        input logic [31:0] a,
        input logic [31:0] b
    );
        integer i;
        begin
            ref_clmul_full = 64'd0;
            for (i = 0; i < 32; i = i + 1) begin
                if (b[i])
                    ref_clmul_full = ref_clmul_full ^ ({32'd0, a} << i);
            end
        end
    endfunction

    function automatic logic [31:0] ref_zip(input logic [31:0] value);
        integer i;
        begin
            ref_zip = 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                ref_zip[2*i] = value[i];
                ref_zip[2*i+1] = value[i+16];
            end
        end
    endfunction

    function automatic logic [31:0] ref_unzip(input logic [31:0] value);
        integer i;
        begin
            ref_unzip = 32'd0;
            for (i = 0; i < 16; i = i + 1) begin
                ref_unzip[i] = value[2*i];
                ref_unzip[i+16] = value[2*i+1];
            end
        end
    endfunction

    function automatic logic [31:0] ref_xperm4(
        input logic [31:0] data,
        input logic [31:0] indices
    );
        integer i;
        logic [3:0] index;
        begin
            ref_xperm4 = 32'd0;
            for (i = 0; i < 8; i = i + 1) begin
                index = indices[4*i +: 4];
                if (index < 8)
                    ref_xperm4[4*i +: 4] = data[4*index +: 4];
            end
        end
    endfunction

    function automatic logic [31:0] ref_xperm8(
        input logic [31:0] data,
        input logic [31:0] indices
    );
        integer i;
        logic [7:0] index;
        begin
            ref_xperm8 = 32'd0;
            for (i = 0; i < 4; i = i + 1) begin
                index = indices[8*i +: 8];
                if (index < 4)
                    ref_xperm8[8*i +: 8] = data[8*index +: 8];
            end
        end
    endfunction

    function automatic logic [31:0] expected_result(
        input bitmanip_op_t op,
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic [4:0] shamt;
        logic [4:0] inv_shamt;
        logic [31:0] mask;
        logic [63:0] product;
        begin
            shamt = b[4:0];
            inv_shamt = 5'd0 - shamt;
            mask = 32'b1 << shamt;
            product = ref_clmul_full(a, b);
            case (op)
                BM_SH1ADD: expected_result = (a << 1) + b;
                BM_SH2ADD: expected_result = (a << 2) + b;
                BM_SH3ADD: expected_result = (a << 3) + b;
                BM_ANDN: expected_result = a & ~b;
                BM_ORN: expected_result = a | ~b;
                BM_XNOR: expected_result = ~(a ^ b);
                BM_CLZ: expected_result = ref_clz(a);
                BM_CTZ: expected_result = ref_ctz(a);
                BM_CPOP: expected_result = ref_cpop(a);
                BM_MAX: expected_result = ($signed(a) < $signed(b)) ? b : a;
                BM_MAXU: expected_result = (a < b) ? b : a;
                BM_MIN: expected_result = ($signed(a) < $signed(b)) ? a : b;
                BM_MINU: expected_result = (a < b) ? a : b;
                BM_SEXT_B: expected_result = {{24{a[7]}}, a[7:0]};
                BM_SEXT_H: expected_result = {{16{a[15]}}, a[15:0]};
                BM_ZEXT_H: expected_result = {16'd0, a[15:0]};
                BM_ROL: expected_result = (a << shamt) | (a >> inv_shamt);
                BM_ROR: expected_result = (a >> shamt) | (a << inv_shamt);
                BM_ORC_B: expected_result = {
                    {8{|a[31:24]}}, {8{|a[23:16]}},
                    {8{|a[15:8]}}, {8{|a[7:0]}}
                };
                BM_REV8: expected_result = {a[7:0], a[15:8],
                                             a[23:16], a[31:24]};
                BM_CLMUL: expected_result = product[31:0];
                BM_CLMULR: expected_result = product[62:31];
                BM_CLMULH: expected_result = product[63:32];
                BM_BCLR: expected_result = a & ~mask;
                BM_BEXT: expected_result = {31'd0, a[shamt]};
                BM_BINV: expected_result = a ^ mask;
                BM_BSET: expected_result = a | mask;
                BM_PACK: expected_result = {b[15:0], a[15:0]};
                BM_PACKH: expected_result = {16'd0, b[7:0], a[7:0]};
                BM_BREV8: expected_result = {
                    ref_reverse8(a[31:24]), ref_reverse8(a[23:16]),
                    ref_reverse8(a[15:8]), ref_reverse8(a[7:0])
                };
                BM_ZIP: expected_result = ref_zip(a);
                BM_UNZIP: expected_result = ref_unzip(a);
                BM_XPERM4: expected_result = ref_xperm4(a, b);
                BM_XPERM8: expected_result = ref_xperm8(a, b);
                default: expected_result = 32'd0;
            endcase
        end
    endfunction

    task automatic run_case(
        input bitmanip_op_t op,
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

    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // All 39 RV32 architectural instruction encodings, including the
        // register/immediate forms that share one execution operation.
        check_decode(make_r_inst(7'h10, 5'd2, 3'b010), BM_SH1ADD);
        check_decode(make_r_inst(7'h10, 5'd2, 3'b100), BM_SH2ADD);
        check_decode(make_r_inst(7'h10, 5'd2, 3'b110), BM_SH3ADD);
        check_decode(make_r_inst(7'h20, 5'd2, 3'b111), BM_ANDN);
        check_decode(make_r_inst(7'h20, 5'd2, 3'b110), BM_ORN);
        check_decode(make_r_inst(7'h20, 5'd2, 3'b100), BM_XNOR);
        check_decode(make_i_inst(12'h600, 3'b001), BM_CLZ);
        check_decode(make_i_inst(12'h601, 3'b001), BM_CTZ);
        check_decode(make_i_inst(12'h602, 3'b001), BM_CPOP);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b110), BM_MAX);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b111), BM_MAXU);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b100), BM_MIN);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b101), BM_MINU);
        check_decode(make_i_inst(12'h604, 3'b001), BM_SEXT_B);
        check_decode(make_i_inst(12'h605, 3'b001), BM_SEXT_H);
        check_decode(make_r_inst(7'h04, 5'd0, 3'b100), BM_ZEXT_H);
        check_decode(make_r_inst(7'h30, 5'd2, 3'b001), BM_ROL);
        check_decode(make_r_inst(7'h30, 5'd2, 3'b101), BM_ROR);
        check_decode(make_i_inst(12'h607, 3'b101), BM_ROR);
        check_decode(make_i_inst(12'h287, 3'b101), BM_ORC_B);
        check_decode(make_i_inst(12'h698, 3'b101), BM_REV8);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b001), BM_CLMUL);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b010), BM_CLMULR);
        check_decode(make_r_inst(7'h05, 5'd2, 3'b011), BM_CLMULH);
        check_decode(make_r_inst(7'h24, 5'd2, 3'b001), BM_BCLR);
        check_decode(make_i_inst(12'h485, 3'b001), BM_BCLR);
        check_decode(make_r_inst(7'h24, 5'd2, 3'b101), BM_BEXT);
        check_decode(make_i_inst(12'h485, 3'b101), BM_BEXT);
        check_decode(make_r_inst(7'h34, 5'd2, 3'b001), BM_BINV);
        check_decode(make_i_inst(12'h685, 3'b001), BM_BINV);
        check_decode(make_r_inst(7'h14, 5'd2, 3'b001), BM_BSET);
        check_decode(make_i_inst(12'h285, 3'b001), BM_BSET);
        check_decode(make_r_inst(7'h04, 5'd2, 3'b100), BM_PACK);
        check_decode(make_r_inst(7'h04, 5'd2, 3'b111), BM_PACKH);
        check_decode(make_i_inst(12'h687, 3'b101), BM_BREV8);
        check_decode(make_i_inst(12'h08f, 3'b001), BM_ZIP);
        check_decode(make_i_inst(12'h08f, 3'b101), BM_UNZIP);
        check_decode(make_r_inst(7'h14, 5'd2, 3'b010), BM_XPERM4);
        check_decode(make_r_inst(7'h14, 5'd2, 3'b100), BM_XPERM8);

        // The shallow frontend policy must preserve the original base/M
        // classification while forcing all non-base ALU encodings to Slot 0.
        check_frontend_single_policy(
            make_r_inst(7'h00, 5'd2, 3'b000), 1'b0); // ADD
        check_frontend_single_policy(
            make_r_inst(7'h20, 5'd2, 3'b000), 1'b0); // SUB
        check_frontend_single_policy(
            make_r_inst(7'h20, 5'd2, 3'b101), 1'b0); // SRA
        check_frontend_single_policy(
            make_r_inst(MULDIV_FUNCT7, 5'd2, 3'b000), 1'b1); // MUL
        check_frontend_single_policy(make_i_inst(12'h005, 3'b001),
                                     1'b0); // SLLI
        check_frontend_single_policy(make_i_inst(12'h405, 3'b101),
                                     1'b0); // SRAI

        for (int op_index = 1; op_index <= 34; op_index = op_index + 1) begin
            run_case(bitmanip_op_t'(op_index), 32'd0, 32'd0);
            run_case(bitmanip_op_t'(op_index), 32'hffff_ffff,
                     32'hffff_ffff);
            run_case(bitmanip_op_t'(op_index), 32'h1234_5678,
                     32'h89ab_cdef);
            for (int n = 0; n < 32; n = n + 1)
                run_case(bitmanip_op_t'(op_index), $urandom(seed),
                         $urandom(seed));
        end

        // A fast operation must use operands captured with its request, not
        // later values on the stalled EX request interface.
        @(negedge clk);
        req_op = BM_XNOR;
        req_rs1 = 32'h1234_5678;
        req_rs2 = 32'h89ab_cdef;
        req_valid = 1'b1;
        consume = 1'b0;
        @(negedge clk);
        req_op = BM_ANDN;
        req_rs1 = 32'd0;
        req_rs2 = 32'hffff_ffff;
        while (!done)
            @(negedge clk);
        if (result !== 32'h6460_6468) begin
            $error("fast bitmanip operands were not isolated from request changes");
            $fatal(1);
        end
        consume = 1'b1;
        @(negedge clk);
        req_valid = 1'b0;
        consume = 1'b0;

        // A completed result must remain stable until EX consumes it.
        @(negedge clk);
        req_op = BM_XNOR;
        req_rs1 = 32'h1234_5678;
        req_rs2 = 32'h89ab_cdef;
        req_valid = 1'b1;
        while (!done)
            @(negedge clk);
        repeat (3) begin
            @(negedge clk);
            if (!done || result !== 32'h6460_6468) begin
                $error("completed bitmanip result did not hold");
                $fatal(1);
            end
        end
        consume = 1'b1;
        @(negedge clk);
        req_valid = 1'b0;
        consume = 1'b0;

        // Abort an in-flight CLMUL and verify that the next request is clean.
        @(negedge clk);
        req_op = BM_CLMUL;
        req_rs1 = 32'hfedc_ba98;
        req_rs2 = 32'h0123_4567;
        req_valid = 1'b1;
        repeat (4) @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        req_valid = 1'b0;
        if (busy || done) begin
            $error("flush did not return bitmanip unit to idle");
            $fatal(1);
        end
        run_case(BM_CLMUL, 32'hfedc_ba98, 32'h0123_4567);

        $display("[PASS] bitmanip decoder/unit randomized test (%0d decode, %0d execution cases)",
                 decode_cases, cases);
        $finish;
    end

endmodule
