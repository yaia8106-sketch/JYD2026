#!/usr/bin/env python3
"""Replay RTL DCache accesses across the first-round cache configurations."""

from __future__ import annotations

import argparse
import csv
import json
import math
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Config:
    name: str
    capacity_bytes: int
    ways: int
    line_bytes: int

    @property
    def lines(self) -> int:
        return self.capacity_bytes // self.line_bytes

    @property
    def sets(self) -> int:
        return self.lines // self.ways

    @property
    def line_words(self) -> int:
        return self.line_bytes // 4


CONFIGS = (
    Config("32k_2way_32b", 32 * 1024, 2, 32),
    Config("32k_1way_32b", 32 * 1024, 1, 32),
    Config("32k_2way_64b", 32 * 1024, 2, 64),
    Config("64k_1way_32b", 64 * 1024, 1, 32),
    Config("64k_2way_32b", 64 * 1024, 2, 32),
    Config("128k_2way_32b", 128 * 1024, 2, 32),
)
BASELINE = CONFIGS[0]


class CacheModel:
    """Write-back, write-allocate cache with exact LRU replacement."""

    COUNTERS = (
        "accesses",
        "loads",
        "stores",
        "hits",
        "misses",
        "load_hits",
        "load_misses",
        "store_hits",
        "store_misses",
        "compulsory",
        "conflict",
        "capacity",
        "dirty_evictions",
    )

    def __init__(self, config: Config) -> None:
        self.config = config
        # OrderedDict order is LRU -> MRU; values are dirty bits.
        self.entries: list[OrderedDict[int, bool]] = [
            OrderedDict() for _ in range(config.sets)
        ]
        self.fa: OrderedDict[int, None] = OrderedDict()
        self.seen: set[int] = set()
        for counter in self.COUNTERS:
            setattr(self, counter, 0)

    @staticmethod
    def touch_fa(entries: OrderedDict[int, None], line: int, limit: int) -> None:
        if line in entries:
            entries.move_to_end(line)
            return
        if len(entries) == limit:
            entries.popitem(last=False)
        entries[line] = None

    def access(self, address: int, write: bool, measured: bool) -> None:
        line = address // self.config.line_bytes
        index = line % self.config.sets
        tag = line // self.config.sets
        cache_set = self.entries[index]
        hit = tag in cache_set
        fa_hit = line in self.fa
        first = line not in self.seen
        dirty_eviction = False

        if hit:
            dirty = cache_set.pop(tag)
            cache_set[tag] = dirty or write
        else:
            if len(cache_set) == self.config.ways:
                _, dirty_eviction = cache_set.popitem(last=False)
            cache_set[tag] = write

        self.touch_fa(self.fa, line, self.config.lines)
        self.seen.add(line)

        if not measured:
            return
        self.accesses += 1
        self.stores += int(write)
        self.loads += int(not write)
        if hit:
            self.hits += 1
            if write:
                self.store_hits += 1
            else:
                self.load_hits += 1
            return

        self.misses += 1
        if write:
            self.store_misses += 1
        else:
            self.load_misses += 1
        self.dirty_evictions += int(dirty_eviction)
        if first:
            self.compulsory += 1
        elif fa_hit:
            self.conflict += 1
        else:
            self.capacity += 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "results_dir",
        type=Path,
        help="run_rtl_perf_profile.py output made with --dump-dcache-trace",
    )
    parser.add_argument("--output-dir", type=Path)
    return parser.parse_args()


def load_rtl_rows(path: Path) -> dict[str, dict[str, str]]:
    with path.open() as stream:
        return {row["benchmark"]: row for row in csv.DictReader(stream)}


def safe_ratio(numerator: float, denominator: float) -> float:
    return numerator / denominator if denominator else 0.0


def geomean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def model_trace(trace: Path) -> dict[str, CacheModel]:
    models = {config.name: CacheModel(config) for config in CONFIGS}
    with trace.open() as stream:
        for line_number, text in enumerate(stream, 1):
            fields = text.split()
            if len(fields) != 3:
                raise ValueError(f"{trace}:{line_number}: malformed trace line")
            active_text, write_text, address_text = fields
            measured = active_text == "1"
            write = write_text == "1"
            address = int(address_text, 16)
            for model in models.values():
                model.access(address, write, measured)
    return models


