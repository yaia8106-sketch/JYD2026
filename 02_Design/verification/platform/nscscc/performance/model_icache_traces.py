#!/usr/bin/env python3
"""Explain RTL ICache results with a simple trace-driven LRU cache model."""

from __future__ import annotations

import argparse
import csv
import json
from collections import OrderedDict
from pathlib import Path


CONFIGS = (
    ("8k_1way", 8192, 1),
    ("8k_2way", 8192, 2),
    ("16k_1way", 16384, 1),
    ("16k_2way", 16384, 2),
    ("32k_1way", 32768, 1),
)


class CacheModel:
    def __init__(self, capacity_bytes: int, ways: int) -> None:
        self.lines = capacity_bytes // 16
        self.ways = ways
        self.sets = self.lines // ways
        self.entries = [OrderedDict() for _ in range(self.sets)]
        self.fa = OrderedDict()
        self.seen: set[int] = set()
        self.accesses = 0
        self.hits = 0
        self.misses = 0
        self.compulsory = 0
        self.conflict = 0
        self.capacity = 0

    @staticmethod
    def touch(entries: OrderedDict[int, None], key: int, limit: int) -> bool:
        hit = key in entries
        if hit:
            entries.move_to_end(key)
        else:
            if len(entries) == limit:
                entries.popitem(last=False)
            entries[key] = None
        return hit

    def access(self, line: int, measured: bool) -> None:
        index = line % self.sets
        tag = line // self.sets
        way_hit = tag in self.entries[index]
        fa_hit = line in self.fa
        first = line not in self.seen

        self.touch(self.entries[index], tag, self.ways)
        self.touch(self.fa, line, self.lines)
        self.seen.add(line)

        if not measured:
            return
        self.accesses += 1
        if way_hit:
            self.hits += 1
            return
        self.misses += 1
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
        help="run_rtl_perf_profile.py output made with --dump-icache-trace",
    )
    parser.add_argument("--output-dir", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source = args.results_dir.resolve()
    output = (args.output_dir or (source / "software_icache_model")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    trace_files = sorted((source / "work").glob("*/icache.trace"))
    if not trace_files:
        raise SystemExit(f"no work/*/icache.trace beneath {source}")
    counter_names = (
        "accesses", "hits", "misses", "compulsory", "conflict", "capacity"
    )
    totals = {
        name: {counter: 0 for counter in counter_names}
        for name, _, _ in CONFIGS
    }
    for trace in trace_files:
        # Each benchmark runs after an independent SoC reset, so its Cache,
        # first-touch set and fully-associative shadow must also start empty.
        models = {
            name: CacheModel(capacity_bytes, ways)
            for name, capacity_bytes, ways in CONFIGS
        }
        with trace.open() as stream:
            for line in stream:
                active_text, address_text = line.split()
                active = active_text == "1"
                line_address = int(address_text, 16)
                for model in models.values():
                    model.access(line_address, active)
        for name, model in models.items():
            for counter in counter_names:
                totals[name][counter] += getattr(model, counter)

    rows = []
    for name, capacity_bytes, ways in CONFIGS:
        counters = totals[name]
        rows.append(
            {
                "config": name,
                "cache_bytes": capacity_bytes,
                "ways": ways,
                "accesses": counters["accesses"],
                "hits": counters["hits"],
                "misses": counters["misses"],
                "miss_rate": counters["misses"] / counters["accesses"],
                "compulsory": counters["compulsory"],
                "conflict": counters["conflict"],
                "capacity": counters["capacity"],
            }
        )

    rtl_misses = None
    rtl_csv = source / "rtl_perf_profile.csv"
    if rtl_csv.is_file():
        with rtl_csv.open() as stream:
            rtl_misses = sum(
                int(row["icache_misses"]) for row in csv.DictReader(stream)
            )
        rows[0]["rtl_baseline_lookup_misses"] = rtl_misses
        rows[0]["model_vs_rtl_miss_delta"] = rows[0]["misses"] - rtl_misses

    fields = sorted({key for row in rows for key in row})
    with (output / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    (output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")

    lines = [
        "# Trace-driven ICache model",
        "",
        "This model replays the real RTL lookup-line stream with immediate "
        "LRU allocation. It explains locality and set conflicts, but does "
        "not model refill latency, redirects, killed requests or AXI "
        "contention; measured RTL cycles remain authoritative.",
        "",
        "| Configuration | Accesses | Misses | Miss rate | Compulsory | "
        "Conflict | Capacity |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['config']} | {row['accesses']:,} | {row['misses']:,} | "
            f"{100 * row['miss_rate']:.3f}% | {row['compulsory']:,} | "
            f"{row['conflict']:,} | {row['capacity']:,} |"
        )
    if rtl_misses is not None:
        lines.extend(
            [
                "",
                f"Baseline RTL lookup misses: {rtl_misses:,}; immediate-fill "
                f"model misses: {rows[0]['misses']:,}. Their difference is "
                "expected and measures effects which a pure address-trace "
                "cache model cannot represent.",
            ]
        )
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"Summary: {output / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
