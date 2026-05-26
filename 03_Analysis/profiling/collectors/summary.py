#!/usr/bin/env python3
"""
Summary collector.

Responsible for:
- extracting the stable run result and existing [PERF] summary counters;
- producing one compact dictionary per test for profile_report.json/csv/md.

Not responsible for:
- running simulations;
- deciding whether a stop condition is correct;
- computing detailed RAW/branch/memory conclusions.

Inputs:
- SimRunResult objects and their raw log files.

Outputs:
- per-test summary dictionaries consumed by reporting/report.py.

Dependencies:
- common/profile_events.py for log parsing helpers.

Common extension point:
- keep this collector limited to top-level summary fields. Put detailed issue,
  RAW, branch, memory, and muldiv metrics in separate collectors.
"""

from __future__ import annotations

from typing import Any, Dict

from common.profile_events import parse_perf_lines
from runners.sim_runner import SimRunResult


def collect(run: SimRunResult) -> Dict[str, Any]:
    """Collect basic run status and existing [PERF] counters for one test."""
    log_text = run.log_file.read_text() if run.log_file.exists() else ""
    perf = parse_perf_lines(log_text.splitlines())

    cycles = perf.get("cycles", run.cycles)
    s0_commits = perf.get("s0_commits")
    s1_commits = perf.get("s1_commits")
    total_commits = perf.get("total_commits", run.raw_result.get("total_commits"))

    row: Dict[str, Any] = {
        "name": run.test_name,
        "irom_mode": run.irom_mode,
        "status": run.status,
        "stop_reason": run.stop_reason,
        "expected_stop_reason": run.expected_stop_reason,
        "returncode": run.returncode,
        "cycles": cycles,
        "s0_commits": s0_commits,
        "s1_commits": s1_commits,
        "total_commits": total_commits,
        "cpi": perf.get("cpi"),
        "dual_issue_percent": perf.get("dual_issue_percent"),
        "log_file": str(run.log_file),
    }

    for key in (
        "if_accepts",
        "s1_accepted",
        "s1_committed",
        "s1_blocked_total",
        "load_use_stall_cycles",
        "dcache_stall_cycles",
        "muldiv_wait_cycles",
        "id_raw_stall_cycles",
        "same_pair_raw_lost_slots",
        "branch_total",
        "branch_mispredicts",
        "nlp_redirects",
    ):
        if key in perf:
            row[key] = perf[key]

    for key in (
        "stop_pc",
        "target_stop_pc",
        "first_led",
        "last_led",
        "led_writes",
        "pc",
        "last_wb0_pc",
        "last_wb1_pc",
    ):
        if key in run.raw_result:
            row[key] = run.raw_result[key]

    return row
