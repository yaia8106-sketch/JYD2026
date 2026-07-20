#pragma once

#include "direction_predictor.hpp"
#include "rv32_sim.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace archsim {

enum class CfiClass : std::uint8_t {
    None,
    Branch,
    Jal,
    Call,
    Ret,
    IndirectJalr,
};

struct DecodedCfi {
    CfiClass type = CfiClass::None;
    bool direct_target_valid = false;
    std::uint32_t direct_target = 0;
    std::uint32_t return_address = 0;
};

DecodedCfi decode_cfi(std::uint32_t instruction, std::uint32_t pc);
const char* cfi_class_name(CfiClass type);

struct BlockContext {
    std::uint64_t block_id = 0;
    bool new_block = false;
    std::uint32_t start_pc = 0;
    std::uint32_t block_pc = 0;
    std::array<DecodedCfi, 2> slots{};
    std::uint8_t eligible_cfis = 0;
    bool current_is_first_cfi = false;
    bool current_is_second_cfi = false;
};

struct CfiBlockStats {
    std::uint64_t blocks = 0;
    std::uint64_t start_bank1 = 0;
    std::array<std::uint64_t, 3> blocks_by_cfi_count{};
    std::array<std::uint64_t, 36> pair_classes{};
    std::uint64_t executed_first_cfi = 0;
    std::uint64_t executed_second_cfi = 0;
    std::uint64_t second_branch = 0;
    std::uint64_t second_jal_or_call = 0;
    std::uint64_t second_ret_or_indirect = 0;
    std::uint64_t older_branch_nt_then_second_cfi = 0;
    std::uint64_t older_branch_nt_then_second_branch = 0;
};

class TraceProfiler {
public:
    explicit TraceProfiler(const ProgramImage& image) : image_(image) {}
    BlockContext observe(const CfiEvent& event);
    [[nodiscard]] const CfiBlockStats& stats() const { return stats_; }

private:
    [[nodiscard]] std::uint32_t instruction_at(std::uint32_t pc) const;

    const ProgramImage& image_;
    bool previous_valid_ = false;
    CfiEvent previous_{};
    std::uint64_t next_block_id_ = 1;
    BlockContext current_{};
    CfiBlockStats stats_{};
};

enum class AbtbType : std::uint8_t {
    Jal,
    Call,
    Branch,
    Ret,
};

struct AbtbPrediction {
    bool hit = false;
    std::uint8_t way = 0;
    AbtbType type = AbtbType::Jal;
    std::uint32_t target = 0;
};

struct AbtbSetStats {
    std::uint64_t lookups = 0;
    std::uint64_t hits = 0;
    std::uint64_t updates = 0;
    std::uint64_t allocations = 0;
    std::uint64_t replacements = 0;
};

struct AbtbStats {
    std::uint64_t resolved_cfis = 0;
    std::uint64_t resolved_hits = 0;
    std::uint64_t type_mismatches = 0;
    std::uint64_t target_mismatches = 0;
    std::uint64_t qualified_updates = 0;
    std::uint64_t stale_hit_writes = 0;
    std::array<std::uint64_t, 2> bank_lookups{};
    std::array<std::uint64_t, 2> bank_hits{};
    std::array<std::uint64_t, 2> bank_updates{};
    std::array<std::array<AbtbSetStats, 16>, 2> sets{};
};

class AbtbModel {
public:
    explicit AbtbModel(std::uint32_t update_delay_instructions);

    AbtbPrediction lookup(std::uint32_t pc, std::uint64_t instruction_ordinal);
    void resolve(const CfiEvent& event, const DecodedCfi& decoded,
                 const AbtbPrediction& prediction);
    void resolution_barrier();
    [[nodiscard]] const AbtbStats& stats() const { return stats_; }
    [[nodiscard]] static constexpr std::uint64_t logical_storage_bits() {
        return 64u * (7u + 2u + 32u + 1u) + 32u;
    }

private:
    struct Entry {
        bool valid = false;
        std::uint8_t tag = 0;
        AbtbType type = AbtbType::Jal;
        std::uint32_t target = 0;
    };
    struct PendingUpdate {
        std::uint64_t due_instruction = 0;
        std::uint32_t pc = 0;
        bool prediction_hit = false;
        std::uint8_t prediction_way = 0;
        AbtbType type = AbtbType::Jal;
        std::uint32_t target = 0;
    };

