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
    wire force_single_nonbase_r = (opcode == OP_R_TYPE)
                                & ~funct7_is_zero & ~r_is_base_alt
                                & ~r_is_muldiv;

    wire is_shift_immediate = funct3[1:0] == 2'b01;
    wire i_is_base_shift = funct7_is_zero
                         | (funct7_is_alt_base & funct3_is_right_shift);
    wire force_single_nonbase_i = (opcode == OP_I_ALU)
                                & is_shift_immediate & ~i_is_base_shift;
    wire force_single_nonbase_alu = force_single_nonbase_r
                                  | force_single_nonbase_i;

    wire csr_funct3_legal = (funct3 == 3'b001) | (funct3 == 3'b010)
                          | (funct3 == 3'b011) | (funct3 == 3'b101)
                          | (funct3 == 3'b110) | (funct3 == 3'b111);
    wire is_csr = (opcode == OP_SYSTEM) & csr_funct3_legal;
    wire is_privileged_flow = (opcode == OP_SYSTEM) & (funct3 == 3'b000);
    wire blocks_younger = (opcode == OP_JALR)
                        | (opcode == OP_SYSTEM)
                        | (opcode == OP_FENCE)
                        | (inst[1:0] != 2'b11)
                        | (r_is_muldiv & funct3[2])
                        | force_single_nonbase_alu;
    wire slot1_forbidden = (opcode == OP_SYSTEM)
                         | (opcode == OP_FENCE)
                         | (inst[1:0] != 2'b11)
                         | r_is_muldiv
                         | force_single_nonbase_alu;

    always_comb begin
        decoded = '0;

        decoded.is_conditional_branch = opcode == OP_BRANCH;
        decoded.is_direct_jump = opcode == OP_JAL;
        decoded.is_indirect_jump = opcode == OP_JALR;
        decoded.is_privileged = opcode == OP_SYSTEM;
        decoded.is_privileged_flow = is_privileged_flow;
        decoded.is_fence = opcode == OP_FENCE;
        decoded.is_illegal = inst[1:0] != 2'b11;
        decoded.is_muldiv = r_is_muldiv;
        decoded.is_load = opcode == OP_LOAD;
        decoded.is_store = opcode == OP_STORE;
        decoded.is_alu_type =
            ((opcode == OP_R_TYPE) && !decoded.is_muldiv)
            || (opcode == OP_I_ALU)
            || (opcode == OP_LUI)
            || (opcode == OP_AUIPC);

        decoded.writes_dst =
            (opcode == OP_R_TYPE)
            || (opcode == OP_I_ALU)
            || (opcode == OP_LOAD)
            || (opcode == OP_LUI)
            || (opcode == OP_AUIPC)
            || (opcode == OP_JAL)
            || (opcode == OP_JALR)
            || is_csr;
        decoded.uses_src0 =
            (opcode == OP_R_TYPE)
            || (opcode == OP_I_ALU)
            || (opcode == OP_LOAD)
            || (opcode == OP_STORE)
            || (opcode == OP_BRANCH)
            || (opcode == OP_JALR)
            || (is_csr & ~funct3[2]);
        decoded.uses_src1 =
            (opcode == OP_R_TYPE)
            || (opcode == OP_STORE)
            || (opcode == OP_BRANCH);
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
                            | (inst[1:0] != 2'b11)
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
