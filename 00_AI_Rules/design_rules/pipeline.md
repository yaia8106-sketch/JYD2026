# RISC-V 五级流水线控制规范

> 本文档定义本项目处理器的流水线握手协议、stall/flush 控制策略及冒险处理规则。
> 所有 RTL 模块的 spec 编写和代码生成均以本文档为准。
>
> **前提假设**：IROM 和 DRAM 均为同步存储器（BRAM，Vivado IP **不启用**输出寄存器），1 拍延迟——posedge N 采样地址，Clk-to-Q 后 dout 更新。IROM 采用预取方案（`irom_addr` 三路 MUX），IF/ID 寄存器锁存指令。DRAM 数据经 MEM/WB 寄存器传递。

---

## 1. 流水线结构

### 1.1 五级划分与寄存器位置

| **Pre_IF_reg** | 当前 PC 值（复位值 = `0x7FFF_FFFC`，即 text_base - 4） | `if_valid`（正常运行时恒为 1） |
| **IF/ID_reg** | PC + 指令（`id_pc` + `id_inst`，均来自 IF 阶段锁存） | `id_valid` |
| **ID/EX_reg** | 译码后的控制信号 + 操作数 | `ex_valid` |
| **EX/MEM_reg** | ALU 结果 + 存储数据 + 控制信号 | `mem_valid` |
| **MEM/WB_reg** | ALU 结果 + 控制信号 + Load 数据（`wb_dram_dout`） | `wb_valid` |

| 级间逻辑 | 位于 | 主要工作 |
|---------|------|---------|
| IF | Pre_IF_reg → IF/ID_reg | IROM Clk-to-Q 输出指令（1 拍 BRAM，预取方案） |
| ID | IF/ID_reg → ID/EX_reg | 指令译码、寄存器堆读取、立即数生成（使用 `id_inst`） |
| EX | ID/EX_reg → EX/MEM_reg | ALU 运算、分支比较与目标计算 |
| MEM | EX/MEM_reg → MEM/WB_reg | DRAM 读写（1 拍 BRAM，数据经 MEM/WB 寄存器传递） |
| WB | MEM/WB_reg → 寄存器堆 | 寄存器堆写回，Load 数据来自 `wb_dram_dout` |

### 1.2 命名约定

| 术语 | 含义 | 示例 |
|------|------|------|
| **级间寄存器** | 两级之间的流水线寄存器，以前后两级命名 | `if_id_reg`、`id_ex_reg` |
| **级间逻辑** | 两个寄存器之间的组合/时序逻辑 | IF 级逻辑、EX 级逻辑 |
| **上游** | 靠近 IF 的方向 | |
| **下游** | 靠近 WB 的方向 | |

---

## 2. 同步存储器时序分析

### 2.1 BRAM 行为模型（同步 1 拍延迟，无输出寄存器）

本项目使用 Vivado BRAM IP，**不启用输出寄存器**（Output Register = NO）。BRAM 为 **1 拍延迟**：

```verilog
// 同步 1 拍延迟 BRAM 等效行为（无输出寄存器）
always_ff @(posedge clk) begin
    if (we)
        mem[addr] <= wdata;          // 写：在沿处执行
    dout <= mem[addr];               // 读：posedge 采样 addr，Clk-to-Q 后 dout 有效
end
```

关键特性：

1. **1 拍延迟**：posedge N 采样地址 → Clk-to-Q（~2ns）后 dout 有效。dout 在同一周期内稳定。
2. 地址可每拍变化。
3. dout 是寄存器输出（Clk-to-Q），组合路径被切断，但下游有 ~3ns 时间窗口。

```
posedge 1: addr=A → dout 更新为 mem[A]（Clk-to-Q ~2ns 后）
posedge 2: addr=B → dout 更新为 mem[B]
posedge 3: addr=C → dout 更新为 mem[C]
```

### 2.2 IROM 读取时序（预取方案）

IROM 为 1 拍 BRAM。采用**预取方案**：`irom_addr` 提前 1 拍送出下一条指令的地址，IF/ID 寄存器锁存 BRAM 输出的指令。

