# C++ Architecture Explorer

这个目录用纯 C++ 执行六个竞赛 COE 程序，并在线评估分支预测方案。它的用途是先筛掉收益小、资源不合适或对更新延迟敏感的设计，再决定哪些方案值得进入 RTL；它不是周期精确的 RTL 替代品。

功能模拟器覆盖这些程序实际使用的 RV32I/RV32M、机器态 CSR、ECALL/MRET、DRAM、测试平台 MMIO 镜像和定时器 MMIO。完整运行必须覆盖：

1. `current`
2. `src0`
3. `src1`
4. `src2`
5. `new_without_Mext`
6. `new_with_Mext`

每个程序从清空的历史、weakly-not-taken PHT 和空 ABTB/RAS 开始。停止 PC 由 COE 入口自环推导，与长 RTL 性能测试的结束条件一致。

## 构建与测试

在工作区根目录执行：

```bash
cmake -S 02_Design/model/cpp_arch_explorer \
      -B 02_Design/model/cpp_arch_explorer/build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build 02_Design/model/cpp_arch_explorer/build -j16
ctest --test-dir 02_Design/model/cpp_arch_explorer/build --output-on-failure
```

测试目标在 Release 构建中显式启用 `assert`，避免 `NDEBUG` 让单元测试静默失效。

## 四类实验

### 1. 路径/目标历史初筛

```bash
02_Design/model/cpp_arch_explorer/build/bp_explorer \
    --experiment target-history --delays 0,2,4,6 --jobs 6
```

`bp_explorer` 保留了早期的 target/path-history 实验，适合验证“PC/GHR 与已解析地址历史组合”的想法。

### 2. 纯方向预测器扫描

```bash
02_Design/model/cpp_arch_explorer/build/direction_study \
    --delays 6,10 --jobs 6
```

`direction_study` 对每个实际执行的条件分支比较：

- PC 直索引 bimodal；
- 256-entry GShare 与 GSelect；
- 不同容量、索引和历史长度；
- 两级或三级小型 TAGE；
- PC[2] 分 bank 的 base/tagged table 组织。

输出包括 `per_program.csv`、`aggregate.csv`、`per_pc.csv` 和 `diagnostics.csv`。统计包含提供者/最终来源准确率、分配失败、陈旧 provider 更新、PC[2] bank 压力和别名切换。

### 3. 集成前端模型

```bash
02_Design/model/cpp_arch_explorer/build/frontend_study \
    --delays 6,10 --jobs 6
```

`frontend_study` 在同一条实际路径上组合当前前端与候选改动：

- 当前 2-bank × 16-set × 2-way ABTB，7-bit tag、type、target、valid 和伪 LRU；
- taken B 才分配，JAL/CALL/RET 分配，使用预测时携带的 hit/way；
- 当前 256-entry、8-bit committed-GHR GShare；
- F0 对 B/JAL 的轻量译码和 PC+immediate 目标；
- F0 可分别启用 JAL direct correction 与 B 一级方向 steering；
- F1 两级 TAGE，以及双读口/只查询程序序最老分支两种策略；
- F1 late override 可选 always、tagged-strong、tagged-useful 及组合过滤；
- committed、有限 pending overlay 和 actual-path 理想上界三类 RAS；
- 固定更新延迟和重定向后可见性敏感性。

候选 `BIMODAL_F0_DIRECT_TAGONLY_*` 把 BP/F0 的有效方向作为 external
base。F1 只含 tagged tables；tag miss 严格保持 BP/F0 next PC，不训练或
计入私有 bimodal base。`*_ALT_{STRONG,USEFUL,STRONG_OR_USEFUL,...}` 用于
扫描 late-override 门控。

输出文件：

- `per_program.csv`：逐程序、逐配置原始计数；
- `aggregate.csv`：六程序原始计数求和；
- `cfi_blocks.csv` / `cfi_pairs.csv`：64-bit fetch block 中的静态/动态双 CFI 情况；
- `ras.csv`：返回目标、下溢、溢出和 pending 深度；
- `abtb_summary.csv`：resolved hit、type/target mismatch、陈旧 hit 写入和 bank 汇总；
- `abtb_sets.csv`：每个 bank/set 的 lookup、hit、allocation 和 replacement；
- `per_pc.csv`：静态分支热点和后端 miss。

常用开发参数：

```text
--programs current,src0
--delays 6,10
--configs CURRENT_GSHARE,BIMODAL_TAGE2_OLDEST
--jobs 6
--max-instructions 1000000
--progress 100000000
```

带 `--max-instructions` 的结果只用于 smoke/debug，不能作为完整性能结论。并行度在程序级实现，命令行硬限制为 16。

长跑时，每个程序完成后会立即写入
`<output-dir>/checkpoints/<program>/`；全部程序结束后才生成顶层六程序汇总。
因此中途中断不会丢失已经完成的程序结果。

### 4. FDQ 周期敏感性

