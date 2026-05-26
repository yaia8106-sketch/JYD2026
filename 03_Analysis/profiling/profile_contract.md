# Profile Contract

<!--
文档职责：
- 只记录 profiling 脚本测什么、怎么测、如何判断程序结束、输出 schema 和自检规则。
- 可以记录稳定指标的定义和分类口径。
- 不记录某次程序的测量结果。
- 不记录临时优化结论。
- 不记录脚本代码结构；代码结构放 README.md。
-->

本文件定义 profiling 工具的稳定契约。后续新增功能时，优先扩展本契约，再修改脚本。

profiling 结果只描述当前工作区当前架构的仿真表现，不要求也不记录 git commit、分支名或 dirty 状态。

## 测试对象

profiling 工具至少支持两类程序：

1. `riscv-tests`：使用 `02_Design/riscv_tests/work/hex/rv32ui-p-*.irom.hex` 和 `.dram.hex`。
2. COE 程序：默认使用 `02_Design/coe/dual_issue/<name>/irom_slot0.coe`、`irom_slot1.coe` 和 `dram.coe`，由 testbench 按上板同样的双 bank IROM 组织取指；只有做 flat/banked 对照实验时才直接使用 `single_issue/<name>/irom.coe`。

日常默认 COE profiling 集合只包含两套最新程序：

| 名称 | IROM | DRAM | 停止条件 |
|------|------|------|----------|
| `new_without_Mext` | `02_Design/coe/dual_issue/new_without_Mext/irom_slot0.coe` + `irom_slot1.coe` | `02_Design/coe/dual_issue/new_without_Mext/dram.coe` | `DONE_PC = 0x80000010` |
| `new_with_Mext` | `02_Design/coe/dual_issue/new_with_Mext/irom_slot0.coe` + `irom_slot1.coe` | `02_Design/coe/dual_issue/new_with_Mext/dram.coe` | `DONE_PC = 0x80000014` |

`current/src0/src1/src2` 不是日常 profiling 默认集合。只有用户明确要求比较旧 COE 或复现实验时才运行。

## 停止条件

停止条件必须由 `test_catalog.py` 或等价的集中模块维护，不允许散落在各 collector 中。

稳定停止条件：

- `LED_PASS`：LED MMIO 写入 riscv-tests PASS 值。
- `LED_COE_DONE`：LED MMIO 写入指定 COE 完成图案。
- `DONE_PC`：commit PC 到达指定自旋点或完成点。
- `COMMIT_LIMIT`：达到指定 commit 数，用于长前缀对比。
- `TIMEOUT`：超过最大 cycles。
- `WATCHDOG`：长时间无 commit 或无进展。
- `FAIL`：LED/MMIO 明确报告失败，或 PC guard 触发。

每次结果必须记录实际停止原因、停止时 cycles、commit 数和最终 LED/PC。

对默认两套最新 COE，第一次 LED 写入不是可靠结束条件，必须以 `DONE_PC` 作为程序完成判据。
如果某个测试声明了 `stop_pc`，脚本只能接受 `DONE_PC` 作为完成条件；
即使仿真过程中出现 LED PASS，只要没有到达声明的 `stop_pc`，报告就必须标为未完成。

默认两套最新 COE 的早期 LED 位是阶段进度，不是完整程序结束：

- `new_without_Mext` 在当前 COE 中会很早写出 `0x00000001`，随后写出 `0x00000003`；这表示初始化/RV32I 入口检查和 CSR/trap/ecall 阶段已经写过进度位，不能按失败解释。
- `new_with_Mext` 在当前 COE 中会很早写出 `0x00000001`，随后写出 `0x00020001`；同样表示早期阶段进度位。
- 后续长时间不增加 LED 位不等于处理器卡死。必须同时查看 `commits`、`pc`、`last_wb0_pc`、`last_wb1_pc` 和 watchdog/PC guard。

## 必须输出的顶层字段

`profile_report.json` 顶层必须包含：

