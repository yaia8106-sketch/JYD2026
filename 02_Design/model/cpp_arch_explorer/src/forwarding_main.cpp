#include "forwarding_model.hpp"
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
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
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
    std::filesystem::path output_dir = "/tmp/forwarding_study_results";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::uint64_t max_instructions = 0;
    std::uint64_t progress_instructions = 100'000'000u;
    unsigned jobs = std::clamp(std::thread::hardware_concurrency(), 1u, 16u);
    bool baseline_only = false;
};

struct VariantResult {
    ForwardingNetwork removed = ForwardingNetwork::Count;
    ForwardingStudyStats stats{};
};

struct ProgramResult {
    std::string name;
    bool architectural_completed = false;
    std::string error;
    ArchitecturalStats architectural{};
    ForwardingStudyStats baseline{};
    std::vector<VariantResult> variants;
    double elapsed_seconds = 0.0;
};

std::mutex console_mutex;

std::vector<std::string> split(const std::string& text,
                               const char delimiter) {
    std::vector<std::string> result;
    std::stringstream stream(text);
    for (std::string part; std::getline(stream, part, delimiter);) {
        if (!part.empty()) {
            result.push_back(part);
        }
    }
    return result;
}

void usage(const char* executable) {
    std::cout
        << "Usage: " << executable << " [options]\n\n"
        << "  --coe-root PATH       Root containing single_issue COE programs\n"
        << "  --output-dir PATH     CSV directory (default /tmp/forwarding_study_results)\n"
        << "  --programs A,B,...    Default: all six contest programs\n"
        << "  --jobs N              Programs simulated in parallel, max 16\n"
        << "  --max-instructions N  Truncated smoke run (0 = full)\n"
        << "  --progress N          Trace progress interval (0 = disabled)\n"
        << "  --baseline-only       Skip 13 ablations; write chain CSVs only\n"
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
        } else if (argument == "--jobs") {
            options.jobs = std::clamp(
                static_cast<unsigned>(std::stoul(value(argument))), 1u, 16u);
        } else if (argument == "--max-instructions") {
            options.max_instructions = std::stoull(value(argument));
        } else if (argument == "--progress") {
            options.progress_instructions = std::stoull(value(argument));
        } else if (argument == "--baseline-only") {
            options.baseline_only = true;
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

ProgramResult run_program(const Options& options, const std::string& name) {
    ProgramResult result;
    result.name = name;
    const auto start = std::chrono::steady_clock::now();
    try {
        const auto image = load_program(options.coe_root, name);
        Rv32Machine machine(image);
        ForwardingStudyModel baseline;
        std::vector<ForwardingStudyModel> mutants;
        if (!options.baseline_only) {
            mutants.reserve(kForwardingNetworkCount);
            for (const auto network : all_forwarding_networks()) {
                mutants.emplace_back(
                    ForwardingNetworkMask::without(network));
            }
        }

        auto next_progress = options.progress_instructions;
        while (!machine.reached_stop() &&
               (options.max_instructions == 0u ||
                machine.stats().retired_instructions <
                    options.max_instructions)) {
            const auto event = machine.step();
            const auto decoded = decode_forwarding_instruction(event);
            baseline.feed(decoded);
            for (auto& mutant : mutants) {
                mutant.feed(decoded);
            }
            if (options.progress_instructions != 0u &&
                machine.stats().retired_instructions >= next_progress) {
                std::lock_guard lock(console_mutex);
                std::cerr << "[forwarding progress] " << name << " trace="
                          << machine.stats().retired_instructions << '\n';
                next_progress += options.progress_instructions;
            }
        }

        baseline.finish();
        for (auto& mutant : mutants) {
            mutant.finish();
        }
        result.architectural_completed = machine.reached_stop();
        result.architectural = machine.stats();
        result.baseline = baseline.stats();
        for (std::size_t index = 0; index < mutants.size(); ++index) {
            result.variants.push_back(
                {all_forwarding_networks()[index], mutants[index].stats()});
        }
    } catch (const std::exception& exception) {
        result.error = exception.what();
    }
    result.elapsed_seconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    return result;
}

std::string csv_quote(const std::string& text) {
    std::string result{"\""};
    for (const auto character : text) {
        result.push_back(character);
        if (character == '"') {
            result.push_back(character);
        }
    }
    result.push_back('"');
    return result;
}

std::int64_t cycle_delta(const std::uint64_t mutant,
                         const std::uint64_t baseline) {
    if (mutant >= baseline) {
        return static_cast<std::int64_t>(mutant - baseline);
    }
    return -static_cast<std::int64_t>(baseline - mutant);
}

double probability(const std::uint64_t numerator,
                   const std::uint64_t denominator) {
    return denominator == 0u
        ? 0.0
        : static_cast<double>(numerator) /
              static_cast<double>(denominator);
}

std::uint64_t total_selected_hits(const ForwardingStudyStats& stats) {
    std::uint64_t total = 0;
    for (const auto hits : stats.selected_hits) {
        total += hits;
    }
    return total;
}

void add_chain_stats(ForwardingStudyStats& total,
                     const ForwardingStudyStats& value) {
    total.cycles += value.cycles;
    total.instructions += value.instructions;
    total.single_issue_cycles += value.single_issue_cycles;
    total.dual_issue_cycles += value.dual_issue_cycles;
    total.inflight_consumer_instructions +=
        value.inflight_consumer_instructions;
    total.eligible_middle_instructions +=
        value.eligible_middle_instructions;
    total.continuous_middle_instructions +=
        value.continuous_middle_instructions;
    total.continuous_operand_edges += value.continuous_operand_edges;
    total.continuous_instruction_pairs +=
        value.continuous_instruction_pairs;
    total.continuous_chain_triplets += value.continuous_chain_triplets;
    total.cycles_with_continuous_forwarding +=
        value.cycles_with_continuous_forwarding;
    total.maximum_continuous_chain_depth = std::max(
        total.maximum_continuous_chain_depth,
        value.maximum_continuous_chain_depth);
    for (std::size_t depth = 0;
         depth < kForwardingChainDepthBucketCount; ++depth) {
        total.chain_depth_histogram[depth] +=
            value.chain_depth_histogram[depth];
    }
    for (std::size_t network = 0;
         network < kForwardingNetworkCount; ++network) {
        total.selected_hits[network] += value.selected_hits[network];
        total.continuous_incoming_edges[network] +=
            value.continuous_incoming_edges[network];
        total.continuous_outgoing_edges[network] +=
            value.continuous_outgoing_edges[network];
        for (std::size_t operand = 0; operand < 4u; ++operand) {
            total.selected_hits_by_operand[network][operand] +=
                value.selected_hits_by_operand[network][operand];
            total.continuous_outgoing_edges_by_operand[network][operand] +=
                value.continuous_outgoing_edges_by_operand[network][operand];
        }
        for (std::size_t outgoing = 0;
             outgoing < kForwardingNetworkCount; ++outgoing) {
            total.continuous_network_pairs[network][outgoing] +=
                value.continuous_network_pairs[network][outgoing];
        }
    }
}

void write_chain_summary_row(std::ostream& output,
                             const std::string& scope,
                             const std::uint64_t program_count,
                             const std::uint64_t completed_programs,
                             const std::string& error,
                             const ForwardingStudyStats& stats,
                             const double elapsed_seconds) {
    const auto issue_cycles =
        stats.single_issue_cycles + stats.dual_issue_cycles;
    const auto forwarding_hits = total_selected_hits(stats);
    output << scope << ',' << program_count << ',' << completed_programs
           << ',' << csv_quote(error) << ',' << stats.instructions << ','
           << stats.cycles << ',' << issue_cycles << ','
           << forwarding_hits << ','
           << stats.inflight_consumer_instructions << ','
           << stats.eligible_middle_instructions << ','
           << stats.continuous_middle_instructions << ','
           << stats.continuous_operand_edges << ','
           << stats.continuous_instruction_pairs << ','
           << stats.continuous_chain_triplets << ','
           << stats.cycles_with_continuous_forwarding << ','
           << probability(stats.continuous_middle_instructions,
                          stats.eligible_middle_instructions)
           << ','
           << probability(stats.continuous_middle_instructions,
                          stats.instructions)
           << ','
           << probability(stats.continuous_operand_edges, forwarding_hits)
           << ','
           << probability(stats.cycles_with_continuous_forwarding,
                          issue_cycles)
           << ','
           << probability(stats.cycles_with_continuous_forwarding,
                          stats.cycles)
           << ',' << stats.maximum_continuous_chain_depth;
    for (const auto count : stats.chain_depth_histogram) {
        output << ',' << count;
    }
    output << ',' << elapsed_seconds << '\n';
}

void write_chain_summary(const std::filesystem::path& path,
                         const std::vector<ProgramResult>& programs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output
        << "scope,programs,completed_programs,error,instructions,cycles,"
           "issue_cycles,total_forwarding_operand_hits,"
           "inflight_consumer_instructions,eligible_middle_instructions,"
           "continuous_middle_instructions,continuous_operand_edges,"
           "continuous_instruction_pairs,continuous_chain_triplets,"
           "cycles_with_continuous_forwarding,relay_probability,"
           "program_probability,traffic_probability,"
           "issue_cycle_probability,total_cycle_probability,"
           "maximum_chain_depth,depth_0,depth_1,depth_2,depth_3,"
           "depth_4_plus,elapsed_seconds\n";
    output << std::fixed << std::setprecision(9);

    ForwardingStudyStats aggregate;
    std::uint64_t successful_programs = 0;
    std::uint64_t completed_programs = 0;
    double elapsed_seconds = 0.0;
    for (const auto& program : programs) {
        write_chain_summary_row(
            output, program.name, 1u,
            static_cast<std::uint64_t>(program.architectural_completed),
            program.error, program.baseline, program.elapsed_seconds);
        if (!program.error.empty()) {
            continue;
        }
        ++successful_programs;
        completed_programs +=
            static_cast<std::uint64_t>(program.architectural_completed);
        elapsed_seconds += program.elapsed_seconds;
        add_chain_stats(aggregate, program.baseline);
    }
    write_chain_summary_row(
        output, "ALL", successful_programs, completed_programs, "",
        aggregate, elapsed_seconds);
}

void write_chain_network_rows(std::ostream& output,
                              const std::string& scope,
                              const ForwardingStudyStats& stats) {
    for (const auto network : all_forwarding_networks()) {
        const auto index = static_cast<std::size_t>(network);
        const auto selected = stats.selected_hits[index];
        output << scope << ',' << forwarding_network_name(network) << ','
               << selected << ','
               << stats.continuous_incoming_edges[index] << ','
               << stats.continuous_outgoing_edges[index] << ','
               << stats.continuous_outgoing_edges_by_operand[index][0] << ','
               << stats.continuous_outgoing_edges_by_operand[index][1] << ','
               << stats.continuous_outgoing_edges_by_operand[index][2] << ','
               << stats.continuous_outgoing_edges_by_operand[index][3] << ','
               << probability(
                      stats.continuous_incoming_edges[index], selected)
               << ','
               << probability(
                      stats.continuous_outgoing_edges[index], selected)
               << '\n';
    }
}

void write_chain_networks(const std::filesystem::path& path,
                          const std::vector<ProgramResult>& programs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output
        << "scope,network,selected_operand_hits,"
           "continuous_incoming_edges,continuous_outgoing_edges,"
           "outgoing_s0_rs1,outgoing_s0_rs2,outgoing_s1_rs1,"
           "outgoing_s1_rs2,incoming_participation_probability,"
           "outgoing_continuous_probability\n";
    output << std::fixed << std::setprecision(9);

    ForwardingStudyStats aggregate;
    for (const auto& program : programs) {
        if (!program.error.empty()) {
            continue;
        }
        write_chain_network_rows(output, program.name, program.baseline);
        add_chain_stats(aggregate, program.baseline);
    }
    write_chain_network_rows(output, "ALL", aggregate);
}

void write_chain_matrix_rows(std::ostream& output,
                             const std::string& scope,
                             const ForwardingStudyStats& stats) {
    for (const auto incoming : all_forwarding_networks()) {
        const auto incoming_index = static_cast<std::size_t>(incoming);
        for (const auto outgoing : all_forwarding_networks()) {
            const auto outgoing_index = static_cast<std::size_t>(outgoing);
            const auto count =
                stats.continuous_network_pairs[incoming_index]
                                              [outgoing_index];
            output << scope << ',' << forwarding_network_name(incoming)
                   << ',' << forwarding_network_name(outgoing) << ','
                   << count << ','
                   << probability(
                          count, stats.continuous_chain_triplets)
                   << '\n';
        }
    }
}

void write_chain_matrix(const std::filesystem::path& path,
                        const std::vector<ProgramResult>& programs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output << "scope,incoming_network,outgoing_network,chain_triplets,"
              "triplet_probability\n";
    output << std::fixed << std::setprecision(9);

    ForwardingStudyStats aggregate;
    for (const auto& program : programs) {
        if (!program.error.empty()) {
            continue;
        }
        write_chain_matrix_rows(output, program.name, program.baseline);
        add_chain_stats(aggregate, program.baseline);
    }
    write_chain_matrix_rows(output, "ALL", aggregate);
}

void write_per_program(const std::filesystem::path& path,
                       const std::vector<ProgramResult>& programs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output
        << "program,architectural_completed,error,network,instructions,"
           "baseline_hits,s0_rs1_hits,s0_rs2_hits,s1_rs1_hits,s1_rs2_hits,"
           "baseline_cycles,mutant_cycles,extra_cycles,delta_cpi,"
           "baseline_rtl_hazard_stalls,mutant_rtl_hazard_stalls,"
           "removed_network_stalls,removed_pair_opportunities,"
           "baseline_single_issue,baseline_dual_issue,"
           "mutant_single_issue,mutant_dual_issue,elapsed_seconds\n";
    output << std::fixed << std::setprecision(9);
    for (const auto& program : programs) {
        if (program.variants.empty()) {
            output << program.name << ','
                   << program.architectural_completed << ','
                   << csv_quote(program.error) << "\n";
            continue;
        }
        for (const auto& variant : program.variants) {
            const auto index = static_cast<std::size_t>(variant.removed);
            const auto delta =
                cycle_delta(variant.stats.cycles, program.baseline.cycles);
            const auto delta_cpi = program.baseline.instructions == 0u
                ? 0.0
                : static_cast<double>(delta) /
                    static_cast<double>(program.baseline.instructions);
            output << program.name << ','
                   << program.architectural_completed << ','
                   << csv_quote(program.error) << ','
                   << forwarding_network_name(variant.removed) << ','
                   << program.baseline.instructions << ','
                   << program.baseline.selected_hits[index] << ','
                   << program.baseline.selected_hits_by_operand[index][0] << ','
                   << program.baseline.selected_hits_by_operand[index][1] << ','
                   << program.baseline.selected_hits_by_operand[index][2] << ','
                   << program.baseline.selected_hits_by_operand[index][3] << ','
                   << program.baseline.cycles << ','
                   << variant.stats.cycles << ',' << delta << ','
                   << delta_cpi << ','
                   << program.baseline.rtl_hazard_stall_cycles << ','
                   << variant.stats.rtl_hazard_stall_cycles << ','
                   << variant.stats.removed_network_stall_cycles << ','
                   << variant.stats.removed_pair_opportunities << ','
                   << program.baseline.single_issue_cycles << ','
                   << program.baseline.dual_issue_cycles << ','
                   << variant.stats.single_issue_cycles << ','
                   << variant.stats.dual_issue_cycles << ','
                   << program.elapsed_seconds << '\n';
        }
    }
}

void write_aggregate(const std::filesystem::path& path,
                     const std::vector<ProgramResult>& programs) {
    std::ofstream output(path);
    if (!output) {
        throw std::runtime_error("cannot write " + path.string());
    }
    output
        << "network,programs,instructions,baseline_hits,s0_rs1_hits,"
           "s0_rs2_hits,s1_rs1_hits,s1_rs2_hits,baseline_cycles,"
           "mutant_cycles,extra_cycles,delta_cpi,removed_network_stalls,"
           "removed_pair_opportunities\n";
    output << std::fixed << std::setprecision(9);
    for (const auto network : all_forwarding_networks()) {
        const auto index = static_cast<std::size_t>(network);
        std::uint64_t program_count = 0;
        std::uint64_t instructions = 0;
        std::uint64_t hits = 0;
        std::array<std::uint64_t, 4> operand_hits{};
        std::uint64_t baseline_cycles = 0;
        std::uint64_t mutant_cycles = 0;
        std::uint64_t removed_stalls = 0;
        std::uint64_t pair_opportunities = 0;
        for (const auto& program : programs) {
            if (program.variants.size() != kForwardingNetworkCount) {
                continue;
            }
            const auto& mutant = program.variants[index].stats;
            ++program_count;
            instructions += program.baseline.instructions;
            hits += program.baseline.selected_hits[index];
            for (std::size_t operand = 0; operand < operand_hits.size();
                 ++operand) {
                operand_hits[operand] +=
                    program.baseline.selected_hits_by_operand[index][operand];
            }
            baseline_cycles += program.baseline.cycles;
            mutant_cycles += mutant.cycles;
            removed_stalls += mutant.removed_network_stall_cycles;
            pair_opportunities += mutant.removed_pair_opportunities;
        }
        const auto delta = cycle_delta(mutant_cycles, baseline_cycles);
        const auto delta_cpi = instructions == 0u
            ? 0.0
            : static_cast<double>(delta) /
                static_cast<double>(instructions);
        output << forwarding_network_name(network) << ',' << program_count
               << ',' << instructions << ',' << hits << ','
               << operand_hits[0] << ',' << operand_hits[1] << ','
               << operand_hits[2] << ',' << operand_hits[3] << ','
               << baseline_cycles << ',' << mutant_cycles << ',' << delta
               << ',' << delta_cpi << ',' << removed_stalls << ','
               << pair_opportunities << '\n';
    }
}

void print_summary(const std::vector<ProgramResult>& programs) {
    std::cout << "\nForwarding ablation summary\n";
    for (const auto network : all_forwarding_networks()) {
        const auto index = static_cast<std::size_t>(network);
        std::uint64_t hits = 0;
        std::uint64_t baseline_cycles = 0;
        std::uint64_t mutant_cycles = 0;
        for (const auto& program : programs) {
            if (program.variants.size() != kForwardingNetworkCount) {
                continue;
            }
            hits += program.baseline.selected_hits[index];
            baseline_cycles += program.baseline.cycles;
            mutant_cycles += program.variants[index].stats.cycles;
        }
        std::cout << "  " << std::left << std::setw(34)
                  << forwarding_network_name(network)
                  << " hits=" << std::right << std::setw(10) << hits
                  << " extra_cycles=" << std::setw(10)
                  << cycle_delta(mutant_cycles, baseline_cycles) << '\n';
    }
}

void print_chain_summary(const std::vector<ProgramResult>& programs) {
    ForwardingStudyStats aggregate;
    std::cout << "\nContinuous dependency summary\n";
    std::cout << std::fixed << std::setprecision(6);
    for (const auto& program : programs) {
        if (!program.error.empty()) {
            continue;
        }
        const auto forwarding_hits = total_selected_hits(program.baseline);
        std::cout
            << "  " << std::left << std::setw(20) << program.name
            << " relay="
            << probability(
                   program.baseline.continuous_middle_instructions,
                   program.baseline.eligible_middle_instructions)
            << " program="
            << probability(
                   program.baseline.continuous_middle_instructions,
                   program.baseline.instructions)
            << " traffic="
            << probability(
                   program.baseline.continuous_operand_edges,
                   forwarding_hits)
            << " middle=" << std::right
            << program.baseline.continuous_middle_instructions << '\n';
        add_chain_stats(aggregate, program.baseline);
    }
    std::cout
        << "  " << std::left << std::setw(20) << "ALL"
        << " relay="
        << probability(aggregate.continuous_middle_instructions,
                       aggregate.eligible_middle_instructions)
        << " program="
        << probability(aggregate.continuous_middle_instructions,
                       aggregate.instructions)
        << " traffic="
        << probability(aggregate.continuous_operand_edges,
                       total_selected_hits(aggregate))
        << " middle=" << std::right
        << aggregate.continuous_middle_instructions << '\n';
}

}  // namespace
}  // namespace archsim

