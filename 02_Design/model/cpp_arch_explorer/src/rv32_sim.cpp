#include "rv32_sim.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace archsim {
namespace {

template <unsigned Bits>
std::int32_t sign_extend(const std::uint32_t value) {
    static_assert(Bits > 0 && Bits < 32);
    return static_cast<std::int32_t>(value << (32u - Bits)) >> (32u - Bits);
}

std::uint32_t add_signed(const std::uint32_t lhs, const std::int32_t rhs) {
    return lhs + static_cast<std::uint32_t>(rhs);
}

std::string hex32(const std::uint32_t value) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return stream.str();
}

}  // namespace

std::vector<std::uint32_t> read_coe_words(const std::filesystem::path& path) {
    std::ifstream input(path);
    if (!input) {
        throw std::runtime_error("cannot open COE file: " + path.string());
    }

    std::vector<std::uint32_t> words;
    std::string line;
    bool in_vector = false;
    while (std::getline(input, line)) {
        if (!in_vector) {
            if (line.find("memory_initialization_vector") == std::string::npos) {
                continue;
            }
            in_vector = true;
            const auto equals = line.find('=');
            line = equals == std::string::npos ? std::string{} : line.substr(equals + 1u);
        }

        std::string token;
        const auto flush_token = [&]() {
            if (token.empty()) {
                return;
            }
            if (token.size() > 16u) {
                throw std::runtime_error("oversized COE token in " + path.string());
            }
            words.push_back(static_cast<std::uint32_t>(
                std::stoull(token, nullptr, 16)));
            token.clear();
        };

        for (const char character : line) {
            if (std::isxdigit(static_cast<unsigned char>(character)) != 0) {
                token.push_back(character);
            } else {
                flush_token();
            }
        }
        flush_token();
    }

    if (words.empty()) {
        throw std::runtime_error("no initialization words found in " + path.string());
    }
    return words;
}

std::uint32_t derive_stop_pc(const std::vector<std::uint32_t>& irom) {
    constexpr std::size_t kEntryWords = 0x100u / 4u;
    bool saw_startup_jal = false;
    const auto limit = std::min(irom.size(), kEntryWords);
    for (std::size_t index = 0; index < limit; ++index) {
        const auto instruction = irom[index];
        const auto opcode = instruction & 0x7fu;
        const auto rd = (instruction >> 7u) & 0x1fu;
        if (opcode == 0x6fu && rd != 0u) {
            saw_startup_jal = true;
        }
        if (instruction == 0x0000'006fu && saw_startup_jal) {
            return kIromBase + static_cast<std::uint32_t>(index * 4u);
        }
    }
    throw std::runtime_error("could not derive entry self-loop stop PC");
}

ProgramImage load_program(const std::filesystem::path& coe_root,
                          const std::string& name) {
    ProgramImage image;
    image.name = name;
    const auto directory = coe_root / name;
    image.irom = read_coe_words(directory / "irom.coe");
    image.dram = read_coe_words(directory / "dram.coe");
    image.stop_pc = derive_stop_pc(image.irom);
    return image;
}

Rv32Machine::Rv32Machine(const ProgramImage& image)
    : image_(image), dram_(kDramBytes, 0u) {
    if (image_.irom.size() * sizeof(std::uint32_t) > kIromBytes) {
        throw std::runtime_error(image_.name + ": IROM image exceeds 16 KiB");
    }
    if (image_.dram.size() * sizeof(std::uint32_t) > kDramBytes) {
        throw std::runtime_error(image_.name + ": DRAM image exceeds 256 KiB");
    }
    for (std::size_t word = 0; word < image_.dram.size(); ++word) {
        const auto value = image_.dram[word];
        for (unsigned byte = 0; byte < 4u; ++byte) {
            dram_[word * 4u + byte] =
                static_cast<std::uint8_t>(value >> (byte * 8u));
        }
    }
    stats_.stop_pc = image_.stop_pc;
}

std::uint32_t Rv32Machine::fetch() const {
    if ((pc_ & 0x3u) != 0u || pc_ < kIromBase ||
        pc_ >= kIromBase + kIromBytes) {
        throw std::runtime_error(image_.name + ": invalid fetch PC " + hex32(pc_));
    }
    const auto index = static_cast<std::size_t>((pc_ - kIromBase) >> 2u);
    return index < image_.irom.size() ? image_.irom[index] : 0x0000'0013u;
}

