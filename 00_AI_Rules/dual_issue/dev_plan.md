# 双发射开发计划（Design-Verify Loop）

> **目标读者**：接手本项目的 AI。请严格按 Phase 顺序执行，每个 Phase 完成验证后再进入下一个。
>
> **开发模式**：用户为 vibe coding，不看代码，只参与方案决策。AI 负责全部 RTL 编写。
>
> **核心原则**：每个 Phase 改完后，CPU 必须通过全部已有测试（回归），同时用专项测试验证新功能。
>
> **架构决策**：见 `architecture.md`（D1-D13）。所有 RTL 实现必须与这些决策一致。

---

## Phase 0：IROM 加宽（不改功能）

> 2026-05-03 执行说明：按用户要求先不修改 Vivado 工程/IP。本轮完成 RTL 64-bit IROM 数据口和 `riscv_tests` 仿真模型适配；Vivado IROM IP 重配留到 FPGA/工程阶段。

### 目标
IROM 从 32-bit 加宽到 64-bit 输出，但仍只使用低 32 位（inst0），CPU 行为与单发射完全一致。

### 改动清单
- [ ] IROM IP 重新配置为 64-bit data width
- [ ] `cpu_top.sv`：取 `irom_data[31:0]` 作为 inst0，忽略 `irom_data[63:32]`
- [ ] `irom_addr` 索引方式适配 64-bit 宽度（地址可能需要右移 1 位）
- [ ] PC 步进仍为 +4，其余逻辑不变

### 验证标准
- [ ] **回归**：43/43 riscv-tests PASS
- [ ] **FPGA**（可选）：src0/src1/src2 通过

### 风险提示
- IROM 地址位宽变化可能影响 COE 文件格式，需确认
- 确保 BRAM 配置后 Clk-to-Q 延迟不变（不启用 output register）

---

## Phase 1：取两条，只发一条

> 2026-05-03 执行结果：完成 RTL/仿真路径，43/43 `riscv_tests` PASS。为避免预测 taken 时把 fall-through 的 slot1 缓冲到 target PC，本阶段只在顺序取指路径填充指令缓冲。

### 目标
取指取 2 条指令，指令缓冲正常工作，双译码器跑起来，Slot 1 级间寄存器链存在但 `s1_valid` 恒 0。`can_dual_issue` 硬编码为 0。

### 改动清单
- [x] 指令缓冲（32-bit reg + valid bit），flush 时清零
- [x] inst0 来源 MUX（IROM 低 32 位 vs 缓冲）
- [x] PC 步进逻辑实现（+4/+8/bp_target/flush_target），但因不双发，实际永远 +4
- [x] Decoder 1（复用 Decoder 0 的模块，inst1 输入）
- [x] Slot 1 级间寄存器链空壳：`id_ex_reg_s1.sv`、`ex_mem_reg_s1.sv`、`mem_wb_reg_s1.sv`
  - `s1_valid` 恒为 0，数据通路连线但不产生副作用
- [x] `if_id_reg.sv` 扩展：传递 `inst1` 和 `s1_valid`

### 验证标准
- [x] **回归**：43/43 riscv-tests PASS
- [x] 行为必须与 Phase 0 完全一致（Slot 1 不参与执行）

### 风险提示
- 指令缓冲的填充/消耗逻辑容易出 off-by-one 错误
- 确保 Slot 1 寄存器链的 valid=0 不会干扰 allowin 链（`ready_go` 公式：`s0_rg & (s1_rg | !s1_valid)`，s1_valid=0 时退化为 `s0_rg`）

---

## Phase 2：数据通路就位（仍不双发）

> 2026-05-03 执行结果：完成 RTL/仿真路径，43/43 `riscv_tests` PASS。Slot1 数据通路已经贯通但 valid 仍为 0；转发逻辑改为显式优先级 MUX，避免 Icarus 对函数引用模块级信号时产生 X。

