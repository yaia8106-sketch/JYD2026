# riscv_tests Script Classification

本目录脚本只分两类维护。新增测试或脚本前先确认属于哪一类，不要把功能正确性 smoke 和性能/长跑入口混用。

## A. Functional Correctness / Smoke

这类脚本用于快速判断 RTL 行为是否正确。它们可以作为改 RTL 后的验证入口。

### A1. Conventional Regression

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `functional/run_all.sh` | 主功能回归，运行大量短 riscv-tests 程序 | 普通 RTL 改动后的 correctness gate |

### A2. Special / Temporary Correctness Smoke

这些入口也验证功能正确性，但不是常规 `run_all` 体系的一部分。适合验证某个封装、协议 adapter、临时集成路径，等测试稳定且适合常规化后，再考虑迁入 `run_all`。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `functional/special/run_axi_adapter.sh` | `axi_master_adapter` 单模块协议 smoke | AXI adapter 或 AXI backend 相关改动后 |
| `functional/special/run_student_top_axi.sh` | `student_top_axi` 处理器侧 AXI 集成 smoke | DCache AXI 路径、AXI 顶层封装或本地 MMIO 隔离相关改动后 |
| `functional/special/run_student_top_smoke.sh` | `student_top` 板级封装短 smoke | 检查 `student_top`、MMIO bridge、IROM/DRAM IP model 接线后 |

规则：

- 新增常规功能正确性测试应放进 `src/`、由 `utility/build_tests.sh` 生成 hex，并纳入 `functional/run_all.sh` 的测试列表。
- 不适合进入 `run_all` 的功能验证脚本，放在 `functional/special/`，并在本文件说明为什么它是 special。
- AXI 单模块协议测试放在 `tb_axi_master_adapter.sv` / `functional/special/run_axi_adapter.sh`。
- AXI CPU 集成测试放在 `tb_student_top_axi.sv` / `functional/special/run_student_top_axi.sh`。
- 不要为了覆盖功能 bug，把新 correctness case 只加到 `run_perf.sh` 或 COE 脚本里。

## B. Performance / Long-Run / COE

这类脚本用于性能分析或完整 COE 长程序。它们不是默认 smoke gate，不应替代 `functional/run_all.sh`。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `performance/short/run_perf.sh` | 短 profiling 入口，对 riscv-tests 程序输出 CPI、stall、双发率、BP 等性能指标 | 人工需要快速 profiling 或比较优化效果时 |
| `performance/branch/run_branch_diag.sh` | 分支预测诊断 wrapper，复用 `run_perf.sh` / `run_coe_perf.sh` 和 `parse_perf.py`，输出 branch-only 指标与启发式分类 | 定位 BTB、方向预测、训练、slot1、redirect/flush、RAS/JALR 等分支预测问题时 |
| `performance/long/run_coe_perf.sh` | 长 COE 入口，跑完整 contest COE 程序并输出性能摘要 | 分析完整比赛程序性能或长程序行为时 |

规则：

- `run_perf.sh` 即使默认只跑很少程序，也属于 profiling 入口；不要把它当 correctness smoke。
- `run_coe_perf.sh` 可能长时间运行，除非用户明确要求或需要检查完整 COE 行为，不要作为常规 smoke。
- 性能实验新增测试集时，应更新 `performance/short/run_perf.sh` 的 set 和本文件；不要修改 `functional/run_all.sh` 的 correctness gate 语义。
- 诊断 wrapper 可以放在 `performance/<topic>/`，但应复用现有短跑/长跑入口和解析器，不另起一套仿真编译流程。
- 不要新增第三个 COE/长跑实现脚本；确实需要板级封装短验证时，放入 `functional/special/`。

## Utility

| 脚本 | 角色 |
|------|------|
| `utility/build_tests.sh` | 编译/生成 `work/hex/*.hex`，不是验证入口 |

`build_tests.sh` 只在修改或新增测试源时运行。普通 RTL 改动不需要重新 build hex。
