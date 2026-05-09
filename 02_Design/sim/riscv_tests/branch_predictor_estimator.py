#!/usr/bin/env python3
"""Estimate branch-predictor variants on COE branch streams.

This is an analysis script only.  It executes the program functionally with the
software profiler's instruction semantics, feeds each conditional branch into a
set of predictor models, and reports mispredict/flush-CPI estimates.  It does
not model RTL timing or pipeline hazards.
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from multiprocessing import Pool

from profiler import COE_DIR, PC_RESET, Inst, Profiler, s32, u32


DEFAULT_PROGRAMS = ("src0", "src1", "src2")
FOCUS_PROGRAMS = ("src0", "src1", "src2")


def pct(num: float, den: float) -> float:
    return 100.0 * num / den if den else 0.0


def sat_update(v: int, taken: bool) -> int:
    return min(3, v + 1) if taken else max(0, v - 1)


class TournamentBP:
    """Same branch-only tournament model as profiler.BP, with explicit result."""

    def __init__(self, name: str, btb_sz: int = 128, ghr_w: int = 8):
        self.name = name
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

    def update(self, pc: int, taken: bool, target: int) -> bool:
        idx = (pc >> 2) & (self.btb_sz - 1)
        pidx = ((pc >> 2) ^ self.ghr) & self.ghr_mask
        tag = pc >> 2
        hit = self.btb_v[idx] and self.btb_tag[idx] == tag

        bim = self.btb_bht[idx] >= 2 if hit else False
        gsh = self.pht[pidx] >= 2
        use_bim = self.sel[pidx] >= 2
        pred_taken = (bim if use_bim else gsh) if hit else False
        pred_target = self.btb_tgt[idx] if hit else u32(pc + 4)
        ok = (pred_taken == taken) and (not taken or pred_target == target)

        if taken or hit:
            self.btb_v[idx] = True
            self.btb_tag[idx] = tag
            self.btb_tgt[idx] = target
        self.btb_bht[idx] = sat_update(self.btb_bht[idx], taken)
        self.pht[pidx] = sat_update(self.pht[pidx], taken)
        if bim != gsh:
            self.sel[pidx] = sat_update(self.sel[pidx], bim == taken)
        self.ghr = ((self.ghr << 1) | int(taken)) & self.ghr_mask
        return ok


class LocalHistoryBP:
    """Direct-mapped BTB plus per-entry local history and PC+history PHT."""

    def __init__(self, name: str, btb_sz: int = 128, hist_w: int = 4):
        self.name = name
        self.btb_sz = btb_sz
        self.hist_w = hist_w
        self.hist_mask = (1 << hist_w) - 1
        self.btb_v = [False] * btb_sz
        self.btb_tag = [0] * btb_sz
        self.btb_tgt = [0] * btb_sz
        self.local_hist = [0] * btb_sz
        self.pht = [1] * (btb_sz << hist_w)

    def update(self, pc: int, taken: bool, target: int) -> bool:
        idx = (pc >> 2) & (self.btb_sz - 1)
        tag = pc >> 2
        hit = self.btb_v[idx] and self.btb_tag[idx] == tag
        hist = self.local_hist[idx] if hit else 0
        pidx = (idx << self.hist_w) | hist

        pred_taken = (self.pht[pidx] >= 2) if hit else False
        pred_target = self.btb_tgt[idx] if hit else u32(pc + 4)
        ok = (pred_taken == taken) and (not taken or pred_target == target)

        if taken or hit:
            if not hit:
                self.local_hist[idx] = 0
                hist = 0
                pidx = idx << self.hist_w
            self.btb_v[idx] = True
            self.btb_tag[idx] = tag
            self.btb_tgt[idx] = target
        self.pht[pidx] = sat_update(self.pht[pidx], taken)
        self.local_hist[idx] = ((hist << 1) | int(taken)) & self.hist_mask
        return ok


@dataclass
class ProgramResult:
    name: str
    done: bool
    result: int | None
    insts: int
    branches: int
    misses: dict[str, int]
    pc_total: Counter
    pc_miss: dict[str, Counter]
    disasm: dict[int, str]


def coe_pair(name: str, coe_root: str) -> tuple[str, str]:
    d = os.path.join(coe_root, name)
    return os.path.join(d, "irom.coe"), os.path.join(d, "dram.coe")


def load_disasm(program: str, coe_root: str) -> dict[int, str]:
    path = os.path.join(coe_root, program, "irom_disasm.txt")
    rows: dict[int, str] = {}
    if not os.path.exists(path):
        return rows
    pat = re.compile(r"^([0-9a-fA-F]+):\s+[0-9a-fA-F]+\s+(.*)$")
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = pat.match(line.strip())
            if m:
                rows[int(m.group(1), 16)] = m.group(2)
    return rows


def make_predictors() -> list:
    return [
        TournamentBP("base_tourn_128_g8", 128, 8),
        TournamentBP("tourn_128_g10", 128, 10),
        TournamentBP("tourn_128_g12", 128, 12),
        TournamentBP("tourn_256_g10", 256, 10),
        TournamentBP("tourn_256_g12", 256, 12),
        LocalHistoryBP("local_128_h2", 128, 2),
        LocalHistoryBP("local_128_h3", 128, 3),
        LocalHistoryBP("local_128_h4", 128, 4),
        LocalHistoryBP("local_128_h6", 128, 6),
        LocalHistoryBP("local_256_h4", 256, 4),
        LocalHistoryBP("local_256_h6", 256, 6),
    ]


def run_program(args: tuple[str, str, int]) -> ProgramResult:
    name, coe_root, max_insts = args
    irom, dram = coe_pair(name, coe_root)
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE pair for {name}: {irom}, {dram}")

    sim = Profiler()
    sim.load_coe(irom, dram)
    sim.pc = u32(PC_RESET + 4)

    predictors = make_predictors()
    misses = {p.name: 0 for p in predictors}
    pc_miss = {p.name: Counter() for p in predictors}
    pc_total: Counter[int] = Counter()
    insts = 0
    branches = 0

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
            pc_total[pc] += 1
            for pred in predictors:
                ok = pred.update(pc, taken, target)
                if not ok:
                    misses[pred.name] += 1
                    pc_miss[pred.name][pc] += 1

        sim.pc = npc if npc is not None else u32(pc + 4)
        insts += 1

    return ProgramResult(
        name=name,
        done=sim.done,
        result=sim.result,
        insts=insts,
        branches=branches,
        misses=misses,
        pc_total=pc_total,
        pc_miss=pc_miss,
        disasm=load_disasm(name, coe_root),
    )


def oracle_pc_best(result: ProgramResult, candidate: str, base: str) -> int:
    pcs = set(result.pc_total)
    return sum(min(result.pc_miss[base][pc], result.pc_miss[candidate][pc]) for pc in pcs)


def fmt_pc(pc: int, disasm: dict[int, str]) -> str:
    text = disasm.get(pc, "")
    return f"0x{pc:08x}  {text}" if text else f"0x{pc:08x}"


def print_summary(rows: list[ProgramResult], base: str) -> None:
    pred_names = list(rows[0].misses)
    print("Branch predictor estimate on functional branch stream")
    print()
    print(f"{'program':<8} {'insts':>10} {'branches':>9} {'predictor':<18} {'miss':>8} {'miss%':>7} {'flushCPI':>9} {'dCPI_gain':>10}")
    print("-" * 88)
    for r in rows:
        base_m = r.misses[base]
        for pred in pred_names:
            m = r.misses[pred]
            flush_cpi = (2.0 * m / r.insts) if r.insts else 0.0
            gain = (2.0 * (base_m - m) / r.insts) if r.insts else 0.0
            print(f"{r.name:<8} {r.insts:10d} {r.branches:9d} {pred:<18} {m:8d} {pct(m, r.branches):6.1f}% {flush_cpi:9.4f} {gain:10.4f}")

        # Per-PC oracle: a rough upper bound for adding a perfect PC-level selector.
        for pred in ("local_128_h4", "local_128_h6", "local_256_h6"):
            m = oracle_pc_best(r, pred, base)
            flush_cpi = (2.0 * m / r.insts) if r.insts else 0.0
            gain = (2.0 * (base_m - m) / r.insts) if r.insts else 0.0
            print(f"{r.name:<8} {r.insts:10d} {r.branches:9d} {'pc_oracle_'+pred:<18} {m:8d} {pct(m, r.branches):6.1f}% {flush_cpi:9.4f} {gain:10.4f}")
        print()

    print_weighted(rows, base)


def print_weighted(rows: list[ProgramResult], base: str) -> None:
    pred_names = list(rows[0].misses)
    insts = sum(r.insts for r in rows)
    branches = sum(r.branches for r in rows)
    base_m = sum(r.misses[base] for r in rows)
    print("Weighted aggregate")
    print(f"{'predictor':<24} {'miss':>9} {'miss%':>7} {'flushCPI':>9} {'dCPI_gain':>10}")
    print("-" * 66)
    for pred in pred_names:
        m = sum(r.misses[pred] for r in rows)
        print(f"{pred:<24} {m:9d} {pct(m, branches):6.1f}% {2.0*m/insts:9.4f} {2.0*(base_m-m)/insts:10.4f}")
    for pred in ("local_128_h4", "local_128_h6", "local_256_h6"):
        m = sum(oracle_pc_best(r, pred, base) for r in rows)
        print(f"{'pc_oracle_'+pred:<24} {m:9d} {pct(m, branches):6.1f}% {2.0*m/insts:9.4f} {2.0*(base_m-m)/insts:10.4f}")


def print_hot_improvements(rows: list[ProgramResult], base: str, pred: str, limit: int) -> None:
    print()
    print(f"Top per-PC improvements: {pred} vs {base}")
    for r in rows:
        deltas = []
        for pc in r.pc_total:
            delta = r.pc_miss[base][pc] - r.pc_miss[pred][pc]
            if delta > 0:
                deltas.append((delta, r.pc_total[pc], r.pc_miss[base][pc], r.pc_miss[pred][pc], pc))
        deltas.sort(reverse=True)
        print()
        print(f"{r.name}:")
        if not deltas:
            print("  (no improved PCs)")
            continue
        for delta, total, bm, pm, pc in deltas[:limit]:
            print(f"  +{delta:7d}  total={total:8d}  base={bm:7d}  cand={pm:7d}  {fmt_pc(pc, r.disasm)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", default=list(DEFAULT_PROGRAMS))
    ap.add_argument("--coe-root", default=os.path.normpath(COE_DIR))
    ap.add_argument("--max-insts", type=int, default=3_000_000)
    ap.add_argument("--jobs", type=int, default=18)
    ap.add_argument("--limit", type=int, default=12)
    args = ap.parse_args()

    jobs = [(name, args.coe_root, args.max_insts) for name in args.programs]
    workers = max(1, min(args.jobs, len(jobs)))
    print(f"COE root: {args.coe_root}")
    print(f"Programs: {' '.join(args.programs)}")
    print(f"Max instructions per program: {args.max_insts}")
    print(f"Workers: {workers}")
    print()

    with Pool(workers) as pool:
        rows = pool.map(run_program, jobs)

    base = "base_tourn_128_g8"
    print_summary(rows, base)
    print_hot_improvements(rows, base, "local_128_h6", args.limit)
    print_hot_improvements(rows, base, "local_256_h6", args.limit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
