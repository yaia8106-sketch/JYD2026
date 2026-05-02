# 文档写作上下文 (Writing Context)

> **用途**：AI 编写比赛文档时的**唯一上下文入口**。每次新对话写文档前先读此文件。
> **维护**：每次设计变更后由 AI 同步更新。
> **最后更新**：2026-05-02
> **当前状态**：初赛设计文档、测评报告、仿真报告、上板验证报告、bit 压缩包和演示视频均已生成到 `04_Submission/`。本文档后续主要作为复赛/答辩材料的素材索引。

---

## 1. 硬数据摘要（可直接引用的数字）

### 1.1 核心指标

| 指标 | 值 | 备注 |
|------|-----|------|
| 指令集 | RV32I 37 条（除 FENCE/ECALL/EBREAK） | 赛题要求的全部 37 条 |
| 流水线级数 | 5 级（IF → ID → EX → MEM → WB） | |
| 目标频率 | 250 MHz（时序收敛） | WNS = +0.120ns，但**提交 200MHz** 以确保稳定 |
| **提交频率** | **200 MHz** | 4/4 COE 全通过，稳定可靠 |
| riscv-tests（官方） | **37/37 PASS**（iverilog 仿真） | 与赛题 37 条指令一一对应 |
| riscv-tests（自定义） | 6/6 PASS（iverilog 仿真） | simple, ld_st, st_ld, bp_stress, coprime, dcache_test |
| FPGA COE 测试 | src0 / src1 / src2 全通过 @ 200MHz | 赛方性能测试程序均通过 |
| 分支预测准确率 | 平均 84.81%（4 程序 5M 指令） | BTB=128, GHR=8, RAS=4 |
| 分支预测 CPI 贡献 | 平均 CPI ≈ 1.141 | Flush penalty = 3 cycles |
| DCache 命中率 | 平均 97.94%（2W 2KB/16B） | 最高 src1 ≈ 100%，最低 src0 = 95.78% |
| DCache 加速比 | 平均 +44.0%（无 Cache@200MHz vs DCache@250MHz） | 含频率 200→250MHz 贡献，`cache_sim.py` 输出 |

### 1.2 资源用量

| 资源 | 用量 | 说明 |
|------|------|------|
| IROM | 16KB，Vivado Block Memory ROM IP | **无 output register，1 拍延迟**，预取方案取指 |
| DRAM | 256KB (65536×32bit)，SDP BRAM | 64×BRAM36，DOB_REG=1 (2-cycle 读延迟) |
| DCache Data RAM | 2×BRAM18 (每 way 1 个) | 2KB 总容量，50% 利用率 |
| BP LUTRAM | ~6,280 bits | BTB 128 + PHT 256 + SEL 256 + RAS 4 |
| FPGA 芯片 | Xilinx Kintex-7 | 赛事数字孪生平台板卡 |

### 1.3 时序关键数据

| 路径 | WNS (ns) | 逻辑级数 | 类型 |
|------|:--------:|:-------:|------|
| PC → IROM（全局最紧之一） | +0.120 | 6 | BP 预测 → 取指地址 |
| DCache → DRAM（全局最紧之一） | +0.120 | 0 | 纯布线（64×BRAM 扇出） |
| ID/EX → BP LUTRAM WE | +0.034 | 8 | BTB/PHT 更新路径 |
| EX 前递环路 | +0.063 | — | ALU 进位链固有底线 |

### 1.4 性能对比（基于仿真 CPI 模型）

| 配置 | 平均 CPI | 对比 |
|------|:--------:|------|
| 无预测 + 无 Cache @ 200MHz | ~1.37 + DRAM stall | 基线 |
| Tournament BP + 无 Cache @ 200MHz | ~1.141 | BP 降低 ~0.23 CPI |
| Tournament BP + DCache 2KB @ 250MHz | ~1.167 | 对比无 Cache @ 200MHz 整体加速 **+44%** |

> **数据来源**：`bp_sweep.py`（152 种 BP 配置扫描）、`cache_sim.py`（cycle-accurate DCache 仿真）。
> 所有性能数据均来自 Python ISA 仿真器，模型严格匹配 RTL 行为。
> **+44% 说明**：公式 = `(base_CPI/200MHz) / (cache_CPI/250MHz)`，包含 DCache 降低 CPI 和频率 200→250MHz 两部分贡献。写文档时需注明这是"引入 DCache 使 250MHz 成为可能的综合加速比"

