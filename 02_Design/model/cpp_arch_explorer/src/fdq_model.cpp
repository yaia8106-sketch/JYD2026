#include "fdq_model.hpp"

#include <algorithm>
#include <stdexcept>
#include <utility>

namespace archsim {
namespace {

FdqInstruction predecode(const CfiEvent& event,
                         const FrontendDecision& decision) {
    FdqInstruction result;
    result.pc = event.source_pc;
    result.instruction = event.instruction;
    result.pred_taken = decision.valid &&
                        decision.f1_next != event.source_pc + 4u;

    const auto opcode = event.instruction & 0x7fu;
    const auto funct3 = (event.instruction >> 12u) & 7u;
    const auto funct7 = (event.instruction >> 25u) & 0x7fu;
    const bool is_r = opcode == 0x33u;
    const bool is_i_alu = opcode == 0x13u;
    const bool is_load = opcode == 0x03u;
    const bool is_store = opcode == 0x23u;
    const bool is_branch = opcode == 0x63u;
    const bool is_jal = opcode == 0x6fu;
    const bool is_jalr = opcode == 0x67u;
    const bool is_system = opcode == 0x73u;
    const bool is_fence = opcode == 0x0fu;
    const bool is_muldiv = is_r && funct7 == 1u;
    const bool is_illegal = (event.instruction & 3u) != 3u;
    const bool is_alt_base = funct7 == 0x20u &&
                             (funct3 == 0u || funct3 == 5u);
    const bool nonbase_r = is_r && funct7 != 0u && !is_alt_base;
    const bool shift_immediate = (funct3 & 3u) == 1u;
    const bool base_i_shift = funct7 == 0u ||
                              (funct7 == 0x20u && funct3 == 5u);
    const bool nonbase_i = is_i_alu && shift_immediate && !base_i_shift;

    result.is_alu_type = (is_r && !is_muldiv) || is_i_alu ||
                         opcode == 0x37u || opcode == 0x17u;
    result.is_lsu = is_load || is_store;
    result.is_cfi = is_branch || is_jal || is_jalr;
    result.writes_rd = is_r || is_i_alu || is_load || opcode == 0x37u ||
                       opcode == 0x17u || is_jal || is_jalr || is_system;
    result.uses_rs1 = is_r || is_i_alu || is_load || is_store ||
                      is_branch || is_jalr;
    result.uses_rs2 = is_r || is_store || is_branch;
    result.rd = static_cast<std::uint8_t>((event.instruction >> 7u) & 0x1fu);
    result.rs1 = static_cast<std::uint8_t>((event.instruction >> 15u) & 0x1fu);
    result.rs2 = static_cast<std::uint8_t>((event.instruction >> 20u) & 0x1fu);
    result.force_single_as_first =
        is_jalr || is_system || is_fence || is_illegal ||
        nonbase_r || nonbase_i;
    result.force_single_as_second =
        is_system || is_fence || is_illegal || nonbase_r || nonbase_i;
    return result;
}

}  // namespace

FdqScenarioModel::FdqScenarioModel(FdqScenarioConfig config)
    : config_(std::move(config)) {
    if (config_.depth == 0u || config_.depth > queue_.size()) {
        throw std::runtime_error("FDQ depth must be in [1, 16]");
    }
    if (config_.f1_refill_cycles == 0u ||
        config_.backend_refill_cycles == 0u) {
        throw std::runtime_error("FDQ refill latency must be non-zero");
    }
    if (config_.consumer_stall_ppm >= 1'000'000u ||
        config_.consumer_stall_burst_cycles == 0u) {
        throw std::runtime_error("invalid FDQ consumer stall configuration");
    }
}

const FdqInstruction& FdqScenarioModel::at(const std::uint32_t offset) const {
    return queue_[(head_ + offset) % queue_.size()];
}

void FdqScenarioModel::push(const FdqInstruction& instruction) {
    queue_[(head_ + count_) % queue_.size()] = instruction;
    ++count_;
    stats_.maximum_occupancy = std::max<std::uint64_t>(
        stats_.maximum_occupancy, count_);
}

void FdqScenarioModel::pop(const std::uint8_t count) {
    head_ = (head_ + count) % queue_.size();
    count_ -= count;
}

bool FdqScenarioModel::pair_ok(const FdqInstruction& first,
                               const FdqInstruction& second) const {
    if (second.pc != first.pc + 4u || first.pred_taken ||
        first.force_single_as_first || second.force_single_as_second) {
        return false;
    }
    const bool raw_rs1 = first.writes_rd && first.rd != 0u &&
                         second.uses_rs1 && second.rs1 == first.rd;
    const bool raw_rs2 = first.writes_rd && first.rd != 0u &&
                         second.uses_rs2 && second.rs2 == first.rd;
    const bool store_data_bypass = first.is_alu_type && second.is_lsu &&
                                   second.uses_rs2 && raw_rs2 && !raw_rs1;
    const bool blocking_raw = (raw_rs1 || raw_rs2) && !store_data_bypass;
    const bool supported0 = first.is_alu_type || first.is_lsu || first.is_cfi;
    const bool supported1 = second.is_alu_type || second.is_lsu || second.is_cfi;
    return supported0 && supported1 &&
           !(first.is_lsu && second.is_lsu) &&
           !(first.is_cfi && second.is_cfi) && !blocking_raw;
}

std::uint8_t FdqScenarioModel::dequeue_width() const {
    if (count_ == 0u) {
        return 0u;
    }
    if (consumer_stalled()) {
        return 0u;
    }
    if (count_ < 2u) {
        return 1u;
    }
    if (config_.consume_policy == FdqConsumePolicy::DualAlways) {
        return 2u;
    }
    return pair_ok(at(0), at(1)) ? 2u : 1u;
}

bool FdqScenarioModel::consumer_stalled() const {
    if (config_.consumer_stall_ppm == 0u) {
        return false;
    }
    const auto burst = static_cast<std::uint64_t>(
        config_.consumer_stall_burst_cycles);
    const auto block = cycle_ / burst;
    const auto previous =
        (block * config_.consumer_stall_ppm) / 1'000'000u;
    const auto next =
        ((block + 1u) * config_.consumer_stall_ppm) / 1'000'000u;
    return next != previous;
}

void FdqScenarioModel::record_due_corrections() {
    if (pending_correction_.has_value() &&
        pending_correction_->cycle <= cycle_) {
        ++stats_.correction_observations;
        stats_.occupancy_sum_at_correction += count_;
        stats_.corrections_with_empty_fdq +=
            static_cast<std::uint64_t>(count_ == 0u);
        ++stats_.retained_at_correction[std::min<std::size_t>(
            count_, stats_.retained_at_correction.size() - 1u)];
        pending_correction_.reset();
    }
}

void FdqScenarioModel::step(const std::array<FdqInstruction, 2>* packet,
                            const std::uint8_t packet_count) {
    record_due_corrections();
    stats_.occupancy_sum += count_;
    const auto deq = dequeue_width();
    if (deq == 0u) {
        if (count_ == 0u) {
            ++stats_.empty_cycles;
        } else {
            ++stats_.consumer_stall_cycles;
        }
    } else if (deq == 1u) {
        ++stats_.single_issue_cycles;
    } else {
        ++stats_.dual_issue_cycles;
    }
    stats_.instructions_consumed += deq;
    pop(deq);
    if (packet != nullptr) {
        for (std::uint8_t slot = 0; slot < packet_count; ++slot) {
            push((*packet)[slot]);
        }
    }
    ++stats_.cycles;
    ++cycle_;
}

void FdqScenarioModel::submit(
    const std::array<FdqInstruction, 2>& packet, const std::uint8_t count,
    const FdqPacketControl& control) {
    if (count == 0u || count > 2u) {
        throw std::runtime_error("FDQ packet must contain one or two instructions");
    }
    while (cycle_ < next_arrival_cycle_) {
        step(nullptr, 0);
    }
    while (true) {
        const auto deq = dequeue_width();
        if (count_ - deq + count <= config_.depth) {
            break;
        }
        ++stats_.producer_blocked_cycles;
        step(nullptr, 0);
    }

    const auto arrival_cycle = cycle_;
    step(&packet, count);
    ++stats_.packets;
    stats_.one_instruction_packets += static_cast<std::uint64_t>(count == 1u);
    stats_.two_instruction_packets += static_cast<std::uint64_t>(count == 2u);
    stats_.f0_corrections += static_cast<std::uint64_t>(control.f0_correction);
    stats_.f1_corrections += static_cast<std::uint64_t>(control.f1_correction);
    stats_.backend_direction_redirects +=
        static_cast<std::uint64_t>(control.backend_direction_wrong);
    stats_.backend_target_redirects +=
        static_cast<std::uint64_t>(control.backend_target_wrong);
    stats_.system_redirects += static_cast<std::uint64_t>(control.system_redirect);

    if (control.f1_correction) {
        if (pending_correction_.has_value()) {
            throw std::runtime_error("overlapping F1 correction observations");
        }
        pending_correction_ = PendingCorrection{arrival_cycle + 1u};
        const auto wrong_blocks = config_.f1_refill_cycles - 1u;
        stats_.estimated_f1_wrong_path_blocks += wrong_blocks;
        stats_.estimated_f1_wrong_path_slots += 2u * wrong_blocks;
    }

    auto delay = 1u;
    const bool penalized_backend = control.backend_direction_wrong ||
        (config_.backend_policy == FdqBackendPolicy::AllControl &&
         control.backend_target_wrong);
    if (penalized_backend || control.system_redirect) {
        delay = config_.backend_refill_cycles;
    } else if (control.f1_correction) {
        delay = config_.f1_refill_cycles;
    }
    next_arrival_cycle_ = arrival_cycle + delay;
}

void FdqScenarioModel::finish() {
    while (count_ != 0u || pending_correction_.has_value()) {
        step(nullptr, 0);
    }
}

FdqStudyModel::FdqStudyModel(std::vector<FdqScenarioConfig> scenarios) {
    scenarios_.reserve(scenarios.size());
    for (auto& scenario : scenarios) {
        scenarios_.emplace_back(std::move(scenario));
    }
}

FdqInstruction FdqStudyModel::decode_instruction(
    const CfiEvent& event, const FrontendDecision& decision) {
    return predecode(event, decision);
}

FdqPacketControl FdqStudyModel::control(
    const CfiEvent& event, const FrontendDecision& decision) {
    FdqPacketControl result;
    if (decision.valid) {
        result.f0_correction = decision.f0_correction;
        result.f1_correction = decision.f1_correction;
        result.backend_direction_wrong = decision.backend_direction_wrong;
        result.backend_target_wrong = decision.backend_target_wrong;
    } else if (event.next_pc != event.source_pc + 4u) {
        result.system_redirect = true;
    }
    return result;
}

bool FdqStudyModel::allows_same_block_successor(
    const CfiEvent& event, const FrontendDecision& decision) {
    if ((event.source_pc & 7u) != 0u ||
        event.next_pc != event.source_pc + 4u) {
        return false;
    }
    if (!decision.valid) {
        return true;
    }
    const auto sequential = event.source_pc + 4u;
    // A taken decision at any steering stage either kills slot 1 or later
    // invalidates it, so the architectural successor must be refetched.
    return decision.stage1_next == sequential &&
           decision.f0_next == sequential &&
           decision.f1_next == sequential;
}

void FdqStudyModel::finalize_pending() {
    if (pending_count_ == 0u) {
        return;
    }
    for (auto& scenario : scenarios_) {
        scenario.submit(pending_, pending_count_, pending_control_);
    }
    pending_count_ = 0u;
    pending_allows_successor_ = false;
    pending_control_ = {};
}

void FdqStudyModel::observe(const CfiEvent& event,
                            const FrontendDecision& decision) {
    const auto instruction = decode_instruction(event, decision);
    const auto item_control = control(event, decision);
    const bool append = pending_count_ == 1u && pending_allows_successor_ &&
                        event.source_pc == pending_[0].pc + 4u;
    if (!append) {
        finalize_pending();
    }
    pending_[pending_count_++] = instruction;
    pending_control_.f0_correction |= item_control.f0_correction;
    pending_control_.f1_correction |= item_control.f1_correction;
    pending_control_.backend_direction_wrong |=
        item_control.backend_direction_wrong;
    pending_control_.backend_target_wrong |= item_control.backend_target_wrong;
    pending_control_.system_redirect |= item_control.system_redirect;
    pending_allows_successor_ =
        pending_count_ == 1u && allows_same_block_successor(event, decision);
    if (pending_count_ == 2u || !pending_allows_successor_) {
        finalize_pending();
    }
}

void FdqStudyModel::finish() {
    finalize_pending();
    for (auto& scenario : scenarios_) {
        scenario.finish();
    }
}

std::vector<FdqScenarioConfig> make_fdq_scenarios(
    const std::uint32_t calibrated_consumer_stall_ppm) {
    std::vector<FdqScenarioConfig> result{
        {"D8_RTLPAIR_F1R1_B6_DIR", 8, 1, 6,
         FdqConsumePolicy::RtlPairing,
         FdqBackendPolicy::BranchDirectionOnly},
        {"D8_RTLPAIR_F1R2_B6_DIR", 8, 2, 6,
         FdqConsumePolicy::RtlPairing,
         FdqBackendPolicy::BranchDirectionOnly},
        {"D8_RTLPAIR_F1R3_B6_DIR", 8, 3, 6,
         FdqConsumePolicy::RtlPairing,
         FdqBackendPolicy::BranchDirectionOnly},
        {"D8_DUALMAX_F1R2_B6_DIR", 8, 2, 6,
         FdqConsumePolicy::DualAlways,
         FdqBackendPolicy::BranchDirectionOnly},
        {"D8_RTLPAIR_F1R2_B4_DIR", 8, 2, 4,
         FdqConsumePolicy::RtlPairing,
         FdqBackendPolicy::BranchDirectionOnly},
        {"D8_RTLPAIR_F1R2_B6_ALL", 8, 2, 6,
         FdqConsumePolicy::RtlPairing,
         FdqBackendPolicy::AllControl},
    };
    if (calibrated_consumer_stall_ppm != 0u) {
        for (const auto refill : {1u, 2u, 3u}) {
            result.push_back({
                "D8_RTLPAIR_F1R" + std::to_string(refill) +
                    "_B6_DIR_CAL_EVEN",
                8, refill, 6, FdqConsumePolicy::RtlPairing,
                FdqBackendPolicy::BranchDirectionOnly,
                calibrated_consumer_stall_ppm, 1});
        }
        result.push_back({
            "D8_RTLPAIR_F1R2_B6_DIR_CAL_BURST8",
            8, 2, 6, FdqConsumePolicy::RtlPairing,
            FdqBackendPolicy::BranchDirectionOnly,
            calibrated_consumer_stall_ppm, 8});
        result.push_back({
            "D4_RTLPAIR_F1R2_B6_DIR_CAL_EVEN",
            4, 2, 6, FdqConsumePolicy::RtlPairing,
            FdqBackendPolicy::BranchDirectionOnly,
            calibrated_consumer_stall_ppm, 1});
        result.push_back({
            "D8_RTLPAIR_F1R2_B6_ALL_CAL_EVEN",
            8, 2, 6, FdqConsumePolicy::RtlPairing,
            FdqBackendPolicy::AllControl,
            calibrated_consumer_stall_ppm, 1});
        result.push_back({
            "D8_RTLPAIR_F1R2_B6_ALL_CAL_BURST8",
            8, 2, 6, FdqConsumePolicy::RtlPairing,
            FdqBackendPolicy::AllControl,
            calibrated_consumer_stall_ppm, 8});
    }
    return result;
}

const char* fdq_consume_policy_name(const FdqConsumePolicy policy) {
    return policy == FdqConsumePolicy::RtlPairing ? "RTL_PAIRING"
                                                   : "DUAL_ALWAYS";
}

const char* fdq_backend_policy_name(const FdqBackendPolicy policy) {
    return policy == FdqBackendPolicy::BranchDirectionOnly
               ? "BRANCH_DIRECTION_ONLY"
               : "ALL_CONTROL";
}

}  // namespace archsim
