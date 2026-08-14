#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::array kDefaultPrograms{
    "bitcount",       "bubble_sort",    "coremark",       "crc32",
    "dhrystone",      "quick_sort",     "select_sort",    "sha",
    "stream_copy",    "stringsearch",   "fireye_A0",      "fireye_B2",
    "fireye_C0",      "fireye_D1",      "fireye_I2",      "inner_product",
    "lookup_table",   "loop_induction", "my_memcmp",      "minmax_sequence",
};

enum class Family : std::uint8_t {
    Bimodal,
    Gshare,
    Gselect,
};

struct Config {
    std::string name;
    Family family = Family::Gshare;
    std::uint32_t entries = 256;
    std::uint32_t history_bits = 8;
    std::uint32_t update_delay_cycles = 0;
    bool fold_pc = false;
};

struct TraceEvent {
    bool measured = false;
    std::uint64_t cycle = 0;
    std::uint32_t pc = 0;
    bool conditional = false;
    bool direct = false;
    bool indirect = false;
    bool taken = false;
    std::uint32_t target = 0;
    std::uint32_t rtl_index = 0;
    std::uint32_t rtl_counter = 0;
};

struct PendingUpdate {
    std::uint64_t due_cycle = 0;
    std::uint32_t index = 0;
    std::uint8_t counter_snapshot = 0;
    bool taken = false;
};

struct ModelResult {
    Config config;
    std::uint64_t branches = 0;
    std::uint64_t misses = 0;
};

struct ProgramResult {
    std::string name;
    std::uint64_t rtl_branches = 0;
    std::uint64_t rtl_misses = 0;
    std::vector<ModelResult> models;
};

struct Options {
    std::filesystem::path trace_root = "/tmp/nscscc-bpu-traces";
    std::filesystem::path output_dir = "/tmp/nscscc-bpu-model-results";
    std::vector<std::string> programs{kDefaultPrograms.begin(),
                                      kDefaultPrograms.end()};
    std::vector<std::uint32_t> delays{0, 2, 4, 6, 8, 10, 12};
};

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

std::vector<std::uint32_t> parse_delays(const std::string& text) {
    std::vector<std::uint32_t> result;
    for (const auto& part : split(text, ',')) {
        result.push_back(static_cast<std::uint32_t>(std::stoul(part)));
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    if (result.empty()) {
        throw std::runtime_error("at least one delay is required");
    }
    return result;
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
        if (argument == "--trace-root") {
            options.trace_root = value(argument);
        } else if (argument == "--output-dir") {
            options.output_dir = value(argument);
        } else if (argument == "--programs") {
            options.programs = split(value(argument), ',');
        } else if (argument == "--delays") {
            options.delays = parse_delays(value(argument));
        } else if (argument == "-h" || argument == "--help") {
            std::cout
                << "Usage: " << argv[0] << " [options]\n"
                << "  --trace-root PATH    run_rtl_perf_profile result directory\n"
                << "  --output-dir PATH    CSV result directory\n"
                << "  --programs A,B,...   default: all 20 official perf cases\n"
                << "  --delays 0,2,...     resolution-to-lookup delay sweep\n";
            std::exit(0);
        } else {
            throw std::runtime_error("unknown option: " + argument);
        }
    }
    return options;
}

std::uint32_t log2_exact(std::uint32_t value) {
    if (value == 0 || (value & (value - 1)) != 0) {
        throw std::runtime_error("predictor entries must be a power of two");
    }
    std::uint32_t bits = 0;
    while (value > 1) {
        value >>= 1;
        ++bits;
    }
    return bits;
}

std::uint64_t bit_mask(const std::uint32_t width) {
    return width == 0 ? 0 : (std::uint64_t{1} << width) - 1;
}

std::uint32_t fold(const std::uint64_t value,
                   const std::uint32_t value_bits,
                   const std::uint32_t output_bits) {
    if (output_bits == 0) {
        return 0;
    }
    const auto mask = bit_mask(output_bits);
    const auto relevant = value & bit_mask(value_bits);
    std::uint64_t result = 0;
    for (std::uint32_t offset = 0; offset < value_bits;
         offset += output_bits) {
        result ^= (relevant >> offset) & mask;
    }
    return static_cast<std::uint32_t>(result & mask);
}

