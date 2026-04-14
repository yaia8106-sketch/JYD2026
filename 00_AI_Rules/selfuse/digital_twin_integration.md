# 数字孪生平台适配记录

> 本文档记录 cpu_top 集成到 `JYD2025_Contest-rv32i/` 数字孪生平台工程过程中的分析、决策和待定事项。

---

## 1. 平台架构概述

```
top.sv
├── PLL (差分时钟 → clk_50MHz + cpu_clk)
├── UART + twin_controller (数字孪生通信)
└── student_top.sv ← 我们写的，CPU 在这里
    ├── cpu_top         (我们的处理器)
    ├── IROM            (指令存储)
    ├── perip_bridge    (自研外设桥)
    │   ├── DRAM        (数据存储)
    │   ├── LED / SEG 寄存器
    │   ├── SW / KEY 读取
    │   └── counter     (模板的，不能改，CDC)
    └── display_seg     (模板的七段驱动)
```

### 不可修改的模块
- `counter.sv`：含 CDC（Gray 码同步），明确禁止修改
- `top.sv`、`twin_controller.sv`、`uart.sv`：数字孪生通信链路

### 可修改/替换的模块
- `student_top.sv`：学生区，自由编写
- `perip_bridge.sv`：可以替换为自研版本
- `dram_driver.sv`：不再使用（由自研 bridge 内部的 BRAM 替代）

---

## 2. 地址空间映射

来源：模板 `perip_bridge.sv` 中的 `localparam` 定义

| 设备 | 地址 | 读/写 | 说明 |
|---|---|---|---|
| DRAM | `0x8010_0000` - `0x8013_FFFF` | R/W | 256KB 数据存储空间 |
| SW[31:0] | `0x8020_0000` | R | 拨码开关低 32 位 |
| SW[63:32] | `0x8020_0004` | R | 拨码开关高 32 位 |
| KEY | `0x8020_0010` | R | 8 位按键 |
| SEG | `0x8020_0020` | R/W | 七段数码管数据 |
| LED | `0x8020_0040` | W | 32 位 LED |
| Counter | `0x8020_0050` | R/W | 硬件计时器（W: start/stop, R: 读值） |

---

## 3. 存储体选型分析

### 三种可选方案

| 特性 | 分布式 RAM | BRAM (无 Output Reg) | BRAM (有 Output Reg) |
|---|---|---|---|
| 读延迟 | 0 拍（组合） | 1 拍 | 2 拍 |
| Clk-to-Q | N/A | ~2.0ns | ~0.6ns |
| 给下游留的时间 (5ns) | 全部 5ns | ~3.0ns | ~4.4ns |
| 容量效率 | 差（1 LUT6 = 64bit） | 好（1 BRAM36 = 36Kbit） | 好 |

### 决策：BRAM 无 Output Register（已确定，IROM 和 DRAM 均如此）

理由：
- 分布式 RAM：大容量（>16KB）时消耗大量 LUT，不适合 DRAM
- BRAM 有 Output Reg（2 拍）：等价于「不勾选 + MEM/WB 寄存器」但 MUX 位置不利
  - 内建 output reg 将 MUX 推迟到 WB 阶段（Clk-to-Q 0.6ns + MUX 1.5ns = 2.1ns）
  - 手动加 reg 的 MEM 阶段压力与不勾选完全相同，白等 1 拍
- BRAM 无 Output Reg（1 拍）：延迟适中，MEM/WB 寄存器承担数据锁存

### DRAM 容量（已确定）

- 65536 × 32bit（256KB），约 64 个 BRAM36
  - 3 级输出 MUX，Clk-to-Q ~2.0ns + MUX ~1.5ns = ~3.5ns
  - 50MHz（20ns 周期）下余量充足

---

## 4. 流水线适配方案

### 核心思路：EX 阶段直连 bridge，MEM/WB 寄存器捕获数据

BRAM 选型：无 Output Register（1 拍读延迟）。
ALU 输出在 EX 阶段直连 bridge 地址端口，BRAM 在 EX→MEM 时钟沿锁存，MEM 阶段 Clk-to-Q 后数据可用。
**流水线改动：IF/ID 寄存器新增 `id_inst`（锁存指令），MEM/WB 寄存器新增 `wb_dram_dout`（锁存 Load 数据）。**