---

## 2. 架构亮点提炼（文档重点展示）

### 亮点 1：五级流水线 + 握手协议
- valid/allowin/ready_go 三信号握手，每级独立控制
- 天然支持多周期操作（DCache miss stall）和动态反压
- 与经典"全局 stall"方案相比，更灵活、可扩展

### 亮点 2：NLP 两级 Tournament 分支预测器
- **IF 级 (L0)**：BTB 查表 + Bimodal BHT[1] 快速预测（1 cycle 内完成）
- **ID 级 (L1)**：Tournament 仲裁（Bimodal vs GShare via Selector），纠正 L0 错误
- **EX 级**：状态更新（BTB/BHT/PHT/GHR/Selector/RAS 全部在此更新）
- 组件：BTB 128-entry 直接映射 + 8-bit GHR + 256-entry GShare PHT + 256-entry Selector + 4-deep RAS
- 4 程序平均准确率 84.81%，CPI ≈ 1.141

### 亮点 3：2KB DCache（Write-Through + Write-Allocate）
- 2-way set-associative，16B line (4 words)，LRU 替换
- 1-entry Store Buffer：SB 后台排空，非连续 store 零开销
- 6 状态 Refill FSM：BURST 读 + SB DRAIN + DONE，约 9 cycles/miss
- Store forwarding + Refill forwarding：减少 RAW stall
- **核心作用**：隔离 CPU 与 DRAM 64×BRAM36 高扇出，使 250MHz 时序收敛成为可能

### 亮点 4：IROM 预取方案
- IROM 为 1 拍 BRAM（无 output register），通过 4 路优先级 MUX + 指令暂存寄存器实现预取
- 优先级：flush > NLP redirect > BP prediction > sequential (pc+4)
- stall 处理已从 MUX 移至 `irom_data_held` 寄存器，解耦 allowin 链→IROM 关键路径
- `pc_plus4` 寄存器预计算：消除 `pc+4` carry chain，省 3 级 CARRY4
- PC 复位值 = `0x7FFF_FFFC`（text_base - 4），首拍自动预取第一条指令

### 亮点 5：硬件资源共享 + AND-OR 平坦化
- **共享加法器**：ADD/SUB/SLT/SLTU 共用加法器（条件取反 src2）
- **共享移位器**：SLL/SRL/SRA 共用右移器（位翻转实现左移）
- **并行 AND-OR MUX**：前递、ALU 输出、`irom_addr`、`bp_target` 等全部采用 one-hot AND-OR，组合深度 2 级 LUT
- ALU 编码 `{funct7[5], funct3}` 直驱硬件控制，零额外译码开销

### 亮点 6：3 级数据前递
- 前递优先级：EX > MEM > WB > regfile（read-first）
- 并行匹配 + 优先级编码 + one-hot AND-OR MUX
- MEM 级显式排除 Load（数据不可用），Load-use 2 拍 stall
- JAL/JALR 的 link 地址 (PC+4) 在 EX 级预算，通过寄存器传递前递

### 亮点 7：系统级时序优化（从 200MHz → 250MHz）
- Flush 延迟 EX→MEM：将分支判断结果打一拍，消除跨级组合路径
- Pblock 约束：CPU + IROM + DCache 共置于 2 个 Clock Region
- bp_target 串行链并行化：利用 don't-care 优化省 3 级 LUT
- DCache tag 直写 LUTRAM：省去 S_DONE 前递 MUX
- BTB/PHT 更新寄存化：延迟 1 拍写入，解耦 EX 比较器→LUTRAM WE

### 亮点 8：Python 量化驱动设计决策
- `bp_sweep.py`：24 核并行扫描 152 种 BP 配置（BTB × GHR × RAS），107 秒完成
- `cache_sim.py`：精确匹配 RTL 的 cycle-accurate cache 仿真，12 配置 × 4 程序
- `bp_coldstart_sim.py`：冷启动预测准确率估算（10M 指令）
- 所有设计参数选择（BTB=128、GHR=8、DCache 2KB 2-way 16B line）均有量化数据支撑

