#include "la32_sim.hpp"

#include "la32_decode.hpp"

#include <elf.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace archsim {
namespace {

std::vector<std::uint8_t> read_binary(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        throw std::runtime_error("cannot open binary file: " + path.string());
    }
    input.seekg(0, std::ios::end);
    const auto size = input.tellg();
    if (size < 0) {
        throw std::runtime_error("cannot determine file size: " + path.string());
    }
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
    input.seekg(0, std::ios::beg);
    input.read(reinterpret_cast<char*>(bytes.data()), size);
    if (!input) {
        throw std::runtime_error("cannot read binary file: " + path.string());
    }
    return bytes;
}

template <typename Type>
const Type& object_at(const std::vector<std::uint8_t>& bytes,
                      const std::size_t offset,
                      const std::filesystem::path& path) {
    if (offset > bytes.size() || sizeof(Type) > bytes.size() - offset) {
        throw std::runtime_error("truncated ELF structure in " + path.string());
    }
    return *reinterpret_cast<const Type*>(bytes.data() + offset);
}

std::uint32_t elf_symbol(const std::filesystem::path& path,
                         const std::string& requested_name) {
    const auto bytes = read_binary(path);
    const auto& header = object_at<Elf32_Ehdr>(bytes, 0u, path);
    if (std::memcmp(header.e_ident, ELFMAG, SELFMAG) != 0 ||
        header.e_ident[EI_CLASS] != ELFCLASS32 ||
        header.e_ident[EI_DATA] != ELFDATA2LSB) {
        throw std::runtime_error("expected a little-endian ELF32 image: " +
                                 path.string());
    }
    for (std::size_t section = 0; section < header.e_shnum; ++section) {
        const auto& symtab = object_at<Elf32_Shdr>(
            bytes, header.e_shoff + section * header.e_shentsize, path);
        if (symtab.sh_type != SHT_SYMTAB || symtab.sh_entsize == 0u ||
            symtab.sh_link >= header.e_shnum) {
            continue;
        }
        const auto& strtab = object_at<Elf32_Shdr>(
            bytes, header.e_shoff + symtab.sh_link * header.e_shentsize, path);
        if (strtab.sh_offset > bytes.size() ||
            strtab.sh_size > bytes.size() - strtab.sh_offset) {
            throw std::runtime_error("truncated ELF string table in " +
                                     path.string());
        }
        const auto* strings = reinterpret_cast<const char*>(
            bytes.data() + strtab.sh_offset);
        const auto count = symtab.sh_size / symtab.sh_entsize;
        for (std::size_t index = 0; index < count; ++index) {
            const auto& symbol = object_at<Elf32_Sym>(
                bytes, symtab.sh_offset + index * symtab.sh_entsize, path);
            if (symbol.st_name >= strtab.sh_size) {
                continue;
            }
            const auto* name = strings + symbol.st_name;
            const auto remaining = strtab.sh_size - symbol.st_name;
            if (std::memchr(name, '\0', remaining) != nullptr &&
                requested_name == name) {
                return symbol.st_value;
            }
        }
    }
    throw std::runtime_error("ELF symbol not found: " + requested_name +
                             " in " + path.string());
}

std::string hex32(const std::uint32_t value) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
    return stream.str();
}

std::uint32_t add(const std::uint32_t lhs, const std::uint32_t rhs) {
    return lhs + rhs;
}

}  // namespace

La32ProgramImage load_la32_perf_program(
    const std::filesystem::path& perf_object_root,
    const std::string& name) {
    La32ProgramImage image;
    image.name = name;
    const auto directory = perf_object_root / name;
    image.bytes = read_binary(directory / "inst_data.bin");
    if (image.bytes.size() > kLa32RamBytes) {
        throw std::runtime_error(name + ": performance image exceeds model RAM");
    }
    const auto elf = directory / "main.elf";
    image.stop_pc = elf_symbol(elf, "test_finish");
    return image;
}

