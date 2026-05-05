# 流水线控制通用规范

> 本文档定义通用的流水线握手协议、级间寄存器模板、stall/flush 原则。
> 具体架构实现（取指、前递、flush 范围等）见对应功能模块文档（如 `dual_issue/architecture.md`）。

---

## 1. 命名约定

| 术语 | 含义 | 示例 |
|------|------|------|
| **级间寄存器** | 两级之间的流水线寄存器，以前后两级命名 | `if_id_reg`、`id_ex_reg` |
| **级间逻辑** | 两个寄存器之间的组合/时序逻辑 | IF 级逻辑、EX 级逻辑 |
| **上游** | 靠近 IF 的方向 | |
| **下游** | 靠近 WB 的方向 | |
| **Slot 0 / Slot 1** | 双发射时的两条发射槽 | `id_ex_reg`（S0）、`id_ex_reg_s1`（S1） |

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

> 具体每级寄存器的 flush 范围和信号连接见架构文档（如 `dual_issue/architecture.md`）。

### 5.2 更新优先级速查表

| 优先级 | 条件 | 行为 |
|-------|------|------|
| 1（最高） | `rst_n = 0` | 全部清零 |
| 2 | `xx_flush = 1` | 清除 valid |
| 3a | `xx_allowin = 1` 且上游握手成功 | 接收有效数据 |
| 3b | `xx_allowin = 1` 且上游握手未成功 | 写入 `valid = 0`（气泡） |
| 4（最低） | `xx_allowin = 0` | 锁存不变（stall） |

---

## 6. Stall（阻塞）

### 6.1 产生原因

| 场景 | 位置 | 受影响的 ready_go |
|------|------|-----------------|
| 乘除法（M 扩展） | EX | `ex_ready_go = 0` |
| 浮点运算（F 扩展） | EX | `ex_ready_go = 0` |
| dcache miss | MEM | `mem_ready_go = 0` |
| icache miss | IF | `if_ready_go = 0` |
| Load-Use 冒险 | ID | `id_ready_go = 0` |

### 6.2 传播机制

stall **只向上游传播**，下游不受影响。

以 EX 级 stall 为例：

```
ex_allowin  = !1 || (0 & mem_allowin) = 0    ← EX 拒绝
id_allowin  = !1 || (1 & 0) = 0              ← ID 被级联阻塞
if_allowin  = !1 || (1 & 0) = 0              ← IF 被级联阻塞（PC 锁存）
mem_allowin = 正常值                           ← MEM 及下游不受影响
```

### 6.3 自动气泡

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

## 7. Flush（冲刷）

### 7.1 通用原则

- flush 信号是**组合逻辑**，在**下一个 posedge** 才生效
- flush 通过清零 `xx_valid` 实现，数据域变成 don't care
- **flush 优先级 > stall 优先级**

### 7.2 副作用屏蔽（valid gating）

所有有副作用的操作必须经过 valid 门控：

```verilog
assign reg_write_en_actual = wb_valid  & wb_reg_write_en;
assign mem_write_en_actual = ex_valid  & ex_mem_write_en;
```

flush 只需清零 valid，所有副作用自动被屏蔽。

> 具体的 flush 范围、代价、信号连接因架构而异，见对应架构文档。