---

## 3. 特色功能卖点（评委视角）

### 3.1 "别人可能没有"的差异化特征

1. **Tournament 分支预测器**：大多数参赛队可能只有简单的 always-not-taken 或 1-bit BHT，我们有完整的 Tournament（Bimodal + GShare + Selector + RAS）
2. **Data Cache**：多数参赛队直连 DRAM，我们用 DCache 隔离高扇出 BRAM，支撑高频
3. **量化驱动设计**：不是拍脑袋选参数，而是用 Python ISA 仿真器扫描 100+ 种配置，数据驱动每个设计决策
4. **高频设计能力**：250MHz 时序收敛（WNS +0.120ns），提交稳定的 200MHz 版本，远超赛题默认 50MHz
5. **握手协议流水线**：非全局 stall 的灵活架构，天然兼容 cache miss 等变延迟操作

### 3.2 值得在"快速预览简介"页突出的数字

- **200 MHz** FPGA 验证通过，4/4 测试程序全通过（250MHz 时序亦收敛）
- **37/37** 官方 riscv-tests 仿真全通过 + 6 个自定义功能测试全通过
- **Tournament 分支预测器**：84.81% 平均准确率
- **2KB DCache**：97.94% 平均命中率，整体加速 +44%
- **20 个 SystemVerilog 模块**，~100KB RTL 代码

---

## 4. 文档素材与提交状态

### 4.1 设计报告（CPU 设计文档）

**对应模板**：`设计报告模版.txt`

| 章节 | 需要的内容 | 素材来源 |
|------|-----------|---------|
| 1.1 项目背景 | 数字孪生竞赛 + RV32I 赛题 | `contest/parsed/比赛要求.txt` |
| 1.2 设计目标 | 37 条指令 + 200MHz 稳定运行 + 低 CPI | 本文件 §1.1 |
| 1.3 设计平台 | Vivado 2024.1, SystemVerilog, Kintex-7 | `digital_twin_integration.md` §1 |
| 2.1 指令集支持 | 37 条指令列表 | `isa_encoding.md` §5 |
| 2.2 整体架构图 | 5 级流水线框图 | 已生成 `fig1_cpu_architecture.png` |
| 2.3 各模块设计 | PC/ALU/Regfile/Decoder/FWD/DCache/MMIO | `pipeline.md`, `design_decisions.md`, 各 `_spec.md` |
| 2.4 数据通路信号表 | 14 个控制信号定义 | `isa_encoding.md` §1 |
| 2.5 控制器设计 | 译码真值表 + 控制信号表 | `isa_encoding.md` §5 |
| 3.1 流水线优化 | 握手协议详解 | `pipeline.md` §3-4 |
| 3.2 分支预测 | Tournament 架构 + 量化数据 | `bp_analysis.md`, `design_decisions.md` §J |
| 3.3 DCache | 架构 + 量化数据 | `cache_analysis.md`, `design_decisions.md` §L |
| 3.4 时序优化 | Flush 延迟/AND-OR/pc_plus4/Pblock | `design_decisions.md` §K/M/N/S/T |
| 4.x 特色功能 | DCache + Tournament BP + 量化驱动 | 本文件 §3 |
| 5.x 附录 | 代码清单 + 目录结构 | `02_Design/rtl/` 文件列表 |
| 封面 | 作品名称 + 队伍编号 + 大赛 LOGO | `templates/第十届集创赛文档封面模板.txt` |
| 快速预览简介 | 1-2 页核心亮点 | 本文件 §3.2 |

**图表状态**：
- [x] 5 级流水线整体架构图
- [x] 模块层次 / 工程目录图
- [x] DCache、Tournament BP、时序优化内容已在正文中用表格和文字说明

### 4.2 仿真报告（CPU 测评报告）

**对应模板**：`仿真报告模版.txt`

