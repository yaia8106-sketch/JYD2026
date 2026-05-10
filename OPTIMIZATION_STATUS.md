# 当前优化状态

更新日期：2026-05-10

## 当前基线

- 当前工作分支：`master`，本地相对 `origin/master` 领先 8 个提交，尚未 push。
- RTL 主线保持干净；后续性能 RTL 实验应从 `master` 新开分支。
- 指令集仍按赛题约束维持 **RV32I**，不要把 `biRISC-V` 的 RV32IM/CoreMark 数字直接作为对标。
- IROM 容量不能变；当前问题更偏向 IROM 读取/前端路径时序，而不是程序从外部存储取指，所以不要优先做通用 ICache。
- `stage_timing_report.txt` 是 Vivado 生成物，已从 git 跟踪中移除；需要做时序验证时运行：

```bash
vivado -mode tcl -source 03_Timing_Analysis/run_vivado_flow.tcl -tclargs "$PWD" current 18
```

- iverilog 回归入口：`bash 02_Design/sim/riscv_tests/run_all.sh`，当前测试集覆盖 64 个测试；这是 RTL 改动后的验证入口，不是熟悉工程时的默认动作。

## 从 biRISC-V 学到的架构点

### 1. slot1 不必复制完整后端

`biRISC-V` 的资源策略是混合式：

- ALU/branch exec：复制两套，slot0/slot1 各一套。
- LSU：一套共享，slot1 L/S 通过 mux 送入同一个 LSU；因此每拍最多一个 L/S。
- MUL：一套共享，slot0/slot1 通过 mux 送入。
- DIV/CSR：只给 slot0。

对本工程最有价值的不是“做双 LSU”，而是让 slot1 获得更多能力，同时共享昂贵后端：

- `slot0 ALU + slot1 branch`
- `slot0 ALU + slot1 load/store`
- 禁止 `slot0 branch + slot1 branch`
- 禁止 `slot0 load/store + slot1 load/store`

### 2. slot1 branch 的关键是限制组合，而不是处理双跳转仲裁

`biRISC-V` 允许 slot1 branch，但 issue 规则保证 slot0 同拍不是 branch。因此它基本不需要复杂的双 branch redirect 仲裁。

若本工程实现 slot1 branch，第一版只考虑：

```text
slot0: non-control, non-LSU preferred
slot1: conditional branch
```

设计契约必须包含：

- 同拍最多一个有效 branch。
- slot0 control 指令禁止和 slot1 branch 同发。
- slot1 branch 的 redirect 可以接受 +1 cycle penalty，不要接回 IROM 当拍快路径。
- slot1 branch 预测器更新必须能被 slot0 flush/exception 杀掉。
- slot1 branch target/compare 在 EX 或寄存后的阶段完成，避免恢复 `ID actual redirect -> IROM` 长路径。

### 3. scoreboard + bypass 的价值是控制复杂度

`biRISC-V` 不是在 issue 时记录“以后从哪里前递”，而是在 issue 当拍完成 operand collection：

```text
regfile / WB / E2 / E1 中谁有最新可用值，就直接 mux 进 operand。
如果结果还不可用，scoreboard 标记 rd busy，消费者不发射，下一拍再判断。
```

本工程当前没有统一 scoreboard，而是：

- 当前 pair RAW 检查阻止 slot0 -> slot1 相关同发。
- `forwarding.sv` 显式列出 S1_EX/S0_EX/S1_MEM/S0_MEM/S1_WB/S0_WB 前递。
- `load_use_hazard`、`jalr_ex_wait_hazard`、`branch_s1_ex_wait_hazard` 等特例决定 ID stall。

只要 slot1 仍然很窄，这种做法可以维持。若扩展 slot1 branch/LSU，就应考虑把规则改成：

```text
pair_struct_ok && operands_ready
```

其中 `operands_ready` 由一个小型 ready/busy 机制表达，而不是继续堆特例。

### 4. 固定 bypass 点换时序稳定

`biRISC-V` 只从固定阶段取前递：

```text
E1 / E2 / WB / regfile
```

若 load 结果尚未到可用 bypass 点，consumer 不 issue；若 load 在 E2 且 data ready，则 issue 阶段直接取 E2 bypass。

本工程已有较激进的 `MEM load ready -> S0 ordinary ALU repair` 特例，能省少量 load-use 周期，但会引入更晚的数据路径。该思路不要扩大到 branch/JALR/store/S1 consumer，除非 Vivado timing 先证明可收敛。

### 5. IROM 读延迟问题不是 ICache 首先解决

IROM 容量不变且取指源仍是片上 BRAM 时，通用 ICache 会增加 tag/valid/refill/flush 复杂度，通常不能直接缩短 IROM 读路径。

下一轮前端优化应优先考虑：

- IROM 地址选择和 bank 地址路径继续重定时。
- IF1/IF2 切分：IF1 选择并寄存 IROM 地址，IF2 读 IROM 并寄存 instruction/prediction snapshot。
- 若引入 IF1/IF2，必须接受并量化 branch redirect penalty 增量，目标仍按程序运行时间 `cycles * clock_period` 判断。

## 已否决或低优先级方向

- Fetch queue / 伪前端切分：官方 4 项仅 `3645 -> 3642 cycles`，但 post-route `WNS +0.049ns -> -1.015ns`，TNS `-615.607ns`，1192 个 failing endpoints。
- 零周期 `ID actual redirect -> IROM`：有 CPI 收益，但 FPGA 时序代价过高，不要直接恢复。
- `load -> store` MEM-ready 修复：对 `src2` 约 `-0.017 CPI`，但 Vivado 200MHz 报负 slack，已撤回。
- BP 容量/GHR 扫描：GHR 8 -> 12 平均约 `-0.007 CPI`，不值得优先扩大表项。
- `zero_eqne_raw` 子集：小测试 `3645 -> 3557 cycles`（约 `2.4%`），收益偏小且完整 COE suite 未闭环；不作为下一轮主线。
- 大型流水线切分：只有成体系做到 `IF1/IF2 + EX branch compare + registered redirect + ID/control retime + memory/control retime` 才可能有价值；目标应设为 `>=225MHz`，优先 `>=235MHz`。

## 下一步建议

1. 下一轮候选评估需要先明确是否跑统计/仿真脚本，重点看：
   - `slot0 non-control + slot1 branch`
   - `slot0 ALU + slot1 load/store`
   - 相关 RAW/WAW/structural conflict 分布
2. 若 slot1 branch 更热：先写 slot1 branch 设计契约，不直接写 RTL。
3. 若 slot1 LSU 更热：先写共享 LSU mux 设计契约，保证每拍最多一个 DCache 请求。
4. 做时序相关改动前，再看 Vivado 当前 top critical paths，确认 IROM 慢点属于地址选择、BRAM 输出还是 IF/ID 后级 decode。
5. 任何 RTL 改动后按顺序验证：
   - `bash 02_Design/sim/riscv_tests/run_all.sh`
   - `run_coe_diff.sh` 长前缀对比
   - Vivado timing flow
