# IF/ID 级间寄存器模块规格

> 时序逻辑模块。存储 PC，遵循 valid/allowin 握手协议。
> **注**：不存指令。指令由 IROM dout 直接提供给 ID 组合逻辑。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `clk` | input | 1 | 时钟 | 系统时钟 |
| `rst_n` | input | 1 | 复位 | 异步低有效复位 |
| **握手信号** |
| `if_valid` | input | 1 | 控制 | IF 级有效（正常运行恒为 1） |
| `if_ready_go` | input | 1 | 控制 | IF 级完成（正常为 1） |
| `id_allowin` | output | 1 | 控制（组合） | ID 级是否允许接收 |
| `id_valid` | output | 1 | 控制（寄存器） | ID 级有效 |
| `id_ready_go` | input | 1 | 控制 | ID 级完成（由 forwarding 模块的 `!load_use_hazard` 驱动） |
| `ex_allowin` | input | 1 | 控制 | 下游 EX 级 allowin |
| **Flush** |
| `id_flush` | input | 1 | 控制 | 分支 flush 信号 |
| **数据** |
| `if_pc` | input | 32 | 数据 | Pre_IF_reg 的 PC 值 |
| `id_pc` | output | 32 | 数据（寄存器） | 传给 ID 级的 PC |

---

## 2. 功能描述

### 2.1 握手

```verilog
assign id_allowin = !id_valid || (id_ready_go & ex_allowin);
```

### 2.2 寄存器更新

见 `pipeline.md` §5.1 通用模板 + §5.3 IF/ID_reg。

优先级：rst > flush > allowin > stall（保持）

---

## 3. 依赖文档

- `pipeline.md` §4（握手公式）、§5.3（IF/ID 更新规则）、§8（flush）
