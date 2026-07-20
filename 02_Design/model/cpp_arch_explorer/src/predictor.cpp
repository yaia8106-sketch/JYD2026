#include "predictor.hpp"

#include <algorithm>
#include <stdexcept>
#include <utility>

namespace archsim {

PredictorModel::PredictorModel(PredictorConfig config)
    : config_(std::move(config)) {
    pht_.fill(1u);  // weakly not-taken, matching frontend_stage1_direction.sv
}

std::uint8_t PredictorModel::address_hash(const std::uint32_t address) {
    const auto low = static_cast<std::uint8_t>((address >> 2u) & 0xffu);
    const auto upper = static_cast<std::uint8_t>((address >> 10u) & 0x0fu);
    return static_cast<std::uint8_t>(low ^ upper);
}

std::uint8_t PredictorModel::target_hash(const std::uint32_t address) const {
    const auto word_address = address >> 2u;
    switch (config_.target_hash) {
        case TargetHash::Low8:
            return static_cast<std::uint8_t>(word_address & 0xffu);
        case TargetHash::Fold4: {
            const auto folded = word_address ^ (word_address >> 4u) ^
                                (word_address >> 8u);
            return static_cast<std::uint8_t>(folded & 0x0fu);
        }
        case TargetHash::Fold2: {
            const auto folded = word_address ^ (word_address >> 2u) ^
                                (word_address >> 4u) ^ (word_address >> 6u) ^
                                (word_address >> 8u) ^ (word_address >> 10u);
            return static_cast<std::uint8_t>(folded & 0x03u);
        }
        case TargetHash::Fold8:
            return address_hash(address);
    }
    return 0;
}

std::uint8_t PredictorModel::spread_path_history() const {
    if (config_.target_hash == TargetHash::Fold4) {
        const auto nibble = static_cast<std::uint8_t>(path_history_ & 0x0fu);
        return static_cast<std::uint8_t>((nibble << 4u) | nibble);
    }
    if (config_.target_hash == TargetHash::Fold2) {
        const auto pair = static_cast<std::uint8_t>(path_history_ & 0x03u);
        return static_cast<std::uint8_t>((pair << 6u) | (pair << 4u) |
                                         (pair << 2u) | pair);
    }
    return path_history_;
}

bool PredictorModel::uses_ghr() const {
    return config_.family != PredictorFamily::Bimodal &&
           config_.family != PredictorFamily::TargetLast &&
           config_.family != PredictorFamily::TargetRolling;
}

bool PredictorModel::uses_path() const {
    return config_.family != PredictorFamily::Bimodal &&
           config_.family != PredictorFamily::Gshare;
}

std::uint8_t PredictorModel::lookup_index(const std::uint32_t pc) const {
    // The baseline deliberately uses the exact RTL PC slice.  Alternative
    // configurations add a precomputed path signature without adding a
    // lookup-time address fold.
    auto index = static_cast<std::uint8_t>((pc >> 2u) & 0xffu);
    if (uses_ghr()) {
        index = static_cast<std::uint8_t>(index ^ ghr_);
    }
    if (uses_path()) {
        index = static_cast<std::uint8_t>(index ^ spread_path_history());
    }
    return index;
}

bool PredictorModel::path_event_eligible(const CfiEvent& event) const {
    if (!uses_path() || event.kind == CfiKind::None) {
        return false;
    }
    if (config_.path_scope == UpdateScope::ConditionalOnly &&
        event.kind != CfiKind::Branch) {
        return false;
    }
    if (config_.path_scope == UpdateScope::None) {
        return false;
    }

    // A target is part of the executed path only when that control transfer
    // is taken.  Source/next-PC/edge signatures can represent a not-taken
    // conditional edge as well.
    if ((config_.family == PredictorFamily::LastTarget ||
         config_.family == PredictorFamily::TargetPath ||
         config_.family == PredictorFamily::TargetLast ||
         config_.family == PredictorFamily::TargetRolling) &&
        !event.taken) {
        return false;
    }
    return true;
}

std::uint8_t PredictorModel::path_event_hash(const CfiEvent& event) const {
    switch (config_.family) {
        case PredictorFamily::LastTarget:
        case PredictorFamily::TargetPath:
        case PredictorFamily::TargetLast:
        case PredictorFamily::TargetRolling:
            return target_hash(event.target);
        case PredictorFamily::SourcePath:
            return address_hash(event.source_pc);
        case PredictorFamily::NextPcPath:
            return address_hash(event.next_pc);
        case PredictorFamily::EdgePath:
            return static_cast<std::uint8_t>(address_hash(event.source_pc) ^
                                             address_hash(event.next_pc));
        case PredictorFamily::Bimodal:
        case PredictorFamily::Gshare:
            return 0;
    }
    return 0;
}

void PredictorModel::push_pending(const PendingUpdate& update) {
    if (pending_size_ == kMaxPending) {
        throw std::runtime_error(
            "predictor pending-update queue overflow; reduce update delay");
    }
    const auto tail = (pending_head_ + pending_size_) % kMaxPending;
    pending_[tail] = update;
    ++pending_size_;
}

void PredictorModel::apply_front() {
    if (pending_size_ == 0) {
        return;
    }

    const auto update = pending_[pending_head_];
    pending_head_ = (pending_head_ + 1u) % kMaxPending;
    --pending_size_;

    if (update.has_direction_update) {
        const auto old_counter = update.counter_snapshot;
        if (update.event.taken) {
            pht_[update.pht_index] =
                static_cast<std::uint8_t>(std::min<unsigned>(3u, old_counter + 1u));
        } else {
            pht_[update.pht_index] =
                static_cast<std::uint8_t>(old_counter == 0u ? 0u : old_counter - 1u);
        }
        if (uses_ghr()) {
            ghr_ = static_cast<std::uint8_t>(
                (ghr_ << 1u) | static_cast<std::uint8_t>(update.event.taken));
        }
    }

    if (path_event_eligible(update.event)) {
        const auto event_hash = path_event_hash(update.event);
        if (config_.family == PredictorFamily::LastTarget ||
            config_.family == PredictorFamily::TargetLast) {
            path_history_ = event_hash;
        } else {
            if (config_.target_hash == TargetHash::Fold2) {
                const auto history =
                    static_cast<std::uint8_t>(path_history_ & 0x03u);
                const auto rotated = static_cast<std::uint8_t>(
                    ((history << 1u) | (history >> 1u)) & 0x03u);
                path_history_ = static_cast<std::uint8_t>(
                    (rotated ^ event_hash) & 0x03u);
            } else if (config_.target_hash == TargetHash::Fold4) {
                const auto history =
                    static_cast<std::uint8_t>(path_history_ & 0x0fu);
                const auto rotated = static_cast<std::uint8_t>(
                    ((history << 1u) | (history >> 3u)) & 0x0fu);
                path_history_ = static_cast<std::uint8_t>(
                    (rotated ^ event_hash) & 0x0fu);
            } else {
                const auto rotated = static_cast<std::uint8_t>(
                    static_cast<std::uint8_t>(path_history_ << 1u) |
                    static_cast<std::uint8_t>(path_history_ >> 7u));
                path_history_ = static_cast<std::uint8_t>(rotated ^ event_hash);
            }
        }
    }
}

void PredictorModel::apply_due(const std::uint64_t instruction_ordinal) {
    while (pending_size_ != 0 &&
           pending_[pending_head_].due_instruction <= instruction_ordinal) {
        apply_front();
    }
}

void PredictorModel::force_resolve_through(const std::uint64_t order) {
    while (pending_size_ != 0 && pending_[pending_head_].order <= order) {
        apply_front();
    }
}

void PredictorModel::observe(const CfiEvent& event) {
    apply_due(event.instruction_ordinal);

    PendingUpdate update{};
    update.due_instruction =
        event.instruction_ordinal + config_.update_delay_instructions;
    update.order = next_order_++;
    update.event = event;

    bool mispredicted = false;
    if (event.kind == CfiKind::Branch) {
        const auto index = lookup_index(event.source_pc);
        const auto counter = pht_[index];
        const bool predicted_taken = (counter & 0x2u) != 0u;
        mispredicted = predicted_taken != event.taken;

        ++stats_.branches;
        stats_.taken += static_cast<std::uint64_t>(event.taken);
        stats_.predicted_taken += static_cast<std::uint64_t>(predicted_taken);
        stats_.mispredictions += static_cast<std::uint64_t>(mispredicted);
        stats_.correct += static_cast<std::uint64_t>(!mispredicted);

        if (last_pc_valid_.test(index) &&
            last_pc_by_index_[index] != event.source_pc) {
            ++stats_.alias_switches;
            stats_.alias_associated_misses +=
                static_cast<std::uint64_t>(mispredicted);
        }
        last_pc_by_index_[index] = event.source_pc;
        last_pc_valid_.set(index);

        if (event.source_pc >= kIromBase &&
            event.source_pc < kIromBase + kIromBytes) {
            const auto word = static_cast<std::size_t>(
                (event.source_pc - kIromBase) >> 2u);
            indices_by_pc_[word].set(index);
        }

        update.pht_index = index;
        update.counter_snapshot = counter;
        update.has_direction_update = true;
    }

    const bool needs_path_update = path_event_eligible(event);
    if (update.has_direction_update || needs_path_update) {
        push_pending(update);
        if (config_.update_delay_instructions == 0u) {
            apply_due(event.instruction_ordinal);
        } else if (mispredicted && config_.mispredict_resolution_barrier) {
            // The correct path is fetched only after this branch resolves.
            // Wrong-path instructions are not modeled because predictor state
            // is committed-only, but the resolving branch and all older
            // updates must be visible before the next correct-path CFI.
            force_resolve_through(update.order);
        }
    }
}

PredictorStats PredictorModel::finalize_stats() const {
    auto result = stats_;
    for (const auto& indices : indices_by_pc_) {
        const auto count = static_cast<std::uint32_t>(indices.count());
        if (count != 0u) {
            ++result.static_branches;
            result.branch_index_pairs += count;
            result.max_indices_per_branch =
                std::max(result.max_indices_per_branch, count);
        }
    }
    return result;
}

std::vector<PredictorConfig> make_first_round_configs(
    const std::vector<std::uint32_t>& delays,
    const bool mispredict_resolution_barrier) {
    std::vector<PredictorConfig> configs;

    const auto add = [&](const std::string& base_name,
                         const PredictorFamily family,
                         const UpdateScope scope,
                         const std::uint32_t delay) {
        PredictorConfig config;
        config.name = base_name;
        config.family = family;
        config.path_scope = scope;
        config.update_delay_instructions = delay;
        config.mispredict_resolution_barrier = mispredict_resolution_barrier;
        configs.push_back(std::move(config));
    };

    const std::array path_families{
        std::pair{std::string{"LAST_TARGET"}, PredictorFamily::LastTarget},
        std::pair{std::string{"SOURCE_PATH"}, PredictorFamily::SourcePath},
        std::pair{std::string{"TARGET_PATH"}, PredictorFamily::TargetPath},
        std::pair{std::string{"NEXT_PC_PATH"}, PredictorFamily::NextPcPath},
        std::pair{std::string{"EDGE_PATH"}, PredictorFamily::EdgePath},
    };

    for (const auto delay : delays) {
        add("BIMODAL", PredictorFamily::Bimodal, UpdateScope::None, delay);
        add("GSHARE", PredictorFamily::Gshare, UpdateScope::None, delay);
        for (const auto& [name, family] : path_families) {
            add(name + "_BRANCH", family, UpdateScope::ConditionalOnly, delay);
            add(name + "_ALL_CFI", family, UpdateScope::AllCfi, delay);
        }
    }
    return configs;
}

std::vector<PredictorConfig> make_target_history_configs(
    const std::vector<std::uint32_t>& delays,
    const bool mispredict_resolution_barrier) {
    std::vector<PredictorConfig> configs;

    const auto add = [&](const std::string& name,
                         const PredictorFamily family,
                         const UpdateScope scope,
                         const TargetHash target_hash,
                         const std::uint32_t delay) {
        PredictorConfig config;
        config.name = name;
        config.family = family;
        config.path_scope = scope;
        config.target_hash = target_hash;
        config.update_delay_instructions = delay;
        config.mispredict_resolution_barrier = mispredict_resolution_barrier;
        configs.push_back(std::move(config));
    };

    for (const auto delay : delays) {
        add("BIMODAL", PredictorFamily::Bimodal, UpdateScope::None,
            TargetHash::Fold8, delay);
        add("GSHARE", PredictorFamily::Gshare, UpdateScope::None,
            TargetHash::Fold8, delay);

        add("TARGET_LAST_LOW8", PredictorFamily::TargetLast,
            UpdateScope::ConditionalOnly, TargetHash::Low8, delay);
        add("TARGET_LAST_FOLD8", PredictorFamily::TargetLast,
            UpdateScope::ConditionalOnly, TargetHash::Fold8, delay);
        add("TARGET_LAST_FOLD4", PredictorFamily::TargetLast,
            UpdateScope::ConditionalOnly, TargetHash::Fold4, delay);
        add("TARGET_LAST_FOLD2", PredictorFamily::TargetLast,
            UpdateScope::ConditionalOnly, TargetHash::Fold2, delay);

        add("TARGET_ROLL_LOW8", PredictorFamily::TargetRolling,
            UpdateScope::ConditionalOnly, TargetHash::Low8, delay);
        add("TARGET_ROLL_FOLD8", PredictorFamily::TargetRolling,
            UpdateScope::ConditionalOnly, TargetHash::Fold8, delay);
        add("TARGET_ROLL_FOLD4", PredictorFamily::TargetRolling,
            UpdateScope::ConditionalOnly, TargetHash::Fold4, delay);

        // Keep the previous PC ^ GHR ^ last-target design as a control so the
        // experiment cleanly separates replacement from augmentation.
        add("GSHARE_PLUS_LAST_TARGET", PredictorFamily::LastTarget,
            UpdateScope::ConditionalOnly, TargetHash::Fold8, delay);
        add("GSHARE_PLUS_LAST_TARGET_FOLD4", PredictorFamily::LastTarget,
            UpdateScope::ConditionalOnly, TargetHash::Fold4, delay);
        add("GSHARE_PLUS_LAST_TARGET_FOLD2", PredictorFamily::LastTarget,
            UpdateScope::ConditionalOnly, TargetHash::Fold2, delay);
    }
    return configs;
}

}  // namespace archsim
