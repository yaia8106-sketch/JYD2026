#include "backend_model.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <deque>
#include <iomanip>
#include <limits>
#include <numeric>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace archsim {
namespace {

enum class FuKind : std::uint8_t {
    Alu0,
    Alu1,
    Lsu,
    Mdu,
};

constexpr std::size_t fu_index(const FuKind fu) {
    return static_cast<std::size_t>(fu);
}

struct Instruction;
using InstPtr = std::shared_ptr<Instruction>;

struct Instruction {
    std::uint64_t id = 0;
    CfiEvent event{};
    BackendDecodedInstruction decoded{};
    std::array<std::uint8_t, 2> psrc{};
    std::array<bool, 2> source_used{};
    std::array<bool, 2> source_ready{};
    bool has_destination = false;
    std::uint8_t pdst = 0;
    std::uint8_t old_pdst = 0;
    bool issued = false;
    bool completed = false;
    bool branch_resolved = false;
    bool checkpoint_active = false;
    bool direction_mispredicted = false;
};

struct TraceEvent {
    CfiEvent event{};
    bool direction_mispredicted = false;
};

struct PredictorUpdate {
    std::uint64_t due_instruction = 0;
    std::uint8_t index = 0;
    std::uint8_t counter = 1;
    bool taken = false;
};

struct IssueQueue {
    std::uint32_t depth = 0;
    std::vector<InstPtr> entries;

    [[nodiscard]] bool full() const { return entries.size() >= depth; }

    void erase(const InstPtr& instruction) {
        const auto found = std::find(entries.begin(), entries.end(), instruction);
        if (found == entries.end()) {
            throw std::runtime_error("issued instruction is absent from its IQ");
        }
        entries.erase(found);
    }
};

struct IqAccumulator {
    std::uint64_t occupancy_sum = 0;
    std::uint32_t maximum = 0;
    std::uint64_t full_cycles = 0;
    std::uint64_t rename_stalls = 0;
    std::vector<std::uint64_t> histogram;

    explicit IqAccumulator(const std::uint32_t depth = 0)
        : histogram(static_cast<std::size_t>(depth) + 1u, 0u) {}

    void observe(const std::size_t occupancy, const std::uint32_t depth) {
        const auto bounded = static_cast<std::uint32_t>(
            std::min<std::size_t>(occupancy, depth));
        occupancy_sum += bounded;
        maximum = std::max(maximum, bounded);
        full_cycles += static_cast<std::uint64_t>(bounded == depth);
        ++histogram[bounded];
    }

    [[nodiscard]] std::uint32_t percentile(const double fraction) const {
        const auto total = std::accumulate(histogram.begin(), histogram.end(),
                                           std::uint64_t{0});
        if (total == 0u) {
            return 0;
        }
        const auto threshold = static_cast<std::uint64_t>(
            std::ceil(fraction * static_cast<double>(total)));
        std::uint64_t cumulative = 0;
        for (std::size_t index = 0; index < histogram.size(); ++index) {
            cumulative += histogram[index];
            if (cumulative >= threshold) {
                return static_cast<std::uint32_t>(index);
            }
        }
        return static_cast<std::uint32_t>(histogram.size() - 1u);
    }

    [[nodiscard]] BackendIqMetrics finalize(const std::uint64_t cycles) const {
        BackendIqMetrics result;
        result.average_occupancy = cycles == 0u
            ? 0.0
            : static_cast<double>(occupancy_sum) / static_cast<double>(cycles);
        result.maximum_occupancy = maximum;
        result.p95_occupancy = percentile(0.95);
        result.p99_occupancy = percentile(0.99);
        result.full_cycles = full_cycles;
        result.rename_stall_cycles = rename_stalls;
        return result;
    }
};

struct AluPipeline {
    std::vector<InstPtr> stages;
    InstPtr result_hold;
    bool can_issue = false;

    explicit AluPipeline(const std::uint32_t latency)
        : stages(std::max(1u, latency)) {}
};

struct SerialFu {
    InstPtr running;
    std::uint32_t remaining = 0;
    InstPtr result_hold;
    bool can_issue = false;
};

struct TimedOperation {
    InstPtr instruction;
    std::uint32_t remaining = 0;
    bool cache_miss = false;
};

struct LsuPipeline {
    std::deque<TimedOperation> inflight;
    InstPtr result_hold;
    std::uint64_t blocking_miss_id = 0;
    std::uint32_t issue_cooldown = 0;
};

struct StoreBufferModel {
    std::deque<std::uint32_t> drain_remaining;
};

struct ResultCandidate {
    FuKind fu = FuKind::Alu0;
    InstPtr instruction;
    bool from_hold = false;
};

struct IssueCandidate {
    FuKind fu = FuKind::Alu0;
    InstPtr instruction;
};

struct CacheLine {
    bool valid = false;
    std::uint64_t tag = 0;
    std::uint64_t last_use = 0;
};

class DcacheModel {
public:
    explicit DcacheModel(const BackendConfig& config)
        : sets_(config.dcache_sets), ways_(config.dcache_ways),
          line_bytes_(config.dcache_line_bytes),
          lines_(static_cast<std::size_t>(sets_) * ways_) {
        if (sets_ == 0u || ways_ == 0u || line_bytes_ == 0u ||
            (sets_ & (sets_ - 1u)) != 0u ||
            (line_bytes_ & (line_bytes_ - 1u)) != 0u) {
            throw std::runtime_error(
                "D-cache sets and line bytes must be nonzero powers of two");
        }
    }

