#pragma once

#include "rv32_sim.hpp"

#include <cstdint>
#include <memory>
#include <string>

namespace archsim {

enum class BackendBranchMode : std::uint8_t {
    Perfect,
    Gshare,
};

enum class BackendQueueKind : std::uint8_t {
    Int,
    Ls,
    Mdu,
};

struct BackendDecodedInstruction {
    BackendQueueKind queue = BackendQueueKind::Int;
    bool uses_rs1 = false;
    bool uses_rs2 = false;
    bool writes_rd = false;
    bool is_load = false;
    bool is_store = false;
    bool is_mul = false;
    bool is_div = false;
    bool is_control = false;
    bool needs_checkpoint = false;
    std::uint8_t rs1 = 0;
    std::uint8_t rs2 = 0;
    std::uint8_t rd = 0;
};

BackendDecodedInstruction decode_backend_instruction(std::uint32_t instruction);

struct BackendConfig {
    std::uint32_t int_iq_depth = 16;
    std::uint32_t ls_iq_depth = 8;
    std::uint32_t mdu_iq_depth = 4;

    std::uint32_t rob_depth = 32;
    std::uint32_t prf_entries = 64;
    std::uint32_t rename_width = 2;
    std::uint32_t issue_width = 2;
    std::uint32_t commit_width = 2;
    std::uint32_t checkpoints = 2;
    std::uint32_t checkpoints_per_cycle = 1;
    std::uint32_t prf_reads_per_bank = 2;

    std::uint32_t regread_latency = 1;
    std::uint32_t alu_latency = 1;
    std::uint32_t mul_latency = 3;
    std::uint32_t div_latency = 32;
    std::uint32_t load_hit_latency = 2;
    std::uint32_t load_miss_latency = 10;
    std::uint32_t store_latency = 1;
    std::uint32_t lsu_hit_initiation_interval = 1;
    std::uint32_t store_buffer_entries = 2;
    std::uint32_t store_drain_latency = 1;

    std::uint32_t dcache_sets = 64;
    std::uint32_t dcache_ways = 2;
    std::uint32_t dcache_line_bytes = 16;

    std::uint32_t frontend_buffer_entries = 64;
    std::uint32_t redirect_penalty = 6;
    std::uint32_t branch_update_delay_instructions = 6;
    BackendBranchMode branch_mode = BackendBranchMode::Gshare;
};

struct BackendIqMetrics {
    double average_occupancy = 0.0;
    std::uint32_t maximum_occupancy = 0;
    std::uint32_t p95_occupancy = 0;
    std::uint32_t p99_occupancy = 0;
    std::uint64_t full_cycles = 0;
    std::uint64_t rename_stall_cycles = 0;
};

struct BackendStats {
    bool drained = false;
    std::uint64_t cycles = 0;
    std::uint64_t trace_instructions = 0;
    std::uint64_t dispatched_instructions = 0;
    std::uint64_t issued_instructions = 0;
    std::uint64_t retired_instructions = 0;
    std::uint64_t issue_zero_cycles = 0;
    std::uint64_t issue_one_cycles = 0;
    std::uint64_t issue_two_cycles = 0;

    BackendIqMetrics int_iq;
    BackendIqMetrics ls_iq;
    BackendIqMetrics mdu_iq;

    std::uint64_t rob_full_stall_cycles = 0;
    std::uint64_t prf_empty_stall_cycles = 0;
    std::uint64_t checkpoint_stall_cycles = 0;
    std::uint64_t branch_barrier_cycles = 0;
    std::uint64_t branch_mispredictions = 0;
    std::uint64_t global_issue_limit_cycles = 0;
    std::uint64_t prf_read_bank_conflict_cycles = 0;
    std::uint64_t int_fu_busy_cycles = 0;
    std::uint64_t lsu_busy_cycles = 0;
    std::uint64_t lsu_miss_blocked_cycles = 0;
    std::uint64_t store_buffer_full_cycles = 0;
    std::uint32_t lsu_max_inflight = 0;
    std::uint32_t store_buffer_max_occupancy = 0;
    std::uint64_t mdu_busy_cycles = 0;
    std::uint64_t wb_bank0_conflict_cycles = 0;
    std::uint64_t wb_bank1_conflict_cycles = 0;
    std::uint64_t alu0_result_hold_cycles = 0;
    std::uint64_t alu1_result_hold_cycles = 0;
    std::uint64_t lsu_result_hold_cycles = 0;
    std::uint64_t mdu_result_hold_cycles = 0;
    std::uint64_t load_hits = 0;
    std::uint64_t load_misses = 0;

    [[nodiscard]] double ipc() const;
};

class BackendModel {
public:
    explicit BackendModel(BackendConfig config);
    ~BackendModel();

    BackendModel(BackendModel&&) noexcept;
    BackendModel& operator=(BackendModel&&) noexcept;
    BackendModel(const BackendModel&) = delete;
    BackendModel& operator=(const BackendModel&) = delete;

    void feed(const CfiEvent& event);
    void finish();

    [[nodiscard]] const BackendConfig& config() const;
    [[nodiscard]] const BackendStats& stats() const;
    [[nodiscard]] std::string config_name() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

const char* backend_branch_mode_name(BackendBranchMode mode);

}  // namespace archsim
