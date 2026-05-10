# 当前优化计划与设计契约

更新日期：2026-05-10

本文只记录仍会影响后续决策的优化方向、设计契约和已否决结论。长实验记录、一次性脚本输出和 Vivado 报告不放进仓库，默认放 `/tmp/` 或本地工作目录。

## 当前基线

- 当前实验分支：`perf/slot1-capability`，从 `master` 新开。
- RTL 当前架构：RV32I 五级流水 + 顺序双发射；slot0 全功能，slot1 支持 ALU 类指令和 V1 条件分支。
- IROM 容量不能变；当前前端问题更偏 IROM 地址/BRAM/IF 后级时序，不优先做通用 ICache。
- iverilog 回归入口：`bash 02_Design/sim/riscv_tests/run_all.sh`；这是 RTL 改动后的验证入口，不是熟悉工程时默认动作。
- Vivado timing 入口：`vivado -mode tcl -source 03_Timing_Analysis/run_vivado_flow.tcl -tclargs "$PWD" current 18`；只在时序相关改动或收敛检查时运行。

## 方向判断

从 biRISC-V 借鉴的前四点可以兼容到本工程，但应拆成两层推进：

- 第一层：扩大 slot1 可发射类型，同时保持后端共享和保守时序边界。
- 第二层：如果 slot1 继续扩展到 branch/LSU 以外，再考虑把现有特例 hazard 改成小型 scoreboard/`operands_ready`。

当前优先级：

1. `slot0 non-control + slot1 conditional branch`
2. `slot0 ALU + slot1 load/store`
3. 小型 `operands_ready`/scoreboard 化
4. 固定 bypass 点，限制 late repair 扩散

不先做重型软件评估，但不盲改。第一版只要求轻量证据：静态机会数或已有 profiling/COE 观察能说明方向不是冷路径即可。真正 RTL 改动后仍按影响范围做功能、前缀、性能和时序验证。

## V1 设计契约：Slot1 Conditional Branch

当前实现状态：最小功能版已落地在 `cpu_top.sv`，`riscv-tests` 65/65 功能回归通过。V1 暂不增加 slot1 branch predictor update，taken branch 通过 MEM replay 风格延迟 redirect 修正前端。

### 目标

允许以下同包发射：

```text
slot0: non-control, non-LSU
slot1: conditional branch
```

意图是利用当前 slot1 已有的译码、寄存器读、前递和 EX 级 ALU/比较资源，减少 tight loop / 分支密集代码里“slot1 位置是 branch 只能进入 inst_buf”的浪费。

### 非目标

- 不允许 slot1 JAL/JALR。
- 不允许 slot1 load/store。
- 不允许同拍两个 control 指令。
- 不把 slot1 branch redirect 接回当前 IROM 快路径。
- 不在第一版重构 branch_predictor 表结构、RAS 或 IF1/IF2。
- 不扩大 `MEM load ready -> S0 ordinary ALU repair` 到 branch/JALR/store/S1 consumer。

### 发射规则

第一版 slot1 可发射类型变为：

- 原有 ALU-type：R-type、I-ALU、LUI、AUIPC。
- 新增 conditional branch：B-type only。

slot1 branch 必须满足：

- slot0 不是 branch/JAL/JALR。
- slot0 不是 load/store。
- 同包 RAW 仍禁止：slot1 branch 的 rs1/rs2 不能依赖 slot0 rd。
- slot1 branch 只在顺序取指包中发射；已有 flush、L0 taken、NLP redirect 或 held 异常路径不新增快速发射规则。

保守第一版可以把 `slot0 load/store + slot1 branch` 全部禁止。这样 slot1 branch redirect 不需要和 DCache miss/refill/flush 形成复杂组合。

### 数据与比较

slot1 branch 比较在 EX 级完成，使用 `ex_s1_rs1_data` / `ex_s1_rs2_data` 或等价的已前递操作数。

约束：

- branch target 优先复用现有 S1 ALU 路径：B-type 解码下 `id_s1_alu_src1=PC`、`id_s1_alu_src2=imm`，EX 的 `alu_s1_result` 可作为 `PC+imm` target。
- fallthrough 使用现有 `ex_s1_pc_plus_4`。
- 不把 S1_EX 结果直接喂回 ID 级 branch compare。
- 对依赖尚不可用 load 的 slot1 branch，沿用现有 `forwarding.sv` 的 load-use stall。
- 若 slot1 branch 需要比较 `<`/`>=`，优先复用 `branch_cond_taken` 等价逻辑或抽出共享组合函数，避免复制出不一致的条件编码。

### Redirect 策略

slot1 branch redirect 允许比 slot0 EX fast redirect 晚一拍。

建议第一版路径：

1. EX 级计算 slot1 branch actual taken 和 target/fallthrough。
2. 打入 EX/MEM 或新增轻量寄存器。
3. 下一拍用 MEM replay 风格 redirect 前端。

优先级：

1. slot0 branch/JAL/JALR redirect 最高。
2. slot0 redirect 同拍杀掉 slot1 branch，slot1 不更新预测器、不写任何副作用。
3. slot1 branch redirect 只在 slot0 没有 redirect、且 slot1 branch valid 时生效。

