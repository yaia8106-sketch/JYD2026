# Stage-1 Frontend Predictor Cleanup Plan

本文档记录 Stage-1 前端预测器的收口状态和后续清理边界。

## 当前状态

当前只有一个有效前端版本：

```text
ABTB + PHT branch steering
ABTB miss sequential
EX redirect final correction
```

已经删除的历史路径：

- shadow-only ABTB 前端版本。
- J/CALL-only direct steering 版本。
- registered frontend correction wrapper。
- legacy frontend correction 机制。

当前 `branch_predictor.sv` 仍实例化，但不再决定 frontend next PC。它暂时只为旧训练 metadata、历史 RAS/JALR plumbing 和统计路径保留，下一阶段再移除实例和对应 metadata 管线。

## 核心原则

不要在阶段 3 一次性删除 `branch_predictor.sv`。

原因是旧 predictor 仍提供若干 EX update 所需 metadata：

- `bp_ghr_snap`
- `bp_btb_hit`
- `bp_btb_type`
- `bp_btb_bht`
- `bp_pht_cnt`
- `bp_sel_cnt`
- slot1 对应 `bp_s1_*` 训练 metadata

这些字段仍从 FTQ/FQ 进入 IF/ID、ID/EX，并供旧 predictor 的 confirmed EX training 使用。它们下一阶段与 `branch_predictor` 实例一起删除。

## 已完成阶段

### 阶段 1：固定 branch steering 为默认路径

- 默认构建就是 ABTB + PHT branch steering。
- `TYPE_JAL` / `TYPE_CALL` 永远参与 ABTB steering。
- `TYPE_BRANCH` 永远由 ABTB/PHT ownership 管理。
- functional 顶层入口只使用 `functional/run_all.sh`。
- 历史 direct/branch wrapper 已删除。

### 阶段 2：ABTB/PHT 成为唯一 Stage-1 steering 来源

`frontend_ftq` 的 canonical next PC 只来自：

- ABTB J/CALL taken。
- ABTB branch + PHT taken。
- ABTB-owned branch not-taken 后继续选择 younger bank1 taken CFI。
- sequential PC。

ABTB miss 不再回退 legacy `bp_taken/bp_target`。RET 和普通 indirect JALR 未命中时当前接受 fall through，由 EX redirect 修正。

### 阶段 3：删除旧 frontend correction

已删除：

- F0 legacy correction 仲裁逻辑。
- F0 registered correction pending/target state。
- FQ `lookup_taken` / `lookup_target` / `bp_verified` 字段。
- `if_id_reg` 中的 verified 标记。
- `id_stage_derive` 中的 tournament direction、ID redirect 和 slot1 squash 输出。
- `cpu_top` 中 ID redirect 参与 flush/epoch/ID-EX prediction override 的路径。
- 旧 frontend correction 相关性能计数和 parser 字段。

阶段 3 后，frontend redirect 来源只剩后端/EX redirect。`id_flush` 不再由 ID correction 产生，slot1 有效性只由 FQ/pair-policy/flush 控制。

## 旧 Predictor Metadata 处理表

| 旧信号或概念 | 当前用途 | 后续处理 |
|---|---|---|
| `bp_taken` / `bp_target` | 旧 predictor 输出；不再 steering | 随旧 predictor 实例删除 |
| `bp_btb_hit` / `bp_btb_type` | 旧 predictor training metadata | 随旧 predictor 实例删除 |
| `bp_btb_bht` / `bp_pht_cnt` / `bp_sel_cnt` | 旧 predictor counter snapshot | 随旧 predictor 实例删除 |
| `bp_ghr_snap` | 旧 predictor update snapshot | 随旧 predictor 实例删除 |
| `bp_s1_*` | slot1 legacy training metadata | 随旧 predictor 实例删除 |
| `ex_bp_taken` / `ex_bp_target` | EX mispredict 比较，来源已是 Stage-1 canonical metadata | 后续建议改名为 `ex_pred_*` |
| `bp_train_*` | confirmed EX update 管线 | 后续建议改名为 `stage1_train_*` |
| legacy RAS/JALR sidecar | 暂留于旧 predictor；当前 Stage-1 不依赖 | 删除后若要恢复性能，单独实现 uRAS |
| `stage1_sequential_count` | ABTB/PHT 未选择 steering 时的 canonical sequential block 计数 | 保留 |

## 下一阶段

### 阶段 4：移除 `branch_predictor` 实例和旧 metadata 管线

目标：

```text
cpu_top 不再实例化 branch_predictor。
旧 bp_* metadata 不再贯穿 FTQ/FQ、IF/ID、ID/EX。
```

建议步骤：

1. 从 `cpu_top.sv` 删除 `u_bp` 实例。
2. 从编译脚本 RTL 文件列表删除 `branch_predictor.sv`。
3. 从 `frontend_ftq.sv`、`if_id_reg.sv`、`id_ex_reg.sv`、`id_ex_reg_s1.sv` 删除旧 `bp_*` 训练端口。
4. 将仍有功能含义的 prediction 字段改名为 `pred_*` 或 `stage1_*`。
5. 重新跑定向前端测试和 CPU 81 项回归。

### 阶段 5：确认 RET/JALR fall-through 策略

旧 predictor 删除后，RET/JALR 会失去 legacy RAS/JALR sidecar。当前接受的策略是：

```text
RET/JALR 未被 ABTB 命中时，前端顺序取指。
EX 发现实际跳转后 redirect。
```

如果后续需要恢复返回预测性能，应单独实现 uRAS，不要和旧 predictor 删除混在同一阶段。

## 验证门槛

每个清理阶段至少运行：

```bash
bash 02_Design/riscv_tests/functional/frontend/run_abtb.sh
bash 02_Design/riscv_tests/functional/frontend/run_direction.sh
bash 02_Design/riscv_tests/functional/frontend/run_pair.sh
bash 02_Design/riscv_tests/functional/frontend/run_canonical.sh
bash 02_Design/riscv_tests/functional/frontend/run_steering.sh
bash 02_Design/riscv_tests/functional/run_all.sh
```

静态检查：

```bash
git diff --check
bash -n 02_Design/riscv_tests/functional/run_all.sh
bash -n 02_Design/riscv_tests/functional/frontend/run_canonical.sh
bash -n 02_Design/riscv_tests/functional/frontend/run_steering.sh
bash -n 02_Design/riscv_tests/performance/short/run_perf.sh
bash -n 02_Design/riscv_tests/performance/branch/run_branch_diag.sh
```

## 非目标

本轮清理不要顺手做这些事：

- 不改 ABTB 容量、bank 数、way 数。
- 不做 target 压缩。
- 不新增 speculative GHR recovery。
- 不优化时序。
- 不实现 uRAS。
- 不删除 `branch_predictor.sv` 或旧 predictor 实例。

不要把阶段 3 和阶段 4 合成一个大改。阶段 3 的目标是删除死 correction 机制，同时保持旧 predictor training metadata 可回归。
