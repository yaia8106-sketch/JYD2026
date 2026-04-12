# IF/ID 级间寄存器模块规格

> 时序逻辑模块。存储 PC 和指令，遵循 valid/allowin 握手协议。
> **注**：指令由 BRAM Clk-to-Q 在 IF 阶段产生，IF/ID 寄存器锁存后供 ID 阶段使用。

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
| `if_inst` | input | 32 | 数据 | BRAM 输出的指令（IF 阶段 Clk-to-Q 有效） |
| `id_pc` | output | 32 | 数据（寄存器） | 传给 ID 级的 PC |
| `id_inst` | output | 32 | 数据（寄存器） | 传给 ID 级的指令（decoder/imm_gen 使用） |

---

## 2. 功能描述

### 2.1 握手

```verilog
assign id_allowin = !id_valid || (id_ready_go & ex_allowin);
```

### 2.2 寄存器更新

优先级：rst > flush > allowin > stall（保持）

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        id_valid <= 1'b0;
        id_pc    <= 32'd0;
        id_inst  <= 32'd0;
    end else if (id_flush) begin
        id_valid <= 1'b0;
    end else if (id_allowin) begin
        id_valid <= if_valid & if_ready_go;
        id_pc    <= if_pc;
        id_inst  <= if_inst;
    end
end
```

### 2.3 与 IROM 的时序关系

IROM 使用 1 拍 BRAM（无 Output Register），`irom_addr` 在 pre-IF 阶段驱动：

```
pre-IF:  irom_addr → BRAM addr_reg 锁存
IF:      BRAM Clk-to-Q → irom_data (= if_inst) 有效
IF→ID:   IF/ID 寄存器锁存 if_inst → id_inst
ID:      decoder/imm_gen 使用 id_inst（仅 Clk-to-Q ~0.3ns）
```

---

## 3. 依赖文档

- `pipeline.md` §4（握手公式）、§5.3（IF/ID 更新规则）、§8（flush）
