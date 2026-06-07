# Performance Optimization Plan

本文档记录后续性能优化的总目标、阶段计划和测试边界。核心原则是先把 profiling 工具做准、做轻量、做可复现，再投入长时间 COE 或 Vivado 验证。

## 总目标

唯一目标是提升处理器在真实目标程序上的有效性能：

```
有效性能 = 正确完成目标程序 / 实际运行时间
实际运行时间 = cycles * clock_period
```

因此优化决策必须同时看 CPI/IPC 和可达到频率。单独提高频率或单独降低 CPI 都不够，只有 `cycles * clock_period` 下降才算有效收益。

## 当前判断

- 继续冲 250 MHz 以上仍有价值，但当前不应只凭 timing 报告决定所有优化方向。
- COE 程序的静态分布显示 Load/Store、JAL/JALR、分支和 ADDI/地址计算占比较高，分支预测、取指双发、DCache/LSU、RAW stall 都可能是高收益点。
- 现有 `run_perf.sh`、`perf_monitor.sv` 和 `tools/parse_perf.py` 已能输出 CPI、双发、stall、分支、DCache/LSU、Branch Predictor、Frontend/FTQ 和互斥 CPI stack，并支持自动落盘、长短测试分级和 baseline 对比。

## 阶段计划

### Phase 0: 明确测试预算

先建立固定测试预算，避免脚本未成熟时做一小时级长跑。

| 等级 | 用途 | 允许时机 | 预算 |
|------|------|----------|------|
| Smoke | 验证脚本能编译、能运行、能解析输出 | 每次脚本改动后 | 1 到 3 个短测试 |
| Focused | 验证某类指标是否可信 | 计数器或解析逻辑完成后 | 少量代表测试 |
| Sampled COE | 看目标程序局部行为 | profiling 脚本稳定后 | commit/cycle 截断 |
| Full COE / Vivado | 最终确认性能和 timing | 阶段性优化完成后 | 只在必要里程碑运行 |

默认不跑 full COE。只有当脚本输出已经可复现、可比较、并且当前改动值得验证时才跑。

### Phase 1: 先完善 profiling 脚本

目标是让一次 profiling 自动产生可比较的数据，而不是只在终端打印一堆文本。

计划改动：

- 增强 `run_perf.sh`，使结果写入 `work/perf/<timestamp-or-name>/`。
- 每次结果记录：git commit、dirty 状态、测试名、cycle limit、commit limit、PASS/FAIL/TIMEOUT、cycles、commits、CPI、IPC、dual-issue rate。
- 用 `tools/parse_perf.py` 把 `[PERF]` 文本解析成稳定的 CSV/JSON summary。
- 支持测试集合分级：`smoke`、`focused`、`branch`、`cache`、`dual`、`all`。
- 支持 `--max-cycles`、`--max-commits`、`--no-compile`、`--out <dir>` 等参数，避免重复编译和误跑长测试。
- 支持 `--baseline <dir-or-summary.csv>` 输出当前结果相对 baseline 的 cycle、CPI、IPC、dual-issue rate 变化。

本阶段只允许跑 smoke，例如：

```bash
cd 02_Design/riscv_tests
bash run_perf.sh
```

### Phase 2: 补齐关键计数器

现有计数器已经覆盖很多 ID/RAW/dual issue 信息，下一步优先补齐会直接影响优化决策的分类。

优先新增：

- DCache：load/store 访问数、hit/miss、refill 次数、writeback/store buffer stall、cacheable/MMIO 分流。已完成第一版，结果进入 `summary.csv/json` 和 baseline compare。
- Branch Predictor：分支总数、taken/not-taken、方向错、目标错、BTB miss、RAS/JALR 相关错误、NLP redirect 原因。已完成第一版，结果进入 `summary.csv/json` 和 baseline compare。
- Frontend：IROM/F0 有效周期、BP0 发射阻塞、FTQ/FQ 占用、redirect、fetch accept bubble。已完成第一版，结果进入 `summary.csv/json` 和 baseline compare。
- CPI stack：形成优先级互斥分类，避免同一个周期被多个 stall 重复归因。已完成第一版，`cpi_stack_total` 应等于 `cycles`。

计数器必须是仿真用、非侵入式或低侵入式，不能改变 RTL 功能路径。

### Phase 3: 建立基线

脚本稳定后建立一份可复现基线。

测试集合：

- Smoke correctness/perf：`simple`、`dual_alu`、`slot1_load`、`slot1_store`。
- Branch focused：`bp_stress`、`bp_dual`、`branch_dual_edge`、`slot1_bp_update`。
- Cache/LSU focused：`dcache_stress`、`dcache_dual`、`counter_stress`、`sb_stress`。
- M/long-latency focused：`m_ext`。
- COE sampled：`current`、`src0`、`src1`、`src2`、`new_with_Mext`，先用 commit/cycle 截断。

基线至少要保存：

