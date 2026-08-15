#pragma once

#include "architectural_trace.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <vector>

namespace archsim {

constexpr std::uint32_t kLa32RamBase = 0x1c00'0000u;
constexpr std::uint32_t kLa32RamBytes = 2u * 1024u * 1024u;

struct La32ProgramImage {
    std::string name;
    std::vector<std::uint8_t> bytes;
    std::uint32_t entry_pc = kLa32RamBase;
    std::uint32_t stop_pc = 0;
};

La32ProgramImage load_la32_perf_program(
    const std::filesystem::path& perf_object_root,
    const std::string& name);

class La32Machine {
public:
    explicit La32Machine(const La32ProgramImage& image);

    CfiEvent step();

    [[nodiscard]] bool reached_stop() const { return reached_stop_; }
    [[nodiscard]] const ArchitecturalStats& stats() const { return stats_; }
    [[nodiscard]] std::uint32_t current_pc() const { return pc_; }
    [[nodiscard]] std::uint32_t performance_result() const;

private:
    [[nodiscard]] std::uint8_t load8(std::uint32_t address) const;
    [[nodiscard]] std::uint16_t load16(std::uint32_t address) const;
    [[nodiscard]] std::uint32_t load32(std::uint32_t address) const;
    void store8(std::uint32_t address, std::uint8_t value);
    void store16(std::uint32_t address, std::uint16_t value);
    void store32(std::uint32_t address, std::uint32_t value);
    [[nodiscard]] std::uint32_t read_csr(std::uint16_t address) const;
    void write_csr(std::uint16_t address, std::uint32_t value);
    [[nodiscard]] std::uint32_t read_cpucfg(std::uint32_t index) const;

    const La32ProgramImage& image_;
    std::array<std::uint32_t, 32> regs_{};
    std::vector<std::uint8_t> memory_;
    std::unordered_map<std::uint32_t, std::uint8_t> peripheral_bytes_;
    std::unordered_map<std::uint16_t, std::uint32_t> csr_;
    std::uint32_t pc_ = kLa32RamBase;
    std::uint64_t stable_counter_ = 0;
    bool reached_stop_ = false;
    ArchitecturalStats stats_{};
};

}  // namespace archsim
