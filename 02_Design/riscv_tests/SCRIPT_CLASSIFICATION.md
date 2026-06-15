# riscv_tests Script Classification

本目录脚本只分两类维护。新增测试或脚本前先确认属于哪一类，不要把功能正确性 smoke 和性能/长跑入口混用。

## A. Functional Correctness / Smoke

这类脚本用于快速判断 RTL 行为是否正确。它们可以作为改 RTL 后的验证入口。

### A1. Conventional Regression

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `functional/run_all.sh` | 默认 ABTB + PHT branch steering 主功能回归，先运行 frontend directed tests，再运行大量短 riscv-tests 程序 | 普通 RTL 改动后的 correctness gate |
| `functional/frontend/run_abtb.sh` | 双 bank ABTB 单模块定向测试，由 `run_all.sh` 自动调用 | 修改 ABTB 表项、替换或选择逻辑后 |
| `functional/frontend/run_direction.sh` | 8-bit committed GHR 与 256-entry PHT 的 VCS 单模块测试，由 `run_all.sh` 自动调用，覆盖 index/hash、四状态饱和、GHR、alias 和无 bypass 可见周期 | 修改 Stage-1 direction 表或更新策略后 |
| `functional/frontend/run_integration.sh` | 真实 `cpu_top` 指令流下的 ABTB shadow metadata、EX 训练、stall/redirect/sidecar 泄漏集成测试，由 `run_all.sh` 自动调用 | 修改前端队列、流水寄存器或 ABTB 训练链路后 |
| `functional/frontend/run_pair.sh` | `frontend_ftq` pair-policy VCS 定向测试，由 `run_all.sh` 自动调用，覆盖同包/跨包 pair、RAW、force-single、pred-taken、slot kill、stall、redirect 和 wrap-around | 修改 FTQ pair eligibility、FQ entry metadata 或双发策略后 |
| `functional/frontend/run_canonical.sh` | 默认 branch steering 下 canonical snapshot VCS 测试，覆盖 ABTB miss 顺序取指、bank1 ABTB 选择、first ABTB 权威性、branch ownership、stall 和 EX redirect 优先级 | 修改 canonical steering 或 Stage-1 metadata 绑定规则后 |
| `functional/frontend/run_steering.sh` | 默认 ABTB/PHT branch steering 集成 VCS 定向测试，覆盖程序顺序、slot metadata、sequential cold miss、EX correction、stall/redirect/wrap、slot1 branch、wrong-path 抑制和 confirmed update | 修改 branch steering、PHT metadata 或训练资格后 |

### A2. Special / Temporary Correctness Smoke

这些入口也验证功能正确性，但不是常规 `run_all` 体系的一部分。适合验证某个封装、协议 adapter、临时集成路径，等测试稳定且适合常规化后，再考虑迁入 `run_all`。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `functional/special/run_axi_adapter.sh` | `axi_master_adapter` 单模块协议 smoke | AXI adapter 或 AXI backend 相关改动后 |
| `functional/special/run_student_top_axi.sh` | `student_top_axi` 处理器侧 AXI 集成 smoke | DCache AXI 路径、AXI 顶层封装或本地 MMIO 隔离相关改动后 |
| `functional/special/run_student_top_smoke.sh` | `student_top` 板级封装短 smoke | 检查 `student_top`、MMIO bridge、IROM/DRAM IP model 接线后 |

规则：

- 新增常规功能正确性测试应放进 `src/`、由 `utility/build_tests.sh` 生成 hex，并纳入 `functional/run_all.sh` 的测试列表。
- 不需要预编译 hex 的独立或集成 RTL 定向测试可放在 `tb/`，使用 `functional/` 下的 VCS 脚本并由 `run_all.sh` 调用。
- 默认 build 就是 ABTB + PHT branch steering。TYPE_JAL/TYPE_CALL 永远参与
  canonical Stage-1 steering；TYPE_BRANCH ABTB hit 永远进入 Stage-1 ownership。
  J/CALL 候选使用 ABTB raw tag hit/type/target；branch 候选使用 ABTB raw tag
  hit/type/target 和 Stage-1 PHT 方向。ABTB miss 顺序取指。RET/普通间接 JALR
  在当前阶段 fall through 后由 EX redirect 修正。
- 历史 direct/branch/registered steering wrapper 已删除。不要在 RTL、
  testbench、functional 脚本或 performance 脚本里重新添加旧 steering define。
- per-slot `stage1_branch_owned` 表达“Stage-1 拥有该 branch 的方向预测”，
  taken 时使用 ABTB target，not-taken 时继续检查更年轻 bank1 CFI 或顺序 PC。
  `pred_source_abtb` 仍只表示最终 taken next-PC 来源，不能作为 branch ownership
  的替代信号。
- 没有 frontend legacy correction 版本，也没有 registered BP1 配置；frontend
  redirect 只来自后端/EX redirect。旧 predictor metadata 管线已删除。