    [[nodiscard]] bool load(const std::uint32_t address) {
        ++clock_;
        const auto [base, tag] = locate(address);
        for (std::uint32_t way = 0; way < ways_; ++way) {
            if (base[way].valid && base[way].tag == tag) {
                base[way].last_use = clock_;
                return true;
            }
        }
        std::uint32_t victim = 0;
        for (std::uint32_t way = 0; way < ways_; ++way) {
            if (!base[way].valid) {
                victim = way;
                break;
            }
            if (base[way].last_use < base[victim].last_use) {
                victim = way;
            }
        }
        base[victim] = CacheLine{true, tag, clock_};
        return false;
    }

    void store(const std::uint32_t address) {
        ++clock_;
        const auto [base, tag] = locate(address);
        for (std::uint32_t way = 0; way < ways_; ++way) {
            if (base[way].valid && base[way].tag == tag) {
                base[way].last_use = clock_;
                return;
            }
        }
        // The RTL cache is write-through and write-no-allocate.
    }

private:
    struct Location {
        CacheLine* base = nullptr;
        std::uint64_t tag = 0;
    };

    [[nodiscard]] Location locate(const std::uint32_t address) {
        const auto line_number = address / line_bytes_;
        const auto set = line_number & (sets_ - 1u);
        const auto tag = line_number / sets_;
        return {&lines_[static_cast<std::size_t>(set) * ways_], tag};
    }

    std::uint32_t sets_ = 0;
    std::uint32_t ways_ = 0;
    std::uint32_t line_bytes_ = 0;
    std::vector<CacheLine> lines_;
    std::uint64_t clock_ = 0;
};

bool is_cacheable_address(const std::uint32_t address) {
    return (address & 0xfffc'0000u) == 0x8010'0000u;
}

bool sources_ready(const InstPtr& instruction) {
    for (std::size_t source = 0; source < 2u; ++source) {
        if (instruction->source_used[source] &&
            !instruction->source_ready[source]) {
            return false;
        }
    }
    return true;
}

std::array<std::uint32_t, 2> read_demand(const InstPtr& instruction) {
    std::array<std::uint32_t, 2> demand{};
    for (std::size_t source = 0; source < 2u; ++source) {
        if (!instruction->source_used[source] ||
            instruction->psrc[source] == 0u) {
            continue;
        }
        ++demand[instruction->psrc[source] & 1u];
    }
    return demand;
}

bool older(const InstPtr& lhs, const InstPtr& rhs) {
    return lhs->id < rhs->id;
}

}  // namespace

BackendDecodedInstruction decode_backend_instruction(
    const std::uint32_t instruction) {
    BackendDecodedInstruction decoded;
    const auto opcode = instruction & 0x7fu;
    const auto funct3 = (instruction >> 12u) & 0x7u;
    const auto funct7 = (instruction >> 25u) & 0x7fu;
    decoded.rd = static_cast<std::uint8_t>((instruction >> 7u) & 0x1fu);
    decoded.rs1 = static_cast<std::uint8_t>((instruction >> 15u) & 0x1fu);
    decoded.rs2 = static_cast<std::uint8_t>((instruction >> 20u) & 0x1fu);

    switch (opcode) {
        case 0x37u:  // LUI
        case 0x17u:  // AUIPC
            decoded.writes_rd = true;
            break;
        case 0x6fu:  // JAL
            decoded.writes_rd = true;
            decoded.is_control = true;
            break;
        case 0x67u:  // JALR
            decoded.uses_rs1 = true;
            decoded.writes_rd = true;
            decoded.is_control = true;
            decoded.needs_checkpoint = true;
            break;
        case 0x63u:  // Conditional branch
            decoded.uses_rs1 = true;
            decoded.uses_rs2 = true;
            decoded.is_control = true;
            decoded.needs_checkpoint = true;
            break;
        case 0x03u:  // Load
            decoded.queue = BackendQueueKind::Ls;
            decoded.uses_rs1 = true;
            decoded.writes_rd = true;
            decoded.is_load = true;
            break;
        case 0x23u:  // Store
            decoded.queue = BackendQueueKind::Ls;
            decoded.uses_rs1 = true;
            decoded.uses_rs2 = true;
            decoded.is_store = true;
            break;
        case 0x13u:  // OP-IMM
            decoded.uses_rs1 = true;
            decoded.writes_rd = true;
            break;
        case 0x33u:  // OP / RV32M
            decoded.uses_rs1 = true;
            decoded.uses_rs2 = true;
            decoded.writes_rd = true;
            if (funct7 == 0x01u) {
                decoded.queue = BackendQueueKind::Mdu;
                decoded.is_div = funct3 >= 4u;
                decoded.is_mul = !decoded.is_div;
            }
            break;
        case 0x73u:  // SYSTEM / CSR
            if (funct3 != 0u) {
                const bool immediate = (funct3 & 0x4u) != 0u;
                decoded.uses_rs1 = !immediate && decoded.rs1 != 0u;
                decoded.writes_rd = true;
            }
            break;
        case 0x0fu:  // FENCE/FENCE.I
            break;
        default:
            throw std::runtime_error("backend model cannot decode instruction");
    }
    return decoded;
}

double BackendStats::ipc() const {
    return cycles == 0u
        ? 0.0
        : static_cast<double>(retired_instructions) /
              static_cast<double>(cycles);
}

const char* backend_branch_mode_name(const BackendBranchMode mode) {
    return mode == BackendBranchMode::Perfect ? "PERFECT" : "GSHARE";
}

class BackendModel::Impl {
public:
    explicit Impl(BackendConfig config)
        : config_(std::move(config)), int_iq_{config_.int_iq_depth, {}},
          ls_iq_{config_.ls_iq_depth, {}},
          mdu_iq_{config_.mdu_iq_depth, {}},
          int_acc_(config_.int_iq_depth), ls_acc_(config_.ls_iq_depth),
          mdu_acc_(config_.mdu_iq_depth),
          alu0_(config_.regread_latency + config_.alu_latency),
          alu1_(config_.regread_latency + config_.alu_latency),
          dcache_(config_) {
        validate_config();
        rat_.fill(0u);
        busy_.assign(config_.prf_entries, false);
        ready_.assign(config_.prf_entries, true);
        for (std::uint32_t reg = 0; reg < 32u; ++reg) {
            rat_[reg] = static_cast<std::uint8_t>(reg);
            busy_[reg] = true;
        }
        trace_pht_.fill(1u);
    }

