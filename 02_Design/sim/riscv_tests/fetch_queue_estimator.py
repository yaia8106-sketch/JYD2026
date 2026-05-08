#!/usr/bin/env python3
"""Estimate the CPI upside of decoupling fetch from issue with a small queue.

This is intentionally a lightweight model.  It reuses the functional RV32I
executor from profiler.py and compares two sequential-front-end policies:

  current-lag:
    Approximate the RTL predict_dual/skip_inst0 behavior.  If the previous
    accepted fetch predicted single issue but the pair actually dual-issued,
    the following cycle is forced to single issue because the frontend fetched
    the already-consumed slot1 again and has to skip it.

  ideal-queue:
    The issue side can always see the next contiguous pair after a dual issue.
    This approximates a shallow fetch queue that stores enough instructions to
    avoid the forced-single skip cycle.  Branch prediction, cache, and load-use
    penalties are not modeled here; the result is an upper bound for frontend
    queue benefit, not a full CPI predictor.
"""

import argparse
import os
import sys
from dataclasses import dataclass

from profiler import COE_DIR, PC_RESET
from profiler import Inst, Profiler, u32


PROGRAMS = ("current", "src0", "src1", "src2")


@dataclass
class Estimate:
    name: str
    total_s0: int = 0
    current_s1: int = 0
    ideal_s1: int = 0
    forced_single: int = 0
    lost_pairable: int = 0
    pairable: int = 0
    raw_block: int = 0
    slot1_not_alu: int = 0
    inst0_jump: int = 0
    inst0_not_seq: int = 0
    done: bool = False

    @property
    def total_current(self) -> int:
        return self.total_s0 + self.current_s1

    @property
    def extra_s1(self) -> int:
        return self.ideal_s1 - self.current_s1

    @property
    def cpi_drop_bound(self) -> float:
        if self.total_current <= 0:
            return 0.0
        return self.extra_s1 / self.total_current


def pair_reason(i0: Inst, i1: Inst, next_pc0: int) -> str:
    """Return 'pairable' or the first current slot1 dual-issue blocker."""
    if i0._is_jal or i0._is_jalr:
        return "inst0_jump"
    if next_pc0 != u32(i0.pc + 4):
        return "inst0_not_seq"
    if not i1._is_alu:
        return "slot1_not_alu"
    if i0._writes_rd and i0.rd != 0:
        if (i1._uses_rs1 and i1.rs1 == i0.rd) or (i1._uses_rs2 and i1.rs2 == i0.rd):
            return "raw_block"
    return "pairable"


class QueueEstimator(Profiler):
    def estimate(self, name: str, max_s0: int) -> Estimate:
        e = Estimate(name=name)
        self.pc = u32(PC_RESET + 4)
        self.done = False
        self.result = None

        predict_dual = False
        force_single = False

        while e.total_s0 < max_s0 and not self.done:
            pc0 = self.pc
            i0 = Inst(self.fetch(pc0), pc0)

            # Execute slot0 first.  This mirrors the profiler's in-order model
            # and gives us the actual next PC for branch/JAL/JALR.
            res0, npc0 = self.exec_one(i0)
            if i0._writes_rd:
                self.regs[i0.rd] = res0
            self.regs[0] = 0

            next_pc0 = npc0 if npc0 is not None else u32(pc0 + 4)
            i1 = Inst(self.fetch(u32(pc0 + 4)), u32(pc0 + 4))
            reason = pair_reason(i0, i1, next_pc0)
            pairable = reason == "pairable"

            e.total_s0 += 1
            if pairable:
                e.pairable += 1
            elif reason == "raw_block":
                e.raw_block += 1
            elif reason == "slot1_not_alu":
                e.slot1_not_alu += 1
            elif reason == "inst0_jump":
                e.inst0_jump += 1
            elif reason == "inst0_not_seq":
                e.inst0_not_seq += 1

            ideal_dual = pairable
            current_dual = pairable and not force_single

            if ideal_dual:
                e.ideal_s1 += 1
            if current_dual:
                e.current_s1 += 1

            if force_single:
                e.forced_single += 1
                if pairable:
                    e.lost_pairable += 1
                force_single = False

            underpredicted_dual = current_dual and not predict_dual
            if underpredicted_dual:
                force_single = True

            # In the RTL, predict_dual is not updated on a skip cycle.  The
            # approximation below is enough to estimate the main F->T penalty.
            if not force_single:
                predict_dual = current_dual

            if current_dual:
                res1, _ = self.exec_one(i1)
                if i1._writes_rd:
                    self.regs[i1.rd] = res1
                self.regs[0] = 0
                self.pc = u32(pc0 + 8)
            else:
                self.pc = next_pc0

        e.done = self.done
        return e


def run_one(name: str, max_s0: int) -> Estimate:
    coe_dir = os.path.normpath(COE_DIR)
    irom = os.path.join(coe_dir, name, "irom.coe")
    dram = os.path.join(coe_dir, name, "dram.coe")
    if not os.path.exists(irom) or not os.path.exists(dram):
        raise FileNotFoundError(f"missing COE files for {name}")

    q = QueueEstimator()
    q.load_coe(irom, dram)
    return q.estimate(name, max_s0=max_s0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("programs", nargs="*", default=list(PROGRAMS))
    ap.add_argument("--max-s0", type=int, default=500_000)
    args = ap.parse_args()

    rows = [run_one(name, args.max_s0) for name in args.programs]

    print("Frontend queue upper-bound estimate")
    print(f"max_s0={args.max_s0}")
    print()
    hdr = (
        f"{'program':<8} {'S0':>9} {'curS1':>9} {'idealS1':>9} "
        f"{'extra':>8} {'dCPI<=':>8} {'skip':>8} {'lost':>8} "
        f"{'!ALU':>8} {'RAW':>8} {'ctrl':>8}"
    )
    print(hdr)
    print("-" * len(hdr))

    total_s0 = total_cur_s1 = total_ideal_s1 = total_extra = 0
    total_skip = total_lost = 0
    for r in rows:
        total_s0 += r.total_s0
        total_cur_s1 += r.current_s1
        total_ideal_s1 += r.ideal_s1
        total_extra += r.extra_s1
        total_skip += r.forced_single
        total_lost += r.lost_pairable
        ctrl = r.inst0_jump + r.inst0_not_seq
        print(
            f"{r.name:<8} {r.total_s0:9d} {r.current_s1:9d} {r.ideal_s1:9d} "
            f"{r.extra_s1:8d} {r.cpi_drop_bound:8.4f} {r.forced_single:8d} "
            f"{r.lost_pairable:8d} {r.slot1_not_alu:8d} {r.raw_block:8d} {ctrl:8d}"
        )

    total_inst = total_s0 + total_cur_s1
    avg_drop = total_extra / total_inst if total_inst else 0.0
    print("-" * len(hdr))
    print(
        f"{'TOTAL':<8} {total_s0:9d} {total_cur_s1:9d} {total_ideal_s1:9d} "
        f"{total_extra:8d} {avg_drop:8.4f} {total_skip:8d} {total_lost:8d}"
    )
    print()
    print("Interpretation: dCPI is an optimistic upper bound from eliminating")
    print("forced-single skip cycles only. It excludes timing, BP, load-use,")
    print("DCache, and finite FIFO fullness effects.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
