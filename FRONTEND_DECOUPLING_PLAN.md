# Frontend Decoupling Plan

更新日期：2026-05-11

本文记录从 biRISC-V 前端/发射架构中提炼出的可迁移设计点，以及本工程若要支持更自然的 slot1 branch/LSU/predictor 扩展，应如何渐进改造。本文是设计契约，不记录一次性实验输出。

## 背景

当前分支 `perf/slot1-capability` 已完成 V1 slot1 conditional branch：

- `slot0 non-control, non-LSU + slot1 conditional branch` 可以同包发射。
- slot1 branch taken 通过 registered/MEM replay 风格 redirect 修正前端。
- V1 不增加 slot1 branch predictor update。

V1 的限制不是 slot1 ALU 不能计算 branch target，而是当前前端、buffer、issue 和 predictor metadata 还没有把 slot1 当成一个可独立消费的指令流位置来建模。继续直接给 slot1 加预测器更新或 PC+4 预测，容易把时序和正确性问题混在一起。

## biRISC-V 参考结论

biRISC-V 的关键不是某个单独模块，而是一组配套契约：

- `fetch PC` 和 `expected PC` 分离。
- frontend 按预测流取 64-bit bundle。
- issue 按 `expected PC` 消费 FIFO 中的指令。
- fetch word 不固定等于 issue slot；`fetch1` 可以 later become primary。
- fetch FIFO 以 64-bit bundle 为 entry，但 lower/upper word 有独立 valid。
- `single_issue` / `dual_issue` 推进 `expected PC`。
- `fetch0_accept` / `fetch1_accept` 只表示 FIFO 哪个 word 被消费，不等同于发射条数。
- BTB 在一个 bundle 内先查 `PC`，若 miss 再查 `PC+4`，以保持最老 control-flow 优先。

这种结构允许 frontend 先预测 upper branch target，而不需要知道该 upper branch 当拍是否能作为 secondary issue。若 upper branch 暂时不能发射，它保留在 FIFO 中，后续按 `expected PC` 作为 primary 发射。

## 当前架构对应关系

本工程当前没有独立、显式的 issue-side `expected PC`。相关职责分散在以下状态中：

- `irom_addr`：下一次 IROM 取指地址，近似 frontend fetch PC。
- `pc`：当前 IROM/fetch window 基准 PC。
- `pc_plus4` / `pc_plus8` / `pc_plus12`：为顺序推进和预测 target 后继地址预计算的 PC 状态。
- `if_pc_live`：当前送入 IF/ID 的 slot0 PC，可能来自 `pc`、`inst_buf_pc` 或 `pc_plus4`。
- `inst_buf` / `inst_buf_pc`：保存未发射的 slot1-like leftover instruction。
- `skip_inst0_valid`：处理跳过当前 window lower word 的特殊路径。
- `irom_held_valid`：stall 时保存 IROM 输出和 BP metadata，避免 BRAM 输出变化破坏 IF/ID 输入。

这些结构已经能覆盖若干 leftover/stall 场景，但它们不是完整 fetch FIFO：

- 没有 per-word FIFO entry 模型。
- 没有统一的 issue-side expected PC 匹配。
- `fetch1` 不能自然跨周期成为一个普通 primary candidate。
- slot1 BP metadata 只在部分路径中作为 buffered snapshot 存在，尚未形成完整生命周期。

## 当前问题

### Frontend 与 Issue 仍然耦合

当前顺序取指推进仍依赖 `predict_dual` / `can_dual` 体系。即使已做了预计算和 held path 优化，架构含义仍偏向：

```text
前端需要预测本轮会消费几条，再决定下一取指窗口
```

这和 biRISC-V 的：

```text
frontend 按预测流取 bundle，issue 按 expected PC 消费
```

不是同一类契约。

### `inst_buf` 承担了过多隐式职责

`inst_buf` 当前既像 leftover slot1 buffer，又参与 shifted pair、BP snapshot、skip path 和 held path 的组合。它能解决局部问题，但扩展到 slot1 branch prediction 或 slot1 LSU 时，状态语义会继续膨胀。

