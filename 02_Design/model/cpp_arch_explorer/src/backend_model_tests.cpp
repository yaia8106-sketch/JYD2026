#include "backend_model.hpp"

#include <cassert>
#include <cstdint>
#include <iostream>

namespace {

archsim::CfiEvent make_event(const std::uint64_t ordinal,
                             const std::uint32_t instruction) {
    archsim::CfiEvent event;
    event.instruction_ordinal = ordinal;
    event.source_pc = archsim::kIromBase +
                      static_cast<std::uint32_t>((ordinal - 1u) * 4u);
    event.instruction = instruction;
    event.next_pc = event.source_pc + 4u;
    return event;
}

std::uint32_t encode_lui(const std::uint32_t rd, const std::uint32_t upper) {
    return (upper << 12u) | (rd << 7u) | 0x37u;
}

std::uint32_t encode_r(const std::uint32_t funct7, const std::uint32_t rs2,
                       const std::uint32_t rs1, const std::uint32_t funct3,
                       const std::uint32_t rd) {
    return (funct7 << 25u) | (rs2 << 20u) | (rs1 << 15u) |
           (funct3 << 12u) | (rd << 7u) | 0x33u;
}

std::uint32_t encode_load(const std::uint32_t rd,
                          const std::uint32_t rs1 = 0u) {
    return (rs1 << 15u) | (2u << 12u) | (rd << 7u) | 0x03u;
}

std::uint32_t encode_store(const std::uint32_t rs2 = 0u,
                           const std::uint32_t rs1 = 0u) {
    return (rs2 << 20u) | (rs1 << 15u) | (2u << 12u) | 0x23u;
}

std::uint32_t encode_branch() {
    return 0x63u;  // BEQ x0, x0, 0; the functional event supplies the outcome.
}

archsim::CfiEvent make_memory_event(const std::uint64_t ordinal,
                                    const std::uint32_t instruction,
                                    const std::uint32_t address,
                                    const archsim::MemoryAccessKind kind) {
    auto event = make_event(ordinal, instruction);
    event.memory_kind = kind;
    event.memory_address = address;
    return event;
}

void test_decode() {
    const auto add = archsim::decode_backend_instruction(
        encode_r(0u, 2u, 1u, 0u, 3u));
    assert(add.queue == archsim::BackendQueueKind::Int);
    assert(add.uses_rs1 && add.uses_rs2 && add.writes_rd);

    const auto mul = archsim::decode_backend_instruction(
        encode_r(1u, 2u, 1u, 0u, 3u));
    assert(mul.queue == archsim::BackendQueueKind::Mdu);
    assert(mul.is_mul && !mul.is_div);

    const auto div = archsim::decode_backend_instruction(
        encode_r(1u, 2u, 1u, 4u, 3u));
    assert(div.queue == archsim::BackendQueueKind::Mdu);
    assert(div.is_div && !div.is_mul);

    const auto load = archsim::decode_backend_instruction(
        (1u << 15u) | (2u << 12u) | (3u << 7u) | 0x03u);
    assert(load.queue == archsim::BackendQueueKind::Ls);
    assert(load.is_load && load.uses_rs1 && load.writes_rd);
}

archsim::BackendConfig test_config() {
    archsim::BackendConfig config;
    config.int_iq_depth = 8;
    config.ls_iq_depth = 4;
    config.mdu_iq_depth = 2;
    config.frontend_buffer_entries = 8;
    config.branch_mode = archsim::BackendBranchMode::Perfect;
    config.redirect_penalty = 0;
    return config;
}

void test_dual_issue_and_drain() {
    archsim::BackendModel model(test_config());
    for (std::uint64_t ordinal = 1; ordinal <= 32u; ++ordinal) {
        const auto rd = 1u + static_cast<std::uint32_t>((ordinal - 1u) % 31u);
        model.feed(make_event(ordinal, encode_lui(rd, rd)));
    }
    model.finish();
    const auto& stats = model.stats();
    assert(stats.drained);
    assert(stats.trace_instructions == 32u);
    assert(stats.dispatched_instructions == 32u);
    assert(stats.issued_instructions == 32u);
    assert(stats.retired_instructions == 32u);
    assert(stats.issue_two_cycles != 0u);
}

void test_prf_read_bank_conflict() {
    auto config = test_config();
    archsim::BackendModel model(config);
    // Both ADDs read two even physical registers, so each consumes both bank0
    // read ports and they cannot receive the two global issue grants together.
    model.feed(make_event(1u, encode_r(0u, 4u, 2u, 0u, 1u)));
    model.feed(make_event(2u, encode_r(0u, 8u, 6u, 0u, 3u)));
    model.finish();
    assert(model.stats().retired_instructions == 2u);
    assert(model.stats().prf_read_bank_conflict_cycles != 0u);
}

void test_mdu_queue_pressure() {
    auto config = test_config();
    config.mdu_iq_depth = 2;
    config.mul_latency = 3;
    archsim::BackendModel model(config);
    for (std::uint64_t ordinal = 1; ordinal <= 12u; ++ordinal) {
        const auto rd = 1u + static_cast<std::uint32_t>((ordinal - 1u) % 12u);
        model.feed(make_event(ordinal,
                              encode_r(1u, 4u, 2u, 0u, rd)));
    }
    model.finish();
    assert(model.stats().retired_instructions == 12u);
    assert(model.stats().mdu_iq.rename_stall_cycles != 0u);
}

void test_repeated_waw_recycles_physical_registers() {
    archsim::BackendModel model(test_config());
    for (std::uint64_t ordinal = 1; ordinal <= 256u; ++ordinal) {
        model.feed(make_event(ordinal, encode_lui(1u, 1u)));
    }
    model.finish();
    assert(model.stats().drained);
    assert(model.stats().retired_instructions == 256u);
}

void test_lsu_hit_pipeline_accepts_overlapping_loads() {
    auto config = test_config();
    config.ls_iq_depth = 16;
    archsim::BackendModel model(config);
    for (std::uint64_t ordinal = 1; ordinal <= 24u; ++ordinal) {
        const auto rd = 1u + static_cast<std::uint32_t>((ordinal - 1u) % 24u);
        model.feed(make_memory_event(
            ordinal, encode_load(rd), 0x8020'0000u,
            archsim::MemoryAccessKind::Load));
    }
    model.finish();
    const auto& stats = model.stats();
    assert(stats.retired_instructions == 24u);
    assert(stats.load_hits == 24u);
    assert(stats.load_misses == 0u);
    assert(stats.lsu_max_inflight >= 2u);
}

void test_store_buffer_backpressure() {
    auto config = test_config();
    config.ls_iq_depth = 8;
    config.store_buffer_entries = 2;
    config.store_drain_latency = 4;
    archsim::BackendModel model(config);
    for (std::uint64_t ordinal = 1; ordinal <= 24u; ++ordinal) {
        model.feed(make_memory_event(
            ordinal, encode_store(),
            0x8010'0000u + static_cast<std::uint32_t>(ordinal * 4u),
            archsim::MemoryAccessKind::Store));
    }
    model.finish();
    const auto& stats = model.stats();
    assert(stats.retired_instructions == 24u);
    assert(stats.store_buffer_max_occupancy == 2u);
    assert(stats.store_buffer_full_cycles != 0u);
}

void test_gshare_outcomes_do_not_depend_on_iq_depth() {
    auto shallow_config = test_config();
    shallow_config.int_iq_depth = 4;
    shallow_config.branch_mode = archsim::BackendBranchMode::Gshare;
    auto deep_config = shallow_config;
    deep_config.int_iq_depth = 12;
    archsim::BackendModel shallow(shallow_config);
    archsim::BackendModel deep(deep_config);
    for (std::uint64_t ordinal = 1; ordinal <= 256u; ++ordinal) {
        auto event = make_event(ordinal, ordinal % 3u == 0u
                                             ? encode_branch()
                                             : encode_lui(1u, 1u));
        if (ordinal % 3u == 0u) {
            event.kind = archsim::CfiKind::Branch;
            event.taken = (ordinal / 3u) % 4u != 0u;
        }
        shallow.feed(event);
        deep.feed(event);
    }
    shallow.finish();
    deep.finish();
    assert(shallow.stats().branch_mispredictions ==
           deep.stats().branch_mispredictions);
}

}  // namespace

int main() {
    test_decode();
    test_dual_issue_and_drain();
    test_prf_read_bank_conflict();
    test_mdu_queue_pressure();
    test_repeated_waw_recycles_physical_registers();
    test_lsu_hit_pipeline_accepts_overlapping_loads();
    test_store_buffer_backpressure();
    test_gshare_outcomes_do_not_depend_on_iq_depth();
    std::cout << "backend_model_tests: PASS\n";
    return 0;
}
