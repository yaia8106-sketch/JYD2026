# 双发射开发状态

> 架构详情见 `architecture.md` | 开发历史见 `dev_plan.md`

---

## 当前状态（2026-05-05）

- **RTL 功能完备**，仿真回归 **63/63 PASS**
- **Vivado 上板待做**（用户短期无法上板）

## 仿真回归

| 类别 | 数量 | 示例 |
|------|------|------|
| 官方 RV32I | 39 | add, beq, lw, jal … |
| 存储 / Cache | 5 | ld_st, dcache_stress, sb_stress … |
| 分支预测 | 2 | bp_stress, bp_dual |
| 双发射基础 | 8 | dual_alu, raw_block, waw, inst_buffer … |
| 分支双发 | 3 | branch_dual, branch_dual_flush, branch_dual_edge |
| 其他 | 6 | counter_stress, ras_overflow … |
| **合计** | **63** | |

## 时序

| 指标 | 值 | 说明 |
|------|----|------|
| 目标频率 | 250MHz | 4ns 周期 |
| 上次综合 WNS | -0.021ns | 分支双发优化前，需重新综合确认 |
| 关键路径 | IROM(BRAM) → IROM(BRAM) | PC → can_dual → irom_addr → BRAM |

## 待做

- [ ] Vivado 重新综合（含分支双发 RTL 改动）
- [ ] FPGA 上板验证（src0 / src1 / src2）
- [ ] CPI 性能对比（基线 CPI ≈ 1.141，目标 < 1.0）