### 精确时序（A-C-B 模型）

```
时钟:  _____|‾‾‾‾‾|_____|‾‾‾‾‾|_____|‾‾‾‾‾|_____
           Edge1      Edge2      Edge3
        ← EX 阶段 →← MEM 阶段 →← WB 阶段 →

EX 阶段（Edge1 ~ Edge2）:
  alu_result, wea, wdata 组合线有效
  → 直连 bridge 输入端口

Edge2（EX→MEM 时钟沿）:
  ├── BRAM 锁存地址（读）/ 执行写入（写）
  ├── MMIO always_ff 捕获写数据（写）
  └── EX/MEM 寄存器锁存 alu_result → mem_alu_result

MEM 阶段（Edge2 ~ Edge3）:
  ├── DRAM: BRAM Clk-to-Q(2.0ns) + output MUX(1.5ns) = ~3.5ns
  ├── MMIO: mem_alu_result(0.3ns) → 地址译码 → 组合读 = ~3.0ns  ← 并行！
  └── 最终 MUX: max(3.5, 3.0) + MUX(0.3ns) = ~3.8ns → bridge_rdata

Edge3（MEM→WB 时钟沿）:
  MEM/WB 寄存器捕获 bridge_rdata → wb_dram_dout

WB 阶段（Edge3 ~）:
  wb_dram_dout → mem_interface load → wb_mux → 写回 regfile
```

### 读写操作总结

| 操作 | 信号来源 | 发生时刻 |
|---|---|---|
| DRAM 读 | EX: alu_result → BRAM 直连 | Edge2 锁存 → MEM 阶段 Clk-to-Q 出数据 |
| MMIO 读 | MEM: mem_alu_result → 组合逻辑 | MEM 阶段内完成（组合） |
| DRAM 写 | EX: alu_result + wea + wdata | Edge2 瞬间写入 |
| MMIO 写 | EX: alu_result + wea + wdata | Edge2 瞬间写入（同一个沿） |

### 与 standalone 的差异

| 方面 | standalone（改动前） | standalone（改动后） | 集成后 |
|---|---|---|---|
| DRAM 类型 | BRAM **有** Reg（2拍） | BRAM **无** Reg（1拍） | 同左 |
| DRAM 数据可用 | WB 阶段 | **MEM 阶段** | 同左 |
| DRAM 数据传递 | 直连 mem_interface | 经 **MEM/WB 寄存器** | 同左 |
| DRAM 位置 | cpu_top 内部 | cpu_top 内部 | bridge 内部（外部） |
| MMIO | 不存在 | 不存在 | 组合读 + 时序写 |
| IROM | BRAM 无 Reg（1拍） | 不变 | 不变，预取方案取指 |

### 需要修改的文件

| 文件 | 改动 |
|---|---|
| `if_id_reg.sv` | ✅已完成：新增 `if_inst` / `id_inst` 传递，锁存指令到 ID 阶段 |
| `cpu_top.sv` | ✅已完成：`irom_addr` 三路 MUX + decoder/imm_gen 使用 `id_inst` |
| `pc_reg.sv` | ✅已完成：复位值改为 `0x7FFF_FFFC`（预取方案） |
| `mem_interface.sv` | ✅已完成：`* 4'd8` → `{addr, 3'b0}` 修复 |
| `student_top.sv` | ✅已完成：CPU + IROM + bridge 连线 |
| `perip_bridge.sv` | ✅已完成：BRAM + MMIO 组合读 + 写逻辑 |

### cpu_top 新增端口（集成时）

```systemverilog
module cpu_top (
    input  logic        clk,
    input  logic        rst_n,
    // IROM 接口 (IF stage)
    output logic [31:0] irom_addr,      // = branch_target / pc / next_pc 三路 MUX
    input  logic [31:0] irom_data,      // 指令（BRAM 1拍 Clk-to-Q，IF 阶段有效）
    // 外设总线 (EX stage → bridge)
    output logic [31:0] perip_addr,     // = alu_result
    output logic [31:0] perip_addr_sum, // = alu_sum（加法器直出，跳过 ALU output MUX）
    output logic [3:0]  perip_wea,      // = mem_interface store wea
    output logic [31:0] perip_wdata,    // = store_data_shifted
    input  logic [31:0] perip_rdata     // bridge 返回数据（MEM 阶段有效）
);
```

