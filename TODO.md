# 当前状态与下一步

更新日期：2026-05-09

## 当前基线

- 当前工作分支：`perf/assess-before-rtl`，从干净 `master` 新开。
- `master` 与 `origin/master` 同步；两个废案分支 `perf/frontend-pipeline-split`、`perf/fetch-queue-frontend` 已删除。
- RTL 主线保持干净；最近一次保留的 RTL 方向是前端取指/分支预测/forwarding 已收敛版本。
- `stage_timing_report.txt` 是 Vivado 生成物，已从 git 跟踪中移除；每次以 `./run_vivado_flow.sh current 18` 重新生成。
- 自有物理板工程在 `PhysicalTwin_XC7A35T/`，CPU RTL 直接引用 `02_Design/rtl`，不维护第二份 CPU 代码。
- 当前 iverilog 回归入口 `02_Design/sim/riscv_tests/run_all.sh` 覆盖 64 个测试；文档中的历史实验若写 63/63，表示当时测试集规模。

## 最近结论

- 2026-05-09 复盘：后续性能改动必须先做脚本评估，再写 RTL。门槛写入 `00_AI_Rules/global_rules.md`：以程序运行时间 `cycles * clock_period` 为目标，不能只看 CPI/cycles。
- Fetch queue / 伪前端切分实验已否决：官方 4 项仅 `3645 -> 3642 cycles`，但 post-route `WNS +0.049ns -> -1.015ns`，TNS `-615.607ns`，1192 个 failing endpoints。已记录到 `tradeoffs*.md`。
- 零周期 `ID actual redirect -> IROM` 有 CPI 收益，但 FPGA 时序代价过高，已记录在 `00_AI_Rules/tradeoffs*.md`，不要直接恢复。
- `load -> store` MEM-ready 修复实验对 `src2` 约有 `-0.017 CPI`，但 Vivado 200MHz 报负 slack，已撤回。
- BP 容量/GHR 扫描收益偏小：软件模型中 GHR 8 -> 12 平均约 `-0.007 CPI`，不值得优先扩大表项。
- 2026-05-09 大型流水线评估：小切分不值得做；真正可能有收益的方向必须是 `IF1/IF2 + EX branch compare + registered redirect + ID/control retime + memory/control retime` 的成体系重构。保持 L1 预测且 branch miss 只额外 1 拍时，COE break-even 约 `215.5MHz`；较有价值的门槛应设为 `>=225MHz`，最好 `>=235MHz`。当前 routed 报告显示到 `4.5ns` 需重定时约 23 类路径，到 `4.25ns` 需约 33 类路径。
- 2026-05-09 ALU-branch fusion 评估：`zero_eqne_raw`（slot0 ALU 写 rd，slot1 BEQ/BNE 用 rd 与 x0 比较）在 `src0/src1/src2` 上有 `0.0251 dCPI` 保守收益（假设 fused branch miss 多 1 拍），同频约 `2.62%`；理想上界 `0.0514 dCPI`。这项不算太小，值得先写设计契约，但不要直接做泛化 slot1 branch。
- `coe_hotspots.py` 显示 `src0/src1/src2` 热点主要集中在除法/取模风格循环：
  - 独立 slot1 branch 机会较多。
  - `andi ..., 1 -> branch` 这类 ALU-to-branch 紧邻相关也很热。
- 自有 XC7A35T 物理板 DRAM 只有 48 个 4KiB 物理页（192KiB）可用：
  - `dual_issue/src1` 已适配，动态页集合为 `0x00..0x2c + 0x34`，可完整放入。
  - `dual_issue/src0` 不再做适配；完整运行需要 62 个 4KiB 页，细分到 1KiB 仍需 245KiB 级工作集，超过板卡容量。`src0=2589ms` 这类短时间是错误/提前结束路径，不作为性能结果。
  - `dual_issue/src2` 也超过 48 页，当前板上结果只能作为容量受限实验结果，严格结果需扩展内存或改程序/数据布局。

## 下一步候选

1. 先生成候选方案评估表：目标 benchmark、baseline cycles、CPI/stall 归因、预期 cycles 收益、预期 WNS/Fmax 影响、验证风险。
2. 每次正式跑脚本都归档到 `05_Experiment_Records/YYYYMMDD_short_topic/`：保存命令、参数、环境、结果摘要和结论；完整日志放 `raw/` 本地保留。
3. 本机脚本默认用 18 核并行（如 `--jobs 18` / `./run_vivado_flow.sh current 18`），若降低并行度必须记录原因。
4. ALU-branch fusion 下一步先写设计契约：限制在 `zero_eqne_raw` 子集，说明 branch 预测/redirect/flush 协议和 IF/IROM 时序隔离；契约过关后才做 RTL。
5. 若做大型流水线 RTL，先写设计契约：新 stage 边界、branch penalty、predicted-fetch 策略、计划切掉的 path classes、最低 Fmax gate（`>=225MHz`，优先 `>=235MHz`）和早期 Vivado 不达标时的回滚规则。
6. 任何 CPI 优化后都要按顺序做：
   - `bash 02_Design/sim/riscv_tests/run_all.sh`
   - `run_coe_diff.sh` 的长前缀对比
   - `./run_vivado_flow.sh current 18`
