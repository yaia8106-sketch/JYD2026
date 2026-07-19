// ============================================================
// Module: frontend_predecode
// Description: Stateless instruction classification for the fetch queue.
// Domain: frontend.
// ============================================================

module frontend_predecode
    import cpu_defs::*;
(
    input  logic [31:0]         inst,
    output frontend_predecode_t decoded
);

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    // Base R-type instructions use funct7=0, except SUB/SRA at funct7=0x20.
    // The multiplier family has its own supported Slot-0 pairing path; other
    // non-base encodings remain single-issue.
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

    // SLLI/SRLI/SRAI are the only supported shift-immediate encodings.  Any
    // other encoding in these funct3 classes is kept single-issue so the real
    // decoder can retire it as a side-effect-free unsupported instruction.
    wire is_shift_immediate = funct3[1:0] == 2'b01;
    wire i_is_base_shift = funct7_is_zero
                         | (funct7_is_alt_base & funct3_is_right_shift);
    wire force_single_nonbase_i = (opcode == OP_I_ALU)
                                & is_shift_immediate & ~i_is_base_shift;
    wire force_single_nonbase_alu = force_single_nonbase_r
                                  | force_single_nonbase_i;

    // Predecode is intentionally shallow: it classifies enough information for
    // pairing and prediction metadata without replacing the real decoder.
    always_comb begin
        decoded = '0;

        decoded.is_branch = opcode == OP_BRANCH;
        decoded.is_jal = opcode == OP_JAL;
        decoded.is_jalr = opcode == OP_JALR;
        decoded.is_system = opcode == OP_SYSTEM;
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

        decoded.writes_rd =
            (opcode == OP_R_TYPE)
            || (opcode == OP_I_ALU)
            || (opcode == OP_LOAD)
            || (opcode == OP_LUI)
            || (opcode == OP_AUIPC)
            || (opcode == OP_JAL)
            || (opcode == OP_JALR)
            || (opcode == OP_SYSTEM);
        decoded.uses_rs1 =
            (opcode == OP_R_TYPE)
            || (opcode == OP_I_ALU)
            || (opcode == OP_LOAD)
            || (opcode == OP_STORE)
            || (opcode == OP_BRANCH)
            || (opcode == OP_JALR);
        decoded.uses_rs2 =
            (opcode == OP_R_TYPE)
            || (opcode == OP_STORE)
            || (opcode == OP_BRANCH);

        decoded.is_jump =
            decoded.is_jal | decoded.is_jalr | decoded.is_system;
        decoded.is_control =
            decoded.is_branch
            | decoded.is_jal
            | decoded.is_jalr
            | decoded.is_system;
        decoded.is_lsu = decoded.is_load | decoded.is_store;
        decoded.is_cfi =
            decoded.is_branch | decoded.is_jal | decoded.is_jalr;
        // MUL/MULH/MULHSU/MULHU may occupy Slot 0 beside a supported younger
        // instruction. DIV/REM remain multi-cycle and therefore serializing.
        // Slot 1 never owns the shared MulDiv unit, so every M operation found
        // there is buffered and later issued through Slot 0.
        decoded.force_single_slot0 =
            decoded.is_jalr
            | decoded.is_system
            | decoded.is_fence
            | decoded.is_illegal
            | (decoded.is_muldiv & funct3[2])
            | force_single_nonbase_alu;
        decoded.force_single_slot1 =
            decoded.is_system
            | decoded.is_fence
            | decoded.is_illegal
            | decoded.is_muldiv
            | force_single_nonbase_alu;
    end

endmodule