```text
schema_version
generated_at
run_config
enabled_collectors
tests
summary
issue
stall
raw
branch
memory
muldiv
self_check
```

`run_config` 至少包含：

- `jobs`：本次 profiling 使用的并行度，必须小于等于 16。
- `max_cycles`
- `watchdog_cycles`
- `simulator`
- `requested_tests`
- `requested_collectors`
- `led_trace`

每个 test 行至少记录：

- `name`
- `irom_mode`：`flat` 或 `banked`。默认两套最新 COE 必须是 `banked`。
- `status`
- `stop_reason`
- `expected_stop_reason`
- `cycles`
- `log_file`
- `commits` 或 `total_commits`
- `pc`
- `last_wb0_pc`
- `last_wb1_pc`

## 稳定指标

### Summary

- `cycles`
- `s0_commits`
- `s1_commits`
- `total_commits`
- `cpi`
- `ipc`
- `dual_issue_rate_commit = s1_commits / s0_commits`
- `stop_reason`

### Issue

slot1 blocked 原因必须优先保证互斥。一个 IF accept 周期中，slot1 未进入 IF/ID 时，只能归入一个主因。

- `if_accepts`
- `s1_accepted`
- `s1_committed`
- `s1_squashed`
- `s1_blocked_total`
- `s1_blocked_raw`
- `s1_blocked_unsupported`
- `s1_blocked_s0_restriction`
- `s1_blocked_not_sequential`
- `s1_blocked_system_order`
- `s1_blocked_muldiv_order`
- `s1_blocked_flush_redirect`
- `s1_blocked_stall_or_hold`

unsupported 需要继续细分：

- `unsupported_load`
- `unsupported_store`
- `unsupported_jal`
- `unsupported_jalr`
- `unsupported_branch_constraint`
- `unsupported_muldiv`
- `unsupported_system`
- `unsupported_other`

### Stall / RAW

- `id_stall_cycles`
- `load_use_stall_cycles`
- `dcache_stall_cycles`
- `muldiv_wait_cycles`
- `raw_ex_load_pending`
- `raw_mem_load_not_ready`
- `raw_mem_ready_no_forward`
- `raw_branch_ex_no_forward`
- `raw_jalr_ex_no_forward`
- `raw_repaired_ex_chain_no_forward`
- `same_pair_raw_lost_slots`

RAW 子项可以按 consumer 类型扩展，但默认报告必须能聚合回上述稳定字段。

### Branch

- `branch_total`
- `branch_conditional`
- `jal_total`
- `jalr_total`
- `btb_hit`
- `btb_miss`
- `mispredicts`
- `mispredict_rate`
- `nlp_redirects`
- `frontend_flushes`
- `slot1_branch_replays`
- `ras_hits`
- `ras_misses`

### Memory

- `loads`
- `stores`
- `s0_loads`
- `s0_stores`
- `s1_loads`
- `s1_stores`
- `dcache_hits`
- `dcache_misses`
- `dcache_refill_cycles`
- `store_buffer_forwards`
- `store_buffer_conflict_stalls`
- `mmio_accesses`

### MulDiv

- `muldiv_insts`
- `mul_insts`
- `div_insts`
- `rem_insts`
- `muldiv_busy_cycles`
- `muldiv_wait_cycles`
- `muldiv_dependency_stalls`

## 自检规则

每次运行结束必须执行自检：

- `total_commits == s0_commits + s1_commits`
- `s1_accepted <= if_accepts`
- `s1_committed <= s1_accepted`
- `s1_blocked_total + s1_accepted == if_accepts`，如果口径不成立，必须在 `self_check.notes` 写明原因。
- cycles 和 commits 非零，除非 stop_reason 是早期 FAIL。
- 每个 test 都有明确 stop_reason。
- JSON schema version 与 reporter 支持版本一致。

自检失败时，脚本仍可生成报告，但必须把 overall status 标为 `INVALID_PROFILE`。
