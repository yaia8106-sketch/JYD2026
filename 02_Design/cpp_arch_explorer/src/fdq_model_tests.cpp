#include "fdq_model.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

archsim::CfiEvent instruction(const std::uint64_t ordinal,
                              const std::uint32_t pc,
                              const std::uint32_t bits = 0x0000'0013u) {
    return {archsim::CfiKind::None, ordinal, pc, bits, 0, pc + 4u, false};
}

void test_fdq_counts_and_correction_observation() {
    archsim::FdqStudyModel model({
        {"TEST", 8, 2, 6, archsim::FdqConsumePolicy::RtlPairing},
    });
    auto first = instruction(1, archsim::kIromBase);
    archsim::FrontendDecision correction;
    correction.valid = true;
    correction.stage1_next = first.source_pc + 4u;
    correction.f0_next = first.source_pc + 4u;
    correction.f1_next = first.source_pc + 8u;
    correction.f1_correction = true;
    correction.backend_direction_wrong = false;
    model.observe(first, correction);
    model.observe(instruction(2, archsim::kIromBase + 8u), {});
    model.finish();
    const auto& stats = model.scenarios().front().stats();
    assert(stats.instructions_consumed == 2u);
    assert(stats.f1_corrections == 1u);
    assert(stats.correction_observations == 1u);
    assert(stats.estimated_f1_wrong_path_blocks == 1u);
}

void test_exact_rtl_pairing_raw_dependency() {
    archsim::FdqStudyModel model({
        {"TEST", 8, 1, 6, archsim::FdqConsumePolicy::RtlPairing},
    });
    // addi x1,x0,1 followed by addi x2,x1,1 cannot dual issue.
    model.observe(instruction(1, archsim::kIromBase, 0x0010'0093u), {});
    model.observe(instruction(2, archsim::kIromBase + 4u, 0x0010'8113u), {});
    model.finish();
    const auto& stats = model.scenarios().front().stats();
    assert(stats.instructions_consumed == 2u);
    assert(stats.single_issue_cycles == 2u);
    assert(stats.dual_issue_cycles == 0u);
}

void test_consumer_stall_rate_is_not_integer_period_quantized() {
    for (const auto burst : {1u, 8u}) {
        archsim::FdqScenarioConfig config{
            "STALL_RATE", 16, 1, 6,
            archsim::FdqConsumePolicy::DualAlways,
            archsim::FdqBackendPolicy::BranchDirectionOnly,
            305'039u, burst};
        archsim::FdqScenarioModel model(config);
        const std::array<archsim::FdqInstruction, 2> packet{};
        for (std::uint32_t index = 0; index < 200'000u; ++index) {
            model.submit(packet, 1u, {});
        }
        model.finish();
        const auto& stats = model.stats();
        const auto measured =
            (stats.consumer_stall_cycles * 1'000'000u) / stats.cycles;
        const auto error = measured > config.consumer_stall_ppm
                               ? measured - config.consumer_stall_ppm
                               : config.consumer_stall_ppm - measured;
        assert(error < 1'000u);
    }
}

}  // namespace

int main() {
    test_fdq_counts_and_correction_observation();
    test_exact_rtl_pairing_raw_dependency();
    test_consumer_stall_rate_is_not_integer_period_quantized();
    std::cout << "FDQ model tests passed\n";
}
