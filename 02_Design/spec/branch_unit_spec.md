# 分支判断单元模块规格

> 纯组合逻辑模块。在 EX 级判断分支/跳转是否实际发生，生成 flush 信号和正确目标地址。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `rs1_data` | input | 32 | 数据 | rs1 值（经前递后） |
| `rs2_data` | input | 32 | 数据 | rs2 值（经前递后） |
| `alu_result` | input | 32 | 数据 | ALU 计算的跳转目标地址 |
| `is_branch` | input | 1 | 控制 | 是否为 B-type 分支 |
| `branch_cond` | input | 3 | 控制 | 分支条件（funct3 透传） |
| `is_jal` | input | 1 | 控制 | 是否为 JAL |
| `is_jalr` | input | 1 | 控制 | 是否为 JALR |
| `ex_valid` | input | 1 | 控制 | EX 级指令是否有效 |
| `branch_flush` | output | 1 | 控制（组合） | 预测失败，需要 flush |
| `branch_target` | output | 32 | 数据（组合） | 正确的跳转目标地址 |

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

### 2.2 跳转判断

```
actual_taken = is_jal | is_jalr | (is_branch & branch_taken)
```

默认预测 not-taken，所以 `actual_taken = 1` 即预测失败。

### 2.3 Flush 和目标

```
branch_flush  = ex_valid & actual_taken
branch_target = is_jalr ? (alu_result & ~32'd1) : alu_result  // JALR 清 LSB
```

---

## 3. 时序约束

- 纯组合逻辑，关键路径：rs1/rs2 → 比较 → flush → Pre_IF_reg

---

## 4. 边界条件

- `ex_valid = 0` 时 `branch_flush` 必须为 0（气泡不触发 flush）
- 未定义的 `branch_cond`（`3'b010`, `3'b011`）：`branch_taken = 0`

---

## 5. 依赖文档

- `design_rules/isa_encoding.md` §6（分支判断单元）
- `design_rules/pipeline.md` §8（flush 机制）
