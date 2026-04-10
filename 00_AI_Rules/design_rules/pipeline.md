# RISC-V 五级流水线控制规范

> 本文档定义本项目处理器的流水线握手协议、stall/flush 控制策略及冒险处理规则。
> 所有 RTL 模块的 spec 编写和代码生成均以本文档为准。
>
> **前提假设**：IROM 和 DRAM 均为同步存储器（BRAM，Vivado IP 启用输出寄存器），内部为两级流水线结构——posedge N 采样地址，posedge N+1 输出寄存器锁存数据（dout 更新）。地址端口可每周期变化，无需保持。

---

## 1. 流水线结构

### 1.1 五级划分与寄存器位置

| **Pre_IF_reg** | 当前 PC 值 | `if_valid`（正常运行时恒为 1） |
| **IF/ID_reg** | PC（来自 Pre_IF_reg）。注：指令不存于此寄存器，由 IROM dout（BRAM 输出寄存器）直接提供 | `id_valid` |
| **ID/EX_reg** | 译码后的控制信号 + 操作数 | `ex_valid` |
| **EX/MEM_reg** | ALU 结果 + 存储数据 + 控制信号 | `mem_valid` |
| **MEM/WB_reg** | ALU 结果 + 控制信号。注：Load 数据不存于此寄存器，由 DRAM dout（BRAM 输出寄存器）直接提供给 WB 写回 MUX | `wb_valid` |

| 级间逻辑 | 位于 | 主要工作 |
|---------|------|---------|
| IF | Pre_IF_reg → IF/ID_reg | IROM 读取指令（BRAM 两级流水线，延迟被流水线吸收） |
| ID | IF/ID_reg → ID/EX_reg | 指令译码、寄存器堆读取、立即数生成 |
| EX | ID/EX_reg → EX/MEM_reg | ALU 运算、分支比较与目标计算 |
| MEM | EX/MEM_reg → MEM/WB_reg | DRAM 读写（BRAM 两级流水线，Load 延迟被流水线吸收） |
| WB | MEM/WB_reg + DRAM dout → 寄存器堆 | 寄存器堆写回（无下游级间寄存器） |

### 1.2 命名约定

| 术语 | 含义 | 示例 |
|------|------|------|
| **级间寄存器** | 两级之间的流水线寄存器，以前后两级命名 | `if_id_reg`、`id_ex_reg` |
| **级间逻辑** | 两个寄存器之间的组合/时序逻辑 | IF 级逻辑、EX 级逻辑 |
| **上游** | 靠近 IF 的方向 | |
| **下游** | 靠近 WB 的方向 | |

---

## 2. 同步存储器时序分析

### 2.1 BRAM 行为模型（同步两周期延迟，带输出寄存器）

本项目使用 Vivado BRAM IP，**启用输出寄存器**（Output Register = YES）。BRAM 内部为**两级流水线**结构：

```verilog
// 同步两周期延迟 BRAM 等效行为（带输出寄存器）
logic [DATA_WIDTH-1:0] mem_rd_internal;

always_ff @(posedge clk) begin
    if (we)
        mem[addr] <= wdata;          // 写：在沿处执行
    mem_rd_internal <= mem[addr];    // 第 1 级：posedge N 采样 addr，读取阵列
end

always_ff @(posedge clk) begin
    dout <= mem_rd_internal;         // 第 2 级：posedge N+1 输出寄存器锁存
end
```

关键特性：

1.两级流水线：posedge N 采样地址 → posedge N+1 dout 更新。dout 在 posedge N+1 之后才作为稳定的寄存器输出可用。
2.地址可每拍变化：两级之间互不干扰。每个 posedge 都可接受新地址，dout 始终输出两拍前地址对应的数据。
3.dout 是寄存器输出：组合路径被切断，下游逻辑有充足时间。

posedge 1: addr=A → stage1 读 mem[A]
posedge 2: addr=B → stage1 读 mem[B], stage2 输出 dout=mem[A]
posedge 3: addr=C → stage1 读 mem[C], stage2 输出 dout=mem[B]
posedge 4: addr=D → stage1 读 mem[D], stage2 输出 dout=mem[C]

核心观察：BRAM 内部是一条独立的两级流水线。只要正确对齐上游寄存器和 BRAM 输出寄存器的时序，两周期延迟可被处理器流水线完全吸收，不引入额外 stall。

### 2.2 IROM 读取时序

**地址来源**：`next_pc`（组合逻辑）同时送给 IROM 地址端口和 Pre_IF_reg：

