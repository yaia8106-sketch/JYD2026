# 双发射 CPU 架构文档（从 RTL 反向生成，2026-05-07 更新）

> **本文档描述当前 RTL 的实际实现**，而非设计规划。所有内容均从代码中提取。
>
> 顶层层次：`student_top` → `cpu_top` + IROM(2×32-bit BRAM) + `dcache` + DRAM + `mmio_bridge`

---

## 1. 总体架构

**RV32I 五级流水线 + 顺序双发射（In-order Dual-Issue）**

```
IF → ID → EX → MEM → WB
         ↑ Slot1 shadow pipeline (ALU-only)
```

- **Slot 0**（主槽）：ALU / Branch / JAL / JALR / Load / Store — 万能槽
- **Slot 1**（副槽）：ALU only（R-type / I-ALU / LUI / AUIPC）
- 两 Slot 同步推进，共享 `allowin`，不可独立 stall

---

## 2. 取指（IF 级）

### 2.1 IROM

两个 32-bit BRAM bank（even / odd），每拍输出 64-bit（两条指令）。

- even bank：`word[0], word[2], word[4], ...`
- odd bank：`word[1], word[3], word[5], ...`
- bank 地址由 `cpu_top` **预算**后直接传入 `student_top`，BRAM 地址端口无加法器
- `irom_fetch_odd_q` 延迟 `irom_fetch_odd` 1 拍，用于对齐 BRAM dout 的高低半字选择
- 地址计算公式（在 `cpu_top` 中作为 function，用于各源头预算）：
  - `irom_even_bank_addr(addr) = {1'b0, addr[13:3]} + {11'd0, addr[2]}`
  - `irom_odd_bank_addr(addr)  = {1'b0, addr[13:3]}`

```
irom_inst0 = irom_data[31:0]   // inst at PC
irom_inst1 = irom_data[63:32]  // inst at PC + 4
```

### 2.2 irom_addr 优先级

5 路 flat MUX（无 allowin 链依赖）：

```
irom_addr = mem_branch_replay  ? mem_branch_target :   // 1. 未被 EX fast redirect 覆盖的 MEM replay
            ex_redirect_to_target      ? ex_branch_target_pre :
            ex_redirect_to_fallthrough ? ex_fallthrough_pc :
            id_bp_redirect_raw ? id_redirect_target :  // 3. NLP ID redirect（raw）
            bp_taken_for_if    ? bp_target_for_if :    // 4. L0 预测 taken
                                  seq_next_pc;         // 5. 顺序（+4/+8）
```

`irom_even_addr` / `irom_odd_addr` / `irom_fetch_odd` 各有独立的同优先级 MUX，源头的 bank 地址来自寄存器或短组合计算：

- **MEM replay**：`mem_branch_even_addr_r` / `mem_branch_odd_addr_r`（寄存器）
- **EX fast redirect**：`branch_target` / `fallthrough_pc` 已在 ID 阶段预计算；EX 从这两个寄存值并行计算 bank 地址，并用 `redirect_to_target` / `redirect_to_fallthrough` 两个 one-hot 信号直接选择，避免先经过 `actual_taken ? target : fallthrough` 数据 MUX
- **NLP redirect**：`id_redirect_even_addr` 等（组合计算，路径短）
- **BP taken**：`bp_even_addr` 等（含 skip_inst0 寄存快照 / held / live 三层 MUX）
- **sequential**：`seq_even_addr` 等（从 `pc_plus4/8_even_addr` 寄存器中选）
- `branch_predictor` 并行输出 `bp_even_addr` / `bp_odd_addr` / `bp_fetch_odd` 和 lookahead 对应 bank 地址，其中 BTB even-bank 地址随 entry 存储，`cpu_top` 不再在 L0 taken 的 IROM 路径上从 32-bit `bp_target` 现场计算 bank 地址。

### 2.3 PC 步进与 predict_dual

