#include "backend_model.hpp"
#include "rv32_sim.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
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
    std::filesystem::path coe_root =
        "02_Design/verification/riscv/coe/single_issue";
    std::filesystem::path output_dir = "/tmp/backend_iq_results";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> int_depths{8};
    std::vector<std::uint32_t> ls_depths{6};
    std::vector<std::uint32_t> mdu_depths{2};
    std::vector<std::array<std::uint32_t, 3>> explicit_configs;
    BackendConfig base_config{};
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    unsigned jobs = std::clamp(std::thread::hardware_concurrency(), 1u, 16u);
};

struct ModelResult {
    BackendConfig config;
    std::string config_name;
    BackendStats stats;
};

struct ProgramResult {
    std::string name;
    bool architectural_completed = false;
    std::string error;
    ArchitecturalStats architectural{};
    std::vector<ModelResult> models;
    double elapsed_seconds = 0.0;
};

std::mutex console_mutex;

std::vector<std::string> split(const std::string& text, const char delimiter) {
    std::vector<std::string> result;
    std::stringstream stream(text);
    for (std::string part; std::getline(stream, part, delimiter);) {
        if (!part.empty()) {
            result.push_back(part);
        }
    }
    return result;
}

std::vector<std::uint32_t> parse_u32_list(const std::string& text) {
    std::vector<std::uint32_t> result;
    for (const auto& part : split(text, ',')) {
        const auto value = std::stoul(part, nullptr, 0);
        if (value == 0u) {
            throw std::runtime_error("depth/latency list values must be nonzero");
        }
        result.push_back(static_cast<std::uint32_t>(value));
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    if (result.empty()) {
        throw std::runtime_error("list must not be empty");
    }
    return result;
}

std::vector<std::array<std::uint32_t, 3>> parse_configs(
    const std::string& text) {
    std::vector<std::array<std::uint32_t, 3>> result;
    for (const auto& config_text : split(text, ',')) {
        const auto fields = split(config_text, ':');
        if (fields.size() != 3u) {
            throw std::runtime_error(
                "--configs entries must use INT:LS:MDU, for example 16:8:4");
        }
        std::array<std::uint32_t, 3> config{};
        for (std::size_t index = 0; index < fields.size(); ++index) {
            const auto value = std::stoul(fields[index], nullptr, 0);
            if (value == 0u) {
                throw std::runtime_error("IQ depths must be nonzero");
            }
            config[index] = static_cast<std::uint32_t>(value);
        }
        result.push_back(config);
    }
    if (result.empty()) {
        throw std::runtime_error("--configs list must not be empty");
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

void usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "  --coe-root PATH          Root containing six single_issue COE programs\n"
        << "  --output-dir PATH        CSV output directory (default /tmp/backend_iq_results)\n"
        << "  --programs A,B,...       Default: all six contest programs\n"
        << "  --int-depths 4,6,8,12    Cross-product INT IQ depths\n"
        << "  --ls-depths 4,6,8        Cross-product LS IQ depths\n"
        << "  --mdu-depths 2           Cross-product MDU IQ depths\n"
        << "  --configs I:L:M,...      Explicit IQ triples; overrides three lists\n"
        << "  --branch-mode MODE       gshare (default) or perfect\n"
        << "  --branch-update-delay N  Trace-order GShare update delay in instructions (default 6)\n"
        << "  --redirect-penalty N     Backend redirect frontend bubbles (default 6)\n"
        << "  --checkpoints N          Branch checkpoint count (default 2)\n"
        << "  --mul-latency N          MUL execution latency (default 3)\n"
        << "  --div-latency N          DIV execution latency (default 32)\n"
        << "  --load-hit-latency N     Load hit execution latency (default 2)\n"
        << "  --load-miss-latency N    Load miss execution latency (default 10)\n"
        << "  --lsu-hit-ii N           LSU hit initiation interval (default 1)\n"
        << "  --store-buffer-entries N Store-buffer entries (default 2)\n"
        << "  --store-drain-latency N  Per-store drain interval (default 1)\n"
        << "  --jobs N                 Programs simulated in parallel, max 16\n"
        << "  --max-instructions N     Truncated smoke/debug run (0 = full)\n"
        << "  --progress N             Trace progress interval (0 = disabled)\n"
        << "  -h, --help               Show this help\n";
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
        } else if (argument == "--int-depths") {
            options.int_depths = parse_u32_list(value(argument));
        } else if (argument == "--ls-depths") {
            options.ls_depths = parse_u32_list(value(argument));
        } else if (argument == "--mdu-depths") {
            options.mdu_depths = parse_u32_list(value(argument));
        } else if (argument == "--configs") {
            options.explicit_configs = parse_configs(value(argument));
        } else if (argument == "--branch-mode") {
            const auto mode = value(argument);
            if (mode == "gshare") {
                options.base_config.branch_mode = BackendBranchMode::Gshare;
            } else if (mode == "perfect") {
                options.base_config.branch_mode = BackendBranchMode::Perfect;
            } else {
                throw std::runtime_error("--branch-mode must be gshare or perfect");
            }
        } else if (argument == "--redirect-penalty") {
            options.base_config.redirect_penalty =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--branch-update-delay") {
            options.base_config.branch_update_delay_instructions =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--checkpoints") {
            options.base_config.checkpoints =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--mul-latency") {
            options.base_config.mul_latency =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--div-latency") {
            options.base_config.div_latency =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--load-hit-latency") {
            options.base_config.load_hit_latency =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--load-miss-latency") {
            options.base_config.load_miss_latency =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--lsu-hit-ii") {
            options.base_config.lsu_hit_initiation_interval =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--store-buffer-entries") {
            options.base_config.store_buffer_entries =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
        } else if (argument == "--store-drain-latency") {
            options.base_config.store_drain_latency =
                static_cast<std::uint32_t>(std::stoul(value(argument)));
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

std::vector<BackendConfig> make_configs(const Options& options) {
    std::vector<BackendConfig> configs;
    const auto append = [&](const std::uint32_t int_depth,
                            const std::uint32_t ls_depth,
                            const std::uint32_t mdu_depth) {
        auto config = options.base_config;
        config.int_iq_depth = int_depth;
        config.ls_iq_depth = ls_depth;
        config.mdu_iq_depth = mdu_depth;
        configs.push_back(config);
    };
    if (!options.explicit_configs.empty()) {
        for (const auto& config : options.explicit_configs) {
            append(config[0], config[1], config[2]);
        }
    } else {
        for (const auto int_depth : options.int_depths) {
            for (const auto ls_depth : options.ls_depths) {
                for (const auto mdu_depth : options.mdu_depths) {
                    append(int_depth, ls_depth, mdu_depth);
                }
            }
        }
    }
    if (configs.size() > 256u) {
        throw std::runtime_error("configuration sweep exceeds 256 combinations");
    }
    return configs;
}

ProgramResult run_program(const Options& options, const std::string& name,
                          const std::vector<BackendConfig>& configs) {
    ProgramResult result;
    result.name = name;
    const auto start = std::chrono::steady_clock::now();
    try {
        const auto image = load_program(options.coe_root, name);
        Rv32Machine machine(image);
        std::vector<BackendModel> models;
        models.reserve(configs.size());
        for (const auto& config : configs) {
            models.emplace_back(config);
        }

        auto next_progress = options.progress_instructions;
        while (!machine.reached_stop() &&
               (options.max_instructions == 0u ||
                machine.stats().retired_instructions < options.max_instructions)) {
            const auto event = machine.step();
            for (auto& model : models) {
                model.feed(event);
            }
            if (options.progress_instructions != 0u &&
                machine.stats().retired_instructions >= next_progress) {
                std::lock_guard lock(console_mutex);
                std::cerr << "[backend progress] " << name << " trace="
                          << machine.stats().retired_instructions << '\n';
                next_progress += options.progress_instructions;
            }
        }
        result.architectural_completed = machine.reached_stop();
        result.architectural = machine.stats();
        for (auto& model : models) {
            model.finish();
            result.models.push_back(
                {model.config(), model.config_name(), model.stats()});
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }
    result.elapsed_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

std::string csv_quote(const std::string& text) {
    std::string escaped;
    escaped.reserve(text.size() + 2u);
    escaped.push_back('"');
    for (const char character : text) {
        escaped.push_back(character);
        if (character == '"') {
            escaped.push_back('"');
        }
    }
    escaped.push_back('"');
    return escaped;
}

void write_iq_metrics(std::ostream& output, const BackendIqMetrics& metrics) {
    output << ',' << metrics.average_occupancy << ','
           << metrics.maximum_occupancy << ',' << metrics.p95_occupancy << ','
           << metrics.p99_occupancy << ',' << metrics.full_cycles << ','
           << metrics.rename_stall_cycles;
}

void write_per_program_csv(const std::filesystem::path& path,
                           const std::vector<ProgramResult>& results) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "program,architectural_completed,error,config,branch_mode,int_depth,"
              "ls_depth,mdu_depth,checkpoints,lsu_hit_ii,store_buffer_entries,"
              "cycles,trace_instructions,dispatched,issued,retired,"
              "ipc,issue0_cycles,issue1_cycles,issue2_cycles,"
              "int_avg,int_max,int_p95,int_p99,int_full,int_rename_stall,"
              "ls_avg,ls_max,ls_p95,ls_p99,ls_full,ls_rename_stall,"
              "mdu_avg,mdu_max,mdu_p95,mdu_p99,mdu_full,mdu_rename_stall,"
              "rob_full_stall,prf_empty_stall,checkpoint_stall,branch_barrier,"
              "branch_mispredict,global_issue_limit,prf_read_bank_conflict,"
              "int_fu_busy,lsu_busy,lsu_miss_blocked,store_buffer_full,"
              "lsu_max_inflight,store_buffer_max_occupancy,mdu_busy,"
              "wb_bank0_conflict,wb_bank1_conflict,"
              "alu0_result_hold,alu1_result_hold,lsu_result_hold,mdu_result_hold,"
              "load_hits,load_misses,elapsed_seconds\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& program : results) {
        if (program.models.empty()) {
            output << program.name << ',' << program.architectural_completed << ','
                   << csv_quote(program.error) << "\n";
            continue;
        }
        for (const auto& model : program.models) {
            const auto& stats = model.stats;
            output << program.name << ',' << program.architectural_completed << ','
                   << csv_quote(program.error) << ',' << model.config_name << ','
                   << backend_branch_mode_name(model.config.branch_mode) << ','
                   << model.config.int_iq_depth << ',' << model.config.ls_iq_depth
                   << ',' << model.config.mdu_iq_depth << ','
                   << model.config.checkpoints << ','
                   << model.config.lsu_hit_initiation_interval << ','
                   << model.config.store_buffer_entries << ',' << stats.cycles
                   << ','
                   << stats.trace_instructions << ','
                   << stats.dispatched_instructions << ','
                   << stats.issued_instructions << ','
                   << stats.retired_instructions << ',' << stats.ipc() << ','
                   << stats.issue_zero_cycles << ',' << stats.issue_one_cycles
                   << ',' << stats.issue_two_cycles;
            write_iq_metrics(output, stats.int_iq);
            write_iq_metrics(output, stats.ls_iq);
            write_iq_metrics(output, stats.mdu_iq);
            output << ',' << stats.rob_full_stall_cycles << ','
                   << stats.prf_empty_stall_cycles << ','
                   << stats.checkpoint_stall_cycles << ','
                   << stats.branch_barrier_cycles << ','
                   << stats.branch_mispredictions << ','
                   << stats.global_issue_limit_cycles << ','
                   << stats.prf_read_bank_conflict_cycles << ','
                   << stats.int_fu_busy_cycles << ',' << stats.lsu_busy_cycles
                   << ',' << stats.lsu_miss_blocked_cycles << ','
                   << stats.store_buffer_full_cycles << ','
                   << stats.lsu_max_inflight << ','
                   << stats.store_buffer_max_occupancy << ','
                   << stats.mdu_busy_cycles << ','
                   << stats.wb_bank0_conflict_cycles << ','
                   << stats.wb_bank1_conflict_cycles << ','
                   << stats.alu0_result_hold_cycles << ','
                   << stats.alu1_result_hold_cycles << ','
                   << stats.lsu_result_hold_cycles << ','
                   << stats.mdu_result_hold_cycles << ',' << stats.load_hits << ','
                   << stats.load_misses << ',' << program.elapsed_seconds << '\n';
        }
    }
}

struct Aggregate {
    BackendConfig config{};
    std::string name;
    std::uint64_t programs = 0;
    std::uint64_t completed_programs = 0;
    std::uint64_t cycles = 0;
    std::uint64_t retired = 0;
    std::uint64_t int_occ_weighted = 0;
    std::uint64_t ls_occ_weighted = 0;
    std::uint64_t mdu_occ_weighted = 0;
    std::uint32_t int_max = 0;
    std::uint32_t ls_max = 0;
    std::uint32_t mdu_max = 0;
    BackendStats totals{};
};

void add_totals(BackendStats& total, const BackendStats& value) {
    total.trace_instructions += value.trace_instructions;
    total.dispatched_instructions += value.dispatched_instructions;
    total.issued_instructions += value.issued_instructions;
    total.issue_zero_cycles += value.issue_zero_cycles;
    total.issue_one_cycles += value.issue_one_cycles;
    total.issue_two_cycles += value.issue_two_cycles;
    total.rob_full_stall_cycles += value.rob_full_stall_cycles;
    total.prf_empty_stall_cycles += value.prf_empty_stall_cycles;
    total.checkpoint_stall_cycles += value.checkpoint_stall_cycles;
    total.branch_barrier_cycles += value.branch_barrier_cycles;
    total.branch_mispredictions += value.branch_mispredictions;
    total.global_issue_limit_cycles += value.global_issue_limit_cycles;
    total.prf_read_bank_conflict_cycles += value.prf_read_bank_conflict_cycles;
    total.int_fu_busy_cycles += value.int_fu_busy_cycles;
    total.lsu_busy_cycles += value.lsu_busy_cycles;
    total.lsu_miss_blocked_cycles += value.lsu_miss_blocked_cycles;
    total.store_buffer_full_cycles += value.store_buffer_full_cycles;
    total.lsu_max_inflight =
        std::max(total.lsu_max_inflight, value.lsu_max_inflight);
    total.store_buffer_max_occupancy = std::max(
        total.store_buffer_max_occupancy,
        value.store_buffer_max_occupancy);
    total.mdu_busy_cycles += value.mdu_busy_cycles;
    total.wb_bank0_conflict_cycles += value.wb_bank0_conflict_cycles;
    total.wb_bank1_conflict_cycles += value.wb_bank1_conflict_cycles;
    total.alu0_result_hold_cycles += value.alu0_result_hold_cycles;
    total.alu1_result_hold_cycles += value.alu1_result_hold_cycles;
    total.lsu_result_hold_cycles += value.lsu_result_hold_cycles;
    total.mdu_result_hold_cycles += value.mdu_result_hold_cycles;
    total.load_hits += value.load_hits;
    total.load_misses += value.load_misses;
    total.int_iq.full_cycles += value.int_iq.full_cycles;
    total.int_iq.rename_stall_cycles += value.int_iq.rename_stall_cycles;
    total.ls_iq.full_cycles += value.ls_iq.full_cycles;
    total.ls_iq.rename_stall_cycles += value.ls_iq.rename_stall_cycles;
    total.mdu_iq.full_cycles += value.mdu_iq.full_cycles;
    total.mdu_iq.rename_stall_cycles += value.mdu_iq.rename_stall_cycles;
}

void write_aggregate_csv(const std::filesystem::path& path,
                         const std::vector<ProgramResult>& results) {
    std::map<std::string, Aggregate> aggregates;
    for (const auto& program : results) {
        for (const auto& model : program.models) {
            auto& aggregate = aggregates[model.config_name];
            aggregate.config = model.config;
            aggregate.name = model.config_name;
            ++aggregate.programs;
            aggregate.completed_programs +=
                static_cast<std::uint64_t>(program.architectural_completed);
            aggregate.cycles += model.stats.cycles;
            aggregate.retired += model.stats.retired_instructions;
            aggregate.int_occ_weighted += static_cast<std::uint64_t>(
                std::llround(model.stats.int_iq.average_occupancy *
                             static_cast<double>(model.stats.cycles)));
            aggregate.ls_occ_weighted += static_cast<std::uint64_t>(
                std::llround(model.stats.ls_iq.average_occupancy *
                             static_cast<double>(model.stats.cycles)));
            aggregate.mdu_occ_weighted += static_cast<std::uint64_t>(
                std::llround(model.stats.mdu_iq.average_occupancy *
                             static_cast<double>(model.stats.cycles)));
            aggregate.int_max = std::max(
                aggregate.int_max, model.stats.int_iq.maximum_occupancy);
            aggregate.ls_max = std::max(
                aggregate.ls_max, model.stats.ls_iq.maximum_occupancy);
            aggregate.mdu_max = std::max(
                aggregate.mdu_max, model.stats.mdu_iq.maximum_occupancy);
            add_totals(aggregate.totals, model.stats);
        }
    }

    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "config,branch_mode,int_depth,ls_depth,mdu_depth,checkpoints,"
              "lsu_hit_ii,store_buffer_entries,programs,"
              "completed_programs,cycles,retired,weighted_ipc,int_avg,int_max,"
              "int_full,int_rename_stall,ls_avg,ls_max,ls_full,ls_rename_stall,"
              "mdu_avg,mdu_max,mdu_full,mdu_rename_stall,rob_full_stall,"
              "prf_empty_stall,checkpoint_stall,branch_barrier,branch_mispredict,"
              "global_issue_limit,prf_read_bank_conflict,int_fu_busy,lsu_busy,"
              "lsu_miss_blocked,store_buffer_full,lsu_max_inflight,"
              "store_buffer_max_occupancy,mdu_busy,wb_bank0_conflict,"
              "wb_bank1_conflict,alu0_result_hold,"
              "alu1_result_hold,lsu_result_hold,mdu_result_hold,load_hits,"
              "load_misses\n";
    output << std::fixed << std::setprecision(6);
    for (const auto& [name, aggregate] : aggregates) {
        const auto average = [&](const std::uint64_t weighted) {
            return aggregate.cycles == 0u
                ? 0.0
                : static_cast<double>(weighted) /
                      static_cast<double>(aggregate.cycles);
        };
        const auto weighted_ipc = aggregate.cycles == 0u
            ? 0.0
            : static_cast<double>(aggregate.retired) /
                  static_cast<double>(aggregate.cycles);
        const auto& totals = aggregate.totals;
        output << name << ','
               << backend_branch_mode_name(aggregate.config.branch_mode) << ','
               << aggregate.config.int_iq_depth << ','
               << aggregate.config.ls_iq_depth << ','
               << aggregate.config.mdu_iq_depth << ','
               << aggregate.config.checkpoints << ','
               << aggregate.config.lsu_hit_initiation_interval << ','
               << aggregate.config.store_buffer_entries << ','
               << aggregate.programs
               << ',' << aggregate.completed_programs << ',' << aggregate.cycles
               << ',' << aggregate.retired << ',' << weighted_ipc << ','
               << average(aggregate.int_occ_weighted) << ',' << aggregate.int_max
               << ',' << totals.int_iq.full_cycles << ','
               << totals.int_iq.rename_stall_cycles << ','
               << average(aggregate.ls_occ_weighted) << ',' << aggregate.ls_max
               << ',' << totals.ls_iq.full_cycles << ','
               << totals.ls_iq.rename_stall_cycles << ','
               << average(aggregate.mdu_occ_weighted) << ',' << aggregate.mdu_max
               << ',' << totals.mdu_iq.full_cycles << ','
               << totals.mdu_iq.rename_stall_cycles << ','
               << totals.rob_full_stall_cycles << ','
               << totals.prf_empty_stall_cycles << ','
               << totals.checkpoint_stall_cycles << ','
               << totals.branch_barrier_cycles << ','
               << totals.branch_mispredictions << ','
               << totals.global_issue_limit_cycles << ','
               << totals.prf_read_bank_conflict_cycles << ','
               << totals.int_fu_busy_cycles << ',' << totals.lsu_busy_cycles << ','
               << totals.lsu_miss_blocked_cycles << ','
               << totals.store_buffer_full_cycles << ','
               << totals.lsu_max_inflight << ','
               << totals.store_buffer_max_occupancy << ','
               << totals.mdu_busy_cycles << ','
               << totals.wb_bank0_conflict_cycles << ','
               << totals.wb_bank1_conflict_cycles << ','
               << totals.alu0_result_hold_cycles << ','
               << totals.alu1_result_hold_cycles << ','
               << totals.lsu_result_hold_cycles << ','
               << totals.mdu_result_hold_cycles << ',' << totals.load_hits << ','
               << totals.load_misses << '\n';
    }
}

}  // namespace
}  // namespace archsim

int main(const int argc, char** argv) {
    using namespace archsim;
    try {
        const auto options = parse_options(argc, argv);
        const auto configs = make_configs(options);
        std::filesystem::create_directories(options.output_dir);

        std::cout << "Backend IQ study: programs=" << options.programs.size()
                  << " configs=" << configs.size()
                  << " branch_mode="
                  << backend_branch_mode_name(options.base_config.branch_mode)
                  << " jobs=" << options.jobs << '\n';
        std::cout << "Resources: Rename=2 Issue=2 Commit=2 ROB=32 PRF=64 "
                     "PRF reads=2/bank writes=1/bank checkpoints="
                  << options.base_config.checkpoints
                  << " store_buffer="
                  << options.base_config.store_buffer_entries << '\n';
        std::cout << "Latencies: regread=" << options.base_config.regread_latency
                  << " ALU=" << options.base_config.alu_latency
                  << " MUL=" << options.base_config.mul_latency
                  << " DIV=" << options.base_config.div_latency
                  << " Load(hit/miss)="
                  << options.base_config.load_hit_latency << '/'
                  << options.base_config.load_miss_latency
                  << " Store=" << options.base_config.store_latency
                  << " LSU_hit_II="
                  << options.base_config.lsu_hit_initiation_interval
                  << " Store_drain="
                  << options.base_config.store_drain_latency
                  << " GShare_update_delay="
                  << options.base_config.branch_update_delay_instructions
                  << " instructions\n";

        std::vector<ProgramResult> results(options.programs.size());
        std::atomic<std::size_t> next_program{0};
        const auto worker_count = std::min<std::size_t>(
            options.jobs, options.programs.size());
        std::vector<std::thread> workers;
        workers.reserve(worker_count);
        for (std::size_t worker = 0; worker < worker_count; ++worker) {
            workers.emplace_back([&]() {
                while (true) {
                    const auto index = next_program.fetch_add(1u);
                    if (index >= options.programs.size()) {
                        break;
                    }
                    results[index] = run_program(
                        options, options.programs[index], configs);
                    std::lock_guard lock(console_mutex);
                    std::cout << "[backend done] " << options.programs[index]
                              << " retired="
                              << results[index].architectural.retired_instructions
                              << " models=" << results[index].models.size()
                              << " elapsed=" << std::fixed << std::setprecision(2)
                              << results[index].elapsed_seconds << "s";
                    if (!results[index].error.empty()) {
                        std::cout << " error=" << results[index].error;
                    }
                    std::cout << '\n';
                }
            });
        }
        for (auto& worker : workers) {
            worker.join();
        }

        write_per_program_csv(options.output_dir / "backend_per_program.csv",
                              results);
        write_aggregate_csv(options.output_dir / "backend_aggregate.csv", results);

        const auto failed = std::count_if(
            results.begin(), results.end(), [](const ProgramResult& result) {
                return !result.error.empty();
            });
        std::cout << "Wrote " << (options.output_dir / "backend_per_program.csv")
                  << " and " << (options.output_dir / "backend_aggregate.csv")
                  << '\n';
        return failed == 0 ? 0 : 1;
    } catch (const std::exception& exception) {
        std::cerr << "backend_iq_study: " << exception.what() << '\n';
        return 1;
    }
}
