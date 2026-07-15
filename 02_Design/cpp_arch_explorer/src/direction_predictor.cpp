#include "direction_predictor.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <utility>

namespace archsim {

DirectionPredictor::DirectionPredictor(DirectionConfig config)
    : config_(std::move(config)), base_table_(config_.base_entries, 1u),
      last_pc_by_base_index_(config_.base_entries),
      last_pc_by_base_index_valid_(config_.base_entries) {
    if (!is_power_of_two(config_.base_entries)) {
        throw std::runtime_error("base predictor entries must be a power of two");
    }
    if (maximum_history_length() > 63u) {
        throw std::runtime_error("direction study supports at most 63 history bits");
    }
    if (base_is_pc2_banked() && config_.base_entries < 2u) {
        throw std::runtime_error("PC[2]-banked base requires at least two entries");
    }
    if (config_.tagged_tables.size() > stats_.tagged_provider.size()) {
        throw std::runtime_error("too many tagged tables for direction statistics");
    }
    for (const auto& table : config_.tagged_tables) {
        if (!is_power_of_two(table.entries) || table.entries < 2u ||
            table.tag_bits == 0u ||
            table.tag_bits > 16u) {
            throw std::runtime_error("invalid tagged table configuration");
        }
        tagged_tables_.emplace_back(table.entries);
    }
}

bool DirectionPredictor::is_power_of_two(const std::uint32_t value) {
    return value != 0u && (value & (value - 1u)) == 0u;
}

std::uint32_t DirectionPredictor::index_bits(const std::uint32_t entries) {
    std::uint32_t bits = 0;
    for (auto value = entries; value > 1u; value >>= 1u) {
        ++bits;
    }
    return bits;
}

std::uint64_t DirectionPredictor::bit_mask(const std::uint32_t width) {
    return width == 0u ? 0u : (std::uint64_t{1} << width) - 1u;
}

std::uint32_t DirectionPredictor::fold_history(
    const std::uint64_t history, const std::uint32_t history_length,
    const std::uint32_t output_width) {
    if (output_width == 0u || history_length == 0u) {
        return 0u;
    }
    const auto mask = bit_mask(output_width);
    const auto relevant_history = history & bit_mask(history_length);
    std::uint64_t folded = 0;
    for (std::uint32_t offset = 0; offset < history_length;
         offset += output_width) {
        folded ^= (relevant_history >> offset) & mask;
    }
    return static_cast<std::uint32_t>(folded & mask);
}

std::uint32_t DirectionPredictor::base_index(
    const std::uint32_t pc, const std::uint64_t history) const {
    const auto bits = index_bits(config_.base_entries);
    const auto pc_index = (pc >> 2u) & (config_.base_entries - 1u);
    if (config_.family == DirectionFamily::Gshare) {
        return pc_index ^ fold_history(history, config_.history_length, bits);
    }
    if (config_.family == DirectionFamily::Gselect) {
        const auto history_bits = std::min(config_.history_length, bits);
        const auto pc_bits = bits - history_bits;
        const auto pc_part = pc_bits == 0u
                                 ? 0u
                                 : pc_index & static_cast<std::uint32_t>(
                                                   bit_mask(pc_bits));
        const auto history_part = static_cast<std::uint32_t>(
            history & bit_mask(history_bits));
        return (pc_part << history_bits) | history_part;
    }
    if (config_.base_index_mode == BaseIndexMode::LowPc) {
        return pc_index;
    }
    const auto irom_word = (pc >> 2u) & 0xfffu;
    if (config_.base_index_mode == BaseIndexMode::FoldedPc) {
        return fold_history(irom_word, 12u, bits);
    }

    const auto bank = static_cast<std::uint32_t>((pc >> 2u) & 1u);
    const auto rows = config_.base_entries / 2u;
    const auto row_bits = index_bits(rows);
    const auto pc_row = (pc >> 3u) & 0x7ffu;
    const auto row = config_.base_index_mode == BaseIndexMode::Pc2BankedLowPc
                         ? pc_row & (rows - 1u)
                         : fold_history(pc_row, 11u, row_bits);
    return bank * rows + row;
}

bool DirectionPredictor::base_is_pc2_banked() const {
    return config_.base_index_mode == BaseIndexMode::Pc2BankedLowPc ||
           config_.base_index_mode == BaseIndexMode::Pc2BankedFoldedPc;
}

std::uint32_t DirectionPredictor::table_index(
    const std::size_t table, const std::uint32_t pc,
    const std::uint64_t history) const {
    const auto& cfg = config_.tagged_tables.at(table);
    const auto entries = config_.tagged_pc2_banked ? cfg.entries / 2u
                                                    : cfg.entries;
    const auto bits = index_bits(entries);
    const auto pc_word = pc >> (config_.tagged_pc2_banked ? 3u : 2u);
    const auto folded = fold_history(history, cfg.history_length, bits);
    const auto rotated = static_cast<std::uint32_t>(
        ((folded << 1u) | (folded >> (bits - 1u))) & (entries - 1u));
    const auto row = (pc_word ^ folded ^ rotated) & (entries - 1u);
    if (!config_.tagged_pc2_banked) {
        return row;
    }
    return static_cast<std::uint32_t>((pc >> 2u) & 1u) * entries + row;
}

std::uint16_t DirectionPredictor::table_tag(
    const std::size_t table, const std::uint32_t pc,
    const std::uint64_t history) const {
    const auto& cfg = config_.tagged_tables.at(table);
    const auto mask = static_cast<std::uint32_t>(bit_mask(cfg.tag_bits));
    const auto folded0 = fold_history(history, cfg.history_length, cfg.tag_bits);
    const auto folded1 = fold_history(
        history >> 1u, cfg.history_length > 0u ? cfg.history_length - 1u : 0u,
        cfg.tag_bits);
    return static_cast<std::uint16_t>(
        ((pc >> 2u) ^ folded0 ^ ((folded1 << 1u) & mask)) & mask);
}

std::uint8_t DirectionPredictor::update_base_counter(
    const std::uint8_t counter, const bool taken) {
    if (taken) {
        return static_cast<std::uint8_t>(std::min<unsigned>(3u, counter + 1u));
    }
    return counter == 0u ? 0u : static_cast<std::uint8_t>(counter - 1u);
}

std::int8_t DirectionPredictor::update_tagged_counter(
    const std::int8_t counter, const bool taken) {
    if (taken) {
        return static_cast<std::int8_t>(std::min<int>(3, counter + 1));
    }
    return static_cast<std::int8_t>(std::max<int>(-4, counter - 1));
}

DirectionPrediction DirectionPredictor::observe(
    const CfiEvent& event, const bool tagged_access,
    const bool automatic_barrier,
    const std::optional<bool> external_base) {
    apply_due(event.instruction_ordinal);
    if (event.kind != CfiKind::Branch) {
        return {};
    }

    PendingUpdate update;
    update.due_instruction =
        event.instruction_ordinal + config_.update_delay_instructions;
    update.order = next_order_++;
    update.event = event;
    update.history_snapshot = ghr_;
    update.base_index = base_index(event.source_pc, ghr_);
    update.base_counter = base_table_.at(update.base_index);
    if (config_.external_base_prediction && !external_base.has_value()) {
        throw std::runtime_error(
            "tagged-only predictor requires an external base prediction");
    }
    update.base_prediction = config_.external_base_prediction
                                 ? *external_base
                                 : (update.base_counter & 0x2u) != 0u;
    update.alternate_prediction = update.base_prediction;
    update.provider_prediction = update.alternate_prediction;
    update.final_prediction = update.provider_prediction;
    update.final_source = -1;

    if (config_.family == DirectionFamily::Tage && tagged_access) {
        update.tables.reserve(config_.tagged_tables.size());
        for (std::size_t table = 0; table < config_.tagged_tables.size(); ++table) {
            TableLookup lookup;
            lookup.index = table_index(table, event.source_pc, ghr_);
            lookup.tag = table_tag(table, event.source_pc, ghr_);
            const auto& entry = tagged_tables_[table][lookup.index];
            lookup.matched = entry.valid && entry.tag == lookup.tag;
            lookup.counter = entry.counter;
            lookup.useful = entry.useful;
            update.tables.push_back(lookup);
            if (lookup.matched) {
                update.alternate = update.provider;
                update.alternate_prediction = update.provider_prediction;
                update.provider = static_cast<int>(table);
                update.provider_prediction = lookup.counter >= 0;
            }
        }
        if (update.provider >= 0) {
            const auto& provider = update.tables[update.provider];
            const bool weak = provider.counter == -1 || provider.counter == 0;
            update.used_alternate = config_.use_alternate_on_weak_new &&
                                    provider.useful == 0u && weak;
            update.final_prediction = update.used_alternate
                                          ? update.alternate_prediction
                                          : update.provider_prediction;
            update.final_source = update.used_alternate ? update.alternate
                                                        : update.provider;
            ++stats_.tagged_provider[update.provider];
            stats_.tagged_provider_correct[update.provider] +=
                static_cast<std::uint64_t>(update.provider_prediction ==
                                           event.taken);
            stats_.alternate_used +=
                static_cast<std::uint64_t>(update.used_alternate);
            stats_.alternate_correct += static_cast<std::uint64_t>(
                update.used_alternate &&
                update.alternate_prediction == event.taken);
        } else {
            ++stats_.base_provider;
            stats_.base_provider_correct += static_cast<std::uint64_t>(
                update.provider_prediction == event.taken);
        }
    } else {
        ++stats_.base_provider;
        stats_.base_provider_correct += static_cast<std::uint64_t>(
            update.provider_prediction == event.taken);
    }

    const bool mispredicted = update.final_prediction != event.taken;
    if (update.final_source < 0) {
        ++stats_.final_base_source;
        stats_.final_base_correct += static_cast<std::uint64_t>(!mispredicted);
    } else {
        ++stats_.final_tagged_source[update.final_source];
        stats_.final_tagged_correct[update.final_source] +=
            static_cast<std::uint64_t>(!mispredicted);
    }
    const auto pc_bank = static_cast<std::size_t>((event.source_pc >> 2u) & 1u);
    ++stats_.base_bank_lookups[pc_bank];
    stats_.base_bank_misses[pc_bank] +=
        static_cast<std::uint64_t>(mispredicted);
    if (last_pc_by_base_index_valid_[update.base_index] &&
        last_pc_by_base_index_[update.base_index] != event.source_pc) {
        ++stats_.base_alias_switches;
        ++stats_.base_bank_alias_switches[pc_bank];
        if (mispredicted) {
            ++stats_.base_alias_misses;
            ++stats_.base_bank_alias_misses[pc_bank];
        }
    }
    last_pc_by_base_index_valid_[update.base_index] = true;
    last_pc_by_base_index_[update.base_index] = event.source_pc;
    ++stats_.branches;
    stats_.taken += static_cast<std::uint64_t>(event.taken);
    stats_.predicted_taken +=
        static_cast<std::uint64_t>(update.final_prediction);
    stats_.correct += static_cast<std::uint64_t>(!mispredicted);
    stats_.mispredictions += static_cast<std::uint64_t>(mispredicted);
    if (event.source_pc >= kIromBase &&
        event.source_pc < kIromBase + kIromBytes) {
        const auto word = static_cast<std::size_t>(
            (event.source_pc - kIromBase) >> 2u);
        ++stats_.branches_by_pc[word];
        stats_.misses_by_pc[word] += static_cast<std::uint64_t>(mispredicted);
    }

    const auto final_counter = update.final_source < 0
                                   ? std::int8_t{0}
                                   : update.tables[update.final_source].counter;
    const auto final_useful = update.final_source < 0
                                  ? std::uint8_t{0}
                                  : update.tables[update.final_source].useful;
    const DirectionPrediction prediction{
        true,
        update.base_prediction,
        update.final_prediction,
        config_.family == DirectionFamily::Tage && tagged_access,
        update.used_alternate,
        update.base_index,
        update.provider,
        update.final_source,
        final_counter,
        final_useful,
    };
    pending_.push_back(std::move(update));
    if (config_.update_delay_instructions == 0u) {
        apply_due(event.instruction_ordinal);
    } else if (automatic_barrier && mispredicted &&
               config_.mispredict_resolution_barrier) {
        force_resolve_through(next_order_ - 1u);
    }

    return prediction;
}

void DirectionPredictor::resolution_barrier() {
    if (next_order_ != 0u) {
        force_resolve_through(next_order_ - 1u);
    }
}

void DirectionPredictor::update_tage(const PendingUpdate& update) {
    if (update.provider < 0) {
        if (!config_.external_base_prediction) {
            base_table_[update.base_index] =
                update_base_counter(update.base_counter, update.event.taken);
        }
    } else {
        auto& entry = tagged_tables_[update.provider]
                                    [update.tables[update.provider].index];
        if (!entry.valid || entry.tag != update.tables[update.provider].tag) {
            ++stats_.stale_provider_updates;
        } else {
            entry.counter = update_tagged_counter(
                update.tables[update.provider].counter, update.event.taken);
            if (update.provider_prediction != update.alternate_prediction) {
                if (update.provider_prediction == update.event.taken) {
                    entry.useful = static_cast<std::uint8_t>(
                        std::min<unsigned>(1u, entry.useful + 1u));
                } else if (entry.useful != 0u) {
                    --entry.useful;
                }
            }
        }

        if (update.used_alternate) {
            if (update.alternate < 0) {
                if (!config_.external_base_prediction) {
                    base_table_[update.base_index] = update_base_counter(
                        update.base_counter, update.event.taken);
                }
            } else {
                auto& alternate = tagged_tables_[update.alternate]
                                                [update.tables[update.alternate].index];
                if (alternate.valid &&
                    alternate.tag == update.tables[update.alternate].tag) {
                    alternate.counter = update_tagged_counter(
                        update.tables[update.alternate].counter,
                        update.event.taken);
                }
            }
        }
    }

    if (update.final_prediction == update.event.taken) {
        return;
    }

    const auto first_longer = static_cast<std::size_t>(update.provider + 1);
    bool allocated = false;
    for (std::size_t table = first_longer; table < update.tables.size(); ++table) {
        auto& entry = tagged_tables_[table][update.tables[table].index];
        if (!entry.valid || entry.useful == 0u) {
            entry.valid = true;
            entry.tag = update.tables[table].tag;
            entry.counter = update.event.taken ? 0 : -1;
            entry.useful = 0;
            ++stats_.allocations;
            ++stats_.allocations_by_bank[(update.event.source_pc >> 2u) & 1u];
            allocated = true;
            break;
        }
    }
    if (!allocated && first_longer < update.tables.size()) {
        ++stats_.allocation_failures;
        ++stats_.allocation_failures_by_bank[
            (update.event.source_pc >> 2u) & 1u];
        for (std::size_t table = first_longer; table < update.tables.size(); ++table) {
            auto& entry = tagged_tables_[table][update.tables[table].index];
            if (entry.useful != 0u) {
                --entry.useful;
            }
        }
    }
}

void DirectionPredictor::apply_front() {
    if (pending_.empty()) {
        return;
    }
    const auto update = std::move(pending_.front());
    pending_.pop_front();

    if (config_.family == DirectionFamily::Tage) {
        update_tage(update);
    } else {
        base_table_[update.base_index] =
            update_base_counter(update.base_counter, update.event.taken);
    }
    ghr_ = ((ghr_ << 1u) | static_cast<std::uint64_t>(update.event.taken)) &
           bit_mask(maximum_history_length());
}

void DirectionPredictor::apply_due(const std::uint64_t instruction_ordinal) {
    while (!pending_.empty() &&
           pending_.front().due_instruction <= instruction_ordinal) {
        apply_front();
    }
}

void DirectionPredictor::force_resolve_through(const std::uint64_t order) {
    while (!pending_.empty() && pending_.front().order <= order) {
        apply_front();
    }
}

std::uint32_t DirectionPredictor::maximum_history_length() const {
    std::uint32_t result = config_.history_length;
    for (const auto& table : config_.tagged_tables) {
        result = std::max(result, table.history_length);
    }
    return result;
}

std::uint64_t DirectionPredictor::logical_storage_bits() const {
    std::uint64_t result = config_.external_base_prediction
                               ? 0u
                               : 2ull * config_.base_entries;
    for (const auto& table : config_.tagged_tables) {
        result += static_cast<std::uint64_t>(table.entries) *
                  (table.tag_bits + 3u + 1u + 1u);
    }
    return result + maximum_history_length();
}

std::uint64_t DirectionPredictor::two_read_storage_bits() const {
    std::uint64_t result = config_.external_base_prediction
                               ? 0u
                               : 2ull * config_.base_entries *
                                     (base_is_pc2_banked() ? 1u : 2u);
    for (const auto& table : config_.tagged_tables) {
        const auto table_bits = static_cast<std::uint64_t>(table.entries) *
                                (table.tag_bits + 3u + 1u + 1u);
        result += table_bits * (config_.tagged_pc2_banked ? 1u : 2u);
    }
    return result + maximum_history_length();
}

std::vector<DirectionConfig> make_direction_study_configs(
    const std::vector<std::uint32_t>& delays,
    const bool mispredict_resolution_barrier) {
    std::vector<DirectionConfig> configs;
    const auto add = [&](std::string name, const DirectionFamily family,
                         const std::uint32_t entries,
                         const std::uint32_t history,
                         std::vector<TageTableConfig> tagged,
                         const std::uint32_t delay,
                         const BaseIndexMode base_index_mode =
                             BaseIndexMode::LowPc,
                         const bool tagged_pc2_banked = false) {
        DirectionConfig config;
        config.name = std::move(name);
        config.family = family;
        config.base_entries = entries;
        config.history_length = history;
        config.base_index_mode = base_index_mode;
        config.tagged_pc2_banked = tagged_pc2_banked;
        config.tagged_tables = std::move(tagged);
        config.update_delay_instructions = delay;
        config.mispredict_resolution_barrier = mispredict_resolution_barrier;
        configs.push_back(std::move(config));
    };

    for (const auto delay : delays) {
        add("BIMODAL_256", DirectionFamily::Bimodal, 256, 0, {}, delay);
        add("BIMODAL_128_LOW", DirectionFamily::Bimodal, 128, 0, {}, delay);
        add("BIMODAL_512_LOW", DirectionFamily::Bimodal, 512, 0, {}, delay);
        add("BIMODAL_128_FOLD", DirectionFamily::Bimodal, 128, 0, {}, delay,
            BaseIndexMode::FoldedPc);
        add("BIMODAL_256_FOLD", DirectionFamily::Bimodal, 256, 0, {}, delay,
            BaseIndexMode::FoldedPc);
        add("BIMODAL_512_FOLD", DirectionFamily::Bimodal, 512, 0, {}, delay,
            BaseIndexMode::FoldedPc);
        add("BIMODAL_256_PC2BANK_LOW", DirectionFamily::Bimodal, 256, 0, {},
            delay, BaseIndexMode::Pc2BankedLowPc);
        add("BIMODAL_256_PC2BANK_FOLD", DirectionFamily::Bimodal, 256, 0, {},
            delay, BaseIndexMode::Pc2BankedFoldedPc);
        add("BIMODAL_128_PC2BANK_FOLD", DirectionFamily::Bimodal, 128, 0, {},
            delay, BaseIndexMode::Pc2BankedFoldedPc);
        add("BIMODAL_128_PC2BANK_LOW", DirectionFamily::Bimodal, 128, 0, {},
            delay, BaseIndexMode::Pc2BankedLowPc);
        for (const auto history : {4u, 6u, 8u, 10u, 12u}) {
            add("GSHARE_256_H" + std::to_string(history),
                DirectionFamily::Gshare, 256, history, {}, delay);
        }
        for (const auto history : {2u, 4u, 6u}) {
            add("GSELECT_256_PC" + std::to_string(8u - history) + "_H" +
                    std::to_string(history),
                DirectionFamily::Gselect, 256, history, {}, delay);
        }
        for (const auto history : {8u, 12u}) {
            add("GSHARE_512_H" + std::to_string(history),
                DirectionFamily::Gshare, 512, history, {}, delay);
        }
        for (const auto history : {8u, 12u, 16u}) {
            add("GSHARE_1024_H" + std::to_string(history),
                DirectionFamily::Gshare, 1024, history, {}, delay);
        }
        for (const auto history : {12u, 24u}) {
            add("GSHARE_2048_H" + std::to_string(history),
                DirectionFamily::Gshare, 2048, history, {}, delay);
        }
        add("TAGE2_B256_T64_H4_12", DirectionFamily::Tage, 256, 0,
            {{64, 4, 6}, {64, 12, 7}}, delay);
        add("TAGE2_B256_T64_H2_8", DirectionFamily::Tage, 256, 0,
            {{64, 2, 6}, {64, 8, 7}}, delay);
        add("TAGE2_B256_T64_H1_2", DirectionFamily::Tage, 256, 0,
            {{64, 1, 6}, {64, 2, 7}}, delay);
        add("TAGE2_B256_T64_H2_4", DirectionFamily::Tage, 256, 0,
            {{64, 2, 6}, {64, 4, 7}}, delay);
        add("TAGE2_B256_T64_H3_6", DirectionFamily::Tage, 256, 0,
            {{64, 3, 6}, {64, 6, 7}}, delay);
        add("TAGE2_B256_T64_H4_8", DirectionFamily::Tage, 256, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay);
        add("TAGE2_B128_T64_H4_8_BASE_LOW", DirectionFamily::Tage, 128, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay);
        add("TAGE2_B512_T64_H4_8_BASE_LOW", DirectionFamily::Tage, 512, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay);
        add("TAGE2_B128_T64_H4_8_BASE_FOLD", DirectionFamily::Tage, 128, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay, BaseIndexMode::FoldedPc);
        add("TAGE2_B256_T64_H4_8_BASE_FOLD", DirectionFamily::Tage, 256, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay, BaseIndexMode::FoldedPc);
        add("TAGE2_B512_T64_H4_8_BASE_FOLD", DirectionFamily::Tage, 512, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay, BaseIndexMode::FoldedPc);
        add("TAGE2_B256_T64_H4_8_BASE_PC2BANK_LOW", DirectionFamily::Tage,
            256, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedLowPc);
        add("TAGE2_B256_T64_H4_8_BASE_PC2BANK_FOLD", DirectionFamily::Tage,
            256, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedFoldedPc);
        add("TAGE2_B128_T64_H4_8_BASE_PC2BANK_FOLD", DirectionFamily::Tage,
            128, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedFoldedPc);
        add("TAGE2_B128_T64_H4_8_BASE_PC2BANK_LOW", DirectionFamily::Tage,
            128, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedLowPc);
        add("TAGE2_B256_T64_H4_8_TAG_PC2BANK", DirectionFamily::Tage, 256, 0,
            {{64, 4, 6}, {64, 8, 7}}, delay, BaseIndexMode::LowPc, true);
        add("TAGE2_B256_T64_H4_8_ALL_PC2BANK_FOLD", DirectionFamily::Tage,
            256, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedFoldedPc, true);
        add("TAGE2_B128_T64_H4_8_ALL_PC2BANK_FOLD", DirectionFamily::Tage,
            128, 0, {{64, 4, 6}, {64, 8, 7}}, delay,
            BaseIndexMode::Pc2BankedFoldedPc, true);
        add("TAGE2_B256_T64_H4_16", DirectionFamily::Tage, 256, 0,
            {{64, 4, 6}, {64, 16, 7}}, delay);
        add("TAGE2_B512_T32_H4_12", DirectionFamily::Tage, 512, 0,
            {{32, 4, 6}, {32, 12, 7}}, delay);
        add("TAGE3_B256_T64_H3_8_24", DirectionFamily::Tage, 256, 0,
            {{64, 3, 6}, {64, 8, 7}, {64, 24, 8}}, delay);
        add("TAGE3_B256_T64_H2_6_12", DirectionFamily::Tage, 256, 0,
            {{64, 2, 6}, {64, 6, 7}, {64, 12, 8}}, delay);
        add("TAGE3_B256_T64_H2_8_16", DirectionFamily::Tage, 256, 0,
            {{64, 2, 6}, {64, 8, 7}, {64, 16, 8}}, delay);
        add("TAGE3_B512_T32_H3_8_24", DirectionFamily::Tage, 512, 0,
            {{32, 3, 6}, {32, 8, 7}, {32, 24, 8}}, delay);
    }
    return configs;
}

}  // namespace archsim
