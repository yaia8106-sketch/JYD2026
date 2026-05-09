#!/usr/bin/env python3
"""Architecture-level runtime estimate for a broad pipeline redesign.

This script does not modify RTL and does not claim a post-route result for a
new design.  It combines:

* current routed timing path classes,
* COE functional branch streams,
* adjacent ALU-to-control dependency counts,
* official small benchmark branch-miss counts,

then reports the Fmax/runtime thresholds a broad redesign would need to clear.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from multiprocessing import Pool
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = ROOT / "02_Design" / "sim" / "riscv_tests"
TIMING_DIR = ROOT / "03_Timing_Analysis"
sys.path.insert(0, str(SIM_DIR))
sys.path.insert(0, str(TIMING_DIR))

from pipeline_split_estimator import parse_timing_paths, run_dep_program  # noqa: E402
from profiler import COE_DIR, PC_RESET, Inst, Profiler, s32, u32  # noqa: E402


BASELINE_PERIOD_NS = 5.0
BASELINE_COE_CPI = 0.957
BASELINE_OFFICIAL_CYCLES = 3645


@dataclass
class BranchStats:
    name: str
    insts: int
    branches: int
    taken: int
    l0_miss: int
    l1_miss: int
    nlp_disagree: int
    done: bool


class CurrentBranchModel:
    """Current L0 bimodal + L1 tournament branch-only model."""

    def __init__(self, btb_sz: int = 128, ghr_w: int = 8):
        self.btb_sz = btb_sz
        self.pht_sz = 1 << ghr_w
        self.btb_v = [False] * btb_sz
        self.btb_tag = [0] * btb_sz
        self.btb_tgt = [0] * btb_sz
        self.btb_bht = [1] * btb_sz
        self.ghr = 0
        self.ghr_mask = self.pht_sz - 1
        self.pht = [1] * self.pht_sz
        self.sel = [2] * self.pht_sz

    @staticmethod
    def sat_update(v: int, taken: bool) -> int:
        return min(3, v + 1) if taken else max(0, v - 1)

    def update(self, pc: int, taken: bool, target: int) -> tuple[bool, bool, bool]:
        idx = (pc >> 2) & (self.btb_sz - 1)
        pidx = ((pc >> 2) ^ self.ghr) & self.ghr_mask
        tag = pc >> 2
        hit = self.btb_v[idx] and self.btb_tag[idx] == tag

        bim = self.btb_bht[idx] >= 2 if hit else False
        gsh = self.pht[pidx] >= 2
        use_bim = self.sel[pidx] >= 2
        l1 = bim if use_bim else gsh

        l0_pred_target = self.btb_tgt[idx] if hit else u32(pc + 4)
        l1_pred_target = self.btb_tgt[idx] if hit else u32(pc + 4)
        l0_ok = (bim == taken) and (not taken or l0_pred_target == target) if hit else (not taken)
        l1_ok = (l1 == taken) and (not taken or l1_pred_target == target) if hit else (not taken)
        disagree = hit and (bim != l1)

        if taken or hit:
            self.btb_v[idx] = True
            self.btb_tag[idx] = tag
            self.btb_tgt[idx] = target
        self.btb_bht[idx] = self.sat_update(self.btb_bht[idx], taken)
        self.pht[pidx] = self.sat_update(self.pht[pidx], taken)
        if bim != gsh:
            self.sel[pidx] = self.sat_update(self.sel[pidx], bim == taken)
        self.ghr = ((self.ghr << 1) | int(taken)) & self.ghr_mask
        return l0_ok, l1_ok, disagree


def pct(num: float, den: float) -> float:
    return 100.0 * num / den if den else 0.0


def coe_pair(name: str, coe_root: str) -> tuple[str, str]:
    d = Path(coe_root) / name
    return str(d / "irom.coe"), str(d / "dram.coe")


def run_branch_program(args: tuple[str, str, int]) -> BranchStats:
    name, coe_root, max_insts = args
    irom, dram = coe_pair(name, coe_root)
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE pair for {name}: {irom}, {dram}")

    sim = Profiler()
    sim.load_coe(irom, dram)
    sim.pc = u32(PC_RESET + 4)
    bp = CurrentBranchModel()

    insts = branches = taken_count = 0
    l0_miss = l1_miss = nlp_disagree = 0
    while insts < max_insts and not sim.done:
        pc = sim.pc
        inst = Inst(sim.fetch(pc), pc)
        res, npc = sim.exec_one(inst)
        if inst._writes_rd:
            sim.regs[inst.rd] = res
        sim.regs[0] = 0

        if inst._is_branch:
            branches += 1
            taken = npc != u32(pc + 4)
            target = u32(pc + s32(inst.imm)) if taken else u32(pc + 4)
            taken_count += int(taken)
            l0_ok, l1_ok, disagree = bp.update(pc, taken, target)
            l0_miss += int(not l0_ok)
            l1_miss += int(not l1_ok)
            nlp_disagree += int(disagree)

        sim.pc = npc if npc is not None else u32(pc + 4)
        insts += 1

    return BranchStats(
        name=name,
        insts=insts,
        branches=branches,
        taken=taken_count,
        l0_miss=l0_miss,
        l1_miss=l1_miss,
        nlp_disagree=nlp_disagree,
        done=sim.done,
    )


def parse_official_perf(path: Path) -> tuple[int, int, int]:
    cycles = 0
    branches = 0
    misses = 0
    pass_re = re.compile(r"\[PASS\]\s+\S+\s+\((\d+) cycles\)")
    br_re = re.compile(r"\[PERF\]\s+Total branch:\s+(\d+)")
    miss_re = re.compile(r"\[PERF\]\s+Mispredicts:\s+(\d+)")
    with path.open(encoding="utf-8") as f:
        for line in f:
            if m := pass_re.search(line):
                cycles += int(m.group(1))
            elif m := br_re.search(line):
                branches += int(m.group(1))
            elif m := miss_re.search(line):
                misses += int(m.group(1))
    return cycles, branches, misses


def print_timing_targets(paths, targets: list[float]) -> None:
    print("Retiming depth required by target period")
    print(f"{'target_ns':>9} {'fmax_mhz':>9} {'path_classes_over_target':>24}  examples")
    print("-" * 100)
    for target in targets:
        over = [p for p in paths if p.required_period > target]
        examples = ", ".join(f"{p.src}->{p.dst}" for p in over[:6])
        print(f"{target:9.3f} {1000.0/target:9.1f} {len(over):24d}  {examples}")


def print_branch_stats(rows: list[BranchStats]) -> dict[str, float]:
    print()
    print("Current branch stream model: L0 bimodal vs L1 tournament")
    print(
        f"{'program':<8} {'insts':>10} {'branches':>9} {'taken':>9} "
        f"{'l0_miss':>9} {'l1_miss':>9} {'nlp_diff':>9} {'l1_m/ki':>8}"
    )
    print("-" * 86)
    totals = {
        "insts": 0,
        "branches": 0,
        "taken": 0,
        "l0_miss": 0,
        "l1_miss": 0,
        "nlp_disagree": 0,
    }
    for r in rows:
        totals["insts"] += r.insts
        totals["branches"] += r.branches
        totals["taken"] += r.taken
        totals["l0_miss"] += r.l0_miss
        totals["l1_miss"] += r.l1_miss
        totals["nlp_disagree"] += r.nlp_disagree
        print(
            f"{r.name:<8} {r.insts:10d} {r.branches:9d} {r.taken:9d} "
            f"{r.l0_miss:9d} {r.l1_miss:9d} {r.nlp_disagree:9d} "
            f"{1000.0*r.l1_miss/r.insts:8.2f}"
        )
    print("-" * 86)
    print(
        f"{'weighted':<8} {totals['insts']:10d} {totals['branches']:9d} "
        f"{totals['taken']:9d} {totals['l0_miss']:9d} {totals['l1_miss']:9d} "
        f"{totals['nlp_disagree']:9d} "
        f"{1000.0*totals['l1_miss']/totals['insts']:8.2f}"
    )
    return {k: float(v) for k, v in totals.items()}


def speedup_for(delta_cpi: float, period_ns: float) -> float:
    old_time = BASELINE_COE_CPI * BASELINE_PERIOD_NS
    new_time = (BASELINE_COE_CPI + delta_cpi) * period_ns
    return old_time / new_time - 1.0


def breakeven_period(delta_cpi: float) -> float:
    return BASELINE_PERIOD_NS * BASELINE_COE_CPI / (BASELINE_COE_CPI + delta_cpi)


def print_coe_runtime_table(branch_totals: dict[str, float], ctrl_s0: float) -> None:
    insts = branch_totals["insts"]
    l0_miss = branch_totals["l0_miss"]
    l1_miss = branch_totals["l1_miss"]
    taken = branch_totals["taken"]

    scenarios = [
        (
            "frontend_only_no_new_bubble",
            0.0,
            "Only valid if pipelined fetch preserves steady predicted flow.",
        ),
        (
            "registered_redirect_keep_l1",
            l1_miss / insts,
            "+1 cycle on each current effective branch miss.",
        ),
        (
            "registered_redirect_l0_only",
            (3.0 * l0_miss - 2.0 * l1_miss) / insts,
            "Drop ID tournament correction and resolve L0 misses one cycle later.",
        ),
        (
            "id_branch_wait",
            ctrl_s0 / insts,
            "+1 wait on each adjacent S0 ALU -> branch/JALR dependency.",
        ),
        (
            "taken_branch_fetch_bubble",
            taken / insts,
            "Bad pipelined-BTB design: +1 bubble on every taken branch.",
        ),
    ]
    periods = [4.951, 4.876, 4.724, 4.469, 4.250, 4.000]

    print()
    print("COE runtime threshold table")
    print(f"Baseline CPI={BASELINE_COE_CPI:.3f}, period={BASELINE_PERIOD_NS:.3f} ns")
    print(
        f"{'scenario':<34} {'dCPI':>8} {'be_ns':>7} {'be_mhz':>8} "
        + " ".join(f"@{p:.3f}ns" for p in periods)
    )
    print("-" * 118)
    for name, delta, _note in scenarios:
        be = breakeven_period(delta)
        cols = " ".join(f"{100.0*speedup_for(delta, p):8.2f}%" for p in periods)
        print(f"{name:<34} {delta:8.4f} {be:7.3f} {1000.0/be:8.1f} {cols}")

    print()
    print("Scenario notes")
    for name, delta, note in scenarios:
        print(f"  {name}: dCPI={delta:.4f}; {note}")


def print_official_runtime_table(perf_log: Path) -> None:
    cycles, branches, misses = parse_official_perf(perf_log)
    if cycles == 0:
        cycles = BASELINE_OFFICIAL_CYCLES
    print()
    print("Official small benchmark redirect-latency threshold")
    print(f"Parsed cycles={cycles}, branches={branches}, branch_misses={misses}")
    print(f"{'extra model':<28} {'extra_cycles':>12} {'break_even_ns':>14} {'break_even_mhz':>15}")
    print("-" * 76)
    for label, extra in [
        ("+1 per branch miss", misses),
        ("+2 per branch miss", 2 * misses),
        ("+1 per all branches", branches),
    ]:
        new_cycles = cycles + extra
        be = BASELINE_PERIOD_NS * cycles / new_cycles if new_cycles else 0.0
        print(f"{label:<28} {extra:12d} {be:14.3f} {1000.0/be:15.1f}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--timing-report",
        default=str(ROOT / "05_Experiment_Records" / "20260509_baseline_assessment" / "raw" / "stage_timing_report.txt"),
    )
    ap.add_argument(
        "--perf-log",
        default=str(ROOT / "05_Experiment_Records" / "20260509_baseline_assessment" / "raw" / "run_perf_default.log"),
    )
    ap.add_argument("--coe-root", default=os.path.normpath(COE_DIR))
    ap.add_argument("--programs", nargs="*", default=["src0", "src1", "src2"])
    ap.add_argument("--max-insts", type=int, default=3_000_000)
    ap.add_argument("--jobs", type=int, default=18)
    args = ap.parse_args()

    paths = parse_timing_paths(Path(args.timing_report))
    print_timing_targets(paths, [5.0, 4.9, 4.8, 4.6, 4.5, 4.25, 4.0])

    jobs = [(p, args.coe_root, args.max_insts) for p in args.programs]
    workers = max(1, min(args.jobs, len(jobs)))
    print()
    print(f"COE root: {args.coe_root}")
    print(f"Programs: {' '.join(args.programs)}")
    print(f"Max instructions per program: {args.max_insts}")
    print(f"Workers: {workers}")
    with Pool(workers) as pool:
        branch_rows = pool.map(run_branch_program, jobs)
    with Pool(workers) as pool:
        dep_rows = pool.map(run_dep_program, jobs)

    branch_totals = print_branch_stats(branch_rows)
    ctrl_s0 = float(sum(r.branch_s0_alu + r.jalr_s0_alu for r in dep_rows))
    print_coe_runtime_table(branch_totals, ctrl_s0)
    print_official_runtime_table(Path(args.perf_log))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
