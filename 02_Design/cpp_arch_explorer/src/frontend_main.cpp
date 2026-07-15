#include "frontend_model.hpp"
#include "rv32_sim.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace archsim {
namespace {

constexpr std::array kDefaultPrograms{
    "current", "src0", "src1", "src2", "new_without_Mext",
    "new_with_Mext",
};

struct Options {
    std::filesystem::path coe_root = "02_Design/coe/single_issue";
    std::filesystem::path output_dir =
        "02_Design/cpp_arch_explorer/results/frontend";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> delays{6u, 10u};
    std::vector<std::string> config_names;
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    unsigned jobs = std::clamp(std::thread::hardware_concurrency(), 1u, 16u);
};

struct ModelResult {
    FrontendConfig config;
    FrontendStats stats;
    DirectionStats fast_direction;
    DirectionStats tage_direction;
    AbtbStats abtb;
    RasStats ras;
    std::uint64_t logical_bits = 0;
};

struct ProgramResult {
    std::string name;
    bool completed = false;
    std::string error;
    ArchitecturalStats architectural;
    CfiBlockStats blocks;
    std::vector<ModelResult> models;
    double elapsed_seconds = 0.0;
};

std::mutex console_mutex;

std::vector<std::string> split(const std::string& text, const char delimiter) {
    std::vector<std::string> parts;
    std::stringstream stream(text);
    for (std::string part; std::getline(stream, part, delimiter);) {
        if (!part.empty()) {
            parts.push_back(part);
        }
    }
    return parts;
}

std::vector<std::uint32_t> parse_delays(const std::string& text) {
    std::vector<std::uint32_t> result;
    for (const auto& part : split(text, ',')) {
        const auto value = std::stoul(part, nullptr, 0);
        if (value >= 63u) {
            throw std::runtime_error("update delay must be below 63 instructions");
        }
        result.push_back(static_cast<std::uint32_t>(value));
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    if (result.empty()) {
        throw std::runtime_error("at least one delay is required");
    }
    return result;
}

void usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "  --coe-root PATH       Root containing single_issue COE directories\n"
        << "  --output-dir PATH     CSV output directory\n"
        << "  --programs A,B,...    Default: all six contest programs\n"
        << "  --delays 6,10         Prediction-to-update instruction delays\n"
        << "  --configs A,B,...     Exact frontend configuration-name filter\n"
        << "  --jobs N              Parallel programs, hard-capped at 16\n"
        << "  --max-instructions N  Truncated smoke run (0 = full)\n"
        << "  --progress N          Progress interval (0 = disabled)\n"
        << "  -h, --help            Show this help\n";
}

Options parse_options(const int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        const auto value = [&](const std::string& option) {
            if (index + 1 >= argc) {
                throw std::runtime_error(option + " requires a value");
            }
            return std::string(argv[++index]);
        };
        if (argument == "--coe-root") {
            options.coe_root = value(argument);
        } else if (argument == "--output-dir") {
            options.output_dir = value(argument);
        } else if (argument == "--programs") {
            options.programs = split(value(argument), ',');
        } else if (argument == "--delays") {
            options.delays = parse_delays(value(argument));
        } else if (argument == "--configs") {
            options.config_names = split(value(argument), ',');
        } else if (argument == "--jobs") {
            options.jobs = std::clamp(
                static_cast<unsigned>(std::stoul(value(argument))), 1u, 16u);
        } else if (argument == "--max-instructions") {
            options.max_instructions = std::stoull(value(argument));
        } else if (argument == "--progress") {
            options.progress_instructions = std::stoull(value(argument));
        } else if (argument == "-h" || argument == "--help") {
            usage(argv[0]);
            std::exit(0);
        } else {
            throw std::runtime_error("unknown option: " + argument);
        }
    }
    if (options.programs.empty()) {
        throw std::runtime_error("program list is empty");
    }
    return options;
}

double percentage(const std::uint64_t numerator,
                  const std::uint64_t denominator) {
    return denominator == 0u
               ? 0.0
               : 100.0 * static_cast<double>(numerator) /
                     static_cast<double>(denominator);
}

const char* read_policy_name(const TaggedReadPolicy policy) {
    return policy == TaggedReadPolicy::DualSlot ? "DUAL_SLOT"
                                                 : "OLDEST_CFI_ONLY";
}

const char* direction_barrier_name(const DirectionBarrierPolicy policy) {
    switch (policy) {
        case DirectionBarrierPolicy::AllBackendRedirects:
            return "ALL_BACKEND_REDIRECTS";
        case DirectionBarrierPolicy::BranchDirectionRedirects:
            return "BRANCH_DIRECTION_REDIRECTS";
        case DirectionBarrierPolicy::NaturalInstructionDelay:
            return "NATURAL_INSTRUCTION_DELAY";
    }
    return "UNKNOWN";
}