### 目标
寄存器堆 4R2W、前递 7 选 1、WB 双写回全部就位，但 `can_dual_issue` 仍为 0。

### 改动清单
- [x] `regfile.sv`：2R1W → 4R2W（加 2 个读端口 + 1 个写端口）
  - 写端口 WAW 优先级：Slot 1 > Slot 0（目前 Slot 1 不写，不生效）
- [x] `forwarding.sv`：4 选 1 → 7 选 1（S1_EX > S0_EX > S1_MEM > S0_MEM > S1_WB > S0_WB > RF）
  - 目前 Slot 1 各级 valid=0，新增匹配永远不命中
  - 4 个操作数各一套 MUX（inst0_rs1, inst0_rs2, inst1_rs1, inst1_rs2）
- [x] Slot 1 ALU（复用 `alu.sv` 模块，实例名 `u_alu_s1`）
- [x] WB 双写回通路连线（Slot 1 `wb_valid` = 0，不实际写入）
- [x] Load-use 检测扩展到 4 个源操作数

### 验证标准
- [x] **回归**：43/43 riscv-tests PASS
- [x] 行为必须与 Phase 1 完全一致

### 风险提示
- 前递扩展最容易引入 bug，重点关注优先级是否正确
- regfile 新增端口后确认 Vivado 综合无 latch warning

---

## Phase 3：开启双发射 🎯

> 2026-05-03 执行结果：完成 RTL/仿真路径，49/49 `riscv_tests` PASS。旧 43 个回归全部通过，新增 6 个 Phase3 专项测试覆盖双发、RAW 拦截、分支单发、WAW、load-use 与指令缓冲。计数器地址为 `0x8020_0060`，统计已提交的 Slot1 指令，避免错误路径发射污染读数。

### 目标
启用 `can_dual_issue`，CPU 真正开始双发射执行。新增性能计数器可观测双发射行为。

### 改动清单
- [x] 发射判断逻辑（D4 约束）：
  ```
  can_dual_issue = inst1_is_alu_type
                 & no_RAW(inst1, inst0)
                 & pc[2] == 0
                 & inst0_valid & inst1_valid
                 & !inst0_is_branch
  ```
- [x] `can_dual_issue` 驱动：
  - `s1_valid` 写入 ID/EX Slot 1 寄存器
  - PC 步进选择 +4 或 +8
  - 指令缓冲填充逻辑（单发时暂存 inst1）
- [x] **新增双发射计数器**（MMIO 寄存器）：
  - 地址：在 MMIO 地址空间分配一个只读寄存器
  - 每次 Slot1 指令提交时 +1
  - 软件可通过 Load 读取计数值
  - 用于客观验证双发射是否真正生效

### 验证标准
- [x] **回归**：43/43 riscv-tests PASS
- [x] **专项测试**（新增，放在 riscv-tests 目录）：

| 测试文件 | 场景 | 验证点 |
|---------|------|--------|
| `dual_alu.S` | 连续 ALU+ALU 对（无 RAW） | 结果正确 + 双发射计数器递增 |
| `raw_block.S` | inst1 的 rs = inst0 的 rd | 结果正确 + 确认退化单发（计数器不增） |
| `branch_single.S` | Branch + ALU 对 | 分支正确跳转 + 不双发 |
| `waw.S` | inst0 和 inst1 写同一个 rd | inst1 的值胜出 |
| `loaduse_dual.S` | Load 后跟无关 ALU+ALU | stall 正确 + 后续可双发 |
| `inst_buffer.S` | 单发后 inst1 → 缓冲 → 下拍作为 inst0 | 结果正确 + 不丢指令 |

### 风险提示
- 这是功能复杂度最高的 Phase，建议每个专项测试逐个调通
- 指令缓冲 + PC 步进 + 发射判断三者耦合紧密，是 bug 高发区
- 如果回归测试失败，优先怀疑前递优先级和 load-use stall 逻辑

---

