# Verification Script Classification

验证脚本按功能正确性与性能/长跑两类维护。共用单元测试和平台 smoke
分别位于相邻的 `../common/`、`../platform/`，不要与 RISC-V 程序回归混用。

## A. Functional Correctness / Smoke

这类脚本用于快速判断 RTL 行为是否正确。它们可以作为改 RTL 后的验证入口。

### A1. Conventional Regression

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `functional/run_all.sh` | 默认 ABTB + PHT branch steering 主功能回归，先运行 frontend directed tests，再运行大量短 riscv-tests 程序 | 普通 RTL 改动后的 correctness gate |
| `../common/frontend/run_abtb.sh` | 双 bank ABTB 单模块定向测试，由 `run_all.sh` 自动调用 | 修改 ABTB 表项、替换或选择逻辑后 |
| `../common/frontend/run_direction.sh` | 8-bit committed GHR 与 256-entry PHT 的 VCS 单模块测试，由 `run_all.sh` 自动调用，覆盖 index/hash、四状态饱和、GHR、alias 和无 bypass 可见周期 | 修改 Stage-1 direction 表或更新策略后 |
| `../common/frontend/run_integration.sh` | 真实 `cpu_top` 指令流下的 ABTB shadow metadata、EX 训练、stall/redirect/sidecar 泄漏集成测试，由 `run_all.sh` 自动调用 | 修改前端队列、流水寄存器或 ABTB 训练链路后 |
| `../common/frontend/run_pair.sh` | `frontend_ftq` pair-policy VCS 定向测试，由 `run_all.sh` 自动调用，覆盖同包/跨包 pair、RAW、force-single、pred-taken、slot kill、stall、redirect 和 wrap-around | 修改 FTQ pair eligibility、FQ entry metadata 或双发策略后 |
| `../common/frontend/run_canonical.sh` | 默认 branch steering 下 canonical snapshot VCS 测试，覆盖 ABTB miss 顺序取指、bank1 ABTB 选择、first ABTB 权威性、branch ownership、stall 和 EX redirect 优先级 | 修改 canonical steering 或 Stage-1 metadata 绑定规则后 |
| `../common/frontend/run_steering.sh` | 默认 ABTB/PHT branch steering 集成 VCS 定向测试，覆盖程序顺序、slot metadata、sequential cold miss、EX correction、stall/redirect/wrap、slot1 branch、wrong-path 抑制和 confirmed update | 修改 branch steering、PHT metadata 或训练资格后 |
| `../loongarch/functional/run_decode_contract.sh` | LA32R 普通整数完整/预译码契约、全编码前缀 legality、F0/FTQ 语义元数据及 `cpu_top` 执行 smoke，由 `run_all.sh` 自动调用 | 修改公共语义结构、ISA 边界、前端元数据或 LoongArch 普通整数译码后 |

### A2. Special / Temporary Correctness Smoke

这些入口也验证功能正确性，但不是常规 `run_all` 体系的一部分。适合验证某个板级封装或临时集成路径，等测试稳定且适合常规化后，再考虑迁入 `run_all`。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `../platform/jyd/functional/run_student_top_smoke.sh` | `student_top` 板级封装短 smoke | 检查 `student_top`、MMIO bridge、IROM/DRAM IP model 接线后 |

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
- 平台封装验证放在 `../platform/<platform>/functional/`，不与 ISA 程序回归混放。
- 不要为了覆盖功能 bug，把新 correctness case 只加到 `run_perf.sh` 或 COE 脚本里。

## B. Performance / Diagnosis / Long-Run / COE

这类脚本用于性能分析、分支诊断或完整 COE 长程序。它们不是默认 smoke gate，不应替代 `functional/run_all.sh`。

常用代号：

- `short-perf`: `performance/short/run_perf.sh`
- `run-perf` / `coe-perf`: `performance/long/run_coe_perf.sh`

这些代号在仓库根目录 `bin/` 下有可追踪的薄入口；`bash bin/install-command-links.sh`
会把它们链接到 `~/.local/bin`，方便人工直接输入命令。