std::size_t Rv32Machine::dram_offset(const std::uint32_t address) const {
    if (address >= kDramBase && address < kDramBase + kDramBytes) {
        return static_cast<std::size_t>(address - kDramBase);
    }
    // Match tb_riscv_tests.sv's MMIO fallback mirror: address[17:2]
    // selects a DRAM word, with the byte offset supplied by address[1:0].
    return static_cast<std::size_t>(address & (kDramBytes - 1u));
}

std::uint8_t Rv32Machine::read_timer_byte(const std::uint32_t address) const {
    const auto select = address & ~0x7u;
    const auto byte = static_cast<unsigned>(address & 0x7u);
    const auto value = (select == kMtimeLo) ? mtime_ : mtimecmp_;
    return static_cast<std::uint8_t>(value >> (byte * 8u));
}

void Rv32Machine::write_timer_byte(const std::uint32_t address,
                                   const std::uint8_t value) {
    const auto select = address & ~0x7u;
    const auto byte = static_cast<unsigned>(address & 0x7u);
    auto* timer = (select == kMtimeLo) ? &mtime_ : &mtimecmp_;
    const auto mask = ~(std::uint64_t{0xff} << (byte * 8u));
    *timer = (*timer & mask) | (static_cast<std::uint64_t>(value) << (byte * 8u));
}

std::uint8_t Rv32Machine::load8(const std::uint32_t address) const {
    if (address >= kMtimeLo && address < kMtimeLo + 16u) {
        return read_timer_byte(address);
    }
    return dram_[dram_offset(address)];
}

std::uint16_t Rv32Machine::load16(const std::uint32_t address) const {
    return static_cast<std::uint16_t>(load8(address)) |
           static_cast<std::uint16_t>(load8(address + 1u) << 8u);
}

std::uint32_t Rv32Machine::load32(const std::uint32_t address) const {
    return static_cast<std::uint32_t>(load8(address)) |
           (static_cast<std::uint32_t>(load8(address + 1u)) << 8u) |
           (static_cast<std::uint32_t>(load8(address + 2u)) << 16u) |
           (static_cast<std::uint32_t>(load8(address + 3u)) << 24u);
}

void Rv32Machine::store8(const std::uint32_t address, const std::uint8_t value) {
    if (address >= kMtimeLo && address < kMtimeLo + 16u) {
        write_timer_byte(address, value);
        return;
    }
    dram_[dram_offset(address)] = value;
}

void Rv32Machine::store16(const std::uint32_t address, const std::uint16_t value) {
    store8(address, static_cast<std::uint8_t>(value));
    store8(address + 1u, static_cast<std::uint8_t>(value >> 8u));
}

void Rv32Machine::store32(const std::uint32_t address, const std::uint32_t value) {
    store8(address, static_cast<std::uint8_t>(value));
    store8(address + 1u, static_cast<std::uint8_t>(value >> 8u));
    store8(address + 2u, static_cast<std::uint8_t>(value >> 16u));
    store8(address + 3u, static_cast<std::uint8_t>(value >> 24u));
}

bool Rv32Machine::timer_pending() const {
    return mtime_ >= mtimecmp_;
}

std::uint32_t Rv32Machine::read_csr(const std::uint16_t address) const {
    switch (address) {
        case kCsrMstatus:
            return csr_.mstatus;
        case kCsrMie:
            return csr_.mie;
        case kCsrMtvec:
            return csr_.mtvec;
        case kCsrMscratch:
            return csr_.mscratch;
        case kCsrMepc:
            return csr_.mepc;
        case kCsrMcause:
            return csr_.mcause;
        case kCsrMip:
            return timer_pending() ? 0x80u : 0u;
        default:
            return 0u;
    }
}

void Rv32Machine::write_csr(const std::uint16_t address,
                            const std::uint32_t value) {
    switch (address) {
        case kCsrMstatus:
            csr_.mstatus = value & 0x88u;
            break;
        case kCsrMie:
            csr_.mie = value & 0x80u;
            break;
        case kCsrMtvec:
            csr_.mtvec = value;
            break;
        case kCsrMscratch:
            csr_.mscratch = value;
            break;
        case kCsrMepc:
            csr_.mepc = value;
            break;
        case kCsrMcause:
            csr_.mcause = value;
            break;
        default:
            break;
    }
}

void Rv32Machine::enter_trap(const std::uint32_t cause,
                             const std::uint32_t mepc) {
    csr_.mepc = mepc;
    csr_.mcause = cause;
    const auto old_mie = (csr_.mstatus >> 3u) & 1u;
    csr_.mstatus = (csr_.mstatus & ~0x88u) | (old_mie << 7u);
    pc_ = csr_.mtvec & ~0x3u;
    ++stats_.trap_count;
}

