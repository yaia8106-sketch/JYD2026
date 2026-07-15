#include "predictor.hpp"
#include "rv32_sim.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace archsim {
namespace {

enum class Experiment : std::uint8_t {
    FirstRound,
    TargetHistory,
};

constexpr std::array kDefaultPrograms{
    "current",
    "src0",
    "src1",
    "src2",
    "new_without_Mext",
    "new_with_Mext",
};

struct Options {
    std::filesystem::path coe_root = "02_Design/coe/single_issue";
    std::filesystem::path output_dir =
        "02_Design/cpp_arch_explorer/results";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> delays{0u, 2u, 4u, 6u};
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    unsigned jobs = std::max(1u, std::thread::hardware_concurrency());
    bool mispredict_resolution_barrier = true;
    Experiment experiment = Experiment::TargetHistory;
};

struct ModelResult {
    PredictorConfig config;
    PredictorStats stats;
};

struct ProgramResult {
    std::string name;
    bool completed = false;
    std::string error;
    ArchitecturalStats architectural;
    std::vector<ModelResult> models;
    double elapsed_seconds = 0.0;
};

std::vector<std::string> split(const std::string& value, const char delimiter) {
    std::vector<std::string> parts;
    std::stringstream stream(value);
    std::string part;
    while (std::getline(stream, part, delimiter)) {
        if (!part.empty()) {
            parts.push_back(part);
        }
    }
    return parts;
}

std::vector<std::uint32_t> parse_delays(const std::string& value) {
    std::vector<std::uint32_t> delays;
    for (const auto& part : split(value, ',')) {
        const auto parsed = std::stoul(part, nullptr, 0);
        if (parsed >= 63u) {
            throw std::runtime_error("update delay must be less than 63 instructions");
        }
        delays.push_back(static_cast<std::uint32_t>(parsed));
    }
    if (delays.empty()) {
        throw std::runtime_error("at least one update delay is required");
    }
    std::sort(delays.begin(), delays.end());
    delays.erase(std::unique(delays.begin(), delays.end()), delays.end());
    return delays;
}

void print_usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "Options:\n"
        << "  --coe-root PATH       Root containing six single_issue COE directories\n"
        << "  --output-dir PATH     CSV output directory\n"
        << "  --programs A,B,...    Development override; default runs all six\n"
        << "  --delays 0,2,4,6      Predictor update delays in dynamic instructions\n"
        << "  --jobs N              Programs simulated in parallel\n"
        << "  --max-instructions N  Truncate each program for smoke testing (0 = full)\n"
        << "  --progress N          Progress interval per program (0 = disabled)\n"
        << "  --experiment NAME     target-history (default) or first-round\n"
        << "  --no-mispredict-barrier  Do not force a mispredicted branch to resolve\n"
        << "  -h, --help            Show this help\n";
}