    void apply_due(std::uint64_t instruction_ordinal);
    void apply_front();
    static bool update_qualified(const CfiEvent& event,
                                 const DecodedCfi& decoded);
    static AbtbType update_type(const DecodedCfi& decoded);

    std::uint32_t update_delay_instructions_ = 0;
    std::array<std::array<std::array<Entry, 2>, 16>, 2> entries_{};
    std::array<std::array<std::uint8_t, 16>, 2> lru_{};
    std::deque<PendingUpdate> pending_;
    AbtbStats stats_{};
};

enum class RasPolicy : std::uint8_t {
    None,
    Committed,
    PendingOverlay,
    SpeculativeUpperBound,
};

struct RasConfig {
    RasPolicy policy = RasPolicy::None;
    std::uint32_t depth = 0;
    std::uint32_t pending_capacity = 0;
    std::uint32_t update_delay_instructions = 0;
};

struct RasPrediction {
    bool is_return = false;
    bool valid = false;
    std::uint32_t target = 0;
};

struct RasStats {
    std::uint64_t calls = 0;
    std::uint64_t returns = 0;
    std::uint64_t valid_predictions = 0;
    std::uint64_t correct_predictions = 0;
    std::uint64_t wrong_targets = 0;
    std::uint64_t invalid_predictions = 0;
    std::uint64_t committed_overflows = 0;
    std::uint64_t committed_underflows = 0;
    std::uint64_t overlay_overflows = 0;
    std::uint64_t maximum_committed_depth = 0;
    std::uint64_t maximum_pending_ops = 0;
};

class RasModel {
public:
    explicit RasModel(RasConfig config);
    RasPrediction observe(const CfiEvent& event, const DecodedCfi& decoded);
    void resolution_barrier();
    [[nodiscard]] const RasConfig& config() const { return config_; }
    [[nodiscard]] const RasStats& stats() const { return stats_; }
    [[nodiscard]] std::uint64_t logical_storage_bits() const;

private:
    enum class OpKind : std::uint8_t { Push, Pop };
    struct Op {
        std::uint64_t due_instruction = 0;
        OpKind kind = OpKind::Push;
        std::uint32_t value = 0;
    };

    void apply_due(std::uint64_t instruction_ordinal);
    void apply_front();
    void apply_op(std::vector<std::uint32_t>& stack, const Op& op,
                  bool count_events);
    [[nodiscard]] std::vector<std::uint32_t> effective_stack();

    RasConfig config_;
    std::vector<std::uint32_t> committed_;
    std::deque<Op> pending_;
    RasStats stats_{};
};

enum class TaggedReadPolicy : std::uint8_t {
    DualSlot,
    OldestCfiOnly,
};

// Instruction-count delay cannot represent the empty cycles introduced by a
// redirect.  These policies bound how aggressively a redirect is allowed to
// make already-resolved direction updates visible to subsequent predictions.
enum class DirectionBarrierPolicy : std::uint8_t {
    AllBackendRedirects,
    BranchDirectionRedirects,
    NaturalInstructionDelay,
};

enum class LateOverridePolicy : std::uint8_t {
    Always,
    TaggedStrong,
    TaggedUseful,
    TaggedStrongOrUseful,
    TaggedStrongAndUseful,
};

struct FrontendConfig {
    std::string name;
    DirectionConfig fast_direction;
    DirectionConfig tage_direction;
    bool enable_f0_direct = false;
    bool enable_f0_branch_direction = true;
    bool enable_f1_tage = false;
    bool enable_f1_ras = false;
    TaggedReadPolicy tagged_read_policy = TaggedReadPolicy::DualSlot;
    DirectionBarrierPolicy direction_barrier_policy =
        DirectionBarrierPolicy::AllBackendRedirects;
    LateOverridePolicy late_override_policy = LateOverridePolicy::Always;
    RasConfig ras;
};

