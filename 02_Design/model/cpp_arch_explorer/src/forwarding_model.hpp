#pragma once

#include "rv32_sim.hpp"

#include <array>
#include <bitset>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <string>

namespace archsim {

// A network is a physically meaningful producer group in the current RTL.
// Ordinary paths fan out to all four ID operands, while MUL paths feed the
// physically separate DSP operand copy.
enum class ForwardingNetwork : std::uint8_t {
    IdS1Ex,
    IdS0Ex,
    IdS1Mem,
    IdS0Mem,
    IdS1Wb,
    IdS0Wb,
    LoadRepairS1Mem,
    LoadRepairS0Mem,
    MulS1Mem,
    MulS0Mem,
    MulS1Wb,
    MulS0Wb,
    PairS0AluToS1StoreData,
    Count,
};

constexpr std::size_t kForwardingNetworkCount =
    static_cast<std::size_t>(ForwardingNetwork::Count);
// Exact depths 0..3 plus a saturated 4+ bucket.
constexpr std::size_t kForwardingChainDepthBucketCount = 5;

const char* forwarding_network_name(ForwardingNetwork network);
const std::array<ForwardingNetwork, kForwardingNetworkCount>&
all_forwarding_networks();

struct ForwardingNetworkMask {
    std::bitset<kForwardingNetworkCount> enabled{};

    static ForwardingNetworkMask all();
    static ForwardingNetworkMask without(ForwardingNetwork network);
    [[nodiscard]] bool has(ForwardingNetwork network) const;
};

enum class ForwardingSource : std::uint8_t {
    S1Ex,
    S0Ex,
    S1Mem,
    S0Mem,
    S1Wb,
    S0Wb,
    RegisterFile,
};

enum class RepairSource : std::uint8_t {
    None,
    S1MemLoad,
    S0MemLoad,
};

struct ForwardingProducer {
    bool valid = false;
    bool reg_write = false;
    bool mem_read = false;
    bool is_load = false;
    bool is_mul = false;
    bool is_muldiv = false;
    bool fast_alu = true;
    std::uint8_t rd = 0;
    std::uint8_t wb_sel = 0;  // 0=execute, 1=load, 2=PC+4
    std::uint32_t alu_result = 0;
    std::uint32_t fast_alu_result = 0;
    std::uint32_t mul_result = 0;
    std::uint32_t pc_plus_4 = 0;
    std::uint32_t write_data = 0;
};

struct ForwardingConsumer {
    bool valid = true;
    bool rs1_used = false;
    bool rs2_used = false;
    bool alu_only = false;
    bool indirect_control = false;
    bool conditional_control = false;
    bool mem_read = false;
    bool mem_write = false;
    bool is_mul = false;
    bool repair_ok = false;  // Slot 1 uses its registered issue-hint rule.
    std::uint8_t rs1 = 0;
    std::uint8_t rs2 = 0;
    std::uint8_t alu_src1_sel = 0;
    bool alu_src2_imm = false;
    std::uint32_t pc = 0;
    std::uint32_t imm = 0;
    std::uint32_t rf_rs1 = 0;
    std::uint32_t rf_rs2 = 0;
};

struct ForwardingInputs {
    ForwardingConsumer s0{};
    ForwardingConsumer s1{};
    ForwardingProducer ex_s0{};
    ForwardingProducer ex_s1{};
    ForwardingProducer mem_s0{};
    ForwardingProducer mem_s1{};
    ForwardingProducer wb_s0{};
    ForwardingProducer wb_s1{};
    bool mem_load_ready = true;
};

struct ForwardedOperand {
    std::uint32_t data = 0;
    ForwardingSource source = ForwardingSource::RegisterFile;
    RepairSource repair = RepairSource::None;
};

struct ForwardingOutputs {
    std::array<ForwardedOperand, 2> s0{};
    std::array<ForwardedOperand, 2> s1{};
    std::array<ForwardedOperand, 2> mul{};
    std::array<std::uint32_t, 2> s0_alu{};
    std::array<std::uint32_t, 2> s1_alu{};
    bool id_ready_go = true;
    bool id_ready_go_if_mem_ready = true;
    bool id_ready_go_if_mem_wait = true;
    bool load_use_hazard = false;
    bool muldiv_use_hazard = false;
    bool mul_launch_ex_raw_hazard = false;
};

// Bit-accurate combinational model of forwarding.sv and
// mul_operand_forwarding. With ForwardingNetworkMask::all(), data priority,
// load-repair tags, and ready signals match the RTL.
ForwardingOutputs evaluate_forwarding(
    const ForwardingInputs& inputs,
    const ForwardingNetworkMask& mask = ForwardingNetworkMask::all());

struct ForwardingDecodedInstruction {
    std::uint64_t ordinal = 0;
    std::uint32_t pc = 0;
    std::uint32_t instruction = 0;
    bool predicted_taken = false;
    bool writes_rd = false;
    bool uses_rs1 = false;
    bool uses_rs2 = false;
    bool is_alu_type = false;
    bool is_load = false;
    bool is_store = false;
    bool is_branch = false;
    bool is_jal = false;
    bool is_jalr = false;
    bool is_muldiv = false;
    bool is_mul = false;
    bool force_single = false;
    std::uint8_t rd = 0;
    std::uint8_t rs1 = 0;
    std::uint8_t rs2 = 0;
};

ForwardingDecodedInstruction decode_forwarding_instruction(
    const CfiEvent& event);
bool forwarding_pair_ok(const ForwardingDecodedInstruction& first,
                        const ForwardingDecodedInstruction& second,
                        bool pair_bypass_enabled = true);

struct ForwardingStudyStats {
    bool finished = false;
    std::uint64_t cycles = 0;
    std::uint64_t instructions = 0;
    std::uint64_t single_issue_cycles = 0;
    std::uint64_t dual_issue_cycles = 0;
    std::uint64_t rtl_hazard_stall_cycles = 0;
    std::uint64_t removed_network_stall_cycles = 0;
    std::uint64_t removed_pair_opportunities = 0;
    std::array<std::uint64_t, kForwardingNetworkCount> selected_hits{};
    // [network][consumer slot * 2 + operand], where operand 0/1 is rs1/rs2.
    std::array<std::array<std::uint64_t, 4>, kForwardingNetworkCount>
        selected_hits_by_operand{};

