#!/usr/bin/env python3
"""Generate Stage-1 frontend prediction diagnostics from perf summaries."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any


BRANCH_COLUMNS = [
    "suite",
    "test",
    "status",
    "cycles",
    "total_branch",
    "mispredicts",
    "accuracy_pct",
    "mispredict_rate_pct",
    "jcall_redirects",
    "cpi_stack_redirect",
    "cpi_redirect_pct",
    "abtb_direct_lookup",
    "abtb_direct_steer",
    "abtb_direct_bank0",
    "abtb_direct_bank1",
    "abtb_direct_correct",
    "abtb_direct_redirect",
    "abtb_direct_target_miss",
    "stage1_sequential",
    "stage1_abtb_owned",
    "stage1_branch_owned_nt",
    "stage1_pht_confirmed",
    "stage1_pht_abtb_branch_hit",
    "stage1_pht_pred_taken",
    "stage1_pht_pred_not_taken",
    "stage1_pht_correct",
    "stage1_pht_wrong",
    "stage1_pht_bank0",
    "stage1_pht_bank1",
    "pred_s0_resolved",
    "pred_s0_branch",
    "pred_s0_jal",
    "pred_s0_jalr",
    "pred_s0_pred_taken",
    "pred_s0_actual_taken",
    "pred_s0_mispredict",
    "pred_s0_dir_to_taken",
    "pred_s0_dir_to_fallthrough",
    "pred_s0_target_wrong",
    "s0_pred_taken_rate_pct",
    "s0_actual_taken_rate_pct",
    "s0_taken_gap_pct",
    "s0_dir_to_taken_pct",
    "s0_dir_to_fallthrough_pct",
    "s0_target_wrong_pct",
    "pred_s1_resolved",
    "pred_s1_branch",
    "pred_s1_jal",
    "pred_s1_pred_taken",
    "pred_s1_actual_taken",
    "pred_s1_dir_wrong",
    "pred_s1_target_wrong",
    "pred_s1_redirect",
    "s1_pred_taken_rate_pct",
    "s1_actual_taken_rate_pct",
    "s1_dir_wrong_rate_pct",
    "pred_train_total",
    "pred_train_s0",
    "pred_train_s1",
    "pred_train_branch",
    "pred_train_jal",
    "pred_train_jalr",
    "train_coverage_pct",
    "stage1_pht_update_per_branch",
    "fe_bp0_fire",
    "fe_bp0_ftq_full",
    "fe_bp0_fq_credit_block",
    "fe_redirect_total",
    "fe_redirect_ex",
    "issue_class",
    "direction_bias",
]

COMPARE_METRICS = [
    "accuracy_pct",
    "mispredict_rate_pct",
    "s0_pred_taken_rate_pct",
    "s0_actual_taken_rate_pct",
    "s0_taken_gap_pct",
    "s0_dir_to_taken_pct",
    "s0_dir_to_fallthrough_pct",
    "s0_target_wrong_pct",
    "s1_dir_wrong_rate_pct",
    "train_coverage_pct",
    "cpi_redirect_pct",
]


def as_float(row: dict[str, Any], key: str, default: float = 0.0) -> float:
    value = row.get(key)
    if value in (None, ""):
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def pct(num: float, den: float) -> float:
    return 100.0 * num / den if den else 0.0


def ratio(num: float, den: float) -> float:
    return num / den if den else 0.0


def fmt(value: Any) -> str:
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def resolve_summary(path: Path) -> Path:
    if path.is_dir():
        candidates = [
            path / "summary.json",
            path / "summary.csv",
            path / "rv32ui" / "summary.json",
            path / "rv32ui" / "summary.csv",
            path / "coe" / "summary.json",
            path / "coe" / "summary.csv",
        ]
        for candidate in candidates:
            if candidate.exists():
                return candidate
    if path.exists():
        return path
    raise FileNotFoundError(f"summary not found: {path}")


def read_rows(path: Path, suite: str) -> list[dict[str, Any]]:
    path = resolve_summary(path)
    if path.suffix == ".json":
        rows = json.loads(path.read_text(encoding="utf-8"))
    elif path.suffix == ".csv":
        with path.open("r", newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    else:
        raise ValueError(f"unsupported summary format: {path}")

    out: list[dict[str, Any]] = []
    for row in rows:
        item = dict(row)
        item["suite"] = suite
        out.append(item)
    return out


def parse_input_specs(values: list[str]) -> list[tuple[str, Path]]:
    specs: list[tuple[str, Path]] = []
    for idx, value in enumerate(values):
        if "=" in value:
            suite, raw_path = value.split("=", 1)
            suite = suite.strip() or f"run{idx}"
        else:
            raw_path = value
            suite = Path(value).name or f"run{idx}"
        specs.append((suite, Path(raw_path)))
    return specs


def classify(row: dict[str, Any]) -> tuple[str, str]:
    status = str(row.get("status", "UNKNOWN"))
    if status not in {"PASS", "DONE"}:
        return "run_status", "n/a"

    total = as_float(row, "total_branch")
    if total == 0:
        return "no_branch_activity", "n/a"

    target = as_float(row, "s0_target_wrong_pct")
    gap = as_float(row, "s0_taken_gap_pct")
    train = as_float(row, "train_coverage_pct")
    pht_per_branch = as_float(row, "stage1_pht_update_per_branch")
    s1_dir = as_float(row, "s1_dir_wrong_rate_pct")
    s1_branch = as_float(row, "pred_s1_branch")
    mispredict = as_float(row, "mispredict_rate_pct")
    dir_to_taken = as_float(row, "s0_dir_to_taken_pct")
    dir_to_fallthrough = as_float(row, "s0_dir_to_fallthrough_pct")

    if gap > 10.0:
        bias = "actual_taken_gt_pred_taken"
    elif gap < -10.0:
        bias = "pred_taken_gt_actual_taken"
    else:
        bias = "balanced"

    if mispredict < 5.0:
        return "ok_or_warmup_only", bias
    if target > 10.0:
        return "target_or_jalr_fallthrough", bias
    if s1_branch > 0 and s1_dir > 25.0 and s1_dir >= dir_to_taken:
        return "slot1_direction_or_training", bias
    if target < 5.0 and abs(gap) > 20.0:
        if gap > 0:
            return "direction_underpredict_taken", bias
        return "direction_overpredict_taken", bias
    if dir_to_taken > 60.0:
        return "direction_underpredict_taken", bias
    if dir_to_fallthrough > 60.0:
        return "direction_overpredict_taken", bias
    if train < 80.0 or pht_per_branch < 0.90:
        return "training_coverage_or_update_gate", bias
    return "mixed_or_needs_trace", bias


def derive(row: dict[str, Any]) -> dict[str, Any]:
    s0_resolved = as_float(row, "pred_s0_resolved")
    if s0_resolved == 0:
        s0_resolved = as_float(row, "total_branch")

    total_branch = as_float(row, "total_branch")
    mispredicts = as_float(row, "mispredicts")
    s0_miss = as_float(row, "pred_s0_mispredict")
    if s0_miss == 0:
        s0_miss = mispredicts

    s1_branch = as_float(row, "pred_s1_branch")
    s1_resolved = as_float(row, "pred_s1_resolved")
    s1_den = s1_branch or s1_resolved

    train_total = as_float(row, "pred_train_total")
    train_branch = as_float(row, "pred_train_branch")
    resolved_total = as_float(row, "pred_s0_resolved") + as_float(row, "pred_s1_resolved")

    out = dict(row)
    out["cycles"] = int(as_float(row, "cycles"))
    out["total_branch"] = int(total_branch)
    out["mispredicts"] = int(mispredicts)
    out["accuracy_pct"] = 100.0 - pct(mispredicts, total_branch)
    out["mispredict_rate_pct"] = as_float(row, "mispredict_rate_pct", pct(mispredicts, total_branch))
    out["s0_pred_taken_rate_pct"] = pct(as_float(row, "pred_s0_pred_taken"), s0_resolved)
    out["s0_actual_taken_rate_pct"] = pct(as_float(row, "pred_s0_actual_taken"), s0_resolved)
    out["s0_taken_gap_pct"] = out["s0_actual_taken_rate_pct"] - out["s0_pred_taken_rate_pct"]
    out["s0_dir_to_taken_pct"] = pct(as_float(row, "pred_s0_dir_to_taken"), s0_miss)
    out["s0_dir_to_fallthrough_pct"] = pct(as_float(row, "pred_s0_dir_to_fallthrough"), s0_miss)
    out["s0_target_wrong_pct"] = pct(as_float(row, "pred_s0_target_wrong"), s0_miss)
    out["s1_pred_taken_rate_pct"] = pct(as_float(row, "pred_s1_pred_taken"), s1_den)
    out["s1_actual_taken_rate_pct"] = pct(as_float(row, "pred_s1_actual_taken"), s1_den)
    out["s1_dir_wrong_rate_pct"] = pct(as_float(row, "pred_s1_dir_wrong"), s1_den)
    out["train_coverage_pct"] = pct(train_total, resolved_total)
    out["stage1_pht_update_per_branch"] = ratio(
        as_float(row, "stage1_pht_confirmed"), train_branch
    )
    out["cpi_redirect_pct"] = pct(as_float(row, "cpi_stack_redirect"), as_float(row, "cycles"))
    out["issue_class"], out["direction_bias"] = classify(out)
    return out


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in columns})


def markdown_report(path: Path, rows: list[dict[str, Any]], inputs: list[tuple[str, Path]]) -> None:
    suspicious = sorted(
        rows,
        key=lambda item: (
            str(item.get("issue_class")) in {"ok_or_warmup_only", "no_branch_activity"},
            -as_float(item, "mispredict_rate_pct"),
        ),
    )

    classes: dict[str, list[str]] = {}
    for row in rows:
        classes.setdefault(str(row.get("issue_class")), []).append(str(row.get("test")))

    lines = [
        "# Stage-1 Frontend Prediction Diagnosis",
        "",
        "## Inputs",
        "",
    ]
    for suite, summary in inputs:
        lines.append(f"- `{suite}`: `{resolve_summary(summary)}`")

    lines += [
        "",
        "## Top Rows",
        "",
        "| suite | test | status | branches | acc% | predT% | actualT% | target-wrong% | train% | redirect-cycle% | class |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in suspicious[:20]:
        lines.append(
            "| {suite} | {test} | {status} | {branches} | {acc} | {pred} | {actual} | {target} | {train} | {redirect} | {klass} |".format(
                suite=row.get("suite", ""),
                test=row.get("test", ""),
                status=row.get("status", ""),
                branches=row.get("total_branch", 0),
                acc=fmt(row.get("accuracy_pct", 0.0)),
                pred=fmt(row.get("s0_pred_taken_rate_pct", 0.0)),
                actual=fmt(row.get("s0_actual_taken_rate_pct", 0.0)),
                target=fmt(row.get("s0_target_wrong_pct", 0.0)),
                train=fmt(row.get("train_coverage_pct", 0.0)),
                redirect=fmt(row.get("cpi_redirect_pct", 0.0)),
                klass=row.get("issue_class", ""),
            )
        )

    lines += [
        "",
        "## Class Buckets",
        "",
    ]
    for klass, tests in sorted(classes.items()):
        lines.append(f"- `{klass}`: {', '.join(tests)}")

    lines += [
        "",
        "## Reading Guide",
        "",
        "- High BTB hit, low target miss, and large positive taken gap points at direction underprediction.",
        "- Low BTB hit after warmup points at BTB allocation, aliasing, or capacity pressure.",
        "- High target miss with decent direction points at target/RAS/JALR metadata.",
        "- Low train coverage or low PHT writes per branch points at update gating or wrong-path filtering.",
        "- Slot1 direction rows need slot1-specific trace because aggregate S0 counters can look healthy.",
    ]

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_compare(path: Path, baseline: list[dict[str, Any]], current: list[dict[str, Any]]) -> None:
    old_by_test = {str(row.get("test")): row for row in baseline}
    rows: list[dict[str, Any]] = []
    for row in current:
        test = str(row.get("test"))
        old = old_by_test.get(test)
        if old is None:
            continue
        out: dict[str, Any] = {
            "test": test,
            "old_status": old.get("status", ""),
            "new_status": row.get("status", ""),
            "old_issue_class": old.get("issue_class", ""),
            "new_issue_class": row.get("issue_class", ""),
        }
        for metric in COMPARE_METRICS:
            old_val = as_float(old, metric)
            new_val = as_float(row, metric)
            out[f"old_{metric}"] = old_val
            out[f"new_{metric}"] = new_val
            out[f"{metric}_delta"] = new_val - old_val
        rows.append(out)

    columns = ["test", "old_status", "new_status", "old_issue_class", "new_issue_class"]
    for metric in COMPARE_METRICS:
        columns += [f"old_{metric}", f"new_{metric}", f"{metric}_delta"]
    write_csv(path, rows, columns)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--summary",
        action="append",
        default=[],
        help="summary path or suite=summary path. May be repeated.",
    )
    parser.add_argument(
        "--run-dir",
        action="append",
        default=[],
        help="run directory containing summary.json/csv. May be repeated.",
    )
    parser.add_argument("--baseline", help="baseline run dir or summary for branch_compare.csv")
    parser.add_argument("--out", required=True, help="output directory for branch diagnostic files")
    args = parser.parse_args()

    specs = parse_input_specs(args.summary + args.run_dir)
    if not specs:
        raise SystemExit("ERROR: provide at least one --summary or --run-dir")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    rows: list[dict[str, Any]] = []
    for suite, summary in specs:
        rows.extend(derive(row) for row in read_rows(summary, suite))
    rows.sort(key=lambda item: (str(item.get("suite", "")), str(item.get("test", ""))))

    write_csv(out_dir / "branch_summary.csv", rows, BRANCH_COLUMNS)
    projected_rows = [
        {column: row.get(column, "") for column in BRANCH_COLUMNS}
        for row in rows
    ]
    with (out_dir / "branch_summary.json").open("w", encoding="utf-8") as handle:
        json.dump(projected_rows, handle, indent=2, sort_keys=True)
        handle.write("\n")
    markdown_report(out_dir / "branch_findings.md", rows, specs)

    if args.baseline:
        baseline_rows = [derive(row) for row in read_rows(Path(args.baseline), "baseline")]
        write_compare(out_dir / "branch_compare.csv", baseline_rows, rows)

    class_counts: dict[str, int] = {}
    for row in rows:
        klass = str(row.get("issue_class", "unknown"))
        class_counts[klass] = class_counts.get(klass, 0) + 1
    print("[INFO] Branch diag:", ", ".join(f"{k}={v}" for k, v in sorted(class_counts.items())))
    print(f"[INFO] Branch summary: {out_dir / 'branch_summary.csv'}")
    print(f"[INFO] Branch findings: {out_dir / 'branch_findings.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
