# 分支判断单元模块规格

> 纯组合逻辑模块。在 EX 级判断分支/跳转是否实际发生，生成 flush 信号和正确目标地址。
> **Phase 2+ 更新**：支持预测感知的 flush 抑制（正确预测时不产生 flush）。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `rs1_data` | input | 32 | 数据 | rs1 值（经前递后） |
| `rs2_data` | input | 32 | 数据 | rs2 值（经前递后） |
| `alu_result` | input | 32 | 数据 | ALU 计算的跳转目标地址 |
| `ex_pc` | input | 32 | 数据 | 当前指令 PC（用于计算 fallthrough 地址） |
| `is_branch` | input | 1 | 控制 | 是否为 B-type 分支 |
| `branch_cond` | input | 3 | 控制 | 分支条件（funct3 透传） |
| `is_jal` | input | 1 | 控制 | 是否为 JAL |
| `is_jalr` | input | 1 | 控制 | 是否为 JALR |
| `ex_valid` | input | 1 | 控制 | EX 级指令是否有效 |
| `pred_taken` | input | 1 | 控制 | IF 级预测是否跳转（经 ID/EX 流水） |
| `pred_target` | input | 32 | 数据 | IF 级预测的目标地址（保留端口） |
| `branch_flush` | output | 1 | 控制（组合） | 预测失败，需要 flush |
| `branch_target` | output | 32 | 数据（组合） | 正确的重定向目标地址 |
| `actual_taken_out` | output | 1 | 控制（组合） | 真实跳转结果（用于训练预测器） |

---

## 2. 功能描述

### 2.1 分支条件判断

利用共享减法器计算 `rs1 - rs2`，从减法结果推导 6 种分支条件：

| `branch_cond` | 条件 | 推导方式 |
|----------------|------|----------|
| `3'b000` BEQ  | `rs1 == rs2` | `~neq` |
| `3'b001` BNE  | `rs1 != rs2` | `neq` |
| `3'b100` BLT  | `signed(rs1) < signed(rs2)` | `cmp` |
| `3'b101` BGE  | `signed(rs1) >= signed(rs2)` | `~cmp` |
| `3'b110` BLTU | `rs1 < rs2` | `cmp`（无符号模式） |
| `3'b111` BGEU | `rs1 >= rs2` | `~cmp`（无符号模式） |

### 2.2 预测感知 Flush 逻辑

```
actual_taken = is_jalr | (is_branch & branch_taken)
missed       = actual_taken & ~pred_taken    // 未预测但实际跳转
wrong_dir    = ~actual_taken & pred_taken    // 预测跳转但实际不跳

branch_flush = ex_valid & (missed | wrong_dir)
```

### 2.3 重定向目标

```
// missed:    跳转到实际分支目标（alu_result）
// wrong_dir: 跳转到顺序地址（ex_pc + 4）
branch_target = wrong_dir ? (ex_pc + 4) : actual_target
```

---

## 3. 边界条件

- `ex_valid = 0` 时 `branch_flush` 必须为 0
- `pred_taken = 1 && actual_taken = 1` → 不 flush（0 拍跳转成功）
- JAL 不在此模块处理（由 BTB 或 ID 级 JAL 逻辑兜底）

---

## 4. 依赖文档

- `spec/front_end_predictor_spec.md`（预测器规格）