- `pc_plus4/8/12`：寄存器预计算，避免 32-bit 进位链出现在 irom_addr 路径
- 每个 `pc_plus*` 同时维护对应的 `*_even_addr` / `*_odd_addr` / `*_fetch_odd` 寄存器
- L0 BP taken 后更新 `pc_plus*` 时，从 `bp_even_addr` / `bp_odd_addr` / `bp_fetch_odd` 推导 `target+4/+8/+12` 的 bank 地址，并用这些 bank 地址重构 IROM PC，避免 `bp_target + offset` 32-bit 进位链进入 `pc_plus*` 寄存器 D 端
- `predict_dual`：**寄存的上一周期 `can_dual_fetch`**，用于选择 `seq_next_pc`
  - `seq_next_pc = predict_dual ? pc_plus8 : pc_plus4`
  - 打断了 `can_dual_issue → seq_next_pc → irom_addr → IROM → can_dual_issue` 组合环路
  - 预测错误由 `skip_inst0` 和 `inst_buf` 机制修正，无气泡

### 2.4 指令保持寄存器（Instruction Hold Register）

BRAM 无 output register，流水线 stall 时 `irom_addr` 可能已变。stall 入口捕获 BRAM 输出到 `irom_inst0/1_held`，恢复时使用 held 版本。

### 2.5 指令缓冲（Instruction Buffer）

- 1×32-bit + valid，单发时暂存未发射的 slot1
- 下拍 `if_inst0_live = if_skip_inst0 ? irom_inst1 : inst_buf_valid ? inst_buf : irom_inst0`
- `inst_buf_before_window`：标记 inst_buf 内容在当前 IROM 窗口之前（predict_dual 导致的偏移）
- 写入 `inst_buf` 时同步保存 `inst_buf_bp_*` 预测快照；before-window 情况直接使用寄存快照，不再用 `inst_buf_before_window` 当拍选择 BP 查询 PC，缩短前端 BP→IROM 路径
- `inst_buf_valid_next` 不复用完整 `can_dual_issue` MUX 链，而是用 raw/shifted 的 `*_pair_can_dual` 与公共前端 gating 并行组合，缩短 IROM→`inst_buf_valid` 路径
- Flush / bp_taken / NLP redirect 时清空

### 2.6 skip_inst0 机制

`predict_dual` 预测错误（预测单发但实际可双发）时的修正机制：

- 条件：`~predict_dual & (if_pc_out == pc)` 且当前选中的 raw/shifted/held 来源可双发（PC 没前进，IROM 窗口重复）
- 效果：下拍 `skip_inst0_valid=1`，跳过已发射的 inst0，从 inst1 开始
- `if_pc_live = skip_inst0 ? pc_plus4 : ...`（修正流水线 PC）
- 主 BP 查询固定使用当前 `pc`；skip 和 inst_buf-before-window 分别使用已寄存的预测快照，避免时序环路和 before-window→BP→IROM 串行链
- 预查 BP：`la_pc = pc_plus8` 提前查询 skip 后的 BP 预测，锁存到 `skip_bp_*_r` 寄存器
- `bp_live_*` MUX：`skip_inst0 ? skip_bp_*_r : if_buf_before_window ? inst_buf_bp_* : bp_*`
- `skip_bp_*_r` 每拍采样 lookahead 预测，只有 `skip_inst0_valid` 选择时才消费，避免 `will_skip_inst0` 进入这些寄存器的 CE 关键路径。
- `will_skip_inst0` 不复用完整 `can_dual_issue` MUX，而是按 raw/shifted/held 三路分别判断后 OR；`if_accept` 只作为 `skip_inst0_valid` 的 CE，不重复进入 D 端，缩短 IROM→`skip_inst0_valid` 路径。

---

## 3. 双发射判定

### 3.1 can_dual_issue

三条路径：raw（直接 BRAM 解码）、shifted（inst_buf 在窗口前）、held（寄存快照）。

```systemverilog
// raw path：跳过 inst_buf MUX + held MUX，节省 2 级 LUT
// ⚠️ 不要改为从 if_inst0_out/if_inst1_out 解码，多 2 级 LUT 在关键路径上
wire raw_can_dual = if_valid
                  & ~if_skip_inst0              // 正在跳过 inst0 时不双发
                  & (pc != 32'h7FFF_FFFC)
                  & if_sequential_fetch         // 非 flush/redirect/bp_taken
                  & raw_pair_can_dual;           // slot1 是 ALU、无同对 RAW、slot0 非 JAL/JALR

// shifted path：inst_buf 在窗口前，配对 inst_buf + irom_inst0
wire shifted_can_dual = if_valid & ... & shifted_inst1_is_alu_type & ...;

// held path：stall 入口时快照
assign can_dual_fetch = if_skip_out ? 1'b0 :
                        irom_held_valid ? held_can_dual_r :
                        if_buf_before_window ? shifted_can_dual : raw_can_dual;
assign can_dual_issue = can_dual_fetch;
```