    // A strict continuous dependency is A -> B -> C where B consumes an
    // in-flight A and, before B retires, becomes the selected producer for C.
    std::uint64_t inflight_consumer_instructions = 0;
    std::uint64_t eligible_middle_instructions = 0;
    std::uint64_t continuous_middle_instructions = 0;
    std::uint64_t continuous_operand_edges = 0;
    std::uint64_t continuous_instruction_pairs = 0;
    std::uint64_t continuous_chain_triplets = 0;
    std::uint64_t cycles_with_continuous_forwarding = 0;
    std::uint64_t maximum_continuous_chain_depth = 0;
    std::array<std::uint64_t, kForwardingChainDepthBucketCount>
        chain_depth_histogram{};
    // An incoming edge is counted once when its consumer first becomes a
    // continuous middle instruction. Outgoing edges are counted per selected
    // consumer operand.
    std::array<std::uint64_t, kForwardingNetworkCount>
        continuous_incoming_edges{};
    std::array<std::uint64_t, kForwardingNetworkCount>
        continuous_outgoing_edges{};
    std::array<std::array<std::uint64_t, 4>, kForwardingNetworkCount>
        continuous_outgoing_edges_by_operand{};
    // [A -> B network][B -> C network], counted per pair of operand edges.
    std::array<std::array<std::uint64_t, kForwardingNetworkCount>,
               kForwardingNetworkCount>
        continuous_network_pairs{};
};

// Ideal-front-end pipeline study. The only baseline waits are the RAW waits
// required by the current RTL. A differential model adds an interlock whenever
// its removed network would otherwise expose a stale value.
class ForwardingStudyModel {
public:
    explicit ForwardingStudyModel(
        ForwardingNetworkMask mask = ForwardingNetworkMask::all());

    void feed(const CfiEvent& event);
    void feed(const ForwardingDecodedInstruction& instruction);
    void finish();

    [[nodiscard]] const ForwardingNetworkMask& mask() const { return mask_; }
    [[nodiscard]] const ForwardingStudyStats& stats() const { return stats_; }

private:
    struct DependencyTag {
        bool valid = false;
        std::uint64_t producer_ordinal = 0;
        ForwardingNetwork network = ForwardingNetwork::Count;
    };
    struct Token {
        ForwardingDecodedInstruction decoded{};
        std::array<DependencyTag, 2> incoming{};
        std::uint32_t continuous_chain_depth = 0;
        bool counted_as_continuous_middle = false;
    };
    struct Bundle {
        std::array<Token, 2> slot{};
        std::uint8_t count = 0;
    };
    struct Delivery {
        bool ready = true;
        bool rtl_hazard = false;
        ForwardingNetwork network = ForwardingNetwork::Count;
        std::uint64_t producer_ordinal = 0;
    };
    using DeliveryMatrix = std::array<std::array<Delivery, 2>, 2>;

    void run_until_one_trace_entry();
    void tick(bool draining);
    [[nodiscard]] Bundle candidate_bundle() const;
    [[nodiscard]] Delivery delivery_for(const Token& consumer,
                                        std::uint8_t consumer_slot,
                                        std::uint8_t operand,
                                        const Bundle& candidate) const;
    [[nodiscard]] const Token* youngest_writer(std::uint8_t reg) const;
    [[nodiscard]] const Token* writer_in(const Bundle& bundle,
                                         std::uint8_t reg) const;
    [[nodiscard]] static bool writes(const Token& token, std::uint8_t reg);
    [[nodiscard]] static bool has_inflight_dependency(const Token& token);
    [[nodiscard]] static Token* token_in(Bundle& bundle,
                                         std::uint64_t ordinal);
    [[nodiscard]] Token* producer_token(Bundle& issued,
                                        std::uint64_t ordinal);
    void annotate_issued_dependencies(Bundle& issued,
                                      const DeliveryMatrix& deliveries);
    void record_issued_dependencies(Bundle& issued,
                                    const DeliveryMatrix& deliveries);

    ForwardingNetworkMask mask_;
    std::deque<Token> trace_;
    Bundle ex_{};
    Bundle mem_{};
    Bundle wb_{};
    ForwardingStudyStats stats_{};
};

}  // namespace archsim
