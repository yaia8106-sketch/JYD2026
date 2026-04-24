# 设计决策记录

> 本文档记录所有架构级设计决策的结论和理由。供自己回顾用。
> 决策结论会被提炼到 `design_rules/` 中供 AI 遵守。

---

## A. 寄存器堆读写冲突策略

**决策：Read-first（读旧值）**

- WB 写 x5 同一拍 ID 读 x5 → ID 读到**旧值**
- 实现方式：regfile 无需内部 bypass，纯 32:1 MUX 读取
- 影响：前递 MUX 需要处理 EX、MEM、WB 三级前递
- 理由：read-first regfile + 3 级前递的**总组合路径比** write-first + 2 级前递**更短**（bypass MUX 串联在 regfile 读路径上增加深度，而前递 MUX 多一级只是并联输入）

---

## B. 分支 Flush 代价

**决策：Flush 代价 = 2 拍气泡**

- 分支在 EX 级判断，默认顺序执行，错了 flush
- IROM 为 1 拍 BRAM（无 Output Register），flush 时 `irom_addr` 立即切换到 `branch_target`
- 冲刷 2 条指令：IF/ID 中的错误指令 + BRAM 正在取的下一条错误指令
- 时序（阶段→动作）：
  ```
  Cycle N:    EX 检测分支 → flush=1, irom_addr=branch_target, IF/ID.valid←0
  Cycle N+1:  BRAM Clk-to-Q 出目标指令, ID=bubble, EX=bubble（第1拍气泡）
  Cycle N+2:  IF/ID 锁存目标指令(id_valid=1), EX=bubble（第2拍气泡）
  Cycle N+3:  目标指令进入 EX，恢复正常执行
  ```
- 对比旧方案（2 拍 BRAM）：flush 代价从 3 拍降到 2 拍

---

## C. JAL/JALR 跳转处理

**决策：初版全部在 EX 级处理，后期优化 JAL 提前到 ID 级**

- 初版：BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR 全部在 EX 级判断，flush 代价统一 2 拍
- 后期优化（时序允许时）：JAL 提前到 ID 级判断，penalty 从 2 拍降到 1 拍
  - JAL 在 ID 级只需要 PC + imm 的加法，组合路径可控
  - JALR 需要读寄存器 + 加立即数，组合路径可能太长，暂不考虑提前
- 理由：先保证正确性和架构简洁，性能优化后面再做

---

## D. 控制信号定义

**决策：已定义，见 `design_rules/isa_encoding.md`**

- 14 个控制信号，覆盖 ALU 操作、操作数选择、写回、访存、分支判断、立即数类型
- ALU 操作用 4-bit 编码 10 种运算
- 分支条件直接复用 funct3 编码，无需额外转换
- LUI 通过 alu_src1_sel=0（零）+ ADD 实现，不需要额外的 ALU 操作码
- 分支/跳转判断：ALU 计算目标地址，独立比较器判断条件，两者并行
- JAL/JALR 的 link 地址（PC+4）在 ID 级计算并通过流水线传递，wb_sel=10 选择

---

## E. DRAM 访存细节

**决策：32-bit Single Port BRAM + 4-bit WEA 字节使能**

- DRAM 宽度 32-bit，BRAM 地址端口接收 word 地址（`ALU_result[?:2]`，去掉低 2 位）
- `addr[1:0]`（ALU_result 的低 2 位）**不送 BRAM**，而是通过流水线传递，用于：
  - Store：与 `mem_size` 一起生成 WEA（字节使能）+ 将写数据移位到正确的字节位置
  - Load：在 WB 级与 `mem_size`/`mem_unsigned` 一起从 BRAM 32-bit dout 中提取正确的 byte/halfword，并做符号/零扩展
- WEA 由 `addr[1:0]`（定位在哪）+ `mem_size`（定义写多宽）共同决定
- `addr[1:0]`、`mem_size`、`mem_unsigned` 需要通过流水线传递到 WB 级

---

## F. 前递完整路径

**决策：前递 MUX 在 ID 级，3 级前递（EX > MEM > WB > regfile）**

前递 MUX 为 rs1 和 rs2 各一个，采用并行匹配 + 优先级编码 + one-hot MUX 结构（详见 `pipeline.md` §9.1）。

MEM 级前递显式排除 Load 指令（`!mem_is_load`），因为 MEM 级的 ALU 结果是 Load 的地址而非数据。

各级前递数据来源：

| 级 | 数据信号 | 来源 | 说明 |
|----|---------|------|------|
| EX | `ex_alu_result` | EX 级 ALU 组合逻辑输出 | Load 在 EX 时数据不可用 → Load-Use stall |
| MEM | `mem_alu_result` | EX/MEM_reg 输出 | 只有 ALU 结果可前递，Load 数据在 MEM 级仍不可用 |
| WB | `wb_write_data` | `wb_is_load ? wb_dram_dout : wb_alu_result` | Load 数据此时才可用（经 MEM/WB 寄存器传递） |
| regfile | `rf_rd1_data` / `rf_rd2_data` | regfile 读端口输出 | read-first，WB 同拍写读读到旧值 |

