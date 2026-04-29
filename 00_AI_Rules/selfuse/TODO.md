# TODO 清单

> 最后更新：2026-04-29

---

## 当前状态

**M10+ 时序持续优化中。** 250MHz 时序收敛（WNS = +0.120ns），DCache 2KB，Pblock 约束生效。

- ✅ riscv-tests 43/43 PASS（iverilog）
- ✅ FPGA 4/4 COE 全部通过 @ 200MHz（current + src0 + src1 + src2）
- ✅ **250MHz 时序收敛**（WNS = +0.120ns，全部路径 slack 为正）
- ✅ BP 配置扫描完成（24 配置 × 4 程序, 详见 `selfuse/bp_analysis.md`）
- ✅ DCache 配置扫描完成（12 配置 × 4 程序, 详见 `selfuse/cache_analysis.md`）
- ⚠️ **250MHz 版本尚未 FPGA 上板验证稳定性**

---

## 🔥 当前待办（按优先级排列）

### 1. 稳定性排查（250MHz FPGA 验证）

250MHz 时序已收敛但**从未在板卡上测试过此版本**。需排查可能导致运行不稳定的因素：

- [ ] 梳理当前设计中可能导致 FPGA 运行不稳定的所有因素
- [ ] 逐项排查并修复（如有问题）
- [ ] 250MHz 烧录 FPGA，4/4 COE 程序全部通过
- [ ] 稳定性测试：长时间运行 / 多次复位 / 边界条件

### 2. 比特流 + 拍照/录视频

- [ ] 烧录最终 bit 文件，放到 `04_Submission/技术数据/`
- [ ] 拍数字孪生平台截图 + 录演示视频（≤10min）

### 3. 比赛文档撰写

**截止时间：2026-05-07 23:59**

详见 `contest/README.md`。Markdown 初稿已在 `04_Submission/技术文档/` 中完成。

### 4. 物理优化：DRAM 拆分（可选）

当前 DCache→DRAM 路径 (0.120ns, 0级纯布线) 是 WNS 瓶颈之一。
考虑将 1×32bit DRAM（64×BRAM36）拆为 4×8bit DRAM（各 16×BRAM36）：

- 地址扇出从 64 降到 16（4× 改善）
- 每组 16 BRAM 可紧凑放置
- DCache 接口不变，仅改 `student_top.sv` 连线
- 预计 slack 从 0.120 → 0.3+ ns

- [ ] 创建 4 个 8-bit BRAM IP
- [ ] 修改 `student_top.sv` 拆分/合并连线
- [ ] 拆分 COE 初始化文件
- [ ] 综合验证时序

### 5. 性能参数优化（可选，视时间而定）

250MHz 稳定后如有余力，可实施以下改动提升 CPI：

| 优先级 | 改动 | CPI 收益 | 时序风险 | 状态 |
|:------:|------|:--------:|:--------:|:----:|
| 1 | BTB 64→128 | -0.014 | ✅ 安全 | 暂缓（先保证稳定） |
| 2 | DCache 2KB→4KB | -0.005 | ✅ 零 | 暂缓（曾实施后回退） |
| 3 | GHR 8→10 | -0.009 | ⚠️ 需验证 | 暂缓 |

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
- [X] Pblock 约束 CPU+IROM+DCache 共置（决策 S）
- [X] pc_plus4 寄存器优化：消除 irom_addr 默认路径 carry chain（决策 S）
- [X] bp_target sel_seq 删除：消除 pc→bp_target→IROM carry chain（决策 S）
- [X] bp_target sel_btb/sel_ras 去 tag_match 依赖：并行化省 3 级（决策 T）

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
- [x] ~~DCache 4KB~~ — 为时序收敛回退至 2KB（节省 cell 面积给 Pblock 空间）

</details>

---

## 我自己想到的

- [ ] TCL 脚本一键创建 Vivado 工程 — **暂缓**
  > 过于复杂，等以后有空再研究。

