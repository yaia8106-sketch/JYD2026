# 时序分析标记法 (REG/COMB Notation)

## 目的

在分析流水线时序、数据冒险、组合路径等问题时，提供一种**无歧义**的伪代码格式，
避免自然语言描述中"同一个周期"、"上升沿之前/之后"等含糊表述导致分析错误。

---

## 核心概念

一个时钟周期 N 被分为两个阶段：

```
         ┌─ REG N ─┐┌──────── COMB N ────────┐
         │         ││                         │
    ─────┤ posedge ├┤  组合逻辑求值 & 稳定    ├─────
         │         ││                         │
         └─────────┘└─────────────────────────┘
              ↑                  ↑
         寄存器捕获         组合逻辑看到
         (非阻塞赋值)       新的寄存器值
```

### REG N（时钟上升沿）

- 所有 `always_ff @(posedge clk)` 在此刻执行
- 非阻塞赋值 (`<=`) 用 **COMB N-1 的旧值** 计算 RHS，更新 LHS
- 写法：`信号 ← 表达式`

### COMB N（组合逻辑阶段）

- 紧跟 REG N 之后，所有 `assign` / `always_comb` 重新求值
- 看到的是 **REG N 更新后的新值**
- 写法：`信号 = 表达式`

---

## 标记格式

```
REG N:
  [阶段/模块]:  信号A ← 表达式1
  [阶段/模块]:  信号B ← 表达式2

COMB N:
  [阶段/模块]:  信号C = f(信号A, 信号B)     // 用 REG N 的新值
  [阶段/模块]:  信号D = g(...)
```

### 规则

1. **REG 和 COMB 编号相同**：`REG N` 后面紧跟 `COMB N`，表示同一个时钟周期
2. **多级流水线分行**：在同一个 REG/COMB 内，按 `[阶段]` 标签分行描述不同流水级的信号
3. **← 表示寄存器写**（非阻塞赋值），**= 表示组合求值**
4. **条件用缩进 + `if`**：
   ```
   REG N:
     [bridge]:  if |mem_wea && !mem_is_dram:
                  seg_wdata ← mem_wdata
   ```
5. **标注数据来源**：当信号来源不明显时，括号注明 `信号(指令名)` 或 `信号(来源模块)`
6. **标注冒险结论**：在 COMB 行末用 `← 新值 ✓` 或 `← 旧值 ✗` 标注

---

## 示例：MMIO 写推迟到 MEM 阶段后的 RAW 分析

场景：`SW x1, SEG_ADDR(x0)` 紧跟 `LW x2, SEG_ADDR(x0)`

```
REG 0:
  [IF/ID]:   id_inst ← irom_dout(SW)

COMB 0:
  [ID(SW)]:  decoder 译码, rs1/rs2 读取
  [IF(LW)]:  PC → IROM 取指

REG 1:
  [ID/EX]:   ex_alu_src1 ← fwd_rs1(SW), ex_alu_src2 ← imm_S(SW)
  [IF/ID]:   id_inst ← irom_dout(LW)

COMB 1:
  [EX(SW)]:  alu_result = rs1 + imm_S = SEG_ADDR
             store_wea = 4'b1111, store_data = wdata
  [ID(LW)]:  decoder 译码

REG 2:
  [EX/MEM]:  mem_addr ← SEG_ADDR(SW), mem_wea ← 4'b1111, mem_wdata ← VALUE
  [ID/EX]:   ex_alu_src1 ← fwd_rs1(LW), ex_alu_src2 ← imm_S(LW)

COMB 2:
  [MEM(SW)]: (MMIO 写在 REG 3 才执行，此周期无写操作)
  [EX(LW)]:  alu_result = rs1 + imm_S = SEG_ADDR

REG 3:
  [bridge]:  if |mem_wea && !mem_is_dram && mem_addr == SEG_ADDR:
               seg_wdata ← mem_wdata = VALUE           // ← SW 的写，用 COMB 2 的旧 mem_*
  [EX/MEM]:  mem_addr ← SEG_ADDR(LW), mem_wea ← 0     // ← LW 是 Load，wea = 0

COMB 3:
  [MEM(LW)]: mmio_rdata = ({32{mem_addr == SEG_ADDR}} & seg_wdata)
                        = VALUE                         // ← 新值 ✓ (REG 3 刚写入)

REG 4:
  [MEM/WB]:  wb_rdata ← rdata(LW) = VALUE              // ← 正确捕获
```

**结论**：REG 3 写入 `seg_wdata`，COMB 3 组合读取 → 读到新值 ✓，无 RAW 冒险。

---

## 示例：Load-Use Stall 分析

场景：`LW x1, 0(x2)` 紧跟 `ADD x3, x1, x4`（x1 数据冒险）

```
REG 1:
  [ID/EX]:   ex_alu_src1 ← fwd_rs1(LW), ...

COMB 1:
  [EX(LW)]:  alu_result = x2 + 0 = DRAM_ADDR
  [ID(ADD)]: decoder: rs1 = x1 → 检测到 EX 级是 Load 且 rd == rs1
             → load_use_stall = 1

REG 2:
  [EX/MEM]:  mem_addr ← DRAM_ADDR(LW)
  [ID/EX]:   bubble (stall 插入无效指令)
  [IF/ID]:   保持不变 (stall)
  [PC]:      保持不变 (stall)

COMB 2:
  [MEM(LW)]: BRAM Clk-to-Q → dram_douta 有效
  [EX]:      bubble，无操作
  [ID(ADD)]: 重新译码，此时 EX 级不再是 Load → stall 解除
             fwd_rs1 = mem_alu_result(LW) 或等待 WB 前递

REG 3:
  [MEM/WB]:  wb_rdata ← dram_douta(LW)
  [ID/EX]:   ex_alu_src1 ← fwd_rs1(ADD) = wb_rdata(LW)  // MEM→ID 前递
```

---

## 使用要求

1. **所有流水线时序分析必须使用此标记法**，禁止用"第 N 个周期"等模糊表述
2. **遇到数据冒险争议时**，必须展开到 REG/COMB 级别逐拍推演
3. **每个 REG/COMB 内按流水级排列**，从后级到前级（MEM → EX → ID → IF）
4. **结论用 ✓/✗ 明确标注**，不允许"应该没问题"等模糊结论
