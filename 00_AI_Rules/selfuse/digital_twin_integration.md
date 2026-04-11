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

### 决策倾向：BRAM 无 Output Register

理由：
- 分布式 RAM：大容量时消耗大量 LUT，不适合 DRAM
- BRAM 有 Output Reg（2 拍）：需要流水线额外等 1 拍或增加流水级
- BRAM 无 Output Reg（1 拍）：延迟适中，可与 MMIO 同步读对齐

### DRAM 容量待定

- 当前 standalone 版本：65536 × 32bit（256KB），约 64 个 BRAM36
  - 3 级输出 MUX，Clk-to-Q ~2.0ns + MUX ~1.5ns = ~3.5ns
  - 5.0ns 周期（200MHz）下余量仅 ~1.5ns，偏紧
- 缩减到 16384 × 32bit（64KB）：约 16 个 BRAM36
  - 2 级输出 MUX，时序更宽裕
- 实际容量取决于比赛程序需求

---

## 4. 流水线适配方案

### 核心思路：保持 EX 阶段直连 BRAM，与 standalone 一致

BRAM 选型：无 Output Register（1 拍读延迟）。
ALU 输出在 EX 阶段直连 bridge 地址端口，BRAM 在 EX→MEM 时钟沿锁存，MEM 阶段 Clk-to-Q 后数据可用。
**这与当前 standalone 的 DRAM 访存方式完全一致，流水线结构不需要改。**

```
EX  (cycle N):   alu_result → bridge.addr（直连，组合）
                 wea/wdata  → bridge.wea/wdata（直连，组合）
                 ─── EX→MEM 时钟沿 ───
                 BRAM 锁存地址 / 执行写入
                 MMIO 寄存器锁存读数据
MEM (cycle N+1): BRAM Clk-to-Q (~2.0ns) → bridge_rdata
                 MMIO Clk-to-Q (~0.3ns) → bridge_rdata
                 → 进入 cpu_top → mem_interface load 侧 → MEM/WB 寄存器
WB  (cycle N+2): wb_mux 选择最终写回数据
```

### 与 standalone 的差异

| 方面 | standalone（当前） | 集成后 |
|---|---|---|
| DRAM 位置 | cpu_top 内部 | bridge 内部（外部） |
| DRAM 类型 | BRAM **有** Output Reg（2拍） | BRAM **无** Output Reg（1拍） |
| DRAM 数据可用 | WB 阶段 | **MEM 阶段** |
| MMIO | 不存在 | 同步读（`always_ff`，1拍对齐 BRAM） |
| mem_interface | 接 cpu_top 内部线 | 接 cpu_top 外部端口 |

### 需要修改的文件

| 文件 | 改动 |
|---|---|
| `cpu_top.sv` | 删内部 IROM/DRAM，新增外设总线端口。mem_interface 改接外部信号 |
| `ex_mem_reg.sv` | 不需要改 |
| `mem_wb_reg.sv` | 不需要改 |
| `mem_interface.sv` | 不需要改代码，输入仍从 EX 阶段信号取 |
| `student_top.sv` | 新写：CPU + IROM + bridge 连线 |
| `perip_bridge.sv` | 自研：BRAM + MMIO 同步读 + 写逻辑 |

### cpu_top 新增端口

```systemverilog
module cpu_top (
    input  logic        clk,
    input  logic        rst_n,
    // IROM 接口 (IF stage)
    output logic [31:0] irom_addr,      // = next_pc
    input  logic [31:0] irom_data,      // 指令（BRAM Clk-to-Q 后有效）
    // 外设总线 (EX stage → bridge)
    output logic [31:0] perip_addr,     // = alu_result
    output logic [3:0]  perip_wea,      // = mem_interface store 输出 wea
    output logic [31:0] perip_wdata,    // = mem_interface store 输出（已移位）
    input  logic [31:0] perip_rdata     // bridge 返回数据（MEM 阶段 Clk-to-Q 有效）
);
```

---

## 5. 自研 perip_bridge 设计要点

### 读路径统一：全部 1 拍延迟（EX→MEM 时钟沿锁存）

- **DRAM**：BRAM 无 output register。EX 阶段地址直连 → EX→MEM 沿锁存 → MEM 阶段 Clk-to-Q 输出
- **MMIO**：`always_ff` 在 EX→MEM 沿锁存读数据 → MEM 阶段 Clk-to-Q 输出
- 两者同时在 MEM 阶段有效，通过 `is_dram_r`（打一拍的地址译码）MUX 选择

```systemverilog
// MMIO 同步读（对齐 BRAM 1 拍延迟）
always_ff @(posedge clk) begin
    case (addr)
        SW0_ADDR: mmio_rdata <= sw[31:0];
        KEY_ADDR: mmio_rdata <= {24'd0, key};
        CNT_ADDR: mmio_rdata <= cnt_val;   // gray_to_bin 被寄存器切断
        ...
    endcase
    is_dram_r <= is_dram;  // 记住上一拍是 DRAM 还是 MMIO
end

// 输出 MUX（MEM 阶段两路同时有效）
assign rdata = is_dram_r ? dram_douta : mmio_rdata;
```

### Counter (CNT) 处理

- `counter.sv` 不可修改，输出 `perip_rdata = gray_to_bin(...)` 是纯组合逻辑（~5-6 级 LUT）
- 由于 MMIO 读本身就是 `always_ff`（同步读），gray_to_bin 的组合延迟在 EX 阶段计算完毕，在 EX→MEM 沿被寄存器切断
- **无需额外处理**，CNT 自然和其他 MMIO 一样走同步读路径

### 写路径

- DRAM 写：`perip_wea` + `perip_wdata` 直接驱动 BRAM 的 `wea` + `dina`（地址译码门控 wea）
- MMIO 写：LED / SEG / CNT enable 在 `always_ff` 中按地址写入
- 写操作在 EX→MEM 时钟沿执行

---

## 6. 待定事项

- [ ] DRAM 容量最终确定（影响 BRAM output MUX 级数和时序）
- [ ] IROM IP 名称和配置确认
- [ ] 复位极性：模板 `w_clk_rst` 高有效，cpu_top `rst_n` 低有效，在 student_top 中反转
- [ ] 汇编程序数据段地址需改为 `0x8010_0000` 起始

