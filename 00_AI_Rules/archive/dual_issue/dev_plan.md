# 双发射 Tradeoff 与踩坑记录

> **目的**：防止未来 AI 走回头路。改架构前先读本文件。

---

## T1. IROM 方案：slot bank > even/odd bank

**结论**：用 slot0/slot1 两个 32-bit BRAM，共享 `irom_addr[13:2]`。

**否决方案**：even/odd bank（偶地址 bank + 奇地址 bank）。odd bank 需要 `addr+1` 进位链，直接吃掉 ~0.5ns 时序。

**代价**：PC[2]=1 时只能取 slot1（slot0 是上一对的高 word），退化单发。实测 CPI 影响 ~0.02，远小于 +1 进位链的时序代价。

---

## T2. can_dual_issue 解码：raw BRAM 直接解码 > 经过 MUX 链后解码

**结论**：从 `irom_inst0/1`（raw BRAM output）直接解码 opcode，不走 `inst_buf MUX → held MUX` 串行链。

**否决方案**：从 `if_inst0_out / if_inst1_out`（经过 2 级 MUX 的最终值）解码。多 2 级 LUT 串在 IROM→IROM 关键路径上，WNS 差 ~0.2ns。

**代价**：需额外维护 `held_can_dual_r` 寄存器（stall 入口快照），逻辑略复杂。但时序收益远大于复杂度代价。

**注意**：`inst_buf_valid` 时 raw 解码仍然正确——因为 inst_buf 填充时 BRAM 地址没变，slot0 内容与 inst_buf 一致。**不要**加 `~inst_buf_valid` 门控，会破坏这个时序优化。

---

## T3. irom_addr MUX：去掉 allowin 链依赖

**结论**：`irom_addr` 的 stall 保持改为用 `irom_inst0/1_held` 寄存器实现，而非在 MUX 里加 `~id_allowin ? pc : ...`。

**否决方案**：MUX 中直接判断 stall 选 pc 保持。这会把 `cache_ready → mem_allowin → ex_allowin → id_allowin` 整条链放到 IROM 地址路径上，关键路径灾难。

**代价**：需要 held register + held_valid 逻辑。

---

## T4. 分支双发：`~is_jump` > `~is_control`

**结论**：条件分支允许与 slot1 ALU 双发，只屏蔽 JAL/JALR。

**否决方案**：所有控制指令（含条件分支）都不双发。安全但严重限制双发率。

**需要的安全机制**（缺一不可，否则会出功能 bug）：
1. **NLP squash**：`id_s1_squash_raw = id_bp_redirect_raw & id_tournament_taken` — 当 L1 Tournament 判定 slot0 分支 taken 时，杀掉错误路径的 slot1
2. **必须用 `_raw` 版本**：squash 信号不能经过 `id_ready_go & ex_allowin` 门控。否则 doomed slot1 的 load-use 冒险会阻止 redirect，导致**死锁**
3. **EX 同拍 flush**：`ex_mem_reg_s1` 必须接 `ex_branch_flush = branch_flush`。因为 `mem_branch_flush` 要下拍才生效，同拍的 slot1 会漏进 MEM 并错误写回

**踩过的坑**：
- `raw_pair_raw` 必须用 `raw_inst0_writes_rd` 门控。Store / Branch 的 rd 字段有值但不写寄存器，不门控会产生 RAW 假阳性，误阻止双发

---

## T5. branch_flush 打拍到 MEM（250MHz 时序）

**结论**：`branch_flush`（EX 级组合）→ 打拍 → `mem_branch_flush`（MEM 级寄存器）。所有 flush 相关控制（`id_flush` / `ex_flush` / `irom_addr` / 预测器更新门控）都用 `mem_branch_flush`。

**否决方案**：直接用 EX 级组合 `branch_flush` 驱动 flush。关键路径：`ALU → branch_unit → flush → id_allowin → irom_addr → BRAM`，250MHz 不可能闭合。

**代价**：flush 晚一拍，错误路径多执行一条指令（进入 EX 后被 `mem_branch_flush` 杀掉）。需要额外门控：
- `cache_req` 门控 `~mem_branch_flush`（防止错误路径触发 DCache）
- BP 更新门控 `ex_valid & ~mem_branch_flush`（防止错误路径污染预测器）
- `ex_mem_reg` 的 `ex_branch_flush` 门控 `& ~mem_branch_flush & mem_allowin`（防止自杀 + stall 期间重复 flush）

---

## T6. 前递网络：完整 7 选 1 > 裁剪

**结论**：保留完整 S1_EX > S0_EX > S1_MEM > S0_MEM > S1_WB > S0_WB > RF 优先级链。

**考虑过的裁剪**：去掉 S1_WB / S0_WB（WB 级可以直接写 regfile，下拍 RF 数据已更新）。但 regfile 是 read-first，WB 写入是 posedge，同拍 ID 读到的是旧值。去掉 WB 前递会引入 1 周期 stall 或功能错误。

**结论**：暂不裁剪，等综合报告确认前递是否真在关键路径上再决定。

---

## T7. DCache：单端口 > 双端口

**结论**：DCache 保持单端口，只有 Slot 0 可以 Load/Store。

**否决方案**：双端口 DCache 让 Slot 1 也做 L/S。需要双 miss 仲裁、store-to-load forwarding、双写冲突检测，复杂度极高，且 FPGA BRAM 天然只有 2 端口（已被 read+write 占满）。

**代价**：Slot 1 只能 ALU，双发率受限。实测条件分支放开后双发率已有显著提升，暂不值得为此大改。