AI 执行约定：

- AI 可以维护这些脚本、运行 `--help`、`bash -n`、parser/unit-style 静态检查和 stop_pc 静态推导。
- AI 不应为了常规验证主动运行 `run-perf` / `coe-perf`，因为它会启动完整 contest COE 长程序。
- 这个长入口由人工显式执行；用户明确要求时再运行。

| 脚本 | 角色 | 何时运行 |
|------|------|----------|
| `performance/short/run_perf.sh` | 短 profiling 入口，输出严格 no-commit 损失栈、提交槽位、动态指令构成、DCache/RAW/MULDIV/BP 和精确 pair blocker | 人工需要快速 profiling 或比较优化效果时 |
| `performance/long/run_coe_perf.sh` | 长 COE 入口，直接基于 `tb_riscv_tests` 跑完整 contest COE 程序，同时输出通用性能摘要和分支预测诊断报告 | 分析完整比赛程序性能、长程序行为或分支预测表现时 |

规则：

- `run_perf.sh` 即使默认只跑很少程序，也属于 profiling 入口；不要把它当 correctness smoke。
- 两个入口都由共享 parser 生成 `summary.csv/json`、`hotspots.csv`、
  `performance_findings.md` 和 `manifest.json`。优化方向先看数据一致性，再看严格
  no-commit 损失栈、资源释放后的 causal recovery 尾拍、lost-slot 比例和精确 pair
  blocker；旧 priority CPI stack 只为历史兼容保留，不能直接当作纯损失周期。
- 已有 implementation 时可给 `short-perf --clock-period-ns <n>`，让报告比较
  `cycles * clock_period`；不得用 cycles 改善掩盖 Fmax 退化。
- `run_coe_perf.sh` 是完整 contest COE 性能入口；它每次都跑完整 contest COE 集合，并行任务数等于 contest 程序数。
- `run_coe_perf.sh` 的同一次仿真同时生成 `summary.csv/json`、`branch_summary.csv/json` 和 `branch_findings.md`，不得为了分支报告重复运行同一组 COE。
- 分支预测 RV32UI/微基准使用 `performance/short/run_perf.sh --set branch_diag`，完整 COE 的分支表现直接读取 `coe-perf` 产物。
- COE stop_pc 由共享工具 `tools/derive_coe_stop_pc.py` 从入口启动段的 `0000006f` fall-through 自环推导；不要在其他脚本里复制一套宽松的 stop_pc 扫描逻辑。
- 性能实验新增测试集时，应更新 `performance/short/run_perf.sh` 的 set 和本文件；不要修改 `functional/run_all.sh` 的 correctness gate 语义。
- 主题诊断优先扩展短测试 set、`coe-perf` 后处理或共享 parser/report 工具，不要新增重复运行完整 COE 的同级入口。
- 新增长程序或 COE 相关能力时，优先扩展 `coe-perf` 或共享 `tools/`；不要新增语义重叠的长跑入口。板级封装短验证放入 `../platform/<platform>/functional/`。

## Utility

| 脚本 | 角色 |
|------|------|
| `utility/build_tests.sh` | 编译/生成 `work/hex/*.hex`，不是验证入口 |
| `tools/derive_coe_stop_pc.py` | 从 dual-bank COE/hex 的入口 fall-through 自环静态推导 stop_pc，供 `coe-perf` 使用 |
| `tools/parse_perf.py` | 解析 perf log，校验计数一致性，并生成 summary、hotspots 和性能优先级报告 |
| `tools/branch_diag_report.py` | 从通用 perf summary 聚合 branch-only 指标并生成诊断报告，由 `coe-perf` 自动调用 |
| `bin/install-command-links.sh` | 安装 `short-perf`、`run-perf` / `coe-perf` 短命令链接 |

`build_tests.sh` 只在修改或新增测试源时运行。普通 RTL 改动不需要重新 build hex。
