# 仿真环境使用指南 (Simulation Environment User Guide)

本目录包含了用于验证 **RV32I 处理器核心** 功能正确性的自动化仿真框架。主要通过标准的 `riscv-tests` 指令集套件来确保流水线逻辑的严谨性。

---

## 1. 核心流程 (Core Workflow)

为了验证处理器功能，您需要遵循“先编译测试固件，后执行电路仿真”的标准流程。

### 第一步：编译测试用例 (Build Tests)

在运行仿真之前，必须先将汇编源码编译为处理器可识别的十六进制镜像。

```bash
cd riscv_tests
bash build_tests.sh
```

* **动作**：调用 `riscv64-unknown-elf-gcc` 进行编译，并利用 `elf2hex.py` 将生成的 ELF 文件拆分为 `irom.hex` (指令) 和 `dram.hex` (数据)。
* **产物**：生成的镜像将存放在 `hex/` 目录下。

### 第二步：运行全量回归 (Run All Tests)

编译完成后，您可以一键运行所有指令集的验证。

```bash
bash run_all.sh [simulator]
```

* **默认参数**：不加参数时默认使用 `iverilog`。
* **支持环境**：
  * `bash run_all.sh` (使用 Icarus Verilog，推荐用于日常快速验证)
  * `bash run_all.sh xsim` (使用 Vivado xsim，适用于需要精确时序分析的场景)

---

## 2. 验证机制说明 (Verification Mechanism)

为了适配您的自研处理器，该环境采用了以下特殊设计：

* **自定义环境 (Custom Env)**：测试代码位于 `riscv-tests/env/custom`。由于核心暂不支持 CSR，我们重写了 `riscv_test.h`，剔除了所有特权指令。
* **通信协议 (Result Signaling)**：
  * CPU 执行完测试后，会通过 `sw` 指令将结果写入 **DRAM 地址 0** (`tohost`)。
  * 写入 `1` 代表 **PASS**；写入其他值代表 **FAIL**（该值的高位指示了失败的测试序号）。
* **自动化监测**：Testbench 会持续观察内存端口。一旦检测到 `tohost` 被写入，仿真将立即终止并汇总报告。

---

## 3. 调试与排查 (Debugging)

如果某个测试用例（如 `add`）报错，您可以进行深入分析：

1. **检查反汇编**：查看 `hex/rv32ui-p-add.dump` 文件，确认编译出的指令序列是否符合预期。
2. **查看仿真波形**：
   * 在 `tb_riscv_tests.sv` 中，仿真结果会自动生成 `riscv_test.vcd`。
   * 使用 `gtkwave riscv_test.vcd` 或 Vivado 的 Waveform Viewer 进行信号追踪。
3. **单项调试**：
   如果您只想单跑某一个生成的仿真包，可以直接进入 `work/` 目录运行 `vvp` 命令，而不必每次都跑全量脚本。

> [!IMPORTANT]
> **设计变动后的同步**：每当您修改了 `02_Design/rtl/` 中的硬件代码，请务必重新执行 `run_all.sh`。脚本会自动重新编译 RTL 逻辑，确保仿真运行在最新的设计之上。

---

## 4. 依赖项 (Prerequisites)

* **工具链**：`riscv64-unknown-elf-gcc` (需支持 `ilp32` 编译选项)。
* **仿真器**：`iverilog` (v11.0+) 或 Vivado 2023.1+。
* **环境**：Python 3 (用于执行 `elf2hex.py`)。