**地址来源**：三路 MUX

```
irom_addr = branch_flush  ? branch_target :   // 分支：预取目标
            !if_allowin   ? pc :               // 停顿：保持当前地址
                            next_pc;           // 正常：预取下一条
```

**时序推导**（阶段→动作）：

```
pre-IF:  irom_addr（= next_pc）→ BRAM addr_reg 锁存
IF:      BRAM Clk-to-Q → irom_data（= if_inst）有效
IF→ID:   IF/ID 寄存器锁存 if_pc（= pc）和 if_inst（= irom_data）→ id_pc, id_inst
ID:      decoder/imm_gen 使用 id_inst（仅寄存器 Clk-to-Q ~0.3ns）
```

**详细时序**：

```
posedge N:   BRAM 锁存 irom_addr = next_pc（假设 = PC_B）
             Pre_IF_reg <= PC_A（若 if_allowin=1）

Cycle N→N+1: BRAM Clk-to-Q → irom_data = inst_B（PC_B 对应的指令）

posedge N+1: IF/ID_reg 锁存: id_pc <= PC_A, id_inst <= inst_A
             （注：inst_A 是上一拍 BRAM 输出的，与 PC_A 对齐）
             BRAM 锁存 irom_addr = next_pc（= PC_C）
             Pre_IF_reg <= PC_B

→ posedge N+1 之后：id_pc = PC_A, id_inst = inst_A → 天然对齐 ✓
```

**PC 复位值**：`0x7FFF_FFFC`（= text_base - 4），使首拍 `next_pc = 0x8000_0000`。

**分支 flush 时序**：

```
Cycle N:    EX 检测分支 → flush=1, irom_addr = branch_target, IF/ID.valid ← 0
Cycle N+1:  BRAM Clk-to-Q 出目标指令, ID=bubble, EX=bubble（第1拍气泡）
Cycle N+2:  IF/ID 锁存目标指令(id_valid=1), EX=bubble（第2拍气泡）
Cycle N+3:  目标指令进入 EX，恢复正常执行
```

**load-use stall 时序**：

```
Cycle N:    stall 检测, if_allowin=0, irom_addr = pc（保持当前地址）
            BRAM 持续输出 inst[pc]，IF/ID 寄存器保持不变
Cycle N+k:  stall 解除, if_allowin=1, irom_addr = next_pc
            IF/ID 锁存: id_pc = pc, id_inst = inst[pc] → 正确 ✓
```

**结论**：
- 仍然是 **5 级流水线**，IF 阶段 **1 个周期**，CPI ≈ 1
- BRAM 1 拍延迟通过预取方案吸收（`irom_addr` 提前 1 拍送出）
- IF/ID 寄存器同时锁存 PC 和指令，ID 阶段无 BRAM 时序压力
- **代价**：`irom_addr` MUX 在 BRAM 地址建立时间的关键路径上

### 2.3 DRAM 时序

DRAM 为 1 拍 BRAM（无 Output Register）。Load 和 Store **统一使用 EX 级 ALU 组合逻辑输出**作为 DRAM 地址。DRAM 使用 **Single Port BRAM**。

```
EX 级 ALU 输出 (组合逻辑)
       │
       ├──→ DRAM 地址端口（读/写共用，Single Port）
       │
       └──→ EX/MEM_reg（在 posedge 锁存）

EX 级 rs2 数据 (经前递)
       └──→ DRAM 写数据端口

写使能：ex_valid & ex_mem_write_en
```

**Load 指令时序**（阶段→动作）：

```
EX:       ALU 输出 = ADDR → 直连 DRAM 地址端口
EX→MEM:   posedge 锁存 ADDR → BRAM 读取 mem[ADDR]
MEM:      BRAM Clk-to-Q → dram_dout 有效（~3.5ns）
MEM→WB:   MEM/WB 寄存器锁存 dram_dout → wb_dram_dout
WB:       wb_dram_dout → mem_interface → wb_mux → 写回 regfile
```