### 3.2 RAW 检测（raw_pair_raw）

```systemverilog
wire raw_pair_raw = raw_inst0_writes_rd & (raw_inst0_rd != 5'd0)
                  & ((raw_inst1_uses_rs1 & (raw_inst1_rs1 == raw_inst0_rd))
                   | (raw_inst1_uses_rs2 & (raw_inst1_rs2 == raw_inst0_rd)));
```

- `raw_inst0_writes_rd`：R / I-ALU / Load / LUI / AUIPC / JAL / JALR
- `raw_inst1_uses_rs1`：R / I-ALU；`raw_inst1_uses_rs2`：R-type only
- WAW **不阻止双发**（regfile 和前递保证 Slot1 > Slot0 优先级）

### 3.3 分支双发约束

| slot0 类型 | 能否双发 | 原因 |
|-----------|---------|------|
| 条件分支（BEQ/BNE/...）| ✅ 可以 | NLP squash + EX flush 保证安全 |
| JAL / JALR | ❌ 不可以 | `~raw_inst0_is_jump` 显式屏蔽（bp_taken 也自然屏蔽） |

---

## 4. 分支预测器

### 4.1 L0：IF 级快速预测

- **BTB**：128-entry direct-mapped LUTRAM（tag + target + type + bht[1:0]）
- **JALR sidecar**：8-entry direct-mapped 小表，专门记录涉及 `x5(t0)` 的 CALL-like / RET-like JALR；它与主 BTB 并行查询，命中时优先使用 sidecar 结果。
- 方向判断：`bht[1]`（Bimodal 最高位）
- 关键路径：`PC → LUTRAM → tag compare → bht MUX → irom_addr`
- `type` 编码：`JAL/CALL/BRANCH` 使用表内 target，`RET` 使用 RAS top。主 BTB 继续服务 branch / JAL / x1 RET；x5 JALR 走 sidecar，避免热 libgcc helper 返回覆盖主 BTB 中的热 JAL/branch。
- **RAS link-register hints**：`x1(ra)` 和 `x5(t0)` 都作为 link register。`JAL/JALR rd=x1/x5` 视为 CALL 并 push `PC+4`，`JALR rd=x0, rs1=x1/x5` 视为 RET 并 pop。普通非 link JALR 暂不预测。

### 4.2 L1：ID 级 Tournament 验证（NLP）

```systemverilog
id_bimodal_taken  = (id_bp_btb_bht >= 2'd2);    // bht[1]
id_gshare_taken   = (id_bp_pht_cnt >= 2'd2);    // GShare PHT
id_use_bimodal    = (id_bp_sel_cnt >= 2'd2);     // Selector
id_tournament_taken = id_use_bimodal ? id_bimodal_taken : id_gshare_taken;
```

当 L0 和 L1 对 BRANCH 方向不一致时 → `id_bp_redirect_raw` 触发重定向。

### 4.3 NLP Redirect 与 Slot1 Squash

当 L1 判定 slot0 分支为 taken → slot1（顺序取指的下一条）在错误路径上，需杀掉：

```systemverilog
wire id_s1_squash_raw = id_bp_redirect_raw & id_tournament_taken;
// 应用到 forwarding.id_s1_valid 和 id_ex_reg_s1.id_s1_valid
```

使用 `_raw`（ungated）版本而非 `id_bp_redirect`（gated by id_ready_go & ex_allowin）。

> ⚠️ **必须用 `_raw`**。否则 doomed slot1 的 load-use 会阻止 redirect，导致死锁。

### 4.4 分支目标预计算与 EX Fast Redirect

ID 阶段用专用分支 target 加法器预计算 taken target，并同时计算 fallthrough。`PC+imm` 与 `rs1+imm(JALR)` 并行计算，避免分支 target D 端复用通用 `id_alu_src1/id_alu_src2` MUX 链：

```systemverilog
id_pc_plus_4 = id_pc + 32'd4;
id_pc_branch_target_sum = id_pc + id_imm;
id_jalr_target_sum = fwd_rs1_data + id_imm;
id_branch_target_pre = dec_is_jalr ? {id_jalr_target_sum[31:1], 1'b0}
                                   : id_pc_branch_target_sum;
```