## Phase 4：综合 + FPGA 上板

> 2026-05-04 当前进度：Phase4 Vivado 路径已切换为两个 32-bit slot IROM bank（保留 `IROMEven32`/`IROMOdd32` IP 名称以减少工程 churn；RTL 实例名为 `u_irom_slot0/u_irom_slot1`），由 Tcl 自动把 `irom.coe` 生成为 `irom_slot0.coe`/`irom_slot1.coe`。slot0 保存 `word[i]`，slot1 保存 `word[i+1]`，两个 bank 共享同一个 word 地址，去掉 even/odd 方案中 odd PC 需要的 `+1` 地址进位链。`riscv_tests` 回归 `60/60 PASS`。Vivado `check current 18` 可跑完 synthesis/place/route，综合和实现 DRC 已无 IROM 组合环；200MHz timing 尚未闭合，当前 routed WNS = `-0.252ns`，剩余唯一架构级 FAIL 为 `IROM(BRAM) -> IROM(BRAM)`。

### 目标
时序收敛 + FPGA 验证 + 性能实测。

### 改动清单
- [x] Vivado 综合，分析时序报告
- [ ] 根据关键路径优化（已尝试 PC+4/+8/+12 预计算、slot IROM、保守 RAW；仍需继续收敛）
- [ ] FPGA 烧录

### 验证标准
- [ ] 时序收敛 ≥ 200MHz（WNS ≥ 0；当前 slot IROM WNS = `-0.252ns`）
- [ ] FPGA src0/src1/src2 全通过
- [ ] CPI 对比单发射有改善（通过执行时间或计数器对比）

### 性能对比方法
- 单发射 CPI ≈ 1.141（master 分支基线）
- 双发射目标 CPI < 1.0（取决于双发射率）
- 使用 MMIO 计数器读取双发射次数 / 总指令数 = 双发射率

---

## 跨 Phase 规则

1. **禁止跳 Phase**：必须按 0 → 1 → 2 → 3 → 4 顺序执行
2. **回归优先**：任何 Phase 的改动必须先通过 43/43 riscv-tests，再做专项测试
3. **回归失败时的调试**：使用 `02_Design/sim/debug/` 下的调试 TB（见 `project_context.md` §3.1）
4. **每个 Phase 完成后**：更新 `status.md` 中对应的 checkbox
5. **发现新的架构问题时**：更新 `architecture.md`，与用户确认后再改代码
6. **git 提交节奏**：每个 Phase 完成验证后做一次 commit，message 格式：`[dual-issue] Phase N: <一句话描述>`

### 验证纪律

**原则**：每个 Phase 的验证不是走过场。AI 必须思考"本次改动可能在哪些场景下出错"，并据此设计针对性的测试。

**最低标准**：

- 每个 Phase 完成后，AI 必须向用户提交一份**验证报告**，包含：
  1. 本 Phase 改了什么（一句话）
  2. 回归测试结果（43/43 是否全过）
  3. 本 Phase 新增或运行了哪些专项测试，以及每个测试覆盖了什么场景
  4. 是否存在本 Phase 改动未被测试覆盖的边界情况，以及理由

- **测试设计要求**：
  - 专项测试必须**针对本 Phase 新增的功能或改动**，而非泛泛的正确性检查
  - 如果本 Phase 是"不改功能"的重构（如 Phase 0/1/2），仍需思考可能的破坏点并解释为何回归测试足够覆盖
  - 测试程序应包含**正例**（功能应该生效的场景）和**反例**（功能不应触发的场景）
  - 鼓励 AI 主动设计极端 case（如连续 100 条同类指令、交替分支、cache miss + 双发射等）

- **用户有权要求补测**：如果用户认为某个场景未被覆盖，AI 应立即补充测试并运行

> 这些规则的目的是确保验证的**思考质量**，而非限制测试的具体形式。AI 应该像一个负责任的验证工程师一样思考，而不是写最少的测试来交差。
