#!/usr/bin/env python3
"""Vivado 2023.2 OOC synthesis sweep for the ICache configurations."""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import json
import re
import subprocess
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
        description="Synthesize only the ICache; never runs implementation"
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        default=Path("/tmp/nscscc-icache-ooc-synth"),
    )
    parser.add_argument(
        "--vivado",
        type=Path,
        default=Path("/tools/Xilinx/Vivado/2023.2/bin/vivado"),
    )
    parser.add_argument("--part", default="xc7a200tfbg676-2")
    parser.add_argument("--period-ns", type=float, default=6.25)
    parser.add_argument("--jobs", type=int, default=2)
    parser.set_defaults(workspace=here.parents[5])
    return parser.parse_args()


def tcl_quote(path: Path) -> str:
    return "{" + str(path.resolve()).replace("}", "\\}") + "}"


def parse_utilization(text: str, resource: str) -> int:
    pattern = re.compile(
        rf"^\|\s*{re.escape(resource)}\s*\|\s*([0-9,]+)\s*\|",
        re.MULTILINE,
    )
    match = pattern.search(text)
    return int(match.group(1).replace(",", "")) if match else 0


def parse_slack(text: str, label: str) -> float | None:
    match = re.search(
        rf"{label}\(ns\).*?\n\s*-+.*?\n\s*(-?[0-9.]+)",
        text,
        re.DOTALL,
    )
    return float(match.group(1)) if match else None


def synthesize(
    config: tuple[str, int, int], args: argparse.Namespace, root: Path
) -> dict[str, object]:
    name, cache_bytes, ways = config
    run_dir = root / name
    run_dir.mkdir(parents=True, exist_ok=True)
    rtl = args.workspace / "core/02_Design/rtl"
    sources = [
        rtl / "common/cpu_defs.sv",
        rtl / "isa/loongarch/loongarch_defs.sv",
        rtl / "isa/loongarch/loongarch_predecode.sv",
        rtl / "memory/icache.sv",
    ]
    tcl = "\n".join(
        [
            "set_param general.maxThreads 4",
            "read_verilog -sv " + " ".join(tcl_quote(path) for path in sources),
            (
                f"synth_design -top icache -part {args.part} "
                f"-mode out_of_context -generic CACHE_BYTES={cache_bytes} "
                f"-generic WAYS={ways}"
            ),
            f"create_clock -name clk -period {args.period_ns} [get_ports clk]",
            f"report_utilization -file {tcl_quote(run_dir / 'utilization.rpt')}",
            (
                "report_timing_summary -delay_type max -max_paths 20 "
                f"-file {tcl_quote(run_dir / 'timing_summary.rpt')}"
            ),
            f"write_checkpoint -force {tcl_quote(run_dir / 'post_synth.dcp')}",
            "exit",
            "",
        ]
    )
    tcl_path = run_dir / "synth.tcl"
    tcl_path.write_text(tcl)
    log_path = run_dir / "vivado.log"
    with log_path.open("w") as log:
        completed = subprocess.run(
            [str(args.vivado), "-mode", "batch", "-source", str(tcl_path)],
            cwd=run_dir,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    if completed.returncode != 0:
        raise RuntimeError(f"{name}: Vivado failed; see {log_path}")

    util = (run_dir / "utilization.rpt").read_text(errors="replace")
    timing = (run_dir / "timing_summary.rpt").read_text(errors="replace")
    return {
        "config": name,
        "cache_bytes": cache_bytes,
        "ways": ways,
        "period_ns": args.period_ns,
        "lut": parse_utilization(util, "Slice LUTs*"),
        "ff": parse_utilization(util, "Slice Registers"),
        "ramb36": parse_utilization(util, "RAMB36/FIFO*"),
        "ramb18": parse_utilization(util, "RAMB18"),
        "wns_ns": parse_slack(timing, "WNS"),
        "whs_ns": parse_slack(timing, "WHS"),
        "run_dir": str(run_dir),
    }


def main() -> int:
    args = parse_args()
    root = args.results_dir.resolve()
    root.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {
            pool.submit(synthesize, config, args, root): config[0]
            for config in CONFIGS
        }
        for future in concurrent.futures.as_completed(futures):
            row = future.result()
            rows.append(row)
            print(
                f"[PASS] {row['config']}: LUT={row['lut']} FF={row['ff']} "
                f"RAMB36={row['ramb36']} WNS={row['wns_ns']} ns",
                flush=True,
            )
    order = {name: index for index, (name, _, _) in enumerate(CONFIGS)}
    rows.sort(key=lambda row: order[str(row["config"])])
    with (root / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (root / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
    lines = [
        "# ICache out-of-context synthesis",
        "",
        f"Generated: {datetime.now().astimezone().isoformat(timespec='seconds')}",
        "",
        "Vivado synthesis only; no implementation and no custom P&R strategy.",
        "",
        "| Configuration | LUT | FF | RAMB36 | RAMB18 | OOC WNS (ns) |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['config']} | {row['lut']} | {row['ff']} | "
            f"{row['ramb36']} | {row['ramb18']} | {row['wns_ns']} |"
        )
    (root / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"Summary: {root / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
