#include "direction_predictor.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <utility>
#include <vector>

namespace {

archsim::CfiEvent branch(const std::uint64_t ordinal, const bool taken,
                         const std::uint32_t pc = archsim::kIromBase) {
    return archsim::CfiEvent{archsim::CfiKind::Branch, ordinal, pc,
                            0x0000'0063u,
                            taken ? pc + 16u : pc + 4u, pc + 4u, taken};
}

archsim::DirectionConfig bimodal(const std::uint32_t delay = 0,
                                 const bool barrier = true) {
    archsim::DirectionConfig config;
    config.name = "TEST_BIMODAL";
    config.family = archsim::DirectionFamily::Bimodal;
    config.base_entries = 16;
    config.history_length = 0;
    config.update_delay_instructions = delay;
    config.mispredict_resolution_barrier = barrier;
    return config;
}

void test_two_bit_counter() {
    archsim::DirectionPredictor always_taken(bimodal());
    for (std::uint64_t ordinal = 0; ordinal < 20; ++ordinal) {
        always_taken.observe(branch(ordinal, true));
    }
    assert(always_taken.stats().branches == 20);
    assert(always_taken.stats().mispredictions == 1);

    archsim::DirectionPredictor alternating(bimodal());
    for (std::uint64_t ordinal = 0; ordinal < 20; ++ordinal) {
        alternating.observe(branch(ordinal, (ordinal & 1u) == 0u));
    }
    assert(alternating.stats().mispredictions == 20);
}

void test_fixed_update_delay() {
    archsim::DirectionPredictor immediate(bimodal(0, false));
    archsim::DirectionPredictor delayed(bimodal(6, false));
    for (std::uint64_t ordinal = 0; ordinal < 12; ++ordinal) {
        const auto event = branch(ordinal, true);
        immediate.observe(event);
        delayed.observe(event);
    }
    assert(immediate.stats().mispredictions == 1);
    assert(delayed.stats().mispredictions > immediate.stats().mispredictions);
}

void test_tage_allocation_and_provider() {
    archsim::DirectionConfig config;
    config.name = "TEST_TAGE";
    config.family = archsim::DirectionFamily::Tage;
    config.base_entries = 16;
    config.history_length = 0;
    config.tagged_tables = {{4, 1, 4}, {4, 3, 4}};
    archsim::DirectionPredictor predictor(config);
    for (std::uint64_t ordinal = 0; ordinal < 200; ++ordinal) {
        predictor.observe(branch(ordinal, (ordinal & 1u) == 0u));
    }
    assert(predictor.stats().allocations != 0);
    assert(predictor.stats().tagged_provider[0] != 0 ||
           predictor.stats().tagged_provider[1] != 0);
}

void test_storage_accounting() {
    archsim::DirectionConfig config;
    config.name = "TEST_STORAGE";
    config.family = archsim::DirectionFamily::Tage;
    config.base_entries = 256;
    config.tagged_tables = {{64, 4, 6}, {64, 12, 7}};
    archsim::DirectionPredictor predictor(config);
    // Base: 512; tagged: 64*(tag + 3-bit ctr + 1 useful + valid); GHR: 12.
    assert(predictor.logical_storage_bits() == 1996);
    assert(predictor.two_read_storage_bits() == 3980);
}

void test_tagged_tables_respect_declared_history_length() {
    archsim::DirectionConfig short_history;
    short_history.name = "TEST_H2_8";
    short_history.family = archsim::DirectionFamily::Tage;
    short_history.base_entries = 16;
    short_history.tagged_tables = {{8, 2, 4}, {8, 8, 4}};
    auto longer_history = short_history;
    longer_history.name = "TEST_H4_8";
    longer_history.tagged_tables[0].history_length = 4;
    archsim::DirectionPredictor short_predictor(short_history);
    archsim::DirectionPredictor longer_predictor(longer_history);

    std::uint32_t state = 0x5au;
    for (std::uint64_t ordinal = 0; ordinal < 2000; ++ordinal) {
        state = ((state << 1u) | (((state >> 7u) ^ (state >> 5u) ^
                                  (state >> 4u) ^ (state >> 3u)) & 1u)) &
                0xffu;
        const auto event = branch(ordinal, (state & 1u) != 0u,
                                  archsim::kIromBase +
                                      static_cast<std::uint32_t>((ordinal & 3u) * 4u));
        short_predictor.observe(event);
        longer_predictor.observe(event);
    }
    assert(short_predictor.stats().mispredictions !=
               longer_predictor.stats().mispredictions ||
           short_predictor.stats().tagged_provider !=
               longer_predictor.stats().tagged_provider);
}

void test_pc2_banked_low_base_is_prediction_equivalent() {
    auto shared = bimodal();
    shared.name = "SHARED_LOW";
    shared.base_entries = 256;
    auto banked = shared;
    banked.name = "BANKED_LOW";
    banked.base_index_mode = archsim::BaseIndexMode::Pc2BankedLowPc;
    archsim::DirectionPredictor shared_predictor(shared);
    archsim::DirectionPredictor banked_predictor(banked);
    std::uint32_t state = 0x35u;
    for (std::uint64_t ordinal = 0; ordinal < 2000; ++ordinal) {
        state = state * 33u + 17u;
        const auto pc = archsim::kIromBase +
                        static_cast<std::uint32_t>(((state >> 8u) & 0x3ffu) * 4u);
        const auto event = branch(ordinal, ((state >> 3u) & 1u) != 0u, pc);
        shared_predictor.observe(event);
        banked_predictor.observe(event);
    }
    assert(shared_predictor.stats().mispredictions ==
           banked_predictor.stats().mispredictions);
    assert(shared_predictor.stats().base_alias_switches ==
           banked_predictor.stats().base_alias_switches);
    assert(banked_predictor.two_read_storage_bits() == 512);
}

void test_folded_pc_separates_low_pc_alias() {
    auto low = bimodal();
    low.name = "LOW";
    low.base_entries = 128;
    auto folded = low;
    folded.name = "FOLDED";
    folded.base_index_mode = archsim::BaseIndexMode::FoldedPc;
    archsim::DirectionPredictor low_predictor(low);
    archsim::DirectionPredictor folded_predictor(folded);
    const auto pc0 = archsim::kIromBase + 0x40u;
    const auto pc1 = pc0 + 128u * 4u;
    for (std::uint64_t ordinal = 0; ordinal < 100; ++ordinal) {
        const bool use_second = (ordinal & 1u) != 0u;
        const auto event = branch(ordinal, use_second,
                                  use_second ? pc1 : pc0);
        low_predictor.observe(event);
        folded_predictor.observe(event);
    }
    assert(low_predictor.stats().base_alias_switches != 0);
    assert(folded_predictor.stats().base_alias_switches == 0);
    assert(folded_predictor.stats().mispredictions <
           low_predictor.stats().mispredictions);
}

void test_fully_banked_tage_avoids_table_replication_cost() {
    archsim::DirectionConfig config;
    config.name = "BANKED_TAGE";
    config.family = archsim::DirectionFamily::Tage;
    config.base_entries = 256;
    config.base_index_mode = archsim::BaseIndexMode::Pc2BankedFoldedPc;
    config.tagged_pc2_banked = true;
    config.tagged_tables = {{64, 4, 6}, {64, 8, 7}};
    archsim::DirectionPredictor predictor(config);
    assert(predictor.logical_storage_bits() == 1992);
    assert(predictor.two_read_storage_bits() == 1992);
}

void test_gselect_concatenates_pc_and_history() {
    archsim::DirectionConfig config;
    config.name = "TEST_GSELECT";
    config.family = archsim::DirectionFamily::Gselect;
    config.base_entries = 256;
    config.history_length = 4;
    archsim::DirectionPredictor predictor(config);
    const auto pc = archsim::kIromBase + 0x3cu;
    const auto first = predictor.observe(branch(1, true, pc));
    const auto second = predictor.observe(branch(2, false, pc));
    assert(first.base_index == 0xf0u);
    assert(second.base_index == 0xf1u);
}

void test_base_only_tage_access_does_not_allocate_tagged_entries() {
    archsim::DirectionConfig config;
    config.name = "TEST_TAGE_BASE_ONLY";
    config.family = archsim::DirectionFamily::Tage;
    config.base_entries = 16;
    config.tagged_tables = {{4, 1, 4}, {4, 3, 4}};
    archsim::DirectionPredictor predictor(config);
    for (std::uint64_t ordinal = 0; ordinal < 200; ++ordinal) {
        const auto prediction = predictor.observe(
            branch(ordinal, (ordinal & 1u) == 0u), false);
        assert(!prediction.tagged_accessed);
        assert(prediction.final_source == -1);
    }
    assert(predictor.stats().branches == 200u);
    assert(predictor.stats().allocations == 0u);
    assert(predictor.stats().tagged_provider[0] == 0u);
    assert(predictor.stats().tagged_provider[1] == 0u);
}

void test_tagged_only_preserves_external_base_on_miss() {
    archsim::DirectionConfig config;
    config.name = "TEST_TAGGED_ONLY";
    config.family = archsim::DirectionFamily::Tage;
    config.base_entries = 16;
    config.history_length = 0;
    config.tagged_tables = {{4, 0, 4}, {4, 0, 5}};
    config.external_base_prediction = true;
    config.use_alternate_on_weak_new = false;
    archsim::DirectionPredictor predictor(config);

    const auto miss = predictor.observe(branch(1, true), true, true, false);
    assert(miss.provider == -1);
    assert(miss.final_source == -1);
    assert(!miss.final_taken);
    assert(predictor.stats().allocations == 1u);

    const auto provider = predictor.observe(branch(2, true), true, true, false);
    assert(provider.provider >= 0);
    assert(provider.final_source >= 0);
    assert(provider.final_taken);

    const auto other_pc = predictor.observe(
        branch(3, true, archsim::kIromBase + 4u), true, true, true);
    assert(other_pc.provider == -1);
    assert(other_pc.final_source == -1);
    assert(other_pc.final_taken);

    // 4/5-bit tags + signed counter/useful/valid.  There is
    // deliberately no 16-entry bimodal table in the physical accounting.
    assert(predictor.logical_storage_bits() == 76u);
}

}  // namespace

int main() {
    test_two_bit_counter();
    test_fixed_update_delay();
    test_tage_allocation_and_provider();
    test_storage_accounting();
    test_tagged_tables_respect_declared_history_length();
    test_pc2_banked_low_base_is_prediction_equivalent();
    test_folded_pc_separates_low_pc_alias();
    test_fully_banked_tage_avoids_table_replication_cost();
    test_gselect_concatenates_pc_and_history();
    test_base_only_tage_access_does_not_allocate_tagged_entries();
    test_tagged_only_preserves_external_base_on_miss();
    std::cout << "direction predictor tests passed\n";
}
