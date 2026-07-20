# run_coe_perf 改动方向

本文档只记录改造方向，不做性能结论。目标是让 `run_coe_perf.sh`
产出的原始数据真实、完整，并且足够定位当前周期主要损失来自哪里。

当前约束：

- 不把时序问题作为分析方向。
- 不用 `run_coe_perf` 代替 correctness smoke；功能正确性仍由
  `functional/run_all.sh` 等入口负责。
- COE 长程序由人工显式触发，脚本维护时优先做静态检查、parser 检查和
  小样本验证。

## P0：先保证一次 run 是否可信

### 1. 明确 run 完整性状态

问题：

- 现在 `latest/coe` 可能是被中断后的半截结果。
- 部分日志出现 `Received SIGHUP` 时，parser 会把它归为 `UNKNOWN`，但整体流程
  仍可能成功结束。
- `SKIP`、`UNKNOWN`、缺日志、非零退出码没有统一变成整次 run 失败。

改动方向：

- 在 `run_coe_perf.sh` 中写入 `run_status.env` 或等价状态文件。
- run 开始时标记 `complete=0`。
- 只有全部预期 COE 都完成、全部日志可解析、没有 `SKIP/UNKNOWN/FAIL/TIMEOUT`
  时，才标记 `complete=1`。
- 增加最终检查：预期测试数量、日志数量、summary 行数必须一致。
- 任意一个 COE 缺失、仿真被信号中断、日志不可解析或状态未知，都让脚本返回
  非零。

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tools/parse_perf.py`

验收标准：

- 中途 Ctrl-C、SIGHUP、缺 COE、缺 log 都不会留下看起来完整的 `latest/coe`。
- summary 中不能静默混入 `UNKNOWN` 或 `SKIP`。

### 2. 区分完整运行和采样运行

问题：

- 使用 `--max-cycles` 时，testbench 目前可能打印类似 `[DONE]` 的结果。
- 这会让截断采样看起来像完整跑完。

改动方向：

- 把 cycle limit 触发的结束原因标成 `CYCLE_LIMIT` 或 `SAMPLED`。
- parser 增加 `completion_reason` 字段，例如：
  `stop_pc`、`tohost_pass`、`cycle_limit`、`commit_limit`、`watchdog`、
  `pc_guard`、`timeout`、`signal`、`unknown`。
- summary 增加 `is_full_run` 字段。
- 完整性能记录默认只接受 `stop_pc` 或明确的 pass 条件。
- 采样模式可以生成数据，但必须在 CSV/JSON 中显式标出不是完整 run。

涉及文件：

- `tb/tb_riscv_tests.sv`
- `tools/parse_perf.py`
- `performance/long/run_coe_perf.sh`

验收标准：

- 看到 summary 就能区分“完整跑完”和“跑到周期上限后截断”。

### 3. 原子更新 latest 输出

问题：

- 当前输出目录可能在 run 开始时被清空。
- 如果长跑中断，旧的完整数据会被半截新数据覆盖。

改动方向：

- 每次先写入 timestamp 目录，例如 `work/perf/runs/coe/<timestamp>/`。
- run 完整通过后，再更新 `work/perf/latest/coe` 指向该目录。
- 如果不用符号链接，也应先写临时目录，最后再做一次原子 rename。
- 保留最近若干次历史 run，便于对比和排查。

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tools/perf_output.sh`

验收标准：

- 失败或中断的 run 不会破坏上一份完整 `latest/coe`。

## P1：让原始数据能解释主要周期损失

### 4. 建立严格的提交槽位统计

问题：

- 现在能看到 cycles、instructions、IPC/CPI，但双发射损失和 CPI stack 不是同一套
  严格口径。
- 只看 IPC 不能知道损失来自完全没提交、单发提交、还是 slot1 被阻塞。

改动方向：

- 增加原始计数：
  - `cycles_measured`
  - `commit0_cycles`
  - `commit1_cycles`
  - `commit2_cycles`
  - `retired_insts`
  - `ideal_slots = cycles_measured * 2`
  - `retired_slots`
  - `lost_slots = ideal_slots - retired_slots`
- 对 `lost_slots` 做第一层归因：
  - no commit cycle 损失
  - single issue cycle 损失
  - slot1 block 损失
  - pipeline stall 损失

涉及文件：

- `tb/perf_monitor.sv`
- `tools/parse_perf.py`

验收标准：