| 章节 | 需要的内容 | 素材来源 |
|------|-----------|---------|
| 1.1 仿真工具 | iverilog + Vivado Simulation | 实际使用情况 |
| 1.2 测试环境 | TB 架构、仿真参数 | `02_Design/sim/riscv_tests/` |
| 2.1 指令集测试 | 37 个官方 riscv-test 用例说明 | `riscv-tests/` 目录，与赛题 37 条指令一一对应 |
| 2.2 自定义功能测试 | 6 个自定义测试说明 | simple, ld_st, st_ld, bp_stress, coprime, dcache_test |
| 2.3 性能分析 | BP/DCache 量化数据 | `bp_sweep.py` + `cache_sim.py` 输出 |
| 3.1 指令集结果 | 37/37 PASS 截图/日志 | 已生成 `run_all.png` |
| 3.2 自定义测试结果 | 6/6 PASS + 各测试意义 | 已合并展示在 `run_all.png` 和结果表 |
| 3.3 性能数据 | CPI/命中率/准确率表格 | Python 仿真脚本输出，标注方法论 |

**截图/日志状态**：
- [x] `build_tests.sh` 编译截图
- [x] `run_all.sh` 43/43 PASS 截图
- [x] `bp_coldstart.png` 分支预测仿真结果截图
- [x] `cache_sim.png` DCache 命中率仿真结果截图

### 4.3 上板验证报告

**对应模板**：`上板验证报告模版.txt`

| 章节 | 需要的内容 | 素材来源 |
|------|-----------|---------|
| 1.1 FPGA 平台 | Kintex-7, 数字孪生平台 | `digital_twin_integration.md` |
| 1.2 烧录工具 | Vivado Hardware Manager 版本 | 实际版本号 |
| 1.3 上电测试说明 | 数字孪生通信方式 | `比赛要求.txt` §3 |
| 2.1 测试用例 | 3 个赛方 COE 程序说明 (src0/src1/src2) | `02_Design/coe/` |
| 2.2 运行流程 | 烧录步骤 | 实际操作记录 |
| 3.1 数字孪生截图 | 3 个 src 程序运行结果照片 | 已生成 `src0.png` / `src1.png` / `src2.png` |
| 3.2 结果总结 | 37/37 指令通过 + 性能时间 (ms) | FPGA 实际运行数据 |

**拍照/截图状态**：
- [x] src0 / src1 / src2 运行时的数码管 + LED 照片（状态 4：✅ + 37 + 时间）
- [x] 时序和资源数据已摘录到测评报告
- [x] 演示视频已记录烧录/运行过程

**提交比特流**：src0 / src1 / src2 各一个 .bit 文件（200MHz），共 3 个

---

## 5. AI 使用声明归档

> 最终提交文档中的声明以 `04_Submission/技术文档/设计报告.md` 和 `测评报告.md` 为准。此处保留一份摘要，便于后续答辩或复赛材料复用。

### AI 工具使用声明

**使用的 AI 工具**：
- Claude (Anthropic)，Claude 4 Sonnet
- Windsurf IDE，Cascade

**使用场景与用途**：
1. **方案讨论与局部草稿**：辅助梳理微架构方案、局部 RTL/脚本草稿和调试思路。
2. **调试辅助**：根据仿真日志、Vivado warning 和时序报告辅助定位问题。
3. **设计空间探索**：辅助整理 `bp_sweep.py`、`cache_sim.py` 等 Python 仿真脚本和结果表述。
4. **文档整理**：辅助报告结构、文字初稿、表格和说明文字整理。

**AI 生成内容占比**（估算）：
- **架构方案与关键参数选择**：约 10%
- **RTL 与脚本实现**：约 30%
- **文档整理**：约 40%
- **验证结果与性能数据**：0%，均来自实际工具输出或 FPGA 运行并经人工复核

---

## 6. RTL 文件清单（当前实现摘要）

> 设计报告最终统计为 22 个 SystemVerilog 文件：19 个活跃模块 + 1 个定义包 + 2 个遗留文件。下表保留主要模块摘要。