const char* late_override_name(const LateOverridePolicy policy) {
    switch (policy) {
        case LateOverridePolicy::Always: return "ALWAYS";
        case LateOverridePolicy::TaggedStrong: return "TAGGED_STRONG";
        case LateOverridePolicy::TaggedUseful: return "TAGGED_USEFUL";
        case LateOverridePolicy::TaggedStrongOrUseful:
            return "TAGGED_STRONG_OR_USEFUL";
        case LateOverridePolicy::TaggedStrongAndUseful:
            return "TAGGED_STRONG_AND_USEFUL";
    }
    return "UNKNOWN";
}

const char* ras_policy_name(const RasPolicy policy) {
    switch (policy) {
        case RasPolicy::None: return "NONE";
        case RasPolicy::Committed: return "COMMITTED";
        case RasPolicy::PendingOverlay: return "PENDING_OVERLAY";
        case RasPolicy::SpeculativeUpperBound: return "SPECULATIVE_UPPER";
    }
    return "UNKNOWN";
}

ProgramResult run_program(const Options& options, const std::string& name,
                          const std::vector<FrontendConfig>& configs) {
    ProgramResult result;
    result.name = name;
    const auto start = std::chrono::steady_clock::now();
    try {
        const auto image = load_program(options.coe_root, name);
        Rv32Machine machine(image);
        TraceProfiler profiler(image);
        std::vector<FrontendModel> models;
        models.reserve(configs.size());
        for (const auto& config : configs) {
            models.emplace_back(config);
        }

        auto next_progress = options.progress_instructions;
        while (!machine.reached_stop() &&
               (options.max_instructions == 0u ||
                machine.stats().retired_instructions < options.max_instructions)) {
            const auto event = machine.step();
            const auto block = profiler.observe(event);
            if (event.kind != CfiKind::None) {
                for (auto& model : models) {
                    model.observe(event, block);
                }
            }
            if (options.progress_instructions != 0u &&
                machine.stats().retired_instructions >= next_progress) {
                std::lock_guard lock(console_mutex);
                std::cerr << "[progress] " << name << " retired="
                          << machine.stats().retired_instructions << '\n';
                next_progress += options.progress_instructions;
            }
        }

        result.completed = machine.reached_stop();
        result.architectural = machine.stats();
        result.blocks = profiler.stats();
        for (const auto& model : models) {
            result.models.push_back(ModelResult{
                model.config(), model.stats(), model.fast_direction_stats(),
                model.tage_direction_stats(), model.abtb_stats(),
                model.ras_stats(), model.logical_storage_bits()});
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }
    result.elapsed_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

void add_stats(FrontendStats& total, const FrontendStats& stats) {
    total.cfis += stats.cfis;
    total.branches += stats.branches;
    total.jal += stats.jal;
    total.jalr += stats.jalr;
    total.calls += stats.calls;
    total.returns += stats.returns;
    total.abtb_hits += stats.abtb_hits;
    total.abtb_misses += stats.abtb_misses;
    total.abtb_branch_hits += stats.abtb_branch_hits;
    total.abtb_jal_hits += stats.abtb_jal_hits;
    total.abtb_jalr_hits += stats.abtb_jalr_hits;
    total.abtb_actionable_misses += stats.abtb_actionable_misses;
    total.abtb_nt_branch_misses += stats.abtb_nt_branch_misses;
    total.stage1_wrong += stats.stage1_wrong;
    total.f0_wrong += stats.f0_wrong;
    total.f1_wrong += stats.f1_wrong;
    total.f0_corrections += stats.f0_corrections;
    total.f0_helpful += stats.f0_helpful;
    total.f0_harmful += stats.f0_harmful;
    total.f1_corrections += stats.f1_corrections;
    total.f1_helpful += stats.f1_helpful;
    total.f1_harmful += stats.f1_harmful;
    total.backend_direction_redirects += stats.backend_direction_redirects;
    total.backend_target_redirects += stats.backend_target_redirects;
    total.tagged_queries += stats.tagged_queries;
    total.tagged_suppressed_second_cfi +=
        stats.tagged_suppressed_second_cfi;
    total.confidence_suppressed_overrides +=
        stats.confidence_suppressed_overrides;
    total.tagged_provider_hits += stats.tagged_provider_hits;
    total.tagged_no_provider += stats.tagged_no_provider;
    total.tagged_alternate_fallbacks += stats.tagged_alternate_fallbacks;
    total.f1_corrections_abtb_hit += stats.f1_corrections_abtb_hit;
    total.f1_corrections_abtb_miss += stats.f1_corrections_abtb_miss;
    total.f1_corrections_nt_to_taken += stats.f1_corrections_nt_to_taken;
    total.f1_corrections_taken_to_nt += stats.f1_corrections_taken_to_nt;
    total.f1_corrections_without_tagged_source +=
        stats.f1_corrections_without_tagged_source;
    for (std::size_t table = 0;
         table < total.f1_corrections_by_tagged_table.size(); ++table) {
        total.f1_corrections_by_tagged_table[table] +=
            stats.f1_corrections_by_tagged_table[table];
        total.f1_helpful_by_tagged_table[table] +=
            stats.f1_helpful_by_tagged_table[table];
        total.f1_harmful_by_tagged_table[table] +=
            stats.f1_harmful_by_tagged_table[table];
    }
    total.second_cfi_resolved += stats.second_cfi_resolved;
}

void add_ras(RasStats& total, const RasStats& stats) {
    total.calls += stats.calls;
    total.returns += stats.returns;
    total.valid_predictions += stats.valid_predictions;
    total.correct_predictions += stats.correct_predictions;
    total.wrong_targets += stats.wrong_targets;
    total.invalid_predictions += stats.invalid_predictions;
    total.committed_overflows += stats.committed_overflows;
    total.committed_underflows += stats.committed_underflows;
    total.overlay_overflows += stats.overlay_overflows;
    total.maximum_committed_depth = std::max(total.maximum_committed_depth,
                                             stats.maximum_committed_depth);
    total.maximum_pending_ops = std::max(total.maximum_pending_ops,
                                         stats.maximum_pending_ops);
}

void add_direction(DirectionStats& total, const DirectionStats& stats) {
    total.branches += stats.branches;
    total.taken += stats.taken;
    total.predicted_taken += stats.predicted_taken;
    total.correct += stats.correct;
    total.mispredictions += stats.mispredictions;
    total.base_provider += stats.base_provider;
    total.base_provider_correct += stats.base_provider_correct;
    total.final_base_source += stats.final_base_source;
    total.final_base_correct += stats.final_base_correct;
    total.alternate_used += stats.alternate_used;
    total.alternate_correct += stats.alternate_correct;
    total.allocations += stats.allocations;
    total.allocation_failures += stats.allocation_failures;
    total.stale_provider_updates += stats.stale_provider_updates;
    for (std::size_t table = 0; table < total.tagged_provider.size(); ++table) {
        total.tagged_provider[table] += stats.tagged_provider[table];
        total.tagged_provider_correct[table] +=
            stats.tagged_provider_correct[table];
        total.final_tagged_source[table] += stats.final_tagged_source[table];
        total.final_tagged_correct[table] += stats.final_tagged_correct[table];
    }
}

void add_abtb(AbtbStats& total, const AbtbStats& stats) {
    total.resolved_cfis += stats.resolved_cfis;
    total.resolved_hits += stats.resolved_hits;
    total.type_mismatches += stats.type_mismatches;
    total.target_mismatches += stats.target_mismatches;
    total.qualified_updates += stats.qualified_updates;
    total.stale_hit_writes += stats.stale_hit_writes;
    for (std::size_t bank = 0; bank < 2; ++bank) {
        total.bank_lookups[bank] += stats.bank_lookups[bank];
        total.bank_hits[bank] += stats.bank_hits[bank];
        total.bank_updates[bank] += stats.bank_updates[bank];
        for (std::size_t set = 0; set < 16; ++set) {
            auto& destination = total.sets[bank][set];
            const auto& source = stats.sets[bank][set];
            destination.lookups += source.lookups;
            destination.hits += source.hits;
            destination.updates += source.updates;
            destination.allocations += source.allocations;
            destination.replacements += source.replacements;
        }
    }
}

void add_blocks(CfiBlockStats& total, const CfiBlockStats& stats) {
    total.blocks += stats.blocks;
    total.start_bank1 += stats.start_bank1;
    total.executed_first_cfi += stats.executed_first_cfi;
    total.executed_second_cfi += stats.executed_second_cfi;
    total.second_branch += stats.second_branch;
    total.second_jal_or_call += stats.second_jal_or_call;
    total.second_ret_or_indirect += stats.second_ret_or_indirect;
    total.older_branch_nt_then_second_cfi +=
        stats.older_branch_nt_then_second_cfi;
    total.older_branch_nt_then_second_branch +=
        stats.older_branch_nt_then_second_branch;
    for (std::size_t count = 0; count < 3; ++count) {
        total.blocks_by_cfi_count[count] += stats.blocks_by_cfi_count[count];
    }
    for (std::size_t pair = 0; pair < total.pair_classes.size(); ++pair) {
        total.pair_classes[pair] += stats.pair_classes[pair];
    }
}

void write_summary_header(std::ofstream& output) {
    output << "program,completed,retired_instructions,config,update_delay,"
              "fast_direction,f0_direct,f0_branch_direction,f1_tage,"
              "tagged_read_policy,"
              "direction_barrier_policy,late_override_policy,ras_policy,"
              "ras_depth,ras_pending_capacity,cfis,branches,jal,jalr,calls,returns,"
              "abtb_hits,abtb_misses,abtb_hit_pct,abtb_branch_hits,"
              "abtb_branch_hit_pct,abtb_jal_hits,abtb_jal_hit_pct,"
              "abtb_jalr_hits,abtb_jalr_hit_pct,abtb_actionable_misses,"
              "abtb_nt_branch_misses,stage1_wrong,f0_wrong,f1_wrong,"
              "stage1_accuracy_pct,f0_accuracy_pct,f1_accuracy_pct,f0_corrections,"
              "f0_helpful,f0_harmful,f1_corrections,f1_helpful,f1_harmful,"
              "backend_direction_redirects,backend_target_redirects,tagged_queries,"
              "tagged_suppressed_second_cfi,confidence_suppressed_overrides,"
              "tagged_provider_hits,tagged_no_provider,tagged_alternate_fallbacks,"
              "f1_corr_abtb_hit,f1_corr_abtb_miss,f1_corr_nt_to_taken,"
              "f1_corr_taken_to_nt,f1_corr_without_tagged_source,"
              "f1_corr_t0,f1_helpful_t0,f1_harmful_t0,"
              "f1_corr_t1,f1_helpful_t1,f1_harmful_t1,"
              "second_cfi_resolved,fast_dir_misses,"
              "tage_dir_misses,ras_valid,ras_correct,ras_wrong_target,ras_invalid,"
              "estimated_control_cycles_1_2_4,estimated_control_cycles_1_3_6,"
              "logical_storage_bits,elapsed_seconds\n";
}

void write_summary_row(std::ofstream& output, const std::string& program,
                       const bool completed, const std::uint64_t retired,
                       const ModelResult& model, const FrontendStats& stats,
                       const DirectionStats& fast,
                       const DirectionStats& tage, const RasStats& ras,
                       const double elapsed) {
    const auto backend = stats.backend_direction_redirects +
                         stats.backend_target_redirects;
    const auto penalty124 = stats.f0_corrections + 2u * stats.f1_corrections +
                            4u * backend;
    const auto penalty136 = stats.f0_corrections + 3u * stats.f1_corrections +
                            6u * backend;
    output << program << ',' << completed << ',' << retired << ','
           << model.config.name << ','
           << model.config.fast_direction.update_delay_instructions << ','
           << model.config.fast_direction.name << ','
           << model.config.enable_f0_direct << ','
           << model.config.enable_f0_branch_direction << ','
           << model.config.enable_f1_tage << ','
           << read_policy_name(model.config.tagged_read_policy) << ','
           << direction_barrier_name(
                  model.config.direction_barrier_policy) << ','
           << late_override_name(model.config.late_override_policy) << ','
           << ras_policy_name(model.config.ras.policy) << ','
           << model.config.ras.depth << ',' << model.config.ras.pending_capacity
           << ',' << stats.cfis << ',' << stats.branches << ',' << stats.jal
           << ',' << stats.jalr << ',' << stats.calls << ',' << stats.returns
           << ',' << stats.abtb_hits << ',' << stats.abtb_misses << ','
           << percentage(stats.abtb_hits, stats.cfis) << ','
           << stats.abtb_branch_hits << ','
           << percentage(stats.abtb_branch_hits, stats.branches) << ','
           << stats.abtb_jal_hits << ','
           << percentage(stats.abtb_jal_hits, stats.jal) << ','
           << stats.abtb_jalr_hits << ','
           << percentage(stats.abtb_jalr_hits, stats.jalr) << ','
           << stats.abtb_actionable_misses << ','
           << stats.abtb_nt_branch_misses << ','
           << stats.stage1_wrong << ',' << stats.f0_wrong << ',' << stats.f1_wrong
           << ',' << percentage(stats.cfis - stats.stage1_wrong, stats.cfis)
           << ',' << percentage(stats.cfis - stats.f0_wrong, stats.cfis)
           << ',' << percentage(stats.cfis - stats.f1_wrong, stats.cfis)
           << ',' << stats.f0_corrections << ',' << stats.f0_helpful << ','
           << stats.f0_harmful << ',' << stats.f1_corrections << ','
           << stats.f1_helpful << ',' << stats.f1_harmful << ','
           << stats.backend_direction_redirects << ','
           << stats.backend_target_redirects << ',' << stats.tagged_queries
           << ',' << stats.tagged_suppressed_second_cfi << ','
           << stats.confidence_suppressed_overrides << ','
           << stats.tagged_provider_hits << ',' << stats.tagged_no_provider
           << ',' << stats.tagged_alternate_fallbacks << ','
           << stats.f1_corrections_abtb_hit << ','
           << stats.f1_corrections_abtb_miss << ','
           << stats.f1_corrections_nt_to_taken << ','
           << stats.f1_corrections_taken_to_nt << ','
           << stats.f1_corrections_without_tagged_source << ','
           << stats.f1_corrections_by_tagged_table[0] << ','
           << stats.f1_helpful_by_tagged_table[0] << ','
           << stats.f1_harmful_by_tagged_table[0] << ','
           << stats.f1_corrections_by_tagged_table[1] << ','
           << stats.f1_helpful_by_tagged_table[1] << ','
           << stats.f1_harmful_by_tagged_table[1] << ','
           << stats.second_cfi_resolved << ',' << fast.mispredictions << ','
           << tage.mispredictions << ',' << ras.valid_predictions << ','
           << ras.correct_predictions << ',' << ras.wrong_targets << ','
           << ras.invalid_predictions << ',' << penalty124 << ',' << penalty136
           << ',' << model.logical_bits << ',' << elapsed << '\n';
}

void write_per_program(const std::filesystem::path& path,
                       const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << std::fixed << std::setprecision(6);
    write_summary_header(output);
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            write_summary_row(output, program.name, program.completed,
                              program.architectural.retired_instructions,
                              model, model.stats, model.fast_direction,
                              model.tage_direction, model.ras,
                              program.elapsed_seconds);
        }
    }
}