控制信号来源：
- `ex_valid`, `ex_reg_write`, `ex_rd`：来自 ID/EX_reg 输出
- `mem_valid`, `mem_reg_write`, `mem_rd`：来自 EX/MEM_reg 输出
- `wb_valid`, `wb_reg_write`, `wb_rd`：来自 MEM/WB_reg 输出

---

## F2. Load-Use Stall 与 1-cycle BRAM 的权衡

**决策：保持 2 拍 stall 不变（暂不加 MEM Load 前递）**

DRAM 从 2 拍 BRAM（有 output register）改为 1 拍（无 output register）后，load 数据在 MEM 阶段就可用（BRAM Clk-to-Q）。
理论上可以从 MEM 阶段直接前递 load 数据到 ID 阶段，将 load-use penalty 从 2 拍降到 1 拍。

### 权衡分析

当前 `load_in_mem` stall 的原因（2 拍 BRAM 时）：MEM 阶段 load 数据不可用。
改为 1 拍 BRAM 后：MEM 阶段 BRAM 已输出数据，`load_in_mem` 可以去掉。

但需要在 MEM 阶段增加 load 前递路径：
```
BRAM Clk-to-Q(2.0) + output MUX(0.2) + mem_interface(0.5)
+ routing(0.5) + 前递MUX(0.3) + routing到ID/EX(0.5) = ~4.0ns
```

对比当前最长路径 3.65ns（EX 前递），这会成为新瓶颈。

### 决策理由

- 4.0ns 路径在 222MHz（4.5ns 周期）下 slack 仅 ~0.5ns，布线后大概率违例
- 当前 2 拍 stall 功能正确，性能损失可通过编译器调度部分弥补
- 先保证时序收敛，后期优化时再考虑此路径

### 后期优化方向

如果需要降低 load-use penalty：
1. 降频到 200MHz（5.0ns），给 MEM load 前递留更多余量
2. 只对 LW（word load）做 MEM 前递，LB/LH 走 2 拍 stall（省去 mem_interface 延迟）
3. 将 mem_interface 的字节提取逻辑移到前递 MUX 之后（WB 侧处理）

---

## G. IROM/DRAM Vivado IP 配置

**IROM：Single Port ROM，32-bit，不启用输出寄存器（1 拍延迟），COE 文件初始化 — 已确定**

**DRAM：Simple Dual Port RAM，32-bit，65536 depth (256KB)，4-bit WEA — 已确定**

- DCache 实现后改为 SDP：Port A = 写（Store Buffer drain），Port B = 读（Refill FSM）
- **重要**: Port B 有 output register（`Register_PortB_Output_of_Memory_Primitives = true`，DOB_REG=1）
- 读延迟 = 2 cycle（BRAM read + output register），加上 registered addr 总延迟 = 3 cycle = DRAM_LATENCY
- 地址粒度：word 地址（64 个 RAMB36E1）

### IROM 取指架构（预取方案）

IROM 为 1 拍 BRAM（无 Output Register），采用预取方案：

```
irom_addr = branch_flush  ? branch_target :   // 分支：预取目标
            !if_allowin   ? pc :               // 停顿：保持当前地址
                            next_pc;           // 正常：预取下一条
```

- **正常执行**：`irom_addr = next_pc = pc + 4`，BRAM 提前 1 拍锁存下一条指令地址
- **分支 flush**：`irom_addr = branch_target`，BRAM 立即锁存目标地址，1 拍后出正确指令
- **load-use stall**：`irom_addr = pc`，BRAM 保持当前地址，stall 解除后出正确指令
- IF/ID 寄存器同时锁存 PC 和指令（`id_pc` + `id_inst`），确保 ID 阶段天然对齐
- PC 复位值 = `0x7FFF_FFFC`（= text_base - 4），使首拍 `next_pc = 0x8000_0000`

### DRAM Output Register 决策

三种方案对比后确定不勾选 output register：
- 内建 output reg（2 拍）：MUX 在输出寄存器之后，WB 的 Clk-to-Q = 2.1ns
- 手动加 reg（2 拍）：MEM 阶段压力与不勾选完全相同（3.5ns），多等 1 拍无优势
- 不勾选（1 拍）：MEM/WB 寄存器承担原来 output register 的角色

### 已完成的改动