| 模块 | 文件 | 功能 | 行数 |
|------|------|------|------|
| cpu_top | `cpu_top.sv` | 顶层连线 + 流水线控制 | ~800 |
| dcache | `dcache.sv` | 2KB 2-way DCache + Store Buffer | ~750 |
| branch_predictor | `branch_predictor.sv` | Tournament BP (BTB+BHT+GShare+SEL+RAS) | ~400 |
| branch_unit | `branch_unit.sv` | 分支判断 + flush 生成 | ~100 |
| decoder | `decoder.sv` | 指令译码器 (14 控制信号) | ~120 |
| alu | `alu.sv` | ALU (10 操作 + 共享加法器/移位器) | ~80 |
| alu_src_mux | `alu_src_mux.sv` | ALU 操作数选择 MUX | ~30 |
| forwarding | `forwarding.sv` | 3 级前递 (AND-OR MUX) | ~130 |
| regfile | `regfile.sv` | 32×32 寄存器堆 (read-first) | ~40 |
| imm_gen | `imm_gen.sv` | 立即数生成器 (5 类型) | ~35 |
| pc_reg | `pc_reg.sv` | PC 寄存器 + pc_plus4 预算 | ~35 |
| if_id_reg | `if_id_reg.sv` | IF/ID 级间寄存器 | ~80 |
| id_ex_reg | `id_ex_reg.sv` | ID/EX 级间寄存器 | ~150 |
| ex_mem_reg | `ex_mem_reg.sv` | EX/MEM 级间寄存器 | ~130 |
| mem_wb_reg | `mem_wb_reg.sv` | MEM/WB 级间寄存器 | ~80 |
| mem_interface | `mem_interface.sv` | Load 字节提取 + Store WEA 生成 | ~80 |
| wb_mux | `wb_mux.sv` | WB 写回数据选择 MUX | ~25 |
| next_pc_mux | `next_pc_mux.sv` | [已废弃，内联到 cpu_top] | — |
| student_top | `platform/student_top.sv` | 平台集成层 (CPU+IROM+DCache+MMIO) | ~200 |
| mmio_bridge | `platform/perip_bridge.sv` | MMIO 外设桥 (LED/SEG/CNT/SW/KEY) | ~100 |

---

## 7. 项目里程碑时间线（文档中可展示）

| 日期 | 里程碑 | 说明 |
|------|--------|------|
| 2026-04 初 | M1-M2 | RTL 完成 + 仿真全通过 |
| 2026-04 中 | M3-M5 | FPGA 验证 50MHz → 200MHz |
| 2026-04-18 | M6 | 纯净基线 FPGA 验证 @ 200MHz |
| 2026-04-19 | M7 | Tournament BP 合并 + FPGA 验证 @ 200MHz |
| 2026-04-24 | M9 | DCache 实现 + 4/4 COE 全 FPGA 通过 |
| 2026-04-29 | M10+ | 250MHz 时序收敛 (WNS +0.120ns) |
| 2026-05-02 | M11 | 初赛提交包定稿：技术文档、bit 压缩包、演示视频齐备 |

---

## 8. 格式提醒

- **命名规则**：`队伍编号+初赛+文件性质`（如 `CICC10xxxxx+初赛+设计文档`）
- **禁止出现**：学校名/老师名（引用除外），违者扣 5 分
- **AI 声明必须有**：未声明扣 10 分
- **封面页 + 快速预览简介页**：必须包含
- **排版**：A4 纵向，小四宋体 + Times New Roman，1.5 倍行距
- **标题层级**：不超过 3 级
- **文件格式**：.docx + .pdf 同时提交
- **截止时间**：**2026-05-07 23:59**

---

## 9. 待确认 / 待修正事项

- [x] **`current/` 命名**：正式提交文档只使用 src0 / src1 / src2 赛方程序，不再将 current 作为提交用例
- [x] **提交频率确认**：提交 200MHz 稳定版，250MHz 作为时序收敛成果展示
- [x] **Vivado 版本号**：Vivado 2024.1
- [ ] **线上提交状态**：橙色云平台上传后再勾选
- [ ] **中期报告表单**：线上填写后再勾选

---

## 10. 写作规范

- **数据驱动**：每当引用性能数据时，必须标注方法论（用什么工具、什么参数、得出什么结论）
  - 例："使用 `bp_sweep.py` 对 152 种 BP 配置进行全参数扫描（4 个赛方测试程序 × 5M 指令/程序），结果表明 BTB=128 + GHR=8 配置在性能与时序之间取得最佳平衡，平均准确率 84.81%"
- **官方测试与自定义测试分开写**：37 个官方 riscv-tests 单独一节，6 个自定义测试另起一节说明设计动机
- **避免空洞论断**：不写"性能大幅提升"，写"平均 CPI 从 1.37 降至 1.141（改善 16.7%）"