int main(const int argc, char** argv) {
    using namespace archsim;
    try {
        const auto options = parse_options(argc, argv);
        std::vector<ProgramResult> results(options.programs.size());
        std::atomic<std::size_t> next_program{0u};
        const auto worker_count = std::min<std::size_t>(
            options.jobs, options.programs.size());
        std::vector<std::thread> workers;
        workers.reserve(worker_count);
        for (std::size_t worker = 0; worker < worker_count; ++worker) {
            workers.emplace_back([&] {
                while (true) {
                    const auto index = next_program.fetch_add(1u);
                    if (index >= options.programs.size()) {
                        return;
                    }
                    results[index] =
                        run_program(options, options.programs[index]);
                    std::lock_guard lock(console_mutex);
                    std::cerr << "[forwarding done] "
                              << options.programs[index] << " trace="
                              << results[index].architectural
                                     .retired_instructions
                              << " seconds=" << std::fixed
                              << std::setprecision(2)
                              << results[index].elapsed_seconds << '\n';
                }
            });
        }
        for (auto& worker : workers) {
            worker.join();
        }

        std::filesystem::create_directories(options.output_dir);
        if (!options.baseline_only) {
            write_per_program(options.output_dir /
                                  "forwarding_per_program.csv",
                              results);
            write_aggregate(options.output_dir /
                                "forwarding_aggregate.csv",
                            results);
        }
        write_chain_summary(
            options.output_dir / "forwarding_chain_summary.csv", results);
        write_chain_networks(
            options.output_dir / "forwarding_chain_networks.csv", results);
        write_chain_matrix(
            options.output_dir / "forwarding_chain_matrix.csv", results);
        if (!options.baseline_only) {
            print_summary(results);
        }
        print_chain_summary(results);
        std::cout << "\n";
        if (!options.baseline_only) {
            std::cout
                << "Wrote "
                << (options.output_dir / "forwarding_per_program.csv")
                << "\nWrote "
                << (options.output_dir / "forwarding_aggregate.csv")
                << '\n';
        }
        std::cout << "Wrote "
                  << (options.output_dir /
                      "forwarding_chain_summary.csv")
                  << "\nWrote "
                  << (options.output_dir /
                      "forwarding_chain_networks.csv")
                  << "\nWrote "
                  << (options.output_dir /
                      "forwarding_chain_matrix.csv")
                  << '\n';

        const auto failed = std::count_if(
            results.begin(), results.end(),
            [](const ProgramResult& result) { return !result.error.empty(); });
        return failed == 0 ? 0 : 1;
    } catch (const std::exception& exception) {
        std::cerr << "forwarding_study: " << exception.what() << '\n';
        return 1;
    }
}
