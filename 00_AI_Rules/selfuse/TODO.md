# TODO 清单

> 最后更新：2026-04-27

---

## 当前状态

**M9 里程碑已完成。** DCache 上线后全部 4 个 COE 程序 FPGA 验证通过。

- ✅ riscv-tests 43/43 PASS（iverilog）
- ✅ FPGA 4/4 COE 全部通过（current + src0 + src1 + src2）
- ✅ 200MHz 时序收敛
- ⚠️ 250MHz WNS 通过但偶尔跑飞（marginal timing，见下方排查项）

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

### 2. 250MHz 偶尔跑飞排查 — 有空再做

**现象**：WNS 不报红但 FPGA 上偶尔跑飞。

**可能原因**：
- Setup margin 不足（WNS 接近 0，PVT 波动导致实际 fail）
- Hold time violation（WHS 可能有违例）
- TPWS（Pulse Width Slack）违例
- DRAM 68×BRAM36 扇出路径 slack 极度边缘

**排查步骤**：
- [ ] 查 Vivado Timing Summary：WNS / WHS / TPWS 三个值
- [ ] 查 Top 20 intra-clock paths，找 slack < 0.1ns 的路径
- [ ] 查综合/实现日志里的 Timing-6 / Timing-18 类 warning
- [ ] 考虑 Pblock 约束（把 CPU 和 DRAM BRAM 放相邻区域）
- [ ] 如果布线拥塞严重，考虑 Performance_ExtraTimingOpt 策略

### 3. 分支预测器优化 — 暂缓（不做 TAGE）

不做 TAGE，当前 Tournament 架构够用。仿真数据和脚本都还在：

| 脚本 | 用途 |
|------|------|
| `02_Design/coe/bp_coldstart_sim.py` | 冷启动 10M 指令精确仿真 |
| `02_Design/coe/bp_test_current.py` | 当前配置详细诊断（L0/L1 breakdown） |
| `02_Design/coe/bp_param_sweep.py` | 7 组参数扫描（GHR/PHT/BTB/RAS 组合） |

当前预测率（冷启动 10M 指令）：

| 程序 | 条件分支 | CALL | RET | JALR | 整体 | CPI |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| current | 78.4% | 100% | 99.9% | 0% | 78.1% | 1.182 |
| src0 | 59.2% | 35.6% | 100% | 0% | 59.7% | 1.173 |
| src1 | 74.5% | 96.8% | 71.2% | 0% | 75.0% | 1.164 |
| src2 | 70.0% | 99.9% | 99.9% | 0% | 71.7% | 1.183 |

如后续有精力，最实际的优化方向：
- BTB 64→128（缓解 src0 CALL aliasing）
- RAS 4→8（改善 src1 RET 准确率）

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

### 已放弃
- [x] ~~JAL 提前到 ID 级~~ — FPGA 跑飞
- [x] ~~JALR 提前到 ID 级~~ — 200MHz 时序不收敛

</details>

---

## 我自己想到的

- [ ] TCL 脚本一键创建 Vivado 工程 — **暂缓**
  > 过于复杂，等以后有空再研究。