### Slot1 BP Metadata 接不住

slot1 branch 若要正确训练 BTB/BHT/PHT/selector，需要把该指令自己的预测 snapshot 严格带到 EX。当前 IF/ID -> ID/EX 主要服务 slot0 snapshot，slot1 的 raw、shifted、held、inst_buf-before-window 路径没有统一的 per-instruction metadata 契约。

### Upper Branch Prediction 缺少承载结构

即使增加 `PC+4` BTB 查询，若 upper branch 不能当拍发射，也需要保证它仍然作为正确路径指令保留并 later issue。当前 `inst_buf` 可以覆盖部分单条 leftover，但不是完整的 per-word valid FIFO，因此不宜先改 BTB。

## 渐进改造方案

### Phase 0：设计冻结与文档化

当前阶段只固化设计，不改 RTL：

- 明确 `fetch PC`、`expected PC`、fetch word、issue slot 的定义。
- 明确当前 `inst_buf` 与 biRISC-V fetch FIFO 的差异。
- 明确 V1 slot1 branch predictor update 延后是架构承载问题，不是单纯 BTB 写口问题。

### Phase 1：显式化 expected PC

目标是先建立 issue/dispatch 侧的真实消费 PC 概念：

```text
发 0 条：expected_pc 保持
发 1 条：expected_pc += 4
发 2 条：expected_pc += 8
redirect：expected_pc = redirect target
```

第一版不要求立即替换所有前端 PC 逻辑，但应能在文档和仿真观测中回答：

- 当前周期哪条指令是 expected PC 对应的 primary candidate？
- 若 slot1 未发射，它后续如何成为 expected PC？
- branch redirect 后 expected PC 与 IROM fetch PC 如何重新对齐？

### Phase 2：将 `inst_buf` 演进为小型 fetch buffer

目标不是直接照搬 biRISC-V，而是把现有 leftover 状态改造成更清晰的 per-word buffer：

每个 buffered word 至少携带：

```text
valid
pc
instr
bp metadata
basic decode class
```

第一版容量可以很小，例如仅覆盖当前 64-bit window 的 lower/upper word 和一个后继 word。重点是语义清晰，而不是先追求深 FIFO。

### Phase 3：重构 issue 选择

把发射选择整理成：

```text
1. 用 expected_pc 找 primary candidate
2. 若 primary 来自 lower word，尝试选择 next word 作为 secondary
3. 检查结构组合
4. 检查数据冒险 / operands_ready
5. 生成 consume mask 和 single/dual issue
```

这一步完成后，`fetch word`、`issue slot`、`execution pipe` 三个概念应解耦。

### Phase 4：Slot1 BP Metadata 与 Upper Prediction

只有在 Phase 1-3 的承载结构稳定后，再考虑：

- 给 upper/slot1 指令携带完整 BP snapshot。
- 为 slot1 branch 增加 predictor update 仲裁。
- 增加 `PC+4` 预测能力。

`PC+4` 预测可以有多个候选实现：

- 复制当前 128-entry BTB 读表，提供真实双读。
- 增加小型 upper/slot1 sidecar BTB。
- 先保持单读，等 upper 指令 later primary 时再预测。
- 重新设计 banked BTB。

当前不选择具体 BTB 方案。

## 非目标

- 不直接重写整个前端。
- 不立即把当前 BTB 改成 biRISC-V 风格 CAM。
- 不立即增加 slot1 branch predictor update。
- 不立即引入完整 scoreboard。
- 不改变 IROM 容量。
- 不把 slot1 branch redirect 接入当前 IROM 当拍快路径。

## 验证要求

任何进入 RTL 的阶段都至少需要：

- focused functional test：覆盖 single issue、dual issue、buffer leftover、branch taken/not-taken。
- full `riscv-tests` 回归。
- 若触及 IROM address、BP lookup、IF/ID allowin 或 redirect priority，必须跑 Vivado timing。
- 若改变 BP 行为，需要增加前缀/随机化测试，覆盖 wrong-path flush 与 stale fetch response。

