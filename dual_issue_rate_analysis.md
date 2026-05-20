# 双发射率偏低原因调查

日期：2026-05-20

本文档记录当前处理器六份 COE 程序的双发射率调查结果。重点不是只看最终 `Dual-issue %`，而是把问题拆成：

1. IF 阶段是否真正把 slot1 带入 IF/ID。
2. slot1 被挡住时，具体是 RAW、slot1 类型不支持、取指不连续，还是 slot0 类型限制。
3. 后端是否被 load-use、DCache miss、MULDIV wait、flush 继续拖慢。

## 测量口径

- 仿真器：Verilator。
- 日志目录：`/tmp/dual_issue_diag/log/`。
- 普通 COE：`current/src0/src1/src2` 使用通用 LED/tohost 停机。
- `new_without_Mext/new_with_Mext`：使用 done-PC testbench，分别在 `0x80000010` 和 `0x80000014` 停机。
- 主要计数器来源：`02_Design/riscv_tests/tb/perf_monitor.sv`。
- 本次给 `perf_monitor.sv` 增加了 IF-accept 口径的动态分类计数：
  - `IF accepts = if_valid & if_ready_go & id_allowin & ~id_flush`
  - `S1 accepted = IF/ID 实际接收 slot1`
  - `S1 blocked = IF/ID 接收 slot0，但 slot1 未被接收`

旧的 `Fetch Mix / Dual-issue Loss` 仍保留，但它按 raw fetch path 计数，且部分项目不是严格互斥。本文后面的原因分析以新的 `IF Accept Dual-issue Diagnosis` 为准。

## 当前双发射规则

RTL 里的硬约束非常关键：

- slot1 当前只支持普通 ALU 类指令，或在受限条件下支持 branch。
- slot1 不支持 load/store/MULDIV/JAL/JALR/SYSTEM。
- 同一 fetch pair 内如果 `slot0.rd == slot1.rs1/rs2`，直接禁止双发射。
- slot0 是 MULDIV 时禁止双发射。
- slot1 是 branch 时，slot0 不能是 control，也不能是 LSU。
- 取指必须是 sequential fetch。

对应代码位置：

- `02_Design/rtl/dual_issue_decider.sv:49` 到 `:80`
- `02_Design/rtl/if_stage_buffer.sv:238` 到 `:239`
- `02_Design/riscv_tests/tb/perf_monitor.sv:71` 到 `:100`
- `02_Design/riscv_tests/tb/perf_monitor.sv:223` 到 `:280`

## 总览

| COE | Cycles | CPI | 最终双发射率 `S1/S0` | IF accepts | S1 accepted / IF | S1 commit / S1 accept | 结论 |
|---|---:|---:|---:|---:|---:|---:|---|
| `current` | 36,247,924 | 1.178 | 60.6% | 27,425,936 | 67.8% | 62.4% | 前端可配对能力强，但取指不连续/flush 影响大 |
| `src0` | 2,044,868,564 | 1.442 | 16.9% | 1,335,707,921 | 21.3% | 72.1% | RAW 是第一主因，slot1 类型和前端也明显 |
| `src1` | 2,153,225,504 | 1.651 | 11.6% | 1,252,687,404 | 16.2% | 66.8% | slot1 不支持 load/store 是第一主因，load-use 很重 |
| `src2` | 2,637,386,996 | 1.426 | 30.8% | 1,733,739,007 | 37.4% | 67.2% | 三类原因都重：RAW、前端、slot1 类型 |
| `new_without_Mext` | 1,132,685,661 | 1.446 | 20.5% | 730,769,910 | 25.1% | 72.7% | RAW 主导，前端和 slot1 类型次之 |
| `new_with_Mext` | 629,033,648 | 1.654 | 6.0% | 359,032,254 | 6.0% | 100.0% | 几乎完全是发射阶段挡住：RAW + slot1 load/store 不支持 |

注意：`new_with_Mext` 双发射率最低，但总周期比 `new_without_Mext` 少很多。M 扩展把原来的软件乘除循环压缩成更少的 M 指令，程序整体更快，只是动态指令流更偏串行依赖和访存，所以双发射率下降。

## slot1 阻塞原因

