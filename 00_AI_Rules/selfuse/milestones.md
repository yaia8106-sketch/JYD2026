# 关键提交记录（里程碑 & 回档点）

本文档记录项目中的关键提交节点，方便回档和追溯。

> **回档方法**：`git checkout <commit_hash>` 查看，`git reset --hard <commit_hash>` 回退。

---

## 里程碑列表

### 🏁 M1: 初始 RTL 完成
- **Commit**: `fe909a5`
- **说明**: RV32I 五级流水线 RTL 初始版本，全部模块完成

### 🏁 M2: 仿真全通过
- **Commit**: `a1aa6b3`
- **说明**: IROM 预取方案实现，Vivado 行为仿真 37 个测试全通过

### 🏁 M3: FPGA 上板验证通过（50MHz）✅
- **Commit**: `22f40e9`
- **说明**: 数字孪生平台集成完成，FPGA 烧录验证通过（LED 对勾 + 数码管 37）
- **重要**: 这是最后一个**功能完全正确且经过 FPGA 验证**的稳定版本
- **回档提示**: 如果后续优化导致功能异常，回到这里

### 🏁 M4: perip_bridge 时序优化（180MHz，FPGA 验证通过）✅
- **Commit**: `48b0f45`
- **说明**: ALU sum 直出 + 部分地址译码 + 并行 AND-OR + wdata 2-bit 命令解码
- **效果**: 最差路径 5.035ns → 3.802ns（↓24.5%），slack +0.377→+1.170ns @180MHz
- **FPGA 验证**: 通过

### 🏁 M5: 200MHz Implementation 通过 + 文档完整化
- **Commit**: `ce50982`
- **说明**: 200MHz timing met（slack +0.011ns），瓶颈转为布线延迟
- **新增**: COE 指令分布分析、分支预测/RAS 优化计划、JAL/JALR 迁移取消记录

### 🏁 M6: 纯净 EX-only 基线 FPGA 验证通过（200MHz）✅ ⭐ 预测器前最终基线
- **Commit**: `bb094dd` (tag: `M6-baseline`)
- **说明**: 清理全部预测器和 JAL ID-stage 残留代码后的纯净 EX-only 基线，数字孪生平台 FPGA 上板验证**功能完全正确**
- **验证结果**: 数字孪生平台上板通过，riscv-tests 40/40 PASS
- **⚗️ 重要**: 添加分支预测器前的最后一次功能正确性确认

### 🏁 M7: NLP Tournament 分支预测器合并 + FPGA 验证通过（200MHz）✅
- **Commit**: `ddc0be4` (master)
- **说明**: Tournament 分支预测器（BTB64 + Bimodal + GShare + Selector + RAS4）合并到 master
- **验证结果**: FPGA 上板通过 @ 200MHz，riscv-tests 42/42 PASS（含 bp_stress + coprime）
- **性能**: current 程序 ~176ms

### 🏁 M8: 250MHz 超频尝试（feat/250mhz-timing 分支）
- **Commit**: `2f84a77` (feat/250mhz-timing)
- **说明**: Flush 延迟 EX→MEM 优化关键路径，200MHz 时序收敛，250MHz 未收敛
- **瓶颈**: DRAM 68×BRAM36 高扇出布线（CPU 逻辑已具备 250MHz 能力）
- **性能**: current 程序 ~180+ms（flush penalty +1 cycle）

