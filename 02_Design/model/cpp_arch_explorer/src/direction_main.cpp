#include "direction_predictor.hpp"
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
    std::filesystem::path coe_root = "02_Design/verification/riscv/coe/single_issue";
    std::filesystem::path output_dir =
        "02_Design/model/cpp_arch_explorer/direction_results";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> delays{0u, 6u};
    std::vector<std::string> config_names;
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    unsigned jobs = std::clamp(std::thread::hardware_concurrency(), 1u, 16u);
    bool mispredict_resolution_barrier = true;
};

struct ModelResult {
    DirectionConfig config;
    DirectionStats stats;
    std::uint64_t logical_bits = 0;
    std::uint64_t two_read_bits = 0;
};

struct ProgramResult {
    std::string name;
    bool completed = false;
    std::string error;
    ArchitecturalStats architectural;
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
    std::vector<std::uint32_t> delays;
    for (const auto& part : split(text, ',')) {
        const auto delay = std::stoul(part, nullptr, 0);
        if (delay >= 63u) {
            throw std::runtime_error("update delay must be below 63 instructions");
        }
        delays.push_back(static_cast<std::uint32_t>(delay));
    }
    std::sort(delays.begin(), delays.end());
    delays.erase(std::unique(delays.begin(), delays.end()), delays.end());
    if (delays.empty()) {
        throw std::runtime_error("at least one update delay is required");
    }
    return delays;
}

void usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "  --coe-root PATH       Root containing single_issue COE directories\n"
        << "  --output-dir PATH     CSV output directory\n"
        << "  --programs A,B,...    Default: all six contest programs\n"
        << "  --delays 0,6          Dynamic-instruction update delays\n"
        << "  --configs A,B,...     Exact configuration-name filter\n"
        << "  --jobs N              Parallel programs, hard-capped at 16\n"
        << "  --max-instructions N  Truncated smoke run (0 = full)\n"
        << "  --progress N          Progress interval (0 = disabled)\n"
        << "  --no-mispredict-barrier  Keep fixed delay across redirects\n"
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
        } else if (argument == "--no-mispredict-barrier") {
            options.mispredict_resolution_barrier = false;
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

std::string family_name(const DirectionFamily family) {
    if (family == DirectionFamily::Bimodal) {
        return "BIMODAL";
    }
    if (family == DirectionFamily::Gshare) {
        return "GSHARE";
    }
    return family == DirectionFamily::Gselect ? "GSELECT" : "MINI_TAGE";
}

std::string base_index_name(const BaseIndexMode mode) {
    switch (mode) {
        case BaseIndexMode::LowPc: return "LOW_PC";
        case BaseIndexMode::FoldedPc: return "FOLDED_PC";
        case BaseIndexMode::Pc2BankedLowPc: return "PC2_BANKED_LOW_PC";
        case BaseIndexMode::Pc2BankedFoldedPc:
            return "PC2_BANKED_FOLDED_PC";
    }
    return "UNKNOWN";
}

double percentage(const std::uint64_t numerator,
                  const std::uint64_t denominator) {
    return denominator == 0u
               ? 0.0
               : 100.0 * static_cast<double>(numerator) /
                     static_cast<double>(denominator);
}

double per_kilo(const std::uint64_t numerator,
                const std::uint64_t denominator) {
    return denominator == 0u
               ? 0.0
               : 1000.0 * static_cast<double>(numerator) /
                     static_cast<double>(denominator);
}

ProgramResult run_program(const Options& options, const std::string& name,
                          const std::vector<DirectionConfig>& configs) {
    ProgramResult result;
    result.name = name;
    const auto start = std::chrono::steady_clock::now();
    try {
        const auto image = load_program(options.coe_root, name);
        Rv32Machine machine(image);
        std::vector<DirectionPredictor> predictors;
        predictors.reserve(configs.size());
        for (const auto& config : configs) {
            predictors.emplace_back(config);
        }

        auto next_progress = options.progress_instructions;
        while (!machine.reached_stop() &&
               (options.max_instructions == 0u ||
                machine.stats().retired_instructions < options.max_instructions)) {
            const auto event = machine.step();
            if (event.kind != CfiKind::None) {
                for (auto& predictor : predictors) {
                    predictor.observe(event);
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
        for (const auto& predictor : predictors) {
            result.models.push_back(ModelResult{
                predictor.config(), predictor.stats(),
                predictor.logical_storage_bits(),
                predictor.two_read_storage_bits()});
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }
    result.elapsed_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

void write_per_program(const std::filesystem::path& path,
                       const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,completed,error,retired_instructions,config,family,update_delay,"
              "mispredict_barrier,branches,taken,predicted_taken,correct,mispredictions,"
              "accuracy_pct,mispred_per_kinst,base_provider,tagged0_provider,"
              "tagged1_provider,tagged2_provider,allocations,allocation_failures,"
              "stale_provider_updates,logical_storage_bits,two_read_storage_bits,"
              "max_history,elapsed_seconds\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            const auto& stats = model.stats;
            output << program.name << ',' << program.completed << ",\""
                   << program.error << "\"," << program.architectural.retired_instructions
                   << ',' << model.config.name << ','
                   << family_name(model.config.family) << ','
                   << model.config.update_delay_instructions << ','
                   << model.config.mispredict_resolution_barrier << ','
                   << stats.branches << ',' << stats.taken << ','
                   << stats.predicted_taken << ',' << stats.correct << ','
                   << stats.mispredictions << ','
                   << percentage(stats.correct, stats.branches) << ','
                   << per_kilo(stats.mispredictions,
                               program.architectural.retired_instructions) << ','
                   << stats.base_provider << ',' << stats.tagged_provider[0] << ','
                   << stats.tagged_provider[1] << ',' << stats.tagged_provider[2]
                   << ',' << stats.allocations << ',' << stats.allocation_failures
                   << ',' << stats.stale_provider_updates << ',' << model.logical_bits
                   << ',' << model.two_read_bits << ','
                   << DirectionPredictor(model.config).maximum_history_length() << ','
                   << program.elapsed_seconds << '\n';
        }
    }
}

void write_aggregate(const std::filesystem::path& path,
                     const std::vector<ProgramResult>& results,
                     const std::vector<DirectionConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "config,family,update_delay,mispredict_barrier,programs_complete,"
              "programs_total,retired_instructions,branches,taken,predicted_taken,"
              "correct,mispredictions,accuracy_pct,mispred_per_kinst,"
              "worst_program_accuracy_pct,base_provider,tagged0_provider,"
              "tagged1_provider,tagged2_provider,allocations,allocation_failures,"
              "stale_provider_updates,logical_storage_bits,two_read_storage_bits,"
              "max_history\n";
    output << std::fixed << std::setprecision(6);
    for (std::size_t index = 0; index < configs.size(); ++index) {
        DirectionStats total;
        std::uint64_t retired = 0;
        unsigned complete = 0;
        double worst = 100.0;
        for (const auto& program : results) {
            if (index >= program.models.size()) {
                continue;
            }
            const auto& stats = program.models[index].stats;
            retired += program.architectural.retired_instructions;
            complete += static_cast<unsigned>(program.completed);
            total.branches += stats.branches;
            total.taken += stats.taken;
            total.predicted_taken += stats.predicted_taken;
            total.correct += stats.correct;
            total.mispredictions += stats.mispredictions;
            total.base_provider += stats.base_provider;
            total.allocations += stats.allocations;
            total.allocation_failures += stats.allocation_failures;
            total.stale_provider_updates += stats.stale_provider_updates;
            for (std::size_t table = 0; table < total.tagged_provider.size(); ++table) {
                total.tagged_provider[table] += stats.tagged_provider[table];
            }
            worst = std::min(worst, percentage(stats.correct, stats.branches));
        }
        DirectionPredictor predictor(configs[index]);
        output << configs[index].name << ',' << family_name(configs[index].family)
               << ',' << configs[index].update_delay_instructions << ','
               << configs[index].mispredict_resolution_barrier << ',' << complete
               << ',' << results.size() << ',' << retired << ',' << total.branches
               << ',' << total.taken << ',' << total.predicted_taken << ','
               << total.correct << ',' << total.mispredictions << ','
               << percentage(total.correct, total.branches) << ','
               << per_kilo(total.mispredictions, retired) << ',' << worst << ','
               << total.base_provider << ',' << total.tagged_provider[0] << ','
               << total.tagged_provider[1] << ',' << total.tagged_provider[2]
               << ',' << total.allocations << ',' << total.allocation_failures
               << ',' << total.stale_provider_updates << ','
               << predictor.logical_storage_bits() << ','
               << predictor.two_read_storage_bits() << ','
               << predictor.maximum_history_length() << '\n';
    }
}

void write_per_pc(const std::filesystem::path& path,
                  const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,pc,branches,mispredictions,miss_rate_pct\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            for (std::size_t word = 0; word < model.stats.branches_by_pc.size(); ++word) {
                const auto branches = model.stats.branches_by_pc[word];
                if (branches == 0u) {
                    continue;
                }
                output << program.name << ',' << model.config.name << ','
                       << model.config.update_delay_instructions << ",0x" << std::hex
                       << (kIromBase + static_cast<std::uint32_t>(word * 4u))
                       << std::dec << ',' << branches << ','
                       << model.stats.misses_by_pc[word] << ','
                       << percentage(model.stats.misses_by_pc[word], branches) << '\n';
            }
        }
    }
}

void add_diagnostics(DirectionStats& total, const DirectionStats& stats) {
    total.branches += stats.branches;
    total.mispredictions += stats.mispredictions;
    total.base_provider += stats.base_provider;
    total.base_provider_correct += stats.base_provider_correct;
    total.final_base_source += stats.final_base_source;
    total.final_base_correct += stats.final_base_correct;
    total.alternate_used += stats.alternate_used;
    total.alternate_correct += stats.alternate_correct;
    total.base_alias_switches += stats.base_alias_switches;
    total.base_alias_misses += stats.base_alias_misses;
    total.allocations += stats.allocations;
    total.allocation_failures += stats.allocation_failures;
    for (std::size_t table = 0; table < total.tagged_provider.size(); ++table) {
        total.tagged_provider[table] += stats.tagged_provider[table];
        total.tagged_provider_correct[table] +=
            stats.tagged_provider_correct[table];
        total.final_tagged_source[table] += stats.final_tagged_source[table];
        total.final_tagged_correct[table] += stats.final_tagged_correct[table];
    }
    for (std::size_t bank = 0; bank < 2; ++bank) {
        total.base_bank_lookups[bank] += stats.base_bank_lookups[bank];
        total.base_bank_misses[bank] += stats.base_bank_misses[bank];
        total.base_bank_alias_switches[bank] +=
            stats.base_bank_alias_switches[bank];
        total.base_bank_alias_misses[bank] +=
            stats.base_bank_alias_misses[bank];
        total.allocations_by_bank[bank] += stats.allocations_by_bank[bank];
        total.allocation_failures_by_bank[bank] +=
            stats.allocation_failures_by_bank[bank];
    }
}

void write_diagnostic_row(std::ofstream& output, const std::string& program,
                          const ModelResult& model,
                          const DirectionStats& stats) {
    output << program << ',' << model.config.name << ','
           << model.config.update_delay_instructions << ','
           << base_index_name(model.config.base_index_mode) << ','
           << model.config.base_entries << ','
           << model.config.tagged_pc2_banked << ',' << stats.branches << ','
           << stats.mispredictions << ',' << stats.base_provider << ','
           << stats.base_provider_correct << ','
           << percentage(stats.base_provider_correct, stats.base_provider);
    for (std::size_t table = 0; table < 3; ++table) {
        output << ',' << stats.tagged_provider[table] << ','
               << stats.tagged_provider_correct[table] << ','
               << percentage(stats.tagged_provider_correct[table],
                             stats.tagged_provider[table]);
    }
    output << ',' << stats.final_base_source << ',' << stats.final_base_correct
           << ',' << percentage(stats.final_base_correct,
                                stats.final_base_source);
    for (std::size_t table = 0; table < 3; ++table) {
        output << ',' << stats.final_tagged_source[table] << ','
               << stats.final_tagged_correct[table] << ','
               << percentage(stats.final_tagged_correct[table],
                             stats.final_tagged_source[table]);
    }
    output << ',' << stats.alternate_used << ',' << stats.alternate_correct
           << ',' << percentage(stats.alternate_correct, stats.alternate_used);
    for (std::size_t bank = 0; bank < 2; ++bank) {
        output << ',' << stats.base_bank_lookups[bank] << ','
               << stats.base_bank_misses[bank] << ','
               << percentage(stats.base_bank_lookups[bank] -
                                 stats.base_bank_misses[bank],
                             stats.base_bank_lookups[bank]) << ','
               << stats.base_bank_alias_switches[bank] << ','
               << stats.base_bank_alias_misses[bank] << ','
               << stats.allocations_by_bank[bank] << ','
               << stats.allocation_failures_by_bank[bank];
    }
    output << ',' << stats.base_alias_switches << ',' << stats.base_alias_misses
           << ',' << stats.allocations << ',' << stats.allocation_failures
           << ',' << model.logical_bits << ',' << model.two_read_bits << '\n';
}

void write_diagnostics(const std::filesystem::path& path,
                       const std::vector<ProgramResult>& results,
                       const std::vector<DirectionConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,config,update_delay,base_index_mode,base_entries,"
              "tagged_pc2_banked,branches,mispredictions,base_provider,"
              "base_provider_correct,base_provider_accuracy_pct";
    for (const auto* table : {"t0", "t1", "t2"}) {
        output << ',' << table << "_provider," << table
               << "_provider_correct," << table << "_provider_accuracy_pct";
    }
    output << ",final_base,final_base_correct,final_base_accuracy_pct";
    for (const auto* table : {"t0", "t1", "t2"}) {
        output << ",final_" << table << ",final_" << table
               << "_correct,final_" << table << "_accuracy_pct";
    }
    output << ",alternate_used,alternate_correct,alternate_accuracy_pct";
    for (const auto* bank : {"bank0", "bank1"}) {
        output << ',' << bank << "_lookups," << bank << "_misses," << bank
               << "_accuracy_pct," << bank << "_alias_switches," << bank
               << "_alias_misses," << bank << "_allocations," << bank
               << "_allocation_failures";
    }
    output << ",base_alias_switches,base_alias_misses,allocations,"
              "allocation_failures,logical_storage_bits,two_read_storage_bits\n";
    output << std::fixed << std::setprecision(6);

    for (const auto& program : results) {
        for (const auto& model : program.models) {
            write_diagnostic_row(output, program.name, model, model.stats);
        }
    }
    for (std::size_t index = 0; index < configs.size(); ++index) {
        DirectionStats total;
        for (const auto& program : results) {
            if (index < program.models.size()) {
                add_diagnostics(total, program.models[index].stats);
            }
        }
        DirectionPredictor predictor(configs[index]);
        const ModelResult aggregate{configs[index], total,
                                    predictor.logical_storage_bits(),
                                    predictor.two_read_storage_bits()};
        write_diagnostic_row(output, "ALL", aggregate, total);
    }
}

void print_summary(const std::vector<ProgramResult>& results,
                   const std::vector<DirectionConfig>& configs) {
    for (const auto delay : {0u, 6u}) {
        struct Row { std::string name; std::uint64_t misses; std::uint64_t branches; };
        std::vector<Row> rows;
        for (std::size_t index = 0; index < configs.size(); ++index) {
            if (configs[index].update_delay_instructions != delay) {
                continue;
            }
            Row row{configs[index].name, 0, 0};
            for (const auto& program : results) {
                if (index < program.models.size()) {
                    row.misses += program.models[index].stats.mispredictions;
                    row.branches += program.models[index].stats.branches;
                }
            }
            rows.push_back(std::move(row));
        }
        if (rows.empty()) {
            continue;
        }
        std::sort(rows.begin(), rows.end(), [](const Row& left, const Row& right) {
            return left.misses < right.misses;
        });
        std::cout << "delay=" << delay << " best configurations:\n";
        for (std::size_t index = 0; index < std::min<std::size_t>(5, rows.size()); ++index) {
            std::cout << "  " << rows[index].name << " misses=" << rows[index].misses
                      << " accuracy="
                      << percentage(rows[index].branches - rows[index].misses,
                                    rows[index].branches) << "%\n";
        }
    }
}

}  // namespace
}  // namespace archsim

