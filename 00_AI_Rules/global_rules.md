# 全局规则

> 需要熟悉工程或修改 RTL 时先读。本文件定义不随架构变化的约束和规范。

---

## 1. 地址空间

| 区域 | 地址范围 | 大小 | 属性 |
|------|---------|------|------|
| **IROM** | `0x8000_0000` ~ `0x8000_3FFF` | 16KB | 只读 |
| **DRAM** | `0x8010_0000` ~ `0x8013_FFFF` | 256KB | 读写（DCache） |
| **MMIO** | `0x8020_0000` ~ `0x8020_00FF` | 256B | 见下表 |

### MMIO

| 地址 | 名称 | 属性 |
|------|------|------|
| `0x8020_0000` | SW 低32位 | 只读 |
| `0x8020_0004` | SW 高32位 | 只读 |
| `0x8020_0010` | KEY | 只读（低8位） |
| `0x8020_0020` | SEG | 读写 |
| `0x8020_0040` | LED | 只写 |
| `0x8020_0050` | CNT | 读写（写0x80000000开始/0xFFFFFFFF停止） |
| `0x8020_0060` | DUAL_ISSUE_CNT | 只读（自定义双发射计数器） |

所有外设仅支持 **4 字节对齐访问**。

---

## 2. 赛方约束

- 指令集：**RV32IM** + 区域赛最小 Zicsr/Trap 子集（CSR / ECALL / MRET）；`fence`/`ebreak` 仍可按 NOP 处理
- 可修改：`Core_cpu`（`student_top.sv`）、PLL
- **禁止修改**：`contest_readonly/` 下所有文件
- PC 复位值：`0x7FFF_FFFC`（text_base - 4）

---

## 3. BRAM 时序模型

所有 BRAM 不启用 Output Register，**1 拍延迟**：

```verilog
always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    dout <= mem[addr];   // posedge 采样 addr，Clk-to-Q (~2ns) 后 dout 有效
end
```

dout 是寄存器输出，组合路径被切断，下游有 ~2ns 时间窗口。

---

## 4. 握手协议

每级流水线使用 `valid` / `allowin` / `ready_go` 三信号握手。

```
xx_allowin = !xx_valid || (xx_ready_go & next_allowin)
```

级间寄存器更新模板：

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             xx_valid <= 0;
    else if (xx_flush)      xx_valid <= 0;         // flush > stall
    else if (xx_allowin)    xx_valid <= prev_valid & prev_ready_go;
    // else: stall，保持不变
