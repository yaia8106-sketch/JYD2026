# Tradeoff 详细说明

> 本文记录已经实际尝试、验证、否决的架构权衡。目标是防止后续会话重复走同一条弯路。

---

## T1. ID actual redirect vs FPGA 时序

### 结论

当前双发射 RTL 不保留零周期 ID actual redirect。

具体含义是：不要把 ID 阶段算出的真实分支方向/目标，通过组合逻辑直接送进 `irom_addr`、`irom_even_addr`、`irom_odd_addr` 这条取指快路径。现阶段继续使用：

```systemverilog
mem_branch_replay
> ex_redirect_to_target / ex_redirect_to_fallthrough
> id_bp_redirect_raw       // NLP Tournament 修正 L0 方向
> bp_taken_for_if
> seq_next_pc
```

如果以后继续做这个方向，应改成注册化 redirect、前端 FIFO/redirect queue，或者更大粒度的流水线切分，而不是恢复零周期组合 redirect。

### 背景

已有前端机制：

- IF/L0：BTB + bimodal 快速预测，直接参与取指。
- ID/L1：Tournament 预测器纠正 L0 的 BRANCH 方向，`id_bp_redirect_raw` 进入 IROM 地址快路径。
- EX：真实分支结果由 `branch_unit` 判断，使用 fast redirect 修正错误路径。

这次实验的想法是：既然 ID 阶段已经有寄存器值、分支目标预计算和部分条件判断，就尝试在 ID 级提前发现真实方向错误，从而比 EX 早一拍 redirect，降低 branch penalty。

### 实验方案

#### 方案 A：全 BRANCH ID actual redirect

尝试逻辑：

- `id_valid & dec_is_branch` 时，在 ID 级使用 `id_branch_taken_pre` 得到真实 taken。
- 使用 `id_branch_target_pre` / `id_pc_plus_4` 得到真实 redirect target。
- 若 `id_bp_taken` 或 `id_bp_target` 与真实结果不一致，则 `id_actual_redirect_raw` 进入 IROM 地址 MUX。

为了避免组合环，曾拆出 `id_s0_ready_go`，只检查 slot0 能否前进；否则 `id_actual_redirect_raw` 参与 slot1 squash 后会反向影响 forwarding hazard 和 `id_ready_go`。

#### 方案 B：仅 BEQ/BNE 方向修正

方案 A 的路径太重后，又收窄为：

- 只处理 `dec_is_branch & ~dec_branch_cond[2]`，即 BEQ/BNE。
- 只比较方向：`id_branch_taken_eqne ^ id_bp_taken`。
- 不在 ID 级比较 32-bit target mismatch。
- BLT/BGE/BLTU/BGEU 和 target mismatch 仍交给 EX fast redirect。

这个版本去掉了减法比较和 32-bit target compare，但仍然需要从 ID equality 结果组合到 IROM 地址。

### 功能验证

两个可综合版本都做过基础功能验证（当时 `run_all.sh` 测试集为 63 个；当前主线已扩展为 64 个）：

- `./run_all.sh`：63/63 PASS。
- `COMMITS=20000 MAX_CYCLES=1000000 WATCHDOG_CYCLES=150000 ./run_coe_diff.sh current src0 src1 src2`：4/4 PASS。

实验过程中也踩过两个功能坑：

- 把 JAL/JALR 一并纳入 ID actual redirect，或在 actual result 已知时抑制原来的 NLP redirect，曾导致 COE trace 错位；`src1` 在约 commit 2871 附近出现 PC/指令元数据不一致。
- `id_actual_redirect_raw` 参与 slot1 squash 后，如果再依赖完整 `id_ready_go`，容易形成组合环。拆出 S0-only ready 可以消掉环，但不能解决关键路径太长的问题。

### CPI 数据

COE 200k commit 采样如下。baseline 是实验前的已提交版本。

| 程序 | baseline CPI | 方案 A CPI | 方案 A 改善 | 方案 B CPI | 方案 B 改善 |
|------|--------------|------------|-------------|------------|-------------|
| current | 0.956 | 0.931 | -0.025 | 0.950 | -0.006 |
| src0 | 1.079 | 1.047 | -0.032 | 1.050 | -0.029 |
| src1 | 1.085 | 1.053 | -0.032 | 1.075 | -0.010 |
| src2 | 1.026 | 0.989 | -0.037 | 0.999 | -0.027 |

`bp_stress` 上也能看到收益：

- baseline 约 `CPI=1.112`。
- 方案 A：`CPI=1.054`，`ID actual red=154`。
- 方案 B：`CPI=1.059`，`ID actual red=144`。

结论：收益是真实的，尤其对分支密集程序有价值；问题不在 CPI，而在 FPGA 时序。

### 时序结果

方案 A：

- Synthesis：0 errors，0 critical warnings。
- Place DRC：0 errors，约 42 warnings。
- post-place/early timing：约 `WNS=-2.5~-3.2ns`。

方案 B：

- Synthesis：0 errors，0 critical warnings。
- Place DRC：0 errors，约 42 warnings。
- post-place timing optimization 后仍约 `WNS=-2.8ns`。

这说明即使只做 BEQ/BNE 方向修正，零周期 ID actual redirect 仍然把过多逻辑压进了取指地址路径。

### 为什么时序不可接受

这条路径本质上太长：

```text
IF/ID reg
-> decoder / branch type
-> forwarding select
-> rs1/rs2 equality or compare
-> predicted-vs-actual 判断
-> target/fallthrough 选择
-> IROM bank address function
-> irom_addr / irom_even_addr / irom_odd_addr MUX
-> BRAM address setup
```

方案 A 还额外包含：

- BLT/BGE 的 32-bit subtract/compare。
- taken 时的 32-bit target mismatch compare。

方案 B 虽然去掉了这些重逻辑，但仍然存在 `ID equality -> redirect mux -> IROM address` 的零周期路径。FPGA 上这类路径不仅逻辑级数长，还会带来明显布线压力。

### 当前决策

不保留这次 RTL 实验改动。不要恢复以下结构：

```systemverilog
wire id_actual_redirect_raw = id_control_resolved & id_control_pred_wrong;
assign irom_addr = id_actual_redirect_raw ? id_control_redirect_target : ...;
```

这不是“没有 CPI 收益”，而是“CPI 收益买不起时序代价”。在当前目标频率下，吞吐更看重可收敛的 Fmax 与稳定的 FPGA 实现。

### 后续可行方向

1. **注册化 ID redirect / 前端 FIFO**
   - ID 当拍只产生 redirect request。
   - 下一拍由前端消费 request 并切换取指。
   - 优点是切断 ID->IROM 组合快路径。
   - 代价是可能少省一拍，必须重新仿真确认真实 CPI。

2. **保持 EX fast redirect，优化其他 CPI 大头**
   - COE 中 load-use 和 slot1 发射限制仍然很显眼。
   - 这些方向可能不需要把新逻辑塞进 IROM 地址路径。

3. **流水线切分**
   - 如果架构切分能显著提高 Fmax，即使 CPI 稍升，实际性能仍可能提高。
   - 但切分会牵动 flush、前递、load-use、双发射对齐，属于更大工程。

4. **更保守的分支优化**
   - 继续改预测器表项或 JALR 预测时，要避免新增 IF address critical path。
   - 优先选择注册表项、预计算字段、低 fanout 的修正路径。
