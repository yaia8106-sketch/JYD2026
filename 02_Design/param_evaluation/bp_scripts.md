# BP 参数评估脚本

> 所有脚本精确匹配 `branch_predictor.sv` 的 NLP Tournament 架构：
> BTB 直接映射 + Bimodal BHT + GShare PHT + Selector + RAS shift stack。

---

## bp_test_current.py

**用途**：测试当前 RTL 配置的预测准确率。

**硬编码参数**（匹配 RTL）：
- BTB: 64-entry 直接映射, TAG_W=5, idx=PC[7:2]
- BHT: 2-bit 饱和计数器，嵌入 BTB entry（Bimodal）
- GShare: 8-bit GHR XOR PC[9:2] → 256-entry PHT
- Selector: 256-entry, GHR 索引
- RAS: 4-deep

**三级预测流水**：
- IF (L0): `bht[1]` 快速预测方向（Bimodal）
- ID (L1): Tournament 验证（Bimodal vs GShare via Selector）
- EX: 全部状态更新（BTB/PHT/Selector/RAS）

**输出**：每程序的分支/CALL/RET/JALR 各类准确率 + CPI 估算。

```bash
python3 bp_test_current.py
```

---

## bp_coldstart_sim.py

**用途**：模拟上电冷启动后的预测行为，严格复刻 RTL 的三级流水时序。

**与 bp_test_current 的区别**：
- bp_test_current 先收集 trace 再回放，是"离线"模拟
- bp_coldstart_sim 是"在线"逐拍模拟，包含流水线延迟效应（IF→ID→EX 的 2 拍更新延迟）
- 更精确但更慢

**输出**：冷启动准确率（无热身），反映 FPGA 上电后的真实表现。

```bash
python3 bp_coldstart_sim.py
```

---

## bp_param_sweep.py

**用途**：快速参数扫描，探索 BTB/GHR/PHT/RAS 不同组合的效果。

**方法**：复用 `bp_test_current.py` 的 `TournamentBP` 类和 `RV32ISim`，多核并行跑。

**可调参数**：
- `btb_entries`: BTB 大小
- `btb_tag_w`: tag 宽度
- `ghr_w`: GHR 位宽 → 决定 PHT/Selector 大小
- `ras_depth`: RAS 深度

**输出**：各配置的平均 CPI 节省排名。

```bash
python3 bp_param_sweep.py
```

---

## bp_sweep.py（34KB，最完整）

**用途**：全配置穷举扫描，独立模型，精确度最高。

**方法**：
1. 先跑一次 ISA 模拟，收集所有分支事件的 trace
2. 对每种 BP 配置回放 trace，统计命中率
3. 多核并行（`multiprocessing.Pool`，自动检测核心数）

**扫描维度**：
- BTB: 64 / 128 / 256 entries
- GHR: 6 / 8 / 10 / 12 bit
- RAS: 2 / 4 / 8 / 16 deep

**输出**：Top N 配置 + 最差配置，含四程序各自命中率和平均 CPI 节省。

**典型耗时**：24 核约 107 秒。

```bash
python3 bp_sweep.py
```

**关键发现**（已归档到 `full/bp_analysis.md`）：
- BTB 64→128 是最大单一改善（src0 BTB miss 37,940→202）
- RAS 4→8/16 零效果（调用深度 ≤ 2）
- GHR ≥ 12 时序违例风险