- `if_id_reg.sv`：新增 `if_inst` / `id_inst` 传递（锁存指令到 ID 阶段）
- `cpu_top.sv`：`irom_addr` 三路 MUX（branch_target / pc / next_pc）
- `cpu_top.sv`：decoder/imm_gen/regfile 读地址从 `irom_data` 改为 `id_inst`
- `pc_reg.sv`：复位值改为 `0x7FFF_FFFC`（预取方案需要 text_base - 4）
- `mem_wb_reg.sv`：新增 `mem_dram_dout` → `wb_dram_dout` 传递

### 平台集成架构

1. **IROM**：在 `student_top` 例化，cpu_top 通过 `irom_addr` / `irom_data` 端口访问
2. **DRAM**：由 DCache 管理（SDP BRAM，Port A=写，Port B=读，DOB_REG=1），CPU 不再直连 DRAM
3. **MMIO 读**：组合逻辑，通过 `mmio_bridge`（原 `perip_bridge` 瘦身）
4. **MMIO 写**：时序逻辑，通过 `mmio_bridge`
5. **DRAM 容量**：65536×32bit（256KB），64 个 RAMB36E1

---

## H. Flush / Stall 时 IROM 地址控制

**决策：通过 `irom_addr` 三路 MUX + valid gating 处理**

- **分支 flush**：`irom_addr = branch_target`，BRAM 立即锁存正确地址。flush 沿 IF/ID.valid = 0（1 拍气泡），下一拍 BRAM 输出正确指令，IF/ID 正常锁存
- **load-use stall**：`irom_addr = pc`（不是 next_pc），BRAM 保持锁存当前指令地址。stall 解除时 BRAM 输出的是正确指令（不会跳过一条）
- **正常执行**：`irom_addr = next_pc`，预取下一条
- 关键：三路 MUX 优先级为 `branch_flush > !if_allowin > default`
- 不需要额外的 BRAM flush 或 enable 控制机制

---

## I. perip_bridge EX→MEM 写路径时序优化

**决策：三轮优化，已全部实施并 FPGA 验证通过**

### 优化内容

1. **ALU `alu_sum` 端口**：暴露加法器直出（跳过 AND-OR output MUX），省 ~1 级 LUT
   - 安全性：Load/Store 指令的 `alu_op` 恒为 `ALU_ADD`，所以 `alu_sum == alu_result`
   - 非 Load/Store 指令时 `wea=0`，`is_dram` 和地址判断的值无关紧要

2. **`is_dram` 使用 `addr_sum[31:18]`**、**MMIO 写用 `addr_sum[6:4]` 部分译码**
   - 跳过 ALU output MUX + 32-bit 比较 → 3-bit 比较
   - `!is_dram` 已确认 MMIO 空间，只需区分设备：LED=100, SEG=010, CNT=101

3. **并行 AND-OR 结构 + wdata 2-bit 命令解码**
   - 每个 MMIO 寄存器独立 `always_ff` + one-hot 写使能（`wr_led/wr_seg/wr_cnt`）
   - `wdata` 命令解码从 32-bit×2 全等比较改为 2-bit 判断：
     - `cnt_start = wr_cnt & wdata[31] & ~wdata[0]`（0x8000_0000）
     - `cnt_stop  = wr_cnt & wdata[31] &  wdata[0]`（0xFFFF_FFFF）

### 优化效果

| 版本 | 约束 | 最差路径 | DataPath | Levels | Slack |
|------|------|---------|----------|--------|-------|
| 原始 | 180MHz | cnt_enable_cfg | 5.035ns | 15 | +0.377ns |
| +alu_sum/部分译码 | 180MHz | cnt_enable_cfg | 5.029ns | 15 | +0.383ns |
| +并行AND-OR/2bit解码 | 180MHz | DRAM WEA | 3.802ns | 13 | +1.170ns |
| **Implementation@200MHz** | **200MHz** | **DRAM DIADI** | **4.269ns** | **5** | **+0.011ns** |

- `cnt_enable_cfg` 路径彻底跌出 Top 10
- RTL 级最差路径从 5.035ns 降至 3.802ns（**↓24.5%**），slack 翻 3 倍
- 200MHz Implementation 通过，但 slack 仅 +0.011ns，瓶颈已转移至**布线延迟**
  （5 级 LUT 纯逻辑 ~1.25ns，布线 ~2.5ns，占总延迟 ~50%）
- 进一步提频需 P&R 策略优化（Performance_Explore / Pblock）而非 RTL 改动

---

## J. 分支预测 / RAS 优化计划

**状态：已实施（NLP Tournament 架构）**

> 以下规划已全部完成。最终实现为 NLP Tournament 分支预测器：
> - BTB 64-entry 直接映射 + 嵌入 2-bit Bimodal BHT
> - GShare: 8-bit GHR XOR PC[9:2] → 256-entry PHT
> - Selector: 256-entry, GHR 索引
> - RAS: 4-deep shift stack
> - IF(L0): 用 bht[1] 快速预测（Bimodal）, ID(L1): Tournament 验证
> - FPGA 验证通过 @ 200MHz, riscv-tests 41/41 PASS

