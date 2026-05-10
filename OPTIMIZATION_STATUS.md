# 当前状态与下一步

更新日期：2026-05-10

## 当前基线

- 当前工作分支：`master`。
- `master` 已合入 2026-05-09 的验证脚本和文档清理；本地相对 `origin/master` 领先 7 个提交，尚未 push。
- 两个废案分支 `perf/frontend-pipeline-split`、`perf/fetch-queue-frontend` 已删除；`perf/assess-before-rtl` 和 `perf/optimization-eval` 也已删除。
- RTL 主线保持干净；最近一次保留的 RTL 方向是前端取指/分支预测/forwarding 已收敛版本。后续性能 RTL 实验应从 `master` 新开分支。
- `stage_timing_report.txt` 是 Vivado 生成物，已从 git 跟踪中移除；每次直接运行 `03_Timing_Analysis/run_vivado_flow.tcl` 重新生成。
- 自有物理板工程在 `PhysicalTwin_XC7A35T/`，CPU RTL 直接引用 `02_Design/rtl`，不维护第二份 CPU 代码。
- 当前 iverilog 回归入口 `02_Design/sim/riscv_tests/run_all.sh` 覆盖 64 个测试。

## 最近结论

- 2026-05-09 复盘：后续性能改动必须先做脚本评估，再写 RTL。门槛写入 `00_AI_Rules/global_rules.md`：以程序运行时间 `cycles * clock_period` 为目标，不能只看 CPI/cycles。
- Fetch queue / 伪前端切分实验已否决：官方 4 项仅 `3645 -> 3642 cycles`，但 post-route `WNS +0.049ns -> -1.015ns`，TNS `-615.607ns`，1192 个 failing endpoints。
- 零周期 `ID actual redirect -> IROM` 有 CPI 收益，但 FPGA 时序代价过高，不要直接恢复。
- `load -> store` MEM-ready 修复实验对 `src2` 约有 `-0.017 CPI`，但 Vivado 200MHz 报负 slack，已撤回。
- BP 容量/GHR 扫描收益偏小：软件模型中 GHR 8 -> 12 平均约 `-0.007 CPI`，不值得优先扩大表项。
- 2026-05-09 大型流水线评估：小切分不值得做；真正可能有收益的方向必须是 `IF1/IF2 + EX branch compare + registered redirect + ID/control retime + memory/control retime` 的成体系重构。保持 L1 预测且 branch miss 只额外 1 拍时，COE break-even 约 `215.5MHz`；较有价值的门槛应设为 `>=225MHz`，最好 `>=235MHz`。当前 routed 报告显示到 `4.5ns` 需重定时约 23 类路径，到 `4.25ns` 需约 33 类路径。
- 2026-05-10 `zero_eqne_raw` 试做后降级：`run_all.sh` 64/64 通过，COE 50k diff 在 `current/src0/src1/src2` 通过，小测试 `3645 -> 3557 cycles`（约 `2.4%`），但收益偏小且完整 COE suite 未闭环（`current` 在 1.5M cycles 超时）。该方向不作为下一轮主线；若以后重启 ALU-branch fusion，应先证明更通用的 slot1 branch/fusion 能带来 `>=5%` 程序时间收益且不破坏时序。
- 此前热点扫描显示 `src0/src1/src2` 热点主要集中在除法/取模风格循环：
  - 独立 slot1 branch 机会较多。
  - `andi ..., 1 -> branch` 这类 ALU-to-branch 紧邻相关也很热。
- 自有 XC7A35T 物理板 DRAM 只有 48 个 4KiB 物理页（192KiB）可用：
  - `dual_issue/src1` 已适配，动态页集合为 `0x00..0x2c + 0x34`，可完整放入。
  - `dual_issue/src0` 不再做适配；完整运行需要 62 个 4KiB 页，细分到 1KiB 仍需 245KiB 级工作集，超过板卡容量。`src0=2589ms` 这类短时间是错误/提前结束路径，不作为性能结果。
  - `dual_issue/src2` 也超过 48 页，当前板上结果只能作为容量受限实验结果，严格结果需扩展内存或改程序/数据布局。

## 下一步候选

1. 先生成候选方案评估表：目标 benchmark、baseline cycles、CPI/stall 归因、预期 cycles 收益、预期 WNS/Fmax 影响、验证风险。
2. 本机脚本默认用 18 核并行；Vivado Tcl flow 的 jobs 参数默认用 `18`，若降低并行度必须记录原因。
3. 暂不继续 `zero_eqne_raw` 子集；如重启 ALU-branch fusion，先用脚本评估更通用的 slot1 branch/fusion、branch penalty 和时序风险，再写 RTL。
4. 可以优先补一轮 memory-side 方案评估：例如 DCache refill、banking、DRAM/总线位宽调整。先用 trace/脚本估算收益上限，再决定是否改 RTL。
5. 若做大型流水线 RTL，先写设计契约：新 stage 边界、branch penalty、predicted-fetch 策略、计划切掉的 path classes、最低 Fmax gate（`>=225MHz`，优先 `>=235MHz`）和早期 Vivado 不达标时的回滚规则。
6. 任何 CPI 优化后都要按顺序做：
   - `bash 02_Design/sim/riscv_tests/run_all.sh`
   - `run_coe_diff.sh` 的长前缀对比
   - `vivado -mode tcl -source 03_Timing_Analysis/run_vivado_flow.tcl -tclargs "$PWD" current 18`