    void feed(const CfiEvent& event) {
        while (pending_trace_.size() >= config_.frontend_buffer_entries) {
            tick();
        }
        apply_predictor_updates(event.instruction_ordinal);
        TraceEvent trace_event;
        trace_event.event = event;
        if (event.kind == CfiKind::Branch &&
            config_.branch_mode == BackendBranchMode::Gshare) {
            const auto index = static_cast<std::uint8_t>(
                ((event.source_pc >> 2u) ^ trace_ghr_) & 0xffu);
            const auto counter = trace_pht_[index];
            trace_event.direction_mispredicted =
                (counter >= 2u) != event.taken;
            predictor_updates_.push_back(
                {event.instruction_ordinal +
                     config_.branch_update_delay_instructions,
                 index, counter, event.taken});
        }
        pending_trace_.push_back(trace_event);
        ++stats_.trace_instructions;
    }

    void finish() {
        std::uint64_t stagnant_cycles = 0;
        auto previous_retired = stats_.retired_instructions;
        while (!quiescent()) {
            tick();
            if (stats_.retired_instructions == previous_retired) {
                ++stagnant_cycles;
            } else {
                stagnant_cycles = 0;
                previous_retired = stats_.retired_instructions;
            }
            if (stagnant_cycles > 1'000'000u) {
                throw std::runtime_error(
                    "backend model made no retirement progress for 1M cycles");
            }
        }
        stats_.drained = true;
        stats_.int_iq = int_acc_.finalize(stats_.cycles);
        stats_.ls_iq = ls_acc_.finalize(stats_.cycles);
        stats_.mdu_iq = mdu_acc_.finalize(stats_.cycles);
    }

    [[nodiscard]] const BackendConfig& config() const { return config_; }
    [[nodiscard]] const BackendStats& stats() const { return stats_; }

private:
    void validate_config() const {
        if (config_.int_iq_depth == 0u || config_.ls_iq_depth == 0u ||
            config_.mdu_iq_depth == 0u) {
            throw std::runtime_error("IQ depths must be nonzero");
        }
        if (config_.prf_entries != 64u || config_.rob_depth == 0u) {
            throw std::runtime_error(
                "this backend model currently requires PRF=64 and nonzero ROB");
        }
        if (config_.rename_width != 2u || config_.issue_width != 2u ||
            config_.commit_width != 2u ||
            config_.prf_reads_per_bank != 2u) {
            throw std::runtime_error(
                "this backend model currently implements rename/issue/commit=2 "
                "and two PRF reads per bank");
        }
        if (config_.frontend_buffer_entries < 2u || config_.checkpoints == 0u ||
            config_.checkpoints_per_cycle == 0u ||
            config_.lsu_hit_initiation_interval == 0u ||
            config_.store_buffer_entries == 0u ||
            config_.store_drain_latency == 0u) {
            throw std::runtime_error("invalid frontend/checkpoint configuration");
        }
        if (config_.load_hit_latency == 0u ||
            config_.load_miss_latency < config_.load_hit_latency ||
            config_.store_latency == 0u) {
            throw std::runtime_error("invalid LSU latency configuration");
        }
    }

    void apply_predictor_updates(const std::uint64_t instruction_ordinal) {
        while (!predictor_updates_.empty() &&
               predictor_updates_.front().due_instruction <=
                   instruction_ordinal) {
            const auto update = predictor_updates_.front();
            predictor_updates_.pop_front();
            auto counter = update.counter;
            if (update.taken) {
                counter = static_cast<std::uint8_t>(
                    std::min(3u, static_cast<unsigned>(counter) + 1u));
            } else if (counter != 0u) {
                --counter;
            }
            trace_pht_[update.index] = counter;
            trace_ghr_ = static_cast<std::uint8_t>(
                (trace_ghr_ << 1u) | update.taken);
        }
    }

