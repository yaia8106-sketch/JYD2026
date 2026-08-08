#!/usr/bin/env python3
"""Screen and compare NSCSCC performance directions against a 5% bar."""

from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path


IDEAL_CLASSES = (
    ("分支错误恢复", "l2_branch_mispredict_slots"),
    ("全部 Fetch Latency", "l2_fetch_latency_slots"),
    ("全部 Fetch Bandwidth", "l2_fetch_bandwidth_slots"),
    ("Load/repair 依赖", "l3_load_repair_dependency_slots"),
    ("全部同组 RAW", "l3_same_pair_dependency_slots"),
    ("配对策略/类型限制", "l3_pairing_policy_slots"),
    ("MulDiv", "l3_muldiv_slots"),
    ("串行化", "l3_serialization_slots"),
    ("Memory Bound", "l2_memory_bound_slots"),
)

IMPLEMENTABLE_SUBDIRECTIONS = (
    ("I$ refill", ("l4_fetch_icache_refill_slots",)),
    ("取指查询/响应等待", ("l4_fetch_response_slots",)),
    ("前端无排队/在途请求", ("l4_fetch_empty_slots",)),
    (
        "普通顺序第二槽供给",
        (
            "l4_fetch_single_no_second_slots",
            "l4_fetch_single_noncontiguous_slots",
        ),
    ),
    ("已在 FQ 且可配对的跳转目标", ("l5_fetch_taken_target_pairable_slots",)),
    (
        "所有预测跳转的目标侧第二槽",
        ("l4_fetch_single_taken_slots",),
    ),
    (
        "ALU 生产者的全部同组 RAW",
        (
            "l4_pair_raw_alu_to_alu_slots",
            "l4_pair_raw_alu_to_lsu_slots",
            "l4_pair_raw_alu_to_cfi_slots",
        ),
    ),
    ("同组 Load 生产者 RAW", ("l4_pair_raw_lsu_producer_slots",)),
    ("EX-only Load RAW", ("l5_load_ex_only_slots",)),
    ("MEM-ready-only Load RAW", ("l5_load_mem_ready_only_slots",)),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--baseline",
        type=Path,
        default=Path("/tmp/nscscc-rtl-perf-results"),
    )
    parser.add_argument(
        "--variant",
        action="append",
        default=[],
        metavar="LABEL=RESULT_DIR",
    )
    parser.add_argument(
        "--repair-variant",
        help="variant label used for delayed repaired-redirect sensitivity",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("/tmp/nscscc-perf-direction-results"),
    )
    parser.add_argument("--threshold", type=float, default=0.05)
    return parser.parse_args()


def read_rows(result_dir: Path) -> dict[str, dict]:
    path = result_dir / "rtl_perf_profile.csv"
    with path.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise RuntimeError(f"no benchmark rows in {path}")
    result = {}
    for row in rows:
        benchmark = row["benchmark"]
        if benchmark in result:
            raise RuntimeError(f"duplicate benchmark {benchmark} in {path}")
        if row.get("status") != "PASS" or int(row.get("pass", 0)) != 1:
            raise RuntimeError(f"{benchmark}: result is not PASS in {path}")
        result[benchmark] = row
    return result


def read_aggregate(result_dir: Path) -> dict:
    return json.loads((result_dir / "aggregate.json").read_text())


def geometric_mean(values: list[float]) -> float:
    if not values or any(value <= 0.0 for value in values):
        return 0.0
    return math.exp(sum(math.log(value) for value in values) / len(values))


def percent(value: float) -> str:
    return f"{100.0 * value:.3f}%"


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    result = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    result.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(result)


def slot_compression_speedup(cycles: int, slots: int) -> float:
    projected = cycles - slots / 2.0
    return cycles / projected - 1.0 if projected > 0 else float("inf")


def parse_variants(specifications: list[str]) -> dict[str, Path]:
    result = {}
    for specification in specifications:
        if "=" not in specification:
            raise RuntimeError(
                f"variant must use LABEL=RESULT_DIR: {specification}"
            )
        label, raw_path = specification.split("=", 1)
        if not label or label in result:
            raise RuntimeError(f"invalid or duplicate variant label: {label}")
        result[label] = Path(raw_path)
    return result


