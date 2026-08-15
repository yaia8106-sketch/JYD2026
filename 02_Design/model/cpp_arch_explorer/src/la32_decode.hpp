#pragma once

#include <cstdint>

namespace archsim {

enum class La32InstructionKind : std::uint8_t {
    Illegal,
    AddW, SubW, Slt, Sltu, Nor, And, Or, Xor, SllW, SrlW, SraW,
    Slti, Sltui, AddiW, Andi, Ori, Xori, SlliW, SrliW, SraiW,
    Lu12iW, Pcaddu12i,
    MulW, MulhW, MulhWu, DivW, DivWu, ModW, ModWu,
    LdB, LdBu, LdH, LdHu, LdW, StB, StH, StW,
    Beq, Bne, Blt, Bge, Bltu, Bgeu, B, Bl, Jirl,
    Cpucfg, Rdcntvl, Rdcntvh, Rdcntid,
    Csrrd, Csrwr, Csrxchg, Syscall, Ertn, Break,
};

struct La32DecodedInstruction {
    La32InstructionKind kind = La32InstructionKind::Illegal;
    std::uint8_t rd = 0;
    std::uint8_t src0 = 0;
    std::uint8_t src1 = 0;
    std::uint32_t immediate = 0;
    std::uint16_t csr_address = 0;
    bool legal = false;
    bool writes_rd = false;
    bool uses_src0 = false;
    bool uses_src1 = false;
    bool is_alu_type = false;
    bool is_load = false;
    bool is_store = false;
    bool is_conditional = false;
    bool is_direct = false;
    bool is_jirl = false;
    bool is_mul = false;
    bool is_divmod = false;
    bool is_privileged = false;
    bool slot1_allowed = false;
    bool block_younger = true;
};

La32DecodedInstruction decode_la32_instruction(std::uint32_t instruction);
const char* la32_instruction_name(La32InstructionKind kind);

}  // namespace archsim