## 当前建议

下一步不直接改 BTB，也不直接做 slot1 BP update。优先把 Phase 1 设计细化成 RTL 改动清单：

1. 列出当前所有 PC 状态及其职责。
2. 定义 `expected_pc` 的更新优先级。
3. 定义 primary/secondary candidate 的选择规则。
4. 判断 `inst_buf` 是否先扩展为 2-word buffer，还是先只增加观测/断言。

## Phase 1 Detailed Design

Phase 1 的目标是先把 issue/dispatch 侧的真实消费 PC 显式化。第一版可以只做观测/断言，不改变现有取指、发射、flush 行为。

### 当前 PC 状态职责

| 状态 | 当前职责 | Phase 1 视角 |
| --- | --- | --- |
| `irom_addr` | 下一次送入 IROM 的取指地址 | frontend fetch PC |
| `pc` | 当前 IROM/fetch window 的基准 PC | 当前 fetch window base |
| `pc_plus4` / `pc_plus8` / `pc_plus12` | 预计算顺序后继地址，避免 IROM 路径上放大加法器 | fetch PC 后继缓存 |
| `if_pc_live` | 当前送入 IF/ID 的 primary 指令 PC | 当前 primary candidate PC |
| `if_pc_out` | stall hold 后的 IF/ID primary PC | 实际送入 IF/ID 的 primary PC |
| `id_pc` / `ex_pc` | slot0 指令在后端流水中的 PC | 已发射 primary 指令 PC |
| `id_s1_pc` / `ex_s1_pc` | slot1 指令在后端流水中的 PC | 已发射 secondary 指令 PC |
| `inst_buf_pc` | single issue 后保留的 leftover 指令 PC | buffered word PC |
| `buf_bp_pc` | buffered slot 的 predictor lookup PC | buffered word BP metadata key |
| `skip_inst0_valid` | 下一轮从当前 window upper word 开始 | fetch window lower word 已被跳过 |

Phase 1 不要求删除这些状态。它只新增一个概念性基准：

```text
expected_pc = issue/dispatch 下一条按程序顺序应该消费的 PC
```

### `expected_pc` 更新优先级

`expected_pc` 应与发射成功事件绑定，而不是与 IROM 下一取指地址绑定。建议优先级：

1. Reset：初始化到 reset vector。
2. 异常 / 中断 / CSR redirect：设置为 architectural redirect target。
3. slot0 branch/JAL/JALR redirect：设置为实际 target 或 fallthrough 修正地址。
4. slot1 branch redirect：设置为 slot1 实际 target。
5. pipeline flush / replay：设置为 replay target。
6. 本周期成功 dual issue：`expected_pc += 8`。
7. 本周期成功 single issue：`expected_pc += 4`。
8. 本周期没有成功 issue：保持不变。

第一版若只做观测/断言，可以不把 `expected_pc` 反接到取指路径。它只用于验证：

```text
if_pc_out == expected_pc
```

或在存在 `inst_buf` / `skip_inst0` 时验证当前 primary candidate 是否等于 `expected_pc`。

### Primary Candidate 选择规则

Phase 1 先不改变现有 mux，只把规则显式化：

1. 若存在有效 buffered word，且 `inst_buf_pc == expected_pc`，则 buffered word 是 primary candidate。
2. 否则若 `skip_inst0_valid`，且当前 window upper PC 等于 `expected_pc`，则 current upper word 是 primary candidate。
3. 否则若当前 window lower PC 等于 `expected_pc`，则 current lower word 是 primary candidate。
4. 否则当前前端供给与 issue 消费流不一致，应视为需要 redirect/flush 的状态。

该规则对应 biRISC-V 的：

```text
fetch0.pc == expected_pc -> fetch0 primary, fetch1 secondary candidate
fetch1.pc == expected_pc -> fetch1 primary, no same-entry secondary
neither matches          -> frontend stream mismatch
```

