#!/usr/bin/env python3
"""
Profile schema helpers.

Responsible for:
- defining the profiling schema version used by generated reports;
- providing small validation helpers for runner/reporter output;
- keeping cross-cutting self-checks in one place.

Not responsible for:
- running simulations;
- parsing simulator logs;
- deciding test stop conditions;
- formatting Markdown or CSV reports.

Inputs:
- profile dictionaries assembled by run_profile.py/reporting/report.py.

Outputs:
- a self_check dictionary that can be embedded in profile_report.json.

Dependencies:
- Python standard library only.

Common extension point:
- add new cross-section consistency checks here when a stable collector field
  becomes part of profile_contract.md.
"""

from __future__ import annotations

from typing import Any, Dict, List


SCHEMA_VERSION = 1
MAX_JOBS = 16


def build_self_check(profile: Dict[str, Any]) -> Dict[str, Any]:
    """Validate stable profile invariants without interpreting collector internals."""
    errors: List[str] = []
    warnings: List[str] = []

    run_config = profile.get("run_config", {})
    jobs = int(run_config.get("jobs", 0) or 0)
    if jobs < 1:
        errors.append("run_config.jobs must be >= 1")
    if jobs > MAX_JOBS:
        errors.append(f"run_config.jobs must be <= {MAX_JOBS}")

    if profile.get("schema_version") != SCHEMA_VERSION:
        errors.append(
            f"schema_version mismatch: got {profile.get('schema_version')}, expected {SCHEMA_VERSION}"
        )

    tests = profile.get("tests", [])
    if not tests:
        errors.append("profile must contain at least one test result")

    for test in tests:
        name = test.get("name", "<unknown>")
        stop_reason = test.get("stop_reason")
        if not stop_reason:
            errors.append(f"{name}: missing stop_reason")
        elif stop_reason == "UNKNOWN":
            errors.append(f"{name}: unknown stop_reason")

        expected_stop_reason = test.get("expected_stop_reason")
        if expected_stop_reason and stop_reason != expected_stop_reason:
            errors.append(
                f"{name}: stop_reason {stop_reason} != expected {expected_stop_reason}"
            )

        cycles = int(test.get("cycles", 0) or 0)
        total_commits = int(test.get("total_commits", 0) or 0)
        if stop_reason not in {"FAIL", "PC_GUARD", "COMPILE_ERROR", "RUN_ERROR"}:
            if cycles <= 0:
                errors.append(f"{name}: cycles must be nonzero")
            if total_commits <= 0:
                warnings.append(f"{name}: total_commits is zero or unavailable")

        s0 = test.get("s0_commits")
        s1 = test.get("s1_commits")
        if s0 is not None and s1 is not None and total_commits:
            if int(s0) + int(s1) != total_commits:
                errors.append(
                    f"{name}: total_commits != s0_commits + s1_commits "
                    f"({total_commits} != {s0} + {s1})"
                )

        if int(test.get("jobs", jobs) or jobs) > MAX_JOBS:
            errors.append(f"{name}: test used more than {MAX_JOBS} jobs")

    return {
        "status": "PASS" if not errors else "INVALID_PROFILE",
        "errors": errors,
        "warnings": warnings,
    }