```bash
02_Design/model/cpp_arch_explorer/build/fdq_study \
    --programs current,src0 \
    --delays 10 \
    --configs CURRENT_GSHARE,BIMODAL_F0_DIRECT_TAGONLY_T64_H4_8_ALT_STRONG_OR_USEFUL \
    --scenarios D8_RTLPAIR_F1R1_B6_DIR_CAL_EVEN,D8_RTLPAIR_F1R2_B6_DIR_CAL_EVEN \
    --jobs 2
```

`fdq_study` 使用当前 RTL pairing 规则和 instruction-granular ring queue，
保留 F1 correct 前的正确 FDQ prefix，并扫描：

- F1 correct 后 0/1/2 个额外 producer interval；
- backend redirect 4/6 cycle；
- depth=4/8；
- direction-only/all-control；
- 由旧 RTL CPI stack 校准的均匀或 burst consumer stall。

输出 `fdq_per_program.csv` 和 `fdq_aggregate.csv`，包括周期、IPC、empty、
平均 occupancy、correct 时保留 0～8 条指令的分布以及估计错误 fetch
block。`--scenarios` 可只运行指定场景。

## 当前 RTL 方向基线

`CURRENT_GSHARE` 对应：

- 256 个 2-bit 饱和计数器，初值 weakly not taken；
- 8-bit committed、non-speculative GHR；
- `index = branch_pc[9:2] XOR GHR`；
- 一个逻辑表、两个异步读口；
- 预测时的 index/counter 随指令带到 EX/MEM 交界处更新；
- 没有 write-to-read bypass，也没有投机历史恢复。

C++ 更新同样使用预测时捕获的 counter，而不是更新时表内的最新 counter，因此能保留真实 RTL 中并发训练覆盖的影响。

## 小型 TAGE 资源口径

`TAGE2_B256_T64_H4_8` 包含 256-entry 2-bit PC-indexed bimodal base，以及两个 64-entry tagged table：

- T0：history=4，tag=6，3-bit signed counter，1-bit useful，1-bit valid；
- T1：history=8，tag=7，3-bit signed counter，1-bit useful，1-bit valid。

逻辑存储为 1992 bit。tagged-only 配置没有第二份 base：T0/T1 为 1472
bit，另用 8-bit committed GHR；相对当前 PHT+GHR 的净增量约 1472 bit。
`logical_storage_bits` 只计一个逻辑副本；`two_read_storage_bits` 会保守计入
双读复制。F1 只查最老分支时不要求整表复制。

TAGE 使用 committed history。最长匹配表提供预测；新且 useful=0 的弱 provider 可使用 alternate；最终误判时向更长历史、无效或 useful=0 的 entry 分配。预测时 index/tag/provider/counter/useful/alternate 都被记录，按配置延迟更新。

## 延迟模型与可信边界

`update_delay_instructions` 用动态指令数近似从预测到 EX/MEM 更新的周期距离。它不能同时精确描述双发射、cache/RAW stall 和 redirect 后的空周期，因此完整研究至少比较 delay=6 和 delay=10。

方向更新提供三个集成敏感性边界：

- `ALL_BACKEND_REDIRECTS`：任何最终目标/方向错误都让已解析方向更新可见；
- `BRANCH_DIRECTION_REDIRECTS`：只有条件分支方向错误这样做；
- `NATURAL_INSTRUCTION_DELAY`：完全依赖固定动态指令延迟。

ABTB/RAS 在后端重定向时仍推进 pending 更新，避免一次敏感性实验同时改变所有结构。

`GSHARE_F0_JAL_ONLY` 用于验证“F0 计算 direct target，但只让 JAL 无条件
修正”；`BIMODAL_TAGE2_OLDEST_{STRONG,USEFUL,...}` 用于量化晚一级 TAGE
减少 correction 与损失 backend accuracy 的权衡。late filter 只控制 F1
是否采用结果，不停止 TAGE 查询和训练。

模型只执行实际路径，不生成完整错误路径取指。因此以下指标可能偏乐观：

- ABTB 的错误路径 lookup、LRU 污染和替换压力；
- 投机 RAS 的错误路径 push/pop 与恢复；
- F1 correct/后端 redirect 与 consumer stall 的精确周期重叠；
- 两条 CFI 同一 fetch block 内的逐周期发送、取消与重取时刻。

有限 pending RAS 和 speculative RAS 都使用 actual-path 操作；后者明确只是目标准确率上界。任何 RAS 结论必须再用带 checkpoint/恢复的时序模型或 RTL 验证。

## 结果使用规则

- 聚合准确率必须由六程序原始计数求和，不能平均六个百分比；
- 同时检查逐程序退化和大程序加权结果；
- 只有在 delay=6/10、方向屏障边界和 tagged-read 限制下排序稳定，方案才值得推荐；
- C++ 的方向收益不等于 CPI 收益，需结合 F0/F1/backend 修正代价；
- 最终候选仍需 RTL 功能回归、六 COE 性能测试和 Vivado WNS/Fmax/资源报告。

2026-07-14 的最终 tagged-only/FDQ 结论见
`TAGGED_ONLY_F1_STUDY_20260714.md`。早期把 F1 建模为带私有 base 的完整
TAGE、或给每次 F1 correct 乘固定 penalty 的结果，只作为历史记录。
