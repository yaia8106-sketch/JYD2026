#include "fdq_model.hpp"
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
#include <mutex>
#include <regex>
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
        "02_Design/cpp_arch_explorer/results/fdq";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> delays{6u, 10u};
    std::vector<std::string> config_names;
    std::vector<std::string> scenario_names;
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    std::filesystem::path rtl_log_dir =
        "02_Design/riscv_tests/work/perf/runs/coe/20260704_125720/logs";
    unsigned jobs = std::clamp(std::thread::hardware_concurrency(), 1u, 16u);
};

struct ScenarioResult {
    FdqScenarioConfig config;
    FdqScenarioStats stats;
};

struct ConfigResult {
    FrontendConfig config;
    FrontendStats frontend;
    std::vector<ScenarioResult> scenarios;
};

struct ProgramResult {
    std::string name;
    bool completed = false;
    std::string error;
    ArchitecturalStats architectural;
    std::vector<ConfigResult> configs;
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
        result.push_back(static_cast<std::uint32_t>(std::stoul(part)));
    }
    if (result.empty()) {
        throw std::runtime_error("at least one delay is required");
    }
    return result;
}

void usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "  --coe-root PATH\n"
        << "  --output-dir PATH\n"
        << "  --programs A,B,...\n"
        << "  --delays 6,10\n"
        << "  --configs A,B,...   Required predictor configurations\n"
        << "  --scenarios A,B,... Optional FDQ scenario subset\n"
        << "  --jobs N            Hard-capped at 16\n"
        << "  --max-instructions N\n"
        << "  --progress N\n"
        << "  --rtl-log-dir PATH  RTL logs used for consumer-stall calibration\n";
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
        } else if (argument == "--scenarios") {
            options.scenario_names = split(value(argument), ',');
        } else if (argument == "--jobs") {
            options.jobs = std::clamp(
                static_cast<unsigned>(std::stoul(value(argument))), 1u, 16u);
        } else if (argument == "--max-instructions") {
            options.max_instructions = std::stoull(value(argument));
        } else if (argument == "--progress") {
            options.progress_instructions = std::stoull(value(argument));
        } else if (argument == "--rtl-log-dir") {
            options.rtl_log_dir = value(argument);
        } else if (argument == "-h" || argument == "--help") {
            usage(argv[0]);
            std::exit(0);
        } else {
            throw std::runtime_error("unknown option: " + argument);
        }
    }
    if (options.config_names.empty()) {
        throw std::runtime_error("--configs is required for the cycle study");
    }
    return options;
}

struct ActiveConfig {
    FrontendConfig config;
    FrontendModel frontend;
    FdqStudyModel fdq;

    ActiveConfig(const FrontendConfig& selected,
                 const std::uint32_t consumer_stall_ppm,
                 const std::vector<std::string>& scenario_names)
        : config(selected), frontend(selected),
          fdq([&] {
              auto scenarios = make_fdq_scenarios(consumer_stall_ppm);
              if (!scenario_names.empty()) {
                  std::erase_if(scenarios, [&](const auto& scenario) {
                      return std::find(scenario_names.begin(),
                                       scenario_names.end(), scenario.name) ==
                             scenario_names.end();
                  });
              }
              return scenarios;
          }()) {}
};

std::uint64_t first_metric(const std::string& text,
                           const std::string& pattern) {
    std::smatch match;
    if (!std::regex_search(text, match, std::regex(pattern))) {
        throw std::runtime_error("missing RTL calibration metric: " + pattern);
    }
    return std::stoull(match[1].str());
}