void write_aggregate(const std::filesystem::path& path,
                     const std::vector<ProgramResult>& results,
                     const std::vector<FrontendConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << std::fixed << std::setprecision(6);
    write_summary_header(output);
    for (std::size_t index = 0; index < configs.size(); ++index) {
        FrontendStats stats;
        DirectionStats fast;
        DirectionStats tage;
        RasStats ras;
        std::uint64_t retired = 0;
        unsigned completed = 0;
        for (const auto& program : results) {
            if (index >= program.models.size()) {
                continue;
            }
            const auto& model = program.models[index];
            add_stats(stats, model.stats);
            fast.branches += model.fast_direction.branches;
            fast.mispredictions += model.fast_direction.mispredictions;
            tage.branches += model.tage_direction.branches;
            tage.mispredictions += model.tage_direction.mispredictions;
            add_ras(ras, model.ras);
            retired += program.architectural.retired_instructions;
            completed += static_cast<unsigned>(program.completed);
        }
        const ModelResult model{configs[index], stats, fast, tage, {}, ras,
                                results.empty() ||
                                        index >= results.front().models.size()
                                    ? 0u
                                    : results.front().models[index].logical_bits};
        write_summary_row(output, "ALL", completed == results.size(), retired,
                          model, stats, fast, tage, ras, 0.0);
    }
}