    [[nodiscard]] bool quiescent() const {
        const auto alu_empty = [](const AluPipeline& pipe) {
            return !pipe.result_hold &&
                   std::none_of(pipe.stages.begin(), pipe.stages.end(),
                                [](const InstPtr& item) { return bool(item); });
        };
        const auto serial_empty = [](const SerialFu& fu) {
            return !fu.running && !fu.result_hold;
        };
        const auto lsu_empty = lsu_.inflight.empty() && !lsu_.result_hold;
        return pending_trace_.empty() && rob_.empty() &&
               int_iq_.entries.empty() && ls_iq_.entries.empty() &&
               mdu_iq_.entries.empty() && alu_empty(alu0_) &&
               alu_empty(alu1_) && lsu_empty && serial_empty(mdu_) &&
               store_buffer_.drain_remaining.empty() && !bank_wb_[0] &&
               !bank_wb_[1];
    }

    void tick() {
        ++stats_.cycles;
        commit();
        write_prf();
        if (lsu_.issue_cooldown != 0u) {
            --lsu_.issue_cooldown;
        }
        for (auto& operation : lsu_.inflight) {
            if (operation.remaining != 0u) {
                --operation.remaining;
            }
            if (operation.cache_miss && operation.remaining == 0u &&
                lsu_.blocking_miss_id == operation.instruction->id) {
                lsu_.blocking_miss_id = 0u;
            }
        }
        if (!store_buffer_.drain_remaining.empty()) {
            auto& remaining = store_buffer_.drain_remaining.front();
            if (remaining != 0u) {
                --remaining;
            }
            if (remaining == 0u) {
                store_buffer_.drain_remaining.pop_front();
            }
        }
        if (mdu_.running && mdu_.remaining != 0u) {
            --mdu_.remaining;
        }

        std::vector<std::uint8_t> wake_tags;
        progress_execution(wake_tags);
        issue();
        dispatch(wake_tags);

        int_acc_.observe(int_iq_.entries.size(), int_iq_.depth);
        ls_acc_.observe(ls_iq_.entries.size(), ls_iq_.depth);
        mdu_acc_.observe(mdu_iq_.entries.size(), mdu_iq_.depth);
        if (frontend_stall_cycles_ != 0u) {
            --frontend_stall_cycles_;
        }
    }

    void commit() {
        for (std::uint32_t count = 0; count < config_.commit_width; ++count) {
            if (rob_.empty() || !rob_.front()->completed) {
                break;
            }
            const auto instruction = rob_.front();
            if (instruction->has_destination) {
                if (instruction->old_pdst == 0u) {
                    throw std::runtime_error("attempted to free physical x0");
                }
                busy_[instruction->old_pdst] = false;
            }
            rob_.pop_front();
            ++stats_.retired_instructions;
        }
    }

    void write_prf() {
        for (auto& entry : bank_wb_) {
            if (!entry) {
                continue;
            }
            ready_[entry->pdst] = true;
            entry->completed = true;
            entry.reset();
        }
    }

    void resolve_branch(const InstPtr& instruction) {
        if (!instruction->decoded.is_control || instruction->branch_resolved) {
            return;
        }
        instruction->branch_resolved = true;
        if (instruction->checkpoint_active) {
            if (active_checkpoints_ == 0u) {
                throw std::runtime_error("checkpoint accounting underflow");
            }
            --active_checkpoints_;
            instruction->checkpoint_active = false;
        }
        if (instruction->direction_mispredicted &&
            mispredict_barrier_id_ == instruction->id) {
            mispredict_barrier_id_ = 0;
            frontend_stall_cycles_ = std::max(frontend_stall_cycles_,
                                              config_.redirect_penalty);
        }
    }

    void finish_without_writeback(const InstPtr& instruction) {
        resolve_branch(instruction);
        instruction->completed = true;
    }

    void wake_iqs(const std::uint8_t pdst) {
        const auto wake_queue = [&](IssueQueue& queue) {
            for (const auto& instruction : queue.entries) {
                for (std::size_t source = 0; source < 2u; ++source) {
                    if (instruction->source_used[source] &&
                        instruction->psrc[source] == pdst) {
                        instruction->source_ready[source] = true;
                    }
                }
            }
        };
        wake_queue(int_iq_);
        wake_queue(ls_iq_);
        wake_queue(mdu_iq_);
    }

    void remove_no_writeback_tail(AluPipeline& pipe) {
        auto& tail = pipe.stages.back();
        if (tail && !tail->has_destination) {
            finish_without_writeback(tail);
            tail.reset();
        }
    }

    void remove_no_writeback_serial(SerialFu& fu) {
        if (fu.running && fu.remaining == 0u &&
            !fu.running->has_destination) {
            finish_without_writeback(fu.running);
            fu.running.reset();
        }
    }

    void remove_no_writeback_lsu() {
        for (auto iterator = lsu_.inflight.begin();
             iterator != lsu_.inflight.end();) {
            if (iterator->remaining == 0u &&
                !iterator->instruction->has_destination) {
                finish_without_writeback(iterator->instruction);
                iterator = lsu_.inflight.erase(iterator);
            } else {
                ++iterator;
            }
        }
    }

    [[nodiscard]] InstPtr oldest_completed_lsu_load() const {
        InstPtr result;
        for (const auto& operation : lsu_.inflight) {
            if (operation.remaining != 0u ||
                !operation.instruction->has_destination) {
                continue;
            }
            if (!result || older(operation.instruction, result)) {
                result = operation.instruction;
            }
        }
        return result;
    }