def main() -> int:
    args = parse_args()
    source = args.results_dir.resolve()
    output = (args.output_dir or source / "software_dcache_model").resolve()
    output.mkdir(parents=True, exist_ok=True)

    rtl_csv = source / "rtl_perf_profile.csv"
    if not rtl_csv.is_file():
        raise SystemExit(f"missing {rtl_csv}")
    rtl_rows = load_rtl_rows(rtl_csv)
    trace_files = sorted((source / "work").glob("*/dcache.trace"))
    if not trace_files:
        raise SystemExit(f"no work/*/dcache.trace beneath {source}")

    per_program_models: dict[str, dict[str, CacheModel]] = {}
    for trace in trace_files:
        benchmark = trace.parent.name
        if benchmark not in rtl_rows:
            raise RuntimeError(f"trace has no matching RTL row: {benchmark}")
        per_program_models[benchmark] = model_trace(trace)
    missing = sorted(set(rtl_rows) - set(per_program_models))
    if missing:
        raise RuntimeError(f"missing DCache traces: {', '.join(missing)}")

    # Calibrate the analytical cycle estimate per benchmark against the
    # measured RTL baseline.  Model miss ratios select the counterfactual
    # request count; measured root-cause cycles preserve the actual pipeline
    # and fixed-DDR penalty.  A wider line adds one cycle per extra AXI beat.
    per_program_rows: list[dict[str, object]] = []
    total_rtl_cycles = sum(int(row["cycles"]) for row in rtl_rows.values())
    for benchmark, rtl in rtl_rows.items():
        baseline = per_program_models[benchmark][BASELINE.name]
        rtl_refills = int(rtl["dcache_refill_requests"])
        rtl_dirty = int(rtl["dcache_dirty_victims"])
        rtl_refill_cycles = int(rtl["root_mem_dcache_refill"])
        rtl_writeback_cycles = int(rtl["root_mem_dcache_writeback"])
        refill_cost = safe_ratio(rtl_refill_cycles, rtl_refills)
        dirty_cost = safe_ratio(rtl_writeback_cycles, rtl_dirty)

        for config in CONFIGS:
            model = per_program_models[benchmark][config.name]
            miss_scale = (
                safe_ratio(model.misses, baseline.misses)
                if baseline.misses else 0.0
            )
            dirty_scale = (
                safe_ratio(model.dirty_evictions, baseline.dirty_evictions)
                if baseline.dirty_evictions else 0.0
            )
            estimated_refills = rtl_refills * miss_scale
            estimated_dirty = rtl_dirty * dirty_scale
            extra_beats = config.line_words - BASELINE.line_words
            estimated_refill_root = estimated_refills * (
                refill_cost + extra_beats
            )
            estimated_writeback_root = estimated_dirty * (
                dirty_cost + max(0, extra_beats)
            )
            estimated_cycles = (
                int(rtl["cycles"])
                - rtl_refill_cycles
                - rtl_writeback_cycles
                + estimated_refill_root
                + estimated_writeback_root
            )
            per_program_rows.append(
                {
                    "benchmark": benchmark,
                    "config": config.name,
                    "cache_bytes": config.capacity_bytes,
                    "ways": config.ways,
                    "line_bytes": config.line_bytes,
                    **{
                        counter: getattr(model, counter)
                        for counter in CacheModel.COUNTERS
                    },
                    "miss_rate": safe_ratio(model.misses, model.accesses),
                    "rtl_cycles": int(rtl["cycles"]),
                    "rtl_refills": rtl_refills,
                    "rtl_dirty_victims": rtl_dirty,
                    "rtl_refill_root_cycles": rtl_refill_cycles,
                    "rtl_writeback_root_cycles": rtl_writeback_cycles,
                    "estimated_refills": estimated_refills,
                    "estimated_dirty_victims": estimated_dirty,
                    "estimated_refill_root_cycles": estimated_refill_root,
                    "estimated_writeback_root_cycles": estimated_writeback_root,
                    "estimated_cycles": estimated_cycles,
                    "estimated_speedup": safe_ratio(
                        int(rtl["cycles"]), estimated_cycles
                    ),
                }
            )

    fields = list(per_program_rows[0])
    with (output / "per_program.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(per_program_rows)

    summary_rows: list[dict[str, object]] = []
    for config in CONFIGS:
        rows = [row for row in per_program_rows if row["config"] == config.name]
        baseline_rows = [
            row for row in per_program_rows if row["config"] == BASELINE.name
        ]
        misses = sum(int(row["misses"]) for row in rows)
        baseline_misses = sum(int(row["misses"]) for row in baseline_rows)
        estimated_cycles = sum(float(row["estimated_cycles"]) for row in rows)
        estimated_refill_root = sum(
            float(row["estimated_refill_root_cycles"]) for row in rows
        )
        summary_rows.append(
            {
                "config": config.name,
                "cache_bytes": config.capacity_bytes,
                "ways": config.ways,
                "line_bytes": config.line_bytes,
                "sets": config.sets,
                "accesses": sum(int(row["accesses"]) for row in rows),
                "misses": misses,
                "miss_rate": safe_ratio(
                    misses, sum(int(row["accesses"]) for row in rows)
                ),
                "misses_removed": baseline_misses - misses,
                "miss_reduction": safe_ratio(
                    baseline_misses - misses, baseline_misses
                ),
                "compulsory": sum(int(row["compulsory"]) for row in rows),
                "conflict": sum(int(row["conflict"]) for row in rows),
                "capacity": sum(int(row["capacity"]) for row in rows),
                "dirty_evictions": sum(
                    int(row["dirty_evictions"]) for row in rows
                ),
                "estimated_cycles": estimated_cycles,
                "estimated_aggregate_speedup": safe_ratio(
                    total_rtl_cycles, estimated_cycles
                ),
                "estimated_geomean_speedup": geomean(
                    [float(row["estimated_speedup"]) for row in rows]
                ),
                "estimated_refill_root_cycles": estimated_refill_root,
                "estimated_refill_bottleneck_share": safe_ratio(
                    estimated_refill_root, estimated_cycles
                ),
            }
        )

    baseline_rtl_misses = sum(
        int(row["dcache_load_misses"]) + int(row["dcache_store_misses"])
        for row in rtl_rows.values()
    )
    baseline_rtl_dirty = sum(
        int(row["dcache_dirty_victims"]) for row in rtl_rows.values()
    )
    summary_rows[0]["rtl_baseline_misses"] = baseline_rtl_misses
    summary_rows[0]["model_vs_rtl_miss_delta"] = (
        int(summary_rows[0]["misses"]) - baseline_rtl_misses
    )
    summary_rows[0]["rtl_baseline_dirty_victims"] = baseline_rtl_dirty
    summary_rows[0]["model_vs_rtl_dirty_delta"] = (
        int(summary_rows[0]["dirty_evictions"]) - baseline_rtl_dirty
    )

    with (output / "summary.csv").open("w", newline="") as stream:
        fields = sorted({key for row in summary_rows for key in row})
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(summary_rows)
    (output / "summary.json").write_text(
        json.dumps(summary_rows, indent=2) + "\n"
    )

    lines = [
        "# First-round trace-driven DCache study",
        "",
        "The cache model is write-back/write-allocate with exact LRU. Cycle "
        "estimates scale each benchmark's measured fixed-latency refill and "
        "writeback root-cause cycles by the modeled miss/dirty-eviction ratios. "
        "They do not model changed AXI contention or RTL timing and are therefore "
        "screening estimates, not cycle-accurate A/B results.",
        "",
        "| Configuration | Sets | Misses | Miss rate | Miss reduction | Dirty "
        "evictions | Estimated speedup | Estimated refill share |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in summary_rows:
        lines.append(
            f"| {row['config']} | {row['sets']:,} | {row['misses']:,} | "
            f"{100 * float(row['miss_rate']):.4f}% | "
            f"{100 * float(row['miss_reduction']):.2f}% | "
            f"{row['dirty_evictions']:,} | "
            f"{float(row['estimated_aggregate_speedup']):.5f}x | "
            f"{100 * float(row['estimated_refill_bottleneck_share']):.3f}% |"
        )
    lines.extend(
        [
            "",
            f"Baseline RTL misses: {baseline_rtl_misses:,}; trace-model misses: "
            f"{int(summary_rows[0]['misses']):,}. Baseline RTL dirty victims: "
            f"{baseline_rtl_dirty:,}; trace-model dirty evictions: "
            f"{int(summary_rows[0]['dirty_evictions']):,}.",
        ]
    )
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"Summary: {output / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