```
         next_pc (组合逻辑)
            │
            ├──→ IROM 地址端口    ← 两者在同一个 posedge 采样同一个值
            │
            └──→ Pre_IF_reg（在 posedge 锁存）
```

**时序推导**（BRAM 两级流水线 + Pre_IF_reg 自然对齐）：

```
posedge N:   IROM stage1 采样 next_pc = PC_A
             Pre_IF_reg <= PC_A

posedge N+1: IROM stage2: dout 更新为 inst_A
             IF/ID_reg 采样 Pre_IF_reg（更新前）= PC_A ✓
             Pre_IF_reg <= PC_B（更新为下一个地址）
             IROM stage1 采样 next_pc = PC_B

→ posedge N+1 之后：IF/ID_reg.pc = PC_A，IROM dout = inst_A
  两者自然对齐，ID 组合逻辑同时拿到 PC 和指令 ✓
```

**关键**：Pre_IF_reg 比 IROM dout 早 1 拍更新。在 posedge N+1 时，IF/ID_reg 采样的是 Pre_IF_reg 的**旧值**（更新前 = PC_A），而 IROM dout 恰好也更新为 PC_A 对应的 inst_A。两者自然同步，无需中间寄存器。

**结论**：
- 仍然是 **5 级流水线**，IF 阶段 **1 个周期**，CPI ≈ 1
- BRAM 两周期延迟被流水线完全吸收（Pre_IF_reg 充当了延迟对齐角色）
- **代价**：next_pc 的计算逻辑（PC+4 / 分支预测目标 / flush 目标的 MUX）在 IROM 地址**建立时间**的关键路径上（posedge 前必须稳定）
- IROM dout 是寄存器输出，组合路径被切断，下游 ID 逻辑有充足时间

### 2.3 DRAM 时序

Load 和 Store **统一使用 EX 级 ALU 组合逻辑输出**作为 DRAM 地址，在同一个 posedge（EX→MEM 边界）采样。由于同一时刻只有一条指令在 EX 级，DRAM 使用 **Single Port BRAM** 即可，无需双端口。

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

**Load 指令时序**：

```
posedge N (EX→MEM):
    BRAM 采样 ALU 输出 = ADDR，we=0
    stage1 读取 mem[ADDR]
    EX/MEM_reg 捕获 {rd, ctrl, is_load}

posedge N+1 (MEM→WB):
    BRAM stage2: dout 更新为 load_data
    MEM/WB_reg 采样 EX/MEM_reg = {rd, ctrl, is_load} ✓

→ posedge N+1 之后：MEM/WB_reg 和 DRAM dout 自然对齐
  WB 写回 MUX 根据 is_load 选择 dram_dout ✓
```

**Store 指令时序**：

```
posedge N (EX→MEM):
    BRAM 采样 ALU 输出 = ADDR，wdata = rs2，we=1
    BRAM 执行写入 mem[ADDR] ← rs2
    EX/MEM_reg 捕获（Store 不需要写回，reg_write_en=0）

（Store 在 posedge 即完成写入，MEM/WB 级只是空过）
```

**结论**：
- Load 和 Store 都只需 **1 个 MEM 周期**，无需 stall
- DRAM 使用 **Single Port BRAM**（地址端口读/写共用），因为同一时刻只有一条指令在 EX，不存在端口冲突
- Store 写使能门控：`ex_valid & ex_mem_write_en`，防止气泡产生假写入

### 2.4 同步存储器的关键路径总结

| 存储器 | 地址来源 | posedge 前的关键路径 | 流水线周期数 |
|--------|---------|--------------------|----|
| IROM | `next_pc`（组合逻辑） | next_pc MUX → 地址建立时间 | 1（延迟被吸收） |
| DRAM（读）| EX 级 ALU 输出（组合逻辑） | ALU 运算 → 地址建立时间 | 1（延迟被吸收） |
| DRAM（写）| EX 级 ALU 输出（组合逻辑） | ALU 运算 → 地址建立时间 | 1（写在 posedge 完成） |

> **注**：DRAM 为 Single Port BRAM。Load 和 Store 统一使用 EX 级 ALU 输出作为地址，在 EX→MEM 边界的 posedge 采样。同一时刻只有一条指令在 EX，不存在端口冲突。

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
        pc <= RESET_VECTOR;
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

> **关键**：`next_pc` 同时送给 Pre_IF_reg **和** IROM 地址端口。两者在同一个 posedge 采样同一个值，这是 BRAM 两周期延迟被流水线吸收的核心机制（见第 2.2 节）。

