# IF/ID 级间寄存器模块规格

> 时序逻辑模块。存储 PC 和指令，遵循 valid/allowin 握手协议。
> **注**：指令由 BRAM Clk-to-Q 在 IF 阶段产生，IF/ID 寄存器锁存后供 ID 阶段使用。
> **NLP**：增加分支预测 snapshot 信号传递（btb_type 替代 btb_way）。

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
| `id_flush` | input | 1 | 控制 | flush 信号（= `branch_flush \| id_bp_redirect`） |
| **数据** |
| `if_pc` | input | 32 | 数据 | Pre_IF_reg 的 PC 值 |
| `if_inst` | input | 32 | 数据 | BRAM 输出的指令（IF 阶段 Clk-to-Q 有效） |
| `id_pc` | output | 32 | 数据（寄存器） | 传给 ID 级的 PC |
| `id_inst` | output | 32 | 数据（寄存器） | 传给 ID 级的指令（decoder/imm_gen 使用） |
| **分支预测 snapshot（NLP）** |
| `if_bp_taken` | input | 1 | 控制 | L0 预测方向 |
| `if_bp_target` | input | 32 | 数据 | L0 预测目标（BTB target） |
| `if_bp_ghr_snap` | input | 8 | 数据 | 预测时 GHR 快照 |
| `if_bp_btb_hit` | input | 1 | 控制 | BTB 命中 |
| `if_bp_btb_type` | input | 2 | 数据 | BTB entry 类型（NLP: ID 级验证用） |
| `if_bp_btb_bht` | input | 2 | 数据 | BTB entry BHT 计数器 |
| `if_bp_pht_cnt` | input | 2 | 数据 | GShare PHT 计数器 |
| `if_bp_sel_cnt` | input | 2 | 数据 | Selector 计数器 |
| `id_bp_*` | output | — | 寄存器 | 以上各信号的 ID 级输出（对称） |

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
        id_valid        <= 1'b0;
        id_pc           <= 32'd0;
        id_inst         <= 32'd0;
        id_bp_taken     <= 1'b0;
        id_bp_target    <= 32'd0;
        id_bp_ghr_snap  <= 8'd0;
        id_bp_btb_hit   <= 1'b0;
        id_bp_btb_type  <= 2'd0;
        id_bp_btb_bht   <= 2'd0;
        id_bp_pht_cnt   <= 2'd0;
        id_bp_sel_cnt   <= 2'd0;
    end else if (id_flush) begin
        id_valid        <= 1'b0;
    end else if (id_allowin) begin
        id_valid        <= if_valid & if_ready_go;
        id_pc           <= if_pc;
        id_inst         <= if_inst;
        id_bp_taken     <= if_bp_taken;
        id_bp_target    <= if_bp_target;
        id_bp_ghr_snap  <= if_bp_ghr_snap;
        id_bp_btb_hit   <= if_bp_btb_hit;
        id_bp_btb_type  <= if_bp_btb_type;
        id_bp_btb_bht   <= if_bp_btb_bht;
        id_bp_pht_cnt   <= if_bp_pht_cnt;
        id_bp_sel_cnt   <= if_bp_sel_cnt;
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

### 2.4 id_flush 来源（NLP）

```verilog
wire id_flush = branch_flush | id_bp_redirect;
```

- `branch_flush`：EX 级分支确认后的误预测冲刷
- `id_bp_redirect`：NLP ID 级 L1 Tournament 验证发现 L0 预测错误时的重定向

---

## 3. 依赖文档

- `branch_predictor_spec.md` §6A（NLP ID 级 redirect 逻辑）
- `pipeline.md` §4（握手公式）、§5.3（IF/ID 更新规则）、§8（flush）