std::uint32_t calibrated_stall_ppm(const Options& options,
                                   const std::string& program) {
    std::ifstream input(options.rtl_log_dir / (program + ".log"));
    if (!input) {
        throw std::runtime_error("cannot read RTL calibration log for " +
                                 program);
    }
    const std::string text((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());
    const auto cycles = first_metric(
        text, R"(\[PERF\]\s+Cycles:\s+(\d+))");
    const auto raw = first_metric(
        text, R"(CPI stack:.*raw_not_ready=(\d+))");
    const auto ready_no_fwd = first_metric(
        text, R"(CPI stack:.*raw_ready_no_fwd=(\d+))");
    const auto dcache = first_metric(
        text, R"(CPI stack:.*dcache=(\d+))");
    const auto muldiv = first_metric(
        text, R"(CPI stack:.*muldiv=(\d+))");
    const auto blocked = raw + ready_no_fwd + dcache + muldiv;
    return static_cast<std::uint32_t>(std::min<std::uint64_t>(
        999'999u, (blocked * 1'000'000u + cycles / 2u) / cycles));
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
        const auto consumer_stall_ppm = calibrated_stall_ppm(options, name);
        std::vector<ActiveConfig> active;
        active.reserve(configs.size());
        for (const auto& config : configs) {
            active.emplace_back(config, consumer_stall_ppm,
                                options.scenario_names);
        }

        auto next_progress = options.progress_instructions;
        while (!machine.reached_stop() &&
               (options.max_instructions == 0u ||
                machine.stats().retired_instructions < options.max_instructions)) {
            const auto event = machine.step();
            const auto block = profiler.observe(event);
            for (auto& item : active) {
                const auto decision = event.kind == CfiKind::None
                                          ? FrontendDecision{}
                                          : item.frontend.observe(event, block);
                item.fdq.observe(event, decision);
            }
            if (options.progress_instructions != 0u &&
                machine.stats().retired_instructions >= next_progress) {
                std::lock_guard lock(console_mutex);
                std::cerr << "[fdq progress] " << name << " retired="
                          << machine.stats().retired_instructions << '\n';
                next_progress += options.progress_instructions;
            }
        }

        result.completed = machine.reached_stop();
        result.architectural = machine.stats();
        for (auto& item : active) {
            item.fdq.finish();
            ConfigResult config_result;
            config_result.config = item.config;
            config_result.frontend = item.frontend.stats();
            for (const auto& scenario : item.fdq.scenarios()) {
                config_result.scenarios.push_back(
                    {scenario.config(), scenario.stats()});
            }
            result.configs.push_back(std::move(config_result));
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }
    result.elapsed_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

void add_stats(FdqScenarioStats& total, const FdqScenarioStats& value) {
    total.cycles += value.cycles;
    total.instructions_consumed += value.instructions_consumed;
    total.empty_cycles += value.empty_cycles;
    total.consumer_stall_cycles += value.consumer_stall_cycles;
    total.single_issue_cycles += value.single_issue_cycles;
    total.dual_issue_cycles += value.dual_issue_cycles;
    total.packets += value.packets;
    total.one_instruction_packets += value.one_instruction_packets;
    total.two_instruction_packets += value.two_instruction_packets;
    total.producer_blocked_cycles += value.producer_blocked_cycles;
    total.f0_corrections += value.f0_corrections;
    total.f1_corrections += value.f1_corrections;
    total.backend_direction_redirects += value.backend_direction_redirects;
    total.backend_target_redirects += value.backend_target_redirects;
    total.system_redirects += value.system_redirects;
    total.estimated_f1_wrong_path_blocks += value.estimated_f1_wrong_path_blocks;
    total.estimated_f1_wrong_path_slots += value.estimated_f1_wrong_path_slots;
    total.correction_observations += value.correction_observations;
    total.corrections_with_empty_fdq += value.corrections_with_empty_fdq;
    total.occupancy_sum_at_correction += value.occupancy_sum_at_correction;
    total.maximum_occupancy = std::max(total.maximum_occupancy,
                                       value.maximum_occupancy);
    total.occupancy_sum += value.occupancy_sum;
    for (std::size_t occupancy = 0;
         occupancy < total.retained_at_correction.size(); ++occupancy) {
        total.retained_at_correction[occupancy] +=
            value.retained_at_correction[occupancy];
    }
}

double ratio(const std::uint64_t numerator, const std::uint64_t denominator) {
    return denominator == 0u ? 0.0 :
        static_cast<double>(numerator) / static_cast<double>(denominator);
}

void write_header(std::ofstream& output) {
    output << "program,completed,retired_instructions,config,update_delay,scenario,"
              "fdq_depth,consume_policy,backend_policy,consumer_stall_ppm,"
              "consumer_stall_burst_cycles,f1_refill_cycles,"
              "backend_refill_cycles,"
              "cycles,instructions_consumed,ipc,empty_cycles,empty_cycle_pct,"
              "consumer_stall_cycles,"
              "single_issue_cycles,dual_issue_cycles,packets,one_inst_packets,"
              "two_inst_packets,producer_blocked_cycles,f0_corrections,"
              "f1_corrections,backend_direction_redirects,"
              "backend_target_redirects,system_redirects,"
              "estimated_f1_wrong_path_blocks,estimated_f1_wrong_path_slots,"
              "correction_observations,corrections_with_empty_fdq,"
              "empty_fdq_at_correction_pct,average_retained_at_correction,"
              "average_occupancy,maximum_occupancy";
    for (std::size_t occupancy = 0; occupancy <= 8; ++occupancy) {
        output << ",retained_" << occupancy;
    }
    output << ",elapsed_seconds\n";
}

void write_row(std::ofstream& output, const std::string& program,
               const bool completed, const std::uint64_t retired,
               const FrontendConfig& config,
               const FdqScenarioConfig& scenario,
               const FdqScenarioStats& stats, const double elapsed) {
    output << program << ',' << completed << ',' << retired << ','
           << config.name << ','
           << config.fast_direction.update_delay_instructions << ','
           << scenario.name << ',' << scenario.depth << ','
           << fdq_consume_policy_name(scenario.consume_policy) << ','
           << fdq_backend_policy_name(scenario.backend_policy) << ','
           << scenario.consumer_stall_ppm << ','
           << scenario.consumer_stall_burst_cycles << ','
           << scenario.f1_refill_cycles << ','
           << scenario.backend_refill_cycles << ',' << stats.cycles << ','
           << stats.instructions_consumed << ','
           << ratio(stats.instructions_consumed, stats.cycles) << ','
           << stats.empty_cycles << ','
           << 100.0 * ratio(stats.empty_cycles, stats.cycles) << ','
           << stats.consumer_stall_cycles << ','
           << stats.single_issue_cycles << ',' << stats.dual_issue_cycles << ','
           << stats.packets << ',' << stats.one_instruction_packets << ','
           << stats.two_instruction_packets << ','
           << stats.producer_blocked_cycles << ',' << stats.f0_corrections << ','
           << stats.f1_corrections << ','
           << stats.backend_direction_redirects << ','
           << stats.backend_target_redirects << ','
           << stats.system_redirects << ','
           << stats.estimated_f1_wrong_path_blocks << ','
           << stats.estimated_f1_wrong_path_slots << ','
           << stats.correction_observations << ','
           << stats.corrections_with_empty_fdq << ','
           << 100.0 * ratio(stats.corrections_with_empty_fdq,
                            stats.correction_observations) << ','
           << ratio(stats.occupancy_sum_at_correction,
                    stats.correction_observations) << ','
           << ratio(stats.occupancy_sum, stats.cycles) << ','
           << stats.maximum_occupancy;
    for (std::size_t occupancy = 0; occupancy <= 8; ++occupancy) {
        output << ',' << stats.retained_at_correction[occupancy];
    }
    output << ',' << elapsed << '\n';
}

void write_results(const std::filesystem::path& output_dir,
                   const std::vector<ProgramResult>& results,
                   const std::vector<FrontendConfig>& configs) {
    std::filesystem::create_directories(output_dir);
    std::ofstream per_program(output_dir / "fdq_per_program.csv");
    std::ofstream aggregate(output_dir / "fdq_aggregate.csv");
    if (!per_program || !aggregate) {
        throw std::runtime_error("cannot open FDQ result CSV files");
    }
    per_program << std::fixed << std::setprecision(6);
    aggregate << std::fixed << std::setprecision(6);
    write_header(per_program);
    write_header(aggregate);

    for (const auto& program : results) {
        for (const auto& config : program.configs) {
            for (const auto& scenario : config.scenarios) {
                write_row(per_program, program.name, program.completed,
                          program.architectural.retired_instructions,
                          config.config, scenario.config, scenario.stats,
                          program.elapsed_seconds);
            }
        }
    }

    for (std::size_t config_index = 0; config_index < configs.size();
         ++config_index) {
        if (results.empty() || config_index >= results.front().configs.size()) {
            continue;
        }
        const auto scenario_count =
            results.front().configs[config_index].scenarios.size();
        for (std::size_t scenario_index = 0;
             scenario_index < scenario_count; ++scenario_index) {
            FdqScenarioStats total;
            auto scenario_config = results.front().configs[config_index]
                                       .scenarios[scenario_index].config;
            std::uint64_t retired = 0;
            std::uint64_t weighted_stall_ppm = 0;
            unsigned completed = 0;
            for (const auto& program : results) {
                if (config_index >= program.configs.size() ||
                    scenario_index >=
                        program.configs[config_index].scenarios.size()) {
                    continue;
                }
                add_stats(total, program.configs[config_index]
                                     .scenarios[scenario_index].stats);
                weighted_stall_ppm +=
                    static_cast<std::uint64_t>(
                        program.configs[config_index]
                            .scenarios[scenario_index]
                            .config.consumer_stall_ppm) *
                    program.architectural.retired_instructions;
                retired += program.architectural.retired_instructions;
                completed += static_cast<unsigned>(program.completed);
            }
            scenario_config.consumer_stall_ppm = retired == 0u
                ? 0u
                : static_cast<std::uint32_t>(weighted_stall_ppm / retired);
            write_row(aggregate, "ALL", completed == results.size(), retired,
                      configs[config_index], scenario_config,
                      total, 0.0);
        }
    }
}

void validate(const std::vector<ProgramResult>& results) {
    for (const auto& program : results) {
        for (const auto& config : program.configs) {
            for (const auto& scenario : config.scenarios) {
                if (scenario.stats.instructions_consumed !=
                    program.architectural.retired_instructions) {
                    throw std::runtime_error(
                        program.name + "/" + config.config.name + "/" +
                        scenario.config.name + ": instruction count mismatch");
                }
                if (scenario.stats.correction_observations !=
                    scenario.stats.f1_corrections) {
                    throw std::runtime_error(
                        program.name + "/" + config.config.name + "/" +
                        scenario.config.name + ": correction count mismatch");
                }
            }
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
        std::erase_if(configs, [&](const FrontendConfig& config) {
            return std::find(options.config_names.begin(),
                             options.config_names.end(), config.name) ==
                   options.config_names.end();
        });
        const bool missing_config = std::any_of(
            options.config_names.begin(), options.config_names.end(),
            [&](const std::string& name) {
                return std::none_of(configs.begin(), configs.end(),
                                    [&](const FrontendConfig& config) {
                                        return config.name == name;
                                    });
            });
        if (missing_config) {
            throw std::runtime_error("--configs contains an unknown or duplicate name");
        }
        if (!options.scenario_names.empty()) {
            const auto available = make_fdq_scenarios(1u);
            const bool missing_scenario = std::any_of(
                options.scenario_names.begin(), options.scenario_names.end(),
                [&](const std::string& name) {
                    return std::none_of(
                        available.begin(), available.end(),
                        [&](const FdqScenarioConfig& scenario) {
                            return scenario.name == name;
                        });
                });
            if (missing_scenario) {
                throw std::runtime_error("--scenarios contains an unknown name");
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
                    results[index] = run_program(
                        options, options.programs[index], configs);
                    if (results[index].error.empty()) {
                        try {
                            const std::vector<ProgramResult> checkpoint{
                                results[index]};
                            validate(checkpoint);
                            write_results(
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
                    std::cerr << "[fdq done] " << options.programs[index]
                              << " retired="
                              << results[index].architectural.retired_instructions
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
        validate(results);
        write_results(options.output_dir, results, configs);
        std::cout << "results: " << options.output_dir << '\n';
    } catch (const std::exception& exception) {
        std::cerr << "error: " << exception.what() << '\n';
        return 1;
    }
}
