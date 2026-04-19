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

---

## 维护指引

1. **每次重大功能变更或优化后**，在本文件追加一条里程碑记录
2. **记录格式**：Commit hash + 简要说明 + 是否经过验证
3. **FPGA 验证通过的版本**标记 ✅，作为可靠回档点
4. 建议在关键节点打 git tag：`git tag -a M3-fpga-verified 22f40e9 -m "FPGA 验证通过"`