    void erase_lsu_operation(const InstPtr& instruction) {
        const auto found = std::find_if(
            lsu_.inflight.begin(), lsu_.inflight.end(),
            [&](const TimedOperation& operation) {
                return operation.instruction == instruction;
            });
        if (found == lsu_.inflight.end()) {
            throw std::runtime_error("LSU result is absent from its pipeline");
        }
        lsu_.inflight.erase(found);
    }

    void progress_execution(std::vector<std::uint8_t>& wake_tags) {
        remove_no_writeback_tail(alu0_);
        remove_no_writeback_tail(alu1_);
        remove_no_writeback_lsu();
        remove_no_writeback_serial(mdu_);

        const auto resolve_tail = [&](AluPipeline& pipe) {
            if (pipe.stages.back()) {
                resolve_branch(pipe.stages.back());
            }
        };
        resolve_tail(alu0_);
        resolve_tail(alu1_);
        if (mdu_.running && mdu_.remaining == 0u) {
            resolve_branch(mdu_.running);
        }

        std::vector<ResultCandidate> candidates;
        const auto add_alu_candidate = [&](const FuKind fu, AluPipeline& pipe) {
            if (pipe.result_hold) {
                candidates.push_back({fu, pipe.result_hold, true});
            } else if (pipe.stages.back()) {
                candidates.push_back({fu, pipe.stages.back(), false});
            }
        };
        const auto add_serial_candidate = [&](const FuKind fu, SerialFu& state) {
            if (state.result_hold) {
                candidates.push_back({fu, state.result_hold, true});
            } else if (state.running && state.remaining == 0u) {
                candidates.push_back({fu, state.running, false});
            }
        };
        add_alu_candidate(FuKind::Alu0, alu0_);
        add_alu_candidate(FuKind::Alu1, alu1_);
        const auto completed_lsu_load = oldest_completed_lsu_load();
        if (lsu_.result_hold) {
            candidates.push_back({FuKind::Lsu, lsu_.result_hold, true});
        } else if (completed_lsu_load) {
            candidates.push_back(
                {FuKind::Lsu, completed_lsu_load, false});
        }
        add_serial_candidate(FuKind::Mdu, mdu_);

        std::array<std::optional<ResultCandidate>, 2> winners;
        std::array<std::uint32_t, 2> requests{};
        for (const auto& candidate : candidates) {
            const auto bank = candidate.instruction->pdst & 1u;
            ++requests[bank];
            if (!winners[bank] ||
                older(candidate.instruction, winners[bank]->instruction)) {
                winners[bank] = candidate;
            }
        }
        stats_.wb_bank0_conflict_cycles += static_cast<std::uint64_t>(
            requests[0] > 1u);
        stats_.wb_bank1_conflict_cycles += static_cast<std::uint64_t>(
            requests[1] > 1u);

        std::array<bool, 4> accepted{};
        std::array<bool, 4> accepted_from_hold{};
        for (std::size_t bank = 0; bank < winners.size(); ++bank) {
            if (!winners[bank]) {
                continue;
            }
            const auto& winner = *winners[bank];
            accepted[fu_index(winner.fu)] = true;
            accepted_from_hold[fu_index(winner.fu)] = winner.from_hold;
            bank_wb_[bank] = winner.instruction;
            wake_tags.push_back(winner.instruction->pdst);
            wake_iqs(winner.instruction->pdst);
        }

        const auto account_hold = [&](const ResultCandidate& candidate) {
            if (accepted[fu_index(candidate.fu)]) {
                return;
            }
            switch (candidate.fu) {
                case FuKind::Alu0: ++stats_.alu0_result_hold_cycles; break;
                case FuKind::Alu1: ++stats_.alu1_result_hold_cycles; break;
                case FuKind::Lsu: ++stats_.lsu_result_hold_cycles; break;
                case FuKind::Mdu: ++stats_.mdu_result_hold_cycles; break;
            }
        };
        for (const auto& candidate : candidates) {
            account_hold(candidate);
        }

        const auto update_alu = [&](const FuKind fu, AluPipeline& pipe) {
            const bool had_hold = bool(pipe.result_hold);
            auto& tail = pipe.stages.back();
            if (pipe.result_hold) {
                if (accepted[fu_index(fu)] &&
                    accepted_from_hold[fu_index(fu)]) {
                    pipe.result_hold.reset();
                    if (tail) {
                        pipe.result_hold = tail;
                        tail.reset();
                    }
                }
            } else if (tail) {
                if (accepted[fu_index(fu)]) {
                    tail.reset();
                } else {
                    pipe.result_hold = tail;
                    tail.reset();
                }
            }

            for (std::size_t index = pipe.stages.size() - 1u; index > 0u;
                 --index) {
                if (!pipe.stages[index] && pipe.stages[index - 1u]) {
                    pipe.stages[index] = pipe.stages[index - 1u];
                    pipe.stages[index - 1u].reset();
                }
            }
            const bool unblocked_by_current_grant =
                had_hold && accepted[fu_index(fu)];
            pipe.can_issue = !pipe.stages.front() &&
                             !unblocked_by_current_grant;
        };

        const auto update_serial = [&](const FuKind fu, SerialFu& state) {
            const bool occupied_at_start = bool(state.result_hold) ||
                                           bool(state.running);
            if (state.result_hold) {
                if (accepted[fu_index(fu)] &&
                    accepted_from_hold[fu_index(fu)]) {
                    state.result_hold.reset();
                }
            } else if (state.running && state.remaining == 0u) {
                if (accepted[fu_index(fu)]) {
                    state.running.reset();
                } else {
                    state.result_hold = state.running;
                    state.running.reset();
                }
            }
            state.can_issue = !state.running && !state.result_hold &&
                              !occupied_at_start;
        };

        update_alu(FuKind::Alu0, alu0_);
        update_alu(FuKind::Alu1, alu1_);

        if (lsu_.result_hold) {
            if (accepted[fu_index(FuKind::Lsu)] &&
                accepted_from_hold[fu_index(FuKind::Lsu)]) {
                lsu_.result_hold.reset();
                if (completed_lsu_load) {
                    lsu_.result_hold = completed_lsu_load;
                    erase_lsu_operation(completed_lsu_load);
                }
            }
        } else if (completed_lsu_load) {
            if (accepted[fu_index(FuKind::Lsu)]) {
                erase_lsu_operation(completed_lsu_load);
            } else {
                lsu_.result_hold = completed_lsu_load;
                erase_lsu_operation(completed_lsu_load);
            }
        }
        update_serial(FuKind::Mdu, mdu_);
    }

