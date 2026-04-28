# TODO 清单

> 最后更新：2026-04-28

---

## 当前状态

**M9 里程碑已完成。** DCache 上线后全部 4 个 COE 程序 FPGA 验证通过。
**性能分析完成。** BP sweep + Cache sim + 时序报告分析 → 优化方案已确定。

- ✅ riscv-tests 43/43 PASS（iverilog）
- ✅ FPGA 4/4 COE 全部通过（current + src0 + src1 + src2）
- ✅ 200MHz 时序收敛（250MHz worst slack = 0.082ns, DCache→DRAM 布线瓶颈）
- ✅ BP 配置扫描完成（24 配置 × 4 程序, 详见 `selfuse/bp_analysis.md`）
- ✅ DCache 配置扫描完成（12 配置 × 4 程序, 详见 `selfuse/cache_analysis.md`）

---

## 🔥 当前待办（按优先级排列）

### 1. 比赛文档撰写 — **最高优先级**

**截止时间：2026-05-07 23:59**（还剩 ~10 天）

提交物清单（详见 `contest/README.md`）：

| 材料 | 模板 | 状态 |
|------|------|------|
| CPU 设计文档 | `contest/parsed/templates/设计报告模版.txt` | 🟡 Markdown 初稿已完成，待补实际数据 + 转 Word/PDF |
| 仿真报告 | `contest/parsed/templates/仿真报告模版.txt` | 🟡 Markdown 初稿已完成，待贴入实际仿真输出 + 转 Word/PDF |
| 上板验证报告 | `contest/parsed/templates/上板验证报告模版.txt` | 🟡 Markdown 初稿已完成，待填写性能数据/资源利用率/截图 + 转 Word/PDF |
| bit 文件 | — | ❌ 待放到 `04_Submission/技术数据/` |
| 演示视频（≤10min） | — | ❌ 需录制 |
| 中期报告表单 | `contest/parsed/中期报告检查通知.md` | ❓ 需确认 |

每份文档通用要求：
- 封面页（作品名称 + 队伍编号 + 大赛 LOGO）
- 快速预览简介页（1-2页，放封面/目录后第一页）
- AI 工具使用声明（工具名+版本、使用场景、生成占比）
- **禁止出现学校/老师信息**
- Word(.docx) + PDF 同时提交，命名：`队伍编号+初赛+文件性质`

工作计划：Markdown 初稿已在 `04_Submission/技术文档/` 中完成 → 下一步：
1. 运行 `run_all.sh` 贴入实际仿真输出
2. 填写上板性能数据、资源利用率、时序信息
3. 添加数字孞生平台截图
4. 转 Word/PDF + 加封面页

### 2. 性能优化实施 — 低风险参数调整

**已完成分析**, 待实施 RTL 改动。详见 `selfuse/bp_analysis.md` 和 `selfuse/cache_analysis.md`。

| 优先级 | 改动 | CPI 收益 | 时序风险 | 资源成本 | 状态 |
|:------:|------|:--------:|:--------:|:--------:|:----:|
| **1** | **DCache 2KB→4KB** (SETS 64→128) | -0.005 | ✅ 零 | ✅ 零 BRAM (填满已有 BRAM18) | ❌ 待实施 |
| **2** | **BTB 64→128** (BTB_ENTRIES) | -0.014 | ✅ 安全 (读路径余量 0.7ns+) | +2,560 bits LUTRAM | ❌ 待实施 |
| 3 | GHR 8→10 (GHR_W) | -0.009 | ⚠️ 需综合验证 | +4,096 bits LUTRAM | ❌ 待验证 |

**关键发现** (bp_sweep.py, 24 核并行, 152 个评估):
- **src0 BTB 容量瓶颈**: 64-entry BTB 有 37,940 次 BTB miss+taken → BTB=128 后降到 202
- **RAS 深度无效果**: 2/4/8/16 全部相同 (调用链深度 ≤ 2)
- **GHR=12+时序违例**: PHT 4096+ entries → LUTRAM MUX 6+ 级, 超出 ID/EX→BP 路径余量 (0.339ns)

### 3. 250MHz 偶尔跑飞排查 — 有空再做

**现象**：WNS 不报红但 FPGA 上偶尔跑飞。

**时序报告 Top-5** (250MHz, `stage_timing_report.txt`):
| # | Slack | Levels | 路径 |
|:-:|:-----:|:------:|------|
| 1 | 0.082ns | 0 | DCache dram_rd_addr → DRAM BRAM (纯布线, 64×BRAM36 扇出) |
| 2 | 0.087ns | 0 | 同上 |
| 3 | 0.092ns | 0 | 同上 |
| 4 | 0.096ns | 0 | 同上 |
| 5 | 0.114ns | 7 | DCache mem_index → IROM BRAM |