### 🏁 M9: DCache 实现 + FPGA 验证通过（4/4 COE 全部通过）✅
- **日期**: 2026-04-24
- **说明**: 2KB 2-way set-associative DCache (16B line, Write-Through + Write-Allocate, 1-entry Store Buffer)
- **架构变更**: DRAM 从 CPU 直连改为 DCache 管理；perip_bridge 瘦身为 mmio_bridge
- **关键修复**:
  1. `cache_flush` 连接 `mem_branch_flush`（原硬编码为 0，refill 不会被 flush 中止）
  2. Refill 开始时先失效 victim tag（防止 flush 中止后部分覆写的 line 被命中）
  3. **DRAM 延迟修复**: `rf_data_valid` 从 `>= 2` 改为 `>= DRAM_LATENCY(3)`——DRAM4MyOwn 有 DOB_REG=1（2-cycle 读延迟），原代码提前 1 拍采样，导致 refill 数据全错
  4. **Synth 8-7137 修复**: DCache forwarding 寄存器（`rf_fwd_way/tag/idx`、`rf_last_fwd_*`、`st_fwd_*`）在 `!rst_n` 分支缺少显式复位，Vivado 综合行为与仿真不一致，导致 current 程序指令条数显示为 00。添加 10 个寄存器的显式复位后修复。（决策 Q）
- **验证结果**: 全部 4 个 COE 程序 FPGA 上板通过 ✅（current + src0 + src1 + src2）
- **⚠️ 教训**:
  1. student_top.sv 注释 "无 output register" 与 IP 实际配置（DOB_REG=1）不符，导致 DCache 延迟参数设错
  2. Vivado Synth 8-7137 是严重 warning——异步复位块中**所有寄存器**必须有显式复位值

### 🏁 M10: 250MHz 时序收敛（WNS = +0.025ns）✅
- **日期**: 2026-04-29
- **说明**: 通过 Pblock 约束 + RTL 关键路径优化实现 250MHz 时序收敛
- **关键改动**:
  1. DCache 4KB→2KB 回退（减少 cell 面积，给 Pblock 留空间）
  2. Pblock 约束：CPU + IROM + DCache 共置于 `CLOCKREGION_X0Y3:CLOCKREGION_X1Y3`
  3. `pc_plus4` 寄存器：消除 irom_addr 默认路径 `pc+4` carry chain（-0.125ns → -0.005ns）
  4. `bp_target` sel_seq 删除：消除 `pc→bp_target→IROM` carry chain（-0.005ns → +0.025ns）
- **时序改善历程**: -0.414ns → -0.284ns → -0.125ns → -0.005ns → **+0.025ns** ✅
- **验证结果**: riscv-tests 43/43 PASS（iverilog）
- **⚠️**: 250MHz 版本尚未 FPGA 上板验证稳定性

---

## 重要回滚点

| Tag | Commit | 说明 | 可信度 |
|-----|--------|------|:------:|
| **功能基线** | `22f40e9` | FPGA 验证通过，功能完全正确（50MHz） | ⭐⭐⭐⭐⭐ |
| **180MHz 基线** | `48b0f45` | 时序优化完成，FPGA 验证通过 | ⭐⭐⭐⭐⭐ |
| **200MHz** | `ce50982` | Implementation 通过 | ⭐⭐⭐ |
| **🔒 预测器前最终基线** | `bb094dd` | 纯净 EX-only，FPGA 功能正确 (tag: M6-baseline) | ⭐⭐⭐⭐⭐ |
| **Tournament BP** | `ddc0be4` | NLP 分支预测器，FPGA 验证通过 @ 200MHz | ⭐⭐⭐⭐⭐ |
| **250MHz 尝试** | `2f84a77` | flush 延迟优化，200MHz 收敛，250MHz 未收敛 | ⭐⭐⭐ |
| **DCache 验证** | (M9) | DCache 实现，4/4 COE 全部 FPGA 通过 | ⭐⭐⭐⭐⭐ |
| **250MHz 收敛** | (当前) | WNS=+0.025ns，仿真通过，**FPGA 待验证** | ⭐⭐⭐ |

---

## 维护指引

1. **每次重大功能变更或优化后**，在本文件追加一条里程碑记录
2. **记录格式**：Commit hash + 简要说明 + 是否经过验证
3. **FPGA 验证通过的版本**标记 ✅，作为可靠回档点
4. 建议在关键节点打 git tag：`git tag -a M3-fpga-verified 22f40e9 -m "FPGA 验证通过"`