    [[nodiscard]] InstPtr oldest_ready(const IssueQueue& queue) const {
        InstPtr result;
        for (const auto& instruction : queue.entries) {
            if (!sources_ready(instruction)) {
                continue;
            }
            if (!result || older(instruction, result)) {
                result = instruction;
            }
        }
        return result;
    }

    [[nodiscard]] InstPtr oldest_entry(const IssueQueue& queue) const {
        if (queue.entries.empty()) {
            return {};
        }
        return *std::min_element(queue.entries.begin(), queue.entries.end(),
                                 older);
    }

    [[nodiscard]] bool legal_pair(const IssueCandidate& lhs,
                                  const IssueCandidate& rhs) const {
        const auto lhs_reads = read_demand(lhs.instruction);
        const auto rhs_reads = read_demand(rhs.instruction);
        for (std::size_t bank = 0; bank < 2u; ++bank) {
            if (lhs_reads[bank] + rhs_reads[bank] >
                config_.prf_reads_per_bank) {
                return false;
            }
        }
        return true;
    }

    [[nodiscard]] std::size_t lsu_pipeline_capacity() const {
        return std::max<std::uint32_t>(
            1u, config_.regread_latency +
                    std::max(config_.load_hit_latency,
                             config_.store_latency));
    }

    [[nodiscard]] bool store_buffer_full_for(
        const InstPtr& instruction) const {
        return instruction->decoded.is_store &&
               is_cacheable_address(instruction->event.memory_address) &&
               store_buffer_.drain_remaining.size() >=
                   config_.store_buffer_entries;
    }

    [[nodiscard]] bool lsu_can_issue(const InstPtr& instruction) const {
        return lsu_.issue_cooldown == 0u &&
               lsu_.blocking_miss_id == 0u &&
               lsu_.inflight.size() < lsu_pipeline_capacity() &&
               !store_buffer_full_for(instruction);
    }

