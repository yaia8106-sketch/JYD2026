#pragma once

#include "rv32_sim.hpp"

#include <array>
#include <bitset>
#include <cstdint>
#include <string>
#include <vector>

namespace archsim {

enum class PredictorFamily : std::uint8_t {
    Bimodal,
    Gshare,
    TargetLast,
    TargetRolling,
    LastTarget,
    SourcePath,
    TargetPath,
    NextPcPath,
    EdgePath,
};

enum class TargetHash : std::uint8_t {
    Fold8,
    Low8,
    Fold4,
    Fold2,
};

enum class UpdateScope : std::uint8_t {
    None,
    ConditionalOnly,
    AllCfi,
};

struct PredictorConfig {
    std::string name;
    PredictorFamily family = PredictorFamily::Gshare;
    UpdateScope path_scope = UpdateScope::None;
    TargetHash target_hash = TargetHash::Fold8;
    std::uint32_t update_delay_instructions = 0;
    bool mispredict_resolution_barrier = true;
};

struct PredictorStats {
    std::uint64_t branches = 0;
    std::uint64_t taken = 0;
    std::uint64_t predicted_taken = 0;
    std::uint64_t correct = 0;
    std::uint64_t mispredictions = 0;
    std::uint64_t alias_switches = 0;
    std::uint64_t alias_associated_misses = 0;
    std::uint64_t static_branches = 0;
    std::uint64_t branch_index_pairs = 0;
    std::uint32_t max_indices_per_branch = 0;
};

class PredictorModel {
public:
    explicit PredictorModel(PredictorConfig config);

    void observe(const CfiEvent& event);
    [[nodiscard]] PredictorStats finalize_stats() const;
    [[nodiscard]] const PredictorConfig& config() const { return config_; }

private:
    static constexpr std::size_t kPhtEntries = 256;
    static constexpr std::size_t kMaxPending = 64;
    static constexpr std::size_t kIromWords = kIromBytes / 4;

    struct PendingUpdate {
        std::uint64_t due_instruction = 0;
        std::uint64_t order = 0;
        CfiEvent event{};
        std::uint8_t pht_index = 0;
        std::uint8_t counter_snapshot = 0;
        bool has_direction_update = false;
    };

    [[nodiscard]] static std::uint8_t address_hash(std::uint32_t address);
    [[nodiscard]] std::uint8_t target_hash(std::uint32_t address) const;
    [[nodiscard]] std::uint8_t spread_path_history() const;
    [[nodiscard]] std::uint8_t lookup_index(std::uint32_t pc) const;
    [[nodiscard]] bool uses_ghr() const;
    [[nodiscard]] bool uses_path() const;
    [[nodiscard]] bool path_event_eligible(const CfiEvent& event) const;
    [[nodiscard]] std::uint8_t path_event_hash(const CfiEvent& event) const;

    void push_pending(const PendingUpdate& update);
    void apply_front();
    void apply_due(std::uint64_t instruction_ordinal);
    void force_resolve_through(std::uint64_t order);

    PredictorConfig config_;
    std::array<std::uint8_t, kPhtEntries> pht_{};
    std::uint8_t ghr_ = 0;
    std::uint8_t path_history_ = 0;

    std::array<PendingUpdate, kMaxPending> pending_{};
    std::size_t pending_head_ = 0;
    std::size_t pending_size_ = 0;
    std::uint64_t next_order_ = 0;

    PredictorStats stats_{};
    std::array<std::uint32_t, kPhtEntries> last_pc_by_index_{};
    std::bitset<kPhtEntries> last_pc_valid_{};
    std::array<std::bitset<kPhtEntries>, kIromWords> indices_by_pc_{};
};

std::vector<PredictorConfig> make_first_round_configs(
    const std::vector<std::uint32_t>& delays,
    bool mispredict_resolution_barrier);

std::vector<PredictorConfig> make_target_history_configs(
    const std::vector<std::uint32_t>& delays,
    bool mispredict_resolution_barrier);

}  // namespace archsim