void write_cfi_blocks(const std::filesystem::path& path,
                      const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,blocks,start_bank1,zero_cfi,one_cfi,two_cfi,"
              "two_cfi_pct,executed_first_cfi,executed_second_cfi,second_branch,"
              "second_jal_or_call,second_ret_or_indirect,"
              "older_branch_nt_then_second_cfi,"
              "older_branch_nt_then_second_branch\n";
    output << std::fixed << std::setprecision(6);
    CfiBlockStats total;
    const auto row = [&](const std::string& name, const CfiBlockStats& stats) {
        output << name << ',' << stats.blocks << ',' << stats.start_bank1 << ','
               << stats.blocks_by_cfi_count[0] << ','
               << stats.blocks_by_cfi_count[1] << ','
               << stats.blocks_by_cfi_count[2] << ','
               << percentage(stats.blocks_by_cfi_count[2], stats.blocks) << ','
               << stats.executed_first_cfi << ',' << stats.executed_second_cfi
               << ',' << stats.second_branch << ',' << stats.second_jal_or_call
               << ',' << stats.second_ret_or_indirect << ','
               << stats.older_branch_nt_then_second_cfi << ','
               << stats.older_branch_nt_then_second_branch << '\n';
    };
    for (const auto& program : results) {
        row(program.name, program.blocks);
        add_blocks(total, program.blocks);
    }
    row("ALL", total);
}

