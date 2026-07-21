`timescale 1ns/1ps

module tb_riscv_decode_contract;
    import cpu_defs::*;
    import riscv_defs::*;

    logic [31:0] inst;
    decoded_uop_t uop;
    frontend_predecode_t predecode;

    integer case_count;
    string current_case;

    riscv_decoder u_decoder (
        .inst (inst),
        .uop  (uop)
    );

    riscv_predecode u_predecode (
        .inst    (inst),
        .decoded (predecode)
    );

    function automatic logic [31:0] enc_r(
        input logic [6:0] funct7,
        input logic [4:0] src1,
        input logic [4:0] src0,
        input logic [2:0] funct3,
        input logic [4:0] dst,
        input logic [6:0] opcode
    );
        enc_r = {funct7, src1, src0, funct3, dst, opcode};
    endfunction

    function automatic logic [31:0] enc_i(
        input logic [11:0] immediate,
        input logic [4:0]  src0,
        input logic [2:0]  funct3,
        input logic [4:0]  dst,
        input logic [6:0]  opcode
    );
        enc_i = {immediate, src0, funct3, dst, opcode};
    endfunction

    function automatic logic [31:0] enc_s(
        input logic [11:0] immediate,
        input logic [4:0]  src1,
        input logic [4:0]  src0,
        input logic [2:0]  funct3
    );
        enc_s = {immediate[11:5], src1, src0, funct3,
                 immediate[4:0], OP_STORE};
    endfunction

    function automatic logic [31:0] enc_b(
        input logic [12:0] immediate,
        input logic [4:0]  src1,
        input logic [4:0]  src0,
        input logic [2:0]  funct3
    );
        enc_b = {immediate[12], immediate[10:5], src1, src0, funct3,
                 immediate[4:1], immediate[11], OP_BRANCH};
    endfunction

    function automatic logic [31:0] enc_u(
        input logic [19:0] immediate,
        input logic [4:0]  dst,
        input logic [6:0]  opcode
    );
        enc_u = {immediate, dst, opcode};
    endfunction

    function automatic logic [31:0] enc_j(
        input logic [20:0] immediate,
        input logic [4:0]  dst
    );
        enc_j = {immediate[20], immediate[10:1], immediate[11],
                 immediate[19:12], dst, OP_JAL};
    endfunction

    function automatic logic issue_metadata_matches;
        logic decoder_alu_only;
        logic decoder_is_muldiv;
        begin
            decoder_alu_only = uop.dst_write
                             && (uop.exec_unit == EXEC_ALU)
                             && (uop.wb_src == WB_EXEC);
            decoder_is_muldiv = uop.exec_unit == EXEC_MULDIV;
            issue_metadata_matches =
                (predecode.uses_src0 == uop.src0_used)
                && (predecode.uses_src1 == uop.src1_used)
                && (predecode.src0_addr == uop.src0_addr)
                && (predecode.src1_addr == uop.src1_addr)
                && (predecode.writes_dst == uop.dst_write)
                && (predecode.dst_addr == uop.dst_addr)
                && (predecode.is_alu_type == decoder_alu_only)
                && (predecode.is_conditional_branch
                    == (uop.control_flow == CF_CONDITIONAL))
                && (predecode.is_indirect_jump
                    == (uop.control_flow == CF_INDIRECT))
                && (predecode.is_load == (uop.mem_cmd == MEM_LOAD))
                && (predecode.is_store == (uop.mem_cmd == MEM_STORE))
                && (predecode.is_muldiv == decoder_is_muldiv)
                && ((predecode.is_muldiv && !inst[14])
                    == (decoder_is_muldiv
                        && (uop.muldiv_op <= MULDIV_MULHU)));
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
            if (!issue_metadata_matches())
                $fatal(1,
                       "[FAIL] %s: predecode issue metadata differs from full decoder (inst=%08x)",
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

    initial begin
        inst = 32'd0;
        case_count = 0;
        current_case = "initial";
        #1;

        begin_case(enc_r(7'h00, 5'd2, 5'd1, 3'b000, 5'd3, OP_R_TYPE),
                   "ADD semantic uop");
        check(uop.exec_unit == EXEC_ALU, "execution unit");
        check(uop.alu_op == ALU_ADD, "ALU operation");
        check(uop.src0_used && uop.src1_used && uop.dst_write,
              "register use/write metadata");
        check((uop.src0_addr == 5'd1) && (uop.src1_addr == 5'd2)
              && (uop.dst_addr == 5'd3), "register addresses");
        check((uop.wb_src == WB_EXEC) && (uop.lane_mask == 2'b11)
              && !uop.block_younger, "writeback and issue policy");
        check(predecode.is_alu_type && predecode.writes_dst
              && predecode.uses_src0 && predecode.uses_src1,
              "frontend metadata");

        begin_case(enc_r(7'h20, 5'd6, 5'd5, 3'b000, 5'd4, OP_R_TYPE),
                   "SUB semantic uop");
        check((uop.exec_unit == EXEC_ALU) && (uop.alu_op == ALU_SUB),
              "SUB operation");

        begin_case(enc_i(12'hff0, 5'd8, 3'b000, 5'd7, OP_I_ALU),
                   "negative ADDI immediate");
        check((uop.imm == 32'hffff_fff0)
              && (uop.operand_b_sel == OPERAND_B_IMM),
              "expanded immediate");
        check(uop.src0_used && !uop.src1_used && uop.dst_write,
              "I-type register metadata");

        begin_case(enc_i(12'h41f, 5'd10, 3'b101, 5'd9, OP_I_ALU),
                   "SRAI semantic operation");
        check((uop.alu_op == ALU_SRA) && (uop.imm == 32'h0000_041f),
              "SRAI operation and immediate");

        begin_case(enc_i(12'h004, 5'd3, 3'b100, 5'd11, OP_LOAD),
                   "LBU memory uop");
        check((uop.exec_unit == EXEC_LSU) && (uop.mem_cmd == MEM_LOAD)
              && (uop.mem_size == MEM_BYTE) && uop.mem_unsigned,
              "load semantics");
        check((uop.wb_src == WB_LOAD) && uop.src0_used && uop.dst_write,
              "load source and writeback");
        check(predecode.is_load && predecode.is_lsu,
              "load frontend metadata");

        begin_case(enc_s(12'hff8, 5'd9, 5'd3, 3'b010),
                   "negative-offset SW uop");
        check((uop.mem_cmd == MEM_STORE) && (uop.mem_size == MEM_WORD)
              && (uop.imm == 32'hffff_fff8), "store semantics");
        check(uop.src0_used && uop.src1_used && !uop.dst_write,
              "store register metadata");

        begin_case(enc_b(13'h1ffc, 5'd2, 5'd1, 3'b110),
                   "backward BLTU uop");
        check((uop.exec_unit == EXEC_BRANCH)
              && (uop.control_flow == CF_CONDITIONAL)
              && (uop.branch_op == BR_LTU), "conditional control semantics");
        check((uop.imm == 32'hffff_fffc)
              && (uop.operand_a_sel == OPERAND_A_PC)
              && (uop.target_base == TARGET_PC), "branch target metadata");
        check(uop.cfi_update && (uop.cfi_type == CFI_TYPE_BRANCH),
              "branch predictor metadata");

        begin_case(enc_j(21'd8, 5'd1), "JAL call uop");
        check((uop.control_flow == CF_DIRECT) && (uop.imm == 32'd8)
              && (uop.wb_src == WB_NEXT_PC), "direct control semantics");
        check(uop.dst_write && uop.cfi_update
              && (uop.cfi_type == CFI_TYPE_CALL), "call metadata");
        check(predecode.is_direct_jump && predecode.is_cfi,
              "direct-control frontend metadata");

        begin_case(enc_i(12'd0, 5'd1, 3'b000, 5'd0, OP_JALR),
                   "JALR return uop");
        check((uop.control_flow == CF_INDIRECT)
              && (uop.target_base == TARGET_SRC0)
              && (uop.target_clear_mask == 2'b01),
              "indirect target semantics");
        check(uop.cfi_update && (uop.cfi_type == CFI_TYPE_RETURN)
              && uop.block_younger, "return and issue metadata");
        check(predecode.is_indirect_jump && predecode.block_younger,
              "indirect-control frontend metadata");

        begin_case(enc_u(20'h12345, 5'd12, OP_LUI), "LUI uop");
        check((uop.operand_a_sel == OPERAND_A_ZERO)
              && (uop.imm == 32'h1234_5000) && uop.dst_write,
              "LUI operands");

        begin_case(enc_u(20'habcde, 5'd13, OP_AUIPC), "AUIPC uop");
        check((uop.operand_a_sel == OPERAND_A_PC)
              && (uop.imm == 32'habcd_e000) && uop.dst_write,
              "AUIPC operands");

        begin_case(enc_r(MULDIV_FUNCT7, 5'd2, 5'd1, 3'b000, 5'd14,
                         OP_R_TYPE), "MUL uop");
        check((uop.exec_unit == EXEC_MULDIV)
              && (uop.muldiv_op == MULDIV_MUL), "multiply operation");
        check((uop.lane_mask == 2'b01) && !uop.block_younger
              && !uop.serializing, "multiply issue policy");
        check(predecode.is_muldiv && (predecode.lane_mask == 2'b01),
              "multiply frontend metadata");

        begin_case(enc_r(MULDIV_FUNCT7, 5'd2, 5'd1, 3'b100, 5'd15,
                         OP_R_TYPE), "DIV uop");
        check((uop.muldiv_op == MULDIV_DIV) && uop.block_younger
              && uop.serializing, "divide operation and issue policy");

        begin_case(enc_i(12'h300, 5'd4, 3'b001, 5'd3, OP_SYSTEM),
                   "CSRRW register-source uop");
        check((uop.exec_unit == EXEC_PRIV) && (uop.priv_op == PRIV_REG)
              && (uop.priv_cmd == PRIV_CMD_WRITE), "privileged operation");
        check(!uop.priv_uses_imm && uop.src0_used && uop.dst_write
              && (uop.priv_addr == 16'h0300), "CSR operand metadata");
        check(predecode.is_privileged && predecode.uses_src0
              && (predecode.lane_mask == 2'b01), "CSR frontend metadata");

        begin_case(enc_i(12'h304, 5'd0, 3'b110, 5'd5, OP_SYSTEM),
                   "CSRRSI immediate-source uop");
        check((uop.priv_op == PRIV_REG) && uop.priv_uses_imm
              && (uop.priv_cmd == PRIV_CMD_SET), "immediate CSR operation");
        check(!uop.src0_used && (uop.priv_imm == 5'd0),
              "immediate CSR source metadata");

        begin_case(RISCV_ECALL, "ECALL privileged flow");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.priv_op == PRIV_SYSCALL)
              && (uop.exception == EXCEPTION_NONE), "ECALL semantics");
        check(predecode.is_privileged_flow && predecode.block_younger,
              "ECALL frontend metadata");

        begin_case(RISCV_MRET, "MRET privileged flow");
        check((uop.exec_unit == EXEC_PRIV) && (uop.priv_op == PRIV_RETURN),
              "MRET semantics");

        begin_case(RISCV_EBREAK, "EBREAK exception metadata");
        check((uop.exec_unit == EXEC_PRIV)
              && (uop.exception == EXCEPTION_BREAKPOINT)
              && (uop.priv_op == PRIV_NONE), "breakpoint metadata");

        begin_case(32'h0000_000f, "serialized FENCE uop");
        check((uop.exec_unit == EXEC_FENCE)
              && (uop.exception == EXCEPTION_NONE)
              && uop.block_younger && uop.serializing,
              "FENCE issue policy");
        check(predecode.is_fence && predecode.serializing,
              "FENCE frontend metadata");

        begin_case(enc_r(7'h10, 5'd2, 5'd1, 3'b000, 5'd3, OP_R_TYPE),
                   "unsupported R encoding");
        check((uop.exec_unit == EXEC_NONE)
              && (uop.exception == EXCEPTION_ILLEGAL)
              && !uop.dst_write && (uop.mem_cmd == MEM_NONE),
              "unsupported instruction is side-effect free");
        check(predecode.block_younger && predecode.serializing,
              "unsupported R frontend containment");

        begin_case(32'h0000_0000, "non-32-bit encoding containment");
        check((uop.exception == EXCEPTION_ILLEGAL) && !uop.dst_write,
              "invalid decode defaults");
        check(predecode.is_illegal && (predecode.lane_mask == 2'b01)
              && predecode.block_younger && predecode.serializing,
              "invalid frontend containment");

        $display("[PASS] RISC-V decoded-uop contract directed test (%0d cases)",
                 case_count);
        $finish;
    end

endmodule
