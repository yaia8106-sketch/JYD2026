#!/usr/bin/env python3
"""
Profile report writer.

Responsible for:
- writing coverage-style latest profile_report.json, .md, and .csv files;
- embedding run_config, enabled collectors, per-test rows, and self-check data;
- keeping output formatting separate from simulation and collector code.

Not responsible for:
- running simulations;
- parsing raw simulator logs;
- defining test stop conditions.

Inputs:
- run configuration dictionary;
- enabled collector names;
- per-test summary dictionaries.

Outputs:
- 03_Analysis/profile_report.json
- 03_Analysis/profile_report.md
- 03_Analysis/profile_report.csv

Dependencies:
- common/schema.py for schema version and self-checks.

Common extension point:
- add new report tables here after a collector has a stable output shape.
"""

from __future__ import annotations

import csv
import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Iterable, List

from common.schema import SCHEMA_VERSION, build_self_check


CSV_FIELDS = [
    "name",
    "irom_mode",
    "status",
    "stop_reason",
    "expected_stop_reason",
    "cycles",
    "total_commits",
    "s0_commits",
    "s1_commits",
    "cpi",
    "dual_issue_percent",
    "pc",
    "last_wb0_pc",
    "last_wb1_pc",
    "if_accepts",
    "s1_accepted",
    "s1_blocked_total",
    "branch_mispredicts",
    "dcache_stall_cycles",
    "muldiv_wait_cycles",
    "log_file",
]


def build_profile(
    *,
    run_config: Dict[str, Any],
    enabled_collectors: Iterable[str],
    tests: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Assemble the stable top-level profile dictionary."""
    profile: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "run_config": run_config,
        "enabled_collectors": list(enabled_collectors),
        "tests": tests,
        "summary": {"test_count": len(tests)},
        "issue": {},
        "stall": {},
        "raw": {},
        "branch": {},
        "memory": {},
        "muldiv": {},
    }
    profile["self_check"] = build_self_check(profile)
    return profile


def write_reports(profile: Dict[str, Any], analysis_dir: Path) -> None:
    """Write JSON, CSV, and Markdown reports using fixed latest filenames."""
    analysis_dir.mkdir(parents=True, exist_ok=True)
    json_path = analysis_dir / "profile_report.json"
    csv_path = analysis_dir / "profile_report.csv"
    md_path = analysis_dir / "profile_report.md"

    json_path.write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n")
    _write_csv(profile["tests"], csv_path)
    md_path.write_text(_format_markdown(profile))


def _write_csv(rows: List[Dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def _fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def _format_markdown(profile: Dict[str, Any]) -> str:
    lines: List[str] = []
    run_config = profile.get("run_config", {})
    self_check = profile.get("self_check", {})

    lines.append("# CPU Profile Report")
    lines.append("")
    lines.append("<!-- Coverage-style generated report. Do not edit by hand. -->")
    lines.append("")
    lines.append(f"- Generated at: `{profile.get('generated_at')}`")
    lines.append(f"- Schema version: `{profile.get('schema_version')}`")
    lines.append(f"- Simulator: `{run_config.get('simulator')}`")
    lines.append(f"- Jobs: `{run_config.get('jobs')}`")
    lines.append(f"- Collectors: `{', '.join(profile.get('enabled_collectors', []))}`")
    lines.append(f"- Self-check: `{self_check.get('status')}`")
    lines.append("")

    warnings = self_check.get("warnings") or []
    errors = self_check.get("errors") or []
    if warnings:
        lines.append("## Warnings")
        lines.extend(f"- {warning}" for warning in warnings)
        lines.append("")
    if errors:
        lines.append("## Errors")
        lines.extend(f"- {error}" for error in errors)
        lines.append("")

    lines.append("## Tests")
    lines.append("")
    lines.append(
        "| Test | IROM | Status | Stop | Expected | Cycles | Insts | CPI | Dual % | S1 blocked | Log |"
    )
    lines.append(
        "|------|------|--------|------|----------|-------:|------:|----:|-------:|-----------:|-----|"
    )
    for row in profile.get("tests", []):
        lines.append(
            "| {name} | {irom_mode} | {status} | {stop} | {expected} | {cycles} | {insts} | {cpi} | {dual} | {blocked} | `{log}` |".format(
                name=row.get("name"),
                irom_mode=row.get("irom_mode"),
                status=row.get("status"),
                stop=row.get("stop_reason"),
                expected=row.get("expected_stop_reason"),
                cycles=_fmt(row.get("cycles")),
                insts=_fmt(row.get("total_commits")),
                cpi=_fmt(row.get("cpi")),
                dual=_fmt(row.get("dual_issue_percent")),
                blocked=_fmt(row.get("s1_blocked_total")),
                log=row.get("log_file"),
            )
        )
    lines.append("")
    return "\n".join(lines)
