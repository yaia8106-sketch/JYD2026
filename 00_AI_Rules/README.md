# 00_AI_Rules 目录索引

> AI 接入本项目时，**先读这个文件**，再按需阅读具体文档。

---

## 项目概述

本工作区是一个 **RV32I 五级流水线处理器** 的设计项目，目标是参加数字孪生平台竞赛。
最终交付物为：将自研 CPU 集成到赛事方提供的数字孪生平台 Vivado 工程中，完成跑分测试。

---

## 工作区顶层结构

```
CPU_Workspace/
├── 00_AI_Rules/              ← AI 角色定义与设计规则（你正在看的目录）
├── 01_Docs/                  ← 参考资料（板卡手册 PDF 等）
├── 02_Design/                ← 核心设计区（所有设计文件）
│   ├── spec/                 ← 模块规格文档
│   ├── rtl/                  ← 自研 CPU RTL 源码
│   │   └── platform/          ← student_top, perip_bridge
│   ├── contest_readonly/     ← 赛方原版文件（RTL、IP、XDC、TB，禁止修改）
│   ├── coe/                  ← BRAM 初始化文件
│   └── sim/                  ← 自研 testbench
├── 03_Timing_Analysis/       ← 时序约束、Vivado TCL 脚本、时序报告
├── JYD2025_Contest-rv32i/    ← 赛事方数字孪生平台 Vivado 工程（集成目标）
└── cdp-tests/                ← 赛事方功能测试框架（Verilator 仿真）
```

---

## 各目录详细说明

### `00_AI_Rules/` — AI 规则基石

```
00_AI_Rules/
├── README.md                 ← 你正在看的文件
├── project_context.md        ← AI 角色定义与工作流
├── design_rules/             ← AI 必须遵守的设计规则
│   ├── pipeline.md           ← 五级流水线控制规范（核心文档）
│   ├── isa_encoding.md       ← RV32I 控制信号与译码表
│   └── spec_format.md        ← Module Spec 编写模板
└── selfuse/                  ← 架构师笔记（每次设计改动后检查是否需要同步更新）
    ├── design_decisions.md   ← A-H 设计决策记录
    └── TODO.md               ← 待办清单
```

| 文件 | 说明 | 何时读 |
|---|---|---|
| `project_context.md` | AI 角色定义、黑盒开发流程、SOP | 每次对话开头 |
| `pipeline.md` | 流水线架构圣经：握手协议、BRAM 时序、前递、flush | 编写任何模块前 |
| `isa_encoding.md` | 指令编码、控制信号定义、译码真值表 | 编写译码器/ALU/分支单元时 |
| `spec_format.md` | Module Spec 格式模板 | 编写新的 `_spec.md` 时 |
| `design_decisions.md` | 架构师决策记录（A-H 共 8 项） | 了解设计决策时。**每次改动后检查是否需要更新** |
| `TODO.md` | 待办清单 | 确认任务优先级时。**每次改动后检查是否需要更新** |

---

### `01_Docs/` — 参考资料

存放板卡数据手册、引脚定义 PDF 等比赛相关参考资料。AI 仅做参考，不应修改。

---

### `02_Design/` — 核心设计区

所有设计相关文件的统一存放位置：

| 子目录 | 内容 | 说明 |
|---|---|---|
| `spec/` | `<Module>_spec.md` | 模块规格文档，生成 RTL 的唯一依据 |
| `rtl/` | `<Module>.sv` | 自研 CPU RTL 源码 |
| `rtl/platform/` | `student_top.sv`, `perip_bridge.sv` | 平台接口层（自研） |
| `contest_readonly/` | 赛方原版文件（见下表） | **禁止修改** |
| `coe/` | BRAM 初始化文件 | `current/` 为当前使用版本 |
| `sim/` | 自研 testbench | `tb_student_top.sv` 等 |

**`contest_readonly/`** — 赛方原版文件（TCL 脚本可一键导入）：

| 子目录 | 内容 |
|---|---|
| `rtl/` | `top.sv`, `twin_controller.sv`, `uart.sv`, `counter.sv`, `display_seg.sv`, `seg7.sv` |
| `ip/` | 扁平化 `.xci`（TCL 可 `glob *.xci` 批量导入） |
| `constraints/` | `digital_twin.xdc` |
| `sim/` | `tb_top.sv`, `tb_myCPU.sv`, `tb_uart.sv` + `.wcfg` |

**IP 配置详情**：

| 文件 | 说明 | 状态 |
|---|---|---|
| `pll.xci` | 1 路输出：clk_out1 = 50MHz，有 reset | 备用 |
| **`pll_1.xci`** | **2 路输出：clk_out1 = 50MHz, clk_out2 = 180MHz (cpu_clk)，无 reset** | **✅ 当前使用** |
| `IROM.xci` | IROM BRAM 配置（Block Memory Generator） | 当前使用 |
| `DRAM.xci` | DRAM BRAM 配置（Block Memory Generator） | 当前使用 |

**这是 AI 的主要代码输出目录。**

- `spec/`：模块规格文档（`<Module>_spec.md`），是生成 RTL 的唯一依据
- `rtl/`：SystemVerilog 源码（`<Module>.sv`），由 Spec 驱动生成

---

### `03_Timing_Analysis/` — 独立时序测试区（临时）

**仅用于 cpu_top 的独立性能测试**，与 `JYD2025_Contest-rv32i/` 中的数字孪生平台工程无关。后续可能删除。

- `constraints/`：临时 XDC 约束文件（为独立测试创建的时钟定义，非数字孪生平台约束）
- `scripts/`：Vivado TCL 脚本（分阶段时序提取）
- `reports/`：Vivado 生成的时序报告

---

### `JYD2025_Contest-rv32i/` — 赛事方数字孪生平台工程

**赛事方提供的 Vivado 工程，是 CPU 集成的目标平台。**

关键文件（位于 `.../digital_twin.srcs/sources_1/new/`）：
- `top.sv` — 顶层模块，包含 PLL（差分时钟）、UART、twin_controller
- `student_top.sv` — **学生区**，CPU 及外设桥在此例化
- `perip_bridge.sv` — 外设桥（地址译码、DRAM、MMIO 读写）
- `dram_driver.sv` — DRAM 读写驱动（使用分布式 RAM）
- `counter.sv` — 硬件计数器（**含 CDC 处理，禁止修改**）
- `display_seg.sv` / `seg7.sv` — 七段数码管驱动
- `twin_controller.sv` / `uart.sv` — 数字孪生通信链路

> **修改约束**：`counter.sv` 及其对应时钟 **明确禁止修改**。其余模块（包括 `perip_bridge.sv`）允许根据需要修改或替换。

---

### `cdp-tests/` — 功能测试框架

赛事方提供的 Verilator 仿真测试程序，用于验证 CPU 指令级功能正确性。

- `mySoC/`：包含一份独立的 RTL 副本（用户自行维护，**AI 编写代码时不参考此目录**）
- `waveform/`：各指令的 VCD 波形文件
- `golden_model/`：参考模型

> **注意**：AI 在编写 `02_Design/rtl/` 中的代码时，**不应参考或同步 `cdp-tests/mySoC/` 中的代码**。两份代码由用户手动管理。