struct FrontendStats {
    std::uint64_t cfis = 0;
    std::uint64_t branches = 0;
    std::uint64_t jal = 0;
    std::uint64_t jalr = 0;
    std::uint64_t calls = 0;
    std::uint64_t returns = 0;
    std::uint64_t abtb_hits = 0;
    std::uint64_t abtb_misses = 0;
    std::uint64_t abtb_branch_hits = 0;
    std::uint64_t abtb_jal_hits = 0;
    std::uint64_t abtb_jalr_hits = 0;
    std::uint64_t abtb_actionable_misses = 0;
    std::uint64_t abtb_nt_branch_misses = 0;
    std::uint64_t stage1_wrong = 0;
    std::uint64_t f0_wrong = 0;
    std::uint64_t f1_wrong = 0;
    std::uint64_t f0_corrections = 0;
    std::uint64_t f0_helpful = 0;
    std::uint64_t f0_harmful = 0;
    std::uint64_t f1_corrections = 0;
    std::uint64_t f1_helpful = 0;
    std::uint64_t f1_harmful = 0;
    std::uint64_t backend_direction_redirects = 0;
    std::uint64_t backend_target_redirects = 0;
    std::uint64_t tagged_queries = 0;
    std::uint64_t tagged_suppressed_second_cfi = 0;
    std::uint64_t confidence_suppressed_overrides = 0;
    std::uint64_t tagged_provider_hits = 0;
    std::uint64_t tagged_no_provider = 0;
    std::uint64_t tagged_alternate_fallbacks = 0;
    std::uint64_t f1_corrections_abtb_hit = 0;
    std::uint64_t f1_corrections_abtb_miss = 0;
    std::uint64_t f1_corrections_nt_to_taken = 0;
    std::uint64_t f1_corrections_taken_to_nt = 0;
    std::uint64_t f1_corrections_without_tagged_source = 0;
    std::array<std::uint64_t, 4> f1_corrections_by_tagged_table{};
    std::array<std::uint64_t, 4> f1_helpful_by_tagged_table{};
    std::array<std::uint64_t, 4> f1_harmful_by_tagged_table{};
    std::uint64_t second_cfi_resolved = 0;
    std::array<std::uint64_t, kIromBytes / 4> branches_by_pc{};
    std::array<std::uint64_t, kIromBytes / 4> backend_misses_by_pc{};
};

struct FrontendDecision {
    bool valid = false;
    std::uint32_t stage1_next = 0;
    std::uint32_t f0_next = 0;
    std::uint32_t f1_next = 0;
    bool f0_correction = false;
    bool f1_correction = false;
    bool backend_wrong = false;
    bool backend_direction_wrong = false;
    bool backend_target_wrong = false;
    bool abtb_hit = false;
    DirectionPrediction tagged{};
};

class FrontendModel {
public:
    explicit FrontendModel(FrontendConfig config);
    FrontendDecision observe(const CfiEvent& event,
                             const BlockContext& block);

    [[nodiscard]] const FrontendConfig& config() const { return config_; }
    [[nodiscard]] const FrontendStats& stats() const { return stats_; }
    [[nodiscard]] const DirectionStats& fast_direction_stats() const {
        return fast_direction_.stats();
    }
    [[nodiscard]] const DirectionStats& tage_direction_stats() const;
    [[nodiscard]] const AbtbStats& abtb_stats() const { return abtb_.stats(); }
    [[nodiscard]] const RasStats& ras_stats() const { return ras_.stats(); }
    [[nodiscard]] std::uint64_t logical_storage_bits() const;

private:
    static std::uint32_t fallthrough(const CfiEvent& event) {
        return event.source_pc + 4u;
    }
    static bool prediction_wrong(std::uint32_t prediction,
                                 const CfiEvent& event) {
        return prediction != event.next_pc;
    }
    void record_transition(std::uint32_t before, std::uint32_t after,
                           const CfiEvent& event, bool f1);

    FrontendConfig config_;
    DirectionPredictor fast_direction_;
    std::unique_ptr<DirectionPredictor> tage_direction_;
    AbtbModel abtb_;
    RasModel ras_;
    FrontendStats stats_{};
    bool previous_cfi_valid_ = false;
    std::uint32_t previous_cfi_pc_ = 0;
    bool previous_branch_not_taken_ = false;
    bool previous_branch_forced_refetch_ = false;
};

std::vector<FrontendConfig> make_frontend_study_configs(
    const std::vector<std::uint32_t>& delays);

}  // namespace archsim