- 每个测试的 PASS/DONE 状态、cycles、commits、CPI、IPC。
- stall 分类百分比。
- branch miss rate 和每类 redirect 贡献。
- DCache miss/stall 贡献。
- dual issue 机会损失分类。
- 对应 commit hash 和是否 dirty。

### Phase 4: 用数据选择优化方向

每个候选优化都按收益排序，不凭直觉排优先级。

评估公式：

```
new_time / old_time = (new_cycles / old_cycles) * (new_period / old_period)
```

优先级规则：

- 若某类 stall 在目标 COE sampled 中占比高，并且 RTL 改动局部，优先做。
- 若某个优化会降低 CPI 但显著恶化 Fmax，需要用公式抵消后再决定。
- 若某个 timing 优化只改善非目标频率瓶颈，且不降低 cycles，优先级降低。
- 每次只改一类机制，避免 profiling 无法归因。

候选方向暂定：

1. Branch Predictor / Frontend：降低 redirect、JALR/RAS/BTB/NLP 相关损失。
2. DCache / LSU：降低 miss/refill/store buffer 对流水线的阻塞。
3. Dual Issue Policy：扩大 S1 可发射范围或减少同包/前端损失。
4. RAW / Forwarding：减少 ready-no-forward 和 load-use 额外等待。
5. Timing-only RTL：只在 Fmax 明确限制最终性能时继续做组合路径优化。

### Phase 5: 分批实现和验证

每一批优化遵循固定流程：

1. 记录 baseline。
2. 只改一个机制。
3. 跑 smoke，确认功能没坏。
4. 跑 focused perf，确认目标计数器确实下降。
5. 若 focused 有收益，再跑 sampled COE。
6. 若 sampled COE 有收益，再考虑 full COE 或 Vivado timing。

## 准确性要求

- 功能正确性优先：性能数据只接受 PASS 或明确 stop_pc/DONE 的样本。
- 同一组对比必须使用相同测试输入、相同 cycle/commit limit、相同仿真模型。
- 每份结果必须记录 git hash 和 dirty 状态。
- 长测试前必须先确认 parser、计数器和 baseline comparison 在 smoke 上工作。
- CPI stack 尽量互斥；无法互斥的计数器只作为辅助指标，不作为主收益归因。
- 对短程序不解读微小百分比差异，避免把启动/收尾流水线开销当成真实收益。
- 最终性能结论必须同时报告 CPI/IPC 和 Fmax/timing，不能只看其中一个。

## 下一步

当前 Phase 1 基本入口已完成：

- `run_perf.sh` 默认只跑 `smoke` 集合，避免误跑长测试。
- profiling 结果会落盘到 `work/perf/<timestamp>_<git>_<set>/`。
- `tools/parse_perf.py` 会生成 `summary.csv`、`summary.json`，并支持 baseline 对比。
- 已用 `simple`、`dual_alu` 做过 smoke 验证。

下一批工作转入 Phase 3：短 focused 集合已有历史基线样例，可作为脚本输出格式参考；若要评价当前 RTL，必须在当前 commit/dirty 状态下重新生成基线。在确认 focused 数据稳定前，不运行一小时级长测试。

Phase 2 当前进度：

- DCache / LSU 细分已接入 `perf_monitor.sv`：cacheable/MMIO load/store、DCache request/hit/miss、refill cycles/words/aborts、store buffer enqueue/drain/block/conflict、store-forward hit。
- Branch Predictor 细分已接入 `perf_monitor.sv`：S0/S1 控制流、S0 方向错/目标错、S1 lookup/redirect、ID tournament redirect、BP training、BTB/PHT/selector/GHR/RAS/JALR sidecar 写入。
- Frontend / FTQ 细分已接入 `perf_monitor.sv`：BP0 fire/阻塞、EX/BP1 redirect、F0 accept/enqueue/kill、BP1 override、IF accept dual/single/empty、FQ/FTQ occupancy。
- CPI stack 已接入 `perf_monitor.sv`：按 redirect、DCache、MUL/DIV、RAW not-ready、RAW ready-no-forward、Frontend empty、other no-commit、retire 做优先级互斥分类。
- `tools/parse_perf.py` 已解析这些字段，并在 baseline compare 中加入 DCache、Branch Predictor、Frontend/FTQ 和 CPI stack 关键指标。
- 已用 `lw`、`sw`、`beq`、`bne`、`jal`、`jalr`、`simple`、`dual_alu` 做短测试验证。
- Frontend/FTQ 和 CPI stack 新增字段已用 `simple`、`dual_alu` 做短 smoke 验证；两个样本的 `cpi_stack_total` 均等于 `cycles`。

下一步建议：先在当前 RTL 上重跑 `branch`、`cache`、`dual` focused 集合，确认各类计数器在对应场景下仍有区分度；再决定是否做 COE profiling。暂不跑 full COE 作为默认动作。