    void issue() {
        std::vector<IssueCandidate> candidates;
        std::vector<InstPtr> int_ready;
        for (const auto& instruction : int_iq_.entries) {
            if (sources_ready(instruction)) {
                int_ready.push_back(instruction);
            }
        }
        std::sort(int_ready.begin(), int_ready.end(), older);
        std::vector<FuKind> available_alus;
        if (alu0_.can_issue) {
            available_alus.push_back(FuKind::Alu0);
        }
        if (alu1_.can_issue) {
            available_alus.push_back(FuKind::Alu1);
        }
        if (!int_ready.empty() && available_alus.empty()) {
            ++stats_.int_fu_busy_cycles;
        }
        const auto int_candidates = std::min(int_ready.size(),
                                             available_alus.size());
        for (std::size_t index = 0; index < int_candidates; ++index) {
            candidates.push_back({available_alus[index], int_ready[index]});
        }

        const auto ls_oldest = oldest_entry(ls_iq_);
        if (ls_oldest && sources_ready(ls_oldest)) {
            if (lsu_can_issue(ls_oldest)) {
                candidates.push_back({FuKind::Lsu, ls_oldest});
            } else {
                ++stats_.lsu_busy_cycles;
                stats_.lsu_miss_blocked_cycles +=
                    static_cast<std::uint64_t>(
                        lsu_.blocking_miss_id != 0u);
                stats_.store_buffer_full_cycles +=
                    static_cast<std::uint64_t>(
                        store_buffer_full_for(ls_oldest));
            }
        }
        const auto mdu_oldest = oldest_entry(mdu_iq_);
        if (mdu_oldest && sources_ready(mdu_oldest)) {
            if (mdu_.can_issue) {
                candidates.push_back({FuKind::Mdu, mdu_oldest});
            } else {
                ++stats_.mdu_busy_cycles;
            }
        }

        std::sort(candidates.begin(), candidates.end(),
                  [](const IssueCandidate& lhs, const IssueCandidate& rhs) {
                      return older(lhs.instruction, rhs.instruction);
                  });
        std::vector<IssueCandidate> selected;
        if (!candidates.empty()) {
            std::optional<std::array<std::size_t, 2>> oldest_legal_pair;
            for (std::size_t first = 0; first < candidates.size(); ++first) {
                for (std::size_t second = first + 1u;
                     second < candidates.size(); ++second) {
                    if (legal_pair(candidates[first], candidates[second])) {
                        oldest_legal_pair = {{first, second}};
                        break;
                    }
                }
                if (oldest_legal_pair) {
                    break;
                }
            }
            if (oldest_legal_pair) {
                selected.push_back(candidates[(*oldest_legal_pair)[0]]);
                selected.push_back(candidates[(*oldest_legal_pair)[1]]);
            } else {
                selected.push_back(candidates.front());
            }
            if (candidates.size() > config_.issue_width) {
                ++stats_.global_issue_limit_cycles;
            }
            if (candidates.size() >= 2u && selected.size() == 1u) {
                ++stats_.prf_read_bank_conflict_cycles;
            }
        }

        switch (selected.size()) {
            case 0u: ++stats_.issue_zero_cycles; break;
            case 1u: ++stats_.issue_one_cycles; break;
            default: ++stats_.issue_two_cycles; break;
        }
        stats_.issued_instructions += selected.size();

        for (const auto& selection : selected) {
            const auto& instruction = selection.instruction;
            switch (instruction->decoded.queue) {
                case BackendQueueKind::Int: int_iq_.erase(instruction); break;
                case BackendQueueKind::Ls: ls_iq_.erase(instruction); break;
                case BackendQueueKind::Mdu: mdu_iq_.erase(instruction); break;
            }
            instruction->issued = true;
            switch (selection.fu) {
                case FuKind::Alu0:
                    if (alu0_.stages.front()) {
                        throw std::runtime_error("ALU0 input overwrite");
                    }
                    alu0_.stages.front() = instruction;
                    alu0_.can_issue = false;
                    break;
                case FuKind::Alu1:
                    if (alu1_.stages.front()) {
                        throw std::runtime_error("ALU1 input overwrite");
                    }
                    alu1_.stages.front() = instruction;
                    alu1_.can_issue = false;
                    break;
                case FuKind::Lsu: {
                    std::uint32_t operation_latency = config_.store_latency;
                    bool cache_miss = false;
                    if (instruction->decoded.is_load) {
                        const bool hit = !is_cacheable_address(
                                             instruction->event.memory_address) ||
                                         dcache_.load(
                                             instruction->event.memory_address);
                        stats_.load_hits += static_cast<std::uint64_t>(hit);
                        stats_.load_misses += static_cast<std::uint64_t>(!hit);
                        operation_latency = hit ? config_.load_hit_latency
                                                : config_.load_miss_latency;
                        cache_miss = !hit;
                    } else if (is_cacheable_address(
                                   instruction->event.memory_address)) {
                        dcache_.store(instruction->event.memory_address);
                        store_buffer_.drain_remaining.push_back(
                            config_.store_drain_latency);
                        stats_.store_buffer_max_occupancy = std::max(
                            stats_.store_buffer_max_occupancy,
                            static_cast<std::uint32_t>(
                                store_buffer_.drain_remaining.size()));
                    }
                    lsu_.inflight.push_back(
                        {instruction,
                         config_.regread_latency + operation_latency,
                         cache_miss});
                    stats_.lsu_max_inflight = std::max(
                        stats_.lsu_max_inflight,
                        static_cast<std::uint32_t>(lsu_.inflight.size()));
                    if (cache_miss) {
                        lsu_.blocking_miss_id = instruction->id;
                    }
                    lsu_.issue_cooldown =
                        config_.lsu_hit_initiation_interval;
                    break;
                }
                case FuKind::Mdu:
                    mdu_.running = instruction;
                    mdu_.remaining = config_.regread_latency +
                        (instruction->decoded.is_div ? config_.div_latency
                                                     : config_.mul_latency);
                    mdu_.can_issue = false;
                    break;
            }
        }
    }

    [[nodiscard]] IssueQueue& target_queue(const BackendQueueKind kind) {
        switch (kind) {
            case BackendQueueKind::Int: return int_iq_;
            case BackendQueueKind::Ls: return ls_iq_;
            case BackendQueueKind::Mdu: return mdu_iq_;
        }
        throw std::runtime_error("invalid IQ kind");
    }

    [[nodiscard]] IqAccumulator& target_accumulator(
        const BackendQueueKind kind) {
        switch (kind) {
            case BackendQueueKind::Int: return int_acc_;
            case BackendQueueKind::Ls: return ls_acc_;
            case BackendQueueKind::Mdu: return mdu_acc_;
        }
        throw std::runtime_error("invalid IQ kind");
    }

    [[nodiscard]] std::optional<std::uint8_t> find_free_preg(
        const std::array<bool, 2>& bank_used) const {
        for (std::uint32_t attempt = 0; attempt < 2u; ++attempt) {
            const auto bank = static_cast<std::uint32_t>(
                attempt == 0u ? allocation_bank_rr_ : 1u - allocation_bank_rr_);
            if (bank_used[bank]) {
                continue;
            }
            for (std::uint32_t preg = 1u; preg < config_.prf_entries; ++preg) {
                if ((preg & 1u) == bank && !busy_[preg]) {
                    return static_cast<std::uint8_t>(preg);
                }
            }
        }
        return std::nullopt;
    }

    [[nodiscard]] bool tag_ready(
        const std::uint8_t tag,
        const std::vector<std::uint8_t>& wake_tags) const {
        return tag == 0u || ready_[tag] ||
               std::find(wake_tags.begin(), wake_tags.end(), tag) !=
                   wake_tags.end();
    }