void Rv32Machine::take_timer_interrupt() {
    enter_trap(0x8000'0007u, pc_);
    ++stats_.timer_interrupt_count;
}

CfiEvent Rv32Machine::step() {
    if ((csr_.mstatus & 0x8u) != 0u && (csr_.mie & 0x80u) != 0u &&
        timer_pending()) {
        take_timer_interrupt();
    }

    const auto instruction_pc = pc_;
    const auto instruction = fetch();
    const auto opcode = instruction & 0x7fu;
    const auto rd = (instruction >> 7u) & 0x1fu;
    const auto funct3 = (instruction >> 12u) & 0x7u;
    const auto rs1 = (instruction >> 15u) & 0x1fu;
    const auto rs2 = (instruction >> 20u) & 0x1fu;
    const auto funct7 = (instruction >> 25u) & 0x7fu;
    const auto rs1_value = regs_[rs1];
    const auto rs2_value = regs_[rs2];

    const auto i_imm = sign_extend<12>(instruction >> 20u);
    const auto s_imm = sign_extend<12>(((instruction >> 25u) << 5u) |
                                       ((instruction >> 7u) & 0x1fu));
    const auto b_bits = ((instruction >> 31u) << 12u) |
                        (((instruction >> 7u) & 0x1u) << 11u) |
                        (((instruction >> 25u) & 0x3fu) << 5u) |
                        (((instruction >> 8u) & 0xfu) << 1u);
    const auto b_imm = sign_extend<13>(b_bits);
    const auto j_bits = ((instruction >> 31u) << 20u) |
                        (((instruction >> 12u) & 0xffu) << 12u) |
                        (((instruction >> 20u) & 0x1u) << 11u) |
                        (((instruction >> 21u) & 0x3ffu) << 1u);
    const auto j_imm = sign_extend<21>(j_bits);

    CfiEvent event;
    event.instruction_ordinal = stats_.retired_instructions + 1u;
    event.source_pc = instruction_pc;
    event.instruction = instruction;
    auto next_pc = instruction_pc + 4u;

    const auto write_rd = [&](const std::uint32_t value) {
        if (rd != 0u) {
            regs_[rd] = value;
        }
    };

    switch (opcode) {
        case 0x37u:  // LUI
            write_rd(instruction & 0xffff'f000u);
            break;

        case 0x17u:  // AUIPC
            write_rd(instruction_pc + (instruction & 0xffff'f000u));
            break;

        case 0x6fu: {  // JAL
            const auto target = add_signed(instruction_pc, j_imm);
            write_rd(instruction_pc + 4u);
            next_pc = target;
            event.kind = CfiKind::Jal;
            event.taken = true;
            event.target = target;
            break;
        }

        case 0x67u: {  // JALR
            if (funct3 != 0u) {
                throw std::runtime_error(image_.name + ": illegal JALR at " +
                                         hex32(instruction_pc));
            }
            const auto target = add_signed(rs1_value, i_imm) & ~1u;
            write_rd(instruction_pc + 4u);
            next_pc = target;
            event.kind = CfiKind::Jalr;
            event.taken = true;
            event.target = target;
            break;
        }

        case 0x63u: {  // Conditional branches
            bool taken = false;
            switch (funct3) {
                case 0u:
                    taken = rs1_value == rs2_value;
                    break;
                case 1u:
                    taken = rs1_value != rs2_value;
                    break;
                case 4u:
                    taken = static_cast<std::int32_t>(rs1_value) <
                            static_cast<std::int32_t>(rs2_value);
                    break;
                case 5u:
                    taken = static_cast<std::int32_t>(rs1_value) >=
                            static_cast<std::int32_t>(rs2_value);
                    break;
                case 6u:
                    taken = rs1_value < rs2_value;
                    break;
                case 7u:
                    taken = rs1_value >= rs2_value;
                    break;
                default:
                    throw std::runtime_error(image_.name + ": illegal branch at " +
                                             hex32(instruction_pc));
            }
            const auto target = add_signed(instruction_pc, b_imm);
            next_pc = taken ? target : instruction_pc + 4u;
            event.kind = CfiKind::Branch;
            event.taken = taken;
            event.target = target;
            ++stats_.conditional_branches;
            stats_.taken_branches += static_cast<std::uint64_t>(taken);
            break;
        }

        case 0x03u: {  // Loads
            const auto address = add_signed(rs1_value, i_imm);
            switch (funct3) {
                case 0u:
                    write_rd(static_cast<std::uint32_t>(
                        sign_extend<8>(load8(address))));
                    break;
                case 1u:
                    write_rd(static_cast<std::uint32_t>(
                        sign_extend<16>(load16(address))));
                    break;
                case 2u:
                    write_rd(load32(address));
                    break;
                case 4u:
                    write_rd(load8(address));
                    break;
                case 5u:
                    write_rd(load16(address));
                    break;
                default:
                    throw std::runtime_error(image_.name + ": illegal load at " +
                                             hex32(instruction_pc));
            }
            break;
        }

        case 0x23u: {  // Stores
            const auto address = add_signed(rs1_value, s_imm);
            switch (funct3) {
                case 0u:
                    store8(address, static_cast<std::uint8_t>(rs2_value));
                    break;
                case 1u:
                    store16(address, static_cast<std::uint16_t>(rs2_value));
                    break;
                case 2u:
                    store32(address, rs2_value);
                    break;
                default:
                    throw std::runtime_error(image_.name + ": illegal store at " +
                                             hex32(instruction_pc));
            }
            break;
        }

        case 0x13u: {  // OP-IMM
            switch (funct3) {
                case 0u:
                    write_rd(add_signed(rs1_value, i_imm));
                    break;
                case 2u:
                    write_rd(static_cast<std::int32_t>(rs1_value) < i_imm ? 1u : 0u);
                    break;
                case 3u:
                    write_rd(rs1_value < static_cast<std::uint32_t>(i_imm) ? 1u : 0u);
                    break;
                case 4u:
                    write_rd(rs1_value ^ static_cast<std::uint32_t>(i_imm));
                    break;
                case 6u:
                    write_rd(rs1_value | static_cast<std::uint32_t>(i_imm));
                    break;
                case 7u:
                    write_rd(rs1_value & static_cast<std::uint32_t>(i_imm));
                    break;
                case 1u:
                    if (funct7 != 0u) {
                        throw std::runtime_error(image_.name + ": illegal SLLI at " +
                                                 hex32(instruction_pc));
                    }
                    write_rd(rs1_value << (rs2 & 0x1fu));
                    break;
                case 5u:
                    if (funct7 == 0u) {
                        write_rd(rs1_value >> (rs2 & 0x1fu));
                    } else if (funct7 == 0x20u) {
                        write_rd(static_cast<std::uint32_t>(
                            static_cast<std::int32_t>(rs1_value) >> (rs2 & 0x1fu)));
                    } else {
                        throw std::runtime_error(image_.name + ": illegal shift-immediate at " +
                                                 hex32(instruction_pc));
                    }
                    break;
                default:
                    throw std::runtime_error(image_.name + ": illegal OP-IMM at " +
                                             hex32(instruction_pc));
            }
            break;
        }

        case 0x33u: {  // OP and RV32M
            if (funct7 == 0x01u) {
                const auto signed_lhs = static_cast<std::int64_t>(
                    static_cast<std::int32_t>(rs1_value));
                const auto signed_rhs = static_cast<std::int64_t>(
                    static_cast<std::int32_t>(rs2_value));
                switch (funct3) {
                    case 0u:
                        write_rd(static_cast<std::uint32_t>(
                            static_cast<std::uint64_t>(rs1_value) * rs2_value));
                        break;
                    case 1u: {
                        const auto product = signed_lhs * signed_rhs;
                        write_rd(static_cast<std::uint32_t>(
                            static_cast<std::uint64_t>(product) >> 32u));
                        break;
                    }
                    case 2u: {
                        // MULHSU high half without a non-standard 128-bit type:
                        // reinterpret the signed lhs as unsigned, then subtract
                        // rhs from the high word when lhs was negative.
                        const auto product = static_cast<std::uint64_t>(rs1_value) *
                                             static_cast<std::uint64_t>(rs2_value);
                        auto high = static_cast<std::uint32_t>(product >> 32u);
                        if (static_cast<std::int32_t>(rs1_value) < 0) {
                            high -= rs2_value;
                        }
                        write_rd(high);
                        break;
                    }
                    case 3u: {
                        const auto product = static_cast<std::uint64_t>(rs1_value) *
                                             static_cast<std::uint64_t>(rs2_value);
                        write_rd(static_cast<std::uint32_t>(product >> 32u));
                        break;
                    }
                    case 4u:
                        if (rs2_value == 0u) {
                            write_rd(0xffff'ffffu);
                        } else if (rs1_value == 0x8000'0000u &&
                                   rs2_value == 0xffff'ffffu) {
                            write_rd(0x8000'0000u);
                        } else {
                            write_rd(static_cast<std::uint32_t>(signed_lhs / signed_rhs));
                        }
                        break;
                    case 5u:
                        write_rd(rs2_value == 0u ? 0xffff'ffffu
                                                : rs1_value / rs2_value);
                        break;
                    case 6u:
                        if (rs2_value == 0u) {
                            write_rd(rs1_value);
                        } else if (rs1_value == 0x8000'0000u &&
                                   rs2_value == 0xffff'ffffu) {
                            write_rd(0u);
                        } else {
                            write_rd(static_cast<std::uint32_t>(signed_lhs % signed_rhs));
                        }
                        break;
                    case 7u:
                        write_rd(rs2_value == 0u ? rs1_value
                                                : rs1_value % rs2_value);
                        break;
                    default:
                        break;
                }
                break;
            }

            switch (funct3) {
                case 0u:
                    if (funct7 == 0u) {
                        write_rd(rs1_value + rs2_value);
                    } else if (funct7 == 0x20u) {
                        write_rd(rs1_value - rs2_value);
                    } else {
                        throw std::runtime_error(image_.name + ": illegal ADD/SUB at " +
                                                 hex32(instruction_pc));
                    }
                    break;
                case 1u:
                    write_rd(rs1_value << (rs2_value & 0x1fu));
                    break;
                case 2u:
                    write_rd(static_cast<std::int32_t>(rs1_value) <
                                     static_cast<std::int32_t>(rs2_value)
                                 ? 1u
                                 : 0u);
                    break;
                case 3u:
                    write_rd(rs1_value < rs2_value ? 1u : 0u);
                    break;
                case 4u:
                    write_rd(rs1_value ^ rs2_value);
                    break;
                case 5u:
                    if (funct7 == 0u) {
                        write_rd(rs1_value >> (rs2_value & 0x1fu));
                    } else if (funct7 == 0x20u) {
                        write_rd(static_cast<std::uint32_t>(
                            static_cast<std::int32_t>(rs1_value) >>
                            (rs2_value & 0x1fu)));
                    } else {
                        throw std::runtime_error(image_.name + ": illegal SRL/SRA at " +
                                                 hex32(instruction_pc));
                    }
                    break;
                case 6u:
                    write_rd(rs1_value | rs2_value);
                    break;
                case 7u:
                    write_rd(rs1_value & rs2_value);
                    break;
                default:
                    break;
            }
            break;
        }

        case 0x0fu:  // FENCE/FENCE.I: no architectural effect here.
            break;

        case 0x73u: {  // SYSTEM/CSR
            if (funct3 == 0u) {
                if (instruction == 0x0000'0073u) {  // ECALL
                    enter_trap(11u, instruction_pc);
                    next_pc = pc_;
                } else if (instruction == 0x3020'0073u) {  // MRET
                    next_pc = csr_.mepc;
                    const auto mpie = (csr_.mstatus >> 7u) & 1u;
                    csr_.mstatus = (csr_.mstatus & ~0x88u) | (mpie << 3u) | 0x80u;
                } else {
                    throw std::runtime_error(image_.name + ": unsupported SYSTEM at " +
                                             hex32(instruction_pc));
                }
                break;
            }

            const auto csr_address = static_cast<std::uint16_t>(instruction >> 20u);
            const auto old_value = read_csr(csr_address);
            const bool immediate = (funct3 & 0x4u) != 0u;
            const auto source = immediate ? rs1 : rs1_value;
            const auto command = funct3 & 0x3u;
            bool write = false;
            auto new_value = old_value;
            if (command == 1u) {
                new_value = source;
                write = true;
            } else if (command == 2u && source != 0u) {
                new_value = old_value | source;
                write = true;
            } else if (command == 3u && source != 0u) {
                new_value = old_value & ~source;
                write = true;
            }
            if (write) {
                write_csr(csr_address, new_value);
            }
            write_rd(old_value);
            break;
        }

        default:
            throw std::runtime_error(image_.name + ": unsupported instruction " +
                                     hex32(instruction) + " at " +
                                     hex32(instruction_pc));
    }

    event.next_pc = next_pc;
    pc_ = next_pc;
    regs_[0] = 0u;
    ++stats_.retired_instructions;
    ++mtime_;

    if (event.kind == CfiKind::Jal) {
        ++stats_.jal_count;
    } else if (event.kind == CfiKind::Jalr) {
        ++stats_.jalr_count;
    }

    if (instruction_pc == image_.stop_pc) {
        reached_stop_ = true;
    }
    return event;
}

}  // namespace archsim
