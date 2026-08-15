#include "la32_decode.hpp"

namespace archsim {
namespace {

template <unsigned Bits>
std::uint32_t sign_extend(const std::uint32_t value) {
    static_assert(Bits > 0 && Bits < 32);
    return static_cast<std::uint32_t>(
        static_cast<std::int32_t>(value << (32u - Bits)) >>
        (32u - Bits));
}

constexpr std::uint32_t op17(const unsigned op4, const unsigned op2,
                             const unsigned op5) {
    return (op4 << 7u) | (op2 << 5u) | op5;
}

void set_common_metadata(La32DecodedInstruction& decoded) {
    using Kind = La32InstructionKind;
    switch (decoded.kind) {
        case Kind::AddW: case Kind::SubW: case Kind::Slt: case Kind::Sltu:
        case Kind::Nor: case Kind::And: case Kind::Or: case Kind::Xor:
        case Kind::SllW: case Kind::SrlW: case Kind::SraW:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.writes_rd = true;
            decoded.is_alu_type = true;
            break;
        case Kind::Slti: case Kind::Sltui: case Kind::AddiW:
        case Kind::Andi: case Kind::Ori: case Kind::Xori:
        case Kind::SlliW: case Kind::SrliW: case Kind::SraiW:
            decoded.uses_src0 = true;
            decoded.writes_rd = true;
            decoded.is_alu_type = true;
            break;
        case Kind::Lu12iW: case Kind::Pcaddu12i:
            decoded.writes_rd = true;
            decoded.is_alu_type = true;
            break;
        case Kind::MulW: case Kind::MulhW: case Kind::MulhWu:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.writes_rd = true;
            decoded.is_mul = true;
            break;
        case Kind::DivW: case Kind::DivWu: case Kind::ModW: case Kind::ModWu:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.writes_rd = true;
            decoded.is_divmod = true;
            break;
        case Kind::LdB: case Kind::LdBu: case Kind::LdH:
        case Kind::LdHu: case Kind::LdW:
            decoded.uses_src0 = true;
            decoded.writes_rd = true;
            decoded.is_load = true;
            break;
        case Kind::StB: case Kind::StH: case Kind::StW:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.is_store = true;
            break;
        case Kind::Beq: case Kind::Bne: case Kind::Blt:
        case Kind::Bge: case Kind::Bltu: case Kind::Bgeu:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.is_conditional = true;
            break;
        case Kind::B:
            decoded.is_direct = true;
            break;
        case Kind::Bl:
            decoded.rd = 1;
            decoded.writes_rd = true;
            decoded.is_direct = true;
            break;
        case Kind::Jirl:
            decoded.uses_src0 = true;
            decoded.writes_rd = true;
            decoded.is_jirl = true;
            break;
        case Kind::Cpucfg:
            decoded.uses_src0 = true;
            decoded.writes_rd = true;
            decoded.is_privileged = true;
            break;
        case Kind::Rdcntvl: case Kind::Rdcntvh: case Kind::Rdcntid:
            decoded.writes_rd = true;
            decoded.is_privileged = true;
            break;
        case Kind::Csrrd:
            decoded.writes_rd = true;
            decoded.is_privileged = true;
            break;
        case Kind::Csrwr:
            decoded.uses_src0 = true;
            decoded.writes_rd = true;
            decoded.is_privileged = true;
            break;
        case Kind::Csrxchg:
            decoded.uses_src0 = true;
            decoded.uses_src1 = true;
            decoded.writes_rd = true;
            decoded.is_privileged = true;
            break;
        case Kind::Syscall: case Kind::Ertn: case Kind::Break:
            decoded.is_privileged = true;
            break;
        case Kind::Illegal:
            return;
    }

    decoded.legal = true;
    decoded.slot1_allowed = decoded.is_alu_type || decoded.is_load ||
                            decoded.is_store || decoded.is_conditional ||
                            decoded.is_direct || decoded.is_jirl;
    const bool younger_allowed = decoded.is_alu_type || decoded.is_mul ||
                                 decoded.is_load || decoded.is_store ||
                                 decoded.is_conditional || decoded.is_direct;
    decoded.block_younger = !younger_allowed;
}

}  // namespace

La32DecodedInstruction decode_la32_instruction(
    const std::uint32_t instruction) {
    using Kind = La32InstructionKind;
    La32DecodedInstruction decoded;
    const auto encoded_op17 = instruction >> 15u;
    const auto encoded_op10 = instruction >> 22u;
    const auto encoded_op7 = instruction >> 25u;
    const auto encoded_op6 = instruction >> 26u;
    const auto rd = static_cast<std::uint8_t>(instruction & 0x1fu);
    const auto rj = static_cast<std::uint8_t>((instruction >> 5u) & 0x1fu);
    const auto rk = static_cast<std::uint8_t>((instruction >> 10u) & 0x1fu);

    decoded.rd = rd;
    decoded.src0 = rj;
    decoded.src1 = rk;

    // Privileged encodings have priority in the RTL decoder.
    if (encoded_op17 == 0u && rk == 27u) {
        decoded.kind = Kind::Cpucfg;
    } else if (encoded_op17 == 0u && rk == 24u && rj == 0u) {
        decoded.kind = Kind::Rdcntvl;
    } else if (encoded_op17 == 0u && rk == 24u && rd == 0u) {
        decoded.kind = Kind::Rdcntid;
        decoded.rd = rj;
    } else if (encoded_op17 == 0u && rk == 25u && rj == 0u) {
        decoded.kind = Kind::Rdcntvh;
    } else if ((instruction >> 24u) == 0x04u) {
        decoded.csr_address =
            static_cast<std::uint16_t>((instruction >> 10u) & 0x3fffu);
        decoded.src0 = rd;
        decoded.src1 = rj;
        decoded.kind = rj == 0u ? Kind::Csrrd
                     : rj == 1u ? Kind::Csrwr : Kind::Csrxchg;
    } else if (encoded_op17 == op17(0u, 2u, 0x16u)) {
        decoded.kind = Kind::Syscall;
    } else if (instruction == 0x0648'3800u) {
        decoded.kind = Kind::Ertn;
    } else if (encoded_op17 == op17(0u, 2u, 0x14u)) {
        decoded.kind = Kind::Break;
    } else {
        switch (encoded_op17) {
            case op17(0u, 1u, 0x00u): decoded.kind = Kind::AddW; break;
            case op17(0u, 1u, 0x02u): decoded.kind = Kind::SubW; break;
            case op17(0u, 1u, 0x04u): decoded.kind = Kind::Slt; break;
            case op17(0u, 1u, 0x05u): decoded.kind = Kind::Sltu; break;
            case op17(0u, 1u, 0x08u): decoded.kind = Kind::Nor; break;
            case op17(0u, 1u, 0x09u): decoded.kind = Kind::And; break;
            case op17(0u, 1u, 0x0au): decoded.kind = Kind::Or; break;
            case op17(0u, 1u, 0x0bu): decoded.kind = Kind::Xor; break;
            case op17(0u, 1u, 0x0eu): decoded.kind = Kind::SllW; break;
            case op17(0u, 1u, 0x0fu): decoded.kind = Kind::SrlW; break;
            case op17(0u, 1u, 0x10u): decoded.kind = Kind::SraW; break;
            case op17(0u, 1u, 0x18u): decoded.kind = Kind::MulW; break;
            case op17(0u, 1u, 0x19u): decoded.kind = Kind::MulhW; break;
            case op17(0u, 1u, 0x1au): decoded.kind = Kind::MulhWu; break;
            case op17(0u, 2u, 0x00u): decoded.kind = Kind::DivW; break;
            case op17(0u, 2u, 0x01u): decoded.kind = Kind::ModW; break;
            case op17(0u, 2u, 0x02u): decoded.kind = Kind::DivWu; break;
            case op17(0u, 2u, 0x03u): decoded.kind = Kind::ModWu; break;
            case op17(1u, 0u, 0x01u): decoded.kind = Kind::SlliW; break;
            case op17(1u, 0u, 0x09u): decoded.kind = Kind::SrliW; break;
            case op17(1u, 0u, 0x11u): decoded.kind = Kind::SraiW; break;
            default: break;
        }
        if (decoded.kind == Kind::Illegal) {
            switch (encoded_op10) {
                case 0x008u: decoded.kind = Kind::Slti; break;
                case 0x009u: decoded.kind = Kind::Sltui; break;
                case 0x00au: decoded.kind = Kind::AddiW; break;
                case 0x00du: decoded.kind = Kind::Andi; break;
                case 0x00eu: decoded.kind = Kind::Ori; break;
                case 0x00fu: decoded.kind = Kind::Xori; break;
                case 0x0a0u: decoded.kind = Kind::LdB; break;
                case 0x0a1u: decoded.kind = Kind::LdH; break;
                case 0x0a2u: decoded.kind = Kind::LdW; break;
                case 0x0a4u: decoded.kind = Kind::StB; break;
                case 0x0a5u: decoded.kind = Kind::StH; break;
                case 0x0a6u: decoded.kind = Kind::StW; break;
                case 0x0a8u: decoded.kind = Kind::LdBu; break;
                case 0x0a9u: decoded.kind = Kind::LdHu; break;
                default: break;
            }
        }
        if (decoded.kind == Kind::Illegal) {
            if (encoded_op7 == 0x0au) decoded.kind = Kind::Lu12iW;
            else if (encoded_op7 == 0x0eu) decoded.kind = Kind::Pcaddu12i;
        }
        if (decoded.kind == Kind::Illegal) {
            switch (encoded_op6) {
                case 0x13u: decoded.kind = Kind::Jirl; break;
                case 0x14u: decoded.kind = Kind::B; break;
                case 0x15u: decoded.kind = Kind::Bl; break;
                case 0x16u: decoded.kind = Kind::Beq; break;
                case 0x17u: decoded.kind = Kind::Bne; break;
                case 0x18u: decoded.kind = Kind::Blt; break;
                case 0x19u: decoded.kind = Kind::Bge; break;
                case 0x1au: decoded.kind = Kind::Bltu; break;
                case 0x1bu: decoded.kind = Kind::Bgeu; break;
                default: break;
            }
        }
    }

    if (decoded.kind == Kind::SlliW || decoded.kind == Kind::SrliW ||
        decoded.kind == Kind::SraiW) {
        decoded.immediate = rk;
    } else if (decoded.kind == Kind::Andi || decoded.kind == Kind::Ori ||
               decoded.kind == Kind::Xori) {
        decoded.immediate = (instruction >> 10u) & 0xfffu;
    } else if (decoded.kind == Kind::Slti || decoded.kind == Kind::Sltui ||
               decoded.kind == Kind::AddiW || decoded.kind == Kind::LdB ||
               decoded.kind == Kind::LdBu || decoded.kind == Kind::LdH ||
               decoded.kind == Kind::LdHu || decoded.kind == Kind::LdW ||
               decoded.kind == Kind::StB || decoded.kind == Kind::StH ||
               decoded.kind == Kind::StW) {
        decoded.immediate = sign_extend<12>((instruction >> 10u) & 0xfffu);
    } else if (decoded.kind == Kind::Lu12iW ||
               decoded.kind == Kind::Pcaddu12i) {
        decoded.immediate = (instruction >> 5u) << 12u;
    } else if (decoded.kind == Kind::Jirl ||
               (decoded.kind >= Kind::Beq && decoded.kind <= Kind::Bgeu)) {
        decoded.immediate = sign_extend<18>(
            ((instruction >> 10u) & 0xffffu) << 2u);
    } else if (decoded.kind == Kind::B || decoded.kind == Kind::Bl) {
        const auto immediate26 = ((instruction & 0x3ffu) << 16u) |
                                 ((instruction >> 10u) & 0xffffu);
        decoded.immediate = sign_extend<28>(immediate26 << 2u);
    }

    const bool conditional = decoded.kind >= Kind::Beq &&
                             decoded.kind <= Kind::Bgeu;
    if (decoded.kind == Kind::StB || decoded.kind == Kind::StH ||
        decoded.kind == Kind::StW || conditional) {
        decoded.src1 = rd;
    }
    set_common_metadata(decoded);
    return decoded;
}

const char* la32_instruction_name(const La32InstructionKind kind) {
    using Kind = La32InstructionKind;
    switch (kind) {
#define LA_NAME(value, text) case Kind::value: return text
        LA_NAME(Illegal, "illegal");
        LA_NAME(AddW, "add.w"); LA_NAME(SubW, "sub.w");
        LA_NAME(Slt, "slt"); LA_NAME(Sltu, "sltu");
        LA_NAME(Nor, "nor"); LA_NAME(And, "and"); LA_NAME(Or, "or");
        LA_NAME(Xor, "xor"); LA_NAME(SllW, "sll.w");
        LA_NAME(SrlW, "srl.w"); LA_NAME(SraW, "sra.w");
        LA_NAME(Slti, "slti"); LA_NAME(Sltui, "sltui");
        LA_NAME(AddiW, "addi.w"); LA_NAME(Andi, "andi");
        LA_NAME(Ori, "ori"); LA_NAME(Xori, "xori");
        LA_NAME(SlliW, "slli.w"); LA_NAME(SrliW, "srli.w");
        LA_NAME(SraiW, "srai.w"); LA_NAME(Lu12iW, "lu12i.w");
        LA_NAME(Pcaddu12i, "pcaddu12i"); LA_NAME(MulW, "mul.w");
        LA_NAME(MulhW, "mulh.w"); LA_NAME(MulhWu, "mulh.wu");
        LA_NAME(DivW, "div.w"); LA_NAME(DivWu, "div.wu");
        LA_NAME(ModW, "mod.w"); LA_NAME(ModWu, "mod.wu");
        LA_NAME(LdB, "ld.b"); LA_NAME(LdBu, "ld.bu");
        LA_NAME(LdH, "ld.h"); LA_NAME(LdHu, "ld.hu");
        LA_NAME(LdW, "ld.w"); LA_NAME(StB, "st.b");
        LA_NAME(StH, "st.h"); LA_NAME(StW, "st.w");
        LA_NAME(Beq, "beq"); LA_NAME(Bne, "bne");
        LA_NAME(Blt, "blt"); LA_NAME(Bge, "bge");
        LA_NAME(Bltu, "bltu"); LA_NAME(Bgeu, "bgeu");
        LA_NAME(B, "b"); LA_NAME(Bl, "bl"); LA_NAME(Jirl, "jirl");
        LA_NAME(Cpucfg, "cpucfg"); LA_NAME(Rdcntvl, "rdcntvl.w");
        LA_NAME(Rdcntvh, "rdcntvh.w"); LA_NAME(Rdcntid, "rdcntid.w");
        LA_NAME(Csrrd, "csrrd"); LA_NAME(Csrwr, "csrwr");
        LA_NAME(Csrxchg, "csrxchg"); LA_NAME(Syscall, "syscall");
        LA_NAME(Ertn, "ertn"); LA_NAME(Break, "break");
#undef LA_NAME
    }
    return "illegal";
}

}  // namespace archsim
