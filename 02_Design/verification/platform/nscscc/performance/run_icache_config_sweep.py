#!/usr/bin/env python3
"""Run and compare the NSCSCC ICache capacity/associativity points."""

from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
from datetime import datetime
from pathlib import Path


CONFIGS = (
    ("8k_1way", 8192, 1),
    ("8k_2way", 8192, 2),
    ("16k_1way", 16384, 1),
    ("16k_2way", 16384, 2),
    ("32k_1way", 32768, 1),
)


def parse_args() -> argparse.Namespace:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="RTL A/B sweep of 16-byte-line ICache configurations"
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("/tmp/nscscc-icache-config-sweep"),
    )
    parser.add_argument(
        "--read-latency",
        action="append",
        type=int,
        dest="read_latencies",
        help="repeatable fixed AR-to-first-R delay; default: 170",
    )
    parser.add_argument("--write-latency", type=int, default=60)
    parser.add_argument("--jobs", type=int, default=12)
    parser.add_argument("--build-jobs", type=int, default=16)
    parser.add_argument("--force-rebuild", action="store_true")
    parser.add_argument("--skip-existing", action="store_true")
    parser.set_defaults(runner=here / "run_rtl_perf_profile.py")
    return parser.parse_args()


def load_csv(path: Path) -> dict[str, dict[str, str]]:
    with path.open() as stream:
        return {row["benchmark"]: row for row in csv.DictReader(stream)}


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def main() -> int:
    args = parse_args()
    latencies = args.read_latencies or [170]
    if any(value <= 0 for value in latencies):
        raise SystemExit("read latency must be positive")

    root = args.results_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    results: dict[int, dict[str, tuple[dict, dict[str, dict[str, str]]]]] = {}

    for config_name, cache_bytes, ways in CONFIGS:
        for latency in latencies:
            output_dir = root / f"latency_{latency}" / config_name
            aggregate_path = output_dir / "aggregate.json"
            csv_path = output_dir / "rtl_perf_profile.csv"
            if not (args.skip_existing and aggregate_path.is_file()
                    and csv_path.is_file()):
                command = [
                    sys.executable,
                    str(args.runner),
                    "--results-dir",
                    str(output_dir),
                    "--delay-mode",
                    "fixed",
                    "--read-latency",
                    str(latency),
                    "--write-latency",
                    str(args.write_latency),
                    "--icache-bytes",
                    str(cache_bytes),
                    "--icache-ways",
                    str(ways),
                    "--jobs",
                    str(args.jobs),
                    "--build-jobs",
                    str(args.build_jobs),
                ]
                if args.force_rebuild:
                    command.append("--force-rebuild")
                print(
                    f"\n=== {config_name}: read latency {latency} ===",
                    flush=True,
                )
                subprocess.run(command, check=True)
            aggregate = json.loads(aggregate_path.read_text())
            rows = load_csv(csv_path)
            results.setdefault(latency, {})[config_name] = (aggregate, rows)

    summary_rows: list[dict[str, object]] = []
    for latency in latencies:
        baseline_aggregate, baseline_rows = results[latency]["8k_1way"]
        baseline_cycles = int(baseline_aggregate["cycles"])
        for config_name, cache_bytes, ways in CONFIGS:
            aggregate, rows = results[latency][config_name]
            for benchmark, baseline in baseline_rows.items():
                current = rows[benchmark]
                if current["instructions"] != baseline["instructions"]:
                    raise RuntimeError(
                        f"{config_name}/{benchmark}: committed instruction "
                        "count differs from baseline"
                    )
            speedups = [
                int(baseline_rows[name]["cycles"]) / int(row["cycles"])
                for name, row in rows.items()
            ]
            cycles = int(aggregate["cycles"])
            summary_rows.append(
                {
                    "read_latency": latency,
                    "config": config_name,
                    "cache_bytes": cache_bytes,
                    "ways": ways,
                    "cycles": cycles,
                    "instructions": int(aggregate["instructions"]),
                    "ipc": float(aggregate["ipc"]),
                    "aggregate_speedup": baseline_cycles / cycles,
                    "geomean_speedup": geomean(speedups),
                    "icache_requests": int(
                        aggregate.get("icache_requests", 0)
                    ),
                    "icache_misses": int(aggregate.get("icache_misses", 0)),
                    "icache_refill_requests": int(
                        aggregate.get("icache_refill_requests", 0)
                    ),
                    "icache_compulsory_refill_requests": int(
                        aggregate.get("icache_compulsory_refill_requests", 0)
                    ),
                    "icache_conflict_refill_requests": int(
                        aggregate.get("icache_conflict_refill_requests", 0)
                    ),
                    "icache_capacity_refill_requests": int(
                        aggregate.get("icache_capacity_refill_requests", 0)
                    ),
                    "icache_refill_slots": int(
                        aggregate.get("l4_fetch_icache_refill_slots", 0)
                    ),
                    "i_first_latency_avg": float(
                        aggregate.get("i_first_latency_avg", 0.0)
                    ),
                    "both_read_outstanding_cycles": int(
                        aggregate.get("axi_both_read_outstanding_cycles", 0)
                    ),
                }
            )

    fields = list(summary_rows[0])
    with (root / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(summary_rows)
    (root / "summary.json").write_text(
        json.dumps(summary_rows, indent=2) + "\n"
    )

    lines = [
        "# ICache RTL configuration sweep",
        "",
        f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        "All configurations retain a 16-byte line, one-cycle hit response, "
        "one miss owner and four-beat critical-first WRAP refill.",
        "",
        "| R latency | Configuration | Cycles | IPC | Aggregate speedup | "
        "Geomean speedup | Refill requests | Conflict | Capacity |",
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summary_rows:
        lines.append(
            f"| {row['read_latency']} | {row['config']} | "
            f"{row['cycles']:,} | {row['ipc']:.5f} | "
            f"{row['aggregate_speedup']:.5f}x | "
            f"{row['geomean_speedup']:.5f}x | "
            f"{row['icache_refill_requests']:,} | "
            f"{row['icache_conflict_refill_requests']:,} | "
            f"{row['icache_capacity_refill_requests']:,} |"
        )
    lines.extend(
        [
            "",
            "The speedups are measured RTL A/B results. The 3C columns come "
            "from the cycle-accurate monitor's fully-associative LRU shadow "
            "model and are explanatory rather than an IPC estimate.",
        ]
    )
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"\nSummary: {root / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