slot1 branch redirect 不进入 `ex_redirect_to_target/fallthrough -> irom_addr` 当拍快路径，避免恢复长的 EX compare/target -> IROM 地址路径。

### Flush 范围

slot1 branch 发生 redirect 时：

- 杀 IF/ID 中更年轻的指令。
- 杀 ID/EX 中更年轻的指令。
- 清空 `inst_buf`。
- 不杀 slot0 本身，也不杀已经在 slot1 branch 之前提交顺序保证成立的老指令。

slot0 redirect 发生时：

- 现有 `ex_mem_reg_s1.s1_flush = branch_flush | mem_branch_flush` 语义必须继续保证 slot1 不漏进 MEM。
- 如果 slot1 branch 与 slot0 同包，slot0 redirect 优先，slot1 branch 被当作错误路径杀掉。

### 预测器更新

第一版可以不让 IF L0 预测 slot1 branch 的方向；slot1 branch 在 EX/MEM 发现 taken 后 redirect，not-taken 不 redirect。

更新策略：

- slot1 branch 可以更新 BHT/PHT/selector/BTB，但必须 valid gating。
- slot0 redirect 或 flush 杀掉的 slot1 branch 不能更新预测器。
- 第一版若为了降低接口风险，也可以暂不更新 slot1 branch 预测器；这会牺牲后续同 PC 的预测收益，但功能正确。若这样做，文档和 perf 结论必须明确。

更稳妥的第一版：增加 slot1 branch 更新通道前，先只做功能 redirect；确认功能后再决定是否复用/仲裁 `branch_predictor` EX update 口。

### 写回与计数器

slot1 branch 不写 rd，`reg_write_en=0`，`wb_sel` 不产生可见副作用。

`dual_issue_count` 当前按 `wb_s1_valid` 计数。slot1 branch 若作为有效提交指令进入 WB，可以计入双发射提交数；若后续希望区分 ALU/branch 双发，应在 perf monitor 中另加分类，不改变 MMIO 计数器语义。

### 需要改动的 RTL 区域

预计涉及：

- `cpu_top.sv`：slot1 发射判定、raw/shifted/held pair 规则、slot1 branch compare/target/redirect、flush 优先级。
- `id_ex_reg_s1.sv`：branch metadata 已基本传递；优先复用 `alu_s1_result` 作为 target，避免新增 imm/target 寄存器。
- `ex_mem_reg_s1.sv`：必要时承载 slot1 branch redirect metadata。
- `branch_predictor.sv`：若启用 slot1 branch update，需要新增或仲裁更新口。
- `perf_monitor.sv`：可选，增加 slot1 branch 发射/提交统计。
- `test_coverage.md` 和新增/更新测试：覆盖 slot1 branch not-taken/taken、slot0 flush 优先级、load-use stall、inst_buf 清空。

## 后续候选：Slot1 LSU

slot1 load/store 方向兼容，但风险高于 slot1 branch。第一版 branch 稳定前不动 LSU。

未来契约要点：

- 同拍最多一个 DCache 请求。
- 禁止 `slot0 load/store + slot1 load/store`。
- slot1 load 写回必须接入 load-use、forwarding、WB 选择和 WAW 优先级。
- slot1 store data/address 的前递和 flush 要单独收敛，不能复用 S0 的 late repair。

## 后续候选：Operands Ready

只有当 slot1 branch/LSU 让现有 hazard 特例明显膨胀时，才引入小型 ready/busy 表达。

目标不是完整乱序 scoreboard，而是把发射规则整理成：

```text
pair_struct_ok && operands_ready
```

其中 `operands_ready` 只表达当前 in-order dual-issue 需要的 RAW/load/late-result 可用性。

## 已否决或低优先级方向

- Fetch queue / 伪前端切分：官方 4 项仅 `3645 -> 3642 cycles`，但 post-route `WNS +0.049ns -> -1.015ns`，TNS `-615.607ns`，1192 个 failing endpoints。
- 零周期 `ID actual redirect -> IROM`：有 CPI 收益，但 FPGA 时序代价过高，不直接恢复。
- `load -> store` MEM-ready 修复：对 `src2` 约 `-0.017 CPI`，但 Vivado 200MHz 报负 slack，已撤回。
- BP 容量/GHR 扫描：GHR 8 -> 12 平均约 `-0.007 CPI`，不优先扩大表项。
- `zero_eqne_raw` 子集：小测试 `3645 -> 3557 cycles`，收益偏小且完整 COE suite 未闭环；不作为下一轮主线。
- 大型流水线切分：只有成体系做到 `IF1/IF2 + EX branch compare + registered redirect + ID/control retime + memory/control retime` 才可能有价值；目标应设为 `>=225MHz`，优先 `>=235MHz`。

## 当前下一步

1. 评估是否给 `branch_predictor` 增加 slot1 update 仲裁；若不做，保留 V1 功能正确、预测收益欠缺的结论。
2. 进入 slot1 LSU 前，先列出 load/store 双发对 DCache、forwarding、load-use 和 WAW 优先级的接口改动清单。