**Store 指令时序**：

```
EX→MEM:   posedge 锁存 ADDR + wdata + wea → BRAM 执行写入
（Store 在 posedge 即完成写入，MEM/WB 级只是空过）
```

**结论**：
- Load 和 Store 都只需 **1 个 MEM 周期**，无需 stall
- Load 数据经 MEM/WB 寄存器传递（`wb_dram_dout`），不直接从 BRAM dout 读取
- Store 写使能门控：`ex_valid & ex_mem_write_en`，防止气泡产生假写入

### 2.4 同步存储器的关键路径总结

| 存储器 | 地址来源 | posedge 前的关键路径 | 流水线周期数 |
|--------|---------|--------------------|----|
| IROM | `irom_addr` 三路 MUX（组合） | branch_target / pc / next_pc MUX → 地址建立时间 | 1（预取吸收） |
| DRAM（读）| EX 级 ALU 输出（组合） | ALU 运算 → 地址建立时间 | 1（MEM/WB 寄存器捕获） |
| DRAM（写）| EX 级 ALU 输出（组合） | ALU 运算 → 地址建立时间 | 1（写在 posedge 完成） |

> **注**：DRAM 为 Single Port BRAM。同一时刻只有一条指令在 EX，不存在端口冲突。

---

## 3. 握手信号定义

每级流水线使用三个控制信号进行握手：**valid**、**allowin**、**ready_go**。

### 3.1 信号总览

| 信号 | 类型 | 归属 | 方向 | 含义 |
|------|------|------|------|------|
| `xx_valid` | 寄存器 | 级间寄存器 | 向本级逻辑输出 | 本级数据是否有效 |
| `xx_ready_go` | 组合 | 本级逻辑 | 向下游输出 | 本级计算是否完成 |
| `xx_allowin` | 组合 | 级间寄存器 | 向上游输出 | 本级的级间寄存器是否允许写入新数据 |

### 3.2 信号详解

**valid**：寄存在级间寄存器中，标识数据是否有效。`valid = 0` 时为气泡，不产生任何副作用。

**ready_go**：本级逻辑产生的组合信号，表示计算完成。
- 单周期操作（普通 ALU）：`ready_go = 1`
- 多周期操作（乘除法）：由 `done` 驱动
- 访存操作（cache miss）：由存储器应答驱动

**allowin**：本级控制逻辑产生的组合信号，表示"我可以接受上游的新数据"。

### 3.3 信号命名对照

| 本文档 | 常见替代命名 | 改名理由 |
|-------|------------|---------|
| `allowin` | `ready` | 避免与 AXI 总线 ready 混淆，语义更清晰 |
| `ready_go` | `readygo` | 统一 snake_case |

---

## 4. 握手逻辑公式

### 4.1 allowin 公式

```
xx_allowin = !xx_valid || (xx_ready_go & next_allowin)
```

含义：本级为空（可直接接受），或者本级数据可以向下流走（本级完成 + 下游允许）。

展开到每一级：

```verilog
// Pre_IF_reg 的 allowin（IF 阶段是否允许 PC 更新）
assign if_allowin  = !if_valid  || (if_ready_go  & id_allowin);
// 因为 if_valid 正常运行时恒为 1，简化为：
// assign if_allowin = if_ready_go & id_allowin;

// IF/ID_reg
assign id_allowin  = !id_valid  || (id_ready_go  & ex_allowin);

// ID/EX_reg
assign ex_allowin  = !ex_valid  || (ex_ready_go  & mem_allowin);

// EX/MEM_reg
assign mem_allowin = !mem_valid || (mem_ready_go & wb_allowin);

// MEM/WB_reg（最后一级，无下游反压）
assign wb_allowin  = !wb_valid  || wb_ready_go;
// wb_ready_go 通常恒为 1，所以 wb_allowin = 1
```

### 4.2 握手成功条件

