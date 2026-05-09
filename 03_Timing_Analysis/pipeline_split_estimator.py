#!/usr/bin/env python3
"""Estimate runtime upside from candidate pipeline timing cuts.

The script is intentionally conservative: it does not claim a routed Fmax for
RTL that does not exist.  It parses the current post-route timing report,
removes path classes that a hypothetical split would cut, and reports the
remaining period bound plus the extra cycles that bound could afford.

It also runs a small COE stream analysis for adjacent ALU->branch/JALR
dependencies, because the current worst path is an EX result feeding ID branch
precompute and then ID/EX.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from multiprocessing import Pool
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = ROOT / "02_Design" / "sim" / "riscv_tests"
sys.path.insert(0, str(SIM_DIR))

from profiler import COE_DIR, PC_RESET, Inst, Profiler, s32, u32  # noqa: E402


@dataclass(frozen=True)
class TimingPath:
    rank: int
    slack: float
    datapath: float
    levels: int
    src: str
    dst: str

    @property
    def required_period(self) -> float:
        return BASELINE_PERIOD_NS - self.slack


@dataclass
class DepStats:
    name: str
    insts: int
    issues: int
    done: bool
    branch_s0_alu: int
    branch_s1_alu: int
    jalr_s0_alu: int
    jalr_s1_alu: int
    branch_s0_load: int
    branch_s1_load: int
    top: Counter


BASELINE_PERIOD_NS = 5.0


def parse_timing_paths(path: Path) -> list[TimingPath]:
    rows: list[TimingPath] = []
    in_step4 = False
    row_re = re.compile(
        r"^\s*(\d+)\s+(-?\d+\.\d+)\s+(\d+\.\d+)\s+(\d+)\s+(.+?)\s*(?:←.*)?$"
    )
    with path.open(encoding="utf-8") as f:
        for line in f:
            if "[Step 4]" in line:
                in_step4 = True
                continue
            if in_step4 and "[Step 5]" in line:
                break
            if not in_step4:
                continue
            m = row_re.match(line.rstrip())
            if not m:
                continue
            logic_path = m.group(5).strip()
            if "\u2192" not in logic_path:
                continue
            src, dst = [x.strip() for x in logic_path.split("\u2192", 1)]
            rows.append(
                TimingPath(
                    rank=int(m.group(1)),
                    slack=float(m.group(2)),
                    datapath=float(m.group(3)),
                    levels=int(m.group(4)),
                    src=src,
                    dst=dst,
                )
            )
    if not rows:
        raise RuntimeError(f"no Step 4 timing rows parsed from {path}")
    return rows


def scenario_predicates() -> list[tuple[str, str, Callable[[TimingPath], bool]]]:
    frontend_dsts = {"IROM(BRAM)"}
    id_branch_srcs = {"ID/EX", "EX/MEM", "MEM/WB", "RegFile"}

    def cut_frontend(p: TimingPath) -> bool:
        return p.dst in frontend_dsts

    def cut_ex_redirect(p: TimingPath) -> bool:
        return p.src in {"ID/EX", "EX/MEM"} and p.dst in {"Pre_IF(PC)", "IROM(BRAM)"}

    def cut_id_branch(p: TimingPath) -> bool:
        return p.src in id_branch_srcs and p.dst == "ID/EX"

    return [
        ("baseline", "No cut; current routed timing.", lambda p: False),
        (
            "frontend_if1_boundary",
            "Upper bound for registering the IROM request side.",
            cut_frontend,
        ),
        (
            "relax_ex_redirect",
            "Upper bound for removing same-cycle EX redirect to frontend.",
            cut_ex_redirect,
        ),
        (
            "id_branch_dep_wait",
            "Upper bound for cutting EX/MEM/WB/RF to ID branch precompute.",
            cut_id_branch,
        ),
        (
            "frontend_plus_id_branch",
            "Combination of frontend_if1_boundary and id_branch_dep_wait.",
            lambda p: cut_frontend(p) or cut_id_branch(p),
        ),
        (
            "cut_top_5_paths",
            "Unrealistic bound: remove the five tightest path classes.",
            lambda p: p.rank <= 5,
        ),
        (
            "cut_top_10_paths",
            "Unrealistic bound: remove the ten tightest path classes.",
            lambda p: p.rank <= 10,
        ),
        (
            "cut_all_slack_lt_0p5",
            "Very broad retiming bound: remove every path with slack < 0.5 ns.",
            lambda p: p.slack < 0.5,
        ),
    ]


def print_timing_estimate(paths: list[TimingPath], baseline_cycles: int) -> None:
    print("Pipeline timing-cut estimate from current routed report")
    print(f"Baseline target period: {BASELINE_PERIOD_NS:.3f} ns")
    print(f"Baseline cycles for runtime math: {baseline_cycles}")
    print()
    print(
        f"{'scenario':<26} {'cut':>4} {'remain':>6} {'period_ns':>9} "
        f"{'fmax_mhz':>9} {'clk_gain':>9} {'extra_cyc_ok':>12}  note"
    )
    print("-" * 116)
    for name, note, cut in scenario_predicates():
        kept = [p for p in paths if not cut(p)]
        if not kept:
            period = 0.0
            worst = "none"
        else:
            worst_path = max(kept, key=lambda p: p.required_period)
            period = worst_path.required_period
            worst = f"{worst_path.src}->{worst_path.dst}"
        gain = BASELINE_PERIOD_NS / period - 1.0 if period else 0.0
        extra = int(baseline_cycles * gain)
        print(
            f"{name:<26} {len(paths)-len(kept):4d} {len(kept):6d} "
            f"{period:9.3f} {1000.0/period:9.1f} {100.0*gain:8.2f}% "
            f"{extra:12d}  {note} worst={worst}"
        )

    print()
    print("Tightest current paths")
    print(f"{'#':>3} {'slack':>7} {'req_ns':>7} {'levels':>6}  path")
    print("-" * 64)
    for p in sorted(paths, key=lambda x: x.rank)[:15]:
        print(
            f"{p.rank:3d} {p.slack:7.3f} {p.required_period:7.3f} "
            f"{p.levels:6d}  {p.src}->{p.dst}"
        )


def coe_pair(name: str, coe_root: str) -> tuple[str, str]:
    d = Path(coe_root) / name
    return str(d / "irom.coe"), str(d / "dram.coe")


def writes_alu(inst: Inst) -> bool:
    return inst._writes_rd and inst._is_alu


def writes_load(inst: Inst) -> bool:
    return inst._writes_rd and inst._is_load


def uses(inst: Inst, rd: int) -> bool:
    if rd == 0:
        return False
    return (inst._uses_rs1 and inst.rs1 == rd) or (inst._uses_rs2 and inst.rs2 == rd)


def can_dual(i0: Inst, i1: Inst, next_pc0: int) -> bool:
    if i0._is_jal or i0._is_jalr:
        return False
    if next_pc0 != u32(i0.pc + 4):
        return False
    if not i1._is_alu:
        return False
    if i0._writes_rd and uses(i1, i0.rd):
        return False
    return True


def run_dep_program(args: tuple[str, str, int]) -> DepStats:
    name, coe_root, max_insts = args
    irom, dram = coe_pair(name, coe_root)
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE pair for {name}: {irom}, {dram}")

    sim = Profiler()
    sim.load_coe(irom, dram)
    sim.pc = u32(PC_RESET + 4)

    insts = 0
    issues = 0
    branch_s0_alu = branch_s1_alu = 0
    jalr_s0_alu = jalr_s1_alu = 0
    branch_s0_load = branch_s1_load = 0
    top: Counter[int] = Counter()
    prev_s0: Inst | None = None
    prev_s1: Inst | None = None

    while insts < max_insts and not sim.done:
        pc0 = sim.pc
        i0 = Inst(sim.fetch(pc0), pc0)

        if i0._is_branch or i0._is_jalr:
            s0_hit = prev_s0 is not None and uses(i0, prev_s0.rd)
            s1_hit = prev_s1 is not None and uses(i0, prev_s1.rd)
            if s0_hit and writes_alu(prev_s0):
                if i0._is_branch:
                    branch_s0_alu += 1
                else:
                    jalr_s0_alu += 1
                top[pc0] += 1
            if s1_hit and writes_alu(prev_s1):
                if i0._is_branch:
                    branch_s1_alu += 1
                else:
                    jalr_s1_alu += 1
                top[pc0] += 1
            if s0_hit and writes_load(prev_s0):
                branch_s0_load += int(i0._is_branch)
            if s1_hit and writes_load(prev_s1):
                branch_s1_load += int(i0._is_branch)

        res0, npc0 = sim.exec_one(i0)
        if i0._writes_rd:
            sim.regs[i0.rd] = res0
        sim.regs[0] = 0
        next_pc0 = npc0 if npc0 is not None else u32(pc0 + 4)
        insts += 1
        issues += 1

        issued_s1: Inst | None = None
        pc1 = u32(pc0 + 4)
        i1 = Inst(sim.fetch(pc1), pc1)
        if insts < max_insts and can_dual(i0, i1, next_pc0):
            res1, npc1 = sim.exec_one(i1)
            if npc1 is not None:
                raise RuntimeError("slot1 unexpectedly changed control flow")
            if i1._writes_rd:
                sim.regs[i1.rd] = res1
            sim.regs[0] = 0
            issued_s1 = i1
            insts += 1
            sim.pc = u32(pc0 + 8)
        else:
            sim.pc = next_pc0

        prev_s0 = i0
        prev_s1 = issued_s1

    return DepStats(
        name=name,
        insts=insts,
        issues=issues,
        done=sim.done,
        branch_s0_alu=branch_s0_alu,
        branch_s1_alu=branch_s1_alu,
        jalr_s0_alu=jalr_s0_alu,
        jalr_s1_alu=jalr_s1_alu,
        branch_s0_load=branch_s0_load,
        branch_s1_load=branch_s1_load,
        top=top,
    )


def print_dep_estimate(rows: list[DepStats]) -> None:
    print()
    print("Adjacent EX-result -> ID control dependency estimate")
    print(
        f"{'program':<8} {'insts':>10} {'issues':>10} {'br_s0_alu':>10} "
        f"{'br_s1_alu':>10} {'jalr_s0':>8} {'jalr_s1':>8} {'ctrl_s0':>9}"
    )
    print("-" * 86)
    total_insts = total_s0 = total_s1 = total_j0 = total_j1 = total_issues = 0
    for r in rows:
        ctrl_s0 = r.branch_s0_alu + r.jalr_s0_alu
        total_insts += r.insts
        total_issues += r.issues
        total_s0 += r.branch_s0_alu
        total_s1 += r.branch_s1_alu
        total_j0 += r.jalr_s0_alu
        total_j1 += r.jalr_s1_alu
        print(
            f"{r.name:<8} {r.insts:10d} {r.issues:10d} {r.branch_s0_alu:10d} "
            f"{r.branch_s1_alu:10d} {r.jalr_s0_alu:8d} {r.jalr_s1_alu:8d} "
            f"{ctrl_s0:9d}"
        )
    total_ctrl_s0 = total_s0 + total_j0
    print("-" * 86)
    print(
        f"{'weighted':<8} {total_insts:10d} {total_issues:10d} {total_s0:10d} "
        f"{total_s1:10d} {total_j0:8d} {total_j1:8d} {total_ctrl_s0:9d}"
    )
    print()
    if total_insts:
        print(
            "If every S0 EX-ALU -> branch/JALR case gained a one-cycle wait, "
            f"the COE prefix cost would be about {total_ctrl_s0 / total_insts:.4f} CPI."
        )
    print("S1 EX-ALU cases are shown separately because current RTL already has a branch_s1_ex_wait hazard.")

    print()
    print("Top PCs for S0/S1 ALU -> control dependencies")
    for r in rows:
        print(f"{r.name}:")
        for pc, count in r.top.most_common(8):
            print(f"  {count:8d}  0x{pc:08x}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--timing-report",
        default=str(ROOT / "05_Experiment_Records" / "20260509_baseline_assessment" / "raw" / "stage_timing_report.txt"),
    )
    ap.add_argument("--baseline-cycles", type=int, default=3645)
    ap.add_argument("--coe-root", default=os.path.normpath(COE_DIR))
    ap.add_argument("--programs", nargs="*", default=["src0", "src1", "src2"])
    ap.add_argument("--max-insts", type=int, default=3_000_000)
    ap.add_argument("--jobs", type=int, default=18)
    args = ap.parse_args()

    paths = parse_timing_paths(Path(args.timing_report))
    print_timing_estimate(paths, args.baseline_cycles)

    jobs = [(p, args.coe_root, args.max_insts) for p in args.programs]
    workers = max(1, min(args.jobs, len(jobs)))
    print()
    print(f"COE root: {args.coe_root}")
    print(f"Programs: {' '.join(args.programs)}")
    print(f"Max instructions per program: {args.max_insts}")
    print(f"Workers: {workers}")

    with Pool(workers) as pool:
        dep_rows = pool.map(run_dep_program, jobs)
    print_dep_estimate(dep_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
