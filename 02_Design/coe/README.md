# COE 文件目录

本目录存放 Vivado Block Memory Generator 使用的初始化文件（`.coe`）。

---

## 目录结构

```
coe/
├── current/          ← 当前使用的 COE（数字孪生平台调试用）
│   ├── irom.coe      1271 条指令，hex 格式
│   └── dram.coe      12 个 word 初始数据
│
├── src0/             ← 赛方测试程序（37 项测试）
│   ├── irom.coe      2035 条指令
│   └── dram.coe      12 个 word 初始数据
│
├── src1/             ← 赛方测试程序变体
│   ├── irom.coe      1909 条指令
│   └── dram.coe      12 个 word 初始数据
│
└── src2/             ← 赛方测试程序变体
    ├── irom.coe      1996 条指令
    └── dram.coe      12 个 word 初始数据
```

## 使用说明

- **调试和仿真时默认使用 `current/` 下的文件**
- `src0/`、`src1/`、`src2/` 为赛方提供的不同测试程序
- 所有 COE 文件格式均为 `memory_initialization_radix=16`（十六进制）

## 分析工具

| 脚本                | 功能               | 用法                                            |
| ------------------- | ------------------ | ----------------------------------------------- |
| `analyze_coe.py`  | 静态指令分布统计   | `python3 analyze_coe.py`                      |
| `disasm_coe.py`   | COE 反汇编         | `python3 disasm_coe.py <coe文件> [base_addr]` |
| `bp_simulator.py` | 分支预测器配置对比 | `python3 bp_simulator.py`                     |
| `bp_sweep.py`     | 多核并行全参数扫描 | `python3 bp_sweep.py`                         |

所有仿真结果输出到 `sim_output/` 目录（已加入 `.gitignore`）。

---

### bp_simulator.py

**测试内容**：对几组预定义的预测器配置进行对比评估。

**固定变量**：

- 测试程序：current / src0 / src1 / src2（四个程序全部跑）
- 仿真周期：2,000,000 cycles / 程序
- JALR 策略：非 RET 的 JALR 不预测、不存入 BTB
- Tag 宽度：8 bit

**测试变量**（在脚本底部 `configs` 列表中修改）：

| 变量         | 当前测试值           | 说明                 |
| ------------ | -------------------- | -------------------- |
| BTB 大小     | 32, 64               | 总 entry 数          |
| BTB 映射方式 | 直接映射, 2 路组相联 | assoc=1 vs assoc=2   |
| BHT 模式     | 内嵌, 独立(128)      | embedded vs separate |
| RAS 深度     | 2, 4                 | entry 数             |

**输出内容**：每个程序的动态指令分布 + 各配置的命中率、CPI 节省、按类型命中率。

**内存映射**（与 `perip_bridge.sv` 一致）：

- IROM: `0x8000_0000` 起
- DRAM: `0x8010_0000 ~ 0x8014_0000`（256KB）
- MMIO: `0x8020_0000` 起（读返回 0，写忽略）

---

### bp_sweep.py

**测试内容**：多核并行穷举所有参数组合，按平均 CPI 节省排序。

**固定变量**：

- 测试程序：current / src0 / src1 / src2
- 仿真周期：5,000,000 cycles / 程序
- JALR 策略：不预测
- Tag 宽度：8 bit
- 索引方式：PC 直接取位

**测试变量**（全组合 = 48 种配置）：

| 变量         | 取值范围                   | 维度数 |
| ------------ | -------------------------- | :----: |
| BTB 大小     | 32, 64                     |   2   |
| BTB 映射方式 | 直接映射, 2 路组相联       |   2   |
| BHT 模式     | 内嵌, 独立(128), 独立(256) |   3   |
| RAS 深度     | 0, 2, 4, 8                 |   4   |

**输出内容**：Top 15 + 最差 5 配置，含四程序各自命中率和平均 CPI 节省。

**运行方式**：自动检测 CPU 核心数，使用 `multiprocessing.Pool` 并行。

## COE 格式参考

```
memory_initialization_radix=16;
memory_initialization_vector=
00108117,
03010113,
...
00008067;     ← 最后一行以分号结尾
```

在 Vivado Block Memory Generator 中使用：

- IROM IP → Other Options → Load Init File → 选择 `irom.coe`
- DRAM IP → Other Options → Load Init File → 选择 `dram.coe`

---

## 指令分布统计

> 以下数据由 `analyze_coe.py` 自动分析生成。

### current/（1271 条指令）

| 类型   | 数量 |  占比 | 包含指令                                                               |
| ------ | ---: | ----: | ---------------------------------------------------------------------- |
| ALU-I  |  457 | 36.0% | ADDI(428) SLLI(7) SRLI/SRAI(6) ORI(6) SLTI(4) XORI(2) ANDI(2) SLTIU(2) |
| Load   |  170 | 13.4% | LW(157) LB(6) LH(3) LBU(2) LHU(2)                                      |
| U-type |  160 | 12.6% | AUIPC(90) LUI(70)                                                      |
| Store  |  157 | 12.4% | SW(151) SB(4) SH(2)                                                    |
| JALR   |   97 |  7.6% | JALR(97)                                                               |
| B-type |   95 |  7.5% | BNE(70) BLT(8) BGE(6) BEQ(4) BLTU(4) BGEU(3)                           |
| JAL    |   81 |  6.4% | JAL(81)                                                                |
| ALU-R  |   54 |  4.2% | ADD/SUB(19) OR(16) SRL/SRA(5) AND(4) SLL(3) SLT(3) SLTU(2) XOR(2)      |