```verilog
// 上一级的数据可以向下游流动
assign prev_to_xx_handshake = prev_valid & prev_ready_go;

// 本级实际接收数据
assign xx_accept = prev_to_xx_handshake & xx_allowin;
```

### 4.3 各级 ready_go 默认值

| 级 | 默认值 | 可能为 0 的场景 |
|----|-------|----------------|
| IF | `1` | BRAM 延迟已被流水线吸收，无需 stall。icache miss（若有 cache） |
| ID | `1` | load-use 冒险（见第 9.2 节） |
| EX | `1` | M 扩展乘除法未完成；F 扩展浮点运算未完成 |
| MEM | `1` | BRAM 延迟已被流水线吸收，无需 stall。dcache miss（若有 cache） |
| WB | `1` | 恒高 |

---

## 5. 级间寄存器更新规则

### 5.1 通用模板

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        xx_valid <= 1'b0;
        xx_data  <= '0;
    end else if (xx_flush) begin
        // 优先级 1：flush —— 无条件清除
        xx_valid <= 1'b0;
    end else if (xx_allowin) begin
        // 优先级 2：接受上游数据（或气泡）
        xx_valid <= prev_valid & prev_ready_go;
        xx_data  <= prev_stage_output;
    end
    // 优先级 3（隐含）：!allowin —— stall，保持不变
end
```

> **注**：在当前架构中，`xx_flush` 仅适用于 IF/ID_reg（`id_flush`）和 ID/EX_reg（`ex_flush`）。EX/MEM_reg 和 MEM/WB_reg 不接受 branch_flush（见第 8 节）。若后续支持异常/中断，MEM/WB 可能需要独立的 flush 信号。

### 5.2 Pre_IF_reg（特殊处理）

Pre_IF_reg（原 PC_reg）不完全遵循通用模板，因为它还受到 flush 和分支预测的影响：

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pc <= 32'h7FFF_FFFC;    // text_base - 4，预取方案首拍 next_pc = 0x8000_0000
    end else if (branch_flush) begin
        // 优先级 1：flush —— 跳转到正确目标（无视 stall）
        pc <= correct_target;
    end else if (if_allowin) begin
        // 优先级 2：正常推进
        pc <= next_pc;
    end
    // 优先级 3：stall，PC 保持不变
end
```

**`next_pc` 的来源**（无 flush 时）：

```verilog
assign next_pc = bp_taken ? bp_target : pc + 4;
// bp_taken / bp_target 来自分支预测器（若有），否则 next_pc = pc + 4
```

> **关键**：`irom_addr` 由三路 MUX 生成（`branch_target / pc / next_pc`），与 Pre_IF_reg 在同一 posedge 采样。这是预取方案的核心机制（见第 2.2 节）。正常时 `irom_addr = next_pc`，stall 时 `irom_addr = pc`，flush 时 `irom_addr = branch_target`。

### 5.3 IF/ID_reg 到 MEM/WB_reg

```verilog
// ----- IF/ID_reg -----
// 存储 PC 和指令。指令来自 IROM BRAM Clk-to-Q（预取方案）。
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        id_valid <= 1'b0;
        id_pc    <= 32'd0;
        id_inst  <= 32'd0;
    end else if (id_flush) begin
        id_valid <= 1'b0;
    end else if (id_allowin) begin
        id_valid <= if_valid & if_ready_go;
        id_pc    <= pc;          // Pre_IF_reg 的当前值
        id_inst  <= irom_data;   // BRAM Clk-to-Q 输出（与 pc 对齐）
    end
end
// ID 组合逻辑使用：id_pc + id_inst（均来自 IF/ID 寄存器）

// ----- ID/EX_reg -----
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         ex_valid <= 1'b0;
    else if (ex_flush)  ex_valid <= 1'b0;
    else if (ex_allowin) begin
        ex_valid <= id_valid & id_ready_go;
        // ex_alu_op, ex_src1, ex_src2, ex_rd, ... <= ID 级输出
    end
end

// ----- EX/MEM_reg -----
// 注意：分支 flush 不清除 EX/MEM_reg（分支指令本身需要正常流过）
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mem_valid <= 1'b0;
    else if (mem_allowin) begin
        mem_valid <= ex_valid & ex_ready_go;
        // mem_alu_result, mem_rd, mem_store_data, ... <= EX 级输出
    end
end

// ----- MEM/WB_reg -----
// 存储 ALU 结果、控制信号和 Load 数据（wb_dram_dout）。
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb_valid <= 1'b0;
    else if (wb_allowin) begin
        wb_valid       <= mem_valid & mem_ready_go;
        wb_alu_result  <= mem_alu_result;
        wb_dram_dout   <= perip_rdata;    // DRAM/MMIO 读数据（MEM 阶段有效）
        // wb_rd, wb_reg_write, wb_is_load, ... <= MEM 级输出
    end
    // WB 级通常不需要 flush
end
// WB 写回 MUX：
// assign wb_write_data = wb_is_load ? wb_dram_dout : wb_alu_result;
```

