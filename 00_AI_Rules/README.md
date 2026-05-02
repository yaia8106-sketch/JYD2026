# 00_AI_Rules 目录索引

> **AI 接入本项目时，先读这个文件，再按指引读 `brief/` 下的精简文档。**

---

## 项目概述

**RV32I 五级流水线处理器**，参加数字孪生平台竞赛。200MHz FPGA 验证通过，250MHz 时序收敛。
初赛提交包已定稿（M11）。当前方向：复赛优化 + 双发射架构学习。

---

## AI 阅读顺序

1. **本文件** — 了解目录结构和阅读顺序
2. **`brief/status.md`** — 项目当前状态、待办、里程碑（1.5KB）
3. **`brief/design_decisions_brief.md`** — 所有架构决策的精简版（4KB）
4. **`project_context.md`** — AI 角色定义、工作流、调试方法（9KB）
5. **按需读 `design_rules/`** — 编写 RTL 时参考

> ⚠️ `full/` 目录下是完整版归档文档（~95KB），**不要主动读**，仅当需要深挖某个决策的详细推导过程时才查阅。

---

## 本目录结构

```
00_AI_Rules/
├── README.md                 ← 你正在看的文件（入口）
├── project_context.md        ← AI 角色定义、SOP、调试流程
│
├── brief/                    ← ⭐ 精简版笔记（AI 每次新对话首先读这里）
│   ├── design_decisions_brief.md   (4KB)  ← 全部决策的结论+约束+教训
│   └── status.md                   (1.5KB) ← 项目状态+待办+回滚表
│
├── full/                     ← 完整版归档（需要时才读）
│   ├── design_decisions.md         (45KB) ← 决策完整推导过程
│   ├── milestones.md               (7KB)  ← 里程碑详细记录
│   ├── TODO.md                     (5KB)  ← 完整待办清单
│   ├── bp_analysis.md              (14KB) ← BP 配置扫描数据
│   ├── cache_analysis.md           (10KB) ← DCache 配置扫描数据
│   └── digital_twin_integration.md (10KB) ← 平台集成记录（部分过时）
│
├── design_rules/             ← 编写 RTL 时必须遵守的规范
│   ├── pipeline.md           ← 流水线控制规范（握手协议、前递、flush）
│   ├── isa_encoding.md       ← RV32I 控制信号与译码表
│   └── spec_format.md        ← Module Spec 编写模板
```

| 文件 | 大小 | 何时读 |
|---|:---:|---|
| `brief/status.md` | 1.5KB | **每次对话开头** |
| `brief/design_decisions_brief.md` | 4KB | **每次对话开头** |
| `project_context.md` | 9KB | 每次对话开头（含 SOP 和调试流程） |
| `design_rules/pipeline.md` | — | 编写/修改任何流水线模块前 |
| `design_rules/isa_encoding.md` | — | 编写译码器/ALU/分支单元时 |
| `full/design_decisions.md` | 45KB | 深挖某个决策的详细推导时 |
| `04_Submission/preliminary/writing-context/writing_context.md` | 16KB | 编写比赛文档时 |

---

## 工作区顶层结构

```
CPU_Workspace/
├── 00_AI_Rules/              ← AI 规则与笔记（你正在看的目录）
├── 02_Design/                ← 核心设计区（AI 的主要代码输出目录）
│   ├── spec/                 ← 复杂模块规格文档（dcache, bp, forwarding）
│   ├── rtl/                  ← 自研 CPU RTL 源码（含 student_top, mmio_bridge）
│   ├── contest_readonly/     ← 赛方原版 RTL（禁止修改）
│   ├── coe/                  ← BRAM 初始化文件 + COE 分析工具
│   ├── param_evaluation/     ← BP/DCache 参数评估脚本
│   └── sim/                  ← 仿真验证
│       ├── riscv_tests/      ← riscv-tests 全自动回归（43 个测试）
│       └── debug/            ← 调试 TB + 仿真输出
├── JYD2025_Contest-rv32i/    ← 主力 Vivado 工程（综合/实现/烧录）
└── riscv-tests/              ← riscv-tests 源码 + 自定义测试
```

**关键约束**：
- `contest_readonly/` 和 `counter.sv` **禁止修改**
