#include "forwarding_model.hpp"

#include <cassert>
#include <cstdint>
#include <initializer_list>
#include <iostream>
#include <random>

namespace {

using archsim::CfiEvent;
using archsim::ForwardedOperand;
using archsim::ForwardingInputs;
using archsim::ForwardingNetwork;
using archsim::ForwardingNetworkMask;
using archsim::ForwardingProducer;
using archsim::ForwardingSource;
using archsim::ForwardingStudyModel;
using archsim::RepairSource;

ForwardingProducer producer(const std::uint8_t rd,
                            const std::uint32_t value) {
    ForwardingProducer result;
    result.valid = true;
    result.reg_write = true;
    result.rd = rd;
    result.alu_result = value;
    result.fast_alu_result = value;
    result.mul_result = value;
    result.write_data = value;
    return result;
}

ForwardedOperand reference_forward(const ForwardingInputs& inputs,
                                   const std::uint8_t source,
                                   const std::uint32_t rf) {
    const auto hit = [source](const ForwardingProducer& candidate) {
        return candidate.valid && candidate.reg_write &&
               candidate.rd != 0u && candidate.rd == source;
    };
    const auto ex_value = [](const ForwardingProducer& candidate,
                             const bool slot0) {
        if (slot0 && candidate.fast_alu) {
            return candidate.fast_alu_result;
        }
        if (candidate.wb_sel == 2u) {
            return candidate.pc_plus_4;
        }
        return candidate.alu_result;
    };
    const auto mem_value = [](const ForwardingProducer& candidate) {
        if (candidate.wb_sel == 2u) {
            return candidate.pc_plus_4;
        }
        return candidate.is_mul
            ? candidate.mul_result
            : candidate.alu_result;
    };
    if (hit(inputs.ex_s1) && !inputs.ex_s1.result_repair) {
        return {ex_value(inputs.ex_s1, false),
                ForwardingSource::S1Ex, RepairSource::None};
    }
    if (hit(inputs.ex_s0) && !inputs.ex_s0.result_repair) {
        return {ex_value(inputs.ex_s0, true),
                ForwardingSource::S0Ex, RepairSource::None};
    }
    if (hit(inputs.mem_s1) && !inputs.mem_s1.is_load) {
        return {mem_value(inputs.mem_s1),
                ForwardingSource::S1Mem, RepairSource::None};
    }
    if (hit(inputs.mem_s0) && !inputs.mem_s0.is_load) {
        return {mem_value(inputs.mem_s0),
                ForwardingSource::S0Mem, RepairSource::None};
    }
    if (hit(inputs.wb_s1)) {
        return {inputs.wb_s1.write_data,
                ForwardingSource::S1Wb, RepairSource::None};
    }
    if (hit(inputs.wb_s0)) {
        return {inputs.wb_s0.write_data,
                ForwardingSource::S0Wb, RepairSource::None};
    }
    return {rf, ForwardingSource::RegisterFile, RepairSource::None};
}

void check_operand(const ForwardedOperand& actual,
                   const ForwardedOperand& expected) {
    assert(actual.data == expected.data);
    assert(actual.source == expected.source);
}

std::uint32_t addi(const std::uint8_t rd, const std::uint8_t rs1,
                   const std::int32_t imm = 1) {
    return 0x00au << 22u |
           (static_cast<std::uint32_t>(imm) & 0xfffu) << 10u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t add(const std::uint8_t rd, const std::uint8_t rs1,
                  const std::uint8_t rs2) {
    return 0x020u << 15u |
           static_cast<std::uint32_t>(rs2) << 10u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t mul(const std::uint8_t rd, const std::uint8_t rs1,
                  const std::uint8_t rs2) {
    return 0x038u << 15u |
           static_cast<std::uint32_t>(rs2) << 10u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t slli(const std::uint8_t rd, const std::uint8_t rs1,
                   const std::uint8_t shift) {
    return 0x081u << 15u |
           static_cast<std::uint32_t>(shift & 31u) << 10u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t lw(const std::uint8_t rd, const std::uint8_t rs1) {
    return 0x0a2u << 22u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t sw(const std::uint8_t rs2, const std::uint8_t rs1) {
    return 0x0a6u << 22u |
           static_cast<std::uint32_t>(rs1) << 5u | rs2;
}

std::uint32_t beq(const std::uint8_t rs1, const std::uint8_t rs2) {
    return 0x16u << 26u |
           static_cast<std::uint32_t>(rs1) << 5u | rs2;
}

std::uint32_t bl() {
    return 0x15u << 26u;
}

std::uint32_t jirl(const std::uint8_t rd, const std::uint8_t rs1) {
    return 0x13u << 26u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

std::uint32_t div_w(const std::uint8_t rd, const std::uint8_t rs1,
                    const std::uint8_t rs2) {
    return 0x040u << 15u |
           static_cast<std::uint32_t>(rs2) << 10u |
           static_cast<std::uint32_t>(rs1) << 5u | rd;
}

CfiEvent event(const std::uint64_t ordinal, const std::uint32_t pc,
               const std::uint32_t instruction) {
    CfiEvent result;
    result.instruction_ordinal = ordinal;
    result.source_pc = pc;
    result.instruction = instruction;
    result.next_pc = pc + 4u;
    return result;
}

void test_priority_and_payloads() {
    ForwardingInputs inputs;
    inputs.s0.rs1 = 5u;
    inputs.s0.rf_rs1 = 0x7000'0005u;
    inputs.ex_s1 = producer(5u, 0x1100'0005u);
    inputs.ex_s0 = producer(5u, 0x1000'0005u);
    inputs.mem_s1 = producer(5u, 0x2100'0005u);
    inputs.mem_s0 = producer(5u, 0x2000'0005u);
    inputs.wb_s1 = producer(5u, 0x3100'0005u);
    inputs.wb_s0 = producer(5u, 0x3000'0005u);

    auto output = archsim::evaluate_forwarding(inputs);
    assert(output.s0[0].source == ForwardingSource::S1Ex);
    assert(output.s0[0].data == 0x1100'0005u);

    auto mask = ForwardingNetworkMask::without(ForwardingNetwork::IdS1Ex);
    output = archsim::evaluate_forwarding(inputs, mask);
    assert(output.s0[0].source == ForwardingSource::S0Ex);
    assert(output.s0[0].data == 0x1000'0005u);

    inputs.ex_s1.wb_sel = 2u;
    inputs.ex_s1.pc_plus_4 = 0x1234'5678u;
    output = archsim::evaluate_forwarding(inputs);
    assert(output.s0[0].data == 0x1234'5678u);

    inputs.ex_s1.valid = false;
    inputs.ex_s0.valid = false;
    inputs.mem_s1.valid = false;
    inputs.mem_s0.is_mul = true;
    inputs.mem_s0.alu_result = 0xbad0'0005u;
    inputs.mem_s0.mul_result = 0x600d'0005u;
    output = archsim::evaluate_forwarding(inputs);
    assert(output.s0[0].source == ForwardingSource::S0Mem);
    assert(output.s0[0].data == 0x600d'0005u);
}

void test_random_ordinary_equivalence() {
    std::mt19937 random(0x5eedu);
    for (unsigned trial = 0; trial < 20'000u; ++trial) {
        ForwardingInputs inputs;
        inputs.s0.rs1 = static_cast<std::uint8_t>(random() & 31u);
        inputs.s0.rf_rs1 = random();
        auto randomize = [&random](ForwardingProducer& value,
                                   const bool ex_stage) {
            value.valid = (random() & 1u) != 0u;
            value.reg_write = (random() & 1u) != 0u;
            value.is_load = (random() & 1u) != 0u;
            value.is_mul = (random() & 1u) != 0u;
            value.fast_alu = (random() & 1u) != 0u;
            value.result_repair = (random() & 1u) != 0u;
            value.rd = static_cast<std::uint8_t>(random() & 31u);
            value.wb_sel = static_cast<std::uint8_t>(random() % 3u);
            value.alu_result = random();
            value.fast_alu_result = ex_stage ? random() : value.alu_result;
            value.mul_result = random();
            value.pc_plus_4 = random();
            value.write_data = random();
        };
        randomize(inputs.ex_s0, true);
        randomize(inputs.ex_s1, false);
        randomize(inputs.mem_s0, false);
        randomize(inputs.mem_s1, false);
        randomize(inputs.wb_s0, false);
        randomize(inputs.wb_s1, false);
        const auto actual = archsim::evaluate_forwarding(inputs).s0[0];
        const auto expected =
            reference_forward(inputs, inputs.s0.rs1, inputs.s0.rf_rs1);
        check_operand(actual, expected);
    }
}

void test_load_repair_and_hazards() {
    ForwardingInputs inputs;
    inputs.s0.valid = true;
    inputs.s0.alu_only = true;
    inputs.s0.rs1_used = true;
    inputs.s0.rs1 = 6u;
    inputs.mem_s0 = producer(6u, 0u);
    inputs.mem_s0.is_load = true;
    inputs.mem_load_ready = true;

    auto output = archsim::evaluate_forwarding(inputs);
    assert(output.id_ready_go);
    assert(output.s0[0].repair == RepairSource::S0MemLoad);

    output = archsim::evaluate_forwarding(
        inputs, ForwardingNetworkMask::without(
                    ForwardingNetwork::LoadRepairS0Mem));
    assert(!output.id_ready_go);
    assert(output.s0[0].repair == RepairSource::None);

    inputs.mem_s0.valid = false;
    inputs.ex_s0 = producer(6u, 0u);
    inputs.ex_s0.mem_read = true;
    inputs.ex_s0.is_load = true;
    output = archsim::evaluate_forwarding(inputs);
    assert(!output.id_ready_go);
    assert(output.load_use_hazard);

    inputs.ex_s0.mem_read = false;
    inputs.ex_s0.is_muldiv = true;
    output = archsim::evaluate_forwarding(inputs);
    assert(!output.id_ready_go);
    assert(output.muldiv_use_hazard);
}

void test_mul_copy() {
    ForwardingInputs inputs;
    inputs.s0.rs1 = 9u;
    inputs.s0.rf_rs1 = 0x99u;
    inputs.mem_s1 = producer(9u, 0x1111u);
    inputs.mem_s0 = producer(9u, 0x2222u);
    inputs.wb_s1 = producer(9u, 0x3333u);
    auto output = archsim::evaluate_forwarding(inputs);
    assert(output.mul[0].source == ForwardingSource::S1Mem);
    assert(output.mul[0].data == 0x1111u);

    output = archsim::evaluate_forwarding(
        inputs,
        ForwardingNetworkMask::without(ForwardingNetwork::MulS1Mem));
    assert(output.mul[0].source == ForwardingSource::S0Mem);
    assert(output.mul[0].data == 0x2222u);
}

void test_pair_policy() {
    const auto first =
        archsim::decode_forwarding_instruction(event(1u, 0x8000'0000u,
                                                     addi(5u, 0u)));
    const auto store =
        archsim::decode_forwarding_instruction(event(2u, 0x8000'0004u,
                                                     sw(5u, 0u)));
    assert(archsim::forwarding_pair_ok(first, store, true));
    assert(!archsim::forwarding_pair_ok(first, store, false));

    const auto dependent_add =
        archsim::decode_forwarding_instruction(event(2u, 0x8000'0004u,
                                                     add(6u, 5u, 0u)));
    assert(!archsim::forwarding_pair_ok(first, dependent_add, true));
}

void test_la32_decode_metadata() {
    const auto store = archsim::decode_forwarding_instruction(
        event(1u, 0x1c00'0000u, sw(7u, 6u)));
    assert(store.is_store);
    assert(store.uses_rs1 && store.rs1 == 6u);
    assert(store.uses_rs2 && store.rs2 == 7u);
    assert(!store.writes_rd);

    const auto branch = archsim::decode_forwarding_instruction(
        event(2u, 0x1c00'0004u, beq(8u, 9u)));
    assert(branch.is_branch);
    assert(branch.rs1 == 8u && branch.rs2 == 9u);

    const auto link = archsim::decode_forwarding_instruction(
        event(3u, 0x1c00'0008u, bl()));
    assert(link.is_jal && link.writes_rd && link.rd == 1u);

    const auto indirect = archsim::decode_forwarding_instruction(
        event(4u, 0x1c00'000cu, jirl(1u, 5u)));
    assert(indirect.is_jalr && indirect.uses_rs1);
    assert(indirect.rs1 == 5u && indirect.rd == 1u);
    assert(indirect.force_single);

    const auto divide = archsim::decode_forwarding_instruction(
        event(5u, 0x1c00'0010u, div_w(3u, 4u, 5u)));
    assert(divide.is_muldiv && !divide.is_mul);
    assert(divide.force_single);

    const auto multiply = archsim::decode_forwarding_instruction(
        event(6u, 0x1c00'0014u, mul(3u, 4u, 5u)));
    const auto independent_add = archsim::decode_forwarding_instruction(
        event(7u, 0x1c00'0018u, add(8u, 6u, 7u)));
    assert(!multiply.force_single);
    assert(archsim::forwarding_pair_ok(multiply, independent_add));
    assert(!archsim::forwarding_pair_ok(independent_add, multiply));
}

ForwardingStudyModel run_two(const std::uint32_t first,
                             const std::uint32_t second,
                             const ForwardingNetworkMask mask =
                                 ForwardingNetworkMask::all()) {
    ForwardingStudyModel model(mask);
    model.feed(event(1u, 0x8000'0000u, first));
    model.feed(event(2u, 0x8000'0004u, second));
    model.finish();
    return model;
}

ForwardingStudyModel run_sequence(
    const std::initializer_list<std::uint32_t> instructions,
    const bool force_single = false) {
    ForwardingStudyModel model;
    std::uint64_t ordinal = 1u;
    std::uint32_t pc = 0x8000'0000u;
    for (const auto instruction : instructions) {
        auto decoded = archsim::decode_forwarding_instruction(
            event(ordinal++, pc, instruction));
        decoded.force_single |= force_single;
        model.feed(decoded);
        pc += 4u;
    }
    model.finish();
    return model;
}

void test_differential_pipeline() {
    const auto baseline = run_two(addi(1u, 0u), add(2u, 1u, 0u));
    const auto no_ex = run_two(
        addi(1u, 0u), add(2u, 1u, 0u),
        ForwardingNetworkMask::without(ForwardingNetwork::IdS0Ex));
    assert(baseline.stats().selected_hits
               [static_cast<std::size_t>(ForwardingNetwork::IdS0Ex)] == 1u);
    assert(no_ex.stats().cycles == baseline.stats().cycles + 1u);
    assert(no_ex.stats().removed_network_stall_cycles == 1u);

    const auto pair = run_two(addi(5u, 0u), sw(5u, 0u));
    const auto no_pair = run_two(
        addi(5u, 0u), sw(5u, 0u),
        ForwardingNetworkMask::without(
            ForwardingNetwork::PairS0AluToS1StoreData));
    assert(pair.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::PairS0AluToS1StoreData)] == 1u);
    assert(no_pair.stats().cycles == pair.stats().cycles + 1u);
    assert(no_pair.stats().removed_pair_opportunities == 1u);

    const auto load = run_two(lw(1u, 0u), add(2u, 1u, 0u));
    const auto no_repair = run_two(
        lw(1u, 0u), add(2u, 1u, 0u),
        ForwardingNetworkMask::without(
            ForwardingNetwork::LoadRepairS0Mem));
    assert(load.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::LoadRepairS0Mem)] == 1u);
    assert(no_repair.stats().cycles == load.stats().cycles + 1u);

    const auto multiply = run_two(addi(1u, 0u), mul(2u, 1u, 0u));
    const auto no_mul_mem = run_two(
        addi(1u, 0u), mul(2u, 1u, 0u),
        ForwardingNetworkMask::without(ForwardingNetwork::MulS0Mem));
    assert(multiply.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::MulS0Mem)] == 1u);
    assert(no_mul_mem.stats().cycles == multiply.stats().cycles + 1u);
}

void test_current_rtl_forwardability_rules() {
    // JIRL uses src0 to form its redirect target, so it cannot consume the
    // one-cycle-late MEM-load repair contract.
    const auto load_to_jirl = run_two(lw(5u, 0u), jirl(0u, 5u));
    assert(load_to_jirl.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::LoadRepairS0Mem)] == 0u);
    assert(load_to_jirl.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::IdS0Wb)] == 1u);

    // The committed RTL keeps a complete Slot1 EX fast copy, including the
    // barrel shifter, so a dependent consumer uses the Slot1 EX path.
    const auto slot1_shift = run_sequence({
        addi(8u, 0u),
        slli(5u, 0u, 3u),
        add(6u, 5u, 0u),
    });
    assert(slot1_shift.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::IdS1Ex)] == 1u);

    // An ALU result computed from a repaired load operand is not itself an
    // EX fast-forward source. Its immediate consumer waits for MEM.
    const auto repaired_chain = run_sequence({
        lw(1u, 0u),
        addi(2u, 1u),
        addi(3u, 2u),
    }, true);
    assert(repaired_chain.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::LoadRepairS0Mem)] == 1u);
    assert(repaired_chain.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::IdS0Ex)] == 0u);
    assert(repaired_chain.stats().selected_hits[static_cast<std::size_t>(
               ForwardingNetwork::IdS0Mem)] == 1u);

    std::uint64_t detailed_hits = 0;
    for (const auto& [key, path] : repaired_chain.stats().detailed_paths) {
        (void)key;
        detailed_hits += path.selected_operand_hits;
    }
    assert(detailed_hits == 2u);
}

void test_dcache_store_load_raw_bypass_accounting() {
    ForwardingStudyModel model;
    auto feed_memory = [&](const std::uint64_t ordinal,
                           const std::uint32_t instruction,
                           const archsim::MemoryAccessKind kind,
                           const std::uint32_t address) {
        auto decoded = archsim::decode_forwarding_instruction(
            event(ordinal, 0x1c00'0000u +
                           static_cast<std::uint32_t>(ordinal - 1u) * 4u,
                  instruction));
        decoded.force_single = true;
        decoded.memory_kind = kind;
        decoded.memory_address = address;
        model.feed(decoded);
    };

    constexpr std::uint32_t address = 0x1c08'1040u;
    // Warm the line, perform a store hit, then issue a same-word load in the
    // following cycle while that store occupies MEM.
    feed_memory(1u, lw(3u, 0u), archsim::MemoryAccessKind::Load, address);
    feed_memory(2u, sw(0u, 0u), archsim::MemoryAccessKind::Store, address);
    feed_memory(3u, lw(4u, 0u), archsim::MemoryAccessKind::Load, address);
    model.finish();

    assert(model.stats().dcache_store_hit_load_overlaps == 1u);
    assert(model.stats().dcache_raw_bypass_hits == 1u);
    assert(model.stats().dcache_raw_bypass_by_kind.at({
               archsim::La32InstructionKind::StW,
               archsim::La32InstructionKind::LdW}) == 1u);
}

void test_continuous_dependency_chain() {
    const auto model = run_sequence({
        addi(1u, 0u),
        addi(2u, 1u),
        addi(3u, 2u),
    });
    const auto& stats = model.stats();
    const auto s0_ex =
        static_cast<std::size_t>(ForwardingNetwork::IdS0Ex);

    assert(stats.inflight_consumer_instructions == 2u);
    assert(stats.eligible_middle_instructions == 2u);
    assert(stats.continuous_middle_instructions == 1u);
    assert(stats.continuous_operand_edges == 1u);
    assert(stats.continuous_instruction_pairs == 1u);
    assert(stats.continuous_chain_triplets == 1u);
    assert(stats.cycles_with_continuous_forwarding == 1u);
    assert(stats.maximum_continuous_chain_depth == 2u);
    assert(stats.chain_depth_histogram[0] == 1u);
    assert(stats.chain_depth_histogram[1] == 1u);
    assert(stats.chain_depth_histogram[2] == 1u);
    assert(stats.continuous_incoming_edges[s0_ex] == 1u);
    assert(stats.continuous_outgoing_edges[s0_ex] == 1u);
    assert(stats.continuous_network_pairs[s0_ex][s0_ex] == 1u);
}

void test_continuous_two_input_and_operand_deduplication() {
    const auto model = run_sequence({
        addi(1u, 0u),
        addi(2u, 0u),
        add(3u, 1u, 2u),
        add(4u, 3u, 3u),
    });
    const auto& stats = model.stats();
    const auto s0_ex =
        static_cast<std::size_t>(ForwardingNetwork::IdS0Ex);
    const auto s1_ex =
        static_cast<std::size_t>(ForwardingNetwork::IdS1Ex);

    assert(stats.inflight_consumer_instructions == 2u);
    assert(stats.eligible_middle_instructions == 2u);
    assert(stats.continuous_middle_instructions == 1u);
    assert(stats.continuous_operand_edges == 2u);
    assert(stats.continuous_instruction_pairs == 1u);
    assert(stats.continuous_chain_triplets == 4u);
    assert(stats.continuous_incoming_edges[s0_ex] == 1u);
    assert(stats.continuous_incoming_edges[s1_ex] == 1u);
    assert(stats.continuous_outgoing_edges[s0_ex] == 2u);
    assert(stats.continuous_network_pairs[s0_ex][s0_ex] == 2u);
    assert(stats.continuous_network_pairs[s1_ex][s0_ex] == 2u);
    assert(stats.chain_depth_histogram[0] == 2u);
    assert(stats.chain_depth_histogram[1] == 1u);
    assert(stats.chain_depth_histogram[2] == 1u);
}

void test_continuous_same_bundle_pair() {
    const auto model = run_sequence({
        addi(1u, 0u),
        addi(2u, 1u),
        sw(2u, 0u),
    });
    const auto& stats = model.stats();
    const auto s0_ex =
        static_cast<std::size_t>(ForwardingNetwork::IdS0Ex);
    const auto pair = static_cast<std::size_t>(
        ForwardingNetwork::PairS0AluToS1StoreData);

    assert(stats.inflight_consumer_instructions == 2u);
    assert(stats.eligible_middle_instructions == 1u);
    assert(stats.continuous_middle_instructions == 1u);
    assert(stats.continuous_operand_edges == 1u);
    assert(stats.continuous_instruction_pairs == 1u);
    assert(stats.continuous_chain_triplets == 1u);
    assert(stats.continuous_incoming_edges[s0_ex] == 1u);
    assert(stats.continuous_outgoing_edges[pair] == 1u);
    assert(stats.continuous_network_pairs[s0_ex][pair] == 1u);
    assert(stats.maximum_continuous_chain_depth == 2u);
}

void test_continuous_wb_retirement_boundary() {
    const auto before_retirement = run_sequence(
        {
            addi(1u, 0u),
            addi(2u, 1u),
            addi(10u, 0u),
            addi(11u, 0u),
            addi(3u, 2u),
        },
        true);
    const auto wb =
        static_cast<std::size_t>(ForwardingNetwork::IdS0Wb);
    assert(before_retirement.stats().continuous_middle_instructions == 1u);
    assert(before_retirement.stats().continuous_operand_edges == 1u);
    assert(before_retirement.stats().continuous_outgoing_edges[wb] == 1u);

    const auto after_retirement = run_sequence(
        {
            addi(1u, 0u),
            addi(2u, 1u),
            addi(10u, 0u),
            addi(11u, 0u),
            addi(12u, 0u),
            addi(3u, 2u),
        },
        true);
    assert(after_retirement.stats().inflight_consumer_instructions == 1u);
    assert(after_retirement.stats().eligible_middle_instructions == 1u);
    assert(after_retirement.stats().continuous_middle_instructions == 0u);
    assert(after_retirement.stats().continuous_operand_edges == 0u);
    assert(after_retirement.stats().continuous_instruction_pairs == 0u);
}

}  // namespace

int main() {
    test_priority_and_payloads();
    test_random_ordinary_equivalence();
    test_load_repair_and_hazards();
    test_mul_copy();
    test_pair_policy();
    test_la32_decode_metadata();
    test_differential_pipeline();
    test_current_rtl_forwardability_rules();
    test_dcache_store_load_raw_bypass_accounting();
    test_continuous_dependency_chain();
    test_continuous_two_input_and_operand_deduplication();
    test_continuous_same_bundle_pair();
    test_continuous_wb_retirement_boundary();
    std::cout << "forwarding_model_tests: PASS\n";
    return 0;
}
