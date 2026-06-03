# CPU_Workspace

本工作区存放当前处理器 RTL、测试、COE、Vivado 工程和实现后的 timing 分析结果。

AI 或人工接手工程时，先看本文件，再按需进入对应目录。

## 阅读顺序

1. **`00_AI_Rules/global_rules.md`** — 地址映射、赛方约束、BRAM 时序、握手协议、编码规则、验证流程
2. **`00_AI_Rules/architecture.md`** — 当前 RTL 架构描述

按需阅读：

- **`02_Design/riscv_tests/test_coverage.md`** — 回归测试覆盖范围
- **`02_Design/coe/README.md`** — COE 文件、转换脚本和静态分布
- **`03_Timing_Analysis/report_stage_timing.tcl`** — 实现后 timing 分组报告脚本

## 工作区结构

```
CPU_Workspace/
├── README.md              ← 本文件
├── 00_AI_Rules/           ← 全局规则和当前架构文档
├── 01_Docs/               ← 外部资料、论文、参考手册、香山文档
├── 02_Design/             ← 自研 CPU RTL、COE、回归测试
├── 03_Timing_Analysis/    ← 实现后的 timing 分析脚本与报告
├── 04_Submission/         ← 提交相关内容
└── JYD2025_Contest-rv32i/ ← Vivado 工程
```

## 关键目录

- `02_Design/rtl/`：自研 CPU RTL 源码。
- `02_Design/coe/`：COE 文件和 COE 转换工具。
- `02_Design/riscv_tests/`：Iverilog 回归测试脚本和 testbench。
- `03_Timing_Analysis/`：只放 timing 分析相关内容，目前保留 `report_stage_timing.tcl`、`stage_timing_report.txt` 和 `vivado_work/`。
- `JYD2025_Contest-rv32i/`：赛方 Vivado 工程。

## 常用入口

回归测试：

```bash
cd 02_Design/riscv_tests
bash run_all.sh
```

实现后 timing 报告：

```tcl
open_project /home/anokyai/Desktop/CPU_Workspace/JYD2025_Contest-rv32i/digital_twin.xpr
open_run impl_1
source /home/anokyai/Desktop/CPU_Workspace/03_Timing_Analysis/report_stage_timing.tcl
```