La32Machine::La32Machine(const La32ProgramImage& image)
    : image_(image), memory_(kLa32RamBytes, 0u), pc_(image.entry_pc) {
    std::copy(image.bytes.begin(), image.bytes.end(), memory_.begin());
    stats_.stop_pc = image.stop_pc;
}

std::uint32_t La32Machine::performance_result() const {
    // Every nscscc_perf shell writes 1 for PASS and 2 for ERROR here before
    // returning to test_finish.
    return load32(0xbfaf'f030u);
}

std::uint8_t La32Machine::load8(const std::uint32_t address) const {
    // The startup/newlib UART driver polls the 16550 line-status register.
    // The software model has no serial timing, so report transmitter empty
    // and ready instead of trapping the trace in the polling loop.
    if (address == 0xbfe0'01e5u) {
        return 0x60u;
    }
    if (address >= kLa32RamBase &&
        address < kLa32RamBase + kLa32RamBytes) {
        return memory_[address - kLa32RamBase];
    }
    const auto iterator = peripheral_bytes_.find(address);
    return iterator == peripheral_bytes_.end() ? 0u : iterator->second;
}

std::uint16_t La32Machine::load16(const std::uint32_t address) const {
    return static_cast<std::uint16_t>(load8(address)) |
           static_cast<std::uint16_t>(load8(address + 1u) << 8u);
}

std::uint32_t La32Machine::load32(const std::uint32_t address) const {
    return static_cast<std::uint32_t>(load8(address)) |
           static_cast<std::uint32_t>(load8(address + 1u)) << 8u |
           static_cast<std::uint32_t>(load8(address + 2u)) << 16u |
           static_cast<std::uint32_t>(load8(address + 3u)) << 24u;
}

void La32Machine::store8(const std::uint32_t address,
                         const std::uint8_t value) {
    if (address >= kLa32RamBase &&
        address < kLa32RamBase + kLa32RamBytes) {
        memory_[address - kLa32RamBase] = value;
    } else {
        peripheral_bytes_[address] = value;
    }
}

void La32Machine::store16(const std::uint32_t address,
                          const std::uint16_t value) {
    store8(address, static_cast<std::uint8_t>(value));
    store8(address + 1u, static_cast<std::uint8_t>(value >> 8u));
}

void La32Machine::store32(const std::uint32_t address,
                          const std::uint32_t value) {
    store8(address, static_cast<std::uint8_t>(value));
    store8(address + 1u, static_cast<std::uint8_t>(value >> 8u));
    store8(address + 2u, static_cast<std::uint8_t>(value >> 16u));
    store8(address + 3u, static_cast<std::uint8_t>(value >> 24u));
}

std::uint32_t La32Machine::read_csr(const std::uint16_t address) const {
    const auto iterator = csr_.find(address);
    return iterator == csr_.end() ? 0u : iterator->second;
}

void La32Machine::write_csr(const std::uint16_t address,
                            const std::uint32_t value) {
    csr_[address] = value;
}

std::uint32_t La32Machine::read_cpucfg(const std::uint32_t index) const {
    // Match loongarch_priv_unit.sv.  In particular CPUCFG.0x10=0 skips the
    // cache-initialization CACOP loops that this core does not implement.
    if (index == 1u) return 0x0001'f1f0u;
    return 0u;
}

CfiEvent La32Machine::step() {
    if (reached_stop_) {
        throw std::runtime_error(image_.name + ": stepped past test_finish");
    }
    if ((pc_ & 3u) != 0u || pc_ < kLa32RamBase ||
        pc_ + 3u >= kLa32RamBase + kLa32RamBytes) {
        throw std::runtime_error(image_.name + ": invalid fetch PC " +
                                 hex32(pc_));
    }

    using Kind = La32InstructionKind;
    const auto instruction_pc = pc_;
    const auto instruction = load32(instruction_pc);
    const auto decoded = decode_la32_instruction(instruction);
    if (!decoded.legal) {
        throw std::runtime_error(image_.name + ": unsupported instruction " +
                                 hex32(instruction) + " at " +
                                 hex32(instruction_pc));
    }

    const auto src0 = regs_[decoded.src0];
    const auto src1 = regs_[decoded.src1];
    auto next_pc = instruction_pc + 4u;
    CfiEvent event;
    event.instruction_ordinal = stats_.retired_instructions + 1u;
    event.source_pc = instruction_pc;
    event.instruction = instruction;

    const auto write_rd = [&](const std::uint32_t value) {
        if (decoded.writes_rd && decoded.rd != 0u) {
            regs_[decoded.rd] = value;
        }
    };
    const auto set_memory_event = [&](const MemoryAccessKind kind,
                                      const std::uint32_t address) {
        event.memory_kind = kind;
        event.memory_address = address;
    };
    const auto set_branch_event = [&](const CfiKind kind,
                                      const std::uint32_t target,
                                      const bool taken) {
        event.kind = kind;
        event.target = target;
        event.taken = taken;
        next_pc = taken ? target : instruction_pc + 4u;
    };

    switch (decoded.kind) {
        case Kind::AddW: write_rd(add(src0, src1)); break;
        case Kind::SubW: write_rd(src0 - src1); break;
        case Kind::Slt:
            write_rd(static_cast<std::int32_t>(src0) <
                     static_cast<std::int32_t>(src1));
            break;
        case Kind::Sltu: write_rd(src0 < src1); break;
        case Kind::Nor: write_rd(~(src0 | src1)); break;
        case Kind::And: write_rd(src0 & src1); break;
        case Kind::Or: write_rd(src0 | src1); break;
        case Kind::Xor: write_rd(src0 ^ src1); break;
        case Kind::SllW: write_rd(src0 << (src1 & 31u)); break;
        case Kind::SrlW: write_rd(src0 >> (src1 & 31u)); break;
        case Kind::SraW:
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(src0) >> (src1 & 31u)));
            break;
        case Kind::Slti:
            write_rd(static_cast<std::int32_t>(src0) <
                     static_cast<std::int32_t>(decoded.immediate));
            break;
        case Kind::Sltui: write_rd(src0 < decoded.immediate); break;
        case Kind::AddiW: write_rd(add(src0, decoded.immediate)); break;
        case Kind::Andi: write_rd(src0 & decoded.immediate); break;
        case Kind::Ori: write_rd(src0 | decoded.immediate); break;
        case Kind::Xori: write_rd(src0 ^ decoded.immediate); break;
        case Kind::SlliW: write_rd(src0 << decoded.immediate); break;
        case Kind::SrliW: write_rd(src0 >> decoded.immediate); break;
        case Kind::SraiW:
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(src0) >> decoded.immediate));
            break;
        case Kind::Lu12iW: write_rd(decoded.immediate); break;
        case Kind::Pcaddu12i:
            write_rd(add(instruction_pc, decoded.immediate));
            break;
        case Kind::MulW:
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::uint64_t>(src0) * src1));
            break;
        case Kind::MulhW: {
            const auto product =
                static_cast<std::int64_t>(static_cast<std::int32_t>(src0)) *
                static_cast<std::int64_t>(static_cast<std::int32_t>(src1));
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::uint64_t>(product) >> 32u));
            break;
        }
        case Kind::MulhWu: {
            const auto product = static_cast<std::uint64_t>(src0) * src1;
            write_rd(static_cast<std::uint32_t>(product >> 32u));
            break;
        }
        case Kind::DivW:
            if (src1 == 0u) write_rd(0xffff'ffffu);
            else if (src0 == 0x8000'0000u && src1 == 0xffff'ffffu)
                write_rd(src0);
            else write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(src0) /
                static_cast<std::int32_t>(src1)));
            break;
        case Kind::DivWu:
            write_rd(src1 == 0u ? 0xffff'ffffu : src0 / src1);
            break;
        case Kind::ModW:
            if (src1 == 0u) write_rd(src0);
            else if (src0 == 0x8000'0000u && src1 == 0xffff'ffffu)
                write_rd(0u);
            else write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(src0) %
                static_cast<std::int32_t>(src1)));
            break;
        case Kind::ModWu: write_rd(src1 == 0u ? src0 : src0 % src1); break;

        case Kind::LdB: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Load, address);
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(static_cast<std::int8_t>(load8(address)))));
            break;
        }
        case Kind::LdBu: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Load, address);
            write_rd(load8(address));
            break;
        }
        case Kind::LdH: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Load, address);
            write_rd(static_cast<std::uint32_t>(
                static_cast<std::int32_t>(static_cast<std::int16_t>(load16(address)))));
            break;
        }
        case Kind::LdHu: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Load, address);
            write_rd(load16(address));
            break;
        }
        case Kind::LdW: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Load, address);
            write_rd(load32(address));
            break;
        }
        case Kind::StB: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Store, address);
            store8(address, static_cast<std::uint8_t>(src1));
            break;
        }
        case Kind::StH: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Store, address);
            store16(address, static_cast<std::uint16_t>(src1));
            break;
        }
        case Kind::StW: {
            const auto address = add(src0, decoded.immediate);
            set_memory_event(MemoryAccessKind::Store, address);
            store32(address, src1);
            break;
        }

        case Kind::Beq: case Kind::Bne: case Kind::Blt:
        case Kind::Bge: case Kind::Bltu: case Kind::Bgeu: {
            bool taken = false;
            if (decoded.kind == Kind::Beq) taken = src0 == src1;
            else if (decoded.kind == Kind::Bne) taken = src0 != src1;
            else if (decoded.kind == Kind::Blt)
                taken = static_cast<std::int32_t>(src0) <
                        static_cast<std::int32_t>(src1);
            else if (decoded.kind == Kind::Bge)
                taken = static_cast<std::int32_t>(src0) >=
                        static_cast<std::int32_t>(src1);
            else if (decoded.kind == Kind::Bltu) taken = src0 < src1;
            else taken = src0 >= src1;
            const auto target = add(instruction_pc, decoded.immediate);
            set_branch_event(CfiKind::Branch, target, taken);
            ++stats_.conditional_branches;
            stats_.taken_branches += static_cast<std::uint64_t>(taken);
            break;
        }
        case Kind::B: case Kind::Bl: {
            if (decoded.kind == Kind::Bl) write_rd(instruction_pc + 4u);
            const auto target = add(instruction_pc, decoded.immediate);
            set_branch_event(CfiKind::Jal, target, true);
            break;
        }
        case Kind::Jirl: {
            write_rd(instruction_pc + 4u);
            const auto target = add(src0, decoded.immediate);
            set_branch_event(CfiKind::Jalr, target, true);
            break;
        }

        case Kind::Cpucfg: write_rd(read_cpucfg(src0)); break;
        case Kind::Rdcntvl:
            write_rd(static_cast<std::uint32_t>(stable_counter_));
            break;
        case Kind::Rdcntvh:
            write_rd(static_cast<std::uint32_t>(stable_counter_ >> 32u));
            break;
        case Kind::Rdcntid: write_rd(read_csr(0x40u)); break;
        case Kind::Csrrd: write_rd(read_csr(decoded.csr_address)); break;
        case Kind::Csrwr: {
            const auto old = read_csr(decoded.csr_address);
            write_csr(decoded.csr_address, src0);
            write_rd(old);
            break;
        }
        case Kind::Csrxchg: {
            const auto old = read_csr(decoded.csr_address);
            write_csr(decoded.csr_address,
                      (old & ~src1) | (src0 & src1));
            write_rd(old);
            break;
        }
        case Kind::Syscall: case Kind::Ertn: case Kind::Break:
            throw std::runtime_error(image_.name + ": executed " +
                                     la32_instruction_name(decoded.kind) +
                                     " at " + hex32(instruction_pc));
        case Kind::Illegal:
            break;
    }

    event.next_pc = next_pc;
    pc_ = next_pc;
    regs_[0] = 0u;
    ++stats_.retired_instructions;
    ++stable_counter_;
    if (event.kind == CfiKind::Jal) ++stats_.jal_count;
    else if (event.kind == CfiKind::Jalr) ++stats_.jalr_count;
    reached_stop_ = pc_ == image_.stop_pc;
    return event;
}

}  // namespace archsim
