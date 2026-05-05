# 双发射 CPU 架构文档（从 RTL 反向生成，2026-05-05 更新）

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

4 路 flat MUX（无 allowin 链依赖，250MHz 时序优化）：

```
irom_addr = mem_branch_flush   ? mem_branch_target :   // 1. MEM flush（registered）
            id_bp_redirect_raw ? id_redirect_target :  // 2. NLP ID redirect（raw）
            bp_taken_for_if    ? bp_target_for_if :    // 3. L0 预测 taken
                                  seq_next_pc;         // 4. 顺序（+4/+8）
```

`irom_even_addr` / `irom_odd_addr` / `irom_fetch_odd` 各有独立的 4 路 MUX，每个源头的 bank 地址均预算好（寄存器或组合），MUX 后无加法器：

- **flush**：`mem_branch_even_addr_r` / `mem_branch_odd_addr_r`（寄存器）
- **NLP redirect**：`id_redirect_even_addr` 等（组合计算，路径短）
- **BP taken**：`bp_even_addr` 等（含 skip_inst0 寄存快照 / held / live 三层 MUX）
- **sequential**：`seq_even_addr` 等（从 `pc_plus4/8_even_addr` 寄存器中选）

### 2.3 PC 步进与 predict_dual

- `pc_plus4/8/12`：寄存器预计算，避免 32-bit 进位链出现在 irom_addr 路径
- 每个 `pc_plus*` 同时维护对应的 `*_even_addr` / `*_odd_addr` / `*_fetch_odd` 寄存器
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
- Flush / bp_taken / NLP redirect 时清空

### 2.6 skip_inst0 机制

`predict_dual` 预测错误（预测单发但实际可双发）时的修正机制：

- 条件：`can_dual_issue & ~predict_dual & (if_pc_out == pc)`（PC 没前进，IROM 窗口重复）
- 效果：下拍 `skip_inst0_valid=1`，跳过已发射的 inst0，从 inst1 开始
- `if_pc_live = skip_inst0 ? pc_plus4 : ...`（修正流水线 PC）
- BP 查询使用 `bp_pc_live`（不经过 skip_inst0 MUX，避免时序环路）
- 预查 BP：`la_pc = pc_plus8` 提前查询 skip 后的 BP 预测，锁存到 `skip_bp_*_r` 寄存器
- `bp_live_*` MUX：`skip_inst0 ? skip_bp_*_r : bp_*`（skip 时用寄存快照，零延迟）

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
                  & raw_inst1_is_alu_type        // slot1 是 ALU 类型
                  & ~raw_pair_raw                // 无同对 RAW
                  & ~raw_inst0_is_jump;          // slot0 非 JAL/JALR

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
- 方向判断：`bht[1]`（Bimodal 最高位）
- 关键路径：`PC → LUTRAM → tag compare → bht MUX → irom_addr`

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

### 4.4 EX 级更新

所有预测器状态（GHR / PHT / BTB / BHT / Selector）在 EX 级更新。
`ex_valid` 门控 `~mem_branch_flush`，防止错误路径指令污染预测器。

**更新信号寄存一拍**（时序优化）：BTB / PHT / Selector 的 write enable 在 `branch_predictor` 内部经过 pipeline register 延迟 1 拍写入，避免 EX 比较器→写使能的长路径。

### 4.5 Lookahead 预测（skip_inst0 专用）

BP 额外暴露 `la_*` 端口，用 `la_pc = pc_plus8`（寄存器）提前查询。当 `will_skip_inst0` 成立时，将 lookahead 预测结果锁存到 `skip_bp_*_r` 寄存器组，下拍 skip 时直接使用，无组合延迟。

---

## 5. 流水线级间寄存器

| 级间 | Slot 0 | Slot 1 |
|------|--------|--------|
| IF/ID | `if_id_reg` | 共享（传递 inst1 + s1_valid） |
| ID/EX | `id_ex_reg` | `id_ex_reg_s1` |
| EX/MEM | `ex_mem_reg` | `ex_mem_reg_s1` |
| MEM/WB | `mem_wb_reg` | `mem_wb_reg_s1` |

- 控制：`allowin` 每级一个，`ready_go` = `s0_rg & (s1_rg | !s1_valid)`（实际由 forwarding 的 `id_ready_go` 统一输出）
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

- **EX 级**：`branch_unit` 组合产生 `branch_flush`（方向错 / 目标错）
- **MEM 级**：`mem_branch_flush` = `branch_flush` 打拍（250MHz 时序优化）
- **Flush 范围**：
  - `id_flush = mem_branch_flush | id_bp_redirect`（杀 IF/ID）
  - `ex_flush = mem_branch_flush`（杀 ID/EX 两个 Slot）
  - `ex_mem_reg_s1.s1_flush = branch_flush | mem_branch_flush`（同拍杀 S1 进 MEM）
  - 指令缓冲清空

### 9.2 Slot1 同拍 Flush

当 slot0(branch) + slot1(ALU) 在 EX 级，branch 误预测时：
- `branch_flush` 当拍有效，`mem_branch_flush` 下拍才生效
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
| `id_ex_reg` / `_s1` | ID/EX 级间寄存器 | S1 版本接 squash 门控 |
| `alu` ×2 | ALU（S0 / S1） | 含独立地址加法器 `alu_addr` |
| `branch_unit` | 分支判断 + 误预测检测 | 只处理 S0 |
| `mem_interface` | Store 移位 / Load 扩展 | EX store，WB load |
| `ex_mem_reg` / `_s1` | EX/MEM 级间寄存器 | S1 版本接 `ex_branch_flush` |
| `mem_wb_reg` / `_s1` | MEM/WB 级间寄存器 | S1 无 load 路径 |
| `wb_mux` ×2 | 写回选择（ALU / Load / PC+4） | S1 的 load 输入接 0 |
| `branch_predictor` | Tournament BP (BTB+GShare+Selector+RAS) | L0 IF 快速预测，L1 ID 验证 |
| `dcache` | 2-way WT+WA 数据缓存 | Store buffer + refill FSM |
| `mmio_bridge` | MMIO 外设桥 | LED / SEG / SW / KEY / CNT |
| `student_top` | 顶层集成 | cpu + IROM + DCache + DRAM + MMIO |

---

## 13. 后续优化方向

| 方向 | 预期收益 | 复杂度 |
|------|---------|-------|
| inst0→inst1 同周期前递（放开 RAW） | 双发率 +5~10% | 高 |
| 裁剪低优先级前递路径（S0_WB） | 时序改善 | 低 |
| Slot1 扩展 Load/Store | 双发率 +10~15% | 很高 |
