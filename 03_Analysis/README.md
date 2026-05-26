# 03_Analysis

<!--
文档职责：
- 只记录 03_Analysis 目录的职责边界、可放内容、产物保留策略。
- 可以记录稳定入口文件和子目录用途。
- 不记录某次实验结论、benchmark 数字、临时优化假设或脚本内部实现细节。
-->

本目录存放可复用的处理器分析入口。这里的脚本可以长期迭代，用来观察当前处理器的时序、性能、双发射、RAW、分支预测、DCache 等状态。

profiling / 仿真分析脚本面向当前工作区的当前架构运行，不绑定 git commit 或 dirty 状态。它们的职责是跑完程序并采集当前结果。

## 当前内容

- `run_vivado_flow.tcl`：Vivado COE/IP 更新、综合、实现和时序报告一键流。
- `report_stage_timing.tcl`：流水线级间 timing 分组报告。
- `profiling/`：仿真 profiling 框架文档和后续脚本位置。

## 产物策略

分析产物采用覆盖式生成，保留最新一次结果，避免按时间戳堆积不可维护的历史报告。

- 时序报告：`03_Analysis/stage_timing_report.txt`
- profiling 总报告：`03_Analysis/profile_report.md`
- profiling 机器可读结果：`03_Analysis/profile_report.json`
- profiling 表格结果：`03_Analysis/profile_report.csv` 或 `03_Analysis/profiling/output/*.csv`

这些产物默认不入 git，但会保留在工作区，下一次运行时覆盖。需要长期归档的实验结论应整理成明确的设计文档；原始长日志仍放 `/tmp/` 或 ignored output 目录。

## 目录边界

允许：

- 可复用分析脚本。
- 描述分析脚本行为、输入、输出、统计口径的文档。
- 覆盖式 latest 报告产物。
- profiling / 仿真分析脚本的并行配置，但最多 16 jobs。

禁止：

- 一次性长实验记录。
- 临时 debug 脚本。
- 和分析入口无关的 RTL、TB、Vivado 工程副本。
