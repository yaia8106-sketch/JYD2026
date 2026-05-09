#!/usr/bin/env python3
"""Estimate ALU+branch same-pair fusion on COE instruction streams.

This is an analysis script only.  It executes the COE program functionally with
the profiler's instruction semantics and counts opportunities where the current
dual-issue rules single-issue an ALU followed by a conditional branch.

The script reports several branch-prediction assumptions because this idea is
only attractive if the fused slot1 branch does not destroy predicted fetch flow.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from multiprocessing import Pool

from profiler import COE_DIR, PC_RESET, Inst, Profiler, s32, u32


BASELINE_COE_CPI = 0.957


def pct(num: float, den: float) -> float:
    return 100.0 * num / den if den else 0.0


def sat_update(v: int, taken: bool) -> int:
    return min(3, v + 1) if taken else max(0, v - 1)


class TournamentBP:
    """Current branch-only tournament model with inspectable predictions."""

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

    def predict(self, pc: int) -> tuple[bool, int, bool, int, bool]:
        idx = (pc >> 2) & (self.btb_sz - 1)
        pidx = ((pc >> 2) ^ self.ghr) & self.ghr_mask
        tag = pc >> 2
        hit = self.btb_v[idx] and self.btb_tag[idx] == tag
        bim = self.btb_bht[idx] >= 2 if hit else False
        gsh = self.pht[pidx] >= 2
        use_bim = self.sel[pidx] >= 2
        l1 = (bim if use_bim else gsh) if hit else False
        target = self.btb_tgt[idx] if hit else u32(pc + 4)
        return l1, target, bim if hit else False, self.btb_tgt[idx] if hit else u32(pc + 4), hit

    def update(self, pc: int, taken: bool, target: int) -> tuple[bool, bool]:
        pred_l1, pred_l1_target, pred_l0, pred_l0_target, hit = self.predict(pc)
        l1_ok = (pred_l1 == taken) and (not taken or pred_l1_target == target)
        l0_ok = (pred_l0 == taken) and (not taken or pred_l0_target == target)

        idx = (pc >> 2) & (self.btb_sz - 1)
        pidx = ((pc >> 2) ^ self.ghr) & self.ghr_mask
        bim = self.btb_bht[idx] >= 2 if hit else False
        gsh = self.pht[pidx] >= 2

        if taken or hit:
            self.btb_v[idx] = True
            self.btb_tag[idx] = pc >> 2
            self.btb_tgt[idx] = target
        self.btb_bht[idx] = sat_update(self.btb_bht[idx], taken)
        self.pht[pidx] = sat_update(self.pht[pidx], taken)
        if bim != gsh:
            self.sel[pidx] = sat_update(self.sel[pidx], bim == taken)
        self.ghr = ((self.ghr << 1) | int(taken)) & self.ghr_mask
        return l1_ok, l0_ok


@dataclass
class PolicyStats:
    candidates: int = 0
    taken: int = 0
    l1_miss: int = 0
    l0_miss: int = 0
    pred_taken: int = 0
    top: Counter = field(default_factory=Counter)
    top_taken: Counter = field(default_factory=Counter)
    top_l1_miss: Counter = field(default_factory=Counter)


@dataclass
class ProgramResult:
    name: str
    done: bool
    result: int | None
    insts: int
    issues: int
    branches: int
    base_l1_miss: int
    base_l0_miss: int
    policies: dict[str, PolicyStats]
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


def fmt_pc(pc: int, disasm: dict[int, str]) -> str:
    text = disasm.get(pc, "")
    return f"0x{pc:08x}  {text}" if text else f"0x{pc:08x}"


def uses(inst: Inst, rd: int) -> bool:
    if rd == 0:
        return False
    return (inst._uses_rs1 and inst.rs1 == rd) or (inst._uses_rs2 and inst.rs2 == rd)


def current_can_dual(i0: Inst, i1: Inst, next_pc0: int) -> bool:
    if i0._is_jal or i0._is_jalr:
        return False
    if next_pc0 != u32(i0.pc + 4):
        return False
    if not i1._is_alu:
        return False
    if i0._writes_rd and uses(i1, i0.rd):
        return False
    return True


def branch_outcome(inst: Inst, regs: list[int]) -> tuple[bool, int]:
    r1 = u32(regs[inst.rs1]) if inst.rs1 else 0
    r2 = u32(regs[inst.rs2]) if inst.rs2 else 0
    s1 = s32(r1)
    s2 = s32(r2)
    taken = {
        0: r1 == r2,
        1: r1 != r2,
        4: s1 < s2,
        5: s1 >= s2,
        6: r1 < r2,
        7: r1 >= r2,
    }.get(inst.f3, False)
    target = u32(inst.pc + s32(inst.imm)) if taken else u32(inst.pc + 4)
    return taken, target


def is_zero_eqne_raw(i0: Inst, i1: Inst) -> bool:
    if not (i0._writes_rd and uses(i1, i0.rd)):
        return False
    if i1.f3 not in (0, 1):
        return False
    return (i1.rs1 == i0.rd and i1.rs2 == 0) or (i1.rs2 == i0.rd and i1.rs1 == 0)


def matching_policies(i0: Inst, i1: Inst) -> list[str]:
    if not (i0._is_alu and i1._is_branch):
        return []
    out = ["all_alu_branch"]
    if i0._writes_rd and uses(i1, i0.rd):
        out.append("raw_alu_branch")
    if is_zero_eqne_raw(i0, i1):
        out.append("zero_eqne_raw")
    return out


def run_program(args: tuple[str, str, int]) -> ProgramResult:
    name, coe_root, max_insts = args
    irom, dram = coe_pair(name, coe_root)
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE pair for {name}: {irom}, {dram}")

    sim = Profiler()
    sim.load_coe(irom, dram)
    sim.pc = u32(PC_RESET + 4)
    bp = TournamentBP()

    policies = {
        "all_alu_branch": PolicyStats(),
        "raw_alu_branch": PolicyStats(),
        "zero_eqne_raw": PolicyStats(),
    }
    insts = issues = branches = 0
    base_l1_miss = base_l0_miss = 0

    while insts < max_insts and not sim.done:
        issues += 1
        pc0 = sim.pc
        i0 = Inst(sim.fetch(pc0), pc0)

        res0, npc0 = sim.exec_one(i0)
        if i0._writes_rd:
            sim.regs[i0.rd] = res0
        sim.regs[0] = 0
        insts += 1

        if i0._is_branch:
            branches += 1
            taken0 = npc0 != u32(pc0 + 4)
            target0 = u32(pc0 + s32(i0.imm)) if taken0 else u32(pc0 + 4)
            l1_ok, l0_ok = bp.update(pc0, taken0, target0)
            base_l1_miss += int(not l1_ok)
            base_l0_miss += int(not l0_ok)

        next_pc0 = npc0 if npc0 is not None else u32(pc0 + 4)
        pc1 = u32(pc0 + 4)
        i1 = Inst(sim.fetch(pc1), pc1)

        if next_pc0 == pc1 and insts < max_insts:
            for policy in matching_policies(i0, i1):
                taken1, target1 = branch_outcome(i1, sim.regs)
                pred_l1, pred_l1_target, pred_l0, pred_l0_target, _hit = bp.predict(pc1)
                l1_ok = (pred_l1 == taken1) and (not taken1 or pred_l1_target == target1)
                l0_ok = (pred_l0 == taken1) and (not taken1 or pred_l0_target == target1)
                st = policies[policy]
                st.candidates += 1
                st.taken += int(taken1)
                st.l1_miss += int(not l1_ok)
                st.l0_miss += int(not l0_ok)
                st.pred_taken += int(pred_l1)
                st.top[pc1] += 1
                st.top_taken[pc1] += int(taken1)
                st.top_l1_miss[pc1] += int(not l1_ok)

        if insts < max_insts and current_can_dual(i0, i1, next_pc0):
            res1, npc1 = sim.exec_one(i1)
            if npc1 is not None:
                raise RuntimeError("current slot1 unexpectedly changed control flow")
            if i1._writes_rd:
                sim.regs[i1.rd] = res1
            sim.regs[0] = 0
            insts += 1
            sim.pc = u32(pc0 + 8)
        else:
            sim.pc = next_pc0

    return ProgramResult(
        name=name,
        done=sim.done,
        result=sim.result,
        insts=insts,
        issues=issues,
        branches=branches,
        base_l1_miss=base_l1_miss,
        base_l0_miss=base_l0_miss,
        policies=policies,
        disasm=load_disasm(name, coe_root),
    )


def policy_delta_cycles(st: PolicyStats) -> dict[str, int]:
    return {
        # Slot1 branch has prediction quality and redirect penalty equal to current S0 branch.
        "ideal_slot1_l1": st.candidates,
        # Slot1 branch preserves L1 prediction, but redirect is registered one cycle later.
        "slot1_l1_miss_plus1": st.candidates - st.l1_miss,
        # Slot1 branch only gets L0-quality prediction and a 3-cycle miss penalty.
        "slot1_l0_miss_plus1": st.candidates + 2 * st.l1_miss - 3 * st.l0_miss,
        # No slot1 branch prediction: fetch falls through, taken fused branches redirect.
        "no_slot1_bp": st.candidates + 2 * st.l1_miss - 2 * st.taken,
    }


def print_summary(rows: list[ProgramResult]) -> None:
    print("ALU+branch fusion estimate on functional COE issue stream")
    print()
    print(
        f"{'program':<8} {'insts':>10} {'issues':>10} {'policy':<16} "
        f"{'cand':>9} {'taken':>9} {'l1miss':>9} {'ideal':>9} "
        f"{'l1+1':>9} {'l0+1':>9} {'noBP':>9}"
    )
    print("-" * 116)
    for r in rows:
        for policy, st in r.policies.items():
            d = policy_delta_cycles(st)
            print(
                f"{r.name:<8} {r.insts:10d} {r.issues:10d} {policy:<16} "
                f"{st.candidates:9d} {st.taken:9d} {st.l1_miss:9d} "
                f"{d['ideal_slot1_l1']/r.insts:9.4f} "
                f"{d['slot1_l1_miss_plus1']/r.insts:9.4f} "
                f"{d['slot1_l0_miss_plus1']/r.insts:9.4f} "
                f"{d['no_slot1_bp']/r.insts:9.4f}"
            )
        print()

    print("Weighted aggregate")
    print(
        f"{'policy':<16} {'cand':>9} {'taken':>9} {'l1miss':>9} "
        f"{'ideal':>9} {'l1+1':>9} {'l0+1':>9} {'noBP':>9} "
        f"{'speedup_l1+1':>13} {'period_ok':>10}"
    )
    print("-" * 116)
    total_insts = sum(r.insts for r in rows)
    for policy in ("all_alu_branch", "raw_alu_branch", "zero_eqne_raw"):
        st = PolicyStats()
        for r in rows:
            s = r.policies[policy]
            st.candidates += s.candidates
            st.taken += s.taken
            st.l1_miss += s.l1_miss
            st.l0_miss += s.l0_miss
            st.pred_taken += s.pred_taken
        d = policy_delta_cycles(st)
        l1_gain = d["slot1_l1_miss_plus1"] / total_insts if total_insts else 0.0
        speedup = l1_gain / BASELINE_COE_CPI if BASELINE_COE_CPI else 0.0
        new_cpi = BASELINE_COE_CPI - l1_gain
        period_ok = (5.0 * BASELINE_COE_CPI / new_cpi) if new_cpi > 0 else 0.0
        print(
            f"{policy:<16} {st.candidates:9d} {st.taken:9d} {st.l1_miss:9d} "
            f"{d['ideal_slot1_l1']/total_insts:9.4f} "
            f"{d['slot1_l1_miss_plus1']/total_insts:9.4f} "
            f"{d['slot1_l0_miss_plus1']/total_insts:9.4f} "
            f"{d['no_slot1_bp']/total_insts:9.4f} "
            f"{100.0*speedup:12.2f}% {period_ok:9.3f}ns"
        )

    print()
    print("Column meanings:")
    print("  ideal: current L1 prediction and current redirect penalty for fused slot1 branches.")
    print("  l1+1 : current L1 prediction, but fused branch misses cost one extra cycle.")
    print("  l0+1 : L0-quality prediction for fused branches, misses cost three cycles.")
    print("  noBP : no slot1 branch prediction; taken fused branches redirect from fallthrough.")
    print("  period_ok is the max clock period for same runtime under the l1+1 model.")


def print_hotspots(rows: list[ProgramResult], policy: str, limit: int) -> None:
    print()
    print(f"Top fused branch PCs: {policy}")
    for r in rows:
        print()
        print(f"{r.name}:")
        st = r.policies[policy]
        if not st.top:
            print("  (no candidates)")
            continue
        for pc, count in st.top.most_common(limit):
            print(
                f"  {count:8d}  taken={st.top_taken[pc]:8d} "
                f"l1miss={st.top_l1_miss[pc]:8d}  {fmt_pc(pc, r.disasm)}"
            )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", default=["src0", "src1", "src2"])
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

    print_summary(rows)
    print_hotspots(rows, "raw_alu_branch", args.limit)
    print_hotspots(rows, "zero_eqne_raw", args.limit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