### 5.3 IF/ID_reg 到 MEM/WB_reg

```verilog
// ----- IF/ID_reg -----
// 注意：IF/ID_reg 只存 PC 和 valid，不存指令。
// 指令由 IROM dout（BRAM 输出寄存器）直接提供给 ID 组合逻辑。
// IF/ID_reg.pc 和 IROM dout 在同一个 posedge 更新，自然对齐。
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         id_valid <= 1'b0;
    else if (id_flush)  id_valid <= 1'b0;
    else if (id_allowin) begin
        id_valid <= if_valid & if_ready_go;
        id_pc    <= pc;          // Pre_IF_reg 的当前值（与 IROM dout 对齐）
    end
end
// ID 组合逻辑使用：IF/ID_reg.id_pc + irom_dout（直接来自 BRAM 输出寄存器）

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
// 注意：MEM/WB_reg 只存控制信号和 ALU 结果，不存 Load 数据。
// Load 数据由 DRAM dout（BRAM 输出寄存器）直接提供给 WB 写回 MUX。
// MEM/WB_reg 和 DRAM dout 在同一个 posedge 更新，自然对齐。
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wb_valid <= 1'b0;
    else if (wb_allowin) begin
        wb_valid      <= mem_valid & mem_ready_go;
        wb_alu_result <= mem_alu_result;
        // wb_rd, wb_reg_write, wb_is_load, ... <= MEM 级输出
    end
    // WB 级通常不需要 flush
end
// WB 写回 MUX：
// assign wb_write_data = wb_is_load ? dram_dout : wb_alu_result;
// dram_dout 直接来自 BRAM 输出寄存器，与 MEM/WB_reg 自然对齐
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
Pre_IF   IF/ID        ID/EX   EX/MEM  MEM/WB  IROM_dout  DRAM_dout  Cycle
pc_F     pc_E         inst_D  inst_C  inst_B  inst_E     data_B     1
pc_G     pc_F         inst_E  inst_D  inst_C  inst_F     data_C     2
pc_H     pc_G         inst_F  inst_E  inst_D  inst_G     data_D     3
（IF/ID 存 PC，指令由 IROM dout 提供；MEM/WB 存控制信号，Load 数据由 DRAM dout 提供）
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

```
cycle N:      EX 级发现分支预测错误，branch_flush = 1（组合逻辑）
              此时 IROM 流水线中：stage1 正在读 PC_wrong2，stage2 正在输出 inst_wrong1

posedge N+1:  flush 生效——
              Pre_IF_reg <- correct_target
              IROM stage1 采样 correct_target（新地址）
              IF/ID_reg.valid <- 0（气泡，屏蔽 IROM dout 上的 inst_wrong1）
              ID/EX_reg.valid <- 0（气泡）
              EX/MEM_reg <- 分支指令本身（正常流入）

posedge N+2:  IROM stage2 输出 inst(correct_target)（正确指令到达 dout）
              IF/ID_reg 采样 Pre_IF_reg = correct_target
              IF/ID_reg.valid <- if_valid & if_ready_go（恢复有效）

posedge N+3:  ID 阶段使用第一条正确指令
```

**结论**：
- Flush 代价 = **2 拍**（posedge N+1 和 posedge N+2 产生气泡）
- IROM BRAM 流水线中残留的错误指令通过 IF/ID_reg.valid = 0 自然屏蔽，**不需要额外的 BRAM flush 机制**
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

Load 指令的结果（dram_dout）要到 **WB 级**才可用（BRAM 输出寄存器在 MEM→WB 的 posedge 才更新）。因此当 Load 尚未到达 WB 时，ID 级无法通过前递拿到 Load 数据，必须 stall。

**核心思想**：不是固定"stall N 拍"，而是 `id_ready_go` 持续检测"当前 ID 级的数据依赖能否被前递解决"。只要依赖的 Load 还没到达 WB（即仍在 EX 或 MEM），前递无法提供数据，`id_ready_go = 0`。

**检测**（在 ID 级）：

```verilog
// Load 在 EX：数据要到 WB 才有，还差 2 级
assign load_in_ex  = ex_valid  & ex_mem_read  & (ex_rd  != 0)
                   & ((ex_rd  == id_rs1) | (ex_rd  == id_rs2));

// Load 在 MEM：dram_dout 还没更新，还差 1 级
assign load_in_mem = mem_valid & mem_is_load  & (mem_rd != 0)
                   & ((mem_rd == id_rs1) | (mem_rd == id_rs2));