void write_cfi_pairs(const std::filesystem::path& path,
                     const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,first_type,second_type,blocks\n";
    CfiBlockStats total;
    for (const auto& program : results) {
        add_blocks(total, program.blocks);
        for (std::size_t first = 0; first < 6; ++first) {
            for (std::size_t second = 0; second < 6; ++second) {
                const auto count = program.blocks.pair_classes[first * 6u + second];
                if (count != 0u) {
                    output << program.name << ','
                           << cfi_class_name(static_cast<CfiClass>(first)) << ','
                           << cfi_class_name(static_cast<CfiClass>(second)) << ','
                           << count << '\n';
                }
            }
        }
    }
    for (std::size_t first = 0; first < 6; ++first) {
        for (std::size_t second = 0; second < 6; ++second) {
            const auto count = total.pair_classes[first * 6u + second];
            if (count != 0u) {
                output << "ALL," << cfi_class_name(static_cast<CfiClass>(first))
                       << ',' << cfi_class_name(static_cast<CfiClass>(second))
                       << ',' << count << '\n';
            }
        }
    }
}

void write_ras(const std::filesystem::path& path,
               const std::vector<ProgramResult>& results,
               const std::vector<FrontendConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,policy,depth,pending_capacity,calls,"
              "returns,valid,correct,wrong_target,invalid,target_accuracy_pct,"
              "committed_overflow,committed_underflow,overlay_overflow,"
              "max_committed_depth,max_pending_ops\n";
    output << std::fixed << std::setprecision(6);
    for (std::size_t index = 0; index < configs.size(); ++index) {
        RasStats total;
        const auto row = [&](const std::string& program, const RasStats& stats) {
            output << program << ',' << configs[index].name << ','
                   << configs[index].fast_direction.update_delay_instructions << ','
                   << ras_policy_name(configs[index].ras.policy) << ','
                   << configs[index].ras.depth << ','
                   << configs[index].ras.pending_capacity << ',' << stats.calls
                   << ',' << stats.returns << ',' << stats.valid_predictions
                   << ',' << stats.correct_predictions << ',' << stats.wrong_targets
                   << ',' << stats.invalid_predictions << ','
                   << percentage(stats.correct_predictions,
                                 stats.valid_predictions) << ','
                   << stats.committed_overflows << ','
                   << stats.committed_underflows << ',' << stats.overlay_overflows
                   << ',' << stats.maximum_committed_depth << ','
                   << stats.maximum_pending_ops << '\n';
        };
        for (const auto& program : results) {
            if (index < program.models.size()) {
                row(program.name, program.models[index].ras);
                add_ras(total, program.models[index].ras);
            }
        }
        row("ALL", total);
    }
}

