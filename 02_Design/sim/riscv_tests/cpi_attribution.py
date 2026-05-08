#!/usr/bin/env python3
"""CPI attribution for the contest COE programs.

This script is deliberately analysis-oriented rather than cycle-exact RTL.
It runs the existing software Profiler in parallel, adds the frontend queue
upper-bound estimate, and prints the parts that should guide the next RTL
optimization pass.  The SRC0/1/2 average is shown separately because those are
the contest-focused inputs we care about most.
"""

import argparse
import os
import sys
from dataclasses import dataclass
from multiprocessing import Pool

from fetch_queue_estimator import run_one as run_queue_estimate
from profiler import COE_DIR, Profiler


DEFAULT_PROGRAMS = ("current", "src0", "src1", "src2")
FOCUS_PROGRAMS = ("src0", "src1", "src2")


@dataclass
class Row:
    name: str
    done: bool
    result: int | None
    cycles: int
    insts: int
    s0: int
    s1: int
    raw_cpi: float
    adj_cpi: float
    load_use_cpi: float
    dcache_cpi: float
    flush_cpi: float
    queue_cpi_bound: float
    dual_rate: float
    bp_total: int
    bp_mispred: int
    dc_access: int
    dc_miss: int
    blk_raw: int
    blk_nalu: int
    blk_jmp: int
    blk_nseq: int


def pct(num: float, den: float) -> float:
    return 100.0 * num / den if den else 0.0


def coe_pair(coe_root: str, name: str) -> tuple[str, str]:
    d = os.path.join(coe_root, name)
    irom = os.path.join(d, "irom.coe")
    dram = os.path.join(d, "dram.coe")
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE pair for {name}: {d}")
    return irom, dram


def run_program(args: tuple[str, str, int, int]) -> Row:
    name, coe_root, max_cyc, queue_max_s0 = args
    irom, dram = coe_pair(coe_root, name)

    p = Profiler()
    p.load_coe(irom, dram)
    p.run(max_cyc=max_cyc)

    c = p.c
    insts = c["s0"] + c["s1"]
    raw_cycles = c["cyc"]
    adjusted_cycles = raw_cycles + c["stall_dc"] + c["flush"]
    q = run_queue_estimate(name, queue_max_s0)

    return Row(
        name=name,
        done=p.done,
        result=p.result,
        cycles=raw_cycles,
        insts=insts,
        s0=c["s0"],
        s1=c["s1"],
        raw_cpi=raw_cycles / insts if insts else 0.0,
        adj_cpi=adjusted_cycles / insts if insts else 0.0,
        load_use_cpi=c["stall_lu"] / insts if insts else 0.0,
        dcache_cpi=c["stall_dc"] / insts if insts else 0.0,
        flush_cpi=c["flush"] / insts if insts else 0.0,
        queue_cpi_bound=q.cpi_drop_bound,
        dual_rate=pct(c["s1"], c["s0"]),
        bp_total=p.bp.total,
        bp_mispred=p.bp.mispred,
        dc_access=p.dc.hits + p.dc.misses,
        dc_miss=p.dc.misses,
        blk_raw=c["blk_raw"],
        blk_nalu=c["blk_nalu"],
        blk_jmp=c["blk_jmp"],
        blk_nseq=c["blk_nseq"],
    )


def weighted_average(rows: list[Row], names: tuple[str, ...]) -> Row | None:
    selected = [r for r in rows if r.name in names]
    if not selected:
        return None

    insts = sum(r.insts for r in selected)
    cycles = sum(r.cycles for r in selected)
    s0 = sum(r.s0 for r in selected)
    s1 = sum(r.s1 for r in selected)
    bp_total = sum(r.bp_total for r in selected)
    bp_mispred = sum(r.bp_mispred for r in selected)
    dc_access = sum(r.dc_access for r in selected)
    dc_miss = sum(r.dc_miss for r in selected)

    def wavg(fn) -> float:
        return sum(fn(r) * r.insts for r in selected) / insts if insts else 0.0

    return Row(
        name="+".join(names),
        done=all(r.done for r in selected),
        result=None,
        cycles=cycles,
        insts=insts,
        s0=s0,
        s1=s1,
        raw_cpi=cycles / insts if insts else 0.0,
        adj_cpi=wavg(lambda r: r.adj_cpi),
        load_use_cpi=wavg(lambda r: r.load_use_cpi),
        dcache_cpi=wavg(lambda r: r.dcache_cpi),
        flush_cpi=wavg(lambda r: r.flush_cpi),
        queue_cpi_bound=wavg(lambda r: r.queue_cpi_bound),
        dual_rate=pct(s1, s0),
        bp_total=bp_total,
        bp_mispred=bp_mispred,
        dc_access=dc_access,
        dc_miss=dc_miss,
        blk_raw=sum(r.blk_raw for r in selected),
        blk_nalu=sum(r.blk_nalu for r in selected),
        blk_jmp=sum(r.blk_jmp for r in selected),
        blk_nseq=sum(r.blk_nseq for r in selected),
    )