assign load_use_hazard = load_in_ex | load_in_mem;
assign id_ready_go     = !load_use_hazard;
```

**时序示例**：

```
cycle 0: LW 在 EX, ADD 在 ID → load_in_ex=1  → stall
cycle 1: LW 在 MEM, ADD 在 ID → load_in_mem=1 → stall
cycle 2: LW 在 WB, ADD 在 ID → load_in_ex=0, load_in_mem=0 → id_ready_go=1, WB 前递 dram_dout
cycle 3: ADD 进入 EX（携带正确的 Load 数据）
```

> **注**：MEM 级前递显式排除 Load 指令（`!mem_is_load`），因为 MEM 级的 `mem_alu_result` 是 Load 的**地址**而非**数据**。Load 数据只能通过 WB 级前递（`wb_write_data = dram_dout`）获取。

### 9.3 WAW / WAR 冒险

顺序单发射流水线中不存在 WAW/WAR 冒险。

---

## 10. 信号连接总览

```
    next_pc ──→ IROM addr            EX ALU out ──→ DRAM addr (Single Port)
       │      (BRAM两级流水线)            │         (BRAM两级流水线)
       ▼                                  ▼
  Pre_IF_reg ─→ [IF] ─→ IF/ID ─→ [ID] ─→ ID/EX ─→ [EX] ─→ EX/MEM ─→ [MEM] ─→ MEM/WB ─→ [WB]
       ↑         ↑                   │  ▲                │    ↑    │              │    ↑
       │      IROM dout              │  │                │    │    │              │    │
       │     (指令直接给ID)           │  │                │    │  DRAM dout      │    │
       │         ┌── flush ──────────┘  │                │    │ (Load数据直接   │    │
       │         │  (清IF/ID, ID/EX)    │                │    │  给WB写回MUX)   │    │
       └── correct_target               │                │    │                  │    │
                                        │  ←── EX 前递 ──┘    │                  │    │
                                        │  ←── MEM 前递 ──────┘                  │    │
                                        │  ←── WB 前递 ──────────────────────────┘    │
                                   [前递 MUX]                                    [写回 MUX]
```

---

## 11. 设计检查清单

### 存储器时序
- [ ] IROM 地址来自 `next_pc`（组合逻辑），与 Pre_IF_reg 在同一 posedge 采样
- [ ] DRAM 地址（读/写）均来自 EX 级 ALU 输出（组合逻辑），与 EX/MEM_reg 在同一 posedge 采样
- [ ] DRAM 写使能门控：`ex_valid & ex_mem_write_en`
- [ ] DRAM 使用 Single Port BRAM（同一时刻只有一条指令在 EX，无端口冲突）
- [ ] IF/ID_reg 不存指令——指令由 IROM dout（BRAM 输出寄存器）直接提供
- [ ] MEM/WB_reg 不存 Load 数据——Load 数据由 DRAM dout（BRAM 输出寄存器）直接提供
- [ ] BRAM 两周期延迟被流水线完全吸收，IF/MEM 均无需额外 stall

### 握手机制
- [ ] Pre_IF_reg 参与 allowin 链（`if_allowin` 控制 PC 是否更新）
- [ ] allowin 从 WB 反向传播到 PC，共 5 级
- [ ] WB 级 `allowin` 恒为 1
- [ ] allowin 链无组合逻辑环路（ready_go 不依赖 allowin）

### Stall
- [ ] 多周期运算正确驱动 `ex_ready_go`
- [ ] Load-Use 冒险检测 EX 和 MEM 两级（Load 在 EX 或 MEM 时 `id_ready_go = 0`）
- [ ] 多周期运算被 flush 时收到 `cancel` 信号

### Flush
- [ ] 分支失败时清除 IF/ID_reg 和 ID/EX_reg 的 valid（EX/MEM_reg 不清除）
- [ ] flush 同时将 PC 更新为正确地址（优先级高于 stall）
- [ ] 所有副作用信号经过 valid gating

### 前递
- [ ] 前递逻辑检查来源级的 valid
- [ ] 优先级：EX > MEM > WB > 寄存器堆
- [ ] MEM 级前递排除 Load 指令（`!mem_is_load`）
- [ ] `rd == x0` 不触发前递
- [ ] Store 写使能门控：`ex_valid & ex_mem_write_en`

### 时序（200MHz 目标）
- [ ] next_pc MUX → IROM 地址建立时间在预算内
- [ ] EX ALU → DRAM 地址建立时间在预算内
- [ ] 5 级 allowin 串联链深度可控