### 5.4 更新优先级速查表

| 优先级 | 条件 | 行为 |
|-------|------|------|
| 1（最高） | `rst_n = 0` | 全部清零 |
| 2 | `xx_flush = 1` | 清除 valid |
| 3a | `xx_allowin = 1` 且上游握手成功 | 接收有效数据 |
| 3b | `xx_allowin = 1` 且上游握手未成功 | 写入 `valid = 0`（气泡） |
| 4（最低） | `xx_allowin = 0` | 锁存不变（stall） |

---

## 6. 正常流水

所有级 `ready_go = 1` 且无 stall/flush 时，数据每周期逐级流动：

```
Pre_IF   IF/ID(pc+inst)  ID/EX   EX/MEM  MEM/WB(+dram)  Cycle
pc_F     pc_E+inst_E     inst_D  inst_C  inst_B+data_B  1
pc_G     pc_F+inst_F     inst_E  inst_D  inst_C+data_C  2
pc_H     pc_G+inst_G     inst_F  inst_E  inst_D+data_D  3
（IF/ID 存 PC+指令；MEM/WB 存控制信号+ALU结果+Load数据）
```

所有级 `valid = 1`，所有级 `allowin = 1`，CPI ≈ 1。

---

## 7. Stall（阻塞）

### 7.1 产生原因

| 场景 | 位置 | 受影响的 ready_go |
|------|------|-----------------|
| 乘除法（M 扩展） | EX | `ex_ready_go = 0` |
| 浮点运算（F 扩展） | EX | `ex_ready_go = 0` |
| dcache miss | MEM | `mem_ready_go = 0` |
| icache miss | IF | `if_ready_go = 0` |
| Load-Use 冒险 | ID | `id_ready_go = 0`（见第 9.2 节）|

### 7.2 传播机制

stall **只向上游传播**，下游不受影响。

以 EX 级 stall 为例：

```
ex_allowin  = !1 || (0 & mem_allowin) = 0    ← EX 拒绝
id_allowin  = !1 || (1 & 0) = 0              ← ID 被级联阻塞
if_allowin  = !1 || (1 & 0) = 0              ← IF 被级联阻塞（PC 锁存）
mem_allowin = 正常值                           ← MEM 及下游不受影响
```

### 7.3 自动气泡

当 `xx_allowin = 1` 但上游 `prev_valid & prev_ready_go = 0` 时，本级自动写入 `valid = 0`。

气泡是握手机制的自然产物，**不需要手动抹除**。

EX 级 stall 示例：

```
Pre_IF  IF/ID   ID/EX       EX/MEM  MEM/WB  Cycle
pc_C    inst_B  inst_A(mul) inst_D  inst_E  1     ex_ready_go=0
pc_C    inst_B  inst_A(mul) bubble  inst_D  2     MEM 收到气泡
pc_C    inst_B  inst_A(mul) bubble  bubble  3     假设乘法仍未完成
pc_C    inst_B  inst_A(mul) bubble  bubble  4     乘法完成，ex_ready_go=1
pc_D    inst_C  inst_B      inst_A  bubble  5     恢复流动
```

