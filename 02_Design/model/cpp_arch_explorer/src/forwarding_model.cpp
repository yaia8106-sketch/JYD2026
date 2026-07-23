#include "forwarding_model.hpp"

#include <algorithm>
#include <stdexcept>
#include <utility>

namespace archsim {
namespace {

constexpr std::array<ForwardingNetwork, kForwardingNetworkCount> kNetworks = {
    ForwardingNetwork::IdS1Ex,
    ForwardingNetwork::IdS0Ex,
    ForwardingNetwork::IdS1Mem,
    ForwardingNetwork::IdS0Mem,
    ForwardingNetwork::IdS1Wb,
    ForwardingNetwork::IdS0Wb,
    ForwardingNetwork::LoadRepairS1Mem,
    ForwardingNetwork::LoadRepairS0Mem,
    ForwardingNetwork::MulS1Mem,
    ForwardingNetwork::MulS0Mem,
    ForwardingNetwork::MulS1Wb,
    ForwardingNetwork::MulS0Wb,
    ForwardingNetwork::PairS0AluToS1StoreData,
};

constexpr std::size_t index_of(const ForwardingNetwork network) {
    return static_cast<std::size_t>(network);
}

ForwardingNetwork ordinary_network(const ForwardingSource source) {
    switch (source) {
        case ForwardingSource::S1Ex:
            return ForwardingNetwork::IdS1Ex;
        case ForwardingSource::S0Ex:
            return ForwardingNetwork::IdS0Ex;
        case ForwardingSource::S1Mem:
            return ForwardingNetwork::IdS1Mem;
        case ForwardingSource::S0Mem:
            return ForwardingNetwork::IdS0Mem;
        case ForwardingSource::S1Wb:
            return ForwardingNetwork::IdS1Wb;
        case ForwardingSource::S0Wb:
            return ForwardingNetwork::IdS0Wb;
        case ForwardingSource::RegisterFile:
            break;
    }
    return ForwardingNetwork::Count;
}

bool matches(const ForwardingProducer& producer, const std::uint8_t source) {
    return producer.valid && producer.reg_write && producer.rd != 0u &&
           producer.rd == source;
}

std::uint32_t ex_value(const ForwardingProducer& producer,
                       const bool slot0) {
    if (slot0 && producer.fast_alu) {
        return producer.fast_alu_result;
    }
    if (producer.wb_sel == 2u) {
        return producer.pc_plus_4;
    }
    return producer.alu_result;
}

std::uint32_t mem_value(const ForwardingProducer& producer) {
    if (producer.wb_sel == 2u) {
        return producer.pc_plus_4;
    }
    return producer.is_mul ? producer.mul_result : producer.alu_result;
}

ForwardedOperand select_ordinary(const ForwardingInputs& inputs,
                                 const std::uint8_t source,
                                 const std::uint32_t rf_data,
                                 const ForwardingNetworkMask& mask) {
    const auto enabled = [&mask](const ForwardingSource candidate) {
        return mask.has(ordinary_network(candidate));
    };
    if (enabled(ForwardingSource::S1Ex) &&
        matches(inputs.ex_s1, source)) {
        return {ex_value(inputs.ex_s1, false), ForwardingSource::S1Ex,
                RepairSource::None};
    }
    if (enabled(ForwardingSource::S0Ex) &&
        matches(inputs.ex_s0, source)) {
        return {ex_value(inputs.ex_s0, true), ForwardingSource::S0Ex,
                RepairSource::None};
    }
    if (enabled(ForwardingSource::S1Mem) &&
        matches(inputs.mem_s1, source) && !inputs.mem_s1.is_load) {
        return {mem_value(inputs.mem_s1), ForwardingSource::S1Mem,
                RepairSource::None};
    }
    if (enabled(ForwardingSource::S0Mem) &&
        matches(inputs.mem_s0, source) && !inputs.mem_s0.is_load) {
        return {mem_value(inputs.mem_s0), ForwardingSource::S0Mem,
                RepairSource::None};
    }
    if (enabled(ForwardingSource::S1Wb) &&
        matches(inputs.wb_s1, source)) {
        return {inputs.wb_s1.write_data, ForwardingSource::S1Wb,
                RepairSource::None};
    }
    if (enabled(ForwardingSource::S0Wb) &&
        matches(inputs.wb_s0, source)) {
        return {inputs.wb_s0.write_data, ForwardingSource::S0Wb,
                RepairSource::None};
    }
    return {rf_data, ForwardingSource::RegisterFile, RepairSource::None};
}

ForwardedOperand select_mul(const ForwardingInputs& inputs,
                            const std::uint8_t source,
                            const std::uint32_t rf_data,
                            const ForwardingNetworkMask& mask) {
    if (mask.has(ForwardingNetwork::MulS1Mem) &&
        matches(inputs.mem_s1, source) && !inputs.mem_s1.is_load) {
        return {mem_value(inputs.mem_s1), ForwardingSource::S1Mem,
                RepairSource::None};
    }
    if (mask.has(ForwardingNetwork::MulS0Mem) &&
        matches(inputs.mem_s0, source) && !inputs.mem_s0.is_load) {
        return {mem_value(inputs.mem_s0), ForwardingSource::S0Mem,
                RepairSource::None};
    }
    if (mask.has(ForwardingNetwork::MulS1Wb) &&
        matches(inputs.wb_s1, source)) {
        return {inputs.wb_s1.write_data, ForwardingSource::S1Wb,
                RepairSource::None};
    }
    if (mask.has(ForwardingNetwork::MulS0Wb) &&
        matches(inputs.wb_s0, source)) {
        return {inputs.wb_s0.write_data, ForwardingSource::S0Wb,
                RepairSource::None};
    }
    return {rf_data, ForwardingSource::RegisterFile, RepairSource::None};
}

std::uint32_t alu_source_1(const ForwardingConsumer& consumer,
                           const std::uint32_t rs1) {
    if (consumer.alu_src1_sel == 0u) {
        return rs1;
    }
    if (consumer.alu_src1_sel == 1u) {
        return consumer.pc;
    }
    return 0u;
}

std::uint32_t alu_source_2(const ForwardingConsumer& consumer,
                           const std::uint32_t rs2) {
    return consumer.alu_src2_imm ? consumer.imm : rs2;
}

bool operand_match(const ForwardingConsumer& consumer,
                   const ForwardingProducer& producer,
                   const std::uint8_t operand) {
    if (!consumer.valid || !producer.valid || producer.rd == 0u) {
        return false;
    }
    return operand == 0u
        ? consumer.rs1_used && consumer.rs1 == producer.rd
        : consumer.rs2_used && consumer.rs2 == producer.rd;
}

bool any_operand_match(const ForwardingConsumer& consumer,
                       const ForwardingProducer& producer) {
    return operand_match(consumer, producer, 0u) ||
           operand_match(consumer, producer, 1u);
}

bool ordinary_hit(const ForwardingInputs& inputs,
                  const ForwardingConsumer& consumer,
                  const std::uint8_t operand,
                  const ForwardingSource source,
                  const ForwardingNetworkMask& mask) {
    if (!mask.has(ordinary_network(source))) {
        return false;
    }
    const ForwardingProducer* producer = nullptr;
    switch (source) {
        case ForwardingSource::S1Ex:
            producer = &inputs.ex_s1;
            break;
        case ForwardingSource::S0Ex:
            producer = &inputs.ex_s0;
            break;
        case ForwardingSource::S1Mem:
            producer = &inputs.mem_s1;
            break;
        case ForwardingSource::S0Mem:
            producer = &inputs.mem_s0;
            break;
        case ForwardingSource::S1Wb:
            producer = &inputs.wb_s1;
            break;
        case ForwardingSource::S0Wb:
            producer = &inputs.wb_s0;
            break;
        case ForwardingSource::RegisterFile:
            return false;
    }
    if (!matches(*producer, operand == 0u ? consumer.rs1 : consumer.rs2)) {
        return false;
    }
    if ((source == ForwardingSource::S1Mem ||
         source == ForwardingSource::S0Mem) &&
        producer->is_load) {
        return false;
    }
    return true;
}

RepairSource repair_source_for(const ForwardingInputs& inputs,
                               const ForwardingConsumer& consumer,
                               const std::uint8_t operand,
                               const bool repair_ok,
                               const ForwardingNetworkMask& mask) {
    if (!consumer.valid || !repair_ok || !inputs.mem_load_ready) {
        return RepairSource::None;
    }
    const auto source = operand == 0u ? consumer.rs1 : consumer.rs2;
    const auto used = operand == 0u ? consumer.rs1_used : consumer.rs2_used;
    if (!used) {
        return RepairSource::None;
    }

    const bool ex_s1_block = ordinary_hit(
        inputs, consumer, operand, ForwardingSource::S1Ex, mask);
    const bool ex_s0_block = ordinary_hit(
        inputs, consumer, operand, ForwardingSource::S0Ex, mask);
    const bool mem_s1_nonload_block = ordinary_hit(
        inputs, consumer, operand, ForwardingSource::S1Mem, mask);

    const bool s1_candidate =
        mask.has(ForwardingNetwork::LoadRepairS1Mem) &&
        inputs.mem_s1.valid && inputs.mem_s1.reg_write &&
        inputs.mem_s1.is_load && inputs.mem_s1.rd != 0u &&
        inputs.mem_s1.rd == source && !ex_s1_block && !ex_s0_block;
    if (s1_candidate) {
        return RepairSource::S1MemLoad;
    }
    const bool s0_candidate =
        mask.has(ForwardingNetwork::LoadRepairS0Mem) &&
        inputs.mem_s0.valid && inputs.mem_s0.reg_write &&
        inputs.mem_s0.is_load && inputs.mem_s0.rd != 0u &&
        inputs.mem_s0.rd == source && !ex_s1_block && !ex_s0_block &&
        !mem_s1_nonload_block;
    return s0_candidate ? RepairSource::S0MemLoad : RepairSource::None;
}

bool consumer_can_repair_from(const ForwardingConsumer& consumer,
                              const ForwardingProducer& producer,
                              const bool instruction_repair_ok,
                              const ForwardingNetwork network,
                              const ForwardingNetworkMask& mask) {
    return instruction_repair_ok && mask.has(network) &&
           any_operand_match(consumer, producer);
}

void validate_chain_stats(const ForwardingStudyStats& stats) {
    const auto fail = [](const char* invariant) {
        throw std::runtime_error(
            std::string("continuous dependency invariant failed: ") +
            invariant);
    };

    std::uint64_t depth_total = 0;
    for (const auto count : stats.chain_depth_histogram) {
        depth_total += count;
    }
    if (depth_total != stats.instructions) {
        fail("depth histogram");
    }
    if (stats.eligible_middle_instructions >
            stats.inflight_consumer_instructions ||
        stats.inflight_consumer_instructions > stats.instructions ||
        stats.continuous_middle_instructions >
            stats.eligible_middle_instructions) {
        fail("instruction subsets");
    }
    if (stats.continuous_instruction_pairs >
            stats.continuous_operand_edges ||
        stats.cycles_with_continuous_forwarding >
            stats.single_issue_cycles + stats.dual_issue_cycles) {
        fail("event subsets");
    }

    std::uint64_t selected_total = 0;
    std::uint64_t outgoing_total = 0;
    std::uint64_t matrix_total = 0;
    for (std::size_t network = 0;
         network < kForwardingNetworkCount; ++network) {
        std::uint64_t selected_operands = 0;
        std::uint64_t outgoing_operands = 0;
        for (std::size_t operand = 0; operand < 4u; ++operand) {
            selected_operands +=
                stats.selected_hits_by_operand[network][operand];
            outgoing_operands +=
                stats.continuous_outgoing_edges_by_operand[network][operand];
        }
        if (selected_operands != stats.selected_hits[network] ||
            outgoing_operands !=
                stats.continuous_outgoing_edges[network] ||
            stats.continuous_incoming_edges[network] >
                stats.selected_hits[network] ||
            stats.continuous_outgoing_edges[network] >
                stats.selected_hits[network]) {
            fail("network edge totals");
        }
        selected_total += stats.selected_hits[network];
        outgoing_total += stats.continuous_outgoing_edges[network];
        for (std::size_t outgoing = 0;
             outgoing < kForwardingNetworkCount; ++outgoing) {
            matrix_total +=
                stats.continuous_network_pairs[network][outgoing];
        }
    }
    if (outgoing_total != stats.continuous_operand_edges ||
        matrix_total != stats.continuous_chain_triplets ||
        stats.continuous_operand_edges > selected_total ||
        (stats.continuous_operand_edges != 0u &&
         stats.continuous_chain_triplets <
             stats.continuous_operand_edges)) {
        fail("global edge totals");
    }
}

}  // namespace

const char* forwarding_network_name(const ForwardingNetwork network) {
    switch (network) {
        case ForwardingNetwork::IdS1Ex:
            return "id_s1_ex";
        case ForwardingNetwork::IdS0Ex:
            return "id_s0_ex";
        case ForwardingNetwork::IdS1Mem:
            return "id_s1_mem";
        case ForwardingNetwork::IdS0Mem:
            return "id_s0_mem";
        case ForwardingNetwork::IdS1Wb:
            return "id_s1_wb";
        case ForwardingNetwork::IdS0Wb:
            return "id_s0_wb";
        case ForwardingNetwork::LoadRepairS1Mem:
            return "load_repair_s1_mem";
        case ForwardingNetwork::LoadRepairS0Mem:
            return "load_repair_s0_mem";
        case ForwardingNetwork::MulS1Mem:
            return "mul_s1_mem";
        case ForwardingNetwork::MulS0Mem:
            return "mul_s0_mem";
        case ForwardingNetwork::MulS1Wb:
            return "mul_s1_wb";
        case ForwardingNetwork::MulS0Wb:
            return "mul_s0_wb";
        case ForwardingNetwork::PairS0AluToS1StoreData:
            return "pair_s0_alu_to_s1_store_data";
        case ForwardingNetwork::Count:
            break;
    }
    return "none";
}

const std::array<ForwardingNetwork, kForwardingNetworkCount>&
all_forwarding_networks() {
    return kNetworks;
}

ForwardingNetworkMask ForwardingNetworkMask::all() {
    ForwardingNetworkMask mask;
    mask.enabled.set();
    return mask;
}

ForwardingNetworkMask ForwardingNetworkMask::without(
    const ForwardingNetwork network) {
    auto mask = all();
    mask.enabled.reset(index_of(network));
    return mask;
}

bool ForwardingNetworkMask::has(const ForwardingNetwork network) const {
    return network != ForwardingNetwork::Count &&
           enabled.test(index_of(network));
}

ForwardingOutputs evaluate_forwarding(const ForwardingInputs& inputs,
                                      const ForwardingNetworkMask& mask) {
    ForwardingOutputs outputs;
    outputs.s0[0] =
        select_ordinary(inputs, inputs.s0.rs1, inputs.s0.rf_rs1, mask);
    outputs.s0[1] =
        select_ordinary(inputs, inputs.s0.rs2, inputs.s0.rf_rs2, mask);
    outputs.s1[0] =
        select_ordinary(inputs, inputs.s1.rs1, inputs.s1.rf_rs1, mask);
    outputs.s1[1] =
        select_ordinary(inputs, inputs.s1.rs2, inputs.s1.rf_rs2, mask);
    outputs.mul[0] =
        select_mul(inputs, inputs.s0.rs1, inputs.s0.rf_rs1, mask);
    outputs.mul[1] =
        select_mul(inputs, inputs.s0.rs2, inputs.s0.rf_rs2, mask);

    outputs.s0_alu = {
        alu_source_1(inputs.s0, outputs.s0[0].data),
        alu_source_2(inputs.s0, outputs.s0[1].data),
    };
    outputs.s1_alu = {
        alu_source_1(inputs.s1, outputs.s1[0].data),
        alu_source_2(inputs.s1, outputs.s1[1].data),
    };

    const bool s0_repair_ok =
        inputs.s0.alu_only || inputs.s0.conditional_control ||
        inputs.s0.indirect_control || inputs.s0.mem_read ||
        inputs.s0.mem_write;
    const bool s1_repair_ok = inputs.s1.valid && inputs.s1.repair_ok;
    for (std::uint8_t operand = 0; operand < 2u; ++operand) {
        outputs.s0[operand].repair = repair_source_for(
            inputs, inputs.s0, operand, s0_repair_ok, mask);
        outputs.s1[operand].repair = repair_source_for(
            inputs, inputs.s1, operand, s1_repair_ok, mask);
    }

    const auto ex_load_hazard = [&](const ForwardingProducer& producer) {
        return producer.valid && producer.mem_read && producer.rd != 0u &&
               (any_operand_match(inputs.s0, producer) ||
                any_operand_match(inputs.s1, producer));
    };
    const bool load_in_ex =
        ex_load_hazard(inputs.ex_s0) || ex_load_hazard(inputs.ex_s1);

    const auto mem_load_hazard = [&](const ForwardingProducer& producer,
                                     const ForwardingNetwork repair_network,
                                     const bool ready) {
        if (!producer.valid || !producer.is_load || producer.rd == 0u) {
            return false;
        }
        const bool s0_match = any_operand_match(inputs.s0, producer);
        const bool s1_match = any_operand_match(inputs.s1, producer);
        if (!ready) {
            return s0_match || s1_match;
        }
        const bool s0_repairs = consumer_can_repair_from(
            inputs.s0, producer, s0_repair_ok, repair_network, mask);
        const bool s1_repairs = consumer_can_repair_from(
            inputs.s1, producer, s1_repair_ok, repair_network, mask);
        return (s0_match && !s0_repairs) || (s1_match && !s1_repairs);
    };
    const bool load_mem_ready =
        mem_load_hazard(inputs.mem_s0,
                        ForwardingNetwork::LoadRepairS0Mem, true) ||
        mem_load_hazard(inputs.mem_s1,
                        ForwardingNetwork::LoadRepairS1Mem, true);
    const bool load_mem_wait =
        mem_load_hazard(inputs.mem_s0,
                        ForwardingNetwork::LoadRepairS0Mem, false) ||
        mem_load_hazard(inputs.mem_s1,
                        ForwardingNetwork::LoadRepairS1Mem, false);

    outputs.muldiv_use_hazard =
        inputs.ex_s0.valid && inputs.ex_s0.is_muldiv &&
        inputs.ex_s0.rd != 0u &&
        (any_operand_match(inputs.s0, inputs.ex_s0) ||
         any_operand_match(inputs.s1, inputs.ex_s0));
    outputs.mul_launch_ex_raw_hazard =
        inputs.s0.is_mul &&
        ((inputs.ex_s0.valid && inputs.ex_s0.reg_write &&
          inputs.ex_s0.rd != 0u &&
          any_operand_match(inputs.s0, inputs.ex_s0)) ||
         (inputs.ex_s1.valid && inputs.ex_s1.reg_write &&
          inputs.ex_s1.rd != 0u &&
          any_operand_match(inputs.s0, inputs.ex_s1)));
    const bool non_load_hazard =
        outputs.muldiv_use_hazard || outputs.mul_launch_ex_raw_hazard;
    outputs.id_ready_go_if_mem_ready =
        !(load_in_ex || load_mem_ready || non_load_hazard);
    outputs.id_ready_go_if_mem_wait =
        !(load_in_ex || load_mem_wait || non_load_hazard);
    outputs.id_ready_go = inputs.mem_load_ready
        ? outputs.id_ready_go_if_mem_ready
        : outputs.id_ready_go_if_mem_wait;
    outputs.load_use_hazard = inputs.mem_load_ready
        ? (load_in_ex || load_mem_ready)
        : (load_in_ex || load_mem_wait);
    return outputs;
}

ForwardingDecodedInstruction decode_forwarding_instruction(
    const CfiEvent& event) {
    ForwardingDecodedInstruction decoded;
    decoded.ordinal = event.instruction_ordinal;
    decoded.pc = event.source_pc;
    decoded.instruction = event.instruction;
    decoded.predicted_taken = event.kind != CfiKind::None && event.taken;

    const auto opcode = event.instruction & 0x7fu;
    const auto funct3 = (event.instruction >> 12u) & 0x7u;
    const auto funct7 = (event.instruction >> 25u) & 0x7fu;
    decoded.rd =
        static_cast<std::uint8_t>((event.instruction >> 7u) & 0x1fu);
    decoded.rs1 =
        static_cast<std::uint8_t>((event.instruction >> 15u) & 0x1fu);
    decoded.rs2 =
        static_cast<std::uint8_t>((event.instruction >> 20u) & 0x1fu);

    const bool funct7_zero = funct7 == 0u;
    const bool funct7_alt = funct7 == 0x20u;
    const bool r_opcode = opcode == 0x33u;
    const bool r_muldiv = r_opcode && funct7 == 0x01u;
    const bool r_alt = funct7_alt && (funct3 == 0u || funct3 == 5u);
    const bool r_base = r_opcode && (funct7_zero || r_alt);
    const bool r_legal = r_base || r_muldiv;

    const bool i_opcode = opcode == 0x13u;
    const bool i_nonshift = funct3 == 0u || funct3 == 2u ||
                            funct3 == 3u || funct3 == 4u ||
                            funct3 == 6u || funct3 == 7u;
    const bool i_shift_left = funct3 == 1u && funct7_zero;
    const bool i_shift_right =
        funct3 == 5u && (funct7_zero || funct7_alt);
    const bool i_legal =
        i_opcode && (i_nonshift || i_shift_left || i_shift_right);
    const bool load = opcode == 0x03u &&
        (funct3 == 0u || funct3 == 1u || funct3 == 2u ||
         funct3 == 4u || funct3 == 5u);
    const bool store =
        opcode == 0x23u && (funct3 == 0u || funct3 == 1u || funct3 == 2u);
    const bool branch = opcode == 0x63u &&
        (funct3 == 0u || funct3 == 1u || funct3 == 4u ||
         funct3 == 5u || funct3 == 6u || funct3 == 7u);
    const bool jal = opcode == 0x6fu;
    const bool jalr = opcode == 0x67u && funct3 == 0u;
    const bool csr = opcode == 0x73u &&
        (funct3 == 1u || funct3 == 2u || funct3 == 3u ||
         funct3 == 5u || funct3 == 6u || funct3 == 7u);
    const bool system_legal = csr || event.instruction == 0x0000'0073u ||
                              event.instruction == 0x0010'0073u ||
                              event.instruction == 0x3020'0073u;
    const bool fence = opcode == 0x0fu;
    const bool legal = r_legal || i_legal || load || store || branch ||
                       opcode == 0x37u || opcode == 0x17u || jal || jalr ||
                       system_legal || fence;

    decoded.is_alu_type =
        r_base || i_legal || opcode == 0x37u || opcode == 0x17u;
    decoded.is_load = load;
    decoded.is_store = store;
    decoded.is_branch = branch;
    decoded.is_jal = jal;
    decoded.is_jalr = jalr;
    decoded.is_muldiv = r_muldiv;
    decoded.is_mul = r_muldiv && (funct3 & 0x4u) == 0u;
    decoded.writes_rd = r_legal || i_legal || load ||
                        opcode == 0x37u || opcode == 0x17u || jal || jalr ||
                        csr;
    decoded.uses_rs1 = r_legal || i_legal || load || store || branch ||
                       jalr || (csr && (funct3 & 0x4u) == 0u);
    decoded.uses_rs2 = r_legal || store || branch;
    decoded.force_single = jalr || opcode == 0x73u || fence || !legal ||
                           (r_muldiv && (funct3 & 0x4u) != 0u) ||
                           (r_opcode && !r_legal) ||
                           (i_opcode && !i_legal);
    return decoded;
}

bool forwarding_pair_ok(const ForwardingDecodedInstruction& first,
                        const ForwardingDecodedInstruction& second,
                        const bool pair_bypass_enabled) {
    if (second.pc != first.pc + 4u || first.predicted_taken ||
        first.force_single || second.force_single) {
        return false;
    }
    const bool raw_rs1 =
        first.writes_rd && first.rd != 0u && second.uses_rs1 &&
        second.rs1 == first.rd;
    const bool raw_rs2 =
        first.writes_rd && first.rd != 0u && second.uses_rs2 &&
        second.rs2 == first.rd;
    const bool store_data_bypass =
        pair_bypass_enabled && raw_rs2 && !raw_rs1 &&
        first.is_alu_type && second.is_store;
    const bool blocking_raw = raw_rs1 || (raw_rs2 && !store_data_bypass);
    const bool first_lsu = first.is_load || first.is_store;
    const bool second_lsu = second.is_load || second.is_store;
    const bool first_cfi =
        first.is_branch || first.is_jal || first.is_jalr;
    const bool second_cfi =
        second.is_branch || second.is_jal || second.is_jalr;
    const bool first_supported =
        first.is_alu_type || first_lsu || first_cfi || first.is_muldiv;
    const bool second_supported =
        second.is_alu_type || second_lsu || second_cfi;
    return first_supported && second_supported &&
           !(first_lsu && second_lsu) && !(first_cfi && second_cfi) &&
           !blocking_raw;
}

ForwardingStudyModel::ForwardingStudyModel(ForwardingNetworkMask mask)
    : mask_(std::move(mask)) {}

bool ForwardingStudyModel::writes(const Token& token, const std::uint8_t reg) {
    return reg != 0u && token.decoded.writes_rd &&
           token.decoded.rd == reg;
}

const ForwardingStudyModel::Token* ForwardingStudyModel::writer_in(
    const Bundle& bundle, const std::uint8_t reg) const {
    if (bundle.count > 1u && writes(bundle.slot[1], reg)) {
        return &bundle.slot[1];
    }
    if (bundle.count > 0u && writes(bundle.slot[0], reg)) {
        return &bundle.slot[0];
    }
    return nullptr;
}

const ForwardingStudyModel::Token* ForwardingStudyModel::youngest_writer(
    const std::uint8_t reg) const {
    if (const auto* writer = writer_in(ex_, reg)) {
        return writer;
    }
    if (const auto* writer = writer_in(mem_, reg)) {
        return writer;
    }
    return writer_in(wb_, reg);
}

ForwardingStudyModel::Bundle ForwardingStudyModel::candidate_bundle() const {
    Bundle candidate;
    if (trace_.empty()) {
        return candidate;
    }
    candidate.slot[0] = trace_[0];
    candidate.count = 1u;
    if (trace_.size() >= 2u &&
        forwarding_pair_ok(
            trace_[0].decoded, trace_[1].decoded,
            mask_.has(ForwardingNetwork::PairS0AluToS1StoreData))) {
        candidate.slot[1] = trace_[1];
        candidate.count = 2u;
    }
    return candidate;
}

ForwardingStudyModel::Delivery ForwardingStudyModel::delivery_for(
    const Token& consumer, const std::uint8_t consumer_slot,
    const std::uint8_t operand, const Bundle& candidate) const {
    const bool used = operand == 0u
        ? consumer.decoded.uses_rs1
        : consumer.decoded.uses_rs2;
    const auto reg = operand == 0u
        ? consumer.decoded.rs1
        : consumer.decoded.rs2;
    if (!used || reg == 0u) {
        return {};
    }

    if (consumer_slot == 1u && candidate.count == 2u &&
        writes(candidate.slot[0], reg)) {
        const bool legal_pair_bypass =
            operand == 1u && consumer.decoded.is_store &&
            candidate.slot[0].decoded.is_alu_type &&
            candidate.slot[0].decoded.rd != consumer.decoded.rs1;
        if (!legal_pair_bypass) {
            return {false, true, ForwardingNetwork::Count,
                    candidate.slot[0].decoded.ordinal};
        }
        return {mask_.has(ForwardingNetwork::PairS0AluToS1StoreData),
                false, ForwardingNetwork::PairS0AluToS1StoreData,
                candidate.slot[0].decoded.ordinal};
    }

    const auto* writer = youngest_writer(reg);
    if (writer == nullptr) {
        return {};
    }
    const auto in_ex = writer_in(ex_, reg) == writer;
    const auto in_mem = writer_in(mem_, reg) == writer;
    const auto in_wb = writer_in(wb_, reg) == writer;
    const auto writer_slot = [&]() -> std::uint8_t {
        const Bundle& bundle = in_ex ? ex_ : (in_mem ? mem_ : wb_);
        return bundle.count > 1u && &bundle.slot[1] == writer ? 1u : 0u;
    }();

    if (in_ex && (writer->decoded.is_load ||
                  writer->decoded.is_muldiv)) {
        return {false, true, ForwardingNetwork::Count,
                writer->decoded.ordinal};
    }

    if (consumer.decoded.is_mul) {
        if (in_ex) {
            return {false, true, ForwardingNetwork::Count,
                    writer->decoded.ordinal};
        }
        if (in_mem && writer->decoded.is_load) {
            return {false, true, ForwardingNetwork::Count,
                    writer->decoded.ordinal};
        }
        ForwardingNetwork network = ForwardingNetwork::Count;
        if (in_mem) {
            network = writer_slot == 1u
                ? ForwardingNetwork::MulS1Mem
                : ForwardingNetwork::MulS0Mem;
        } else if (in_wb) {
            network = writer_slot == 1u
                ? ForwardingNetwork::MulS1Wb
                : ForwardingNetwork::MulS0Wb;
        }
        return {mask_.has(network), false, network,
                writer->decoded.ordinal};
    }

    if (in_mem && writer->decoded.is_load) {
        const bool repair_ok = consumer_slot == 1u ||
            consumer.decoded.is_alu_type || consumer.decoded.is_branch ||
            consumer.decoded.is_jalr || consumer.decoded.is_load ||
            consumer.decoded.is_store;
        const auto network = writer_slot == 1u
            ? ForwardingNetwork::LoadRepairS1Mem
            : ForwardingNetwork::LoadRepairS0Mem;
        return {repair_ok && mask_.has(network), !repair_ok, network,
                writer->decoded.ordinal};
    }

    ForwardingNetwork network = ForwardingNetwork::Count;
    if (in_ex) {
        network = writer_slot == 1u
            ? ForwardingNetwork::IdS1Ex
            : ForwardingNetwork::IdS0Ex;
    } else if (in_mem) {
        network = writer_slot == 1u
            ? ForwardingNetwork::IdS1Mem
            : ForwardingNetwork::IdS0Mem;
    } else if (in_wb) {
        network = writer_slot == 1u
            ? ForwardingNetwork::IdS1Wb
            : ForwardingNetwork::IdS0Wb;
    }
    return {mask_.has(network), false, network, writer->decoded.ordinal};
}

bool ForwardingStudyModel::has_inflight_dependency(const Token& token) {
    return std::any_of(
        token.incoming.begin(), token.incoming.end(),
        [](const DependencyTag& dependency) { return dependency.valid; });
}

ForwardingStudyModel::Token* ForwardingStudyModel::token_in(
    Bundle& bundle, const std::uint64_t ordinal) {
    for (std::uint8_t slot = 0; slot < bundle.count; ++slot) {
        if (bundle.slot[slot].decoded.ordinal == ordinal) {
            return &bundle.slot[slot];
        }
    }
    return nullptr;
}

ForwardingStudyModel::Token* ForwardingStudyModel::producer_token(
    Bundle& issued, const std::uint64_t ordinal) {
    if (ordinal == 0u) {
        return nullptr;
    }
    if (auto* token = token_in(issued, ordinal)) {
        return token;
    }
    if (auto* token = token_in(ex_, ordinal)) {
        return token;
    }
    if (auto* token = token_in(mem_, ordinal)) {
        return token;
    }
    return token_in(wb_, ordinal);
}

void ForwardingStudyModel::annotate_issued_dependencies(
    Bundle& issued, const DeliveryMatrix& deliveries) {
    // Slot 0 is processed before slot 1 so a same-bundle S0 -> S1 bypass
    // observes any in-flight dependencies that S0 acquires in this cycle.
    for (std::uint8_t slot = 0; slot < issued.count; ++slot) {
        auto& consumer = issued.slot[slot];
        for (std::uint8_t operand = 0; operand < 2u; ++operand) {
            const auto& delivery = deliveries[slot][operand];
            if (delivery.network == ForwardingNetwork::Count ||
                delivery.producer_ordinal == 0u) {
                continue;
            }
            auto* producer =
                producer_token(issued, delivery.producer_ordinal);
            if (producer == nullptr) {
                throw std::runtime_error(
                    "forwarding producer token disappeared before issue");
            }
            consumer.incoming[operand] = {
                true, delivery.producer_ordinal, delivery.network};
            consumer.continuous_chain_depth = std::max(
                consumer.continuous_chain_depth,
                producer->continuous_chain_depth + 1u);
        }
    }
}

void ForwardingStudyModel::record_issued_dependencies(
    Bundle& issued, const DeliveryMatrix& deliveries) {
    for (std::uint8_t slot = 0; slot < issued.count; ++slot) {
        const auto& token = issued.slot[slot];
        const bool consumes_inflight = has_inflight_dependency(token);
        stats_.inflight_consumer_instructions +=
            static_cast<std::uint64_t>(consumes_inflight);
        stats_.eligible_middle_instructions +=
            static_cast<std::uint64_t>(
                consumes_inflight && token.decoded.writes_rd &&
                token.decoded.rd != 0u);
        const auto depth_bucket = std::min<std::size_t>(
            token.continuous_chain_depth,
            kForwardingChainDepthBucketCount - 1u);
        ++stats_.chain_depth_histogram[depth_bucket];
        stats_.maximum_continuous_chain_depth = std::max<std::uint64_t>(
            stats_.maximum_continuous_chain_depth,
            token.continuous_chain_depth);
    }

    struct DynamicPair {
        std::uint64_t producer = 0;
        std::uint64_t consumer = 0;
    };
    std::array<DynamicPair, 4> observed_pairs{};
    std::size_t observed_pair_count = 0;
    bool continuous_cycle = false;

    for (std::uint8_t slot = 0; slot < issued.count; ++slot) {
        const auto consumer_ordinal = issued.slot[slot].decoded.ordinal;
        for (std::uint8_t operand = 0; operand < 2u; ++operand) {
            const auto& delivery = deliveries[slot][operand];
            if (delivery.network == ForwardingNetwork::Count) {
                continue;
            }
            const auto outgoing = index_of(delivery.network);
            ++stats_.selected_hits[outgoing];
            ++stats_.selected_hits_by_operand[outgoing]
                                              [slot * 2u + operand];

            auto* producer =
                producer_token(issued, delivery.producer_ordinal);
            if (producer == nullptr ||
                !has_inflight_dependency(*producer)) {
                continue;
            }

            continuous_cycle = true;
            ++stats_.continuous_operand_edges;
            ++stats_.continuous_outgoing_edges[outgoing];
            ++stats_.continuous_outgoing_edges_by_operand[outgoing]
                                                        [slot * 2u + operand];

            bool pair_seen = false;
            for (std::size_t index = 0; index < observed_pair_count;
                 ++index) {
                pair_seen |=
                    observed_pairs[index].producer ==
                        delivery.producer_ordinal &&
                    observed_pairs[index].consumer == consumer_ordinal;
            }
            if (!pair_seen) {
                observed_pairs[observed_pair_count++] = {
                    delivery.producer_ordinal, consumer_ordinal};
                ++stats_.continuous_instruction_pairs;
            }

            if (!producer->counted_as_continuous_middle) {
                producer->counted_as_continuous_middle = true;
                ++stats_.continuous_middle_instructions;
                for (const auto& incoming : producer->incoming) {
                    if (incoming.valid) {
                        ++stats_.continuous_incoming_edges
                            [index_of(incoming.network)];
                    }
                }
            }

            for (const auto& incoming : producer->incoming) {
                if (!incoming.valid) {
                    continue;
                }
                ++stats_.continuous_chain_triplets;
                ++stats_.continuous_network_pairs[index_of(incoming.network)]
                                                    [outgoing];
            }
        }
    }
    stats_.cycles_with_continuous_forwarding +=
        static_cast<std::uint64_t>(continuous_cycle);
}

void ForwardingStudyModel::tick(const bool) {
    ++stats_.cycles;

    const bool removed_pair_candidate =
        trace_.size() >= 2u &&
        forwarding_pair_ok(trace_[0].decoded, trace_[1].decoded, true) &&
        !forwarding_pair_ok(
            trace_[0].decoded, trace_[1].decoded,
            mask_.has(ForwardingNetwork::PairS0AluToS1StoreData));

    const auto candidate = candidate_bundle();
    DeliveryMatrix deliveries{};
    bool rtl_hazard = false;
    bool removed_hazard = false;
    for (std::uint8_t slot = 0; slot < candidate.count; ++slot) {
        for (std::uint8_t operand = 0; operand < 2u; ++operand) {
            deliveries[slot][operand] =
                delivery_for(candidate.slot[slot], slot, operand, candidate);
            rtl_hazard |= deliveries[slot][operand].rtl_hazard;
            removed_hazard |= !deliveries[slot][operand].ready &&
                              !deliveries[slot][operand].rtl_hazard;
        }
    }

    Bundle issued;
    if (candidate.count != 0u && !rtl_hazard && !removed_hazard) {
        issued = candidate;
        annotate_issued_dependencies(issued, deliveries);
        record_issued_dependencies(issued, deliveries);
        for (std::uint8_t slot = 0; slot < issued.count; ++slot) {
            trace_.pop_front();
        }
        stats_.instructions += issued.count;
        if (issued.count == 2u) {
            ++stats_.dual_issue_cycles;
        } else {
            ++stats_.single_issue_cycles;
            stats_.removed_pair_opportunities +=
                static_cast<std::uint64_t>(removed_pair_candidate);
        }
    } else if (candidate.count != 0u) {
        if (rtl_hazard) {
            ++stats_.rtl_hazard_stall_cycles;
        } else {
            ++stats_.removed_network_stall_cycles;
        }
    }

    wb_ = mem_;
    mem_ = ex_;
    ex_ = issued;
}

void ForwardingStudyModel::run_until_one_trace_entry() {
    while (trace_.size() >= 2u) {
        tick(false);
    }
}

void ForwardingStudyModel::feed(const CfiEvent& event) {
    feed(decode_forwarding_instruction(event));
}

void ForwardingStudyModel::feed(
    const ForwardingDecodedInstruction& instruction) {
    if (stats_.finished) {
        throw std::runtime_error("cannot feed a finished forwarding model");
    }
    Token token;
    token.decoded = instruction;
    trace_.push_back(token);
    run_until_one_trace_entry();
}

void ForwardingStudyModel::finish() {
    if (stats_.finished) {
        return;
    }
    while (!trace_.empty() || ex_.count != 0u || mem_.count != 0u ||
           wb_.count != 0u) {
        tick(true);
    }
    validate_chain_stats(stats_);
    stats_.finished = true;
}

}  // namespace archsim
