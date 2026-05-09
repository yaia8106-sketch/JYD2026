#!/usr/bin/env python3
"""Dynamic hotspot report for the contest COE programs.

The existing CPI attribution script answers "which class is expensive?".
This script answers the follow-up: "which PCs are causing it?".  It reuses the
lightweight software profiler model and reports hot conditional branches,
load-use consumers, and dual-issue blockers with disassembly context.
"""

import argparse
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from multiprocessing import Pool

from fetch_queue_estimator import pair_reason
from profiler import COE_DIR, PC_RESET, Inst, Profiler, s32, u32


DEFAULT_PROGRAMS = ("current", "src0", "src1", "src2")


@dataclass
class HotspotResult:
    name: str
    done: bool
    s0: int
    s1: int
    branch_total: Counter
    branch_miss: Counter
    load_use: Counter
    load_use_role: Counter
    dual_block: dict[str, Counter]
    disasm: dict[int, str]


def load_disasm(program: str) -> dict[int, str]:
    path = os.path.join(os.path.normpath(COE_DIR), program, "irom_disasm.txt")
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


def bp_predict(p: Profiler, pc: int) -> tuple[bool, int]:
    bp = p.bp
    idx = (pc >> 2) & (bp.btb_sz - 1)
    pht_idx = ((pc >> 2) ^ bp.ghr) & bp.ghr_mask
    hit = bp.btb_v[idx] and bp.btb_tag[idx] == (pc >> 2)
    bimodal_taken = bp.btb_bht[idx] >= 2 if hit else False
    gshare_taken = bp.pht[pht_idx] >= 2
    use_bimodal = bp.sel[pht_idx] >= 2
    pred_taken = (bimodal_taken if use_bimodal else gshare_taken) if hit else False
    pred_target = bp.btb_tgt[idx] if hit else u32(pc + 4)
    return pred_taken, pred_target


def classify_load_use(inst: Inst, dep_rs1: bool, dep_rs2: bool) -> str:
    if inst._is_branch:
        return "branch"
    if inst._is_jalr:
        return "jalr"
    if inst._is_load and dep_rs1:
        return "load_addr"
    if inst._is_store:
        if dep_rs1:
            return "store_addr"
        if dep_rs2:
            return "store_data"
    if inst._is_alu:
        return "alu"
    return "other"


class HotspotProfiler(Profiler):
    def run_hotspots(self, name: str, max_s0: int) -> HotspotResult:
        branch_total: Counter = Counter()
        branch_miss: Counter = Counter()
        load_use: Counter = Counter()
        load_use_role: Counter = Counter()
        dual_block: dict[str, Counter] = defaultdict(Counter)

        prev_load_rd: list[tuple[int, int, int]] = []
        self.pc = u32(PC_RESET + 4)
        self.done = False
        self.result = None
        s0 = 0
        s1 = 0

        while s0 < max_s0 and not self.done:
            pc0 = self.pc
            i0 = Inst(self.fetch(pc0), pc0)

            lu_stall = 0
            lu_dep_rs1 = False
            lu_dep_rs2 = False
            for lrd, age, _load_pc in prev_load_rd:
                if lrd == 0:
                    continue
                dep_rs1 = i0._uses_rs1 and i0.rs1 == lrd
                dep_rs2 = i0._uses_rs2 and i0.rs2 == lrd
                if dep_rs1 or dep_rs2:
                    lu_stall = max(lu_stall, 2 - age)
                    lu_dep_rs1 |= dep_rs1
                    lu_dep_rs2 |= dep_rs2

            if lu_stall > 0:
                load_use[pc0] += lu_stall
                load_use_role[classify_load_use(i0, lu_dep_rs1, lu_dep_rs2)] += lu_stall
                prev_load_rd = [
                    (rd, age + lu_stall, lpc)
                    for rd, age, lpc in prev_load_rd
                    if age + lu_stall < 3
                ]

            pred_taken, pred_target = bp_predict(self, pc0) if i0._is_branch else (False, u32(pc0 + 4))

            res0, npc0 = self.exec_one(i0)
            if i0._writes_rd:
                self.regs[i0.rd] = res0
            self.regs[0] = 0
            s0 += 1

            if i0._is_branch:
                taken = npc0 != u32(pc0 + 4)
                actual_target = u32(pc0 + s32(i0.imm)) if taken else u32(pc0 + 4)
                branch_total[pc0] += 1
                if pred_taken != taken or (taken and pred_target != actual_target):
                    branch_miss[pc0] += 1
                self.bp.update(pc0, taken, actual_target)

            if i0._is_load and i0.rd != 0:
                prev_load_rd.append((i0.rd, 0, pc0))
            prev_load_rd = [(rd, age + 1, lpc) for rd, age, lpc in prev_load_rd if age + 1 < 3]

            next_pc0 = npc0 if npc0 is not None else u32(pc0 + 4)
            pc1 = u32(pc0 + 4)
            i1 = Inst(self.fetch(pc1), pc1)
            reason = pair_reason(i0, i1, next_pc0)
            if reason == "pairable":
                res1, _ = self.exec_one(i1)
                if i1._writes_rd:
                    self.regs[i1.rd] = res1
                self.regs[0] = 0
                s1 += 1
                self.pc = u32(pc0 + 8)
            else:
                dual_block[reason][pc0] += 1
                self.pc = next_pc0

        return HotspotResult(
            name=name,
            done=self.done,
            s0=s0,
            s1=s1,
            branch_total=branch_total,
            branch_miss=branch_miss,
            load_use=load_use,
            load_use_role=load_use_role,
            dual_block=dict(dual_block),
            disasm=load_disasm(name),
        )