void write_abtb_sets(const std::filesystem::path& path,
                     const std::vector<ProgramResult>& results,
                     const std::vector<FrontendConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,bank,set,lookups,hits,hit_pct,updates,"
              "allocations,replacements\n";
    output << std::fixed << std::setprecision(6);
    for (std::size_t index = 0; index < configs.size(); ++index) {
        AbtbStats total;
        const auto rows = [&](const std::string& program,
                              const AbtbStats& stats) {
            for (std::size_t bank = 0; bank < 2; ++bank) {
                for (std::size_t set = 0; set < 16; ++set) {
                    const auto& item = stats.sets[bank][set];
                    output << program << ',' << configs[index].name << ','
                           << configs[index].fast_direction.update_delay_instructions
                           << ',' << bank << ',' << set << ',' << item.lookups
                           << ',' << item.hits << ','
                           << percentage(item.hits, item.lookups) << ','
                           << item.updates << ',' << item.allocations << ','
                           << item.replacements << '\n';
                }
            }
        };
        for (const auto& program : results) {
            if (index < program.models.size()) {
                rows(program.name, program.models[index].abtb);
                add_abtb(total, program.models[index].abtb);
            }
        }
        rows("ALL", total);
    }
}

void write_abtb_summary(const std::filesystem::path& path,
                        const std::vector<ProgramResult>& results,
                        const std::vector<FrontendConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,resolved_cfis,resolved_hits,hit_pct,"
              "type_mismatches,target_mismatches,qualified_updates,"
              "stale_hit_writes,bank0_lookups,bank0_hits,bank0_hit_pct,"
              "bank0_updates,bank1_lookups,bank1_hits,bank1_hit_pct,"
              "bank1_updates\n";
    output << std::fixed << std::setprecision(6);
    for (std::size_t index = 0; index < configs.size(); ++index) {
        AbtbStats total;
        const auto row = [&](const std::string& program,
                             const AbtbStats& stats) {
            output << program << ',' << configs[index].name << ','
                   << configs[index].fast_direction.update_delay_instructions
                   << ',' << stats.resolved_cfis << ',' << stats.resolved_hits
                   << ',' << percentage(stats.resolved_hits,
                                         stats.resolved_cfis)
                   << ',' << stats.type_mismatches << ','
                   << stats.target_mismatches << ',' << stats.qualified_updates
                   << ',' << stats.stale_hit_writes << ','
                   << stats.bank_lookups[0] << ',' << stats.bank_hits[0] << ','
                   << percentage(stats.bank_hits[0], stats.bank_lookups[0])
                   << ',' << stats.bank_updates[0] << ','
                   << stats.bank_lookups[1] << ',' << stats.bank_hits[1] << ','
                   << percentage(stats.bank_hits[1], stats.bank_lookups[1])
                   << ',' << stats.bank_updates[1] << '\n';
        };
        for (const auto& program : results) {
            if (index < program.models.size()) {
                row(program.name, program.models[index].abtb);
                add_abtb(total, program.models[index].abtb);
            }
        }
        row("ALL", total);
    }
}