---

## 8. Flush（冲刷）

### 8.1 flush 的时序本质

flush 信号由 EX 级的**组合逻辑**产生，在**下一个 posedge** 才生效。理解这一点是分析 flush 范围的关键：

```
cycle N:      EX 级组合逻辑计算出 branch_flush = 1（分支预测失败）
              此时 EX 级的数据来自 ID/EX_reg（即分支指令本身）

posedge N+1:  flush 生效——
              Pre_IF_reg ← correct_target（重定向）
              IF/ID_reg  ← valid = 0（flush 掉错误路径指令）
              ID/EX_reg  ← valid = 0（flush 掉错误路径指令）
              EX/MEM_reg ← 分支指令本身的数据（正常流入，不被 flush）
```

**分支指令本身在 flush 生效的那个 posedge 自然流入了 EX/MEM_reg**，然后正常经过 MEM → WB 完成写回。因此 JAL/JALR 的 link 地址写回（rd = pc+4）**完全不受 flush 影响**，无需任何特殊处理。

### 8.2 分支预测失败时的 flush 范围

| 寄存器 | flush? | 理由 |
|--------|--------|------|
| Pre_IF_reg | ✅ | 更新为正确跳转目标 |
| IF/ID_reg (`id_valid`) | ✅ | 分支指令之后取的错误路径指令 |
| ID/EX_reg (`ex_valid`) | ✅ | 分支指令之后译码的错误路径指令 |
| EX/MEM_reg (`mem_valid`) | ❌ | 分支指令本身在此 posedge 正常流入，需要继续执行 |
| MEM/WB_reg (`wb_valid`) | ❌ | 更早的正确路径指令 |

### 8.3 Flush 代价分析

分支在 EX 级判断，默认顺序执行（预测不跳转）。预测错误时 flush 代价为 **2 拍气泡**。

冲刷 2 条指令：IF/ID 中的错误指令 + BRAM 正在取的下一条错误指令。

```
Cycle N:    EX 检测分支 → flush=1（组合逻辑）
            irom_addr = branch_target（三路 MUX 最高优先级）
            EX/MEM_reg ← 分支指令本身（正常流入）

posedge N+1: flush 生效——
            Pre_IF_reg ← branch_target
            BRAM 锁存 branch_target 地址
            IF/ID_reg.valid ← 0（气泡）
            ID/EX_reg.valid ← 0（气泡）

Cycle N+1:  BRAM Clk-to-Q → 目标指令有效
            ID = bubble, EX = bubble（第1拍气泡）

posedge N+2: IF/ID 锁存目标指令
            IF/ID_reg.valid ← 1（恢复有效）

Cycle N+2:  ID = 目标指令, EX = bubble（第2拍气泡）

Cycle N+3:  目标指令进入 EX，恢复正常执行
```

**结论**：
- Flush 代价 = **2 拍**（Cycle N+1 和 N+2，EX 级为 bubble）
- BRAM 旧输出被 IF/ID.valid = 0 屏蔽，**不需要额外的 BRAM flush 机制**
- 所有副作用操作经过 valid gating，气泡不产生任何副作用

### 8.4 flush 信号连接

```verilog
assign branch_flush = ex_valid & is_branch_or_jump
                    & (predicted_taken != actual_taken
                     | predicted_target != actual_target);

// flush 清除 IF/ID 和 ID/EX 两个级间寄存器
assign id_flush = branch_flush;   // 清除 IF/ID_reg 中的 id_valid
assign ex_flush = branch_flush;   // 清除 ID/EX_reg 中的 ex_valid
// EX/MEM_reg 和 MEM/WB_reg：不被 flush
```

PC 更新见第 5.2 节：flush 时 `pc <= correct_target`，优先级高于 stall。

### 8.5 副作用屏蔽（valid gating）

所有有副作用的操作必须经过 valid 门控：

