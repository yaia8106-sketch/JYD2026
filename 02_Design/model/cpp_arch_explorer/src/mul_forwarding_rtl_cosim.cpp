#include "Vmul_operand_forwarding.h"
#include "forwarding_model.hpp"
#include "verilated.h"

#include <cstdint>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>

namespace {

void randomize_common(archsim::ForwardingProducer& producer,
                      std::mt19937_64& random) {
    producer.valid = (random() & 1u) != 0u;
    producer.reg_write = (random() & 1u) != 0u;
    producer.rd = static_cast<std::uint8_t>(random() & 31u);
    producer.wb_sel = static_cast<std::uint8_t>(random() % 3u);
    producer.is_load = (random() & 1u) != 0u;
    producer.is_mul = (random() & 1u) != 0u;
    producer.alu_result = static_cast<std::uint32_t>(random());
    producer.mul_result = static_cast<std::uint32_t>(random());
    producer.pc_plus_4 = static_cast<std::uint32_t>(random());
    producer.write_data = static_cast<std::uint32_t>(random());
}

void drive(Vmul_operand_forwarding& rtl,
           archsim::ForwardingInputs& model, std::mt19937_64& random) {
    model.s0.rs1 = static_cast<std::uint8_t>(random() & 31u);
    model.s0.rs2 = static_cast<std::uint8_t>(random() & 31u);
    model.s0.rf_rs1 = static_cast<std::uint32_t>(random());
    model.s0.rf_rs2 = static_cast<std::uint32_t>(random());
    rtl.id_rs1_addr = model.s0.rs1;
    rtl.id_rs2_addr = model.s0.rs2;
    rtl.rf_rs1_data = model.s0.rf_rs1;
    rtl.rf_rs2_data = model.s0.rf_rs2;

    randomize_common(model.mem_s0, random);
    rtl.mem_valid = model.mem_s0.valid;
    rtl.mem_reg_write = model.mem_s0.reg_write;
    rtl.mem_is_load = model.mem_s0.is_load;
    rtl.mem_is_mul = model.mem_s0.is_mul;
    rtl.mem_rd = model.mem_s0.rd;
    rtl.mem_alu_result = model.mem_s0.alu_result;
    rtl.mem_mul_result = model.mem_s0.mul_result;
    rtl.mem_pc_plus_4 = model.mem_s0.pc_plus_4;
    rtl.mem_wb_sel = model.mem_s0.wb_sel;

    randomize_common(model.mem_s1, random);
    model.mem_s1.is_mul = false;
    rtl.mem_s1_valid = model.mem_s1.valid;
    rtl.mem_s1_reg_write = model.mem_s1.reg_write;
    rtl.mem_s1_is_load = model.mem_s1.is_load;
    rtl.mem_s1_rd = model.mem_s1.rd;
    rtl.mem_s1_alu_result = model.mem_s1.alu_result;
    rtl.mem_s1_pc_plus_4 = model.mem_s1.pc_plus_4;
    rtl.mem_s1_wb_sel = model.mem_s1.wb_sel;

    randomize_common(model.wb_s0, random);
    rtl.wb_valid = model.wb_s0.valid;
    rtl.wb_reg_write = model.wb_s0.reg_write;
    rtl.wb_rd = model.wb_s0.rd;
    rtl.wb_write_data = model.wb_s0.write_data;

    randomize_common(model.wb_s1, random);
    rtl.wb_s1_valid = model.wb_s1.valid;
    rtl.wb_s1_reg_write = model.wb_s1.reg_write;
    rtl.wb_s1_rd = model.wb_s1.rd;
    rtl.wb_s1_write_data = model.wb_s1.write_data;
}

void check(const char* name, const std::uint32_t rtl,
           const std::uint32_t model, const std::uint64_t trial) {
    if (rtl != model) {
        throw std::runtime_error(
            "trial " + std::to_string(trial) + " " + name +
            " RTL=" + std::to_string(rtl) +
            " model=" + std::to_string(model));
    }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        Vmul_operand_forwarding rtl;
        std::mt19937_64 random(0x4d554c5f434f5349ull);
        constexpr std::uint64_t kTrials = 100'000u;
        for (std::uint64_t trial = 0; trial < kTrials; ++trial) {
            archsim::ForwardingInputs inputs;
            drive(rtl, inputs, random);
            rtl.eval();
            const auto model = archsim::evaluate_forwarding(inputs);
            check("mul_rs1_data", rtl.mul_rs1_data,
                  model.mul[0].data, trial);
            check("mul_rs2_data", rtl.mul_rs2_data,
                  model.mul[1].data, trial);
        }
        rtl.final();
        std::cout << "mul_forwarding_rtl_cosim: PASS (" << kTrials
                  << " randomized vectors)\n";
        return 0;
    } catch (const std::exception& exception) {
        std::cerr << "mul_forwarding_rtl_cosim: "
                  << exception.what() << '\n';
        return 1;
    }
}