void write_per_pc(const std::filesystem::path& path,
                  const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,pc,branches,backend_misses,miss_pct\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            for (std::size_t word = 0; word < model.stats.branches_by_pc.size();
                 ++word) {
                const auto branches = model.stats.branches_by_pc[word];
                if (branches == 0u) {
                    continue;
                }
                const auto misses = model.stats.backend_misses_by_pc[word];
                output << program.name << ',' << model.config.name << ','
                       << model.config.fast_direction.update_delay_instructions
                       << ",0x" << std::hex
                       << kIromBase + static_cast<std::uint32_t>(word * 4u)
                       << std::dec << ',' << branches << ',' << misses << ','
                       << percentage(misses, branches) << '\n';
            }
        }
    }
}

void write_tagged_diagnostics(
    const std::filesystem::path& path,
    const std::vector<ProgramResult>& results,
    const std::vector<FrontendConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,external_base,use_alternate,branches,"
              "base_provider,base_provider_correct,base_provider_accuracy_pct,"
              "t0_provider,t0_provider_correct,t0_provider_accuracy_pct,"
              "t1_provider,t1_provider_correct,t1_provider_accuracy_pct,"
              "final_base,final_base_correct,final_base_accuracy_pct,"
              "final_t0,final_t0_correct,final_t0_accuracy_pct,"
              "final_t1,final_t1_correct,final_t1_accuracy_pct,"
              "alternate_used,alternate_correct,alternate_accuracy_pct,"
              "allocations,allocation_failures,stale_provider_updates,"
              "f1_corrections,f1_helpful,f1_harmful,"
              "f1_corr_without_tagged_source\n";
    output << std::fixed << std::setprecision(6);
    const auto row = [&](const std::string& program,
                         const FrontendConfig& config,
                         const DirectionStats& stats,
                         const FrontendStats& frontend) {
        output << program << ',' << config.name << ','
               << config.fast_direction.update_delay_instructions << ','
               << config.tage_direction.external_base_prediction << ','
               << config.tage_direction.use_alternate_on_weak_new << ','
               << stats.branches << ',' << stats.base_provider << ','
               << stats.base_provider_correct << ','
               << percentage(stats.base_provider_correct, stats.base_provider)
               << ',' << stats.tagged_provider[0] << ','
               << stats.tagged_provider_correct[0] << ','
               << percentage(stats.tagged_provider_correct[0],
                             stats.tagged_provider[0])
               << ',' << stats.tagged_provider[1] << ','
               << stats.tagged_provider_correct[1] << ','
               << percentage(stats.tagged_provider_correct[1],
                             stats.tagged_provider[1])
               << ',' << stats.final_base_source << ','
               << stats.final_base_correct << ','
               << percentage(stats.final_base_correct,
                             stats.final_base_source)
               << ',' << stats.final_tagged_source[0] << ','
               << stats.final_tagged_correct[0] << ','
               << percentage(stats.final_tagged_correct[0],
                             stats.final_tagged_source[0])
               << ',' << stats.final_tagged_source[1] << ','
               << stats.final_tagged_correct[1] << ','
               << percentage(stats.final_tagged_correct[1],
                             stats.final_tagged_source[1])
               << ',' << stats.alternate_used << ','
               << stats.alternate_correct << ','
               << percentage(stats.alternate_correct, stats.alternate_used)
               << ',' << stats.allocations << ','
               << stats.allocation_failures << ','
               << stats.stale_provider_updates << ','
               << frontend.f1_corrections << ',' << frontend.f1_helpful << ','
               << frontend.f1_harmful << ','
               << frontend.f1_corrections_without_tagged_source << '\n';
    };

    for (std::size_t index = 0; index < configs.size(); ++index) {
        DirectionStats total_direction;
        FrontendStats total_frontend;
        for (const auto& program : results) {
            if (index >= program.models.size()) {
                continue;
            }
            row(program.name, configs[index],
                program.models[index].tage_direction,
                program.models[index].stats);
            add_direction(total_direction,
                          program.models[index].tage_direction);
            add_stats(total_frontend, program.models[index].stats);
        }
        row("ALL", configs[index], total_direction, total_frontend);
    }
}

void write_result_files(const std::filesystem::path& output_dir,
                        const std::vector<ProgramResult>& results,
                        const std::vector<FrontendConfig>& configs) {
    std::filesystem::create_directories(output_dir);
    write_per_program(output_dir / "per_program.csv", results);
    write_aggregate(output_dir / "aggregate.csv", results, configs);
    write_cfi_blocks(output_dir / "cfi_blocks.csv", results);
    write_cfi_pairs(output_dir / "cfi_pairs.csv", results);
    write_ras(output_dir / "ras.csv", results, configs);
    write_abtb_summary(output_dir / "abtb_summary.csv", results, configs);
    write_abtb_sets(output_dir / "abtb_sets.csv", results, configs);
    write_per_pc(output_dir / "per_pc.csv", results);
    write_tagged_diagnostics(output_dir / "tagged_diagnostics.csv", results,
                             configs);
}

