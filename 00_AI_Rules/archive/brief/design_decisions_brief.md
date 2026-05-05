# 设计决策精简版

> 完整版见 `full/design_decisions.md`。本文件只保留结论、约束和教训。

---

## 架构基础 (A-F)

| ID | 决策 | 结论 | 关键约束 |
|----|------|------|---------|
| A | Regfile 读写冲突 | **Read-first** | 3 级前递 (EX>MEM>WB>regfile) |
| B | Flush 代价 | **3 拍气泡** | 决策 K 将 flush 延迟 EX→MEM，penalty 2→3 |
| C | JAL/JALR | **全部 EX 级** | JAL 提前到 ID → FPGA 跑飞；JALR → 时序不收敛。用 BP 替代 |
| D | 控制信号 | 14 个，见 `isa_encoding.md` | ALU op = `{funct7[5], funct3}`；分支条件直接复用 funct3 |
| E | DRAM 访存 | 32-bit SDP BRAM + 4-bit WEA | `addr[1:0]` 流水线传递，WB 级字节提取 |
| F | 前递路径 | ID 级 MUX，AND-OR one-hot | MEM 级排除 Load；Load-use 2 拍 stall |
| F2 | Load-use stall | 保持 2 拍 | MEM Load 前递 ~4ns，超出 250MHz 预算 |

## 存储与取指 (G-H)

- **IROM**: 1 拍 BRAM（无 output register），4 路优先级 MUX + `irom_data_held` 停顿保持
  - 优先级: `mem_flush > id_redirect_raw > bp_taken > pc_plus4`
  - PC 复位 = `0x7FFF_FFFC`（text_base - 4）
- **DRAM**: SDP, 256KB (64×BRAM36), DOB_REG=1, `DRAM_LATENCY=4`
  - 由 DCache 管理，CPU 不直连 DRAM
- **DCache**: 2KB 2-way 16B line, WT+WA, 1-entry Store Buffer, LRU
  - 2×BRAM18, 6 状态 FSM, ~9 cycles/miss
  - flush 中断 refill，victim tag 提前失效

## 分支预测 (J)

- **NLP Tournament**: BTB 128 + Bimodal BHT + GShare (8-bit GHR, 256 PHT) + Selector 256 + RAS 4
- IF(L0): bht[1] 快速预测; ID(L1): Tournament 纠正; EX: 全部状态更新
- 平均准确率 84.81%, CPI ≈ 1.141 (flush penalty=3)
- **已验证无效**: RAS 4→8/16（零效果）; GHR≥12（时序违例）; BTB 256（vs 128 无差异）

## 时序优化 (I, K, M, N, S, T)

| ID | 改动 | 效果 | 原理 |
|----|------|------|------|
| I | perip_bridge AND-OR + `alu_sum` 直出 + 部分译码 | 5.0ns→3.8ns | 省 2 级 LUT |
| K | Flush 延迟 EX→MEM（打一拍） | 250MHz CPU 逻辑就绪 | 代价: penalty 2→3 |
| M | `branch_unit` 用 `alu_addr`; `btb_valid` LUTRAM 化; L0 AND-OR | 各省 1-2 级 | 跳过 ALU output MUX |
| N | `next_pc_mux` 消除; BTB tag 7→5; redirect raw/gated 拆分 | IF/ID→IROM 7级→4级 | don't-care 优化 + 去 hazard 依赖 |
| S | Pblock 约束 + `pc_plus4` 寄存器 + `bp_target` sel_seq 删除 | WNS -0.414→+0.025ns | 消除 carry chain + 布线约束 |
| T | `bp_target` sel_btb/sel_ras 去 tag_match | WNS +0.025→**+0.120ns** | bp_taken 已含 tag_match 门控，bp_target 是 don't-care |

**最终 250MHz WNS = +0.120ns**，瓶颈: PC→IROM (6级) 和 DCache→DRAM (0级纯布线) 并列。

## Bug 修复与教训

| ID | Bug | 根因 | 教训 |
|----|-----|------|------|
| D-11 | JAL/JALR 前递值错误 | forwarding 取 alu_result（跳转目标）而非 PC+4（返回地址） | BP 改变了流水线共存关系，新功能必须重审前递/stall/flush |
| O | DCache refill 数据全错 | `rf_data_valid >= 2` 但 DRAM 实际 DOB_REG=1 需 ≥4 | IP XCI 配置是唯一可信来源，注释可能错 |
| P | PC+4 预算 + iverilog 兼容 | forwarding/wb_mux 各含 `pc+32'd4` 加法器 | 加法器集中预算到 EX 级，消除后续级的 carry chain |
| Q | DCache forwarding 寄存器 FPGA 错误 | `always_ff` 异步复位块中部分寄存器无显式复位 | **Synth 8-7137 是严重 warning**——所有寄存器必须有显式复位 |
| — | BTB 误预测非分支指令致 DCache 数据损坏 | cache_req 被 branch_flush 门控 + ex_mem_reg flush 优先级 + dcache pipeline_advance `\|flush` | 三个修复必须配对；flush 不能无条件杀 valid |

## 参数优化 (R)

- **BTB 64→128**: src0 BTB miss 37,940→202，最大单一改善，已采用
- **DCache 2KB→4KB**: 零 BRAM 成本但 Pblock 面积紧，为 250MHz 回退到 2KB
- **GHR 8→10**: CPI -0.009 但 PHT 写路径 slack 不足，未实施（复赛可选）