class Predictor {
public:
    explicit Predictor(Config config)
        : config_(std::move(config)), table_(config_.entries, 1) {
        index_bits_ = log2_exact(config_.entries);
    }

    bool predict_and_train(const TraceEvent& event) {
        apply_due(event.cycle);
        const auto index = lookup_index(event);
        const auto snapshot = table_[index];
        const bool prediction = (snapshot & 2u) != 0;
        pending_.push_back(PendingUpdate{
            event.cycle + config_.update_delay_cycles,
            index,
            snapshot,
            event.taken,
        });
        if (config_.update_delay_cycles == 0) {
            apply_due(event.cycle);
        }
        return prediction;
    }

private:
    std::uint32_t lookup_index(const TraceEvent& event) const {
        const auto pc_word = static_cast<std::uint64_t>(event.pc >> 2u);
        const auto pc_index = config_.fold_pc
                                  ? fold(pc_word, 30, index_bits_)
                                  : static_cast<std::uint32_t>(
                                        pc_word & (config_.entries - 1u));
        if (config_.family == Family::Bimodal) {
            return pc_index;
        }
        // The current RTL carried its prediction-time PHT index alongside
        // this branch.  Since current_index = PC[9:2] XOR GHR, recover the
        // exact committed GHR that this dynamic branch saw at lookup time.
        // This is ISA-independent and avoids guessing GHR visibility from
        // the later resolution cycle.  The delay sweep below is then needed
        // only for candidate PHT write visibility.
        const auto lookup_ghr = static_cast<std::uint64_t>(
            (event.rtl_index ^ ((event.pc >> 2u) & 0xffu)) & 0xffu);
        if (config_.family == Family::Gshare) {
            return pc_index ^
                   fold(lookup_ghr, config_.history_bits, index_bits_);
        }
        const auto history_in_index =
            std::min(config_.history_bits, index_bits_);
        const auto pc_bits = index_bits_ - history_in_index;
        const auto pc_part = pc_bits == 0
                                 ? 0u
                                 : pc_index & static_cast<std::uint32_t>(
                                                   bit_mask(pc_bits));
        const auto history_part = static_cast<std::uint32_t>(
            lookup_ghr & bit_mask(history_in_index));
        return (pc_part << history_in_index) | history_part;
    }

    void apply_due(const std::uint64_t cycle) {
        while (!pending_.empty() && pending_.front().due_cycle <= cycle) {
            const auto update = pending_.front();
            pending_.pop_front();
            if (update.taken) {
                table_[update.index] = static_cast<std::uint8_t>(
                    std::min<unsigned>(3, update.counter_snapshot + 1));
            } else {
                table_[update.index] = update.counter_snapshot == 0
                                           ? 0
                                           : static_cast<std::uint8_t>(
                                                 update.counter_snapshot - 1);
            }
        }
    }

    Config config_;
    std::vector<std::uint8_t> table_;
    std::uint32_t index_bits_ = 0;
    std::deque<PendingUpdate> pending_;
};

std::vector<Config> make_configs(const std::vector<std::uint32_t>& delays) {
    std::vector<Config> configs;
    const auto add = [&](const std::string& name, const Family family,
                         const std::uint32_t entries,
                         const std::uint32_t history,
                         const bool fold_pc = false) {
        for (const auto delay : delays) {
            configs.push_back(Config{
                name,
                family,
                entries,
                history,
                delay,
                fold_pc,
            });
        }
    };

    for (const auto entries : {32u, 64u, 128u, 256u, 512u}) {
        add("BIMODAL_" + std::to_string(entries), Family::Bimodal,
            entries, 0);
    }
    for (const auto entries : {32u, 64u, 128u, 256u, 512u}) {
        add("BIMODAL_" + std::to_string(entries) + "_FOLD",
            Family::Bimodal, entries, 0, true);
    }
    for (const auto entries : {32u, 64u, 128u, 256u, 512u}) {
        for (const auto history : {4u, 6u, 8u}) {
            add("GSHARE_" + std::to_string(entries) + "_H" +
                    std::to_string(history),
                Family::Gshare, entries, history);
        }
    }
    for (const auto entries : {64u, 128u, 256u}) {
        for (const auto history : {2u, 4u, 6u}) {
            add("GSELECT_" + std::to_string(entries) + "_H" +
                    std::to_string(history),
                Family::Gselect, entries, history);
        }
    }
    return configs;
}

