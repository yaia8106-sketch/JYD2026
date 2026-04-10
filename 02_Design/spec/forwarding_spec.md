# 前递与冒险检测模块规格

> 纯组合逻辑模块。位于 ID 级，包含前递 MUX（rs1/rs2 各一个）和 Load-Use 冒险检测。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| **ID 级输入** |
| `id_rs1_addr` | input | 5 | 数据 | ID 级 rs1 地址 |
| `id_rs2_addr` | input | 5 | 数据 | ID 级 rs2 地址 |
| `rf_rs1_data` | input | 32 | 数据 | regfile 读端口 1（read-first 旧值） |
| `rf_rs2_data` | input | 32 | 数据 | regfile 读端口 2（read-first 旧值） |
| **EX 级信号** |
| `ex_valid` | input | 1 | 控制 | EX 级有效 |
| `ex_reg_write` | input | 1 | 控制 | EX 级写寄存器使能 |
| `ex_mem_read` | input | 1 | 控制 | EX 级 Load 标志 |
| `ex_rd` | input | 5 | 数据 | EX 级目标寄存器 |
| `ex_alu_result` | input | 32 | 数据 | EX 级 ALU 组合逻辑输出 |
| **MEM 级信号** |
| `mem_valid` | input | 1 | 控制 | MEM 级有效 |
| `mem_reg_write` | input | 1 | 控制 | MEM 级写寄存器使能 |
| `mem_is_load` | input | 1 | 控制 | MEM 级 Load 标志 |
| `mem_rd` | input | 5 | 数据 | MEM 级目标寄存器 |
| `mem_alu_result` | input | 32 | 数据 | MEM 级 ALU 结果（EX/MEM_reg 输出） |
| **WB 级信号** |
| `wb_valid` | input | 1 | 控制 | WB 级有效 |
| `wb_reg_write` | input | 1 | 控制 | WB 级写寄存器使能 |
| `wb_rd` | input | 5 | 数据 | WB 级目标寄存器 |
| `wb_write_data` | input | 32 | 数据 | WB 级写回数据（ALU / dram_dout / PC+4） |
| **输出** |
| `id_rs1_data` | output | 32 | 数据（组合） | 前递后的 rs1 数据 |
| `id_rs2_data` | output | 32 | 数据（组合） | 前递后的 rs2 数据 |
| `load_use_hazard` | output | 1 | 控制（组合） | Load-Use 冒险（驱动 `id_ready_go = !load_use_hazard`） |

---

## 2. 功能描述

### 2.1 前递 MUX（rs1/rs2 各一个，结构相同）

并行匹配 + 优先级编码 + AND-OR MUX（见 `pipeline.md` §9.1）：

优先级：**EX > MEM > WB > regfile**

匹配条件：
- EX：`ex_valid & ex_reg_write & (ex_rd != 0) & (ex_rd == id_rsX)`
- MEM：`mem_valid & mem_reg_write & !mem_is_load & (mem_rd != 0) & (mem_rd == id_rsX)`
- WB：`wb_valid & wb_reg_write & (wb_rd != 0) & (wb_rd == id_rsX)`

> **注**：MEM 级排除 Load（`!mem_is_load`），因为 MEM 级的 alu_result 是地址不是数据。

### 2.2 Load-Use 冒险检测

检测 EX 和 MEM 两级（见 `pipeline.md` §9.2）：

```
load_in_ex  = ex_valid  & ex_mem_read & (ex_rd  != 0) & ((ex_rd  == id_rs1) | (ex_rd  == id_rs2))
load_in_mem = mem_valid & mem_is_load & (mem_rd != 0) & ((mem_rd == id_rs1) | (mem_rd == id_rs2))
load_use_hazard = load_in_ex | load_in_mem
```

---

## 3. 时序约束

- 纯组合逻辑
- 关键路径：EX 级 ALU 组合输出 → 前递 MUX → ID/EX_reg（跨级组合路径）

---

## 4. 边界条件

- `rd == x0` 不触发前递和冒险检测
- `valid = 0`（气泡）不参与前递

---

## 5. 依赖文档

- `pipeline.md` §9.1（前递逻辑）
- `pipeline.md` §9.2（Load-Use 冒险）
- `project_context.md` §5.1（AND-OR MUX 原则）
