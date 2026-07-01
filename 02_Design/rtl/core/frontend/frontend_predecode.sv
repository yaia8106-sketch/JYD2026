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

    logic [6:0] opcode;

    always_comb begin
        opcode = inst[6:0];
        decoded = '0;

        decoded.is_branch = opcode == OP_BRANCH;
        decoded.is_jal = opcode == OP_JAL;
        decoded.is_jalr = opcode == OP_JALR;
        decoded.is_system = opcode == OP_SYSTEM;
        decoded.is_fence = opcode == OP_FENCE;
        decoded.is_illegal = inst[1:0] != 2'b11;
        decoded.is_muldiv =
            (opcode == OP_R_TYPE) && (inst[31:25] == MULDIV_FUNCT7);
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
        decoded.force_single_slot0 =
            decoded.is_jalr
            | decoded.is_system
            | decoded.is_fence
            | decoded.is_illegal
            | decoded.is_muldiv;
        decoded.force_single_slot1 =
            decoded.is_system
            | decoded.is_fence
            | decoded.is_illegal
            | decoded.is_muldiv;
    end

endmodule