TraceEvent parse_event(const std::string& line) {
    TraceEvent event;
    unsigned measured = 0;
    unsigned conditional = 0;
    unsigned direct = 0;
    unsigned indirect = 0;
    unsigned taken = 0;
    std::string pc;
    std::string target;
    std::string rtl_index;
    std::string rtl_counter;
    std::istringstream stream(line);
    if (!(stream >> measured >> event.cycle >> pc >> conditional >> direct >>
          indirect >> taken >> target >> rtl_index >> rtl_counter)) {
        throw std::runtime_error("malformed BPU trace line: " + line);
    }
    event.measured = measured != 0;
    event.pc = static_cast<std::uint32_t>(std::stoul(pc, nullptr, 16));
    event.conditional = conditional != 0;
    event.direct = direct != 0;
    event.indirect = indirect != 0;
    event.taken = taken != 0;
    event.target = static_cast<std::uint32_t>(
        std::stoul(target, nullptr, 16));
    event.rtl_index = static_cast<std::uint32_t>(
        std::stoul(rtl_index, nullptr, 16));
    event.rtl_counter = static_cast<std::uint32_t>(
        std::stoul(rtl_counter, nullptr, 16));
    return event;
}

ProgramResult run_program(const std::string& name,
                          const std::filesystem::path& trace,
                          const std::vector<Config>& configs) {
    std::ifstream input(trace);
    if (!input) {
        throw std::runtime_error("cannot open " + trace.string());
    }

    ProgramResult result;
    result.name = name;
    result.models.reserve(configs.size());
    std::vector<Predictor> predictors;
    predictors.reserve(configs.size());
    for (const auto& config : configs) {
        result.models.push_back(ModelResult{config, 0, 0});
        predictors.emplace_back(config);
    }

    for (std::string line; std::getline(input, line);) {
        if (line.empty()) {
            continue;
        }
        const auto event = parse_event(line);
        if (!event.conditional) {
            continue;
        }
        if (event.measured) {
            ++result.rtl_branches;
            result.rtl_misses +=
                static_cast<std::uint64_t>(((event.rtl_counter >> 1u) & 1u) !=
                                           event.taken);
        }
        for (std::size_t index = 0; index < predictors.size(); ++index) {
            const bool prediction = predictors[index].predict_and_train(event);
            if (event.measured) {
                ++result.models[index].branches;
                result.models[index].misses +=
                    static_cast<std::uint64_t>(prediction != event.taken);
            }
        }
    }
    return result;
}

double accuracy(const std::uint64_t branches, const std::uint64_t misses) {
    return branches == 0
               ? 0.0
               : 100.0 * static_cast<double>(branches - misses) /
                     static_cast<double>(branches);
}

std::string family_name(const Family family) {
    if (family == Family::Bimodal) {
        return "BIMODAL";
    }
    return family == Family::Gshare ? "GSHARE" : "GSELECT";
}

