# 寄存器堆模块规格

> 时序逻辑模块。32 个 32-bit 寄存器，2 读 1 写，read-first 架构。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `clk` | input | 1 | 时钟 | 系统时钟 |
| `rst_n` | input | 1 | 复位 | 异步低有效复位 |
| `rs1_addr` | input | 5 | 数据 | 读端口 1 地址 |
| `rs2_addr` | input | 5 | 数据 | 读端口 2 地址 |
| `rd_addr` | input | 5 | 数据 | 写端口地址 |
| `rd_data` | input | 32 | 数据 | 写入数据 |
| `rd_wen` | input | 1 | 控制 | 写使能（已经过 valid gating） |
| `rs1_data` | output | 32 | 数据（组合） | 读端口 1 数据 |
| `rs2_data` | output | 32 | 数据（组合） | 读端口 2 数据 |

---

## 2. 功能描述

### 2.1 写操作（posedge clk）

```
if (rd_wen && rd_addr != 0)
    regs[rd_addr] <= rd_data;
```

- `x0` 硬连线为 0，永远不可写入
- `rd_wen` 已经过上游 valid gating（`wb_valid & wb_reg_write_en`），模块内部不再检查

### 2.2 读操作（组合逻辑）

```
rs1_data = (rs1_addr == 0) ? 0 : regs[rs1_addr];
rs2_data = (rs2_addr == 0) ? 0 : regs[rs2_addr];
```

### 2.3 Read-first 行为

同一拍 WB 写 x5、ID 读 x5 → ID 读到**旧值**。

这是 read-first 的固有行为，不需要额外逻辑。前递 MUX（forwarding 模块）中的 WB 级前递路径负责处理此情况。

---

## 3. 时序约束

- 写：`posedge clk` 时采样 `rd_addr`/`rd_data`/`rd_wen`
- 读：纯组合逻辑（地址变化 → 数据变化，无时钟延迟）
- 复位：异步低有效，所有寄存器清零

---

## 4. 边界条件

- **复位**：所有 32 个寄存器清零（`regs[0..31] = 0`）
- **x0 读**：始终返回 0
- **x0 写**：写操作被忽略（`rd_addr != 0` 门控）
- **读写同地址同拍**：读到旧值（read-first）

---

## 5. 依赖文档

- `design_decisions.md` §A（read-first 决策）
- `pipeline.md` §9.1（WB 级前递路径）