def compare_variant(
    baseline_rows: dict[str, dict], variant_rows: dict[str, dict]
) -> dict:
    if set(baseline_rows) != set(variant_rows):
        raise RuntimeError("variant benchmark set differs from baseline")
    baseline_cycles = 0
    variant_cycles = 0
    ratios = []
    per_program = []
    for name, baseline in baseline_rows.items():
        variant = variant_rows[name]
        if int(baseline["instructions"]) != int(variant["instructions"]):
            raise RuntimeError(f"{name}: dynamic instruction count changed")
        before = int(baseline["cycles"])
        after = int(variant["cycles"])
        baseline_cycles += before
        variant_cycles += after
        ratios.append(before / after)
        per_program.append(
            {
                "benchmark": name,
                "baseline_cycles": before,
                "variant_cycles": after,
                "speedup": before / after - 1.0,
            }
        )
    return {
        "baseline_cycles": baseline_cycles,
        "variant_cycles": variant_cycles,
        "saved_cycles": baseline_cycles - variant_cycles,
        "aggregate_speedup": baseline_cycles / variant_cycles - 1.0,
        "geomean_speedup": geometric_mean(ratios) - 1.0,
        "per_program": per_program,
    }


def main() -> int:
    args = parse_args()
    variants = parse_variants(args.variant)
    baseline_rows = read_rows(args.baseline)
    aggregate = read_aggregate(args.baseline)
    cycles = int(aggregate["cycles"])
    required_saved_cycles = cycles - cycles / (1.0 + args.threshold)
    required_slots = 2.0 * required_saved_cycles

    ideal_rows = []
    ideal_json = []
    for label, key in IDEAL_CLASSES:
        slots = int(aggregate[key])
        speedup = slot_compression_speedup(cycles, slots)
        ideal_rows.append(
            [
                label,
                f"{slots:,}",
                percent(speedup),
                "是" if speedup >= args.threshold else "否",
            ]
        )
        ideal_json.append(
            {"label": label, "slots": slots, "ideal_speedup": speedup}
        )

    subdirection_rows = []
    subdirection_json = []
    for label, keys in IMPLEMENTABLE_SUBDIRECTIONS:
        slots = sum(int(aggregate.get(key, 0)) for key in keys)
        speedup = slot_compression_speedup(cycles, slots)
        subdirection_rows.append(
            [
                label,
                f"{slots:,}",
                percent(speedup),
                "是" if speedup >= args.threshold else "否",
            ]
        )
        subdirection_json.append(
            {"label": label, "slots": slots, "ideal_speedup": speedup}
        )

    actual_rows = []
    actual_json = {}
    loaded_variants = {}
    for label, result_dir in variants.items():
        rows = read_rows(result_dir)
        loaded_variants[label] = rows
        comparison = compare_variant(baseline_rows, rows)
        actual_json[label] = comparison
        actual_rows.append(
            [
                label,
                f"{comparison['variant_cycles']:,}",
                f"{comparison['saved_cycles']:,}",
                percent(comparison["aggregate_speedup"]),
                percent(comparison["geomean_speedup"]),
                "是"
                if comparison["aggregate_speedup"] >= args.threshold
                and comparison["geomean_speedup"] >= args.threshold
                else "否",
            ]
        )

    shadow_rows = []
    shadow_json = {}
    for label, saved_key in (
        ("保守提前 DCache、首版消费者", "early_safe_net_saved_cycles"),
        ("激进提前 DCache、首版消费者", "early_aggressive_net_saved_cycles"),
        ("保守提前 DCache、全部消费者", "early_safe_all_net_saved_cycles"),
        ("激进提前 DCache、全部消费者", "early_aggressive_all_net_saved_cycles"),
    ):
        saved = sum(int(row.get(saved_key, 0)) for row in baseline_rows.values())
        ratios = []
        for row in baseline_rows.values():
            before = int(row["cycles"])
            after = before - int(row.get(saved_key, 0))
            ratios.append(before / after)
        aggregate_speedup = cycles / (cycles - saved) - 1.0
        geomean_speedup = geometric_mean(ratios) - 1.0
        shadow_rows.append(
            [
                label,
                f"{saved:,}",
                percent(aggregate_speedup),
                percent(geomean_speedup),
                "是"
                if aggregate_speedup >= args.threshold
                and geomean_speedup >= args.threshold
                else "否",
            ]
        )
        shadow_json[label] = {
            "saved_cycles": saved,
            "aggregate_speedup": aggregate_speedup,
            "geomean_speedup": geomean_speedup,
        }

    delayed_rows = []
    delayed_json = []
    if args.repair_variant:
        if args.repair_variant not in loaded_variants:
            raise RuntimeError("--repair-variant must name one --variant")
        rows = loaded_variants[args.repair_variant]
        for penalty in (0, 1, 2):
            projected_cycles = 0
            ratios = []
            repaired_redirects = 0
            for name, baseline in baseline_rows.items():
                variant = rows[name]
                redirects = int(variant.get("repaired_control_redirects", 0))
                before = int(baseline["cycles"])
                after = int(variant["cycles"]) + penalty * redirects
                repaired_redirects += redirects
                projected_cycles += after
                ratios.append(before / after)
            aggregate_speedup = cycles / projected_cycles - 1.0
            geomean_speedup = geometric_mean(ratios) - 1.0
            delayed_rows.append(
                [
                    str(penalty),
                    f"{repaired_redirects:,}",
                    f"{projected_cycles:,}",
                    percent(aggregate_speedup),
                    percent(geomean_speedup),
                    "是"
                    if aggregate_speedup >= args.threshold
                    and geomean_speedup >= args.threshold
                    else "否",
                ]
            )
            delayed_json.append(
                {
                    "extra_cycles_per_repaired_redirect": penalty,
                    "repaired_redirects": repaired_redirects,
                    "projected_cycles": projected_cycles,
                    "aggregate_speedup": aggregate_speedup,
                    "geomean_speedup": geomean_speedup,
                }
            )

    report = f"""# NSCSCC 超过 5% 的性能方向筛选

## 口径

- 基线覆盖 {len(baseline_rows)} 个 perf，总周期 {cycles:,}。
- 门槛同时要求总周期加速和逐程序几何平均加速不低于
  {percent(args.threshold)}；实测 RTL 方案还必须 20/20 PASS。
- `slot compression` 是乐观筛选上界：假定消除两个损失槽可减少一个周期，且不产生
  新瓶颈。达到上界不等于方案可实现；低于上界则可以直接淘汰。
- 达到 5% 至少要净省 {required_saved_cycles:,.0f} cycle，等价于理想消除
  {required_slots:,.0f} 个损失槽。

## 实际 RTL A/B

{markdown_table(
    ['方案', '候选周期', '节省周期', '聚合加速', '几何平均', '双门槛通过'],
    actual_rows,
) if actual_rows else '未提供完整 RTL 变体。'}

## repaired branch 延后一到两拍的保守敏感性

这里仅给真正携带 load-repair 的错误预测分支增加代价，不给所有分支统一加罚。

{markdown_table(
    ['每次 repaired redirect 加拍', 'repaired redirect', '估算周期', '聚合加速', '几何平均', '双门槛通过'],
    delayed_rows,
) if delayed_rows else '未指定 repair 变体。'}

## 提前 DCache 影子模型

{markdown_table(
    ['影子方案', '净省 cycle', '聚合加速', '几何平均', '双门槛通过'],
    shadow_rows,
)}

## 顶层方向的乐观上界

{markdown_table(['方向', '损失 slot', '理想上界', '可能超过 5%'], ideal_rows)}

## 可实施子方向的乐观上界

{markdown_table(
    ['子方向', '可覆盖 slot', '理想上界', '可能超过 5%'],
    subdirection_rows,
)}

## 功能淘汰项

“预测跳转 + FQ 中已有目标指令”曾做真实 RTL A/B。16 个程序完成并有正收益，
但 `dhrystone`、`coremark`、`stringsearch`、`fireye_C0` 进入错误执行，未能完成；
因此不能把部分程序数据计作有效性能结果。要继续该方向，必须重新设计非连续 Slot 1
的 flush、异常与提交语义，而不是只放开 `contiguous/pred_taken` 配对门禁。
"""

    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "report.md").write_text(report)
    payload = {
        "threshold": args.threshold,
        "baseline": str(args.baseline.resolve()),
        "cycles": cycles,
        "required_saved_cycles": required_saved_cycles,
        "required_slots": required_slots,
        "actual_variants": actual_json,
        "delayed_repair": delayed_json,
        "shadow_models": shadow_json,
        "ideal_classes": ideal_json,
        "subdirections": subdirection_json,
    }
    (args.output_dir / "results.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    )
    print(args.output_dir / "report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