下表百分比均以 `S1 blocked` 为分母。

| COE | S1 blocked | RAW | slot1 不支持类型 | Not seq fetch | S0 MULDIV | 主要问题 |
|---|---:|---:|---:|---:|---:|---|
| `current` | 8,833,139 | 11.4% | 24.7% | 62.8% | 0.0% | 前端/分支路径扰动 |
| `src0` | 1,051,075,791 | 54.0% | 25.0% | 21.0% | 0.0% | RAW 主导 |
| `src1` | 1,049,167,261 | 39.6% | 43.8% | 16.7% | 0.0% | slot1 load/store 不支持略高于 RAW |
| `src2` | 1,085,230,741 | 38.9% | 27.0% | 34.0% | 0.0% | RAW、前端、slot1 类型三者接近 |
| `new_without_Mext` | 547,417,481 | 52.9% | 22.4% | 24.7% | 0.0% | RAW 主导 |
| `new_with_Mext` | 337,453,914 | 60.8% | 32.9% | 3.2% | 3.1% | RAW 和 slot1 load/store，几乎不是分支 |

`Not seq fetch` 来自 `if_sequential_fetch = ~frontend_branch_flush & ~id_bp_redirect_raw & ~if_bp_taken_out`，所以它不等价于“误预测”。它还包含预测 taken、前端 redirect 等情况。

## slot1 不支持类型细分

slot1 不支持类型里，绝大多数不是奇怪指令，而是 load/store。

| COE | 不支持类型总数 | load | store | JAL/JALR/SYSTEM | MULDIV |
|---|---:|---:|---:|---:|---:|
| `current` | 2,179,540 | 600,257 | 200,199 | 1,379,084 | 0 |
| `src0` | 262,717,528 | 218,499,530 | 40,873,295 | 3,344,703 | 0 |
| `src1` | 459,122,191 | 371,221,138 | 66,106,096 | 21,794,957 | 0 |
| `src2` | 293,428,826 | 154,812,871 | 97,303,984 | 41,311,971 | 0 |
| `new_without_Mext` | 122,568,350 | 99,899,515 | 21,435,668 | 1,233,166 | 0 |
| `new_with_Mext` | 110,868,814 | 89,414,938 | 21,319,023 | 134,853 | 0 |

这说明“让 slot1 支持更多类型”确实有潜在收益，但收益主要来自 load/store，而不是 slot1 MULDIV。slot1 load 代价很高，因为会碰到 LSU/DCache 端口、load-use、异常/flush 顺序；slot1 store 可能是更现实的第一步，但它只能覆盖一部分机会。

## 后端停顿

| COE | Load-use / cycles | DCache miss / cycles | MULDIV wait / cycles | 分支误预测率 |
|---|---:|---:|---:|---:|
| `current` | 2.2% | 0.3% | 0.0% | 9.9% |
| `src0` | 16.6% | 4.0% | 0.0% | 18.8% |
| `src1` | 29.3% | 7.9% | 0.0% | 9.4% |
| `src2` | 12.3% | 3.1% | 0.0% | 19.4% |
| `new_without_Mext` | 15.6% | 5.9% | 0.0% | 21.4% |
| `new_with_Mext` | 27.7% | 10.2% | 5.1% | 1.2% |

`src1` 和 `new_with_Mext` 的 CPI 高，主要不是分支误预测，而是 load-use 和 DCache stall 很重。`new_with_Mext` 的 MULDIV wait 只有 5.1% cycles，不能解释 6.0% 的双发射率；它真正的 slot1 阻塞是 RAW 和 load/store 不支持。

## 分程序结论

### current

`current` 的双发射率 60.6%，说明当前结构在合适程序上可以工作。slot1 阻塞主要是 `Not seq fetch`，同时有较多 slot1 branch 被接受。这里继续优化分支路径、减少 redirect/flush，对双发射率有意义。

### src0

`src0` 双发射率低的第一原因是同包 RAW，占 blocked 的 54.0%。slot1 不支持类型占 25.0%，其中 98.7% 是 load/store。分支误预测率 18.8%，所以前端也值得优化，但不是唯一矛盾。

### src1

