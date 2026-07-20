#pragma once

#include "rv32_sim.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

namespace archsim {

enum class DirectionFamily : std::uint8_t {
    Bimodal,
    Gshare,
    Gselect,
    Tage,
};

enum class BaseIndexMode : std::uint8_t {
    LowPc,
    FoldedPc,
    Pc2BankedLowPc,
    Pc2BankedFoldedPc,
};

struct TageTableConfig {
    std::uint32_t entries = 0;
    std::uint32_t history_length = 0;
    std::uint32_t tag_bits = 0;
};

struct DirectionConfig {
    std::string name;
    DirectionFamily family = DirectionFamily::Gshare;
    std::uint32_t base_entries = 256;
    std::uint32_t history_length = 8;
    BaseIndexMode base_index_mode = BaseIndexMode::LowPc;
    bool tagged_pc2_banked = false;
    std::vector<TageTableConfig> tagged_tables;
    std::uint32_t update_delay_instructions = 0;
    bool mispredict_resolution_barrier = true;
    bool use_alternate_on_weak_new = true;
    // A late tagged-only predictor has no private bimodal table.  Its base
    // prediction is supplied by the already-computed BP/F0 next-PC decision.
    bool external_base_prediction = false;
};

struct DirectionStats {
    std::uint64_t branches = 0;
    std::uint64_t taken = 0;
    std::uint64_t predicted_taken = 0;
    std::uint64_t correct = 0;
    std::uint64_t mispredictions = 0;
    std::uint64_t base_provider = 0;
    std::uint64_t base_provider_correct = 0;
    std::array<std::uint64_t, 4> tagged_provider{};
    std::array<std::uint64_t, 4> tagged_provider_correct{};
    std::uint64_t final_base_source = 0;
    std::uint64_t final_base_correct = 0;
    std::array<std::uint64_t, 4> final_tagged_source{};
    std::array<std::uint64_t, 4> final_tagged_correct{};
    std::uint64_t alternate_used = 0;
    std::uint64_t alternate_correct = 0;
    std::array<std::uint64_t, 2> base_bank_lookups{};
    std::array<std::uint64_t, 2> base_bank_misses{};
    std::uint64_t base_alias_switches = 0;
    std::uint64_t base_alias_misses = 0;
    std::array<std::uint64_t, 2> base_bank_alias_switches{};
    std::array<std::uint64_t, 2> base_bank_alias_misses{};
    std::uint64_t allocations = 0;
    std::uint64_t allocation_failures = 0;
    std::array<std::uint64_t, 2> allocations_by_bank{};
    std::array<std::uint64_t, 2> allocation_failures_by_bank{};
    std::uint64_t stale_provider_updates = 0;
    std::array<std::uint64_t, kIromBytes / 4> branches_by_pc{};
    std::array<std::uint64_t, kIromBytes / 4> misses_by_pc{};
};

// Prediction-time result exposed to the integrated frontend model.  The
// predictor still owns the full metadata token internally; callers only need
// the architectural direction and enough diagnostics to compare BP and F1.
struct DirectionPrediction {
    bool valid = false;
    bool base_taken = false;
    bool final_taken = false;
    bool tagged_accessed = false;
    bool used_alternate = false;
    std::uint32_t base_index = 0;
    int provider = -1;
    int final_source = -1;
    std::int8_t final_counter = 0;
    std::uint8_t final_useful = 0;
};

class DirectionPredictor {
public:
    explicit DirectionPredictor(DirectionConfig config);

    DirectionPrediction observe(const CfiEvent& event,
                                bool tagged_access = true,
                                bool automatic_barrier = true,
                                std::optional<bool> external_base = std::nullopt);
    // The integrated BP/F0/F1 model calls this only when the final F1
    // prediction, rather than an intermediate BP prediction, is wrong.
    void resolution_barrier();
    [[nodiscard]] const DirectionConfig& config() const { return config_; }
    [[nodiscard]] const DirectionStats& stats() const { return stats_; }
    [[nodiscard]] std::uint64_t logical_storage_bits() const;
    [[nodiscard]] std::uint64_t two_read_storage_bits() const;
    [[nodiscard]] std::uint32_t maximum_history_length() const;

private:
    struct TageEntry {
        std::uint16_t tag = 0;
        std::int8_t counter = 0;
        std::uint8_t useful = 0;
        bool valid = false;
    };

    struct TableLookup {
        std::uint32_t index = 0;
        std::uint16_t tag = 0;
        std::int8_t counter = 0;
        std::uint8_t useful = 0;
        bool matched = false;
    };

    struct PendingUpdate {
        std::uint64_t due_instruction = 0;
        std::uint64_t order = 0;
        CfiEvent event{};
        std::uint64_t history_snapshot = 0;
        std::uint32_t base_index = 0;
        std::uint8_t base_counter = 0;
        bool base_prediction = false;
        std::vector<TableLookup> tables;
        int provider = -1;
        int alternate = -1;
        bool provider_prediction = false;
        bool alternate_prediction = false;
        bool final_prediction = false;
        bool used_alternate = false;
        int final_source = -1;
    };

    [[nodiscard]] static bool is_power_of_two(std::uint32_t value);
    [[nodiscard]] static std::uint32_t index_bits(std::uint32_t entries);
    [[nodiscard]] static std::uint64_t bit_mask(std::uint32_t width);
    [[nodiscard]] static std::uint32_t fold_history(
        std::uint64_t history, std::uint32_t history_length,
        std::uint32_t output_width);
    [[nodiscard]] std::uint32_t base_index(std::uint32_t pc,
                                           std::uint64_t history) const;
    [[nodiscard]] std::uint32_t table_index(
        std::size_t table, std::uint32_t pc, std::uint64_t history) const;
    [[nodiscard]] std::uint16_t table_tag(
        std::size_t table, std::uint32_t pc, std::uint64_t history) const;
    [[nodiscard]] bool base_is_pc2_banked() const;

    static std::uint8_t update_base_counter(std::uint8_t counter, bool taken);
    static std::int8_t update_tagged_counter(std::int8_t counter, bool taken);
    void apply_front();
    void apply_due(std::uint64_t instruction_ordinal);
    void force_resolve_through(std::uint64_t order);
    void update_tage(const PendingUpdate& update);

    DirectionConfig config_;
    std::vector<std::uint8_t> base_table_;
    std::vector<std::uint32_t> last_pc_by_base_index_;
    std::vector<bool> last_pc_by_base_index_valid_;
    std::vector<std::vector<TageEntry>> tagged_tables_;
    std::uint64_t ghr_ = 0;
    std::deque<PendingUpdate> pending_;
    std::uint64_t next_order_ = 0;
    DirectionStats stats_{};
};

std::vector<DirectionConfig> make_direction_study_configs(
    const std::vector<std::uint32_t>& delays,
    bool mispredict_resolution_barrier);

}  // namespace archsim
