#pragma once

#include "frontend_model.hpp"

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace archsim {

enum class FdqConsumePolicy : std::uint8_t {
    RtlPairing,
    DualAlways,
};

enum class FdqBackendPolicy : std::uint8_t {
    BranchDirectionOnly,
    AllControl,
};

struct FdqScenarioConfig {
    std::string name;
    std::uint32_t depth = 8;
    std::uint32_t f1_refill_cycles = 2;
    std::uint32_t backend_refill_cycles = 6;
    FdqConsumePolicy consume_policy = FdqConsumePolicy::RtlPairing;
    FdqBackendPolicy backend_policy = FdqBackendPolicy::BranchDirectionOnly;
    std::uint32_t consumer_stall_ppm = 0;
    std::uint32_t consumer_stall_burst_cycles = 1;
};

struct FdqScenarioStats {
    std::uint64_t cycles = 0;
    std::uint64_t instructions_consumed = 0;
    std::uint64_t empty_cycles = 0;
    std::uint64_t consumer_stall_cycles = 0;
    std::uint64_t single_issue_cycles = 0;
    std::uint64_t dual_issue_cycles = 0;
    std::uint64_t packets = 0;
    std::uint64_t one_instruction_packets = 0;
    std::uint64_t two_instruction_packets = 0;
    std::uint64_t producer_blocked_cycles = 0;
    std::uint64_t f0_corrections = 0;
    std::uint64_t f1_corrections = 0;
    std::uint64_t backend_direction_redirects = 0;
    std::uint64_t backend_target_redirects = 0;
    std::uint64_t system_redirects = 0;
    std::uint64_t estimated_f1_wrong_path_blocks = 0;
    std::uint64_t estimated_f1_wrong_path_slots = 0;
    std::uint64_t correction_observations = 0;
    std::uint64_t corrections_with_empty_fdq = 0;
    std::uint64_t occupancy_sum_at_correction = 0;
    std::uint64_t maximum_occupancy = 0;
    std::uint64_t occupancy_sum = 0;
    std::array<std::uint64_t, 17> retained_at_correction{};
};

struct FdqInstruction {
    std::uint32_t pc = 0;
    std::uint32_t instruction = 0;
    bool pred_taken = false;
    bool force_single_as_first = false;
    bool force_single_as_second = false;
    bool is_alu_type = false;
    bool is_lsu = false;
    bool is_cfi = false;
    bool writes_rd = false;
    bool uses_rs1 = false;
    bool uses_rs2 = false;
    std::uint8_t rd = 0;
    std::uint8_t rs1 = 0;
    std::uint8_t rs2 = 0;
};

struct FdqPacketControl {
    bool f0_correction = false;
    bool f1_correction = false;
    bool backend_direction_wrong = false;
    bool backend_target_wrong = false;
    bool system_redirect = false;
};

class FdqScenarioModel {
public:
    explicit FdqScenarioModel(FdqScenarioConfig config);
    void submit(const std::array<FdqInstruction, 2>& packet,
                std::uint8_t count, const FdqPacketControl& control);
    void finish();

    [[nodiscard]] const FdqScenarioConfig& config() const { return config_; }
    [[nodiscard]] const FdqScenarioStats& stats() const { return stats_; }

private:
    struct PendingCorrection {
        std::uint64_t cycle = 0;
    };

    [[nodiscard]] std::uint8_t dequeue_width() const;
    [[nodiscard]] bool consumer_stalled() const;
    [[nodiscard]] bool pair_ok(const FdqInstruction& first,
                               const FdqInstruction& second) const;
    void step(const std::array<FdqInstruction, 2>* packet,
              std::uint8_t packet_count);
    void record_due_corrections();
    void push(const FdqInstruction& instruction);
    void pop(std::uint8_t count);
    [[nodiscard]] const FdqInstruction& at(std::uint32_t offset) const;

    FdqScenarioConfig config_;
    std::array<FdqInstruction, 16> queue_{};
    std::uint32_t head_ = 0;
    std::uint32_t count_ = 0;
    std::uint64_t cycle_ = 0;
    std::uint64_t next_arrival_cycle_ = 0;
    std::optional<PendingCorrection> pending_correction_;
    FdqScenarioStats stats_{};
};

class FdqStudyModel {
public:
    explicit FdqStudyModel(std::vector<FdqScenarioConfig> scenarios);
    void observe(const CfiEvent& event, const FrontendDecision& decision);
    void finish();

    [[nodiscard]] const std::vector<FdqScenarioModel>& scenarios() const {
        return scenarios_;
    }

private:
    static FdqInstruction decode_instruction(const CfiEvent& event,
                                             const FrontendDecision& decision);
    static FdqPacketControl control(const CfiEvent& event,
                                    const FrontendDecision& decision);
    static bool allows_same_block_successor(const CfiEvent& event,
                                            const FrontendDecision& decision);
    void finalize_pending();

    std::vector<FdqScenarioModel> scenarios_;
    std::array<FdqInstruction, 2> pending_{};
    std::uint8_t pending_count_ = 0;
    bool pending_allows_successor_ = false;
    FdqPacketControl pending_control_{};
};

std::vector<FdqScenarioConfig> make_fdq_scenarios(
    std::uint32_t calibrated_consumer_stall_ppm = 0);
const char* fdq_consume_policy_name(FdqConsumePolicy policy);
const char* fdq_backend_policy_name(FdqBackendPolicy policy);

}  // namespace archsim
