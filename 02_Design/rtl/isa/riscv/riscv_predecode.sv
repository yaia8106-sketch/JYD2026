// ============================================================
// Module: riscv_predecode
// Description: Shallow RISC-V classification for fetch/pairing policy.
// ============================================================

module riscv_predecode
    import cpu_defs::*;
    import riscv_defs::*;
(
    input  logic [31:0]         inst,
    output frontend_predecode_t decoded
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    wire funct7_is_zero = ~|funct7;
    wire funct7_is_alt_base = funct7 == 7'h20;
    wire r_is_muldiv = (opcode == OP_R_TYPE)
                     & (funct7 == MULDIV_FUNCT7);
    wire funct3_is_sub = funct3 == 3'b000;
    wire funct3_is_right_shift = funct3 == 3'b101;
    wire r_is_base_alt = funct7_is_alt_base
                       & (funct3_is_sub | funct3_is_right_shift);
    wire r_base_legal = (opcode == OP_R_TYPE)
                      & (funct7_is_zero | r_is_base_alt);
    wire r_type_legal = r_base_legal | r_is_muldiv;
    wire force_single_nonbase_r = (opcode == OP_R_TYPE) & ~r_type_legal;

    wire is_shift_immediate = funct3[1:0] == 2'b01;
    wire i_is_base_shift = funct7_is_zero
                         | (funct7_is_alt_base & funct3_is_right_shift);
    wire i_alu_legal = (opcode == OP_I_ALU)
                     & (~is_shift_immediate | i_is_base_shift);
    wire force_single_nonbase_i = (opcode == OP_I_ALU) & ~i_alu_legal;
    wire force_single_nonbase_alu = force_single_nonbase_r
                                  | force_single_nonbase_i;

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
    wire is_csr = (opcode == OP_SYSTEM) & csr_funct3_legal;
    wire is_privileged_flow = (opcode == OP_SYSTEM) & (funct3 == 3'b000);
    wire system_legal = is_csr
                      | (inst == RISCV_ECALL)
                      | (inst == RISCV_EBREAK)
                      | (inst == RISCV_MRET);
    wire instruction_legal = r_type_legal | i_alu_legal
                           | load_legal | store_legal | branch_legal
                           | (opcode == OP_LUI) | (opcode == OP_AUIPC)
                           | (opcode == OP_JAL) | jalr_legal
                           | system_legal | (opcode == OP_FENCE);
    wire instruction_illegal = ~instruction_legal;
    wire blocks_younger = jalr_legal
                        | (opcode == OP_SYSTEM)
                        | (opcode == OP_FENCE)
                        | instruction_illegal
                        | (r_is_muldiv & funct3[2])
                        | force_single_nonbase_alu;
    wire slot1_forbidden = (opcode == OP_SYSTEM)
                         | (opcode == OP_FENCE)
                         | instruction_illegal
                         | r_is_muldiv
                         | force_single_nonbase_alu;

    always_comb begin
        decoded = '0;

        decoded.is_conditional_branch = branch_legal;
        decoded.is_direct_jump = opcode == OP_JAL;
        decoded.is_indirect_jump = jalr_legal;
        decoded.is_privileged = opcode == OP_SYSTEM;
        decoded.is_privileged_flow = is_privileged_flow;
        decoded.is_fence = opcode == OP_FENCE;
        decoded.is_illegal = instruction_illegal;
        decoded.is_muldiv = r_is_muldiv;
        decoded.is_mul = r_is_muldiv & ~funct3[2];
        decoded.is_load = load_legal;
        decoded.is_store = store_legal;
        decoded.is_alu_type = r_base_legal
            || i_alu_legal
            || (opcode == OP_LUI)
            || (opcode == OP_AUIPC);

        decoded.writes_dst = r_type_legal
            || i_alu_legal
            || load_legal
            || (opcode == OP_LUI)
            || (opcode == OP_AUIPC)
            || (opcode == OP_JAL)
            || jalr_legal
            || is_csr;
        decoded.uses_src0 = r_type_legal
            || i_alu_legal
            || load_legal
            || store_legal
            || branch_legal
            || jalr_legal
            || (is_csr & ~funct3[2]);
        decoded.uses_src1 = r_type_legal
            || store_legal
            || branch_legal;
        decoded.src0_addr = inst[19:15];
        decoded.src1_addr = inst[24:20];
        decoded.dst_addr = inst[11:7];

        decoded.is_jump = decoded.is_direct_jump
                        | decoded.is_indirect_jump
                        | decoded.is_privileged_flow;
        decoded.is_control = decoded.is_conditional_branch
                           | decoded.is_direct_jump
                           | decoded.is_indirect_jump
                           | decoded.is_privileged_flow;
        decoded.is_lsu = decoded.is_load | decoded.is_store;
        decoded.is_cfi = decoded.is_conditional_branch
                       | decoded.is_direct_jump
                       | decoded.is_indirect_jump;

        decoded.lane_mask = slot1_forbidden ? 2'b01 : 2'b11;
        decoded.block_younger = blocks_younger;
        decoded.serializing = (opcode == OP_SYSTEM)
                            | (opcode == OP_FENCE)
                            | instruction_illegal
                            | (r_is_muldiv & funct3[2])
                            | force_single_nonbase_alu;
    end

endmodule

module isa_predecode
    import cpu_defs::*;
(
    input  logic [31:0]         inst,
    output frontend_predecode_t decoded
);
    riscv_predecode u_impl (
        .inst    (inst),
        .decoded (decoded)
    );
endmodule