### src0/（2035 条指令）

| 类型   | 数量 |  占比 | 包含指令                                                                |
| ------ | ---: | ----: | ----------------------------------------------------------------------- |
| ALU-I  |  715 | 35.1% | ADDI(614) SLLI(75) SRLI/SRAI(7) ORI(6) SLTI(4) ANDI(4) SLTIU(3) XORI(2) |
| Load   |  355 | 17.4% | LW(342) LB(6) LH(3) LBU(2) LHU(2)                                       |
| Store  |  267 | 13.1% | SW(261) SB(4) SH(2)                                                     |
| U-type |  194 |  9.5% | LUI(104) AUIPC(90)                                                      |
| ALU-R  |  135 |  6.6% | ADD/SUB(100) OR(16) SRL/SRA(5) AND(4) SLL(3) SLT(3) SLTU(2) XOR(2)      |
| B-type |  133 |  6.5% | BNE(75) BGE(28) BLT(14) BEQ(9) BLTU(4) BGEU(3)                          |
| JAL    |  129 |  6.3% | JAL(129)                                                                |
| JALR   |  107 |  5.3% | JALR(107)                                                               |

### src1/（1909 条指令）

| 类型   | 数量 |  占比 | 包含指令                                                                |
| ------ | ---: | ----: | ----------------------------------------------------------------------- |
| ALU-I  |  674 | 35.3% | ADDI(595) SLLI(52) SRLI/SRAI(7) ORI(6) ANDI(6) SLTI(4) SLTIU(2) XORI(2) |
| Load   |  326 | 17.1% | LW(313) LB(6) LH(3) LBU(2) LHU(2)                                       |
| Store  |  248 | 13.0% | SW(241) SB(5) SH(2)                                                     |
| U-type |  185 |  9.7% | LUI(95) AUIPC(90)                                                       |
| B-type |  133 |  7.0% | BNE(78) BGE(20) BLT(14) BEQ(12) BLTU(6) BGEU(3)                         |
| JAL    |  132 |  6.9% | JAL(132)                                                                |
| JALR   |  106 |  5.6% | JALR(106)                                                               |
| ALU-R  |  105 |  5.5% | ADD/SUB(69) OR(16) SRL/SRA(5) AND(4) SLL(3) SLT(3) SLTU(3) XOR(2)       |

### src2/（1996 条指令）

| 类型   | 数量 |  占比 | 包含指令                                                                 |
| ------ | ---: | ----: | ------------------------------------------------------------------------ |
| ALU-I  |  707 | 35.4% | ADDI(613) SLLI(54) SRLI/SRAI(16) ANDI(8) ORI(6) SLTI(4) XORI(4) SLTIU(2) |
| Load   |  326 | 16.3% | LW(301) LHU(11) LB(6) LBU(5) LH(3)                                       |
| Store  |  266 | 13.3% | SW(250) SH(9) SB(7)                                                      |
| U-type |  197 |  9.9% | LUI(107) AUIPC(90)                                                       |
| JAL    |  136 |  6.8% | JAL(136)                                                                 |
| ALU-R  |  130 |  6.5% | ADD/SUB(91) OR(16) AND(6) SRL/SRA(5) XOR(4) SLL(3) SLT(3) SLTU(2)        |
| B-type |  126 |  6.3% | BNE(78) BGE(20) BEQ(11) BLT(10) BLTU(4) BGEU(3)                          |
| JALR   |  108 |  5.4% | JALR(108)                                                                |

---

### 跨文件对比（类型占比 %）

| 类型   | current | src0 | src1 | src2 | 平均 |
| ------ | :-----: | :--: | :--: | :--: | :--: |
| ALU-I  |  36.0  | 35.1 | 35.3 | 35.4 | 35.5 |
| Load   |  13.4  | 17.4 | 17.1 | 16.3 | 16.1 |
| Store  |  12.4  | 13.1 | 13.0 | 13.3 | 13.0 |
| U-type |  12.6  | 9.5 | 9.7 | 9.9 | 10.4 |
| B-type |   7.5   | 6.5 | 7.0 | 6.3 | 6.8 |
| JAL    |   6.4   | 6.3 | 6.9 | 6.8 | 6.6 |
| JALR   |   7.6   | 5.3 | 5.6 | 5.4 | 6.0 |
| ALU-R  |   4.2   | 6.6 | 5.5 | 6.5 | 5.7 |

**关键观察**：

- **ADDI 占比最高**（~31%），大量用于栈操作和地址计算
- **Load/Store 合计 ~29%**，内存访问密集
- **JAL + JALR 合计 ~12.6%**，跳转指令占比可观
- **分支指令 ~6.8%**，以 BNE 为主
- 四个测试程序的指令分布高度一致，说明来自相似的编译器 / 测试框架
