#include "Vforwarding.h"
#include "forwarding_model.hpp"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>

namespace {

using archsim::ForwardingInputs;
using archsim::RepairSource;

template <typename Actual, typename Expected>
void check_equal(const char* name, const Actual actual,
                 const Expected expected, const std::uint64_t trial) {
    if (actual != expected) {
        throw std::runtime_error(
            "trial " + std::to_string(trial) + " " + name +
            " RTL=" + std::to_string(static_cast<std::uint64_t>(actual)) +
            " model=" +
            std::to_string(static_cast<std::uint64_t>(expected)));
    }
}

void drive_consumer(Vforwarding& rtl, ForwardingInputs& model,
                    std::mt19937_64& random) {
    auto& s0 = model.s0;
    s0.valid = true;
    s0.rs1 = static_cast<std::uint8_t>(random() & 31u);
    s0.rs2 = static_cast<std::uint8_t>(random() & 31u);
    s0.rs1_used = (random() & 1u) != 0u;
    s0.rs2_used = (random() & 1u) != 0u;
    s0.alu_only = (random() & 1u) != 0u;
    s0.indirect_control = (random() & 1u) != 0u;
    s0.conditional_control = (random() & 1u) != 0u;
    s0.mem_read = (random() & 1u) != 0u;
    s0.mem_write = (random() & 1u) != 0u;
    s0.is_mul = (random() & 1u) != 0u;
    s0.pc = static_cast<std::uint32_t>(random());
    s0.imm = static_cast<std::uint32_t>(random());
    s0.alu_src1_sel = static_cast<std::uint8_t>(random() & 3u);
    s0.alu_src2_imm = (random() & 1u) != 0u;
    s0.rf_rs1 = static_cast<std::uint32_t>(random());
    s0.rf_rs2 = static_cast<std::uint32_t>(random());

    rtl.id_rs1_addr = s0.rs1;
    rtl.id_rs2_addr = s0.rs2;
    rtl.id_rs1_used = s0.rs1_used;
    rtl.id_rs2_used = s0.rs2_used;
    rtl.id_s0_alu_only = s0.alu_only;
    rtl.id_s0_indirect_control = s0.indirect_control;
    rtl.id_s0_conditional_control = s0.conditional_control;
    rtl.id_s0_mem_read = s0.mem_read;
    rtl.id_s0_mem_write = s0.mem_write;
    rtl.id_s0_is_mul = s0.is_mul;
    rtl.id_s0_pc = s0.pc;
    rtl.id_s0_imm = s0.imm;
    rtl.id_s0_alu_src1_sel = s0.alu_src1_sel;
    rtl.id_s0_alu_src2_sel = s0.alu_src2_imm;
    rtl.rf_rs1_data = s0.rf_rs1;
    rtl.rf_rs2_data = s0.rf_rs2;

    auto& s1 = model.s1;
    s1.valid = (random() & 1u) != 0u;
    s1.rs1 = static_cast<std::uint8_t>(random() & 31u);
    s1.rs2 = static_cast<std::uint8_t>(random() & 31u);
    s1.rs1_used = (random() & 1u) != 0u;
    s1.rs2_used = (random() & 1u) != 0u;
    s1.repair_ok = (random() & 1u) != 0u;
    s1.pc = static_cast<std::uint32_t>(random());
    s1.imm = static_cast<std::uint32_t>(random());
    s1.alu_src1_sel = static_cast<std::uint8_t>(random() & 3u);
    s1.alu_src2_imm = (random() & 1u) != 0u;
    s1.rf_rs1 = static_cast<std::uint32_t>(random());
    s1.rf_rs2 = static_cast<std::uint32_t>(random());

    rtl.id_s1_valid = s1.valid;
    rtl.id_s1_rs1_addr = s1.rs1;
    rtl.id_s1_rs2_addr = s1.rs2;
    rtl.id_s1_rs1_used = s1.rs1_used;
    rtl.id_s1_rs2_used = s1.rs2_used;
    rtl.id_s1_repair_ok = s1.repair_ok;
    rtl.id_s1_pc = s1.pc;
    rtl.id_s1_imm = s1.imm;
    rtl.id_s1_alu_src1_sel = s1.alu_src1_sel;
    rtl.id_s1_alu_src2_sel = s1.alu_src2_imm;
    rtl.rf_s1_rs1_data = s1.rf_rs1;
    rtl.rf_s1_rs2_data = s1.rf_rs2;
}

void drive_producers(Vforwarding& rtl, ForwardingInputs& model,
                     std::mt19937_64& random) {
    const auto random_common =
        [&random](archsim::ForwardingProducer& producer) {
            producer.valid = (random() & 1u) != 0u;
            producer.reg_write = (random() & 1u) != 0u;
            producer.rd = static_cast<std::uint8_t>(random() & 31u);
            producer.wb_sel = static_cast<std::uint8_t>(random() % 3u);
            producer.alu_result = static_cast<std::uint32_t>(random());
            producer.fast_alu_result =
                static_cast<std::uint32_t>(random());
            producer.mul_result = static_cast<std::uint32_t>(random());
            producer.pc_plus_4 = static_cast<std::uint32_t>(random());
            producer.write_data = static_cast<std::uint32_t>(random());
        };
    random_common(model.ex_s0);
    model.ex_s0.is_muldiv = (random() & 1u) != 0u;
    model.ex_s0.mem_read = (random() & 1u) != 0u;
    model.ex_s0.fast_alu = (random() & 1u) != 0u;
    rtl.ex_valid = model.ex_s0.valid;
    rtl.ex_reg_write = model.ex_s0.reg_write;
    rtl.ex_is_muldiv = model.ex_s0.is_muldiv;
    rtl.ex_mem_read = model.ex_s0.mem_read;
    rtl.ex_rd = model.ex_s0.rd;
    rtl.ex_alu_result = model.ex_s0.alu_result;
    rtl.ex_fast_alu = model.ex_s0.fast_alu;
    rtl.ex_fast_alu_result = model.ex_s0.fast_alu_result;
    rtl.ex_pc_plus_4 = model.ex_s0.pc_plus_4;
    rtl.ex_wb_sel = model.ex_s0.wb_sel;

    random_common(model.ex_s1);
    model.ex_s1.mem_read = (random() & 1u) != 0u;
    rtl.ex_s1_valid = model.ex_s1.valid;
    rtl.ex_s1_reg_write = model.ex_s1.reg_write;
    rtl.ex_s1_mem_read = model.ex_s1.mem_read;
    rtl.ex_s1_rd = model.ex_s1.rd;
    rtl.ex_s1_alu_result = model.ex_s1.alu_result;
    rtl.ex_s1_pc_plus_4 = model.ex_s1.pc_plus_4;
    rtl.ex_s1_wb_sel = model.ex_s1.wb_sel;

    random_common(model.mem_s0);
    model.mem_s0.is_load = (random() & 1u) != 0u;
    model.mem_s0.is_mul = (random() & 1u) != 0u;
    rtl.mem_valid = model.mem_s0.valid;
    rtl.mem_reg_write = model.mem_s0.reg_write;
    rtl.mem_is_load = model.mem_s0.is_load;
    rtl.mem_is_mul = model.mem_s0.is_mul;
    rtl.mem_rd = model.mem_s0.rd;
    rtl.mem_alu_result = model.mem_s0.alu_result;
    rtl.mem_mul_result = model.mem_s0.mul_result;
    rtl.mem_pc_plus_4 = model.mem_s0.pc_plus_4;
    rtl.mem_wb_sel = model.mem_s0.wb_sel;

    random_common(model.mem_s1);
    model.mem_s1.is_load = (random() & 1u) != 0u;
    rtl.mem_s1_valid = model.mem_s1.valid;
    rtl.mem_s1_reg_write = model.mem_s1.reg_write;
    rtl.mem_s1_is_load = model.mem_s1.is_load;
    rtl.mem_s1_rd = model.mem_s1.rd;
    rtl.mem_s1_alu_result = model.mem_s1.alu_result;
    rtl.mem_s1_pc_plus_4 = model.mem_s1.pc_plus_4;
    rtl.mem_s1_wb_sel = model.mem_s1.wb_sel;

    random_common(model.wb_s0);
    rtl.wb_valid = model.wb_s0.valid;
    rtl.wb_reg_write = model.wb_s0.reg_write;
    rtl.wb_rd = model.wb_s0.rd;
    rtl.wb_write_data = model.wb_s0.write_data;

    random_common(model.wb_s1);
    rtl.wb_s1_valid = model.wb_s1.valid;
    rtl.wb_s1_reg_write = model.wb_s1.reg_write;
    rtl.wb_s1_rd = model.wb_s1.rd;
    rtl.wb_s1_write_data = model.wb_s1.write_data;

    model.mem_load_ready = (random() & 1u) != 0u;
    rtl.mem_load_ready = model.mem_load_ready;
}

void compare(Vforwarding& rtl, const ForwardingInputs& inputs,
             const archsim::ForwardingOutputs& model,
             const std::uint64_t trial) {
    if (rtl.id_s1_rs1_data != model.s1[0].data) {
        std::cerr << "diagnostic src=" << static_cast<unsigned>(inputs.s1.rs1)
                  << " model_source="
                  << static_cast<unsigned>(model.s1[0].source)
                  << " ex1=" << inputs.ex_s1.valid
                  << '/' << inputs.ex_s1.reg_write
                  << '/' << static_cast<unsigned>(inputs.ex_s1.rd)
                  << " ex0=" << inputs.ex_s0.valid
                  << '/' << inputs.ex_s0.reg_write
                  << '/' << static_cast<unsigned>(inputs.ex_s0.rd)
                  << " fast=" << inputs.ex_s0.fast_alu
                  << " wbsel=" << static_cast<unsigned>(inputs.ex_s0.wb_sel)
                  << " alu=" << inputs.ex_s0.alu_result
                  << " fastval=" << inputs.ex_s0.fast_alu_result
                  << " pc4=" << inputs.ex_s0.pc_plus_4
                  << " mem1=" << inputs.mem_s1.valid
                  << '/' << inputs.mem_s1.reg_write
                  << '/' << inputs.mem_s1.is_load
                  << '/' << static_cast<unsigned>(inputs.mem_s1.rd)
                  << " mem0=" << inputs.mem_s0.valid
                  << '/' << inputs.mem_s0.reg_write
                  << '/' << inputs.mem_s0.is_load
                  << '/' << inputs.mem_s0.is_mul
                  << '/' << static_cast<unsigned>(inputs.mem_s0.rd)
                  << " wb1=" << inputs.wb_s1.valid
                  << '/' << inputs.wb_s1.reg_write
                  << '/' << static_cast<unsigned>(inputs.wb_s1.rd)
                  << " wb0=" << inputs.wb_s0.valid
                  << '/' << inputs.wb_s0.reg_write
                  << '/' << static_cast<unsigned>(inputs.wb_s0.rd)
                  << '\n';
    }
    check_equal("id_rs1_data", rtl.id_rs1_data, model.s0[0].data, trial);
    check_equal("id_rs2_data", rtl.id_rs2_data, model.s0[1].data, trial);
    check_equal("id_s1_rs1_data", rtl.id_s1_rs1_data,
                model.s1[0].data, trial);
    check_equal("id_s1_rs2_data", rtl.id_s1_rs2_data,
                model.s1[1].data, trial);
    check_equal("id_s0_alu_src1", rtl.id_s0_alu_src1,
                model.s0_alu[0], trial);
    check_equal("id_s0_alu_src2", rtl.id_s0_alu_src2,
                model.s0_alu[1], trial);
    check_equal("id_s1_alu_src1", rtl.id_s1_alu_src1,
                model.s1_alu[0], trial);
    check_equal("id_s1_alu_src2", rtl.id_s1_alu_src2,
                model.s1_alu[1], trial);

    check_equal("id_rs1_wb_repair", rtl.id_rs1_wb_repair,
                model.s0[0].repair != RepairSource::None, trial);
    check_equal("id_rs2_wb_repair", rtl.id_rs2_wb_repair,
                model.s0[1].repair != RepairSource::None, trial);
    check_equal("id_s1_rs1_wb_repair", rtl.id_s1_rs1_wb_repair,
                model.s1[0].repair != RepairSource::None, trial);
    check_equal("id_s1_rs2_wb_repair", rtl.id_s1_rs2_wb_repair,
                model.s1[1].repair != RepairSource::None, trial);
    check_equal("id_rs1_wb_repair_s1", rtl.id_rs1_wb_repair_s1,
                model.s0[0].repair == RepairSource::S1MemLoad, trial);
    check_equal("id_rs2_wb_repair_s1", rtl.id_rs2_wb_repair_s1,
                model.s0[1].repair == RepairSource::S1MemLoad, trial);
    check_equal("id_s1_rs1_wb_repair_s1",
                rtl.id_s1_rs1_wb_repair_s1,
                model.s1[0].repair == RepairSource::S1MemLoad, trial);
    check_equal("id_s1_rs2_wb_repair_s1",
                rtl.id_s1_rs2_wb_repair_s1,
                model.s1[1].repair == RepairSource::S1MemLoad, trial);
    check_equal("id_ready_go", rtl.id_ready_go, model.id_ready_go, trial);
    check_equal("id_ready_go_if_mem_ready",
                rtl.id_ready_go_if_mem_ready,
                model.id_ready_go_if_mem_ready, trial);
    check_equal("id_ready_go_if_mem_wait",
                rtl.id_ready_go_if_mem_wait,
                model.id_ready_go_if_mem_wait, trial);
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Vforwarding rtl;
        std::mt19937_64 random(0x4657445f434f5349ull);
        constexpr std::uint64_t kTrials = 100'000u;
        for (std::uint64_t trial = 0; trial < kTrials; ++trial) {
            ForwardingInputs model_inputs;
            drive_consumer(rtl, model_inputs, random);
            drive_producers(rtl, model_inputs, random);
            rtl.eval();
            compare(rtl, model_inputs,
                    archsim::evaluate_forwarding(model_inputs), trial);
        }
        rtl.final();
        std::cout << "forwarding_rtl_cosim: PASS (" << kTrials
                  << " randomized vectors)\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "forwarding_rtl_cosim: " << exception.what() << '\n';
        return 1;
    }
}
