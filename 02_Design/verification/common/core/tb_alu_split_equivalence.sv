`timescale 1ns/1ps

module tb_alu_split_equivalence;
    import cpu_defs::*;

    logic [3:0]  alu_op;
    logic [31:0] result_src1;
    logic [31:0] result_src2;
    logic [31:0] addr_src1;
    logic [31:0] addr_src2;
    logic [31:0] architectural_result;
    logic [31:0] architectural_sum;
    logic [31:0] architectural_addr;
    logic [31:0] fast_result;
    logic [31:0] fast_sum;

    logic [3:0]  valid_ops [0:10];
    logic [31:0] edge_values [0:15];
    integer random_seed;
    integer case_count;

    alu u_architectural_alu (
        .alu_op       (alu_op),
        .alu_src1     (result_src1),
        .alu_src2     (result_src2),
        .alu_addr_src1(addr_src1),
        .alu_addr_src2(addr_src2),
        .alu_result   (architectural_result),
        .alu_sum      (architectural_sum),
        .alu_addr     (architectural_addr)
    );

    alu_result_datapath u_fast_forward_alu (
        .alu_op    (alu_op),
        .alu_src1  (result_src1),
        .alu_src2  (result_src2),
        .alu_result(fast_result),
        .alu_sum   (fast_sum)
    );

    function automatic logic [31:0] reference_result(
        input logic [3:0]  op,
        input logic [31:0] lhs,
        input logic [31:0] rhs
    );
        case (op)
            ALU_ADD:  reference_result = lhs + rhs;
            ALU_SUB:  reference_result = lhs - rhs;
            ALU_SLL:  reference_result = lhs << rhs[4:0];
            ALU_SLT:  reference_result = {
                31'd0, $signed(lhs) < $signed(rhs)
            };
            ALU_SLTU: reference_result = {31'd0, lhs < rhs};
            ALU_XOR:  reference_result = lhs ^ rhs;
            ALU_SRL:  reference_result = lhs >> rhs[4:0];
            ALU_SRA:  reference_result = $signed(lhs) >>> rhs[4:0];
            ALU_OR:   reference_result = lhs | rhs;
            ALU_NOR:  reference_result = ~(lhs | rhs);
            ALU_AND:  reference_result = lhs & rhs;
            default:  reference_result = 32'd0;
        endcase
    endfunction

    task automatic check_case(
        input logic [3:0]  op,
        input logic [31:0] lhs,
        input logic [31:0] rhs,
        input logic [31:0] address_lhs,
        input logic [31:0] address_rhs
    );
        logic [31:0] expected;
        begin
            alu_op = op;
            result_src1 = lhs;
            result_src2 = rhs;
            addr_src1 = address_lhs;
            addr_src2 = address_rhs;
            #1;

            expected = reference_result(op, lhs, rhs);
            if (architectural_result !== expected)
                $fatal(1,
                       "[FAIL] architectural ALU op=%h lhs=%h rhs=%h got=%h expected=%h",
                       op, lhs, rhs, architectural_result, expected);
            if (fast_result !== expected)
                $fatal(1,
                       "[FAIL] fast ALU op=%h lhs=%h rhs=%h got=%h expected=%h",
                       op, lhs, rhs, fast_result, expected);
            if (fast_result !== architectural_result)
                $fatal(1, "[FAIL] fast/full ALU copies disagree");
            if (fast_sum !== architectural_sum)
                $fatal(1, "[FAIL] fast/full shared sums disagree");
            if (architectural_addr !== (address_lhs + address_rhs))
                $fatal(1,
                       "[FAIL] independent LSU address add got=%h expected=%h",
                       architectural_addr, address_lhs + address_rhs);

            if ((op == ALU_ADD) && (architectural_sum !== lhs + rhs))
                $fatal(1, "[FAIL] ADD shared sum mismatch");
            if (((op == ALU_SUB) || (op == ALU_SLT)
                 || (op == ALU_SLTU))
                && (architectural_sum !== lhs - rhs))
                $fatal(1, "[FAIL] subtract/compare shared sum mismatch");
            case_count = case_count + 1;
        end
    endtask

    initial begin
        if (!$value$plusargs("seed=%d", random_seed))
            random_seed = 32'h5a17_2026;
        void'($urandom(random_seed));
        case_count = 0;

        valid_ops[0] = ALU_ADD;
        valid_ops[1] = ALU_SUB;
        valid_ops[2] = ALU_SLL;
        valid_ops[3] = ALU_SLT;
        valid_ops[4] = ALU_SLTU;
        valid_ops[5] = ALU_XOR;
        valid_ops[6] = ALU_SRL;
        valid_ops[7] = ALU_SRA;
        valid_ops[8] = ALU_OR;
        valid_ops[9] = ALU_NOR;
        valid_ops[10] = ALU_AND;

        edge_values[0] = 32'h0000_0000;
        edge_values[1] = 32'h0000_0001;
        edge_values[2] = 32'hffff_ffff;
        edge_values[3] = 32'h7fff_ffff;
        edge_values[4] = 32'h8000_0000;
        edge_values[5] = 32'h8000_0001;
        edge_values[6] = 32'h0000_001f;
        edge_values[7] = 32'h0000_0020;
        edge_values[8] = 32'h0000_0021;
        edge_values[9] = 32'haaaa_aaaa;
        edge_values[10] = 32'h5555_5555;
        edge_values[11] = 32'hffff_0000;
        edge_values[12] = 32'h0000_ffff;
        edge_values[13] = 32'h7fff_0001;
        edge_values[14] = 32'h8000_ffff;
        edge_values[15] = 32'hdead_beef;

        for (int op_index = 0; op_index < 11; op_index++) begin
            for (int lhs_index = 0; lhs_index < 16; lhs_index++) begin
                for (int rhs_index = 0; rhs_index < 16; rhs_index++) begin
                    check_case(
                        valid_ops[op_index],
                        edge_values[lhs_index], edge_values[rhs_index],
                        edge_values[rhs_index], edge_values[lhs_index]
                    );
                end
            end
        end

        for (int trial = 0; trial < 2000; trial++) begin
            for (int op_index = 0; op_index < 11; op_index++) begin
                check_case(
                    valid_ops[op_index], $urandom, $urandom,
                    $urandom, $urandom
                );
            end
        end

        $display("[PASS] split ALU semantic/equivalence test cases=%0d seed=%0d",
                 case_count, random_seed);
        $finish;
    end
endmodule