void write_results(const Options& options,
                   const std::vector<ProgramResult>& programs,
                   const std::vector<Config>& configs) {
    std::filesystem::create_directories(options.output_dir);
    std::ofstream per_program(options.output_dir / "per_program.csv");
    per_program
        << "program,config,family,entries,history_bits,delay_cycles,fold_pc,"
           "storage_bits,two_read_storage_bits,branches,misses,accuracy_pct,"
           "rtl_current_misses,rtl_current_accuracy_pct\n";
    for (const auto& program : programs) {
        for (const auto& model : program.models) {
            const auto storage_bits =
                2ull * model.config.entries + model.config.history_bits;
            const auto two_read_bits =
                4ull * model.config.entries + model.config.history_bits;
            per_program << program.name << ',' << model.config.name << ','
                        << family_name(model.config.family) << ','
                        << model.config.entries << ','
                        << model.config.history_bits << ','
                        << model.config.update_delay_cycles << ','
                        << model.config.fold_pc << ',' << storage_bits << ','
                        << two_read_bits << ',' << model.branches << ','
                        << model.misses << ',' << std::fixed
                        << std::setprecision(8)
                        << accuracy(model.branches, model.misses) << ','
                        << program.rtl_misses << ','
                        << accuracy(program.rtl_branches, program.rtl_misses)
                        << '\n';
        }
    }

    std::ofstream aggregate(options.output_dir / "aggregate.csv");
    aggregate
        << "config,family,entries,history_bits,delay_cycles,fold_pc,"
           "storage_bits,two_read_storage_bits,branches,misses,accuracy_pct,"
           "miss_delta_vs_current_model,miss_change_vs_current_model_pct,"
           "rtl_current_misses,rtl_current_accuracy_pct\n";

    std::uint64_t rtl_branches = 0;
    std::uint64_t rtl_misses = 0;
    for (const auto& program : programs) {
        rtl_branches += program.rtl_branches;
        rtl_misses += program.rtl_misses;
    }

    for (std::size_t index = 0; index < configs.size(); ++index) {
        std::uint64_t branches = 0;
        std::uint64_t misses = 0;
        for (const auto& program : programs) {
            branches += program.models[index].branches;
            misses += program.models[index].misses;
        }
        const auto& config = configs[index];
        std::uint64_t baseline_misses = 0;
        for (std::size_t candidate = 0; candidate < configs.size(); ++candidate) {
            const auto& base = configs[candidate];
            if (base.name == "GSHARE_256_H8" &&
                base.update_delay_cycles == config.update_delay_cycles) {
                for (const auto& program : programs) {
                    baseline_misses += program.models[candidate].misses;
                }
                break;
            }
        }
        const auto delta = static_cast<std::int64_t>(misses) -
                           static_cast<std::int64_t>(baseline_misses);
        const auto delta_pct = baseline_misses == 0
                                   ? 0.0
                                   : 100.0 * static_cast<double>(delta) /
                                         static_cast<double>(baseline_misses);
        aggregate << config.name << ',' << family_name(config.family) << ','
                  << config.entries << ',' << config.history_bits << ','
                  << config.update_delay_cycles << ',' << config.fold_pc << ','
                  << 2ull * config.entries + config.history_bits << ','
                  << 4ull * config.entries + config.history_bits << ','
                  << branches << ',' << misses << ',' << std::fixed
                  << std::setprecision(8) << accuracy(branches, misses) << ','
                  << delta << ',' << delta_pct << ',' << rtl_misses << ','
                  << accuracy(rtl_branches, rtl_misses) << '\n';
    }

    std::ofstream summary(options.output_dir / "summary.txt");
    summary << "Programs: " << programs.size() << '\n'
            << "Measured conditional branches: " << rtl_branches << '\n'
            << "RTL current PHT misses: " << rtl_misses << '\n'
            << "RTL current PHT accuracy: " << std::fixed
            << std::setprecision(6) << accuracy(rtl_branches, rtl_misses)
            << "%\n"
            << "See aggregate.csv and per_program.csv for the full sweep.\n";
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto options = parse_options(argc, argv);
        const auto configs = make_configs(options.delays);
        std::vector<ProgramResult> results;
        results.reserve(options.programs.size());
        for (const auto& program : options.programs) {
            const auto trace = options.trace_root / "work" / program /
                               "bpu.trace";
            std::cout << "Reading " << program << " from " << trace << "\n";
            results.push_back(run_program(program, trace, configs));
        }
        write_results(options, results, configs);
        std::cout << "Wrote " << options.output_dir << "\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "ERROR: " << error.what() << '\n';
        return 1;
    }
}
