// ============================================================
// Module: riscv_decoder
// Description: RV32I/M/Zicsr decoder to the ISA-neutral decoded-uop contract.
// ============================================================

module riscv_decoder
    import cpu_defs::*;
    import riscv_defs::*;
(
    input  logic [31:0] inst,
    output decoded_uop_t uop
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];
    wire [4:0] src0_addr = inst[19:15];
    wire [4:0] src1_addr = inst[24:20];
    wire [4:0] dst_addr = inst[11:7];

    wire r_base_legal = (funct7 == 7'b0000000)
                      | ((funct7 == 7'b0100000)
                         & ((funct3 == 3'b000) | (funct3 == 3'b101)));
    wire r_muldiv_legal = funct7 == MULDIV_FUNCT7;
    wire r_type_legal = (opcode == OP_R_TYPE)
                      & (r_base_legal | r_muldiv_legal);

    wire i_nonshift_legal = (funct3 == 3'b000)
                          | (funct3 == 3'b010)
                          | (funct3 == 3'b011)
                          | (funct3 == 3'b100)
                          | (funct3 == 3'b110)
                          | (funct3 == 3'b111);
    wire i_slli_legal = (funct3 == 3'b001) & (funct7 == 7'b0000000);
    wire i_right_shift_legal = (funct3 == 3'b101)
                             & ((funct7 == 7'b0000000)
                                | (funct7 == 7'b0100000));
    wire i_alu_legal = (opcode == OP_I_ALU)
                     & (i_nonshift_legal | i_slli_legal
                        | i_right_shift_legal);

    wire load_legal = (opcode == OP_LOAD)
                    & ((funct3 == 3'b000) | (funct3 == 3'b001)
                       | (funct3 == 3'b010) | (funct3 == 3'b100)
                       | (funct3 == 3'b101));
    wire store_legal = (opcode == OP_STORE)
                     & ((funct3 == 3'b000) | (funct3 == 3'b001)
                        | (funct3 == 3'b010));
    wire branch_legal = (opcode == OP_BRANCH)
                      & ((funct3 == 3'b000) | (funct3 == 3'b001)
                         | (funct3 == 3'b100) | (funct3 == 3'b101)
                         | (funct3 == 3'b110) | (funct3 == 3'b111));
    wire jalr_legal = (opcode == OP_JALR) & (funct3 == 3'b000);
    wire csr_funct3_legal = (funct3 == 3'b001) | (funct3 == 3'b010)
                          | (funct3 == 3'b011) | (funct3 == 3'b101)
                          | (funct3 == 3'b110) | (funct3 == 3'b111);
    wire csr_legal = (opcode == OP_SYSTEM) & csr_funct3_legal;
    wire is_ecall = inst == RISCV_ECALL;
    wire is_ebreak = inst == RISCV_EBREAK;
    wire is_mret = inst == RISCV_MRET;

    wire jal_call = (opcode == OP_JAL) & is_link_reg(dst_addr);
    wire jalr_call = jalr_legal & is_link_reg(dst_addr);
    wire jalr_return = jalr_legal & (dst_addr == 5'd0)
                     & is_link_reg(src0_addr) & (imm_i(inst) == 32'd0);

    always_comb begin
        // Safe unsupported-instruction defaults: no architectural side effect.
        uop = '0;
        uop.exec_unit = EXEC_NONE;
        uop.src0_addr = src0_addr;
        uop.src1_addr = src1_addr;
        uop.dst_addr = dst_addr;
        uop.operand_a_sel = OPERAND_A_SRC0;
        uop.operand_b_sel = OPERAND_B_SRC1;
        uop.alu_op = ALU_ADD;
        uop.wb_src = WB_NONE;
        uop.mem_cmd = MEM_NONE;
        uop.mem_size = MEM_WORD;
        uop.control_flow = CF_NONE;
        uop.branch_op = BR_NONE;
        uop.target_base = TARGET_PC;
        uop.cfi_type = CFI_TYPE_JUMP;
        uop.priv_op = PRIV_NONE;
        uop.priv_cmd = PRIV_CMD_NONE;
        uop.muldiv_op = MULDIV_MUL;
        uop.exception = EXCEPTION_ILLEGAL;
        uop.lane_mask = 2'b01;
        uop.block_younger = 1'b1;
        uop.serializing = 1'b1;

        if (r_type_legal) begin
            uop.exception = EXCEPTION_NONE;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;

            if (r_muldiv_legal) begin
                uop.exec_unit = EXEC_MULDIV;
                case (funct3)
                    3'b000: uop.muldiv_op = MULDIV_MUL;
                    3'b001: uop.muldiv_op = MULDIV_MULH;
                    3'b010: uop.muldiv_op = MULDIV_MULHSU;
                    3'b011: uop.muldiv_op = MULDIV_MULHU;
                    3'b100: uop.muldiv_op = MULDIV_DIV;
                    3'b101: uop.muldiv_op = MULDIV_DIVU;
                    3'b110: uop.muldiv_op = MULDIV_REM;
                    default: uop.muldiv_op = MULDIV_REMU;
                endcase
                // The shared MDU is owned by Slot 0. Multiply may still pair
                // with a younger supported instruction; DIV/REM serialize.
                uop.lane_mask = 2'b01;
                uop.block_younger = funct3[2];
                uop.serializing = funct3[2];
            end else begin
                uop.exec_unit = EXEC_ALU;
                case (funct3)
                    3'b000: uop.alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                    3'b001: uop.alu_op = ALU_SLL;
                    3'b010: uop.alu_op = ALU_SLT;
                    3'b011: uop.alu_op = ALU_SLTU;
                    3'b100: uop.alu_op = ALU_XOR;
                    3'b101: uop.alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: uop.alu_op = ALU_OR;
                    default: uop.alu_op = ALU_AND;
                endcase
            end
        end else if (i_alu_legal) begin
            uop.exec_unit = EXEC_ALU;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_i(inst);
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
            case (funct3)
                3'b000: uop.alu_op = ALU_ADD;
                3'b001: uop.alu_op = ALU_SLL;
                3'b010: uop.alu_op = ALU_SLT;
                3'b011: uop.alu_op = ALU_SLTU;
                3'b100: uop.alu_op = ALU_XOR;
                3'b101: uop.alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: uop.alu_op = ALU_OR;
                default: uop.alu_op = ALU_AND;
            endcase
        end else if (load_legal) begin
            uop.exec_unit = EXEC_LSU;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_i(inst);
            uop.wb_src = WB_LOAD;
            uop.mem_cmd = MEM_LOAD;
            case (funct3[1:0])
                2'b00: uop.mem_size = MEM_BYTE;
                2'b01: uop.mem_size = MEM_HALF;
                default: uop.mem_size = MEM_WORD;
            endcase
            uop.mem_unsigned = funct3[2];
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (store_legal) begin
            uop.exec_unit = EXEC_LSU;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_s(inst);
            uop.mem_cmd = MEM_STORE;
            case (funct3[1:0])
                2'b00: uop.mem_size = MEM_BYTE;
                2'b01: uop.mem_size = MEM_HALF;
                default: uop.mem_size = MEM_WORD;
            endcase
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (branch_legal) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.src0_used = 1'b1;
            uop.src1_used = 1'b1;
            uop.operand_a_sel = OPERAND_A_PC;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_b(inst);
            uop.control_flow = CF_CONDITIONAL;
            uop.target_base = TARGET_PC;
            uop.cfi_update = 1'b1;
            uop.cfi_type = CFI_TYPE_BRANCH;
            case (funct3)
                3'b000: uop.branch_op = BR_EQ;
                3'b001: uop.branch_op = BR_NE;
                3'b100: uop.branch_op = BR_LT;
                3'b101: uop.branch_op = BR_GE;
                3'b110: uop.branch_op = BR_LTU;
                default: uop.branch_op = BR_GEU;
            endcase
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (opcode == OP_LUI) begin
            uop.exec_unit = EXEC_ALU;
            uop.dst_write = 1'b1;
            uop.operand_a_sel = OPERAND_A_ZERO;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_u(inst);
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (opcode == OP_AUIPC) begin
            uop.exec_unit = EXEC_ALU;
            uop.dst_write = 1'b1;
            uop.operand_a_sel = OPERAND_A_PC;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_u(inst);
            uop.wb_src = WB_EXEC;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (opcode == OP_JAL) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.dst_write = 1'b1;
            uop.operand_a_sel = OPERAND_A_PC;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_j(inst);
            uop.wb_src = WB_NEXT_PC;
            uop.control_flow = CF_DIRECT;
            uop.branch_op = BR_ALWAYS;
            uop.target_base = TARGET_PC;
            uop.cfi_update = 1'b1;
            uop.cfi_type = jal_call ? CFI_TYPE_CALL : CFI_TYPE_JUMP;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b0;
            uop.serializing = 1'b0;
        end else if (jalr_legal) begin
            uop.exec_unit = EXEC_BRANCH;
            uop.src0_used = 1'b1;
            uop.dst_write = 1'b1;
            uop.operand_b_sel = OPERAND_B_IMM;
            uop.imm = imm_i(inst);
            uop.wb_src = WB_NEXT_PC;
            uop.control_flow = CF_INDIRECT;
            uop.branch_op = BR_ALWAYS;
            uop.target_base = TARGET_SRC0;
            uop.target_clear_mask = 2'b01;
            uop.cfi_update = jalr_call | jalr_return;
            uop.cfi_type = jalr_return ? CFI_TYPE_RETURN
                          : jalr_call ? CFI_TYPE_CALL
                                      : CFI_TYPE_JUMP;
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b11;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b0;
        end else if (csr_legal) begin
            uop.exec_unit = EXEC_PRIV;
            uop.src0_used = ~funct3[2];
            uop.dst_write = 1'b1;
            uop.wb_src = WB_EXEC;
            uop.priv_op = PRIV_REG;
            uop.priv_uses_imm = funct3[2];
            case (funct3[1:0])
                2'b01: uop.priv_cmd = PRIV_CMD_WRITE;
                2'b10: uop.priv_cmd = PRIV_CMD_SET;
                default: uop.priv_cmd = PRIV_CMD_CLEAR;
            endcase
            uop.priv_addr = {{(PRIV_ADDR_W-12){1'b0}}, inst[31:20]};
            uop.priv_imm = inst[19:15];
            uop.exception = EXCEPTION_NONE;
            uop.lane_mask = 2'b01;
            uop.block_younger = 1'b1;
            uop.serializing = 1'b1;
        end else if (is_ecall) begin
            uop.exec_unit = EXEC_PRIV;
            uop.priv_op = PRIV_SYSCALL;
            uop.exception = EXCEPTION_NONE;
        end else if (is_mret) begin
            uop.exec_unit = EXEC_PRIV;
            uop.priv_op = PRIV_RETURN;
            uop.exception = EXCEPTION_NONE;
        end else if (is_ebreak) begin
            // Breakpoint entry is exposed in the neutral decode contract but
            // remains side-effect free until precise exception plumbing lands.
            uop.exec_unit = EXEC_PRIV;
            uop.exception = EXCEPTION_BREAKPOINT;
        end else if (opcode == OP_FENCE) begin
            // Existing fence behavior is a serialized, side-effect-free uop.
            uop.exec_unit = EXEC_FENCE;
            uop.exception = EXCEPTION_NONE;
        end
    end

endmodule

// The common core instantiates this selected implementation name. Platform
// filelists compile exactly one ISA adapter, so no preprocessor selection is
// required inside the core.
module isa_decoder
    import cpu_defs::*;
(
    input  logic [31:0] inst,
    output decoded_uop_t uop
);
    riscv_decoder u_impl (
        .inst (inst),
        .uop  (uop)
    );
endmodule
