# 全局规则

> AI 每次新会话必读。本文件定义不随架构变化的约束和规范。

---

## 1. 地址空间

| 区域 | 地址范围 | 大小 | 属性 |
|------|---------|------|------|
| **IROM** | `0x8000_0000` ~ `0x8000_3FFF` | 16KB | 只读 |
| **DRAM** | `0x8010_0000` ~ `0x8013_FFFF` | 256KB | 读写（DCache） |
| **MMIO** | `0x8020_0000` ~ `0x8020_00FF` | 256B | 见下表 |

### MMIO

| 地址 | 名称 | 属性 |
|------|------|------|
| `0x8020_0000` | SW 低32位 | 只读 |
| `0x8020_0004` | SW 高32位 | 只读 |
| `0x8020_0010` | KEY | 只读（低8位） |
| `0x8020_0020` | SEG | 读写 |
| `0x8020_0040` | LED | 只写 |
| `0x8020_0050` | CNT | 读写（写0x80000000开始/0xFFFFFFFF停止） |
| `0x8020_0060` | DUAL_ISSUE_CNT | 只读（自定义双发射计数器） |

所有外设仅支持 **4 字节对齐访问**。

---

## 2. 赛方约束

- 指令集：**RV32I**（37 条，fence/ebreak/ecall 可 NOP）
- 可修改：`Core_cpu`（`student_top.sv`）、PLL
- **禁止修改**：`contest_readonly/` 下所有文件
- PC 复位值：`0x7FFF_FFFC`（text_base - 4）

---

## 3. BRAM 时序模型

所有 BRAM 不启用 Output Register，**1 拍延迟**：

```verilog
always_ff @(posedge clk) begin
    if (we) mem[addr] <= wdata;
    dout <= mem[addr];   // posedge 采样 addr，Clk-to-Q (~2ns) 后 dout 有效
end
```

dout 是寄存器输出，组合路径被切断，下游有 ~2ns 时间窗口。

---

## 4. 握手协议

每级流水线使用 `valid` / `allowin` / `ready_go` 三信号握手。

```
xx_allowin = !xx_valid || (xx_ready_go & next_allowin)
```

级间寄存器更新模板：

```verilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)             xx_valid <= 0;
    else if (xx_flush)      xx_valid <= 0;         // flush > stall
    else if (xx_allowin)    xx_valid <= prev_valid & prev_ready_go;
    // else: stall，保持不变
end
```

关键性质：
- Stall 只向上游传播
- 气泡是握手自然产物（allowin=1 但上游无数据 → valid <= 0）
- **flush > stall**
- 所有副作用必须 valid gating：`actual_en = xx_valid & en`

---

## 5. 硬件编码规则

- **禁止 Latch**：`always_comb` 必须有完整默认分支
- **禁止 `initial`**：不可用于可综合逻辑
- **所有寄存器必须显式复位**（Synth 8-7137 是严重 warning）
- 优先 **并行 AND-OR MUX** 替代 `case/if-else` 链
- ALU 编码 `alu_op = {funct7[5], funct3}`，直接透传
- 分支条件直接用 `funct3`，无需额外编码

---

## 6. 文档维护

- 只维护 global_rules.md 和 architecture.md 两个文档，不新建文档文件
- 优化待办和 profiling 基线记录在项目根目录 `TODO.md`
- 信号名必须与 RTL 一致，不写规划、不写历史、只写当前状态