- 每个 COE 都能从 CSV 直接算出双发射利用率和 lost slot 总量。

### 5. 拆细 `other_no_commit`

问题：

- 当前 `other_no_commit` 很大时，只能说明“有大量周期没有提交”，但不知道原因。
- branch recovery bubble、frontend 空、pipe fill/drain、特殊等待可能都混在里面。

改动方向：

- 保留当前 CPI stack，同时新增更细的 raw counter。
- 将 no-commit 周期至少拆成：
  - redirect recovery / branch flush 后恢复
  - frontend empty / fetch 无有效指令
  - decode/issue held
  - backend 等待但非 DCache、非 MULDIV、非 RAW
  - reset 后 warmup 或 stop 前 drain
  - unknown no commit
- 如果信号不足，先把能可靠判定的项拆出来，剩余保留为
  `unknown_no_commit`。

涉及文件：

- `tb/perf_monitor.sv`
- `tools/parse_perf.py`

验收标准：

- `other_no_commit` 不再是主要大项；如果仍然很大，必须有对应的
  `unknown_no_commit` 明确暴露。

### 6. 保留完整 stall 和事件原始计数

问题：

- `perf_monitor.sv` 已打印不少详细计数，但 parser 只抓了一部分字段。
- 后续分析依赖 CSV/JSON，不应该要求人工重新翻 log。

改动方向：

- parser 把 perf log 中已经打印的关键 raw counter 全部收进 JSON。
- CSV 保留高价值列，JSON 保留完整字段。
- 对以下类别至少完整保留：
  - DCache request/miss/refill/wait 相关计数
  - load-use stall
  - RAW stall
  - MULDIV wait
  - branch redirect/flush/recovery
  - frontend empty
  - dual-issue blocked reason
  - slot0/slot1 commit 分布

涉及文件：

- `tools/parse_perf.py`
- `tb/perf_monitor.sv`

验收标准：

- 同一个 log 里的关键 perf counter，不会只存在于 `.log` 而缺失于
  `summary.json`。

### 7. 所有派生指标从整数 raw counter 重算

问题：

- 如果 parser 直接使用日志里的四舍五入 CPI/IPC，后续做对比会丢精度。

改动方向：

- CSV/JSON 中保留整数 raw counter。
- CPI、IPC、百分比、每千指令事件数等派生指标由 parser 统一重算。
- summary 增加 `schema_version`，避免之后字段语义变化时混用旧数据。

涉及文件：

- `tools/parse_perf.py`

验收标准：

- 同一份 summary 可以重复计算出一致的 CPI、IPC 和占比。

## P1：让数据可复现

### 8. 保存输入和二进制来源

问题：

- 当前只记录 git commit/dirty 还不够。
- dirty worktree、`--no-compile`、旧 simv、旧 COE 都可能让数据无法复现。

改动方向：

- 保存：
  - git commit
  - git dirty 状态
  - `git diff --stat`
  - 可选的 `git diff` 快照
  - `simv` 路径、mtime、sha256
  - 每个 COE 文件路径、mtime、sha256
  - run command line
  - VCS compile options
  - RTL define/config 摘要
- 使用 `--no-compile` 时，明确记录复用的 simv hash，并打印 warning。

涉及文件：

- `performance/long/run_coe_perf.sh`

验收标准：

- 仅凭 run 目录中的 metadata，可以判断这次数据对应哪个源码和哪个输入。

### 9. 保存 stop_pc 推导结果

问题：

- COE stop_pc 是完整运行判断的重要依据。
- 如果 stop_pc 推导错，完整性判断会失效。

改动方向：

- 每个 COE 保存：
  - 推导出的 `stop_pc`
  - 推导工具版本或命令
  - 推导失败原因
- stop_pc 推导失败时，不应静默降级为不完整的 run。

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tools/derive_coe_stop_pc.py`

验收标准：

- summary 能说明每个程序是靠哪个 stop_pc 判定结束的。

## P2：增强异常检测，但不替代功能测试

### 10. 增加活跃跑飞检测

问题：

- 现在 watchdog 主要检测长时间无进展。
- 如果程序跑飞后仍持续提交，watchdog 不一定触发。

改动方向：

- 对完整 COE 增加可选硬上限，例如 `--hard-max-cycles`。
- 硬上限触发时标为 `TIMEOUT`，不能标为普通完成。
- 可选增加 commit 上限，防止错误循环持续提交。
- 对 PC guard 增加可配置范围和命中统计。

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tb/tb_riscv_tests.sv`