但 Phase 1 暂不要求当前实现完全具备 biRISC-V 的 `fetch1 later primary` 能力，只先明确我们希望最终达到的语义。

### Secondary Candidate 选择规则

secondary candidate 必须是 primary 后的下一条顺序指令：

```text
secondary.pc == primary.pc + 4
```

候选来源按当前架构可分为：

1. raw pair：primary 来自 current lower，secondary 来自 current upper。
2. shifted pair：primary 来自 `inst_buf`，secondary 来自 current lower。
3. held pair：stall 期间保存的 primary/secondary snapshot。

Phase 1 只记录候选，不改变现有 `raw_pair_can_dual` / `shifted_pair_can_dual` / `held_can_dual_r` 判定。

### Consume Mask 规则

需要区分两个概念：

```text
issue_count：本周期成功发射几条顺序指令
consume_mask：本周期消费了哪些前端/buffer word
```

建议定义：

- `issue_count = 0`：没有发射，`expected_pc` 保持。
- `issue_count = 1`：发射 primary，`expected_pc += 4`。
- `issue_count = 2`：发射 primary + secondary，`expected_pc += 8`。

当前实现可先映射为：

- dual issue 成功：consume primary + secondary。
- single issue 且 slot1 leftover 进入 `inst_buf`：consume primary，buffer secondary。
- single issue 且 primary 来自 `inst_buf`：consume buffered word。
- flush/redirect：consume mask 不推进 `expected_pc`，由 redirect target 覆盖。

这一层文档化后，后续才能安全判断 `fetch0_accept` / `fetch1_accept` / `inst_buf_valid` 是否需要统一成 per-word consume mask。

### 与现有 `inst_buf` 的兼容策略

Phase 1 不要求立刻把 `inst_buf` 改成 FIFO。先把它定义成单 entry buffered word：

```text
inst_buf_valid
inst_buf_pc
inst_buf_instr
inst_buf_bp_metadata
```

它只能表达一个 leftover word。若后续要支持更自然的 upper branch prediction 或跨 window dual issue，需要升级为小型 fetch buffer。

### 暂不改变的行为

Phase 1 不改变：

- IROM 地址优先级。
- `predict_dual` / `can_dual` 的现有取指推进方式。
- `inst_buf` 的容量。
- branch predictor 读写结构。
- slot1 branch redirect 策略。
- slot1 branch predictor update 策略。

### RTL 影响区域

若进入 RTL，预计第一版只涉及：

- `cpu_top.sv`：新增 `expected_pc` 观测寄存器和更新逻辑。
- `cpu_top.sv`：新增 candidate PC match / mismatch debug wire 或 assertion。
- `00_AI_Rules/architecture.md`：记录 frontend/issue 解耦术语。
- `test_coverage.md`：增加 expected-PC 观测覆盖项。

第一版不应修改：

- `branch_predictor.sv`
- `pc_reg.sv`
- IROM bank address MUX
- `id_ex_reg_s1.sv` / `ex_mem_reg_s1.sv`

### 风险点

- `expected_pc` 初始化必须与 reset PC 约定一致。
- flush、EX fast redirect、MEM replay、ID/NLP redirect 的优先级需要和现有前端完全一致，否则观测会误报。
- slot1 branch redirect 晚一拍，`expected_pc` 的观测更新必须能表达这个 registered redirect。
- 当前 `predict_dual` 是预测性推进，不一定等同于真实 issue count；Phase 1 不能用它直接更新 architectural `expected_pc`，只能用真实发射/流水 valid 事件。
- 若只做观测，assertion 应先以调试开关保护，避免在已知过渡状态下阻塞正常仿真。

### Phase 1 出口条件

进入 Phase 2 前，需要回答：

1. 当前所有正常路径下，primary candidate PC 是否能与 `expected_pc` 对齐。
2. `inst_buf` leftover 路径是否能被单 entry buffered word 模型完整解释。
3. slot1 branch redirect 是否能用 `expected_pc` 更新优先级表达。
4. 若不能表达，是否需要先扩展为 2-word fetch buffer。