- FTQ pair-policy 定向测试只验证现有双发资格语义。它不得通过禁止
  cross-packet pairing、降低双发能力或推迟 pair 生效周期来换取 PASS。
- 上述 VCS 脚本必须真正获得 license 并完成仿真后才能记为 PASS。若 license
  checkout 失败，只能记录为未跑通。
- 不适合进入 `run_all` 的功能验证脚本，放在 `functional/special/`，并在本文件说明为什么它是 special。
- AXI 单模块协议测试放在 `tb_axi_master_adapter.sv` / `functional/special/run_axi_adapter.sh`。
- AXI CPU 集成测试放在 `tb_student_top_axi.sv` / `functional/special/run_student_top_axi.sh`。
- 不要为了覆盖功能 bug，把新 correctness case 只加到 `run_perf.sh` 或 COE 脚本里。

## B. Performance / Diagnosis / Long-Run / COE

这类脚本用于性能分析、分支诊断或完整 COE 长程序。它们不是默认 smoke gate，不应替代 `functional/run_all.sh`。

常用代号：

- `short-perf`: `performance/short/run_perf.sh`
- `run-perf` / `coe-perf`: `performance/long/run_coe_perf.sh`
- `branch-diag`: `performance/branch/run_branch_diag.sh`

这些代号在仓库根目录 `bin/` 下有可追踪的薄入口；`bash bin/install-command-links.sh`
会把它们链接到 `~/.local/bin`，方便人工直接输入命令。

AI 执行约定：

- AI 可以维护这些脚本、运行 `--help`、`bash -n`、parser/unit-style 静态检查和 stop_pc 静态推导。
- AI 不应为了常规验证主动运行 `run-perf` / `coe-perf` 或 `branch-diag`，因为它们会启动完整 contest COE 长程序。
- 这两个长入口由人工显式执行；用户明确要求时再运行。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `performance/short/run_perf.sh` | 短 profiling 入口，对 riscv-tests 程序输出 CPI、stall、双发率、BP 等性能指标 | 人工需要快速 profiling 或比较优化效果时 |
| `performance/long/run_coe_perf.sh` | 长 COE 入口，直接基于 `tb_riscv_tests` 跑完整 contest COE 程序并输出性能摘要 | 分析完整比赛程序性能或长程序行为时 |
| `performance/branch/run_branch_diag.sh` | 分支预测诊断入口，直接基于 `tb_riscv_tests` 运行精选 riscv-tests 和完整 contest COE 集合，输出 branch-only 指标与启发式分类 | 定位 BTB、方向预测、训练、slot1、redirect/flush、RAS/JALR 等分支预测问题时 |

规则：

- `run_perf.sh` 即使默认只跑很少程序，也属于 profiling 入口；不要把它当 correctness smoke。
- `run_coe_perf.sh` 是完整 contest COE 性能入口；它每次都跑完整 contest COE 集合，并行任务数等于 contest 程序数。
- `run_branch_diag.sh` 是独立的 branch 诊断入口，不依赖 `run_perf.sh` 或 `run_coe_perf.sh`；它的 COE 阶段同样每次都跑完整 contest COE 集合，并行任务数等于 contest 程序数。
- `run_coe_perf.sh` 和 `run_branch_diag.sh` 是同级入口：二者都直接编译/运行 `tb_riscv_tests`，不是脚本链式调用关系。
- COE stop_pc 由共享工具 `tools/derive_coe_stop_pc.py` 从入口启动段的 `0000006f` fall-through 自环推导；不要在各脚本里复制一套宽松的 stop_pc 扫描逻辑。
- 性能实验新增测试集时，应更新 `performance/short/run_perf.sh` 的 set 和本文件；不要修改 `functional/run_all.sh` 的 correctness gate 语义。
- 主题诊断入口可以放在 `performance/<topic>/`；若它需要和短跑/长跑不同的测试组织，应直接复用基础 TB 和共享解析器，而不是让诊断脚本依赖另一个入口脚本。
- 新增长程序或 COE 相关能力时，优先扩展 `coe-perf`、`branch-diag` 或共享 `tools/`；不要新增语义重叠的长跑入口。确实需要板级封装短验证时，放入 `functional/special/`。

## Utility

| 脚本 | 角色 |
|------|------|
| `utility/build_tests.sh` | 编译/生成 `work/hex/*.hex`，不是验证入口 |
| `tools/derive_coe_stop_pc.py` | 从 dual-bank COE/hex 的入口 fall-through 自环静态推导 stop_pc，供 `coe-perf` 和 `branch-diag` 复用 |
| `tools/parse_perf.py` | 解析 perf log，生成 `summary.csv/json` |
| `tools/branch_diag_report.py` | 聚合 branch-only 指标并生成诊断报告 |
| `bin/install-command-links.sh` | 安装 `short-perf`、`run-perf` / `coe-perf`、`branch-diag` 短命令链接 |

`build_tests.sh` 只在修改或新增测试源时运行。普通 RTL 改动不需要重新 build hex。