验收标准：

- 活跃错误循环不会无限占用仿真资源，也不会被误认为完整性能数据。

### 11. 增加轻量一致性检查

问题：

- `run_coe_perf` 不是 correctness gate，但长程序跑飞时需要尽早暴露异常。

改动方向：

- 检查日志中是否出现 X/Z、fatal、assert、error 关键字。
- 检查 tohost、stop_pc、pc_guard、watchdog 等结束条件是否互斥且合理。
- 检查 `cycles >= committed_cycles`、`commit0+commit1+commit2 == cycles`
  这类内部一致性。
- 检查 `retired_insts == slot0_commits + slot1_commits`。

涉及文件：

- `tools/parse_perf.py`
- `performance/long/run_coe_perf.sh`

验收标准：

- 数据口径内部矛盾时，summary 明确标红或脚本失败。

## P2：改善使用体验和对比能力

### 12. 增加 baseline 对比模式

问题：

- 用户最终需要判断优化空间，但原始数据本身应先真实。
- 在数据可信后，可以做轻量对比，不直接替代人工判断。

改动方向：

- 支持 `--baseline <summary.csv/json>`。
- 生成 `compare.csv`，只列原始计数和派生指标差值。
- 不在脚本里自动给性能建议，只输出变化量。

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tools/parse_perf.py` 或新增共享 compare 工具

验收标准：

- 能比较两次完整 COE run 的 cycles、IPC、lost slots 和主要事件计数变化。

### 13. 增加机器可读 manifest

问题：

- 后续脚本、人工和 AI 都会读数据，目录结构需要稳定。

改动方向：

- 每次 run 生成 `manifest.json`，包括：
  - run id
  - schema version
  - expected tests
  - produced logs
  - per-test status
  - metadata files
  - summary 文件路径
  - complete 标记

涉及文件：

- `performance/long/run_coe_perf.sh`
- `tools/parse_perf.py`

验收标准：

- 其他工具不用猜目录结构，也能判断这次 run 是否完整。

## P3：后续测试覆盖方向

这些不是 `run_coe_perf` 的首要改动，但和当前 M 扩展、DCache 后出现跑飞有关。
如果要补测试，应放到 correctness 体系里，而不是只靠 COE 长跑发现。

### 14. M 扩展边界测试

方向：

- `mul/mulh/mulhsu/mulhu` 的符号边界。
- `div/divu/rem/remu` 的除零、溢出、负数、最小负数边界。
- MULDIV 多周期等待期间的 stall、flush、redirect 交互。
- MULDIV 结果写回与后续 RAW 的交互。

主要位置：

- `verification/riscv/src/`
- `functional/run_all.sh`

### 15. DCache load miss 边界测试

方向：

- load miss 后关键字返回周期。
- refill 期间同地址/不同地址 load。
- load miss 后紧跟 store。
- byte/half/word load 的符号扩展。
- cacheline 边界、未命中后 RAW、flush/branch redirect 期间的 miss。

主要位置：

- `verification/riscv/src/`
- DCache 或 CPU 集成 testbench
- `functional/run_all.sh`

### 16. 长程序小型定向化

方向：

- 从 COE 跑飞现象中提取最小复现片段。
- 把复现片段做成短 hex 或 directed test。
- 短测试进入 correctness gate，COE 继续作为长程序性能入口。

主要位置：

- `verification/riscv/src/`
- `functional/`

## 建议实施顺序

1. P0-1 到 P0-3：先修完整性、结束原因和 latest 输出，避免继续生成假完整数据。
2. P1-4 到 P1-7：补 lost slot、no commit、stall、DCache、RAW、MULDIV、
   branch 的 raw counter 和 parser 字段。
3. P1-8 到 P1-9：补 metadata、hash 和 stop_pc provenance。
4. P2-10 到 P2-13：补异常检测、manifest 和 baseline 对比。
5. P3-14 到 P3-16：针对 M 扩展和 DCache 补 correctness 边界测试。

第一轮最小可交付版本：

- `run_coe_perf` 不再接受半截结果。
- `summary.csv/json` 能区分完整 run 和采样 run。
- `summary.json` 保留关键 raw counter。
- 每个 COE 都有 `cycles`、`instret`、`IPC/CPI`、`lost_slots`、
  `commit0/1/2_cycles`、DCache、RAW、MULDIV、branch、frontend/no-commit 相关
  计数。