`id_ex_reg` 额外传递 `ex_branch_target` 和 `ex_fallthrough_pc`。EX 级 `branch_unit` 只做条件比较和预测对比，并输出 `redirect_to_target` / `redirect_to_fallthrough` 两个 one-hot redirect 类型；redirect 路径不再依赖 32-bit 目标加法器。
EX redirect 的 IROM bank 地址从已打拍的 `ex_branch_target_pre` / `ex_fallthrough_pc` 并行计算，IROM 地址 MUX 直接用 one-hot redirect 类型选择 target 或 fallthrough；bank 地址不进入 ID/EX 寄存器 D 端。

```systemverilog
ex_redirect_fire = ~mem_branch_flush & ex_ready_go_w & mem_allowin;
ex_redirect_to_target = redirect_to_target & ex_redirect_fire;
ex_redirect_to_fallthrough = redirect_to_fallthrough & ex_redirect_fire;
ex_branch_redirect = ex_redirect_to_target | ex_redirect_to_fallthrough;
mem_branch_replay  = mem_branch_flush & ~fast_branch_redirect_r;
frontend_branch_flush = mem_branch_replay | ex_branch_redirect;
```

- `ex_branch_redirect` 当拍驱动 `pc_reg` / `irom_addr` / IF-ID flush / ID-EX flush。
- `mem_branch_flush` 仍由 `ex_mem_reg` 打拍，用于 DCache/backend cleanup。
- `fast_branch_redirect_r` 抑制下一拍 `mem_branch_flush` 对前端的重复 redirect/flush，避免正确目标首条指令被二次冲刷。
- 当 EX 因 `mem_allowin=0` 或 `ex_ready_go_w=0` 停住时，不发出 fast redirect；等分支指令可前进时再 redirect。

### 4.5 EX 级更新

所有预测器状态（GHR / PHT / BTB / BHT / Selector）在 EX 级更新。
`ex_valid` 门控 `~mem_branch_flush`，防止错误路径指令污染预测器。

JAL/JALR 分类在 EX 级使用 `x1/x5` link-register 规则：

```systemverilog
ex_rd_is_link  = (ex_rd == 5'd1) | (ex_rd == 5'd5);
ex_rs1_is_link = (ex_rs1_addr == 5'd1) | (ex_rs1_addr == 5'd5);

ex_is_jalr_call = ex_is_jalr & ex_rd_is_link;
ex_is_call      = (ex_is_jal & ex_rd_is_link) | ex_is_jalr_call;
ex_is_ret       = ex_is_jalr & (ex_rd == 5'd0) & ex_rs1_is_link;
ex_sidecar_jalr = (ex_is_jalr_call | ex_is_ret)
                & ((ex_rd == 5'd5) | (ex_rs1_addr == 5'd5));
```

这覆盖 `src0/src1/src2` 中 libgcc 辅助函数常见的 `jr t0` 返回路径，使其经过一次冷启动后可由 RAS 预测，而不是每次等 EX redirect。软件前缀模型显示，x5 JALR 如果直接写主 BTB 会在 `src1` 覆盖热 JAL；因此当前实现把这类 JALR 放入 sidecar，主 BTB 不被污染。

预测器更新在 EX 同拍写入；普通 IF 读口在时钟沿后自然看到更新后的表项。skip lookahead 与 inst_buf buffered-slot 读口只对轻量 history / PHT / selector 状态做同拍旁路，BTB/JALR target 表使用当前拍读出的快照，不旁路 EX target/update 结果，避免把 EX branch compare 重新接回 `skip_bp_target_r` / `inst_buf_bp_target` 前端寄存器；少数同拍 BTB/JALR 更新会多保留一次旧 skip/buffered 预测，由正常 EX redirect 修正。

### 4.6 Lookahead 预测（skip_inst0 专用）

BP 额外暴露 `la_*` 端口，用 `la_pc = pc_plus8`（寄存器）提前查询。当 `will_skip_inst0` 成立时，将 lookahead 预测结果锁存到 `skip_bp_*_r` 寄存器组，下拍 skip 时直接使用，无组合延迟。为收敛 200MHz，`la_bp_target/even/odd/fetch_odd` 不再使用 EX 同拍 BTB/JALR target 旁路，避免 `actual_taken`/branch compare 进入 `skip_bp_target_r` D 端；如果刚好错过一个同拍表项更新，最多造成一次旧预测，功能由 EX redirect 保证。

