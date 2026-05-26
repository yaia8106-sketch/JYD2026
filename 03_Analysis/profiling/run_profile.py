#!/usr/bin/env python3
"""
Profiling entry point.

Responsible for:
- parsing user options;
- resolving the default/current profiling tests;
- preparing COE inputs, compiling the simulator, running tests, invoking
  collectors, and writing coverage-style latest reports.

Not responsible for:
- knowing detailed metric definitions;
- duplicating stop conditions inside collectors;
- storing timestamped historical reports.

Inputs:
- command-line options such as --tests, --jobs, --max-cycles, --watchdog-cycles;
- COE files and existing RTL/testbench files from the workspace.

Outputs:
- 03_Analysis/profile_report.md
- 03_Analysis/profile_report.json
- 03_Analysis/profile_report.csv
- ignored intermediates under 03_Analysis/profiling/output/

Dependencies:
- catalog/test_catalog.py for tests and COE conversion;
- runners/sim_runner.py for compile/run;
- collectors/summary.py for the initial summary collector;
- reporting/report.py for output files.

Common extension point:
- add new collectors and let run_profile.py enable them by name. Do not add
  detailed metric parsing directly to this file.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import shutil
import sys
from pathlib import Path
from typing import Iterable, List, Optional


SCRIPT_DIR = Path(__file__).resolve().parent
ANALYSIS_DIR = SCRIPT_DIR.parent
WORKSPACE = ANALYSIS_DIR.parent
for module_dir in (SCRIPT_DIR, SCRIPT_DIR / "catalog", SCRIPT_DIR / "runners", SCRIPT_DIR / "collectors", SCRIPT_DIR / "reporting", SCRIPT_DIR / "common"):
    sys.path.insert(0, str(module_dir))

from catalog.test_catalog import prepare_test, resolve_tests  # noqa: E402
from collectors.summary import collect as collect_summary  # noqa: E402
from common.schema import MAX_JOBS  # noqa: E402
from reporting.report import build_profile, write_reports  # noqa: E402
from runners.sim_runner import IverilogRunner, VerilatorRunner  # noqa: E402


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run CPU profiling simulations.")
    parser.add_argument(
        "--tests",
        nargs="+",
        help="Test names to run. Defaults to the two latest COE programs.",
    )
    parser.add_argument(
        "--jobs",
        type=int,
        default=2,
        help=f"Maximum parallel test runs, capped at {MAX_JOBS}. Default: 2.",
    )
    parser.add_argument(
        "--max-cycles",
        type=int,
        help="Override per-test max simulation cycles.",
    )
    parser.add_argument(
        "--watchdog-cycles",
        type=int,
        help="Override per-test no-progress watchdog cycles.",
    )
    parser.add_argument(
        "--simulator",
        choices=["verilator", "iverilog"],
        default="verilator",
        help="Simulator backend. Default: verilator.",
    )
    parser.add_argument(
        "--no-perf",
        action="store_true",
        help="Run without +perf. Reports will contain only stop status.",
    )
    parser.add_argument(
        "--led-trace",
        action="store_true",
        help="Print every LED MMIO write into each raw simulator log.",
    )
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Return success even if a test does not reach its expected stop condition.",
    )
    parser.add_argument(
        "--list-tests",
        action="store_true",
        help="List available default profiling tests and exit.",
    )
    return parser.parse_args(list(argv) if argv is not None else None)


def _require_tool(name: str) -> None:
    if shutil.which(name) is None:
        raise RuntimeError(f"required tool not found in PATH: {name}")


def _run_one(runner: IverilogRunner, prepared, args: argparse.Namespace):
    run = runner.run_test(
        prepared,
        max_cycles=args.max_cycles,
        watchdog_cycles=args.watchdog_cycles,
        perf=not args.no_perf,
        led_trace=args.led_trace,
    )
    return collect_summary(run)


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = parse_args(argv)
    jobs = max(1, min(args.jobs, MAX_JOBS))

    tests = resolve_tests(WORKSPACE, args.tests)
    if args.list_tests:
        for spec in tests:
            stop = f"0x{spec.stop_pc:08x}" if spec.stop_pc is not None else "none"
            irom_mode = "banked" if spec.irom_slot0_coe is not None else "flat"
            print(f"{spec.name}\t{spec.kind}\tirom={irom_mode}\tstop_pc={stop}")
        return 0

    output_dir = SCRIPT_DIR / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    if args.simulator == "iverilog":
        _require_tool("iverilog")
        _require_tool("vvp")
    else:
        _require_tool("verilator")

    prepared_tests = [prepare_test(spec, output_dir) for spec in tests]
    if args.simulator == "iverilog":
        runner = IverilogRunner(WORKSPACE, output_dir)
    else:
        runner = VerilatorRunner(WORKSPACE, output_dir, jobs=jobs)
    runner.compile()

    rows: List[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(prepared_tests))) as pool:
        futures = [pool.submit(_run_one, runner, prepared, args) for prepared in prepared_tests]
        for future in concurrent.futures.as_completed(futures):
            rows.append(future.result())

    rows.sort(key=lambda row: row["name"])
    run_config = {
        "jobs": jobs,
        "max_cycles": args.max_cycles,
        "watchdog_cycles": args.watchdog_cycles,
        "simulator": args.simulator,
        "requested_tests": args.tests or [spec.name for spec in tests],
        "requested_collectors": ["summary"],
        "perf_enabled": not args.no_perf,
        "led_trace": args.led_trace,
    }
    profile = build_profile(
        run_config=run_config,
        enabled_collectors=["summary"],
        tests=rows,
    )
    write_reports(profile, ANALYSIS_DIR)

    incomplete = [
        row
        for row in rows
        if row.get("expected_stop_reason") and row.get("stop_reason") != row.get("expected_stop_reason")
    ]
    if incomplete and not args.allow_incomplete:
        for row in incomplete:
            print(
                f"{row.get('name')}: did not reach expected stop condition "
                f"({row.get('status')} / {row.get('stop_reason')}); log={row.get('log_file')}",
                file=sys.stderr,
            )
        return 1

    print(f"Wrote {ANALYSIS_DIR / 'profile_report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