Options parse_options(const int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        const auto require_value = [&](const std::string& option) -> std::string {
            if (index + 1 >= argc) {
                throw std::runtime_error(option + " requires a value");
            }
            return argv[++index];
        };

        if (argument == "--coe-root") {
            options.coe_root = require_value(argument);
        } else if (argument == "--output-dir") {
            options.output_dir = require_value(argument);
        } else if (argument == "--programs") {
            options.programs = split(require_value(argument), ',');
        } else if (argument == "--delays") {
            options.delays = parse_delays(require_value(argument));
        } else if (argument == "--jobs") {
            options.jobs = std::max(1u, static_cast<unsigned>(
                                           std::stoul(require_value(argument))));
        } else if (argument == "--max-instructions") {
            options.max_instructions = std::stoull(require_value(argument));
        } else if (argument == "--progress") {
            options.progress_instructions = std::stoull(require_value(argument));
        } else if (argument == "--experiment") {
            const auto experiment = require_value(argument);
            if (experiment == "target-history") {
                options.experiment = Experiment::TargetHistory;
            } else if (experiment == "first-round") {
                options.experiment = Experiment::FirstRound;
            } else {
                throw std::runtime_error(
                    "--experiment must be target-history or first-round");
            }
        } else if (argument == "--no-mispredict-barrier") {
            options.mispredict_resolution_barrier = false;
        } else if (argument == "-h" || argument == "--help") {
            print_usage(argv[0]);
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

std::mutex console_mutex;

ProgramResult run_program(const Options& options,
                          const std::string& program_name,
                          const std::vector<PredictorConfig>& configs) {
    ProgramResult result;
    result.name = program_name;
    const auto start = std::chrono::steady_clock::now();

    try {
        const auto image = load_program(options.coe_root, program_name);
        Rv32Machine machine(image);
        std::vector<PredictorModel> models;
        models.reserve(configs.size());
        for (const auto& config : configs) {
            models.emplace_back(config);
        }

        std::uint64_t next_progress = options.progress_instructions;
        while (!machine.reached_stop()) {
            if (options.max_instructions != 0u &&
                machine.stats().retired_instructions >= options.max_instructions) {
                break;
            }

            const auto event = machine.step();
            if (event.kind != CfiKind::None) {
                for (auto& model : models) {
                    model.observe(event);
                }
            }

            if (options.progress_instructions != 0u &&
                machine.stats().retired_instructions >= next_progress) {
                std::lock_guard lock(console_mutex);
                std::cerr << "[progress] " << program_name << " retired="
                          << machine.stats().retired_instructions << '\n';
                next_progress += options.progress_instructions;
            }
        }

        result.completed = machine.reached_stop();
        result.architectural = machine.stats();
        result.models.reserve(models.size());
        for (const auto& model : models) {
            result.models.push_back(ModelResult{model.config(), model.finalize_stats()});
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }

    const auto end = std::chrono::steady_clock::now();
    result.elapsed_seconds = std::chrono::duration<double>(end - start).count();
    return result;
}

double percentage(const std::uint64_t numerator, const std::uint64_t denominator) {
    return denominator == 0u
               ? 0.0
               : 100.0 * static_cast<double>(numerator) /
                     static_cast<double>(denominator);
}

double per_kilo(const std::uint64_t numerator, const std::uint64_t denominator) {
    return denominator == 0u
               ? 0.0
               : 1000.0 * static_cast<double>(numerator) /
                     static_cast<double>(denominator);
}

unsigned lookup_xor_operands(const PredictorFamily family) {
    if (family == PredictorFamily::Bimodal) {
        return 1u;
    }
    if (family == PredictorFamily::Gshare ||
        family == PredictorFamily::TargetLast ||
        family == PredictorFamily::TargetRolling) {
        return 2u;
    }
    return 3u;
}

unsigned history_state_bits(const PredictorConfig& config) {
    const auto family = config.family;
    if (family == PredictorFamily::Bimodal) {
        return 0u;
    }
    if (family == PredictorFamily::Gshare) {
        return 8u;
    }
    if (family == PredictorFamily::TargetLast ||
        family == PredictorFamily::TargetRolling) {
        if (config.target_hash == TargetHash::Fold2) {
            return 2u;
        }
        return config.target_hash == TargetHash::Fold4 ? 4u : 8u;
    }
    if (config.target_hash == TargetHash::Fold2) {
        return 10u;
    }
    return config.target_hash == TargetHash::Fold4 ? 12u : 16u;
}

void write_per_program_csv(const std::filesystem::path& path,
                           const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,completed,error,retired_instructions,conditional_branches,"
              "taken_branches,jal,jalr,traps,timer_interrupts,config,update_delay,"
              "mispredict_barrier,predicted_taken,correct,mispredictions,accuracy_pct,"
              "mispred_per_kinst,alias_switches,alias_associated_misses,static_branches,"
              "branch_index_pairs,max_indices_per_branch,pht_bits,history_state_bits,"
              "lookup_xor_operands,elapsed_seconds\n";
    output << std::fixed << std::setprecision(6);

    for (const auto& program : results) {
        if (program.models.empty()) {
            output << program.name << ',' << program.completed << ',' << '"'
                   << program.error << '"' << ','
                   << program.architectural.retired_instructions
                   << ",0,0,0,0,0,0,,,,,,,,,,,,,,,,," << program.elapsed_seconds
                   << '\n';
            continue;
        }
        for (const auto& model : program.models) {
            const auto& stats = model.stats;
            output << program.name << ',' << program.completed << ',' << '"'
                   << program.error << '"' << ','
                   << program.architectural.retired_instructions << ','
                   << program.architectural.conditional_branches << ','
                   << program.architectural.taken_branches << ','
                   << program.architectural.jal_count << ','
                   << program.architectural.jalr_count << ','
                   << program.architectural.trap_count << ','
                   << program.architectural.timer_interrupt_count << ','
                   << model.config.name << ','
                   << model.config.update_delay_instructions << ','
                   << model.config.mispredict_resolution_barrier << ','
                   << stats.predicted_taken << ',' << stats.correct << ','
                   << stats.mispredictions << ','
                   << percentage(stats.correct, stats.branches) << ','
                   << per_kilo(stats.mispredictions,
                               program.architectural.retired_instructions)
                   << ',' << stats.alias_switches << ','
                   << stats.alias_associated_misses << ',' << stats.static_branches
                   << ',' << stats.branch_index_pairs << ','
                   << stats.max_indices_per_branch << ",512,"
                   << history_state_bits(model.config) << ','
                   << lookup_xor_operands(model.config.family) << ','
                   << program.elapsed_seconds << '\n';
        }
    }
}

void write_aggregate_csv(const std::filesystem::path& path,
                         const std::vector<ProgramResult>& results,
                         const std::vector<PredictorConfig>& configs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "config,update_delay,mispredict_barrier,programs_complete,programs_total,"
              "retired_instructions,branches,taken,predicted_taken,correct,mispredictions,"
              "accuracy_pct,mispred_per_kinst,worst_program_accuracy_pct,"
              "alias_switches,alias_associated_misses,pht_bits,history_state_bits,"
              "lookup_xor_operands\n";
    output << std::fixed << std::setprecision(6);

    for (std::size_t config_index = 0; config_index < configs.size(); ++config_index) {
        std::uint64_t retired = 0;
        PredictorStats total{};
        unsigned complete = 0;
        double worst_accuracy = 100.0;
        for (const auto& program : results) {
            retired += program.architectural.retired_instructions;
            complete += static_cast<unsigned>(program.completed);
            if (config_index >= program.models.size()) {
                continue;
            }
            const auto& stats = program.models[config_index].stats;
            total.branches += stats.branches;
            total.taken += stats.taken;
            total.predicted_taken += stats.predicted_taken;
            total.correct += stats.correct;
            total.mispredictions += stats.mispredictions;
            total.alias_switches += stats.alias_switches;
            total.alias_associated_misses += stats.alias_associated_misses;
            worst_accuracy = std::min(
                worst_accuracy, percentage(stats.correct, stats.branches));
        }

        const auto& config = configs[config_index];
        output << config.name << ',' << config.update_delay_instructions << ','
               << config.mispredict_resolution_barrier << ',' << complete << ','
               << results.size() << ',' << retired << ',' << total.branches << ','
               << total.taken << ',' << total.predicted_taken << ',' << total.correct
               << ',' << total.mispredictions << ','
               << percentage(total.correct, total.branches) << ','
               << per_kilo(total.mispredictions, retired) << ',' << worst_accuracy
               << ',' << total.alias_switches << ','
               << total.alias_associated_misses << ",512,"
               << history_state_bits(config) << ','
               << lookup_xor_operands(config.family) << '\n';
    }
}

void print_summary(const std::vector<ProgramResult>& results,
                   const std::vector<PredictorConfig>& configs,
                   const std::vector<std::uint32_t>& delays) {
    std::cout << "\nArchitectural execution:\n";
    for (const auto& program : results) {
        std::cout << "  " << std::left << std::setw(18) << program.name
                  << " status=" << (program.completed ? "complete" : "incomplete")
                  << " retired=" << program.architectural.retired_instructions
                  << " branches=" << program.architectural.conditional_branches
                  << " stop=0x" << std::hex << program.architectural.stop_pc
                  << std::dec << " time=" << std::fixed << std::setprecision(2)
                  << program.elapsed_seconds << "s";
        if (!program.error.empty()) {
            std::cout << " error=" << program.error;
        }
        std::cout << '\n';
    }

    for (const auto delay : delays) {
        struct Rank {
            std::string name;
            std::uint64_t misses = 0;
            std::uint64_t branches = 0;
        };
        std::vector<Rank> ranks;
        for (std::size_t index = 0; index < configs.size(); ++index) {
            if (configs[index].update_delay_instructions != delay) {
                continue;
            }
            Rank rank{configs[index].name};
            for (const auto& program : results) {
                if (index < program.models.size()) {
                    rank.misses += program.models[index].stats.mispredictions;
                    rank.branches += program.models[index].stats.branches;
                }
            }
            ranks.push_back(rank);
        }
        std::sort(ranks.begin(), ranks.end(), [](const Rank& lhs, const Rank& rhs) {
            return lhs.misses < rhs.misses;
        });

        std::cout << "\nTop configurations at update delay " << delay << ":\n";
        const auto count = std::min<std::size_t>(5u, ranks.size());
        for (std::size_t rank = 0; rank < count; ++rank) {
            std::cout << "  " << (rank + 1u) << ". " << std::left
                      << std::setw(24) << ranks[rank].name << " misses="
                      << ranks[rank].misses << " accuracy=" << std::fixed
                      << std::setprecision(4)
                      << percentage(ranks[rank].branches - ranks[rank].misses,
                                    ranks[rank].branches)
                      << "%\n";
        }
    }
}

}  // namespace
}  // namespace archsim

int main(const int argc, char** argv) {
    using namespace archsim;
    try {
        const auto options = parse_options(argc, argv);
        const auto configs =
            options.experiment == Experiment::FirstRound
                ? make_first_round_configs(options.delays,
                                           options.mispredict_resolution_barrier)
                : make_target_history_configs(
                      options.delays, options.mispredict_resolution_barrier);

        const auto task_count = options.programs.size() * options.delays.size();
        const auto worker_count = std::min<std::size_t>(options.jobs, task_count);
        std::cout << "Programs: " << options.programs.size()
                  << ", configurations: " << configs.size()
                  << ", tasks: " << task_count
                  << ", jobs: " << worker_count << '\n';

        std::vector<std::optional<ProgramResult>> task_slots(task_count);
        std::atomic_size_t next_task{0u};
        std::vector<std::thread> workers;
        workers.reserve(worker_count);
        for (std::size_t worker = 0; worker < worker_count; ++worker) {
            workers.emplace_back([&]() {
                while (true) {
                    const auto task_index = next_task.fetch_add(1u);
                    if (task_index >= task_count) {
                        break;
                    }
                    const auto program_index = task_index / options.delays.size();
                    const auto delay_index = task_index % options.delays.size();
                    const auto delay = options.delays[delay_index];
                    std::vector<PredictorConfig> task_configs;
                    task_configs.reserve(12u);
                    std::copy_if(configs.begin(), configs.end(),
                                 std::back_inserter(task_configs),
                                 [delay](const PredictorConfig& config) {
                                     return config.update_delay_instructions == delay;
                                 });
                    auto result = run_program(options,
                                              options.programs[program_index],
                                              task_configs);
                    {
                        std::lock_guard lock(console_mutex);
                        std::cerr << "[done] " << result.name
                                  << " delay=" << delay << " retired="
                                  << result.architectural.retired_instructions
                                  << " completed=" << result.completed
                                  << " time=" << std::fixed << std::setprecision(2)
                                  << result.elapsed_seconds << "s\n";
                    }
                    task_slots[task_index] = std::move(result);
                }
            });
        }
        for (auto& worker : workers) {
            worker.join();
        }

        std::vector<ProgramResult> results;
        results.reserve(options.programs.size());
        for (std::size_t program_index = 0;
             program_index < options.programs.size(); ++program_index) {
            ProgramResult merged;
            merged.name = options.programs[program_index];
            merged.completed = true;
            for (std::size_t delay_index = 0;
                 delay_index < options.delays.size(); ++delay_index) {
                auto task = std::move(
                    task_slots[program_index * options.delays.size() + delay_index]
                        .value());
                if (delay_index == 0u) {
                    merged.architectural = task.architectural;
                } else if (task.architectural.retired_instructions !=
                               merged.architectural.retired_instructions ||
                           task.architectural.conditional_branches !=
                               merged.architectural.conditional_branches) {
                    merged.error += "architectural replay mismatch across delays; ";
                }
                merged.completed = merged.completed && task.completed;
                if (!task.error.empty()) {
                    merged.error += task.error + "; ";
                }
                merged.elapsed_seconds =
                    std::max(merged.elapsed_seconds, task.elapsed_seconds);
                std::move(task.models.begin(), task.models.end(),
                          std::back_inserter(merged.models));
            }
            results.push_back(std::move(merged));
        }

        std::filesystem::create_directories(options.output_dir);
        write_per_program_csv(options.output_dir / "per_program.csv", results);
        write_aggregate_csv(options.output_dir / "aggregate.csv", results, configs);
        print_summary(results, configs, options.delays);

        const bool all_complete = std::all_of(
            results.begin(), results.end(),
            [](const ProgramResult& result) { return result.completed; });
        if (!all_complete && options.max_instructions == 0u) {
            return 2;
        }
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "ERROR: " << exception.what() << '\n';
        return 1;
    }
}