### CPI 损失分析（基于 COE 指令分布统计）

当前五级流水线无分支预测，CPI 损失：

| 来源 | 指令占比 | Penalty | CPI 损失 |
|------|:--------:|:-------:|:--------:|
| JAL + JALR | 12.6% | 2 拍 | ~0.25 |
| 条件分支 (taken) | 6.8% × ~50% | 2 拍 | ~0.07 |
| Load-use stall | ~16% × ~30% | 1 拍 | ~0.05 |
| **总计** | | | **CPI ≈ 1.37** |

JAL+JALR 占 CPI 损失的 **68%**，是最大优化目标。

### 三种预测器分工

| 预测器 | 解决什么 | 对应指令 | 说明 |
|--------|---------|---------|------|
| **RAS** | 函数返回跳转地址 | JALR (rs1=ra) | 4-8 entry 栈，预测 ret 目标 |
| **局部预测 (BHT)** | 条件分支 taken/not-taken | BEQ/BNE/BLT... | 每条分支独立的 2-bit 饱和计数器 |
| **全局预测 (GShare)** | 分支间关联预测 | BEQ/BNE/BLT... | GHR XOR PC 索引 PHT |

### 方案选择依据

- COE 中 **BNE 占分支的 60-80%**，大部分是循环底部的固定模式跳转
- 局部预测对循环模式效果最好，GShare 在分支关联性强时更优
- 测试程序以循环为主 → **局部预测（BHT）已经够用**

### 实施计划

| 阶段 | 内容 | 预期 CPI 改善 | 时序风险 |
|------|------|:------------:|:-------:|
| Phase 1 | **RAS**（4 entry） | ~0.10 | 无 |
| Phase 2 | **2-bit BHT**（256 entry 局部预测） | ~0.05 | 低 |
| Phase 3 | 改 GShare（如 BHT 不够好） | ~0.01-0.02 | 低 |

Phase 1 + Phase 2 覆盖 ~90% 的收益。

### 冷启动预测准确率实测（10M 指令，bp_coldstart_sim.py）

| 程序 | 条件分支 | CALL | RET | JALR(other) | 整体 | CPI |
|:----:|:--------:|:----:|:---:|:-----------:|:----:|:---:|
| current | 78.4% | 100.0% | 99.9% | 0.0% | 78.1% | 1.182 |
| src0 | 59.2% | 35.6% | 100.0% | 0.0% | 59.7% | 1.173 |
| src1 | 74.5% | 96.8% | 71.2% | 0.0% | 75.0% | 1.164 |
| src2 | 70.0% | 99.9% | 99.9% | 0.0% | 71.7% | 1.183 |

**薄弱环节**：
- 非 RET 的 JALR（间接跳转）0% — 设计上不写入 BTB，无法预测
- src0 的 CALL 仅 35.6% — BTB 64-entry 直接映射 index 冲突
- src1 的 RET 仅 71.2% — 调用深度可能超过 RAS 4 层
- 条件分支 59-78%，受 BTB 容量和 aliasing 限制

详见 `02_Design/coe/sim_output/bp_coldstart_results.md`。

---

## 决策 D-11: 前递值修复（预测器集成时发现的隐藏 bug）

**日期**: 2026-04-19  
**状态**: 已修复  
**触发条件**: bp_stress Test 5（函数调用/返回）失败

### 问题

`forwarding.sv` 的 EX/MEM 前递值始终取 `alu_result`。对于 JAL/JALR 指令：
- `alu_result` = 跳转目标地址（如函数入口 `0x80000150`）
- 实际写入 `rd` 的 = `PC+4`（返回地址 `0x800001D4`）

**前递给出的是跳转目标，而不是返回地址。**

### 为什么之前没有暴露

无预测器时，每次 JAL/JALR taken 都会 flush IF/ID。flush 后 ID 级不存在有效指令，
前递的 match 条件 (`ex_valid=0`) 永远不成立 → bug 代码路径从未执行。

### 为什么有预测器后暴露

正确预测的 CALL 不 flush → 函数体内的指令立即进入 ID → 如果函数第 2 条指令
读取 `ra`（如 `ret`），前递 match 成功 → 拿到错误的跳转目标而非返回地址。

### 修复

```sv
// forwarding.sv
wire [31:0] ex_fwd_val  = (ex_wb_sel  == 2'b10) ? (ex_pc  + 32'd4) : ex_alu_result;
wire [31:0] mem_fwd_val = (mem_wb_sel == 2'b10) ? (mem_pc + 32'd4) : mem_alu_result;
```

### 教训

> 分支预测器改变了"哪些指令可以同时存在于流水线中"的关系。  
> 新增优化功能时，必须重新审视前递、stall、flush 三者的隐含假设。

---

## K. 250MHz 超频尝试与 DRAM 瓶颈