end
```

关键性质：
- Stall 只向上游传播
- 气泡是握手自然产物（allowin=1 但上游无数据 → valid <= 0）
- **flush > stall**
- 所有副作用必须 valid gating：`actual_en = xx_valid & en`

---

## 5. 硬件编码规则

- **禁止 Latch**：`always_comb` 必须有完整默认分支
- **禁止 `initial`**：不可用于可综合逻辑
- **所有寄存器必须显式复位**（Synth 8-7137 是严重 warning）
- 优先 **并行 AND-OR MUX** 替代 `case/if-else` 链
- ALU 编码 `alu_op = {funct7[5], funct3}`，直接透传
- 分支条件直接用 `funct3`，无需额外编码

---

## 6. 性能优化立项门槛

> 2026-05-09 追加：先评估，再修改。禁止先写 RTL 再用脚本证明“也许有用”。
> 这些脚本是按需入口，不是新会话或“熟悉工程”时的默认动作；只有用户要求、准备做性能 RTL 改动，或需要验证已完成修改时才运行。

性能目标以**程序运行时间**为准：

```text
runtime ~= cycles * clock_period
```

因此 CPI/cycles 只是半个指标。任何降低 CPI 但明显恶化 Fmax/时序收敛的方案，都按运行时间退化处理。

### RTL 修改前必须完成

1. 从干净 `master` 开实验分支，确认 `git status --short` 为空。
2. 写清楚假设：要改善哪个 benchmark/热点、预期减少哪类 stall 或哪条关键路径、可能伤害哪条路径。
3. 对性能 RTL 改动，用脚本或已有记录拿 baseline，而不是凭感觉：
   - benchmark cycles：`run_perf.sh` 或 COE suite/diff。
   - 更细的 CPI/热点归因：优先用临时 `/tmp/` 分析脚本，不把一次性评估脚本放进仓库。
   - 时序相关方案：先跑 Vivado timing，至少确认当前 top critical paths。
4. 设定淘汰线。没有明确超过门槛的预期，不动 RTL。
   - cycles/runtime 类优化：预期至少约 `1%` 运行时间收益。
   - 时序类优化：必须解释预期切断的路径，或预期改善至少约 `0.3ns` WNS。
   - 大型/流水线切分：必须同时给出 cycles 代价和 Fmax 收益的估算。
5. 先把评估结论写到临时 `/tmp/` 报告，再开始 RTL。

### RTL 修改后验证

- 功能：改 RTL 后运行 `run_all.sh`，目标是全通过。
- 长前缀正确性：涉及前端/分支/访存时，运行 `run_coe_diff.sh`。
- 性能：性能相关改动需要和 baseline cycles/runtime 对比，不能只报”功能通过”。
- 时序：任何影响 IF/IROM、redirect、DCache ready、forwarding/hazard 的改动需要跑 Vivado timing。

### 实验记录策略

默认不在仓库中保留长实验记录。性能方向由人工确认后再进入 RTL；脚本输出、Vivado 报告和中间分析默认放 `/tmp/` 或本地工作目录。

本机脚本优先使用 **18 核**，例如 `--jobs 18`、`JOBS=18` 或 Vivado Tcl flow 的 jobs 参数为 `18`。如果降低并行度，只需在当前讨论或短结论中说明原因。

---

## 7. 验证流程

### 回归测试（仅在 RTL 改动后或用户要求时运行）

```bash
cd 02_Design/riscv_tests
bash run_all.sh
```

- 预期结果：**74/74 PASS**（`run_all.sh` 当前测试集：基础 RV32I、RV32M、综合/压力、自定义双发射/BP/DCache/RAS、Zicsr/Trap 测试）
- 默认启用 PC 越界 guard 和流水线无进展 watchdog；PC 跑出 IROM 窗口会直接报错，避免只表现为长时间 timeout。
- 依赖：iverilog、`work/hex/*.hex`（已预编译，无需重新 build）
- 编译产物自动生成在 `work/`，已 gitignore

### 性能 Profiling（按需运行）

```bash
cd 02_Design/riscv_tests
bash run_perf.sh [test_name...]
```

- 不带参数时脚本会跑 `bp_stress dcache_stress counter_stress sb_stress`
- 输出 `[PERF]` 开头的性能报告（CPI、stall 分解、双发射率、BP 误预测率）

### 重新编译测试（仅在修改/新增测试用例时）

```bash
cd 02_Design/riscv_tests
bash build_tests.sh
```

- 依赖：`riscv64-unknown-elf-gcc`、项目根目录 `riscv-tests/` 源码
- 中间产物放 `/tmp/riscv_build/`，只有 .hex 输出到 `work/hex/`

### COE 程序功能/性能检查

```bash
cd 02_Design/riscv_tests
MAX_CYCLES=1500000 WATCHDOG_CYCLES=150000 bash run_coe_suite.sh current src0 src1 src2
COMMITS=50000 MAX_CYCLES=1500000 WATCHDOG_CYCLES=150000 bash run_coe_diff.sh current src0 src1 src2
```

- `run_coe_suite.sh`：跑完整 COE 程序到 LED 结果。
- `run_coe_diff.sh`：对比软件参考模型和 RTL commit trace，适合 RTL 改动后做长前缀正确性检查。

### Vivado 时序流

```bash
vivado -mode tcl \
  -log 03_Timing_Analysis/vivado_work/vivado.log \
  -journal 03_Timing_Analysis/vivado_work/vivado.jou \
  -source 03_Timing_Analysis/run_vivado_flow.tcl \
  -tclargs "$PWD" current 18
```

- 流程：更新 COE/IP → `synth_1` → `impl_1`（不生成 bitstream）→ `open_run impl_1` → `source report_stage_timing.tcl`。
- 报告输出：`03_Timing_Analysis/stage_timing_report.txt`。
- Vivado 工作目录：`03_Timing_Analysis/vivado_work/`，已 gitignore。

### 自有物理板 bitstream

```bash
./PhysicalTwin_Nexys4DDR/run_build.sh dual_issue/current
./PhysicalTwin_Nexys4DDR/run_build.sh dual_issue/src1
```

- 生成文件在 `PhysicalTwin_Nexys4DDR/vivado/`。
- 生成内存初始化文件在 `PhysicalTwin_Nexys4DDR/generated/`。
- Nexys 4 DDR 工程使用板上 BRAM 实现完整 256 KiB 逻辑 DRAM；当前不使用 DDR2/MIG。
- `constraints/board.xdc` 是工程实际使用的约束；`constraints/Nexys-4-DDR-Master.xdc` 保留 Digilent master XDC 作为引脚参考。

---

## 8. 工程卫生

### 目录职责（不得混放）

| 目录 | 允许内容 | 禁止 |
|------|---------|------|
| `02_Design/rtl/` | 可综合 RTL 源码 | TB、脚本、文档 |
| `02_Design/riscv_tests/` | 回归 TB + 脚本 | 临时调试 TB |
| `02_Design/coe/` | COE 文件 + 工具脚本 | 仿真产物 |
| `00_AI_Rules/` | 当前规则、架构文档 | 临时实验记录 |
| `PhysicalTwin_Nexys4DDR/` | Nexys 4 DDR 板级封装、约束和板级文档 | CPU RTL 副本 |

### 临时/实验性文件

- **一律放 `/tmp/`**（如 `/tmp/dcache_opt/`、`/tmp/riscv_build/`）
- 验证有价值后再决定是否纳入工程目录
- **禁止**在工程目录下随手建 `test_xxx.sv`、`debug_xxx.py` 等临时文件

### 编译/仿真产物

- 必须被 `.gitignore` 覆盖
- 允许存放位置：`work/`（已 gitignore）或 `/tmp/`
- 禁止与源码同目录

### 新增文件检查清单

在创建任何新文件前确认：
1. 是否属于已有目录的职责范围？
2. 是否有 `.gitignore` 覆盖产物？
3. 临时文件是否放在 `/tmp/`？
4. 是否会在迭代后变成死文件？→ 放 `/tmp/`

---

## 9. 文档维护

- 当前有效文档包括：`global_rules.md`、`architecture.md`、`02_Design/coe/README.md`、`02_Design/riscv_tests/test_coverage.md`、`PhysicalTwin_Nexys4DDR/README.md`。
- RTL 改动通过回归后，同步更新 `architecture.md`。
- 信号名必须与 RTL 一致；当前架构文档只写当前状态，不保存长实验档案。