---

## 5. 流水线级间寄存器

| 级间 | Slot 0 | Slot 1 |
|------|--------|--------|
| IF/ID | `if_id_reg` | 共享（传递 inst1 + s1_valid） |
| ID/EX | `id_ex_reg` | `id_ex_reg_s1` |
| EX/MEM | `ex_mem_reg` | `ex_mem_reg_s1` |
| MEM/WB | `mem_wb_reg` | `mem_wb_reg_s1` |

- 控制：`allowin` 每级一个，`ready_go` = `s0_rg & (s1_rg | !s1_valid)`（实际由 forwarding 的 `id_ready_go` 统一输出）
- `id_ex_reg` 额外传递 `ex_branch_target` / `ex_fallthrough_pc`，供 EX fast redirect 使用
- Slot 1 全链传递 valid / pc / inst / alu_result / rd / reg_write_en / wb_sel

---

## 6. 寄存器堆

`regfile.sv`：FF 阵列 32×32-bit，4R2W，read-first。

- 4 读端口：S0-rs1, S0-rs2, S1-rs1, S1-rs2
- 2 写端口：S0-WB, S1-WB
- **WAW 优先级**：Slot 1 最后赋值，覆盖 Slot 0（SystemVerilog `always_ff` 语义保证）

---

## 7. 前递网络

`forwarding.sv`：4 个操作数各一套 6 选 1 优先级 MUX。

```
优先级：S1_EX > S0_EX > S1_MEM > S0_MEM > S0_WB > regfile
```

- EX/MEM 级：`wb_sel==10`（JAL/JALR）时前递 `PC+4` 而非 `alu_result`
- S1_MEM 排除 Load 匹配（`mem_s1_is_load` 接 `1'b0`，因为 S1 不做 L/S）
- S1_WB 不进入前递数据 MUX；当实际使用的源操作数只命中 `wb_s1_rd` 且没有更新的 EX/MEM 命中时，`s1_wb_wait_hazard` 让 ID 等 1 拍，再从 regfile 读取
- 同周期 inst0→inst1 不前递（RAW 约束已在发射判定中拦截）

---

## 8. Load-Use Hazard

`forwarding.sv` 中检测，4 个源操作数 × 4 个 Load 来源（S0_EX / S1_EX / S0_MEM / S1_MEM）。

匹配任一 → `id_ready_go = 0` → 全流水线 stall。

S1 在 EX/MEM 永远不触发 load-use（S1 不做 Load，`ex_s1_mem_read` / `mem_s1_is_load` 恒 0）。

Load-use 和 S1_WB 等待都只对指令实际使用的源操作数生效：
- S0 rs1：`id_rs1_used = (dec_alu_src1_sel == 2'b00) | dec_is_branch`
- S0 rs2：`id_rs2_used = (dec_alu_src2_sel == 1'b0) | dec_is_branch | dec_mem_write_en`
- S1 使用同样规则，并额外受 `id_s1_valid` 门控

---

## 9. Flush 与 Stall

### 9.1 Flush

- **EX 级**：`branch_unit` 组合产生 `redirect_to_target` / `redirect_to_fallthrough`，再 OR 成 `branch_flush`（方向错 / 目标错）
- **EX fast redirect**：`ex_redirect_fire = ~mem_branch_flush & ex_ready_go_w & mem_allowin`，再分别门控 two one-hot redirect 类型
- **MEM 级**：`mem_branch_flush` = `ex_branch_redirect` 打拍，用于 DCache/backend cleanup
- **前端 replay 抑制**：`mem_branch_replay = mem_branch_flush & ~fast_branch_redirect_r`
- **Flush 范围**：
  - `id_flush = frontend_branch_flush | id_bp_redirect`（杀 IF/ID）
  - `ex_flush = frontend_branch_flush`（杀 ID/EX 两个 Slot）
  - `ex_mem_reg_s1.s1_flush = branch_flush | mem_branch_flush`（同拍杀 S1 进 MEM）
  - 指令缓冲清空

### 9.2 Slot1 同拍 Flush