### IROM 预取时序

IROM 为 1 拍 BRAM（无 Output Register），采用预取方案：

```
irom_addr = branch_flush  ? branch_target :   // 分支：预取目标
            !if_allowin   ? pc :               // 停顿：保持当前地址
                            next_pc;           // 正常：预取下一条
```

IF/ID 寄存器同时锁存 `id_pc`（来自 pc）和 `id_inst`（来自 irom_data），确保 ID 阶段天然对齐。
PC 复位值 = `0x7FFF_FFFC`（= text_base - 4），使首拍 `next_pc = 0x8000_0000`。

---

## 5. 自研 perip_bridge 设计要点

### 读路径：DRAM 1 拍 + MMIO 组合，MEM 阶段统一输出

- **DRAM**：BRAM 无 output register。EX 地址直连 → Edge2 锁存 → MEM 阶段 Clk-to-Q
- **MMIO**：MEM 阶段用 `mem_alu_result`（从 EX/MEM 寄存器来）做地址译码 → 组合读
- 两者在 MEM 阶段并行产生数据，最终 MUX 选择输出
- **MMIO 组合路径（~3ns）< BRAM 路径（~3.5ns），不构成瓶颈**

```systemverilog
// DRAM：BRAM 1 拍读
BRAM u_dram (
    .clka  (clk),
    .addra (addr[17:2]),         // EX 阶段直连
    .wea   (is_dram ? wea : 4'b0),
    .dina  (wdata),
    .douta (dram_douta)          // MEM 阶段 Clk-to-Q 有效
);

// MMIO：组合读（MEM 阶段）
always_comb begin
    mmio_rdata = 32'd0;
    case (mem_addr)              // mem_alu_result 从 cpu_top 传入
        SW0_ADDR: mmio_rdata = sw[31:0];
        KEY_ADDR: mmio_rdata = {24'd0, key};
        CNT_ADDR: mmio_rdata = cnt_val;   // gray_to_bin 组合逻辑，~2.5ns
        ...
    endcase
end

// 输出 MUX（MEM 阶段）
wire is_dram_r;  // 打一拍的地址范围标志
assign rdata = is_dram_r ? dram_douta : mmio_rdata;
```

### Counter (CNT) 处理

- `counter.sv` 不可修改，输出 `perip_rdata = gray_to_bin(...)` 是纯组合逻辑（~5-6 级 LUT，~2.5ns）
- 在 MEM 阶段做组合读时，gray_to_bin 延迟（~2.5ns）< BRAM 延迟（~3.5ns），不构成关键路径
- **无需额外打拍处理**
- 未来如有更复杂外设使组合路径超过 BRAM 路径，再考虑改为同步读

### 写路径

- 所有写操作在 **Edge2（EX→MEM 时钟沿）** 统一执行
- DRAM 写：`{4{is_dram}} & wea` 直驱 BRAM，`is_dram` 使用 `addr_sum[31:18]`（跳过 ALU output MUX）
- MMIO 写：`always_ff` 按 `addr_sum[6:4]` 部分译码（3-bit）写入 LED / SEG / CNT enable
  - 优化：`!is_dram` 已确认 MMIO 空间，只需区分设备（LED=100, SEG=010, CNT=101）
- 写信号全部来自 EX 阶段组合输出（alu_result, alu_sum, wea, wdata）

---

## 6. 待定事项

- [x] DRAM 容量已确定：65536×32bit（256KB）
- [x] IROM IP 确认：1 拍 BRAM（无 Output Register），预取方案取指
- [x] 复位极性：模板 `w_clk_rst` 高有效，cpu_top `rst_n` 低有效，在 student_top 中反转
- [x] 汇编程序数据段地址已确认为 `0x8010_0000` 起始
- [ ] bridge 需要 `mem_alu_result` 输入端口（来自 cpu_top，用于 MMIO 组合读地址）