def print_table(rows: list[Row]) -> None:
    print("CPI attribution, software model")
    print()
    hdr = (
        f"{'program':<10} {'insts':>9} {'CPI':>7} {'raw':>7} "
        f"{'LU':>7} {'D$':>7} {'flush':>7} {'Q<=':>7} "
        f"{'dual%':>7} {'br_m%':>7} {'dcm%':>7}"
    )
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(
            f"{r.name:<10} {r.insts:9d} {r.adj_cpi:7.3f} {r.raw_cpi:7.3f} "
            f"{r.load_use_cpi:7.3f} {r.dcache_cpi:7.3f} {r.flush_cpi:7.3f} "
            f"{r.queue_cpi_bound:7.3f} {r.dual_rate:6.1f}% "
            f"{pct(r.bp_mispred, r.bp_total):6.1f}% {pct(r.dc_miss, r.dc_access):6.1f}%"
        )


def print_dual_blockers(rows: list[Row]) -> None:
    print()
    print("Dual-issue blocker mix, per S0 opportunity")
    hdr = (
        f"{'program':<10} {'!ALU':>8} {'RAW':>8} {'jump':>8} "
        f"{'!seq':>8} {'issued':>8}"
    )
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(
            f"{r.name:<10} {pct(r.blk_nalu, r.s0):7.1f}% {pct(r.blk_raw, r.s0):7.1f}% "
            f"{pct(r.blk_jmp, r.s0):7.1f}% {pct(r.blk_nseq, r.s0):7.1f}% "
            f"{r.dual_rate:7.1f}%"
        )


def print_priorities(focus: Row) -> None:
    components = [
        ("dcache_miss", focus.dcache_cpi, "cache miss/refill and memory locality path"),
        ("branch_flush", focus.flush_cpi, "branch/JALR prediction or earlier redirect"),
        ("load_use", focus.load_use_cpi, "load-use forwarding/stall policy"),
        ("frontend_queue_bound", focus.queue_cpi_bound, "small fetch queue / frontend decoupling"),
    ]
    components.sort(key=lambda x: x[1], reverse=True)

    print()
    print(f"SRC0/1/2 weighted priority, avg CPI={focus.adj_cpi:.3f}")
    for idx, (name, value, hint) in enumerate(components, 1):
        print(f"  {idx}. {name:<20} dCPI~{value:.3f}  {hint}")

    blocker_total = focus.blk_nalu + focus.blk_raw + focus.blk_jmp + focus.blk_nseq
    if blocker_total:
        blockers = [
            ("slot1_not_alu", focus.blk_nalu),
            ("same_pair_raw", focus.blk_raw),
            ("slot0_jump", focus.blk_jmp),
            ("not_sequential", focus.blk_nseq),
        ]
        blockers.sort(key=lambda x: x[1], reverse=True)
        print()
        print("Main dual-issue blockers in SRC0/1/2:")
        for name, value in blockers:
            print(f"  {name:<16} {value:8d}  {pct(value, focus.s0):5.1f}% of S0")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", default=list(DEFAULT_PROGRAMS))
    ap.add_argument("--coe-root", default=os.path.normpath(COE_DIR))
    ap.add_argument("--max-cyc", type=int, default=2_000_000)
    ap.add_argument("--queue-max-s0", type=int, default=100_000)
    ap.add_argument("--jobs", type=int, default=18)
    args = ap.parse_args()

    jobs = [(name, args.coe_root, args.max_cyc, args.queue_max_s0)
            for name in args.programs]
    workers = max(1, min(args.jobs, len(jobs)))

    print(f"COE root: {args.coe_root}")
    print(f"Programs: {' '.join(args.programs)}")
    print(f"Workers: {workers}")
    print()

    with Pool(workers) as pool:
        rows = pool.map(run_program, jobs)

    print_table(rows)
    focus = weighted_average(rows, FOCUS_PROGRAMS)
    if focus is not None:
        print_table([focus])
    print_dual_blockers(rows)
    if focus is not None:
        print_priorities(focus)

    unfinished = [r.name for r in rows if not r.done]
    if unfinished:
        print()
        print("Note: these programs did not reach LED completion in the software model:")
        print("  " + " ".join(unfinished))
    return 0


if __name__ == "__main__":
    sys.exit(main())
