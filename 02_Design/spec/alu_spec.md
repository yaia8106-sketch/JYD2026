# ALU 模块规格

> 纯组合逻辑模块。根据 `alu_op` 对两个 32-bit 操作数执行运算，输出 32-bit 结果。
> 编码方式 `alu_op = {funct7[5], funct3}` 使 bit 位直接驱动硬件共享逻辑。

---

## 1. 端口列表

| 信号名 | 方向 | 位宽 | 类型 | 含义 |
|--------|------|------|------|------|
| `alu_op` | input | 4 | 控制 | ALU 操作类型（`{funct7[5], funct3}`） |
| `alu_src1` | input | 32 | 数据 | 操作数 1（已由上游 MUX 选定：rs1 / PC / 0） |
| `alu_src2` | input | 32 | 数据 | 操作数 2（已由上游 MUX 选定：rs2 / 立即数） |
| `alu_result` | output | 32 | 数据（组合） | 运算结果 |

> **注**：操作数来源的 MUX 选择不在本模块内部，由上游逻辑完成。本模块只做纯运算。

---

## 2. 功能描述

| `alu_op` | 编码 | 运算 | 结果 |
|----------|------|------|------|
| `ALU_ADD` | `4'b0_000` | 加法 | `src1 + src2` |
| `ALU_SUB` | `4'b1_000` | 减法 | `src1 - src2` |
| `ALU_SLL` | `4'b0_001` | 逻辑左移 | `src1 << src2[4:0]` |
| `ALU_SLT` | `4'b0_010` | 有符号比较 | `$signed(src1) < $signed(src2) ? 1 : 0` |
| `ALU_SLTU`| `4'b0_011` | 无符号比较 | `src1 < src2 ? 1 : 0` |
| `ALU_XOR` | `4'b0_100` | 异或 | `src1 ^ src2` |
| `ALU_SRL` | `4'b0_101` | 逻辑右移 | `src1 >> src2[4:0]` |
| `ALU_SRA` | `4'b1_101` | 算术右移 | `$signed(src1) >>> src2[4:0]` |
| `ALU_OR`  | `4'b0_110` | 或 | `src1 \| src2` |
| `ALU_AND` | `4'b0_111` | 与 | `src1 & src2` |
| 其他 | — | 未定义 | `32'd0`（默认值，防止 latch） |

---

## 3. 实现要求：硬件共享

### 3.1 共享加法器

一个 32-bit 加法器同时服务 ADD/SUB/SLT/SLTU：

```verilog
wire negate = alu_op[3] | alu_op[1];  // SUB(1_000), SLT(0_010), SLTU(0_011) 需要减法
wire [31:0] sum = alu_src1 + (negate ? ~alu_src2 + 1 : alu_src2);
```

> 其他操作（SRA、OR、AND 等）也可能触发 negate，但其结果不使用 sum，不影响正确性。

### 3.2 统一比较器

利用减法结果判断大小关系：

```verilog
// 同号：直接看差值符号位
// 异号：有符号比较看 src1 符号，无符号比较看 src2 符号
wire cmp = (alu_src1[31] == alu_src2[31]) ? sum[31]
         : alu_op[0] ? alu_src2[31] : alu_src1[31];
```

- `alu_op[0] = 0` → 有符号比较（SLT）
- `alu_op[0] = 1` → 无符号比较（SLTU）

### 3.3 位翻转移位器

一个右移位器服务 SLL/SRL/SRA：

```verilog
wire [31:0] shin  = alu_op[2] ? alu_src1 : reverse(alu_src1);  // [2]=0 左移：先翻转
wire [32:0] shift = {alu_op[3] & shin[31], shin};               // [3]=1 算术：符号扩展
wire [32:0] shiftt = $signed(shift) >>> alu_src2[4:0];
wire [31:0] shiftr = shiftt[31:0];
wire [31:0] shiftl = reverse(shiftr);                            // 左移结果：翻转回来
```

- `alu_op[2] = 0` → 左移（SLL）：翻转 → 右移 → 翻转
- `alu_op[2] = 1` → 右移（SRL/SRA）：直接右移
- `alu_op[3] = 1` → 算术右移（SRA）：高位填符号位

### 3.4 输出选择

```verilog
case (alu_op)
    ALU_ADD, ALU_SUB:   alu_result = sum;
    ALU_SLL:            alu_result = shiftl;
    ALU_SLT, ALU_SLTU:  alu_result = {31'b0, cmp};
    ALU_XOR:            alu_result = alu_src1 ^ alu_src2;
    ALU_SRL, ALU_SRA:   alu_result = shiftr;
    ALU_OR:             alu_result = alu_src1 | alu_src2;
    ALU_AND:            alu_result = alu_src1 & alu_src2;
    default:            alu_result = 32'd0;
endcase
```

---

## 4. 时序约束

- 纯组合逻辑，无时钟、无寄存器
- **关键路径**：`alu_result` 直接驱动 DRAM 地址端口，在 EX→MEM posedge 前必须稳定（见 `pipeline.md` §2.3）

---

## 5. 边界条件

- 无时钟、无复位、无 stall/flush
- 所有 `alu_op` 值（包括未定义值）必须有确定输出，`default` 分支输出 `32'd0`

---

## 6. 依赖文档

- `design_rules/isa_encoding.md` §2（ALU 操作编码及 bit 位含义）