```verilog
assign reg_write_en_actual = wb_valid  & wb_reg_write_en;
assign mem_write_en_actual = ex_valid  & ex_mem_write_en;   // Store 在 EX 级写入 DRAM
assign csr_write_en_actual = wb_valid  & wb_csr_write_en;   // 若支持
```

flush 只需清零 valid，所有副作用自动被屏蔽。

### 8.6 Stall 与 Flush 并发

**flush 优先级 > stall 优先级**。

在当前架构中，branch_flush 由 EX 级自身产生，所以“EX 级做乘除法时被 flush”这种场景**不会发生**（EX 级正在执行的是分支指令，不是乘除法）。

但若后续支持**异常/中断**（在 MEM/WB 级触发 flush），则可能出现 EX 级多周期运算被 flush 的情况。此时多周期运算单元需要收到 `cancel` 信号以回到空闲态。

---

## 9. 数据冒险处理

### 9.1 前递 / 旁路（Forwarding）

前递源优先级（高 → 低）：EX > MEM > WB > 寄存器堆

```verilog
// ---- Step 1: 并行匹配检测 ----
assign ex_match  = ex_valid  & ex_reg_write  & (ex_rd  != 0) & (ex_rd  == id_rs);
assign mem_match = mem_valid & mem_reg_write & !mem_is_load & (mem_rd != 0) & (mem_rd == id_rs);
assign wb_match  = wb_valid  & wb_reg_write  & (wb_rd  != 0) & (wb_rd  == id_rs);

// ---- Step 2: 优先级编码（并行，one-hot）----
assign sel_ex  = ex_match;
assign sel_mem = mem_match & ~ex_match;
assign sel_wb  = wb_match  & ~ex_match & ~mem_match;
assign sel_rf  = ~ex_match & ~mem_match & ~wb_match;

// ---- Step 3: 4:1 MUX（并行 AND-OR）----
assign forward_data = ({32{sel_ex}}  & ex_alu_result)
                    | ({32{sel_mem}} & mem_alu_result)
                    | ({32{sel_wb}}  & wb_write_data)
                    | ({32{sel_rf}}  & rf_read_data);
```

> **关键**：必须检查 valid 信号，气泡的数据不应参与前递。
>
> **注**：寄存器堆采用 **read-first** 架构——WB 写和 ID 读同一寄存器时，ID 读到旧值。因此前递 MUX 需要 WB 级前递路径来处理 WB→ID 的数据旁路。

### 9.2 Load-Use 冒险

Load 指令的结果（`wb_dram_dout`）要到 **WB 级**才可用（DRAM 数据在 MEM 阶段 Clk-to-Q 有效，经 MEM/WB 寄存器传递到 WB）。因此当 Load 尚未到达 WB 时，ID 级无法通过前递拿到 Load 数据，必须 stall。

**核心思想**：不是固定"stall N 拍"，而是 `id_ready_go` 持续检测"当前 ID 级的数据依赖能否被前递解决"。只要依赖的 Load 还没到达 WB（即仍在 EX 或 MEM），前递无法提供数据，`id_ready_go = 0`。

**检测**（在 ID 级）：

```verilog
// Load 在 EX：数据要到 WB 才有，还差 2 级
assign load_in_ex  = ex_valid  & ex_mem_read  & (ex_rd  != 0)
                   & ((ex_rd  == id_rs1) | (ex_rd  == id_rs2));

// Load 在 MEM：wb_dram_dout 还没更新，还差 1 级
assign load_in_mem = mem_valid & mem_is_load  & (mem_rd != 0)
                   & ((mem_rd == id_rs1) | (mem_rd == id_rs2));

assign load_use_hazard = load_in_ex | load_in_mem;
assign id_ready_go     = !load_use_hazard;
```

**时序示例**：

```
cycle 0: LW 在 EX, ADD 在 ID → load_in_ex=1  → stall
cycle 1: LW 在 MEM, ADD 在 ID → load_in_mem=1 → stall
cycle 2: LW 在 WB, ADD 在 ID → load_in_ex=0, load_in_mem=0 → id_ready_go=1, WB 前递 wb_dram_dout
cycle 3: ADD 进入 EX（携带正确的 Load 数据）
```

