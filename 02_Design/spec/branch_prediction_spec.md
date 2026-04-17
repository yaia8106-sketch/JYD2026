# 分支预测规格 (Phase 1: ID 级快速回归)

> 本文档定义了处理器分支预测的第一阶段优化：**ID 级快速跳转重定向**。
> 目标：将 `JAL` 指令的跳转收益从 EX 级提前到 ID 级，使 Penalty 从 2 拍降低至 **1 拍**。

---

## 1. 架构变更概述

在基础 5 级流水线中，跳转在 EX 级判定，导致 IF 和 ID 级的指令均被浪费。
通过在 ID 级识别 `JAL` 并计算目标地址，我们可以在指令进入 EX 级之前就完成 PC 重定向。

| 指令类型 | 判定阶段 | Penalty (当前) | Penalty (优化后) | 备注 |
|---------|---------|----------------|-----------------|------|
| **JAL** | **ID** | 2 拍 | **1 拍** | 无需等待寄存器，极其稳定 |
| **JALR**| EX | 2 拍 | 2 拍 | 依赖寄存器值，保持原样避免时序爆炸 |
| **Branch**| EX | 2 拍 | 2 拍 | 默认 Static Not-Taken，EX 级修正 |

---

## 2. 逻辑定义

### 2.1 ID 级判决逻辑 (cpu_top.sv)

在 ID 阶段，根据译码出的 `id_inst` 判定是否触发快速跳转：

```verilog
// 识别 JAL
wire id_is_jal = (id_inst[6:0] == 7'b1101111) && id_valid;

// 计算目标地址（使用专用加法器，避免复用 ALU 导致时序过长）
wire [31:0] id_jump_target = id_pc + id_imm;

// 快速跳转执行信号
wire id_jump_taken = id_is_jal;
```

### 2.2 重定向优先级 (next_pc_mux.sv)

更新 `irom_addr` 的选择逻辑，加入 ID 级重定向：

| 优先级 | 触发信号 | 目标地址 | 说明 |
|-------|----------|---------|------|
| 1 (最高) | `ex_branch_flush` | `ex_branch_target` | EX 级修正（处理预测失败） |
| 2 | **`id_jump_taken`** | **`id_jump_target`** | **ID 级快速跳转 (JAL)** |
| 3 | `!id_allowin` | `pc` | 流水线停顿，保持地址 |
| 4 (默认) | — | `next_pc` (pc + 4) | 顺序预取 |

### 2.3 流水线冲刷 (Flush)

当 ID 级发生跳转时，必须冲掉已经在 IF 阶段预取的那条错误指令：

*   **IF 级处理**：当 `id_jump_taken` 为 1 时，下一拍进入 ID 级的指令标记为 `id_valid = 0`。
*   **注意**：`JAL` 指令本身已经在 ID 级，它会正常流向 EX 级（写入 `ra` 寄存器），不会被自己触发的 flush 冲掉。

---

## 3. 时序分析 (Timing Analysis)

ID 级加法器引入了新的关键路径：
`if_id_reg (Q) -> imm_gen/adder -> next_pc_mux -> irom_addr (BRAM Setup)`

*   **估计延迟**：
    *   Reg Clk-to-Q: 0.3ns
    *   Imm Gen: 0.2ns
    *   32-bit Adder: 1.4ns
    *   MUX: 0.3ns
    *   BRAM Setup: 0.5ns
    *   **总计**: ~2.7ns
*   **主频兼容性**：在 200MHz (5ns) 下，该路径有约 **2.3ns** 的余量，相比于 EX 级前递路径（Slack 0.011ns），非常安全。

---

## 4. 验证计划

1.  **正确性**：运行 `riscv-tests` 的 `jal.bin`。
2.  **性能对比**：
    *   使用 `simple.bin` 测试。
    *   **预期**：JAL 指令后的气泡从 2 个减少为 1 个。
    *   **测量**：通过执行总时钟周期数下降来确认。

---

## 5. 待定事项 (TODO)

- [ ] 是否需要将 `B-type` 的向后跳转预测（Backwards Taken）也加入 ID 级判决？
- [ ] 评估在 ID 级增加这个加法器对资源（LUT）的消耗。
