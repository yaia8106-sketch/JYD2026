`timescale 1ns/1ps

module tb_loongarch_decode_contract;
    import cpu_defs::*;

    logic [31:0] inst;
    decoded_uop_t uop;
    frontend_predecode_t predecode;

    logic [31:0] alu_src1;
    logic [31:0] alu_src2;
    logic [31:0] alu_result;
    logic [31:0] alu_sum;
    logic [31:0] alu_addr;

    integer case_count;
    integer opcode_prefix_count;
    string current_case;

    loongarch_decoder u_decoder (
        .inst (inst),
        .uop  (uop)
    );

    loongarch_predecode u_predecode (
        .inst    (inst),
        .decoded (predecode)
    );

    alu u_alu (
        .alu_op       (uop.alu_op),
        .alu_src1     (alu_src1),
        .alu_src2     (alu_src2),
        .alu_addr_src1(32'd0),
        .alu_addr_src2(32'd0),
        .alu_result   (alu_result),
        .alu_sum      (alu_sum),
        .alu_addr     (alu_addr)
    );

    // Independent encoders mirror the field diagrams in Appendix B. They do
    // not consume the constants used by the DUT.
    function automatic logic [31:0] enc_rr(
        input logic [1:0] op_21_20,
        input logic [4:0] op_19_15,
        input logic [4:0] rk,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_rr = {6'h00, 4'h0, op_21_20, op_19_15, rk, rj, rd};
    endfunction

    function automatic logic [31:0] enc_shift_imm(
        input logic [4:0] op_19_15,
        input logic [4:0] ui5,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_shift_imm = {6'h00, 4'h1, 2'h0, op_19_15, ui5, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i12(
        input logic [5:0] op_31_26,
        input logic [3:0] op_25_22,
        input logic [11:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i12 = {op_31_26, op_25_22, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_upper(
        input logic [5:0] op_31_26,
        input logic [19:0] immediate,
        input logic [4:0] rd
    );
        enc_upper = {op_31_26, 1'b0, immediate, rd};
    endfunction

    function automatic logic [31:0] enc_i16(
        input logic [5:0] op_31_26,
        input logic [15:0] immediate,
        input logic [4:0] rj,
        input logic [4:0] rd
    );
        enc_i16 = {op_31_26, immediate, rj, rd};
    endfunction

    function automatic logic [31:0] enc_i26(
        input logic [5:0] op_31_26,
        input logic [25:0] immediate
    );
        enc_i26 = {op_31_26, immediate[15:0], immediate[25:16]};
    endfunction

    function automatic logic predecode_matches_uop;
        logic decoder_alu_only;
        logic decoder_is_muldiv;
        logic decoder_is_mul;
        logic decoder_is_privileged_flow;
        begin
            decoder_alu_only = uop.dst_write
                             && (uop.exec_unit == EXEC_ALU)
                             && (uop.wb_src == WB_EXEC);
            decoder_is_muldiv = uop.exec_unit == EXEC_MULDIV;
            decoder_is_mul = decoder_is_muldiv
                           && (uop.muldiv_op <= MULDIV_MULHU);
            decoder_is_privileged_flow = (uop.priv_op == PRIV_SYSCALL)
                                       | (uop.priv_op == PRIV_RETURN)
                                       | (uop.exception != EXCEPTION_NONE);
            predecode_matches_uop =
                (predecode.uses_src0 == uop.src0_used)
                && (predecode.uses_src1 == uop.src1_used)
                && (predecode.src0_addr == uop.src0_addr)
                && (predecode.src1_addr == uop.src1_addr)
                && (predecode.writes_dst == uop.dst_write)
                && (predecode.dst_addr == uop.dst_addr)
                && (predecode.is_alu_type == decoder_alu_only)
                && (predecode.is_conditional_branch
                    == (uop.control_flow == CF_CONDITIONAL))
                && (predecode.is_direct_jump
                    == (uop.control_flow == CF_DIRECT))
                && (predecode.is_indirect_jump
                    == (uop.control_flow == CF_INDIRECT))
                && (predecode.is_privileged
                    == (uop.exec_unit == EXEC_PRIV))
                && (predecode.is_privileged_flow
                    == decoder_is_privileged_flow)
                && (predecode.is_fence == (uop.exec_unit == EXEC_FENCE))
                && (predecode.is_illegal
                    == (uop.exception == EXCEPTION_ILLEGAL))
                && (predecode.is_load == (uop.mem_cmd == MEM_LOAD))
                && (predecode.is_store == (uop.mem_cmd == MEM_STORE))
                && (predecode.is_muldiv == decoder_is_muldiv)
                && (predecode.is_mul == decoder_is_mul)
                && (predecode.is_jump
                    == ((uop.control_flow == CF_DIRECT)
                       | (uop.control_flow == CF_INDIRECT)
                       | decoder_is_privileged_flow))
                && (predecode.is_control
                    == ((uop.control_flow != CF_NONE)
                       | decoder_is_privileged_flow))
                && (predecode.is_lsu
                    == ((uop.mem_cmd == MEM_LOAD)
                       | (uop.mem_cmd == MEM_STORE)))
                && (predecode.is_cfi
                    == (uop.control_flow != CF_NONE))
                && (predecode.lane_mask == uop.lane_mask)
                && (predecode.block_younger == uop.block_younger)
                && (predecode.serializing == uop.serializing);
        end
    endfunction

    // Independent literal table for the complete phase-2 legality boundary.
    // LA32R legality in this subset depends only on inst[31:15], so enumerating
    // every value of that prefix covers every possible 32-bit instruction's
    // opcode classification while leaving register/immediate fields to the
    // directed semantic cases below.
    function automatic logic reference_legal(
        input logic [31:0] instruction
    );
        logic legal_op17;
        logic legal_op10;
        logic legal_op7;
        logic legal_op6;
        begin
            legal_op17 = 1'b0;
            case (instruction[31:15])
                17'h00020, 17'h00022, 17'h00024, 17'h00025,
                17'h00028, 17'h00029, 17'h0002a, 17'h0002b,
                17'h0002e, 17'h0002f, 17'h00030,
                17'h00038, 17'h00039, 17'h0003a,
                17'h00040, 17'h00041, 17'h00042, 17'h00043,
                17'h00081, 17'h00089, 17'h00091:
                    legal_op17 = 1'b1;
                default: ;
            endcase

            legal_op10 = 1'b0;
            case (instruction[31:22])
                10'h008, 10'h009, 10'h00a,
                10'h00d, 10'h00e, 10'h00f,
                10'h0a0, 10'h0a1, 10'h0a2,
                10'h0a4, 10'h0a5, 10'h0a6,
                10'h0a8, 10'h0a9:
                    legal_op10 = 1'b1;
                default: ;
            endcase

            legal_op7 = 1'b0;
            case (instruction[31:25])
                7'h0a, 7'h0e: legal_op7 = 1'b1;
                default: ;
            endcase

            legal_op6 = 1'b0;
            case (instruction[31:26])
                6'h13, 6'h14, 6'h15, 6'h16, 6'h17,
                6'h18, 6'h19, 6'h1a, 6'h1b:
                    legal_op6 = 1'b1;
                default: ;
            endcase

            reference_legal = legal_op17 | legal_op10
                            | legal_op7 | legal_op6
                            | (instruction[31:24] == 8'h04)
                            | (instruction[31:15]
                               == {6'h00, 4'h0, 2'h2, 5'h16})
                            | (instruction[31:15]
                               == {6'h00, 4'h0, 2'h2, 5'h14});
        end
    endfunction

    task automatic begin_case(
        input logic [31:0] instruction,
        input string       name
    );
        begin
            inst = instruction;
            current_case = name;
            case_count = case_count + 1;
            #1;
            if (!predecode_matches_uop())
                $fatal(1,
                       "[FAIL] %s: predecode differs from full decoder (inst=%08x)",
                       current_case, inst);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            if (condition !== 1'b1)
                $fatal(1, "[FAIL] %s: %s (inst=%08x)",
                       current_case, message, inst);
        end
    endtask

    task automatic test_unsupported_containment(
        input logic [31:0] instruction,
        input string       name
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_NONE)
                  && (uop.exception == EXCEPTION_ILLEGAL)
                  && !uop.dst_write && (uop.mem_cmd == MEM_NONE)
                  && (uop.control_flow == CF_NONE)
                  && (uop.lane_mask == 2'b01)
                  && uop.block_younger && uop.serializing,
                  "unsupported encoding containment policy");
        end
    endtask

    task automatic run_exhaustive_opcode_prefix_check;
        integer legal_prefix_count;
        logic expected_legal;
        begin
            legal_prefix_count = 0;
            $display("[INFO] Exhaustively checking all 131072 inst[31:15] prefixes...");
            for (int unsigned prefix = 0; prefix < 131072; prefix++) begin
                inst = {prefix[16:0], 15'd0};
                #1ps;
                expected_legal = reference_legal(inst);
                if (expected_legal)
                    legal_prefix_count++;

                if (predecode.is_illegal !== ~expected_legal)
                    $fatal(1,
                           "[FAIL] prefix %05x: predecode legality expected %0d",
                           prefix[16:0], expected_legal);
                if ((uop.exception != EXCEPTION_ILLEGAL) !== expected_legal)
                    $fatal(1,
                           "[FAIL] prefix %05x: full-decode legality expected %0d",
                           prefix[16:0], expected_legal);
                if (!predecode_matches_uop())
                    $fatal(1,
                           "[FAIL] prefix %05x: predecode/full-decode mismatch",
                           prefix[16:0]);
                if (!expected_legal
                    && ((uop.exec_unit != EXEC_NONE)
                        || uop.dst_write || (uop.mem_cmd != MEM_NONE)
                        || (uop.control_flow != CF_NONE)
                        || (uop.lane_mask != 2'b01)
                        || !uop.block_younger || !uop.serializing))
                    $fatal(1,
                           "[FAIL] prefix %05x: illegal encoding has side effects",
                           prefix[16:0]);
            end
            check(legal_prefix_count == 22807,
                  "independent legal-prefix population");
            opcode_prefix_count = 131072;
        end
    endtask

    task automatic test_alu_rr(
        input logic [31:0] instruction,
        input string       name,
        input alu_op_t     expected_op
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_ALU) && (uop.alu_op == expected_op),
                  "register ALU operation");
            check(uop.src0_used && uop.src1_used && uop.dst_write,
                  "register ALU operands");
            check((uop.wb_src == WB_EXEC) && (uop.lane_mask == 2'b11)
                  && !uop.block_younger && !uop.serializing,
                  "register ALU issue/writeback policy");
        end
    endtask

    task automatic test_alu_imm(
        input logic [31:0] instruction,
        input string       name,
        input alu_op_t     expected_op,
        input logic [31:0] expected_imm
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_ALU) && (uop.alu_op == expected_op),
                  "immediate ALU operation");
            check(uop.src0_used && !uop.src1_used && uop.dst_write,
                  "immediate ALU operands");
            check((uop.operand_b_sel == OPERAND_B_IMM)
                  && (uop.imm == expected_imm), "expanded immediate");
        end
    endtask

    task automatic test_muldiv(
        input logic [31:0] instruction,
        input string       name,
        input muldiv_op_t  expected_op,
        input logic        expected_mul
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_MULDIV)
                  && (uop.muldiv_op == expected_op), "MULDIV operation");
            check(uop.src0_used && uop.src1_used && uop.dst_write,
                  "MULDIV register operands");
            check((uop.lane_mask == 2'b01)
                  && (uop.block_younger == !expected_mul)
                  && (uop.serializing == !expected_mul),
                  "MULDIV issue policy");
            check(predecode.is_mul == expected_mul,
                  "semantic multiply metadata");
        end
    endtask

    task automatic test_branch(
        input logic [31:0] instruction,
        input string       name,
        input branch_op_t  expected_op,
        input logic [31:0] expected_imm
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_BRANCH)
                  && (uop.control_flow == CF_CONDITIONAL)
                  && (uop.branch_op == expected_op), "branch operation");
            check(uop.src0_used && uop.src1_used && !uop.dst_write,
                  "branch register operands");
            check((uop.operand_a_sel == OPERAND_A_PC)
                  && (uop.operand_b_sel == OPERAND_B_IMM)
                  && (uop.imm == expected_imm), "branch target operands");
        end
    endtask

    task automatic test_load(
        input logic [31:0] instruction,
        input string       name,
        input mem_size_t   expected_size,
        input logic        expected_unsigned,
        input logic [31:0] expected_imm
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_LSU) && (uop.mem_cmd == MEM_LOAD)
                  && (uop.mem_size == expected_size)
                  && (uop.mem_unsigned == expected_unsigned),
                  "load operation");
            check(uop.src0_used && !uop.src1_used && uop.dst_write
                  && (uop.wb_src == WB_LOAD), "load operands/writeback");
            check((uop.imm == expected_imm) && (uop.lane_mask == 2'b11),
                  "load displacement and dual-lane policy");
        end
    endtask

    task automatic test_store(
        input logic [31:0] instruction,
        input string       name,
        input mem_size_t   expected_size,
        input logic [31:0] expected_imm
    );
        begin
            begin_case(instruction, name);
            check((uop.exec_unit == EXEC_LSU) && (uop.mem_cmd == MEM_STORE)
                  && (uop.mem_size == expected_size), "store operation");
            check(uop.src0_used && uop.src1_used && !uop.dst_write,
                  "store operands");
            check((uop.src1_addr == inst[4:0]) && (uop.imm == expected_imm)
                  && (uop.lane_mask == 2'b11),
                  "store rd source, displacement, and dual-lane policy");
        end
    endtask

    initial begin
        inst = 32'd0;
        alu_src1 = 32'h1234_5678;
        alu_src2 = 32'h0f0f_f0f0;
        case_count = 0;
        opcode_prefix_count = 0;
        current_case = "initial";
        #1;

        // Official chiplab disassembly word: add.w r15,r17,r18.
        test_alu_rr(32'h0010_4a2f, "ADD.W", ALU_ADD);
        check((uop.src0_addr == 5'd17) && (uop.src1_addr == 5'd18)
              && (uop.dst_addr == 5'd15), "ADD.W architectural fields");
        test_alu_rr(enc_rr(2'h1, 5'h02, 5'd5, 5'd4, 5'd3),
                    "SUB.W", ALU_SUB);
        test_alu_rr(enc_rr(2'h1, 5'h04, 5'd5, 5'd4, 5'd3),
                    "SLT", ALU_SLT);
        test_alu_rr(enc_rr(2'h1, 5'h05, 5'd5, 5'd4, 5'd3),
                    "SLTU", ALU_SLTU);
        // Official disassembly word: nor r10,r12,r13.
        test_alu_rr(32'h0014_358a, "NOR", ALU_NOR);
        check(alu_result == ~(alu_src1 | alu_src2), "NOR execution result");
        test_alu_rr(enc_rr(2'h1, 5'h09, 5'd5, 5'd4, 5'd3),
                    "AND", ALU_AND);
        test_alu_rr(enc_rr(2'h1, 5'h0a, 5'd5, 5'd4, 5'd3),
                    "OR", ALU_OR);
        test_alu_rr(enc_rr(2'h1, 5'h0b, 5'd5, 5'd4, 5'd3),
                    "XOR", ALU_XOR);
        test_alu_rr(enc_rr(2'h1, 5'h0e, 5'd5, 5'd4, 5'd3),
                    "SLL.W", ALU_SLL);
        test_alu_rr(enc_rr(2'h1, 5'h0f, 5'd5, 5'd4, 5'd3),
                    "SRL.W", ALU_SRL);
        test_alu_rr(enc_rr(2'h1, 5'h10, 5'd5, 5'd4, 5'd3),
                    "SRA.W", ALU_SRA);

        test_alu_imm(enc_i12(6'h00, 4'ha, 12'hff0, 5'd4, 5'd3),
                     "ADDI.W", ALU_ADD, 32'hffff_fff0);
        test_alu_imm(enc_i12(6'h00, 4'h8, 12'h800, 5'd4, 5'd3),
                     "SLTI", ALU_SLT, 32'hffff_f800);
        test_alu_imm(enc_i12(6'h00, 4'h9, 12'h800, 5'd4, 5'd3),
                     "SLTUI sign extension", ALU_SLTU, 32'hffff_f800);
        test_alu_imm(enc_i12(6'h00, 4'hd, 12'hf80, 5'd4, 5'd3),
                     "ANDI", ALU_AND, 32'h0000_0f80);
        test_alu_imm(enc_i12(6'h00, 4'he, 12'hf80, 5'd4, 5'd3),
                     "ORI", ALU_OR, 32'h0000_0f80);
        test_alu_imm(enc_i12(6'h00, 4'hf, 12'hf80, 5'd4, 5'd3),
                     "XORI", ALU_XOR, 32'h0000_0f80);
        test_alu_imm(enc_i12(6'h00, 4'ha, 12'h000, 5'd4, 5'd3),
                     "ADDI.W zero boundary", ALU_ADD, 32'd0);
        test_alu_imm(enc_i12(6'h00, 4'ha, 12'h7ff, 5'd4, 5'd3),
                     "ADDI.W positive boundary", ALU_ADD, 32'h0000_07ff);
        test_alu_imm(enc_i12(6'h00, 4'hd, 12'hfff, 5'd4, 5'd3),
                     "ANDI unsigned boundary", ALU_AND, 32'h0000_0fff);
        test_alu_imm(enc_shift_imm(5'h01, 5'd9, 5'd14, 5'd15),
                     "SLLI.W", ALU_SLL, 32'd9);
        test_alu_imm(enc_shift_imm(5'h09, 5'd31, 5'd4, 5'd3),
                     "SRLI.W", ALU_SRL, 32'd31);
        test_alu_imm(enc_shift_imm(5'h11, 5'd17, 5'd4, 5'd3),
                     "SRAI.W", ALU_SRA, 32'd17);
        test_alu_imm(enc_shift_imm(5'h01, 5'd0, 5'd4, 5'd3),
                     "SLLI.W zero boundary", ALU_SLL, 32'd0);
        test_alu_imm(enc_shift_imm(5'h11, 5'd31, 5'd4, 5'd3),
                     "SRAI.W maximum boundary", ALU_SRA, 32'd31);

        begin_case(enc_upper(6'h05, 20'habcde, 5'd3), "LU12I.W");
        check((uop.exec_unit == EXEC_ALU) && uop.dst_write
              && (uop.operand_a_sel == OPERAND_A_ZERO)
              && (uop.imm == 32'habcd_e000), "LU12I.W semantics");
        begin_case(enc_upper(6'h07, 20'h81234, 5'd3), "PCADDU12I");
        check((uop.exec_unit == EXEC_ALU) && uop.dst_write
              && (uop.operand_a_sel == OPERAND_A_PC)
              && (uop.imm == 32'h8123_4000), "PCADDU12I semantics");

        // rk=20 makes inst[14]=1. It must remain a multiply.
        test_muldiv(enc_rr(2'h1, 5'h18, 5'd20, 5'd4, 5'd3),
                    "MUL.W encoding-leak guard", MULDIV_MUL, 1'b1);
        check(inst[14] == 1'b1, "MUL.W guard really sets inst[14]");
        test_muldiv(enc_rr(2'h1, 5'h19, 5'd5, 5'd4, 5'd3),
                    "MULH.W", MULDIV_MULH, 1'b1);
        test_muldiv(enc_rr(2'h1, 5'h1a, 5'd5, 5'd4, 5'd3),
                    "MULH.WU", MULDIV_MULHU, 1'b1);
        // rk=5 makes inst[14]=0. It must not be classified as multiply.
        test_muldiv(enc_rr(2'h2, 5'h00, 5'd5, 5'd4, 5'd3),
                    "DIV.W encoding-leak guard", MULDIV_DIV, 1'b0);
        check(inst[14] == 1'b0, "DIV.W guard really clears inst[14]");
        test_muldiv(enc_rr(2'h2, 5'h02, 5'd5, 5'd4, 5'd3),
                    "DIV.WU", MULDIV_DIVU, 1'b0);
        test_muldiv(enc_rr(2'h2, 5'h01, 5'd5, 5'd4, 5'd3),
                    "MOD.W", MULDIV_REM, 1'b0);
        test_muldiv(enc_rr(2'h2, 5'h03, 5'd5, 5'd4, 5'd3),
                    "MOD.WU", MULDIV_REMU, 1'b0);

        // Official disassembly word: beq r13,r12,+120.
        test_branch(32'h5800_79ac, "BEQ", BR_EQ, 32'd120);
        check((uop.src0_addr == 5'd13) && (uop.src1_addr == 5'd12),
              "BEQ compares rj against rd");
        test_branch(enc_i16(6'h17, 16'hffff, 5'd4, 5'd3),
                    "BNE", BR_NE, 32'hffff_fffc);
        test_branch(enc_i16(6'h18, 16'h0002, 5'd4, 5'd3),
                    "BLT", BR_LT, 32'd8);
        test_branch(enc_i16(6'h19, 16'h0003, 5'd4, 5'd3),
                    "BGE", BR_GE, 32'd12);
        test_branch(enc_i16(6'h1a, 16'h0004, 5'd4, 5'd3),
                    "BLTU", BR_LTU, 32'd16);
        test_branch(enc_i16(6'h1b, 16'h0005, 5'd4, 5'd3),
                    "BGEU", BR_GEU, 32'd20);
        test_branch(enc_i16(6'h16, 16'h7fff, 5'd4, 5'd3),
                    "BEQ positive displacement boundary", BR_EQ,
                    32'h0001_fffc);
        test_branch(enc_i16(6'h16, 16'h8000, 5'd4, 5'd3),
                    "BEQ negative displacement boundary", BR_EQ,
                    32'hfffe_0000);
        test_branch(enc_i16(6'h16, 16'h0000, 5'd0, 5'd0),
                    "BEQ r0,r0 zero displacement", BR_EQ, 32'd0);

        begin_case(enc_i26(6'h14, 26'h3ff_ffff), "B");
        check((uop.control_flow == CF_DIRECT) && (uop.branch_op == BR_ALWAYS)
              && !uop.dst_write && (uop.wb_src == WB_NONE)
              && (uop.imm == 32'hffff_fffc), "B semantics");
        begin_case(enc_i26(6'h15, 26'h000_0002), "BL");
        check((uop.control_flow == CF_DIRECT) && (uop.branch_op == BR_ALWAYS)
              && uop.dst_write && (uop.dst_addr == 5'd1)
              && (uop.wb_src == WB_NEXT_PC) && (uop.imm == 32'd8)
              && (uop.cfi_type == CFI_TYPE_CALL), "BL semantics");
        begin_case(enc_i26(6'h14, 26'h1ff_ffff),
                   "B positive displacement boundary");
        check(uop.imm == 32'h07ff_fffc,
              "B positive displacement expansion");
        begin_case(enc_i26(6'h14, 26'h200_0000),
                   "B negative displacement boundary");
        check(uop.imm == 32'hf800_0000,
              "B negative displacement expansion");
        // Official disassembly word: jirl r0,r1,0 (return).
        begin_case(32'h4c00_0020, "JIRL return");
        check((uop.control_flow == CF_INDIRECT)
              && (uop.target_base == TARGET_SRC0)
              && (uop.target_clear_mask == 2'b00)
              && (uop.wb_src == WB_NEXT_PC)
              && (uop.cfi_type == CFI_TYPE_RETURN)
              && uop.block_younger && !uop.serializing,
              "JIRL target/link semantics");
        begin_case(enc_i16(6'h13, 16'h0002, 5'd6, 5'd1), "JIRL call hint");
        check(uop.cfi_update && (uop.cfi_type == CFI_TYPE_CALL)
              && (uop.imm == 32'd8), "JIRL call metadata");
        begin_case(enc_i16(6'h13, 16'hffff, 5'd9, 5'd9),
                   "JIRL rd equals rj with negative displacement");
        check(uop.src0_used && (uop.src0_addr == 5'd9)
              && uop.dst_write && (uop.dst_addr == 5'd9)
              && (uop.imm == 32'hffff_fffc)
              && !uop.cfi_update && (uop.cfi_type == CFI_TYPE_JUMP),
              "JIRL overlapping source/destination metadata");

        test_load(enc_i12(6'h0a, 4'h0, 12'hff8, 5'd4, 5'd3),
                  "LD.B", MEM_BYTE, 1'b0, 32'hffff_fff8);
        test_load(enc_i12(6'h0a, 4'h8, 12'hff8, 5'd4, 5'd3),
                  "LD.BU", MEM_BYTE, 1'b1, 32'hffff_fff8);
        test_load(enc_i12(6'h0a, 4'h1, 12'h004, 5'd4, 5'd3),
                  "LD.H", MEM_HALF, 1'b0, 32'd4);
        test_load(enc_i12(6'h0a, 4'h9, 12'h004, 5'd4, 5'd3),
                  "LD.HU", MEM_HALF, 1'b1, 32'd4);
        test_load(enc_i12(6'h0a, 4'h2, 12'h004, 5'd4, 5'd3),
                  "LD.W", MEM_WORD, 1'b0, 32'd4);
        test_store(enc_i12(6'h0a, 4'h4, 12'hff8, 5'd4, 5'd3),
                   "ST.B", MEM_BYTE, 32'hffff_fff8);
        test_store(enc_i12(6'h0a, 4'h5, 12'h004, 5'd4, 5'd3),
                   "ST.H", MEM_HALF, 32'd4);
        // Official disassembly word: st.w r13,r4,0.
        test_store(32'h2980_008d, "ST.W", MEM_WORD, 32'd0);
        check((uop.src0_addr == 5'd4) && (uop.src1_addr == 5'd13),
              "ST.W base/data architectural fields");
        test_load(enc_i12(6'h0a, 4'h2, 12'h800, 5'd4, 5'd0),
                  "LD.W r0 negative displacement boundary", MEM_WORD,
                  1'b0, 32'hffff_f800);
        check(uop.dst_write && (uop.dst_addr == 5'd0),
              "load to r0 retains the memory side effect");
        test_store(enc_i12(6'h0a, 4'h6, 12'h7ff, 5'd4, 5'd0),
                   "ST.W r0 positive displacement boundary", MEM_WORD,
                   32'h0000_07ff);
        check(uop.src1_used && (uop.src1_addr == 5'd0),
              "store reads r0 through the rd field");

        begin_case(32'h0340_0000, "NOP alias (ANDI r0,r0,0)");
        check((uop.exec_unit == EXEC_ALU) && (uop.alu_op == ALU_AND)
              && (uop.dst_addr == 5'd0) && uop.dst_write
              && (uop.imm == 32'd0), "NOP alias semantics");

        begin_case(enc_rr(2'h2, 5'h16, 5'd0, 5'd0, 5'd0), "SYSCALL");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_SYSCALL)
              && (uop.exception == EXCEPTION_NONE)
              && uop.serializing && uop.block_younger,
              "SYSCALL privileged-flow semantics");
        begin_case(32'h002a_0000, "BREAK");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.exception == EXCEPTION_BREAKPOINT)
              && uop.serializing && uop.block_younger,
              "BREAK exception semantics");
        begin_case(32'h0400_0007, "CSRRD");
        check((uop.exec_unit == EXEC_PRIV) && (uop.priv_op == PRIV_REG)
              && (uop.priv_cmd == PRIV_CMD_NONE)
              && !uop.src0_used && !uop.src1_used
              && uop.dst_write && (uop.dst_addr == 5'd7),
              "CSRRD operand semantics");
        begin_case({8'h04, 14'h006, 5'd1, 5'd7}, "CSRWR");
        check((uop.priv_cmd == PRIV_CMD_WRITE)
              && uop.src0_used && (uop.src0_addr == 5'd7)
              && !uop.src1_used && (uop.priv_addr == 16'h0006),
              "CSRWR rd source semantics");
        begin_case({8'h04, 14'h005, 5'd9, 5'd7}, "CSRXCHG");
        check((uop.priv_cmd == PRIV_CMD_EXCHANGE)
              && uop.src0_used && (uop.src0_addr == 5'd7)
              && uop.src1_used && (uop.src1_addr == 5'd9),
              "CSRXCHG value/mask semantics");
        begin_case(32'h0648_3800, "ERTN");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_RETURN)
              && uop.serializing && uop.block_younger,
              "ERTN privileged-flow semantics");
        begin_case(32'h0000_600d, "RDCNTVL.W");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_COUNTER)
              && (uop.priv_addr == 16'hfffd)
              && uop.dst_write && (uop.dst_addr == 5'd13)
              && !uop.src0_used && !uop.src1_used,
              "RDCNTVL.W counter-low semantics");
        begin_case(32'h0000_640e, "RDCNTVH.W");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_COUNTER)
              && (uop.priv_addr == 16'hfffe)
              && uop.dst_write && (uop.dst_addr == 5'd14),
              "RDCNTVH.W counter-high semantics");
        begin_case(32'h0000_6180, "RDCNTID.W");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_COUNTER)
              && (uop.priv_addr == 16'hffff)
              && uop.dst_write && (uop.dst_addr == 5'd12),
              "RDCNTID.W TID semantics");

        // Remaining architecturally defined encodings belong to later phases
        // and remain contained as side-effect-free illegal uops.
        test_unsupported_containment(32'h2ac0_0000,
                                     "out-of-scope PRELD containment");
        test_unsupported_containment(32'h2000_0000,
                                     "out-of-scope LL.W containment");
        test_unsupported_containment(32'h2100_0000,
                                     "out-of-scope SC.W containment");
        test_unsupported_containment(32'h3872_0000,
                                     "out-of-scope DBAR containment");
        test_unsupported_containment(32'h3872_8000,
                                     "out-of-scope IBAR containment");
        test_unsupported_containment(32'h0600_0000,
                                     "out-of-scope CACOP containment");
        test_unsupported_containment(32'h0648_8000,
                                     "out-of-scope IDLE containment");
        test_unsupported_containment(32'hffff_ffff,
                                     "unknown encoding containment");

        run_exhaustive_opcode_prefix_check();

        $display("[PASS] LoongArch decoded-uop contract directed test (%0d cases, %0d opcode prefixes)",
                 case_count, opcode_prefix_count);
        $finish;
    end

endmodule