int main(int argc, char** argv) {
    using namespace archsim;
    try {
        const auto options = parse_options(argc, argv);
        auto configs = make_direction_study_configs(
            options.delays, options.mispredict_resolution_barrier);
        if (!options.config_names.empty()) {
            std::erase_if(configs, [&](const DirectionConfig& config) {
                return std::find(options.config_names.begin(),
                                 options.config_names.end(), config.name) ==
                       options.config_names.end();
            });
            if (configs.empty()) {
                throw std::runtime_error("--configs did not match any configuration");
            }
        }
        std::vector<ProgramResult> results(options.programs.size());
        std::atomic_size_t next{0};
        const auto worker_count = std::min<std::size_t>(
            options.jobs, options.programs.size());
        std::vector<std::thread> workers;
        for (std::size_t worker = 0; worker < worker_count; ++worker) {
            workers.emplace_back([&] {
                while (true) {
                    const auto index = next.fetch_add(1);
                    if (index >= options.programs.size()) {
                        return;
                    }
                    results[index] = run_program(options, options.programs[index], configs);
                    std::lock_guard lock(console_mutex);
                    std::cerr << "[done] " << options.programs[index] << " retired="
                              << results[index].architectural.retired_instructions
                              << " completed=" << results[index].completed << " elapsed="
                              << results[index].elapsed_seconds << "s\n";
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
        std::filesystem::create_directories(options.output_dir);
        write_per_program(options.output_dir / "per_program.csv", results);
        write_aggregate(options.output_dir / "aggregate.csv", results, configs);
        write_per_pc(options.output_dir / "per_pc.csv", results);
        write_diagnostics(options.output_dir / "diagnostics.csv", results,
                          configs);
        print_summary(results, configs);
        if (options.max_instructions != 0u) {
            std::cout << "NOTE: max-instructions was set; this is an incomplete sample.\n";
        }
        std::cout << "results: " << options.output_dir << '\n';
    } catch (const std::exception& exception) {
        std::cerr << "error: " << exception.what() << '\n';
        return 1;
    }
}
