#include "frontend_model.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

constexpr std::uint32_t kBeqPlus8 = 0x0000'0463u;
constexpr std::uint32_t kJalX0Plus8 = 0x0080'006fu;
constexpr std::uint32_t kJalX1Plus8 = 0x0080'00efu;
constexpr std::uint32_t kRet = 0x0000'8067u;

archsim::CfiEvent event(const archsim::CfiKind kind,
                        const std::uint64_t ordinal,
                        const std::uint32_t pc,
                        const std::uint32_t instruction,
                        const std::uint32_t target,
                        const bool taken = true) {
    return archsim::CfiEvent{
        kind,
        ordinal,
        pc,
        instruction,
        target,
        taken ? target : pc + 4u,
        taken,
    };
}

void test_decode_cfi() {
    const auto branch = archsim::decode_cfi(kBeqPlus8, archsim::kIromBase);
    assert(branch.type == archsim::CfiClass::Branch);
    assert(branch.direct_target_valid);
    assert(branch.direct_target == archsim::kIromBase + 8u);

    const auto call = archsim::decode_cfi(kJalX1Plus8, archsim::kIromBase);
    assert(call.type == archsim::CfiClass::Call);
    assert(call.direct_target == archsim::kIromBase + 8u);
    assert(call.return_address == archsim::kIromBase + 4u);

    const auto ret = archsim::decode_cfi(kRet, archsim::kIromBase + 8u);
    assert(ret.type == archsim::CfiClass::Ret);
    assert(!ret.direct_target_valid);
}

void test_dual_cfi_block_profile() {
    archsim::ProgramImage image;
    image.irom = {kBeqPlus8, kJalX0Plus8};
    archsim::TraceProfiler profiler(image);
    const auto first_event = event(archsim::CfiKind::Branch, 1,
                                   archsim::kIromBase, kBeqPlus8,
                                   archsim::kIromBase + 8u, false);
    const auto first = profiler.observe(first_event);
    assert(first.new_block);
    assert(first.eligible_cfis == 2u);
    assert(first.current_is_first_cfi);

    const auto second_event = event(archsim::CfiKind::Jal, 2,
                                    archsim::kIromBase + 4u, kJalX0Plus8,
                                    archsim::kIromBase + 12u);
    const auto second = profiler.observe(second_event);
    assert(!second.new_block);
    assert(second.current_is_second_cfi);
    assert(profiler.stats().blocks_by_cfi_count[2] == 1u);
    assert(profiler.stats().older_branch_nt_then_second_cfi == 1u);
}

void test_abtb_taken_allocation_and_not_taken_filter() {
    archsim::AbtbModel abtb(0);
    const auto branch_taken = event(archsim::CfiKind::Branch, 1,
                                    archsim::kIromBase, kBeqPlus8,
                                    archsim::kIromBase + 8u);
    const auto decoded = archsim::decode_cfi(branch_taken.instruction,
                                             branch_taken.source_pc);
    const auto miss = abtb.lookup(branch_taken.source_pc, 1);
    assert(!miss.hit);
    abtb.resolve(branch_taken, decoded, miss);
    const auto hit = abtb.lookup(branch_taken.source_pc, 2);
    assert(hit.hit);
    assert(hit.type == archsim::AbtbType::Branch);
    assert(hit.target == branch_taken.target);

    archsim::AbtbModel filtered(0);
    auto branch_nt = branch_taken;
    branch_nt.taken = false;
    branch_nt.next_pc = branch_nt.source_pc + 4u;
    const auto filtered_miss = filtered.lookup(branch_nt.source_pc, 1);
    filtered.resolve(branch_nt, decoded, filtered_miss);
    assert(!filtered.lookup(branch_nt.source_pc, 2).hit);
}

void test_pending_ras_covers_delayed_call() {
    const auto call = event(archsim::CfiKind::Jal, 1, archsim::kIromBase,
                            kJalX1Plus8, archsim::kIromBase + 8u);
    const auto ret = event(archsim::CfiKind::Jalr, 2,
                           archsim::kIromBase + 8u, kRet,
                           archsim::kIromBase + 4u);

    archsim::RasModel committed(
        {archsim::RasPolicy::Committed, 8, 0, 6});
    committed.observe(call, archsim::decode_cfi(call.instruction, call.source_pc));
    const auto committed_prediction = committed.observe(
        ret, archsim::decode_cfi(ret.instruction, ret.source_pc));
    assert(!committed_prediction.valid);

    archsim::RasModel pending(
        {archsim::RasPolicy::PendingOverlay, 8, 2, 6});
    pending.observe(call, archsim::decode_cfi(call.instruction, call.source_pc));
    const auto pending_prediction = pending.observe(
        ret, archsim::decode_cfi(ret.instruction, ret.source_pc));
    assert(pending_prediction.valid);
    assert(pending_prediction.target == archsim::kIromBase + 4u);
}