当 slot0(branch) + slot1(ALU) 在 EX 级，branch 误预测时：
- `branch_flush` / `ex_branch_redirect` 当拍有效，`mem_branch_flush` 下拍才生效
- `ex_mem_reg_s1` 接 `ex_branch_flush = branch_flush`，防止 slot1 漏进 MEM

> ⚠️ 不能只用 `mem_branch_flush`——它下拍才生效，同拍 slot1 会漏进 MEM 并错误写回。

### 9.3 Stall

- `if_ready_go = 1`（BRAM 无延迟）
- `id_ready_go = ~(load_use_hazard | s1_wb_wait_hazard)`
- `ex_ready_go = ~mmio_st_ld_hazard`（保守：EX load + MEM MMIO store → 1 cycle stall）
- `mem_ready_go = cache_ready`（DCache miss 时 stall）
- `cache_pipeline_stall = ~mem_allowin`（同步 DCache 与 CPU 流水线）

---

## 10. 存储子系统

### 10.1 DCache

`dcache.sv`：2KB / 2-way set-associative / Write-Through + Write-Allocate / Store Buffer。

- EX 发请求，MEM 出数据
- Tag：LUTRAM（EX 读，MEM 比较）
- Data：BRAM（EX 地址，MEM 数据）
- Miss：FSM → DRAM refill → S_DONE
- Store forward：S_DONE 写 BRAM 时旁路给读端口

### 10.2 Cacheable 判定

`is_cacheable = addr[20] & ~addr[21] & ~addr[19] & ~addr[18]`（DRAM 区域 0x8010_0000~0x8013_FFFF）

### 10.3 MMIO

地址不在 DRAM 区域 → 通过 `mmio_bridge` 访问（LED / SEG / SW / KEY / CNT）。
`DUAL_ISSUE_CNT_ADDR = 0x8020_0060`：双发射计数器（cpu_top 内部实现，基于 `wb_s1_valid` 累加）。

---

## 11. 性能计数器

```systemverilog
always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) dual_issue_count <= 0;
    else if (wb_s1_valid) dual_issue_count <= dual_issue_count + 1;
```

通过 MMIO Load `0x80200060` 读取。只在 Slot1 指令真正提交（WB valid）时计数，避免错误路径污染。

---

## 12. 模块清单

| 模块 | 职责 | 关键特征 |
|------|------|---------|
| `cpu_top` | 顶层连线 + 控制逻辑 | 无 assign 运算符规则（wiring only） |
| `pc_reg` | PC 寄存器 | allowin 门控，flush 优先 |
| `if_id_reg` | IF/ID 级间寄存器 | 传递 BP snapshot / inst1 / s1_valid |
| `decoder` ×2 | 指令译码（S0 / S1） | 完整 RV32I 译码 |
| `imm_gen` ×2 | 立即数生成（S0 / S1） | R/I/S/B/U/J 六种格式 |
| `regfile` | 寄存器堆 | FF 4R2W，S1 > S0 WAW |
| `forwarding` | 前递 + ID 冒险检测 | 6 选 1 MUX，S1_WB 命中等待 1 拍 |
| `alu_src_mux` ×2 | ALU 操作数选择（ID 级） | rs / PC / imm / 0 |
| `id_ex_reg` / `_s1` | ID/EX 级间寄存器 | S0 携带预计算 redirect target / fallthrough；S1 版本接 squash 门控 |
| `alu` ×2 | ALU（S0 / S1） | 含独立地址加法器 `alu_addr` |
| `branch_unit` | 分支判断 + 误预测检测 | 只处理 S0，使用 ID 预计算 target/fallthrough |
| `mem_interface` | Store 移位 / Load 扩展 | EX store，WB load |
| `ex_mem_reg` / `_s1` | EX/MEM 级间寄存器 | S1 版本接 `ex_branch_flush` |
| `mem_wb_reg` / `_s1` | MEM/WB 级间寄存器 | S1 无 load 路径 |
| `wb_mux` ×2 | 写回选择（ALU / Load / PC+4） | S1 的 load 输入接 0 |
| `branch_predictor` | Tournament BP (BTB+GShare+Selector+RAS) | L0 IF 快速预测，L1 ID 验证 |
| `dcache` | 2-way WT+WA 数据缓存 | Store buffer + refill FSM |
| `mmio_bridge` | MMIO 外设桥 | LED / SEG / SW / KEY / CNT |
| `student_top` | 顶层集成 | cpu + IROM + DCache + DRAM + MMIO |