> **注**：MEM 级前递显式排除 Load 指令（`!mem_is_load`），因为 MEM 级的 `mem_alu_result` 是 Load 的**地址**而非**数据**。Load 数据只能通过 WB 级前递（`wb_write_data = wb_dram_dout`）获取。

### 9.3 WAW / WAR 冒险

顺序单发射流水线中不存在 WAW/WAR 冒险。

---

## 10. 信号连接总览

```
 irom_addr(3路MUX) ──→ IROM(1拍BRAM)     EX ALU out ──→ DRAM addr (1拍BRAM)
  ↑ branch_target                              │
  ↑ pc (stall时)                               ▼
  ↑ next_pc (正常)                        perip_bridge
       ▼                                       │
  Pre_IF_reg ─→ [IF] ─→ IF/ID ─→ [ID] ─→ ID/EX ─→ [EX] ─→ EX/MEM ─→ [MEM] ─→ MEM/WB ─→ [WB]
       ↑        ↑  ↑          │  ▲                │    ↑                  │    ↑
       │     irom  id_inst    │  │                │    │                  │    │
       │     data  (寄存器)   │  │                │    │    wb_dram_dout  │    │
       │              ┌ flush ┘  │                │    │    (经MEM/WB寄存器) │    │
       │              │(清IF/ID  │                │    │                  │    │
       │              │  ID/EX)  │                │    │                  │    │
       └── branch_target        │  ←── EX 前递 ──┘    │                  │    │
                                │  ←── MEM 前递 ──────┘                  │    │
                                │  ←── WB 前递 ──────────────────────────┘    │
                           [前递 MUX]                                    [写回 MUX]
```

---

## 11. 设计检查清单

### 存储器时序
- [x] IROM 为 1 拍 BRAM（无 Output Register），预取方案取指
- [x] `irom_addr` 三路 MUX：`branch_flush > !if_allowin > default`
- [x] IF/ID_reg 存指令（`id_inst`）和 PC（`id_pc`），天然对齐
- [x] DRAM 为 1 拍 BRAM（无 Output Register），Single Port
- [x] DRAM 写使能门控：`ex_valid & ex_mem_write_en`
- [x] MEM/WB_reg 存 Load 数据（`wb_dram_dout`），经寄存器传递
- [x] PC 复位值 = `0x7FFF_FFFC`（text_base - 4，预取方案需要）

### 握手机制
- [x] Pre_IF_reg 参与 allowin 链（`if_allowin` 控制 PC 是否更新）
- [x] allowin 从 WB 反向传播到 PC，共 5 级
- [x] WB 级 `allowin` 恒为 1
- [x] allowin 链无组合逻辑环路（ready_go 不依赖 allowin）

### Stall
- [x] Load-Use 冒险检测 EX 和 MEM 两级（Load 在 EX 或 MEM 时 `id_ready_go = 0`）
- [x] stall 时 `irom_addr = pc`（保持当前地址，不预取 next_pc）
- [ ] 多周期运算正确驱动 `ex_ready_go`（M 扩展，待实现）
- [ ] 多周期运算被 flush 时收到 `cancel` 信号（待实现）

### Flush
- [x] 分支失败时清除 IF/ID_reg 和 ID/EX_reg 的 valid（EX/MEM_reg 不清除）
- [x] flush 同时将 PC 更新为正确地址（优先级高于 stall）
- [x] flush 时 `irom_addr = branch_target`，BRAM 立即锁存正确地址
- [x] Flush 代价 = 2 拍气泡
- [x] 所有副作用信号经过 valid gating

### 前递
- [x] 前递逻辑检查来源级的 valid
- [x] 优先级：EX > MEM > WB > 寄存器堆
- [x] MEM 级前递排除 Load 指令（`!mem_is_load`）
- [x] `rd == x0` 不触发前递

### 验证状态
- [x] Vivado 行为仿真：37 个指令测试全通过
- [x] FPGA 烧录验证通过（50MHz）