**根因确认**: 全局最差 5 条全是 DCache→DRAM **纯布线**延迟 (0 级逻辑), CPU 逻辑不是瓶颈。

**排查步骤**：
- [ ] 查 Vivado Timing Summary：WNS / WHS / TPWS 三个值
- [ ] 查综合/实现日志里的 Timing-6 / Timing-18 类 warning
- [ ] 考虑 Pblock 约束（把 CPU 和 DRAM BRAM 放相邻区域）
- [ ] 如果布线拥塞严重，考虑 Performance_ExtraTimingOpt 策略

### 4. 分支预测器 — 已完成分析, 不做 TAGE

分析脚本:

| 脚本 | 用途 |
|------|------|
| `02_Design/coe/bp_sweep.py` | **24 核并行配置扫描** (BTB×GHR×RAS, 152 评估, 107s) |
| `02_Design/coe/bp_test_current.py` | 当前配置详细诊断（L0/L1 breakdown） |
| `02_Design/coe/bp_coldstart_sim.py` | 冷启动 10M 指令精确仿真 |

最新预测率 (bp_sweep.py, 精确匹配 RTL, 5M 指令):

| 程序 | Overall | Branch | BTBm+T | CPI |
|:---:|:---:|:---:|:---:|:---:|
| current | 92.17% | 91.71% | 16 | 1.118 |
| src0 | **74.63%** | 74.34% | **37,940** | **1.193** |
| src1 | 85.27% | 85.15% | 10,282 | 1.159 |
| src2 | 85.29% | 84.10% | 33 | 1.148 |

---

## ✅ 已完成项（归档）

<details>
<summary>点击展开已完成项目列表</summary>

### RTL 设计 & 集成
- [X] 按 spec 逐模块生成 `.sv` 文件（20 个模块）
- [X] 顶层集成连线 (`cpu_top.sv`)
- [X] IROM 预取方案 + IF/ID 寄存器存指令
- [X] PC 复位值 `0x7FFF_FFFC`
- [X] `student_top.sv`：CPU + IROM + DCache + mmio_bridge 连线
- [X] DRAM SDP BRAM 256KB, DOB_REG=1

### 验证
- [X] riscv-tests 43/43 PASS（iverilog）
- [X] FPGA 4/4 COE 全部通过 @ 200MHz

### 时序优化
- [X] perip_bridge AND-OR 优化（决策 I）
- [X] Flush 延迟 EX→MEM（决策 K）
- [X] branch_unit 用 alu_addr（决策 M）
- [X] btb_valid LUTRAM 化（决策 M）
- [X] L0 预测 AND-OR 平坦化（决策 M）
- [X] next_pc_mux 消除 + BTB tag 7→5 bit + NLP redirect 拆分（决策 N）
- [X] PC+4 EX 级预算（决策 P）

### DCache
- [X] 可行性评估 cache_sim.py（决策 L）
- [X] 2KB 2-way WT+WA + 1-entry SB（决策 L）
- [X] DRAM 延迟 bug 修复 DRAM_LATENCY=3（决策 O）
- [X] Synth 8-7137 forwarding 寄存器复位修复（决策 Q）

### Tournament 分支预测器
- [X] BTB64 + Bimodal BHT + GShare 256 + Selector 256 + RAS 4
- [X] NLP: IF(L0) Bimodal, ID(L1) Tournament
- [X] bp_stress 测试程序

### 性能分析
- [X] DCache 配置扫描 (12 配置 × 4 程序, `cache_sim.py`) → `selfuse/cache_analysis.md`
- [X] BP 配置扫描 (24 配置 × 4 程序, `bp_sweep.py`, 24 核并行) → `selfuse/bp_analysis.md`
- [X] 时序报告分析 (`stage_timing_report.txt`) → 已整合到两份分析文档

### 已放弃
- [x] ~~JAL 提前到 ID 级~~ — FPGA 跑飞
- [x] ~~JALR 提前到 ID 级~~ — 200MHz 时序不收敛
- [x] ~~RAS 4→8~~ — bp_sweep 证实 RAS 深度对所有程序零效果 (调用链深度 ≤ 2)
- [x] ~~GHR 12/14~~ — 时序分析证实 PHT 4096+ entries 导致 LUTRAM MUX 违例

</details>

---

## 我自己想到的

- [ ] TCL 脚本一键创建 Vivado 工程 — **暂缓**
  > 过于复杂，等以后有空再研究。