**日期**: 2026-04-19  
**分支**: `feat/250mhz-timing`  
**状态**: 200MHz 时序收敛，250MHz 未收敛，瓶颈为 DRAM BRAM 布线

### 核心改动：Flush 延迟一拍（EX→MEM）

为降低关键路径延迟，将 `branch_flush` 和 `branch_target` 从 EX 级组合逻辑推迟到 MEM 级（打一拍）：

- **关键路径优化前**: EX ALU 输出 → `branch_flush` → `irom_addr` MUX → IROM（组合逻辑跨 EX-IF 两级）
- **关键路径优化后**: 寄存器输出 → `mem_branch_flush` → `irom_addr` MUX → IROM（仅 1 级 MUX）
- **代价**: Branch penalty 从 2 cycles 增加到 3 cycles

修改文件：
- `cpu_top.sv`: 更新 `irom_addr` MUX 优先级，使用 `mem_branch_flush`
- `ex_mem_reg.sv`: 新增 `mem_branch_flush/target` 寄存器 + 门控 spurious 指令
- `id_ex_reg.sv`: 更新 `ex_flush` 信号源
- `cpu_top.sv`: 门控 `branch_flush & ~mem_branch_flush` 防止错误路径 flush
- `cpu_top.sv`: 门控预测器 `ex_valid & ~mem_branch_flush` 防止错误路径训练

### 时序结果

| 约束频率 | WNS | 结果 |
|---------|:---:|:----:|
| 200MHz (主分支, 无 flush 延迟) | -0.647ns | ❌ |
| **200MHz (本分支, flush 延迟)** | **+0.099ns** | **✅** |
| 220MHz | -1.241ns | ❌ (拥塞) |
| 250MHz (AggressiveExplore) | -0.623ns | ❌ |

### 250MHz 瓶颈分析

超过 4ns 的路径**全部是 DRAM BRAM 相关**，CPU 内部逻辑最差仅 3.41ns：

| 路径 | 最差延迟 | 逻辑级 | 原因 |
|------|:-------:|:-----:|------|
| MEM ALU → DRAM BRAM 读地址 | 4.47ns | 0 级 | `mem_alu_result` 寄存器直连 BRAM 读端口，扇出 68 导致布线长 |
| EX forwarding → DRAM BRAM 写地址 | 4.33ns | 9 级 | ALU 组合逻辑 → 经 perip_bridge → BRAM 写端口 |
| MEM 写数据 → DRAM BRAM | 4.21ns | 0 级 | `mem_store_data/wea` 寄存器直连 BRAM 写数据端口，扇出大 |

**根本原因**: DRAM 由 68 个 BRAM36 块组成（256KB），任何连到 DRAM 的信号扇出都很大。

### 已尝试的优化

1. **MAX_FANOUT 约束**: XDC 中对高扇出寄存器设置 `MAX_FANOUT 24`，效果有限
2. **Performance_Explore + AggressiveExplore**: Vivado 策略优化，改善但不足以收敛

### 后续方向思考

- **Data Cache**: 在 CPU 和 DRAM 之间加一层小容量 Cache（如 4KB direct-mapped），Cache 只用少量 BRAM 块（扇出小，布线短），频率应能显著提升。同时 Cache 可降低 DRAM 访问频率，对多次访问同一区域的程序有性能加速效果。
- **缩小 DRAM**: 如比赛允许，减小 DRAM 容量（如 64KB → 17 个 BRAM）直接降低扇出
- **Pblock/Floorplan**: 手动约束 CPU 和 DRAM BRAM 放到相邻区域

### 基准性能对比 (current 程序, 200MHz)

| 分支 | 时钟频率 | 运行时间 | 说明 |
|------|:-------:|:-------:|------|
| master (NLP Tournament) | 200MHz | ~176ms | 时序收敛 |
| feat/250mhz-timing | 200MHz | ~180+ms | flush penalty +1 cycle |

当前分支因 flush penalty 增加（2→3 cycles），性能略有回退。
在 200MHz 不变的前提下，本分支不如主分支。
本分支价值在于：**如果未来加入 Cache 解决 DRAM 瓶颈，可在更高频率下运行。**

---

## L. Data Cache 可行性量化分析

**日期**: 2026-04-19  
**状态**: 模拟完成，确认可行，待实现

### 背景

决策 K 确定 250MHz 瓶颈在 DRAM 68×BRAM36 高扇出布线。需量化评估 Data Cache 方案的收益。

### 模拟方法

使用 `cache_sim.py` 进行 ISA 级仿真：运行 4 个 COE 程序各 5M 周期，记录所有 DRAM Load/Store 访问地址，送入 9 种 Cache 配置模拟命中率。

### 访存特征

