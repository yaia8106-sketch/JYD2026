#pragma once

#include <cstdint>

namespace archsim {

enum class CfiKind : std::uint8_t {
    None,
    Branch,
    Jal,
    Jalr,
};

enum class MemoryAccessKind : std::uint8_t {
    None,
    Load,
    Store,
};

// One retired architectural instruction.  The dependency studies consume
// this ISA-neutral trace instead of depending on a particular interpreter.
struct CfiEvent {
    CfiKind kind = CfiKind::None;
    std::uint64_t instruction_ordinal = 0;
    std::uint32_t source_pc = 0;
    std::uint32_t instruction = 0;
    std::uint32_t target = 0;
    std::uint32_t next_pc = 0;
    bool taken = false;
    MemoryAccessKind memory_kind = MemoryAccessKind::None;
    std::uint32_t memory_address = 0;
};

struct ArchitecturalStats {
    std::uint64_t retired_instructions = 0;
    std::uint64_t conditional_branches = 0;
    std::uint64_t taken_branches = 0;
    std::uint64_t jal_count = 0;
    std::uint64_t jalr_count = 0;
    std::uint64_t trap_count = 0;
    std::uint64_t timer_interrupt_count = 0;
    std::uint32_t stop_pc = 0;
};

}  // namespace archsim
