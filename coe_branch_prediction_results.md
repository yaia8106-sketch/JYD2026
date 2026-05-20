# COE 分支预测统计结果

日期：2026-05-20

本文档记录当前 `02_Design/coe/single_issue/` 下六份 COE 测试程序的完整程序级分支预测统计结果。

## 测量方法

- 仿真器：Verilator，使用当前 RTL 和仅用于仿真的 `perf_monitor` 构建。
- 计数器来源：`02_Design/riscv_tests/tb/perf_monitor.sv`。
- 分支总数口径：`Total branch = ex_is_branch | ex_is_jal | ex_is_jalr`。
- 误预测计数口径：EX 阶段的 `branch_flush`。
- 预测率计算公式：

```text
prediction_rate = 1 - Mispredicts / Total_branch
```

`NLP redirects` 单独列出，不计入 `Mispredicts`。

## 停机条件

通用 `tb_riscv_tests.sv` 会在第一次 LED MMIO 写入时停止。对于 `current/src0/src1/src2`，第一次 LED 写入就是最终 COE 结果，因此这个停机条件是正确的。

对于 `new_without_Mext` 和 `new_with_Mext`，第一次 LED 写入不是程序结束点。这两份程序已使用临时 `/tmp` testbench 重新运行：该 testbench 会忽略中途 LED 写入，只在程序到达最终自旋点时停止：

- `new_without_Mext`：在提交 PC 为 `0x80000010` 时停止。
- `new_with_Mext`：在提交 PC 为 `0x80000014` 时停止。

因此，之前约 1K cycles 的短结果是无效的，不能使用。

## 最终结果

| COE | 停机条件 | Cycles | 总提交指令数 | CPI | 分支总数 | 误预测数 | 误预测率 | 预测率 | NLP redirects | 双发射率 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `current` | 最终 COE LED 写入 `0x01221c08` | 36,247,924 | 30,761,346 | 1.178 | 9,538,432 | 948,440 | 9.9% | 90.1% | 1,287,223 | 60.6% |
| `src0` | 最终 COE LED 写入 `0x01221c08` | 2,044,868,564 | 1,417,756,400 | 1.442 | 241,355,203 | 45,377,904 | 18.8% | 81.2% | 29,806,681 | 16.9% |
| `src1` | 最终 COE LED 写入 `0x01221c08` | 2,153,225,504 | 1,304,110,661 | 1.651 | 220,242,312 | 20,788,557 | 9.4% | 90.6% | 14,057,067 | 11.6% |
| `src2` | 最终 COE LED 写入 `0x01221c08` | 2,637,386,996 | 1,849,101,593 | 1.426 | 479,516,092 | 93,027,943 | 19.4% | 80.6% | 56,623,497 | 30.8% |
| `new_without_Mext` | 自旋 PC `0x80000010`，最终 LED `0x04887123`，共 4 次 LED 写入 | 1,132,685,661 | 783,164,548 | 1.446 | 145,012,831 | 31,001,622 | 21.4% | 78.6% | 18,464,386 | 20.5% |
| `new_with_Mext` | 自旋 PC `0x80000014`，最终 LED `0x048a7121`，共 4 次 LED 写入 | 629,033,648 | 380,344,274 | 1.654 | 11,215,167 | 133,271 | 1.2% | 98.8% | 28 | 6.0% |

## 说明

- `current/src0/src1/src2` 在通用 riscv-tests testbench 中会打印为 `[FAIL] test #9506308`，原因是该 testbench 把任何非 `1` 的 LED 值都解释为 riscv-tests 失败码。对于这些 COE 程序，`0x01221c08` 是 COE 的通过 LED 图案，因此这些运行按完整 COE PASS 处理。
- `new_without_Mext` 和 `new_with_Mext` 使用不同的最终 LED 值，并且存在中途 LED 写入。它们的最终完成状态通过到达 self-loop PC 验证，而不是通过第一次 LED 写入验证。
- 临时日志和修改过的 64-bit / done-PC testbench 保存在 `/tmp/coe_bp_full_1779241412/`。