void validate_results(const std::vector<ProgramResult>& results) {
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            const auto& stats = model.stats;
            if (stats.abtb_hits + stats.abtb_misses != stats.cfis) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": ABTB hit invariant failed");
            }
            if (stats.abtb_branch_hits + stats.abtb_jal_hits +
                    stats.abtb_jalr_hits != stats.abtb_hits) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": ABTB type-hit invariant failed");
            }
            if (stats.abtb_actionable_misses +
                    stats.abtb_nt_branch_misses != stats.abtb_misses) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": ABTB miss-class invariant failed");
            }
            if (stats.backend_direction_redirects +
                    stats.backend_target_redirects != stats.f1_wrong) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": backend redirect invariant failed");
            }
            if (stats.f0_helpful > stats.f0_corrections ||
                stats.f1_helpful > stats.f1_corrections) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": correction invariant failed");
            }
            if (model.config.enable_f1_tage &&
                model.tage_direction.branches != stats.branches) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": TAGE branch invariant failed");
            }
            if (model.config.enable_f1_tage &&
                stats.tagged_provider_hits + stats.tagged_no_provider !=
                    stats.tagged_queries) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": tagged query invariant failed");
            }
            if (model.config.enable_f1_tage &&
                model.tage_direction.final_base_source +
                        model.tage_direction.final_tagged_source[0] +
                        model.tage_direction.final_tagged_source[1] !=
                    stats.branches) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": tagged final-source invariant failed");
            }
            if (model.config.tage_direction.external_base_prediction &&
                model.config.ras.policy == RasPolicy::None &&
                stats.f1_corrections_without_tagged_source != 0u) {
                throw std::runtime_error(program.name + "/" + model.config.name +
                                         ": tag-miss changed F1 next PC");
            }
        }
    }
}

void print_summary(const std::vector<ProgramResult>& results,
                   const std::vector<FrontendConfig>& configs) {
    for (const auto delay : {6u, 10u}) {
        std::cout << "delay=" << delay << " integrated frontend results:\n";
        for (std::size_t index = 0; index < configs.size(); ++index) {
            if (configs[index].fast_direction.update_delay_instructions != delay) {
                continue;
            }
            FrontendStats total;
            for (const auto& program : results) {
                if (index < program.models.size()) {
                    add_stats(total, program.models[index].stats);
                }
            }
            std::cout << "  " << configs[index].name
                      << " f1_wrong=" << total.f1_wrong
                      << " f0_corr=" << total.f0_corrections
                      << " f1_corr=" << total.f1_corrections << '\n';
        }
    }
}

}  // namespace
}  // namespace archsim

int main(int argc, char** argv) {
    using namespace archsim;
    try {
        const auto options = parse_options(argc, argv);
        auto configs = make_frontend_study_configs(options.delays);
        if (!options.config_names.empty()) {
            std::erase_if(configs, [&](const FrontendConfig& config) {
                return std::find(options.config_names.begin(),
                                 options.config_names.end(), config.name) ==
                       options.config_names.end();
            });
            if (configs.empty()) {
                throw std::runtime_error("--configs matched no frontend configuration");
            }
        }

        std::vector<ProgramResult> results(options.programs.size());
        std::atomic_size_t next{0};
        const auto workers_count = std::min<std::size_t>(
            options.jobs, options.programs.size());
        std::vector<std::thread> workers;
        for (std::size_t worker = 0; worker < workers_count; ++worker) {
            workers.emplace_back([&] {
                while (true) {
                    const auto index = next.fetch_add(1);
                    if (index >= options.programs.size()) {
                        return;
                    }
                    results[index] = run_program(options,
                                                 options.programs[index], configs);
                    if (results[index].error.empty()) {
                        try {
                            const std::vector<ProgramResult> checkpoint{
                                results[index]};
                            validate_results(checkpoint);
                            write_result_files(
                                options.output_dir / "checkpoints" /
                                    options.programs[index],
                                checkpoint, configs);
                        } catch (const std::exception& exception) {
                            results[index].error =
                                "checkpoint write failed: " +
                                std::string(exception.what());
                        }
                    }
                    std::lock_guard lock(console_mutex);
                    std::cerr << "[done] " << options.programs[index]
                              << " retired="
                              << results[index].architectural.retired_instructions
                              << " completed=" << results[index].completed
                              << " elapsed=" << results[index].elapsed_seconds
                              << "s\n";
                }
            });
        }
        for (auto& worker : workers) {
            worker.join();
        }
        for (const auto& result : results) {
            if (!result.error.empty()) {
                throw std::runtime_error(result.name + ": " + result.error);
            }
        }
        validate_results(results);

        write_result_files(options.output_dir, results, configs);
        print_summary(results, configs);
        if (options.max_instructions != 0u) {
            std::cout << "NOTE: max-instructions was set; results are incomplete.\n";
        }
        std::cout << "results: " << options.output_dir << '\n';
    } catch (const std::exception& exception) {
        std::cerr << "error: " << exception.what() << '\n';
        return 1;
    }
}
