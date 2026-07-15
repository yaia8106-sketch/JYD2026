#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace archsim {

constexpr std::uint32_t kIromBase = 0x8000'0000u;
constexpr std::uint32_t kIromBytes = 16u * 1024u;
constexpr std::uint32_t kDramBase = 0x8010'0000u;
constexpr std::uint32_t kDramBytes = 256u * 1024u;

enum class CfiKind : std::uint8_t {
    None,
    Branch,
    Jal,
    Jalr,
};

struct CfiEvent {
    CfiKind kind = CfiKind::None;
    std::uint64_t instruction_ordinal = 0;
    std::uint32_t source_pc = 0;
    std::uint32_t instruction = 0;
    std::uint32_t target = 0;
    std::uint32_t next_pc = 0;
    bool taken = false;
};

struct ProgramImage {
    std::string name;
    std::vector<std::uint32_t> irom;
    std::vector<std::uint32_t> dram;
    std::uint32_t stop_pc = 0;
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

std::vector<std::uint32_t> read_coe_words(const std::filesystem::path& path);
std::uint32_t derive_stop_pc(const std::vector<std::uint32_t>& irom);
ProgramImage load_program(const std::filesystem::path& coe_root,
                          const std::string& name);

class Rv32Machine {
public:
    explicit Rv32Machine(const ProgramImage& image);

    // Executes one architectural instruction.  Timer interrupts may be taken
    // immediately before it, but the call still retires exactly one instruction.
    CfiEvent step();

    [[nodiscard]] bool reached_stop() const { return reached_stop_; }
    [[nodiscard]] const ArchitecturalStats& stats() const { return stats_; }

private:
    static constexpr std::uint32_t kMtimeLo = 0x8020'0070u;
    static constexpr std::uint32_t kMtimeHi = 0x8020'0074u;
    static constexpr std::uint32_t kMtimecmpLo = 0x8020'0078u;
    static constexpr std::uint32_t kMtimecmpHi = 0x8020'007cu;

    static constexpr std::uint16_t kCsrMstatus = 0x300;
    static constexpr std::uint16_t kCsrMie = 0x304;
    static constexpr std::uint16_t kCsrMtvec = 0x305;
    static constexpr std::uint16_t kCsrMscratch = 0x340;
    static constexpr std::uint16_t kCsrMepc = 0x341;
    static constexpr std::uint16_t kCsrMcause = 0x342;
    static constexpr std::uint16_t kCsrMip = 0x344;

    struct CsrState {
        std::uint32_t mstatus = 0;
        std::uint32_t mie = 0;
        std::uint32_t mtvec = 0;
        std::uint32_t mscratch = 0;
        std::uint32_t mepc = 0;
        std::uint32_t mcause = 0;
    };

    [[nodiscard]] std::uint32_t fetch() const;
    [[nodiscard]] std::uint8_t load8(std::uint32_t address) const;
    [[nodiscard]] std::uint16_t load16(std::uint32_t address) const;
    [[nodiscard]] std::uint32_t load32(std::uint32_t address) const;
    void store8(std::uint32_t address, std::uint8_t value);
    void store16(std::uint32_t address, std::uint16_t value);
    void store32(std::uint32_t address, std::uint32_t value);

    [[nodiscard]] std::uint8_t read_timer_byte(std::uint32_t address) const;
    void write_timer_byte(std::uint32_t address, std::uint8_t value);
    [[nodiscard]] std::size_t dram_offset(std::uint32_t address) const;

    [[nodiscard]] bool timer_pending() const;
    void take_timer_interrupt();
    [[nodiscard]] std::uint32_t read_csr(std::uint16_t address) const;
    void write_csr(std::uint16_t address, std::uint32_t value);
    void enter_trap(std::uint32_t cause, std::uint32_t mepc);

    const ProgramImage& image_;
    std::array<std::uint32_t, 32> regs_{};
    std::vector<std::uint8_t> dram_;
    CsrState csr_{};
    std::uint32_t pc_ = kIromBase;
    std::uint64_t mtime_ = 0;
    std::uint64_t mtimecmp_ = ~std::uint64_t{0};
    bool reached_stop_ = false;
    ArchitecturalStats stats_{};
};

}  // namespace archsim