def coe_pair(name: str) -> tuple[str, str]:
    root = os.path.normpath(COE_DIR)
    irom = os.path.join(root, name, "irom.coe")
    dram = os.path.join(root, name, "dram.coe")
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE files for {name}")
    return irom, dram


def run_one(args: tuple[str, int]) -> HotspotResult:
    name, max_s0 = args
    irom, dram = coe_pair(name)
    p = HotspotProfiler()
    p.load_coe(irom, dram)
    return p.run_hotspots(name, max_s0)


def fmt_pc(pc: int, disasm: dict[int, str]) -> str:
    text = disasm.get(pc, "")
    return f"0x{pc:08x}  {text}" if text else f"0x{pc:08x}"


def print_counter(title: str, counter: Counter, disasm: dict[int, str], limit: int) -> None:
    print(title)
    if not counter:
        print("  (none)")
        return
    for pc, count in counter.most_common(limit):
        print(f"  {count:8d}  {fmt_pc(pc, disasm)}")


def print_result(r: HotspotResult, limit: int) -> None:
    insts = r.s0 + r.s1
    dual_rate = 100.0 * r.s1 / r.s0 if r.s0 else 0.0
    branch_misses = sum(r.branch_miss.values())
    branches = sum(r.branch_total.values())
    print()
    print("=" * 86)
    print(f"{r.name}: S0={r.s0} S1={r.s1} insts={insts} dual={dual_rate:.1f}% done={r.done}")
    if branches:
        print(f"branches={branches} misses={branch_misses} miss_rate={100.0 * branch_misses / branches:.1f}%")
    if r.load_use_role:
        role_text = " ".join(f"{k}={v}" for k, v in r.load_use_role.most_common())
        print(f"load-use roles: {role_text}")
    print("=" * 86)

    print_counter("Top branch-mispredict PCs", r.branch_miss, r.disasm, limit)
    print_counter("Top load-use consumer PCs", r.load_use, r.disasm, limit)

    for reason in ("slot1_not_alu", "raw_block", "inst0_not_seq", "inst0_jump"):
        print_counter(f"Top dual blocker PCs: {reason}", r.dual_block.get(reason, Counter()), r.disasm, limit)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", default=list(DEFAULT_PROGRAMS))
    ap.add_argument("--max-s0", type=int, default=300_000)
    ap.add_argument("--jobs", type=int, default=18)
    ap.add_argument("--limit", type=int, default=8)
    args = ap.parse_args()

    workers = max(1, min(args.jobs, len(args.programs)))
    with Pool(workers) as pool:
        rows = pool.map(run_one, [(name, args.max_s0) for name in args.programs])

    for row in rows:
        print_result(row, args.limit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