| 程序 | DRAM 访问 | 唯一 word | 地址范围 | 特征 |
|------|:---------:|:---------:|:-------:|------|
| current | 170K | **22** | 32 KB | 极高局部性，栈操作为主 |
| src0 | 690K | 16,671 | 245 KB | 工作集较大 |
| src1 | 771K | **89** | 212 KB | 极高局部性 |
| src2 | 539K | 14,029 | 241 KB | 工作集较大 |

### 关键结果

| 配置 | 平均命中率 | 250MHz 加速比 | BRAM 开销 |
|------|:---------:|:------------:|:---------:|
| DM 1KB/16B | 96.7% | +23.8% | ~1 BRAM36 |
| DM 2KB/16B | 97.8% | +24.2% | ~1 BRAM36 |
| **DM 4KB/32B** | **98.8%** | **+24.6%** | **~1 BRAM36** |
| 2W 4KB/16B | 98.5% | +24.5% | ~1 BRAM36 |
| 4W 4KB/16B | 98.5% | +24.5% | ~1 BRAM36 |

- current 和 src1 在任何配置下都 ~100% 命中（工作集极小）
- src0 和 src2 工作集较大，但在 4KB 下也有 97%+ 命中率
- **组相联对这些程序收益甚微**，直接映射即可

### 推荐方案（模拟阶段）

~~**DM 4KB/32B**（直接映射，4KB 容量，32B 行大小 = 8 words/line）~~

### 最终实现

**2-way 2KB/16B**（2-way set-associative，2KB 容量，16B 行大小 = 4 words/line）

最终选择理由：
1. 2KB vs 4KB 仅差 0.5% hit rate，省一半 BRAM
2. 2-way 在 src0/src2（工作集大）上比 DM 更稳定，减少 conflict miss
3. 16B 行 vs 32B 在无 CWF 下差距小，refill 周期更短（8 vs 14 cycles）
4. 2-way LRU 只需 1 bit/set，实现简单

### 实现要点（已完成）

```
CPU ←→ DCache (2×BRAM18) ←→ DRAM (64×BRAM36, SDP, DOB_REG=1)
     关键路径: ≤2ns           多周期 FSM, 非关键路径
```

- Cache 仅 2×BRAM18（每 way 1 个），扇出小→布线短
- Miss: 6 状态 FSM（BURST→DRAIN→DONE_RD→DONE），pipeline overlap，8 cycles/miss
- Write-through + 1-entry Store Buffer，SB drain 优先于 refill（保证 DRAM 数据一致性）
- flush 中断 refill，victim tag 提前失效防止部分覆写命中
- 详见 `02_Design/spec/dcache_spec.md` v1.1


## M. 250MHz 时序优化：非 DRAM 关键路径削减

**日期**: 2026-04-21
**分支**: `feat/dcache-250mhz`
**状态**: 已实施，待 FPGA 验证

### 背景

决策 K 确认 250MHz 瓶颈在 DRAM 68×BRAM36 布线（决策 L 推荐用 DCache 解决）。
但从 200MHz 时序报告分析，去掉 DRAM 路径后，还有 5 条路径在 250MHz 下会违例。
本决策记录其中 2 条已优化的路径。

### 优化 1：branch_unit 使用 alu_addr 替代 alu_result

**问题路径**: `ID/EX(ex_alu_src1) → ALU → branch_unit → branch_flush → EX/MEM(mem_branch_flush_reg)`
- DataPath = 4.430ns, 9 级逻辑, slack = +0.518ns @200MHz
- 250MHz 下 slack ≈ -0.43ns ❌

**根因**: `branch_unit` 输入 `alu_result` 需经过 ALU 的 negate 判断 + src2 条件取反 + 7 路 AND-OR output MUX，多出 ~3 级逻辑。但分支/跳转指令的 `alu_op` 恒为 ADD，不需要 negate 和 output MUX。

**改动**:
- `branch_unit.sv`: 端口 `alu_result` → `alu_addr`
- `cpu_top.sv`: 连接 `alu_addr`（纯 src1+src2 加法器直出）

**效果**: 省掉 negate + conditional invert + output MUX 三段，约减少 ~0.9ns。250MHz 下预估 slack 翻转为 +0.5ns ✅

**安全性**: 对所有分支/跳转指令，`alu_addr == alu_result`。非分支指令时 `branch_flush` 不被激活。

### 优化 2：btb_valid 从 FF 数组改为 LUTRAM

**问题路径**: `BP(btb_valid FF) → 64:1 MUX → tag compare → bp_taken → next_pc → pc_reg`
- DataPath = 4.428ns, 8 级逻辑, slack = +0.471ns @200MHz
- 250MHz 下 slack ≈ -0.43ns ❌

**根因**: `btb_valid` 声明为普通 `logic` 数组（有 async reset），Vivado 综合为 64 个独立 FF。读取 `btb_valid[if_idx]` 变成 64:1 FF MUX（~2-3 级 LUT）。