`src1` 的第一大阻塞是 slot1 不支持类型，占 43.8%，其中 load 占绝对多数。同时 load-use 占 29.3% cycles，DCache miss 占 7.9% cycles。这份程序不适合先从分支预测下手，更应该看访存相关、slot1 load/store 支持范围、load-use bypass。

### src2

`src2` 三类问题比较均衡：RAW 38.9%，Not seq 34.0%，slot1 不支持 27.0%。这份程序是分支前端优化最有代表性的对象之一，但只优化前端也不能解决全部双发射损失。

### new_without_Mext

`new_without_Mext` RAW 占 52.9%，Not seq 24.7%，slot1 不支持 22.4%。这和 `src0` 类似，属于 RAW 主导，同时有明显分支路径损失。

### new_with_Mext

`new_with_Mext` 最关键：

- 最终双发射率 6.0%。
- S1 accepted / IF accepts 也是 6.0%。
- S1 accepted 到 S1 commit 基本 100%。
- slot1 blocked 中 RAW 60.8%。
- slot1 不支持类型 32.9%，其中 load/store 占几乎全部。
- S0 MULDIV 只占 3.1% blocked。
- Not seq 只有 3.2%，分支误预测率只有 1.2%。

所以这份程序的低双发射率不是分支预测问题，也不是“除法器太慢直接造成 slot1 发不出”。M 扩展版本缩短了原来的软件除法/乘法控制流，剩下的动态流更像一串数据依赖 + load/use + 少量 MULDIV 长延迟，因此 slot1 很难找到可并行的 ALU/branch。

## 优化建议优先级

1. 保留并继续使用 IF-accept 级 slot1 blocker 计数。后续优化不要只看最终 `Dual-issue %`，要看 `S1 accepted / IF accepts` 和 blocked Pareto。

2. 优先研究 RAW。`src0/new_without_Mext/new_with_Mext` 都是 RAW 主导。硬件同周期解决 `slot0 -> slot1` RAW 很难，因为 slot1 需要在同一个 EX 周期使用 slot0 的结果。更现实的方向是：
   - 编译/汇编层面调度，把独立指令放到 slot1。
   - 改进 inst buffer，让被挡住的 slot1 有机会下周期作为 slot0 继续走。
   - 研究轻量 replay/hold 机制，但要小心时序和控制复杂度。

3. slot1 支持范围要按 PPA 谨慎扩展。统计显示不支持类型主要是 load/store：
   - slot1 store 可能是相对现实的第一步，但需要处理 store buffer、顺序提交、异常/flush、DCache 写端口或入队仲裁。
   - slot1 load 潜在收益更大，但硬件代价也明显更高，可能需要双 LSU 或 load queue/DCache 端口重构。
   - slot1 MULDIV 目前不建议优先做，`new_with_Mext` 中 S0 MULDIV 阻塞只有 3.1%。

4. 分支/前端优化适合 `current/src2/src0/new_without_Mext`，但不适合解释 `new_with_Mext`。下一步如果做前端，应进一步拆 `Not seq fetch`：
   - `if_bp_taken_out`
   - `id_bp_redirect_raw`
   - `frontend_branch_flush`
   - JAL/JALR/return 类控制流

5. 对 `src1/new_with_Mext`，load-use 和 DCache stall 是 CPI 的主要压力。这里可以继续看：
   - MEM-ready load-use 是否能旁路或少停一拍。
   - DCache miss/refill 路径是否能减少阻塞。
   - 程序访存局部性和数据布局。

## 本次结论

双发射率低不是因为双发射单元整体失效。`current` 能达到 60.6%，说明结构本身能工作。低双发射主要来自当前发射策略过保守且 slot1 支持范围窄：

- RAW 是最普遍的一号原因。
- slot1 不支持 load/store 是第二大结构性原因。
- 分支/前端只对部分程序是主因。
- M 扩展版本的低双发射率是预期现象：程序变快了，但剩余动态指令更串行、更依赖访存和 MULDIV。

下一步最值得做的是：保持这些计数器，先做一轮 `Not seq fetch` 细分和 RAW/slot1 unsupported 的热点 PC 采样，然后再决定是动前端、slot1 store，还是访存/load-use 路径。
