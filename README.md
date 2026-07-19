# CPU_Workspace

本工作区存放当前处理器 RTL、测试、COE、Vivado 工程和实现后的 timing 分析结果。

AI 或人工接手工程时，先看本文件，再按需进入对应目录。

## 阅读顺序

1. **`00_AI_Rules/global_rules.md`** — 地址映射、赛方约束、BRAM 时序、握手协议、编码规则、验证流程

按需阅读：

- **`02_Design/FRONTEND_STAGE1_PREDICTOR_AI_PROMPT.md`** — 一级 ABTB/PHT/uRAS、双 bank、FTQ 和 redirect 的已确认设计约束
- **`PERFORMANCE_OPTIMIZATION_PLAN.md`** — 性能优化总目标、profiling 计划和长短测试边界
- **`02_Design/riscv_tests/SCRIPT_CLASSIFICATION.md`** — riscv_tests 脚本分类：功能正确性 smoke vs 性能/长跑/COE
- **`02_Design/riscv_tests/test_coverage.md`** — 回归测试覆盖范围
- **`02_Design/coe/README.md`** — COE 文件、转换脚本和静态分布
- **`03_Timing_Analysis/sta.sh`** — 对已有 implementation 运行 timing 分组报告
- **`03_Timing_Analysis/report_stage_timing.tcl`** — timing 分组报告 Tcl 脚本

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
- `02_Design/riscv_tests/`：VCS 回归测试脚本和 testbench。
- `03_Timing_Analysis/`：只放 timing 分析相关内容，目前保留 `sta.sh`、`report_stage_timing.tcl`、`stage_timing_report.txt` 和 `vivado_work/`。
- `JYD2025_Contest-rv32i/`：赛方 Vivado 工程。

## 常用入口

功能正确性 / Smoke：

```bash
cd 02_Design/riscv_tests
bash functional/run_all.sh
bash functional/special/run_axi_adapter.sh
bash functional/special/run_student_top_axi.sh
bash functional/special/run_student_top_smoke.sh
```

性能 / 长跑 / COE（不要当作默认 smoke）：

```bash
short-perf
short-perf --set branch
short-perf --set cache
short-perf --set dual
short-perf --clock-period-ns 4.0 --baseline <old-run-dir>
run-perf
```

短命令由 `bin/install-command-links.sh` 链接到 `~/.local/bin`。若换机器或链接丢失，执行：

```bash
bash bin/install-command-links.sh
```

所有性能入口都会生成 `summary.csv/json`、按严格 no-commit 损失周期排序的
`hotspots.csv` 和 `performance_findings.md`。提供实现后的时钟周期时，报告还会计算
`cycles * clock_period` 运行时间估计；没有时钟数据时只比较 cycles。`run-perf` /
`coe-perf` 会运行完整 contest COE 程序集合，并从同一次仿真额外生成分支预测诊断
报告。短测原始数据还包含 MULDIV 多周期资源的等待和延迟分布。这个入口很长，不作为 AI 默认验证命令。分支微基准使用
`short-perf --set branch_diag`。

实现后 timing 报告：

```bash
sta
```

`sta` 只分析当前已经存在的 `impl_1`，不会自动生成 implementation。若实现还没跑完，它会直接报错。