void test_f0_direct_repairs_cold_jal() {
    const auto configs = archsim::make_frontend_study_configs({6u});
    const auto find_config = [&](const std::string& name) {
        for (const auto& config : configs) {
            if (config.name == name) {
                return config;
            }
        }
        assert(false && "frontend test configuration not found");
        return configs.front();
    };
    const auto jal = event(archsim::CfiKind::Jal, 1, archsim::kIromBase,
                           kJalX0Plus8, archsim::kIromBase + 8u);
    archsim::BlockContext block;
    block.new_block = true;
    block.current_is_first_cfi = true;

    archsim::FrontendModel baseline(find_config("CURRENT_GSHARE"));
    baseline.observe(jal, block);
    assert(baseline.stats().stage1_wrong == 1u);
    assert(baseline.stats().f1_wrong == 1u);

    archsim::FrontendModel f0_direct(find_config("GSHARE_F0_DIRECT"));
    f0_direct.observe(jal, block);
    assert(f0_direct.stats().stage1_wrong == 1u);
    assert(f0_direct.stats().f0_corrections == 1u);
    assert(f0_direct.stats().f1_wrong == 0u);
}

void test_direction_barrier_policy_bounds_delayed_training() {
    const auto configs = archsim::make_frontend_study_configs({6u});
    const auto selected = [](const auto& all, const std::string& name) {
        for (const auto& config : all) {
            if (config.name == name) {
                return config;
            }
        }
        assert(false && "frontend test configuration not found");
        return all.front();
    };
    auto eager_config = selected(configs, "BIMODAL_TAGE2_OLDEST");
    auto natural_config = selected(configs,
        "BIMODAL_TAGE2_OLDEST_NO_BARRIER");
    archsim::FrontendModel eager(eager_config);
    archsim::FrontendModel natural(natural_config);
    archsim::BlockContext block;
    block.new_block = true;
    block.current_is_first_cfi = true;

    const auto first = event(archsim::CfiKind::Branch, 1,
                             archsim::kIromBase, kBeqPlus8,
                             archsim::kIromBase + 8u, true);
    const auto second = event(archsim::CfiKind::Branch, 2,
                              archsim::kIromBase, kBeqPlus8,
                              archsim::kIromBase + 8u, true);
    eager.observe(first, block);
    eager.observe(second, block);
    natural.observe(first, block);
    natural.observe(second, block);

    assert(eager.stats().f1_wrong == 1u);
    assert(natural.stats().f1_wrong == 2u);
}

void test_oldest_only_tagged_port_reopens_after_older_refetch() {
    const auto configs = archsim::make_frontend_study_configs({6u});
    const auto find_config = [&](const std::string& name) {
        for (const auto& config : configs) {
            if (config.name == name) {
                return config;
            }
        }
        assert(false && "frontend test configuration not found");
        return configs.front();
    };
    archsim::FrontendModel model(find_config("BIMODAL_TAGE2_OLDEST"));
    archsim::BlockContext first_block;
    first_block.new_block = true;
    first_block.current_is_first_cfi = true;
    archsim::BlockContext second_block = first_block;
    second_block.new_block = false;
    second_block.current_is_first_cfi = false;
    second_block.current_is_second_cfi = true;

    // Train the older branch taken.  Its subsequent not-taken outcome is then
    // predicted taken and forces a refetch at PC+4, where the younger branch
    // becomes the oldest visible branch and is allowed to use the tagged port.
    model.observe(event(archsim::CfiKind::Branch, 1, archsim::kIromBase,
                        kBeqPlus8, archsim::kIromBase + 8u, true),
                  first_block);
    model.observe(event(archsim::CfiKind::Branch, 2, archsim::kIromBase,
                        kBeqPlus8, archsim::kIromBase + 8u, false),
                  first_block);
    model.observe(event(archsim::CfiKind::Branch, 3,
                        archsim::kIromBase + 4u, kBeqPlus8,
                        archsim::kIromBase + 12u, false),
                  second_block);

    assert(model.stats().tagged_queries == 3u);
    assert(model.stats().tagged_suppressed_second_cfi == 0u);
}

void test_tagged_only_never_corrects_without_a_tagged_source() {
    const auto configs = archsim::make_frontend_study_configs({0u});
    auto selected = configs.front();
    for (const auto& config : configs) {
        if (config.name ==
            "BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_PROVIDER") {
            selected = config;
            break;
        }
    }
    archsim::FrontendModel model(selected);
    archsim::BlockContext block;
    block.new_block = true;
    block.current_is_first_cfi = true;
    for (std::uint64_t ordinal = 1; ordinal <= 100; ++ordinal) {
        model.observe(event(archsim::CfiKind::Branch, ordinal,
                            archsim::kIromBase, kBeqPlus8,
                            archsim::kIromBase + 8u,
                            (ordinal & 1u) != 0u),
                      block);
    }
    const auto& stats = model.stats();
    assert(stats.tagged_provider_hits + stats.tagged_no_provider ==
           stats.tagged_queries);
    assert(stats.f1_corrections_without_tagged_source == 0u);
    assert(stats.f1_corrections ==
           stats.f1_corrections_by_tagged_table[0] +
               stats.f1_corrections_by_tagged_table[1]);
}

}  // namespace

int main() {
    test_decode_cfi();
    test_dual_cfi_block_profile();
    test_abtb_taken_allocation_and_not_taken_filter();
    test_pending_ras_covers_delayed_call();
    test_f0_direct_repairs_cold_jal();
    test_direction_barrier_policy_bounds_delayed_training();
    test_oldest_only_tagged_port_reopens_after_older_refetch();
    test_tagged_only_never_corrects_without_a_tagged_source();
    std::cout << "frontend model tests passed\n";
}