**改动**:
- `branch_predictor.sv`: `btb_valid` 加 `(* ram_style = "distributed" *)` 属性
- 去掉 async reset，改为 `always_ff @(posedge clk)` + `initial` 块

**效果**: 省掉 ~1-2 级 LUT（~0.3-0.5ns）。

**安全性**: 冷启动安全——虚假 hit 由 branch_unit flush 纠正，与 PHT/Selector 冷启动模式一致。

### 优化 3：L0 预测逻辑 if-case → AND-OR 平坦化

**问题**: `bp_taken` 由 `if (btb_hit_w) case (r_type)` 生成，综合器可能产生 2 级 MUX（hit 门控 + type 解码）。

**改动**:
- `branch_predictor.sv`: 用 AND-OR 表达式替代 always_comb if-case

```sv
// bp_taken: 5 输入 → 单 LUT6
bp_taken = btb_hit_w & (
      ~r_type[1]                    // JAL/CALL: always taken
    | (~r_type[0] & r_bht[1])      // BRANCH: bimodal direction
    | ( r_type[0] & ras_valid)     // RET: RAS valid
);

// bp_target: 3 路 AND-OR MUX（one-hot select）
sel_btb / sel_ras / sel_seq → AND-OR
```

**效果**: `bp_taken` 从 ~2 级 LUT → **1 个 LUT6**，省 ~0.2-0.3ns。`bp_target` 显式 one-hot MUX，加法器与 MUX 并行。

### 优化后剩余风险路径

| 路径 | 优化前 DataPath | 优化后估算 | 250MHz Slack |
|------|:--------------:|:---------:|:------------:|
| ID/EX → EX/MEM flush | 4.430ns | ~3.5ns | ~+0.5ns ✅ |
| ID/EX → BP btb_tgt 写 | 4.450ns | ~3.5ns | ~+0.5ns ✅ |
| BP → PC | 4.428ns | ~3.6ns | ~+0.1ns ⚠️ |
| BP → IROM | 4.153ns | ~3.7ns | ~+0.0ns ⚠️ |
| PC → IROM | 4.203ns | ~4.0ns | ~-0.2ns ⚠️ |

取指前端的剩余违例主要是布线延迟，可能需要 Pblock 布局约束配合。


## N. 250MHz 时序优化：→IROM 取指前端路径削减

**日期**: 2026-04-21
**分支**: `feat/dcache-250mhz`
**状态**: 已实施，待 FPGA 验证

### 背景

决策 M 完成后，200MHz WNS = +0.090ns。全局 Top 10 最差路径均为 EX/MEM→DRAM 布线（0 级逻辑），
CPU 内部逻辑不在瓶颈。但分析 →IROM 路径群在 250MHz 下仍有 deficit：
- PC→IROM: +0.396ns @200MHz → -0.6ns @250MHz
- IF/ID→IROM: +0.583ns → -0.4ns
- BP→IROM: +0.678ns → -0.3ns

这些路径不受 DCache 改动影响，需要独立优化。

### 优化 4：next_pc_mux 消除（irom_addr 内联）

**问题路径**: `PC → BP → bp_taken → next_pc → irom_addr MUX → IROM`
- next_pc = bp_taken ? bp_target : pc+4（1 级 MUX）
- irom_addr = ... : next_pc（又 1 级 MUX）
- 两级串联 MUX 可合并

**改动**:
- `cpu_top.sv`: 删除 `next_pc_mux` 例化，删除 `next_pc` 中间变量
- 将 bp_taken/bp_target 直接内联到 irom_addr 的 5 路优先级 MUX

```diff
- irom_addr = ... : next_pc;  // next_pc = bp_taken ? bp_target : pc+4
+ irom_addr = ... : bp_taken ? bp_target : (pc + 32'd4);
```

**效果**: 省 1 级 LUT（~0.2-0.3ns）。`next_pc_mux.sv` 不再被例化。

### 优化 5：BTB tag 7-bit → 5-bit

**问题路径**: `PC → BTB LUTRAM → 7-bit tag compare → btb_hit_w → bp_taken`
- 7-bit compare 需 2 级 LUT（3+4 bit compare → combine + valid）

**改动**:
- `branch_predictor.sv`: `BTB_TAG_W = 7 → 5`，tag = `pc[12:8]`（原 `pc[14:8]`）

**效果**: 5-bit compare + valid = 6 输入 → **单 LUT6**，省 1 整级 LUT（~0.2-0.3ns）。

**代价**: 覆盖范围从 8K 字 → 2K 字，误命中概率从 1/128 → 1/32。
对当前测试程序（~1271 条）无影响；大程序可能多几次 misprediction，但功能安全（flush 纠正）。

### 优化 6：NLP redirect raw/gated 拆分 + stall 优先级提升