    void dispatch(const std::vector<std::uint8_t>& wake_tags) {
        if (pending_trace_.empty()) {
            return;
        }
        if (frontend_stall_cycles_ != 0u || mispredict_barrier_id_ != 0u) {
            ++stats_.branch_barrier_cycles;
            return;
        }

        std::array<bool, 2> allocation_bank_used{};
        std::uint32_t checkpoints_created = 0;
        for (std::uint32_t slot = 0;
             slot < config_.rename_width && !pending_trace_.empty(); ++slot) {
            const auto& trace_event = pending_trace_.front();
            const auto& event = trace_event.event;
            const auto decoded = decode_backend_instruction(event.instruction);
            auto& queue = target_queue(decoded.queue);
            if (queue.full()) {
                ++target_accumulator(decoded.queue).rename_stalls;
                break;
            }
            if (rob_.size() >= config_.rob_depth) {
                ++stats_.rob_full_stall_cycles;
                break;
            }
            if (decoded.needs_checkpoint &&
                (active_checkpoints_ >= config_.checkpoints ||
                 checkpoints_created >= config_.checkpoints_per_cycle)) {
                ++stats_.checkpoint_stall_cycles;
                break;
            }

            const bool has_destination = decoded.writes_rd && decoded.rd != 0u;
            std::optional<std::uint8_t> new_pdst;
            if (has_destination) {
                new_pdst = find_free_preg(allocation_bank_used);
                if (!new_pdst) {
                    ++stats_.prf_empty_stall_cycles;
                    break;
                }
            }

            auto instruction = std::make_shared<Instruction>();
            instruction->id = next_instruction_id_++;
            instruction->event = event;
            instruction->decoded = decoded;
            instruction->source_used = {decoded.uses_rs1 && decoded.rs1 != 0u,
                                        decoded.uses_rs2 && decoded.rs2 != 0u};
            instruction->psrc = {rat_[decoded.rs1], rat_[decoded.rs2]};
            for (std::size_t source = 0; source < 2u; ++source) {
                instruction->source_ready[source] =
                    !instruction->source_used[source] ||
                    tag_ready(instruction->psrc[source], wake_tags);
            }
            instruction->has_destination = has_destination;
            if (has_destination) {
                instruction->old_pdst = rat_[decoded.rd];
                instruction->pdst = *new_pdst;
                rat_[decoded.rd] = *new_pdst;
                busy_[*new_pdst] = true;
                ready_[*new_pdst] = false;
                const auto bank = *new_pdst & 1u;
                allocation_bank_used[bank] = true;
                allocation_bank_rr_ = static_cast<std::uint8_t>(1u - bank);
            }

            if (decoded.needs_checkpoint) {
                instruction->checkpoint_active = true;
                ++active_checkpoints_;
                ++checkpoints_created;
            }
            instruction->direction_mispredicted =
                trace_event.direction_mispredicted;

            rob_.push_back(instruction);
            queue.entries.push_back(instruction);
            pending_trace_.pop_front();
            ++stats_.dispatched_instructions;

            if (instruction->direction_mispredicted) {
                ++stats_.branch_mispredictions;
                mispredict_barrier_id_ = instruction->id;
                break;
            }
        }
    }

    BackendConfig config_;
    BackendStats stats_{};
    std::deque<TraceEvent> pending_trace_;
    std::deque<InstPtr> rob_;
    IssueQueue int_iq_;
    IssueQueue ls_iq_;
    IssueQueue mdu_iq_;
    IqAccumulator int_acc_;
    IqAccumulator ls_acc_;
    IqAccumulator mdu_acc_;
    AluPipeline alu0_;
    AluPipeline alu1_;
    LsuPipeline lsu_;
    SerialFu mdu_;
    StoreBufferModel store_buffer_;
    std::array<InstPtr, 2> bank_wb_{};
    std::array<std::uint8_t, 32> rat_{};
    std::vector<bool> busy_;
    std::vector<bool> ready_;
    std::uint8_t allocation_bank_rr_ = 0;
    std::uint64_t next_instruction_id_ = 1;
    std::uint32_t active_checkpoints_ = 0;
    std::uint64_t mispredict_barrier_id_ = 0;
    std::uint32_t frontend_stall_cycles_ = 0;
    std::array<std::uint8_t, 256> trace_pht_{};
    std::uint8_t trace_ghr_ = 0;
    std::deque<PredictorUpdate> predictor_updates_;
    DcacheModel dcache_;
};

BackendModel::BackendModel(BackendConfig config)
    : impl_(std::make_unique<Impl>(std::move(config))) {}

BackendModel::~BackendModel() = default;
BackendModel::BackendModel(BackendModel&&) noexcept = default;
BackendModel& BackendModel::operator=(BackendModel&&) noexcept = default;

void BackendModel::feed(const CfiEvent& event) { impl_->feed(event); }
void BackendModel::finish() { impl_->finish(); }
const BackendConfig& BackendModel::config() const { return impl_->config(); }
const BackendStats& BackendModel::stats() const { return impl_->stats(); }

std::string BackendModel::config_name() const {
    std::ostringstream stream;
    stream << "I" << config().int_iq_depth << "_L" << config().ls_iq_depth
           << "_M" << config().mdu_iq_depth << '_'
           << backend_branch_mode_name(config().branch_mode);
    return stream.str();
}

}  // namespace archsim
