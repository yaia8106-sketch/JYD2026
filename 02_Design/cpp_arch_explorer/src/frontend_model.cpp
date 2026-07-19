#include "frontend_model.hpp"

#include <algorithm>
#include <bit>
#include <stdexcept>
#include <utility>

namespace archsim {
namespace {

std::int32_t sign_extend(const std::uint32_t value, const unsigned bits) {
    const auto shift = 32u - bits;
    return static_cast<std::int32_t>(value << shift) >> shift;
}

std::uint32_t add_signed(const std::uint32_t value,
                         const std::int32_t offset) {
    return value + static_cast<std::uint32_t>(offset);
}

bool is_link_register(const std::uint32_t reg) {
    return reg == 1u || reg == 5u;
}

bool is_supported_abtb_type(const CfiClass type) {
    return type == CfiClass::Branch || type == CfiClass::Jal ||
           type == CfiClass::Call || type == CfiClass::Ret;
}

AbtbType to_abtb_type(const CfiClass type) {
    switch (type) {
        case CfiClass::Branch: return AbtbType::Branch;
        case CfiClass::Call: return AbtbType::Call;
        case CfiClass::Ret: return AbtbType::Ret;
        case CfiClass::Jal:
        case CfiClass::None:
        case CfiClass::IndirectJalr:
            return AbtbType::Jal;
    }
    return AbtbType::Jal;
}

std::uint32_t ceil_log2(const std::uint32_t value) {
    return value <= 1u ? 0u : std::bit_width(value - 1u);
}

}  // namespace

DecodedCfi decode_cfi(const std::uint32_t instruction,
                      const std::uint32_t pc) {
    DecodedCfi result;
    const auto opcode = instruction & 0x7fu;
    const auto rd = (instruction >> 7u) & 0x1fu;
    const auto rs1 = (instruction >> 15u) & 0x1fu;
    const auto i_imm = sign_extend(instruction >> 20u, 12u);

    if (opcode == 0x63u) {
        const auto bits = ((instruction >> 31u) << 12u) |
                          (((instruction >> 7u) & 1u) << 11u) |
                          (((instruction >> 25u) & 0x3fu) << 5u) |
                          (((instruction >> 8u) & 0xfu) << 1u);
        result.type = CfiClass::Branch;
        result.direct_target_valid = true;
        result.direct_target = add_signed(pc, sign_extend(bits, 13u));
        return result;
    }

    if (opcode == 0x6fu) {
        const auto bits = ((instruction >> 31u) << 20u) |
                          (((instruction >> 12u) & 0xffu) << 12u) |
                          (((instruction >> 20u) & 1u) << 11u) |
                          (((instruction >> 21u) & 0x3ffu) << 1u);
        result.type = is_link_register(rd) ? CfiClass::Call : CfiClass::Jal;
        result.direct_target_valid = true;
        result.direct_target = add_signed(pc, sign_extend(bits, 21u));
        result.return_address = pc + 4u;
        return result;
    }

    if (opcode == 0x67u && ((instruction >> 12u) & 7u) == 0u) {
        const bool is_ret = rd == 0u && is_link_register(rs1) && i_imm == 0;
        if (is_ret) {
            result.type = CfiClass::Ret;
        } else if (is_link_register(rd)) {
            result.type = CfiClass::Call;
        } else {
            result.type = CfiClass::IndirectJalr;
        }
        result.return_address = pc + 4u;
    }
    return result;
}

const char* cfi_class_name(const CfiClass type) {
    switch (type) {
        case CfiClass::None: return "NONE";
        case CfiClass::Branch: return "BRANCH";
        case CfiClass::Jal: return "JAL";
        case CfiClass::Call: return "CALL";
        case CfiClass::Ret: return "RET";
        case CfiClass::IndirectJalr: return "INDIRECT_JALR";
    }
    return "UNKNOWN";
}

std::uint32_t TraceProfiler::instruction_at(const std::uint32_t pc) const {
    if (pc < kIromBase || pc >= kIromBase + kIromBytes || (pc & 3u) != 0u) {
        return 0x0000'0013u;
    }
    const auto word = static_cast<std::size_t>((pc - kIromBase) >> 2u);
    return word < image_.irom.size() ? image_.irom[word] : 0x0000'0013u;
}

BlockContext TraceProfiler::observe(const CfiEvent& event) {
    const bool sequential_bank1 =
        previous_valid_ && (previous_.source_pc & 7u) == 0u &&
        previous_.next_pc == previous_.source_pc + 4u &&
        event.source_pc == previous_.source_pc + 4u;
    const bool new_block = !sequential_bank1;

    if (new_block) {
        current_ = {};
        current_.block_id = next_block_id_++;
        current_.start_pc = event.source_pc;
        current_.block_pc = event.source_pc & ~7u;
        current_.slots[0] = decode_cfi(
            instruction_at(current_.block_pc), current_.block_pc);
        current_.slots[1] = decode_cfi(
            instruction_at(current_.block_pc + 4u), current_.block_pc + 4u);

        const bool bank0_eligible = (event.source_pc & 4u) == 0u;
        const bool slot0_cfi = bank0_eligible &&
                               current_.slots[0].type != CfiClass::None;
        const bool slot1_cfi = current_.slots[1].type != CfiClass::None;
        current_.eligible_cfis = static_cast<std::uint8_t>(slot0_cfi) +
                                 static_cast<std::uint8_t>(slot1_cfi);

        ++stats_.blocks;
        stats_.start_bank1 += static_cast<std::uint64_t>(!bank0_eligible);
        ++stats_.blocks_by_cfi_count[current_.eligible_cfis];
        if (current_.eligible_cfis == 2u) {
            const auto first = static_cast<std::size_t>(current_.slots[0].type);
            const auto second = static_cast<std::size_t>(current_.slots[1].type);
            ++stats_.pair_classes[first * 6u + second];
        }
    }

    BlockContext result = current_;
    result.new_block = new_block;
    result.current_is_first_cfi = false;
    result.current_is_second_cfi = false;

    const auto current_decoded = decode_cfi(event.instruction, event.source_pc);
    if (current_decoded.type != CfiClass::None) {
        const bool start_bank1 = (current_.start_pc & 4u) != 0u;
        const bool bank0_cfi = !start_bank1 &&
                               current_.slots[0].type != CfiClass::None;
        if ((event.source_pc & 4u) == 0u || !bank0_cfi) {
            result.current_is_first_cfi = true;
            ++stats_.executed_first_cfi;
        } else {
            result.current_is_second_cfi = true;
            ++stats_.executed_second_cfi;
            if (current_decoded.type == CfiClass::Branch) {
                ++stats_.second_branch;
            } else if (current_decoded.type == CfiClass::Jal ||
                       current_decoded.type == CfiClass::Call) {
                ++stats_.second_jal_or_call;
            } else {
                ++stats_.second_ret_or_indirect;
            }
            if (previous_valid_ && previous_.kind == CfiKind::Branch &&
                !previous_.taken &&
                (previous_.source_pc & ~7u) == current_.block_pc) {
                ++stats_.older_branch_nt_then_second_cfi;
                stats_.older_branch_nt_then_second_branch +=
                    static_cast<std::uint64_t>(
                        current_decoded.type == CfiClass::Branch);
            }
        }
    }

    previous_ = event;
    previous_valid_ = true;
    return result;
}

AbtbModel::AbtbModel(const std::uint32_t update_delay_instructions)
    : update_delay_instructions_(update_delay_instructions) {}

AbtbPrediction AbtbModel::lookup(const std::uint32_t pc,
                                 const std::uint64_t instruction_ordinal) {
    apply_due(instruction_ordinal);
    const auto bank = static_cast<std::size_t>((pc >> 2u) & 1u);
    const auto block_pc = pc & ~7u;
    const auto set = static_cast<std::size_t>((block_pc >> 3u) & 0xfu);
    const auto tag = static_cast<std::uint8_t>((block_pc >> 7u) & 0x7fu);
    ++stats_.bank_lookups[bank];
    ++stats_.sets[bank][set].lookups;

    AbtbPrediction result;
    for (std::size_t way = 0; way < 2; ++way) {
        const auto& entry = entries_[bank][set][way];
        if (entry.valid && entry.tag == tag) {
            result.hit = true;
            result.way = static_cast<std::uint8_t>(way);
            result.type = entry.type;
            result.target = entry.target;
            ++stats_.bank_hits[bank];
            ++stats_.sets[bank][set].hits;
            lru_[bank][set] = static_cast<std::uint8_t>(!way);
            break;
        }
    }
    return result;
}

bool AbtbModel::update_qualified(const CfiEvent& event,
                                 const DecodedCfi& decoded) {
    if (decoded.type == CfiClass::Branch) {
        return event.taken;
    }
    return decoded.type == CfiClass::Jal || decoded.type == CfiClass::Call ||
           decoded.type == CfiClass::Ret;
}

AbtbType AbtbModel::update_type(const DecodedCfi& decoded) {
    return to_abtb_type(decoded.type);
}

void AbtbModel::resolve(const CfiEvent& event, const DecodedCfi& decoded,
                        const AbtbPrediction& prediction) {
    ++stats_.resolved_cfis;
    stats_.resolved_hits += static_cast<std::uint64_t>(prediction.hit);
    if (prediction.hit && is_supported_abtb_type(decoded.type)) {
        stats_.type_mismatches += static_cast<std::uint64_t>(
            prediction.type != update_type(decoded));
        if (decoded.type != CfiClass::Ret && event.taken) {
            stats_.target_mismatches += static_cast<std::uint64_t>(
                prediction.target != event.target);
        }
    }
    if (!update_qualified(event, decoded)) {
        return;
    }

    ++stats_.qualified_updates;
    pending_.push_back(PendingUpdate{
        event.instruction_ordinal + update_delay_instructions_,
        event.source_pc,
        prediction.hit,
        prediction.way,
        update_type(decoded),
        event.target,
    });
    if (update_delay_instructions_ == 0u) {
        apply_due(event.instruction_ordinal);
    }
}

void AbtbModel::apply_front() {
    if (pending_.empty()) {
        return;
    }
    const auto update = pending_.front();
    pending_.pop_front();
    const auto bank = static_cast<std::size_t>((update.pc >> 2u) & 1u);
    const auto block_pc = update.pc & ~7u;
    const auto set = static_cast<std::size_t>((block_pc >> 3u) & 0xfu);
    const auto tag = static_cast<std::uint8_t>((block_pc >> 7u) & 0x7fu);

    std::size_t way = update.prediction_way;
    if (update.prediction_hit) {
        const auto& old = entries_[bank][set][way];
        stats_.stale_hit_writes += static_cast<std::uint64_t>(
            !old.valid || old.tag != tag);
    } else if (!entries_[bank][set][0].valid) {
        way = 0;
    } else if (!entries_[bank][set][1].valid) {
        way = 1;
    } else {
        way = lru_[bank][set];
        ++stats_.sets[bank][set].replacements;
    }

    auto& entry = entries_[bank][set][way];
    if (!update.prediction_hit) {
        ++stats_.sets[bank][set].allocations;
    }
    entry.valid = true;
    entry.tag = tag;
    entry.type = update.type;
    entry.target = update.target;
    lru_[bank][set] = static_cast<std::uint8_t>(!way);
    ++stats_.bank_updates[bank];
    ++stats_.sets[bank][set].updates;
}

void AbtbModel::apply_due(const std::uint64_t instruction_ordinal) {
    while (!pending_.empty() &&
           pending_.front().due_instruction <= instruction_ordinal) {
        apply_front();
    }
}

void AbtbModel::resolution_barrier() {
    while (!pending_.empty()) {
        apply_front();
    }
}

RasModel::RasModel(RasConfig config) : config_(std::move(config)) {
    if (config_.policy != RasPolicy::None && config_.depth == 0u) {
        throw std::runtime_error("enabled RAS requires non-zero depth");
    }
}

void RasModel::apply_op(std::vector<std::uint32_t>& stack, const Op& op,
                        const bool count_events) {
    if (op.kind == OpKind::Push) {
        if (stack.size() == config_.depth) {
            stack.erase(stack.begin());
            if (count_events) {
                ++stats_.committed_overflows;
            }
        }
        stack.push_back(op.value);
        if (count_events) {
            stats_.maximum_committed_depth = std::max<std::uint64_t>(
                stats_.maximum_committed_depth, stack.size());
        }
    } else if (stack.empty()) {
        if (count_events) {
            ++stats_.committed_underflows;
        }
    } else {
        stack.pop_back();
    }
}

void RasModel::apply_front() {
    if (pending_.empty()) {
        return;
    }
    const auto op = pending_.front();
    pending_.pop_front();
    apply_op(committed_, op, true);
}

void RasModel::apply_due(const std::uint64_t instruction_ordinal) {
    while (!pending_.empty() &&
           pending_.front().due_instruction <= instruction_ordinal) {
        apply_front();
    }
}

std::vector<std::uint32_t> RasModel::effective_stack() {
    auto result = committed_;
    if (config_.policy == RasPolicy::Committed ||
        config_.policy == RasPolicy::None) {
        return result;
    }
    if (config_.policy == RasPolicy::PendingOverlay &&
        pending_.size() > config_.pending_capacity) {
        ++stats_.overlay_overflows;
        return result;
    }
    for (const auto& op : pending_) {
        apply_op(result, op, false);
    }
    return result;
}

RasPrediction RasModel::observe(const CfiEvent& event,
                                const DecodedCfi& decoded) {
    apply_due(event.instruction_ordinal);
    RasPrediction prediction;
    prediction.is_return = decoded.type == CfiClass::Ret;

    if (decoded.type == CfiClass::Call) {
        ++stats_.calls;
    } else if (decoded.type == CfiClass::Ret) {
        ++stats_.returns;
        const auto stack = effective_stack();
        prediction.valid = !stack.empty() && config_.policy != RasPolicy::None;
        if (prediction.valid) {
            prediction.target = stack.back();
            ++stats_.valid_predictions;
            if (prediction.target == event.target) {
                ++stats_.correct_predictions;
            } else {
                ++stats_.wrong_targets;
            }
        } else {
            ++stats_.invalid_predictions;
        }
    }

    if (config_.policy == RasPolicy::None) {
        return prediction;
    }
    if (decoded.type == CfiClass::Call) {
        pending_.push_back(Op{
            event.instruction_ordinal + config_.update_delay_instructions,
            OpKind::Push,
            decoded.return_address,
        });
    } else if (decoded.type == CfiClass::Ret) {
        pending_.push_back(Op{
            event.instruction_ordinal + config_.update_delay_instructions,
            OpKind::Pop,
            0u,
        });
    }
    stats_.maximum_pending_ops = std::max<std::uint64_t>(
        stats_.maximum_pending_ops, pending_.size());
    if (config_.update_delay_instructions == 0u) {
        apply_due(event.instruction_ordinal);
    }
    return prediction;
}

void RasModel::resolution_barrier() {
    while (!pending_.empty()) {
        apply_front();
    }
}

std::uint64_t RasModel::logical_storage_bits() const {
    if (config_.policy == RasPolicy::None) {
        return 0u;
    }
    const auto pointer_bits = ceil_log2(config_.depth + 1u);
    const auto overlay_bits = config_.policy == RasPolicy::PendingOverlay
                                  ? config_.pending_capacity * 33u
                                  : 0u;
    return static_cast<std::uint64_t>(config_.depth) * 32u + pointer_bits +
           overlay_bits;
}

FrontendModel::FrontendModel(FrontendConfig config)
    : config_(std::move(config)),
      fast_direction_(config_.fast_direction),
      tage_direction_(config_.enable_f1_tage
                          ? std::make_unique<DirectionPredictor>(
                                config_.tage_direction)
                          : nullptr),
      abtb_(config_.fast_direction.update_delay_instructions),
      ras_(config_.ras) {}

const DirectionStats& FrontendModel::tage_direction_stats() const {
    static const DirectionStats empty;
    return tage_direction_ ? tage_direction_->stats() : empty;
}

void FrontendModel::record_transition(const std::uint32_t before,
                                      const std::uint32_t after,
                                      const CfiEvent& event,
                                      const bool f1) {
    if (before == after) {
        return;
    }
    auto& corrections = f1 ? stats_.f1_corrections : stats_.f0_corrections;
    auto& helpful = f1 ? stats_.f1_helpful : stats_.f0_helpful;
    auto& harmful = f1 ? stats_.f1_harmful : stats_.f0_harmful;
    ++corrections;
    helpful += static_cast<std::uint64_t>(prediction_wrong(before, event) &&
                                          !prediction_wrong(after, event));
    harmful += static_cast<std::uint64_t>(!prediction_wrong(before, event) &&
                                          prediction_wrong(after, event));
}

FrontendDecision FrontendModel::observe(const CfiEvent& event,
                                        const BlockContext& block) {
    if (event.kind == CfiKind::None) {
        return {};
    }
    ++stats_.cfis;
    const auto decoded = decode_cfi(event.instruction, event.source_pc);
    const auto direct_target = decoded.direct_target_valid
                                   ? decoded.direct_target
                                   : event.target;
    if (event.kind == CfiKind::Branch) {
        ++stats_.branches;
    } else if (event.kind == CfiKind::Jal) {
        ++stats_.jal;
    } else {
        ++stats_.jalr;
    }
    stats_.calls += static_cast<std::uint64_t>(decoded.type == CfiClass::Call);
    stats_.returns += static_cast<std::uint64_t>(decoded.type == CfiClass::Ret);
    stats_.second_cfi_resolved +=
        static_cast<std::uint64_t>(block.current_is_second_cfi);

    const auto abtb_prediction = abtb_.lookup(
        event.source_pc, event.instruction_ordinal);
    stats_.abtb_hits += static_cast<std::uint64_t>(abtb_prediction.hit);
    stats_.abtb_misses += static_cast<std::uint64_t>(!abtb_prediction.hit);
    stats_.abtb_branch_hits += static_cast<std::uint64_t>(
        abtb_prediction.hit && event.kind == CfiKind::Branch);
    stats_.abtb_jal_hits += static_cast<std::uint64_t>(
        abtb_prediction.hit && event.kind == CfiKind::Jal);
    stats_.abtb_jalr_hits += static_cast<std::uint64_t>(
        abtb_prediction.hit && event.kind == CfiKind::Jalr);
    const bool actionable_abtb_miss = !abtb_prediction.hit &&
        (event.kind != CfiKind::Branch || event.taken);
    stats_.abtb_actionable_misses +=
        static_cast<std::uint64_t>(actionable_abtb_miss);
    stats_.abtb_nt_branch_misses += static_cast<std::uint64_t>(
        !abtb_prediction.hit && event.kind == CfiKind::Branch && !event.taken);

    DirectionPrediction fast_prediction;
    DirectionPrediction tage_prediction;
    if (event.kind == CfiKind::Branch) {
        fast_prediction = fast_direction_.observe(event, true, false);
    }
    const auto ras_prediction = ras_.observe(event, decoded);

    const auto sequential = fallthrough(event);
    auto stage1_next = sequential;
    if (abtb_prediction.hit) {
        if (abtb_prediction.type == AbtbType::Jal ||
            abtb_prediction.type == AbtbType::Call) {
            stage1_next = abtb_prediction.target;
        } else if (abtb_prediction.type == AbtbType::Branch &&
                   fast_prediction.final_taken) {
            stage1_next = abtb_prediction.target;
        }
        // The current RTL ties both RET-valid inputs low, so a RET ABTB hit
        // does not steer BP until a future RAS is integrated.
    }

    auto f0_next = stage1_next;
    if (config_.enable_f0_direct) {
        if (decoded.type == CfiClass::Branch) {
            // Direct B target decoding is independent of direction.  When the
            // optional F0 direction steering is disabled, preserve BP's
            // effective direction while still replacing an ABTB target with
            // the architecturally exact PC+immediate target.
            const bool f0_taken = config_.enable_f0_branch_direction
                                      ? fast_prediction.final_taken
                                      : stage1_next != sequential;
            f0_next = f0_taken ? direct_target : sequential;
        } else if (event.kind == CfiKind::Jal) {
            f0_next = direct_target;
        }
    }

    if (event.kind == CfiKind::Branch && tage_direction_) {
        const bool same_block_after_older_branch =
            block.current_is_second_cfi && previous_cfi_valid_ &&
            previous_branch_not_taken_ &&
            (previous_cfi_pc_ & ~7u) == (event.source_pc & ~7u);
        const bool tagged_access =
            config_.tagged_read_policy == TaggedReadPolicy::DualSlot ||
            !block.current_is_second_cfi ||
            (same_block_after_older_branch &&
             previous_branch_forced_refetch_);
        const auto external_base =
            config_.tage_direction.external_base_prediction
                ? std::optional<bool>{f0_next != sequential}
                : std::nullopt;
        tage_prediction = tage_direction_->observe(
            event, tagged_access, false, external_base);
        stats_.tagged_queries += static_cast<std::uint64_t>(tagged_access);
        stats_.tagged_suppressed_second_cfi +=
            static_cast<std::uint64_t>(!tagged_access);
        stats_.tagged_provider_hits += static_cast<std::uint64_t>(
            tagged_access && tage_prediction.provider >= 0);
        stats_.tagged_no_provider += static_cast<std::uint64_t>(
            tagged_access && tage_prediction.provider < 0);
        stats_.tagged_alternate_fallbacks += static_cast<std::uint64_t>(
            tage_prediction.provider >= 0 && tage_prediction.used_alternate);
    }

    auto f1_next = f0_next;
    if (event.kind == CfiKind::Branch && tage_direction_) {
        const bool tagged = tage_prediction.final_source >= 0;
        const bool strong = tage_prediction.final_counter <= -2 ||
                            tage_prediction.final_counter >= 1;
        const bool useful = tage_prediction.final_useful != 0u;
        bool allow_override = true;
        switch (config_.late_override_policy) {
            case LateOverridePolicy::Always:
                break;
            case LateOverridePolicy::TaggedStrong:
                allow_override = tagged && strong;
                break;
            case LateOverridePolicy::TaggedUseful:
                allow_override = tagged && useful;
                break;
            case LateOverridePolicy::TaggedStrongOrUseful:
                allow_override = tagged && (strong || useful);
                break;
            case LateOverridePolicy::TaggedStrongAndUseful:
                allow_override = tagged && strong && useful;
                break;
        }
        const auto tage_next = tage_prediction.final_taken
                                   ? direct_target
                                   : sequential;
        stats_.confidence_suppressed_overrides +=
            static_cast<std::uint64_t>(!allow_override &&
                                       tage_next != f0_next);
        if (allow_override) {
            f1_next = tage_next;
        }
    } else if (decoded.type == CfiClass::Ret && config_.enable_f1_ras &&
               ras_prediction.valid) {
        f1_next = ras_prediction.target;
    }

    stats_.stage1_wrong +=
        static_cast<std::uint64_t>(prediction_wrong(stage1_next, event));
    stats_.f0_wrong +=
        static_cast<std::uint64_t>(prediction_wrong(f0_next, event));
    stats_.f1_wrong +=
        static_cast<std::uint64_t>(prediction_wrong(f1_next, event));
    record_transition(stage1_next, f0_next, event, false);
    record_transition(f0_next, f1_next, event, true);

    const bool f1_correction = f0_next != f1_next;
    if (f1_correction) {
        stats_.f1_corrections_abtb_hit +=
            static_cast<std::uint64_t>(abtb_prediction.hit);
        stats_.f1_corrections_abtb_miss +=
            static_cast<std::uint64_t>(!abtb_prediction.hit);
        stats_.f1_corrections_nt_to_taken += static_cast<std::uint64_t>(
            f0_next == sequential && f1_next != sequential);
        stats_.f1_corrections_taken_to_nt += static_cast<std::uint64_t>(
            f0_next != sequential && f1_next == sequential);
        if (tage_prediction.final_source < 0) {
            ++stats_.f1_corrections_without_tagged_source;
        } else {
            const auto source = static_cast<std::size_t>(
                tage_prediction.final_source);
            ++stats_.f1_corrections_by_tagged_table[source];
            stats_.f1_helpful_by_tagged_table[source] +=
                static_cast<std::uint64_t>(prediction_wrong(f0_next, event) &&
                                           !prediction_wrong(f1_next, event));
            stats_.f1_harmful_by_tagged_table[source] +=
                static_cast<std::uint64_t>(!prediction_wrong(f0_next, event) &&
                                           prediction_wrong(f1_next, event));
        }
    }

    const bool backend_wrong = prediction_wrong(f1_next, event);
    const bool direction_wrong = backend_wrong &&
        event.kind == CfiKind::Branch &&
        ((f1_next != sequential) != event.taken);
    if (backend_wrong) {
        stats_.backend_direction_redirects +=
            static_cast<std::uint64_t>(direction_wrong);
        stats_.backend_target_redirects +=
            static_cast<std::uint64_t>(!direction_wrong);
    }
    if (event.kind == CfiKind::Branch && event.source_pc >= kIromBase &&
        event.source_pc < kIromBase + kIromBytes) {
        const auto word = static_cast<std::size_t>(
            (event.source_pc - kIromBase) >> 2u);
        ++stats_.branches_by_pc[word];
        stats_.backend_misses_by_pc[word] +=
            static_cast<std::uint64_t>(backend_wrong);
    }

    abtb_.resolve(event, decoded, abtb_prediction);
    const bool direction_barrier =
        (config_.direction_barrier_policy ==
             DirectionBarrierPolicy::AllBackendRedirects &&
         backend_wrong) ||
        (config_.direction_barrier_policy ==
             DirectionBarrierPolicy::BranchDirectionRedirects &&
         direction_wrong);
    if (direction_barrier) {
        fast_direction_.resolution_barrier();
        if (tage_direction_) {
            tage_direction_->resolution_barrier();
        }
    }
    if (backend_wrong) {
        abtb_.resolution_barrier();
        ras_.resolution_barrier();
    }

    previous_cfi_valid_ = true;
    previous_cfi_pc_ = event.source_pc;
    previous_branch_not_taken_ =
        event.kind == CfiKind::Branch && !event.taken;
    previous_branch_forced_refetch_ = previous_branch_not_taken_ &&
        (stage1_next != sequential || f0_next != sequential ||
         f1_next != sequential);

    return FrontendDecision{
        true,
        stage1_next,
        f0_next,
        f1_next,
        stage1_next != f0_next,
        f1_correction,
        backend_wrong,
        direction_wrong,
        backend_wrong && !direction_wrong,
        abtb_prediction.hit,
        tage_prediction,
    };
}

std::uint64_t FrontendModel::logical_storage_bits() const {
    auto result = fast_direction_.logical_storage_bits() +
                  AbtbModel::logical_storage_bits() +
                  ras_.logical_storage_bits();
    if (tage_direction_) {
        result += tage_direction_->logical_storage_bits();
        const bool shared_base =
            config_.fast_direction.family == DirectionFamily::Bimodal &&
            config_.fast_direction.base_entries ==
                config_.tage_direction.base_entries &&
            config_.fast_direction.base_index_mode ==
                config_.tage_direction.base_index_mode;
        if (shared_base &&
            !config_.tage_direction.external_base_prediction) {
            result -= 2u * config_.fast_direction.base_entries;
        }
    }
    return result;
}

std::vector<FrontendConfig> make_frontend_study_configs(
    const std::vector<std::uint32_t>& delays) {
    std::vector<FrontendConfig> configs;
    for (const auto delay : delays) {
        const auto direction = [&](const std::string& name,
                                   const DirectionFamily family,
                                   const std::uint32_t history) {
            DirectionConfig result;
            result.name = name;
            result.family = family;
            result.base_entries = 256;
            result.history_length = history;
            result.base_index_mode = family == DirectionFamily::Bimodal
                                         ? BaseIndexMode::Pc2BankedLowPc
                                         : BaseIndexMode::LowPc;
            result.update_delay_instructions = delay;
            result.mispredict_resolution_barrier = false;
            return result;
        };
        const auto tage = [&] {
            DirectionConfig result;
            result.name = "TAGE2_B256_T64_H4_8";
            result.family = DirectionFamily::Tage;
            result.base_entries = 256;
            result.base_index_mode = BaseIndexMode::Pc2BankedLowPc;
            result.tagged_tables = {{64, 4, 6}, {64, 8, 7}};
            result.update_delay_instructions = delay;
            result.mispredict_resolution_barrier = false;
            return result;
        };
        const auto tagged_only = [&](const std::uint32_t entries,
                                     const std::uint32_t short_history,
                                     const std::uint32_t long_history,
                                     const bool use_alternate,
                                     const std::uint32_t requested_short_tag = 0u) {
            DirectionConfig result;
            result.name = "TAGONLY_T" + std::to_string(entries) + "_H" +
                          std::to_string(short_history) + "_" +
                          std::to_string(long_history) +
                          (use_alternate ? "_ALT" : "_PROVIDER");
            result.family = DirectionFamily::Tage;
            // Kept only for PC-index diagnostics; no physical base storage is
            // counted or trained when external_base_prediction is true.
            result.base_entries = 256;
            result.base_index_mode = BaseIndexMode::Pc2BankedLowPc;
            const auto short_tag = requested_short_tag != 0u
                ? requested_short_tag
                : entries <= 32u ? 5u : entries <= 64u ? 6u : 7u;
            result.tagged_tables = {
                {entries, short_history, short_tag},
                {entries, long_history, short_tag + 1u},
            };
            result.update_delay_instructions = delay;
            result.mispredict_resolution_barrier = false;
            result.use_alternate_on_weak_new = use_alternate;
            result.external_base_prediction = true;
            return result;
        };
        const auto add = [&](const std::string& name,
                             const DirectionConfig& fast,
                             const bool f0_direct,
                             const bool f1_tage,
                             const TaggedReadPolicy read_policy,
                             const RasConfig& ras) {
            FrontendConfig config;
            config.name = name;
            config.fast_direction = fast;
            config.tage_direction = tage();
            config.enable_f0_direct = f0_direct;
            config.enable_f1_tage = f1_tage;
            config.enable_f1_ras = ras.policy != RasPolicy::None;
            config.tagged_read_policy = read_policy;
            config.ras = ras;
            configs.push_back(std::move(config));
        };

        const auto gshare = direction("GSHARE_256_H8", DirectionFamily::Gshare, 8);
        const auto bimodal = direction("BIMODAL_256_PC2BANK",
                                       DirectionFamily::Bimodal, 0);
        const auto gselect = direction("GSELECT_256_PC4_H4",
                                       DirectionFamily::Gselect, 4);
        const RasConfig no_ras{RasPolicy::None, 0, 0, delay};
        add("CURRENT_GSHARE", gshare, false, false,
            TaggedReadPolicy::DualSlot, no_ras);
        add("CURRENT_GSHARE_DIR_BARRIER", gshare, false, false,
            TaggedReadPolicy::DualSlot, no_ras);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::BranchDirectionRedirects;
        add("CURRENT_GSHARE_NO_BARRIER", gshare, false, false,
            TaggedReadPolicy::DualSlot, no_ras);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::NaturalInstructionDelay;
        add("GSHARE_F0_DIRECT", gshare, true, false,
            TaggedReadPolicy::DualSlot, no_ras);
        add("GSHARE_F0_JAL_ONLY", gshare, true, false,
            TaggedReadPolicy::DualSlot, no_ras);
        configs.back().enable_f0_branch_direction = false;
        add("BIMODAL_F0_DIRECT_BASE", bimodal, true, false,
            TaggedReadPolicy::DualSlot, no_ras);
        configs.back().enable_f0_branch_direction = false;
        add("GSHARE_TAGE2_DUAL", gshare, true, true,
            TaggedReadPolicy::DualSlot, no_ras);
        add("BIMODAL_TAGE2_DUAL", bimodal, true, true,
            TaggedReadPolicy::DualSlot, no_ras);
        add("BIMODAL_TAGE2_OLDEST", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::AllBackendRedirects;
        add("BIMODAL_TAGE2_OLDEST_DIR_BARRIER", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::BranchDirectionRedirects;
        add("BIMODAL_TAGE2_OLDEST_NO_BARRIER", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::NaturalInstructionDelay;
        add("GSHARE_F0_JAL_TAGE2_OLDEST", gshare, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);
        configs.back().enable_f0_branch_direction = false;
        add("BIMODAL_F0_JAL_TAGE2_OLDEST", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);
        configs.back().enable_f0_branch_direction = false;
        for (const auto& [suffix, policy] : {
                 std::pair{"STRONG", LateOverridePolicy::TaggedStrong},
                 std::pair{"USEFUL", LateOverridePolicy::TaggedUseful},
                 std::pair{"STRONG_OR_USEFUL",
                           LateOverridePolicy::TaggedStrongOrUseful},
                 std::pair{"STRONG_AND_USEFUL",
                           LateOverridePolicy::TaggedStrongAndUseful},
             }) {
            add("BIMODAL_TAGE2_OLDEST_" + std::string(suffix), bimodal,
                true, true, TaggedReadPolicy::OldestCfiOnly, no_ras);
            configs.back().late_override_policy = policy;
        }
        add("GSELECT_PC4_H4_TAGE2_OLDEST", gselect, true, true,
            TaggedReadPolicy::OldestCfiOnly, no_ras);

        const auto add_tag_only = [&](const std::string& name,
                                      const DirectionConfig& fast,
                                      const std::uint32_t entries,
                                      const std::uint32_t short_history,
                                      const std::uint32_t long_history,
                                      const bool use_alternate = true,
                                      const std::uint32_t short_tag = 0u) {
            add(name, fast, true, true, TaggedReadPolicy::OldestCfiOnly,
                no_ras);
            configs.back().enable_f0_branch_direction = false;
            configs.back().tage_direction = tagged_only(
                entries, short_history, long_history, use_alternate,
                short_tag);
        };

        // BP/F0 is the system base.  These F1 candidates contain only the two
        // tagged tables and preserve the BP/F0 next PC on a tag miss.
        for (const auto& [short_history, long_history] : {
                 std::pair{1u, 2u}, std::pair{2u, 4u},
                 std::pair{3u, 6u}, std::pair{4u, 8u},
                 std::pair{4u, 12u}, std::pair{4u, 16u},
                 std::pair{6u, 12u}, std::pair{8u, 16u}}) {
            add_tag_only(
                "BIMODAL_F0_DIRECT_TAGONLY_T64_H" +
                    std::to_string(short_history) + "_" +
                    std::to_string(long_history) + "_ALT",
                bimodal, 64, short_history, long_history, true);
        }
        for (const auto entries : {32u, 128u}) {
            add_tag_only(
                "BIMODAL_F0_DIRECT_TAGONLY_T" + std::to_string(entries) +
                    "_H4_8_ALT",
                bimodal, entries, 4, 8, true);
        }
        add_tag_only("BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_PROVIDER",
                     bimodal, 64, 4, 8, false);
        for (const auto& [suffix, policy] : {
                 std::pair{"STRONG", LateOverridePolicy::TaggedStrong},
                 std::pair{"USEFUL", LateOverridePolicy::TaggedUseful},
                 std::pair{"STRONG_OR_USEFUL",
                           LateOverridePolicy::TaggedStrongOrUseful},
                 std::pair{"STRONG_AND_USEFUL",
                           LateOverridePolicy::TaggedStrongAndUseful},
             }) {
            add_tag_only(
                "BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_ALT_" +
                    std::string(suffix),
                bimodal, 64, 4, 8, true);
            configs.back().late_override_policy = policy;
        }
        add_tag_only("GSHARE_F0_DIRECT_TAGONLY_T64_H4_8_ALT",
                     gshare, 64, 4, 8, true);
        add_tag_only("GSHARE_F0_DIRECT_TAGONLY_T64_H4_8_PROVIDER",
                     gshare, 64, 4, 8, false);
        for (const auto short_tag : {4u, 5u, 7u}) {
            add_tag_only(
                "BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_TAG" +
                    std::to_string(short_tag) + "_" +
                    std::to_string(short_tag + 1u) + "_ALT",
                bimodal, 64, 4, 8, true, short_tag);
        }

        add_tag_only("BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_DIR_BARRIER",
                     bimodal, 64, 4, 8, true);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::BranchDirectionRedirects;
        add_tag_only("BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_NO_BARRIER",
                     bimodal, 64, 4, 8, true);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::NaturalInstructionDelay;
        add_tag_only("BIMODAL_F0_DIRECT_TAGONLY_T64_H4_12_DIR_BARRIER",
                     bimodal, 64, 4, 12, true);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::BranchDirectionRedirects;
        add_tag_only("BIMODAL_F0_DIRECT_TAGONLY_T64_H4_12_NO_BARRIER",
                     bimodal, 64, 4, 12, true);
        configs.back().direction_barrier_policy =
            DirectionBarrierPolicy::NaturalInstructionDelay;

        add("BIMODAL_TAGE2_OLDEST_RAS_COMMIT_D4", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly,
            RasConfig{RasPolicy::Committed, 4, 0, delay});
        add("BIMODAL_TAGE2_OLDEST_RAS_COMMIT_D8", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly,
            RasConfig{RasPolicy::Committed, 8, 0, delay});
        for (const auto pending : {1u, 2u, 4u}) {
            add("BIMODAL_TAGE2_OLDEST_RAS_PENDING" +
                    std::to_string(pending) + "_D8",
                bimodal, true, true, TaggedReadPolicy::OldestCfiOnly,
                RasConfig{RasPolicy::PendingOverlay, 8, pending, delay});
        }
        add("BIMODAL_TAGE2_OLDEST_RAS_SPEC_D8", bimodal, true, true,
            TaggedReadPolicy::OldestCfiOnly,
            RasConfig{RasPolicy::SpeculativeUpperBound, 8, 0, delay});
    }
    return configs;
}

}  // namespace archsim