**问题路径**: `IF/ID → id_inst → hazard detect → id_ready_go → id_bp_redirect → irom_addr → IROM`
- 7 级逻辑，主犯是 hazard 检测（5-bit compare ×2）在 →IROM 关键路径上

**核心发现**: `id_bp_redirect` 含 `id_ready_go & ex_allowin` 门控是因为旧 irom_addr 中
redirect 优先级高于 stall。如果 **stall 提到 redirect 上方**，门控就不再必要（stall 时
`!if_allowin_w=1` 自动选 `pc`，挡住 redirect）。

**改动**:
- `cpu_top.sv`: 拆分为 `id_bp_redirect_raw`（不含 stall 门控）和 `id_bp_redirect`（含门控）
- irom_addr 优先级调整：`flush > stall > redirect > prediction > sequential`
- `id_flush` 仍使用门控版 `id_bp_redirect`，确保 stall 期间不丢指令

```sv
// raw: 快速，仅用于 irom_addr（stall 在上层挡住）
wire id_bp_redirect_raw = id_valid & ~mem_branch_flush
                        & id_bp_btb_hit & (type == BRANCH)
                        & (bht[1] != tournament_taken);

// gated: 安全，用于 id_flush
assign id_bp_redirect = id_bp_redirect_raw & id_ready_go & ex_allowin;

// irom_addr: stall > redirect
irom_addr = mem_flush       ? target :
            !if_allowin_w   ? pc :              // stall 挡住 redirect
            redirect_raw    ? redirect_target :
            bp_taken        ? bp_target :
                              pc + 4;
```

**效果**: IF/ID→IROM 路径从 ~7 级 → **~4 级**，省 ~3 级 LUT（~0.6-0.9ns）。

**安全性验证**: 已完成 8 种场景的全面逻辑验证（正常/stall/flush/DCache 兼容等），所有场景行为与改前一致。

### 优化后 Vivado 结果（@200MHz, ExtraTimingOpt）

| 路径 | 决策 M 后 Slack | **决策 N 后 Slack** | 变化 |
|------|:--------------:|:------------------:|:----:|
| PC → IROM | +0.396 | **+0.435** | +0.039 |
| IF/ID → IROM | +0.583 | **+0.536** | -0.047 |
| BP → IROM | +0.678 | **+0.591** | -0.087 |
| **WNS (全局)** | +0.090 | **+0.062** | -0.028 |

> [!NOTE]
> Slack 变化被 P&R 随机性掩盖（DataPath 因布局变化增大）。
> 逻辑级数减少已反映在 RTL 中，实际 Slack 改善预计在 DCache 减压 DRAM 布线后显现。
> 全局 Top 10 仍全部是 EX/MEM→DRAM 纯布线（0 级逻辑），CPU 逻辑不在瓶颈。

---

## O. DCache DRAM 延迟 Bug 修复

**日期**: 2026-04-24
**状态**: 已修复，FPGA 验证通过（src2 通过）

### 问题

DCache refill FSM 的 `rf_data_valid` 信号使用 `rf_burst_cycle >= 2`，假设 DRAM 读延迟为 1 cycle。
但 DRAM4MyOwn IP 实际配置了 `Register_PortB_Output_of_Memory_Primitives = true`（DOB_REG=1），
读延迟为 **2 cycle**。加上 `dram_rd_addr` 寄存器的 1 cycle，总延迟 = 3 cycle。

DCache 在 `rf_burst_cycle=2` 时就开始采样 `dram_rdata`，但此时 DRAM 的 output register 尚未更新，
读到的是 DOB 寄存器中的**旧值**。结果：每次 refill 的 cache line 数据全错（第一个 word 是垃圾，
后续 word 各偏移 1 位，最后一个 word 丢失）。

### 为什么 current 程序没发现

current 程序的 DRAM 工作集极小（仅 22 个唯一 word），且以栈操作为主。
大量 store → load 的访问模式使得数据主要通过 store forwarding 或 cache hit 获取，
首次 cold miss refill 的错误数据恰好被后续 store 覆盖，未暴露问题。

### 为什么 src2 暴露

src2 工作集大（14,029 个唯一 word），有大量 cold miss 且依赖 refill 拿到的初始数据做计算。

### 修复

```sv
// dcache.sv: rf_data_valid
// 修复前:
assign rf_data_valid = (rf_burst_cycle >= 4'd2) & ...;
// 修复后:
assign rf_data_valid = (rf_burst_cycle >= 4'(DRAM_LATENCY)) & ...;
// DRAM_LATENCY = 3 (registered addr + BRAM read + DOB_REG)
```

### 教训

> 1. IP 配置参数（XCI）是唯一可信来源，代码注释和文档可能过时或错误。
> 2. 涉及时序假设的 localparam 必须与实际硬件 IP 配置保持一致，并通过仿真验证。
> 3. `student_top.sv` 的注释 "无 output register" 与 IP 实际配置不符——已修正注释。
