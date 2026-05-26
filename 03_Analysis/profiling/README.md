# Profiling

<!--
文档职责：
- 只记录 profiling 框架的整体目标、入口、脚本联动方式和覆盖式输出约定。
- 可以记录未来脚本的命名、职责和调用关系。
- 不记录具体指标定义细节；指标定义放 profile_contract.md。
- 不记录某次运行结果；结果只写覆盖式 profile_report.* 或 output/。
-->

本目录用于建设可维护的处理器仿真 profiling 框架。目标是让后续优化前能够稳定回答：

- 当前性能是多少：cycles、CPI、IPC、双发射率。
- 为什么没有双发：slot1 blocked 的互斥原因。
- 为什么停顿：RAW、load-use、DCache、MULDIV、flush/redirect。
- 分支和访存是否是瓶颈：mispredict、NLP redirect、DCache miss、store buffer stall。

## 设计原则

1. profiling 只描述当前工作区当前架构的仿真结果，不记录 git commit 或 dirty 状态。
2. 脚本可以组合，不把所有分析都写进一个不可维护的大文件。
3. runner 负责“怎么跑完程序”，collector 负责“测什么”，reporter 负责“怎么展示”。
4. collector 之间通过统一 JSON 交换数据，不复制停止条件、测试路径和指令分类逻辑。
5. 输出文件名固定，每次运行覆盖旧结果。
6. profiling / 仿真分析最多使用 16 jobs。
7. 每个输出都带 schema version、测试集、停止条件、仿真器信息和启用的 collectors。

## 默认测试集

日常 profiling 默认只跑两套最新 COE：

- `new_without_Mext`
- `new_with_Mext`

这两套程序使用 `02_Design/coe/dual_issue/<name>/irom_slot0.coe`、`irom_slot1.coe` 和 `dram.coe` 作为默认仿真输入。也就是说，profiling 默认模拟上板使用的双 bank IROM 组织，而不是只用 flat `single_issue/irom.coe`。它们不能按第一次 LED 写入停止，必须使用集中维护的 done PC 停止条件。具体路径和 done PC 记录在 `profile_contract.md`，实现时由 `catalog/test_catalog.py` 统一提供。

带 `stop_pc` 的测试期望停止原因为 `DONE_PC`。LED 写入仍可作为观测字段记录，但不能掩盖 watchdog、timeout 或 PC guard 等未完成结果。

当前默认 COE 的 LED 是阶段进度寄存器，不是单一 pass/fail 寄存器。比如 `new_without_Mext` 早期的 `0x00000003` 和 `new_with_Mext` 早期的 `0x00020001` 都不能直接解释成失败；判断是否跑完必须看 `DONE_PC`，判断是否卡住必须看 `commits`、`pc`、最后提交 PC 和 watchdog。

## 建议脚本分层

后续实现时按职责拆分，并按目录分层存放。不要把所有脚本和文档平铺在 `profiling/` 根目录。

建议目录结构：

```text
03_Analysis/profiling/
├── README.md
├── profile_contract.md
├── document_rules.md
├── run_profile.py
├── runners/
│   └── sim_runner.py
├── catalog/
│   └── test_catalog.py
├── collectors/
│   ├── summary.py
│   ├── issue.py
│   ├── raw.py
│   ├── branch.py
│   ├── memory.py
│   └── muldiv.py
├── reporting/
│   └── report.py
├── common/
│   ├── schema.py
│   ├── profile_events.py
│   └── decode.py
└── output/                 # ignored, coverage-style latest intermediates
```

各层职责：

| 脚本 | 职责 | 不应该做什么 |
|------|------|--------------|
| `run_profile.py` | 总入口，解析参数，调度 runner/collector/report，合并 collector 需求 | 不直接写复杂指标判定 |
| `runners/sim_runner.py` | 编译仿真器、运行测试、处理 timeout/watchdog/停止条件，保证程序可靠结束 | 不解释双发射、RAW、DCache 指标 |
| `catalog/test_catalog.py` | 管理 riscv-tests/COE 测试列表、hex 路径、默认停止条件 | 不跑仿真 |
| `collectors/*.py` | 声明采集需求，解析 `[PROFILE]` 或 trace，输出局部 JSON | 不决定程序何时结束，不生成最终 Markdown |
| `reporting/report.py` | 聚合 JSON，生成 Markdown/CSV | 不重新计算底层事件 |
| `common/schema.py` | 定义 profile JSON schema 和自检规则 | 不包含工程路径 |
| `common/decode.py` | 提供共享指令分类/解码辅助 | 不维护测试列表或停止条件 |

## 脚本说明块

每个 Python 脚本文件开头必须有自然语言说明块，方便后续 AI 和人类维护。说明块至少写清：

- 这个脚本负责什么。
- 这个脚本不负责什么。
- 它读取哪些输入。
- 它生成哪些输出。
- 它依赖哪些同级模块。
- 新增功能时应该扩展哪里，而不是修改哪里。

脚本内部复杂函数也应有短注释说明统计口径或边界条件。不要只依赖函数名表达 profiling 语义。

## 脚本联动模型

一次 profiling 运行由总入口统一编排：

```text
run_profile.py
  -> catalog/test_catalog.py # 选择测试、hex、停止条件
  -> runners/sim_runner.py   # 编译并运行仿真，保证程序结束
  -> collectors/summary.py  # 基础状态和现有 PERF 摘要
  -> collectors/issue.py    # 双发射和 slot1 blocked
  -> collectors/raw.py      # RAW 和数据相关
  -> collectors/branch.py   # 分支预测
  -> collectors/memory.py   # DCache/store buffer
  -> reporting/report.py    # 输出 profile_report.*
```

如果某个新分析不能独立完成，例如 RAW 分析需要知道程序何时结束、指令类型、commit trace，那么它必须复用 `catalog/test_catalog.py`、`runners/sim_runner.py` 和已有 decoder/trace collector，而不是复制一套停止条件或指令分类逻辑。

collector 可以声明自己需要的仿真能力，例如 `+perf`、commit trace、decode trace、DCache event trace。`run_profile.py` 负责合并这些需求，优先一次仿真跑完；只有需求互斥或开销过大时，才由 `sim_runner.py` 统一拆成多次运行。

## 并行策略

profiling 脚本默认可以并行跑多个测试，但总并行度不得超过 16 jobs。实现时应集中在 `run_profile.py` 或 `sim_runner.py` 处理 `--jobs`，collector 不允许各自启动不受控的并行任务。

## 覆盖式输出

默认输出位置：

```text
03_Analysis/profile_report.md
03_Analysis/profile_report.json
03_Analysis/profile_report.csv
03_Analysis/profiling/output/
```

`profile_report.md` 面向人工阅读，`profile_report.json` 是完整机器可读结果，CSV 文件用于表格比较。`output/` 可保存本次运行的中间 JSON、raw log 摘要和分项 CSV，但不保存历史多版本。

## 和 perf_monitor.sv 的关系

RTL/TB 侧的 `perf_monitor.sv` 应负责打印稳定事件和计数，例如：

```text
[PROFILE] section=issue key=s1_blocked_raw value=123
```

Python 侧负责解析、聚合和报告。除非没有其它选择，不要让 Python 从非结构化普通日志中猜指标。
