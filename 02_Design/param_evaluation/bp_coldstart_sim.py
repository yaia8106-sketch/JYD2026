#!/usr/bin/env python3
"""
Branch Predictor Cold-Start Accuracy Simulator
===============================================
Faithfully models the NLP Tournament branch predictor from branch_predictor.sv.
Runs ISA-level simulation of COE programs from power-on (cold predictor state).

Memory map (from perip_bridge.sv):
  IROM:  0x80000000 - ...         (instruction ROM)
  DRAM:  0x80100000 - 0x80140000  (256KB, single port BRAM)
  MMIO:  0x80200000+              (SW, KEY, SEG, LED, CNT)
"""

import struct
import sys
import os
from dataclasses import dataclass

# ============================================================
#  Constants
# ============================================================
TEXT_BASE  = 0x8000_0000
DRAM_BASE  = 0x8010_0000
DRAM_END   = 0x8014_0000   # exclusive
DRAM_SIZE  = DRAM_END - DRAM_BASE  # 256KB

# MMIO addresses
SW0_ADDR = 0x8020_0000
SW1_ADDR = 0x8020_0004
KEY_ADDR = 0x8020_0010
SEG_ADDR = 0x8020_0020
LED_ADDR = 0x8020_0040
CNT_ADDR = 0x8020_0050

# RV32I opcodes
OP_R_TYPE = 0b0110011
OP_I_ALU  = 0b0010011
OP_LOAD   = 0b0000011
OP_STORE  = 0b0100011
OP_BRANCH = 0b1100011
OP_LUI    = 0b0110111
OP_AUIPC  = 0b0010111
OP_JAL    = 0b1101111
OP_JALR   = 0b1100111

MAX_CYCLES = 10_000_000

# ============================================================
#  Utility
# ============================================================
def sext(val, bits):
    if val & (1 << (bits - 1)):
        val |= (~0) << bits
    return val & 0xFFFF_FFFF

def to_signed(val):
    val &= 0xFFFF_FFFF
    return val - 0x1_0000_0000 if val & 0x8000_0000 else val

# ============================================================
#  RV32I Decoder
# ============================================================
@dataclass
class DecodedInst:
    raw: int = 0; opcode: int = 0; rd: int = 0; rs1: int = 0; rs2: int = 0
    funct3: int = 0; funct7: int = 0; imm: int = 0
    is_branch: bool = False; is_jal: bool = False; is_jalr: bool = False
    is_load: bool = False; is_store: bool = False; reg_write: bool = False
    wb_sel: int = 0; mem_size: int = 0; mem_unsigned: bool = False
    alu_op: int = 0; alu_src1_sel: int = 0; alu_src2_sel: int = 0
    branch_cond: int = 0

def decode(w):
    d = DecodedInst()
    d.raw = w; d.opcode = w & 0x7F; d.rd = (w >> 7) & 0x1F
    d.rs1 = (w >> 15) & 0x1F; d.rs2 = (w >> 20) & 0x1F
    d.funct3 = (w >> 12) & 0x7; d.funct7 = (w >> 25) & 0x7F

    if d.opcode in (OP_I_ALU, OP_LOAD, OP_JALR):
        d.imm = sext(w >> 20, 12)
    elif d.opcode == OP_STORE:
        d.imm = sext(((w >> 25) << 5) | ((w >> 7) & 0x1F), 12)
    elif d.opcode == OP_BRANCH:
        d.imm = sext(((w >> 31) << 12) | (((w >> 7) & 1) << 11) |
                      (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13)
    elif d.opcode in (OP_LUI, OP_AUIPC):
        d.imm = w & 0xFFFFF000
    elif d.opcode == OP_JAL:
        d.imm = sext(((w >> 31) << 20) | (((w >> 12) & 0xFF) << 12) |
                      (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21)

    d.is_branch = (d.opcode == OP_BRANCH)
    d.is_jal = (d.opcode == OP_JAL)
    d.is_jalr = (d.opcode == OP_JALR)
    d.is_load = (d.opcode == OP_LOAD)
    d.is_store = (d.opcode == OP_STORE)

    if d.opcode == OP_R_TYPE:    d.reg_write=True;  d.wb_sel=0; d.alu_src1_sel=0; d.alu_src2_sel=0
    elif d.opcode == OP_I_ALU:   d.reg_write=True;  d.wb_sel=0; d.alu_src1_sel=0; d.alu_src2_sel=1
    elif d.opcode == OP_LOAD:    d.reg_write=True;  d.wb_sel=1; d.alu_src1_sel=0; d.alu_src2_sel=1
    elif d.opcode == OP_STORE:   d.reg_write=False; d.wb_sel=0; d.alu_src1_sel=0; d.alu_src2_sel=1
    elif d.opcode == OP_BRANCH:  d.reg_write=False; d.wb_sel=0; d.alu_src1_sel=1; d.alu_src2_sel=1
    elif d.opcode == OP_LUI:     d.reg_write=True;  d.wb_sel=0; d.alu_src1_sel=2; d.alu_src2_sel=1
    elif d.opcode == OP_AUIPC:   d.reg_write=True;  d.wb_sel=0; d.alu_src1_sel=1; d.alu_src2_sel=1
    elif d.opcode == OP_JAL:     d.reg_write=True;  d.wb_sel=2; d.alu_src1_sel=1; d.alu_src2_sel=1
    elif d.opcode == OP_JALR:    d.reg_write=True;  d.wb_sel=2; d.alu_src1_sel=0; d.alu_src2_sel=1

    is_alu = d.opcode in (OP_R_TYPE, OP_I_ALU)
    use_f7 = (d.opcode == OP_R_TYPE) or (d.opcode == OP_I_ALU and d.funct3 == 0b101)
    d.alu_op = (((d.funct7 >> 5) & 1 if use_f7 else 0) << 3) | d.funct3 if is_alu else 0
    d.branch_cond = d.funct3; d.mem_size = d.funct3 & 3; d.mem_unsigned = bool(d.funct3 & 4)
    return d

# ============================================================
#  ALU
# ============================================================
def alu_exec(op, s1, s2):
    s1 &= 0xFFFF_FFFF; s2 &= 0xFFFF_FFFF; sh = s2 & 0x1F
    if op == 0b0000: return (s1 + s2) & 0xFFFF_FFFF
    if op == 0b1000: return (s1 - s2) & 0xFFFF_FFFF
    if op == 0b0001: return (s1 << sh) & 0xFFFF_FFFF
    if op == 0b0010: return 1 if to_signed(s1) < to_signed(s2) else 0
    if op == 0b0011: return 1 if s1 < s2 else 0
    if op == 0b0100: return s1 ^ s2
    if op == 0b0101: return s1 >> sh
    if op == 0b1101: return (to_signed(s1) >> sh) & 0xFFFF_FFFF
    if op == 0b0110: return s1 | s2
    if op == 0b0111: return s1 & s2
    return 0

def eval_branch(cond, r1, r2):
    r1 &= 0xFFFF_FFFF; r2 &= 0xFFFF_FFFF
    if cond == 0b000: return r1 == r2
    if cond == 0b001: return r1 != r2
    if cond == 0b100: return to_signed(r1) < to_signed(r2)
    if cond == 0b101: return to_signed(r1) >= to_signed(r2)
    if cond == 0b110: return r1 < r2
    if cond == 0b111: return r1 >= r2
    return False

# ============================================================
#  Branch Predictor (exact RTL model)
# ============================================================
class BranchPredictor:
    BTB_N = 64; TAG_W = 7; GHR_W = 8; PHT_N = 256; RAS_D = 4
    JAL=0; CALL=1; BR=2; RET=3

    def __init__(self):
        self.btb_v = [False]*64; self.btb_tag = [0]*64
        self.btb_tgt = [0]*64; self.btb_type = [0]*64; self.btb_bht = [0]*64
        self.ghr = 0; self.pht = [1]*256; self.sel = [1]*256
        self.ras = [0]*4; self.ras_cnt = 0

    def _ix(self, pc): return (pc >> 2) & 63
    def _tg(self, pc): return (pc >> 8) & 127

    def predict(self, pc):
        ix = self._ix(pc); tg = self._tg(pc)
        hit = self.btb_v[ix] and self.btb_tag[ix] == tg
        r_tgt = self.btb_tgt[ix]; r_type = self.btb_type[ix]; r_bht = self.btb_bht[ix]
        pi = (self.ghr ^ ((pc >> 2) & 0xFF)) & 0xFF
        snap = {'ghr': self.ghr, 'hit': hit, 'type': r_type if hit else 0,
                'bht': r_bht, 'pht': self.pht[pi], 'sel': self.sel[self.ghr & 0xFF]}
        taken = False; target = (pc + 4) & 0xFFFF_FFFF
        if hit:
            if r_type in (self.JAL, self.CALL):
                taken = True; target = (r_tgt << 2) & 0xFFFF_FFFF
            elif r_type == self.BR:
                taken = bool(r_bht >> 1); target = (r_tgt << 2) & 0xFFFF_FFFF
            elif r_type == self.RET:
                if self.ras_cnt > 0:
                    taken = True; target = self.ras[0]
        return taken, target, snap

    def update(self, pc, is_br, is_jal, is_jalr, rd, rs1, actual_taken, actual_target, snap):
        is_call = is_jal and rd == 1; is_jnc = is_jal and rd != 1
        is_ret = is_jalr and rs1 == 1 and rd == 0; is_jnr = is_jalr and not is_ret
        if not (is_br or is_jal or is_jalr): return
        ix = self._ix(pc); tg = self._tg(pc)
        bh = snap['hit']; bb = snap['bht']; pp = snap['pht']; ss = snap['sel']; gg = snap['ghr']

        # BTB write
        btb_wr = (not is_jnr) and (is_jal or is_ret or (is_br and (actual_taken or bh)))
        if btb_wr:
            ty = self.JAL if is_jnc else (self.CALL if is_call else (self.RET if is_ret else self.BR))
            if is_br:
                nb = (min(bb+1,3) if actual_taken else max(bb-1,0)) if bh else (2 if actual_taken else 1)
            else:
                nb = 3
            self.btb_v[ix]=True; self.btb_tag[ix]=tg
            self.btb_tgt[ix]=(actual_target>>2)&0x3FFFFFFF; self.btb_type[ix]=ty; self.btb_bht[ix]=nb

        # GShare + GHR
        if is_br:
            pi = (gg ^ ((pc >> 2) & 0xFF)) & 0xFF
            self.pht[pi] = min(pp+1,3) if actual_taken else max(pp-1,0)
            self.ghr = ((self.ghr << 1) | (1 if actual_taken else 0)) & 0xFF

        # Selector
        if is_br and bh:
            bp_b = (bb >= 2); bp_g = (pp >= 2)
            if bp_b != bp_g:
                si = gg & 0xFF
                self.sel[si] = min(ss+1,3) if (bp_b == actual_taken) else max(ss-1,0)

        # RAS
        if is_call:
            for i in range(3,0,-1): self.ras[i] = self.ras[i-1]
            self.ras[0] = (pc + 4) & 0xFFFF_FFFF
            self.ras_cnt = min(self.ras_cnt + 1, 4)
        elif is_ret:
            for i in range(3): self.ras[i] = self.ras[i+1]
            self.ras[3] = 0
            self.ras_cnt = max(self.ras_cnt - 1, 0)

# ============================================================
#  Memory
# ============================================================
class Memory:
    def __init__(self):
        self.irom = {}
        self.dram = bytearray(DRAM_SIZE)

    def load_irom_coe(self, path):
        with open(path) as f: lines = f.readlines()
        started = False; addr = TEXT_BASE
        for line in lines:
            line = line.strip().rstrip(';').rstrip(',')
            if 'memory_initialization_vector' in line: started = True; continue
            if not started or 'radix' in line or not line: continue
            self.irom[addr] = int(line, 16); addr += 4

    def load_dram_coe(self, path):
        with open(path) as f: lines = f.readlines()
        started = False; offset = 0
        for line in lines:
            line = line.strip().rstrip(';').rstrip(',')
            if 'memory_initialization_vector' in line: started = True; continue
            if not started or 'radix' in line or not line: continue
            if offset + 3 < DRAM_SIZE:
                # COE uses big-endian hex, BRAM stores as little-endian words
                struct.pack_into('<I', self.dram, offset, int(line, 16))
            offset += 4

    def fetch(self, pc): return self.irom.get(pc & 0xFFFF_FFFF, 0)

    def _dram_off(self, addr):
        a = addr & 0xFFFF_FFFF
        if DRAM_BASE <= a < DRAM_END: return a - DRAM_BASE
        return None

    def load_mem(self, addr, size, unsigned):
        off = self._dram_off(addr)
        if off is None: return 0  # MMIO read → 0 (simplified)
        if size == 0:
            v = self.dram[off]
            return v if unsigned or not (v & 0x80) else (v | 0xFFFFFF00) & 0xFFFF_FFFF
        elif size == 1:
            v = struct.unpack_from('<H', self.dram, off & ~1)[0]
            return v if unsigned or not (v & 0x8000) else (v | 0xFFFF0000) & 0xFFFF_FFFF
        else:
            return struct.unpack_from('<I', self.dram, off & ~3)[0]

    def store_mem(self, addr, val, size):
        off = self._dram_off(addr)
        if off is None: return  # MMIO write (ignored)
        if size == 0: self.dram[off] = val & 0xFF
        elif size == 1: struct.pack_into('<H', self.dram, off & ~1, val & 0xFFFF)
        else: struct.pack_into('<I', self.dram, off & ~3, val & 0xFFFF_FFFF)

# ============================================================
#  Stats
# ============================================================
@dataclass
class Stats:
    total_branches: int = 0; correct_branches: int = 0
    total_jal: int = 0;     correct_jal: int = 0
    total_call: int = 0;    correct_call: int = 0
    total_ret: int = 0;     correct_ret: int = 0
    total_jalr: int = 0;    correct_jalr: int = 0
    total_cycles: int = 0;  flush_cycles: int = 0

# ============================================================
#  Simulator
# ============================================================
def simulate(irom_path, dram_path, max_cycles=MAX_CYCLES):
    mem = Memory()
    mem.load_irom_coe(irom_path)
    mem.load_dram_coe(dram_path)
    bp = BranchPredictor()
    regs = [0] * 32
    # SP init: top of DRAM area
    regs[2] = DRAM_END  # 0x80140000 (stack grows down into DRAM)
    pc = TEXT_BASE
    stats = Stats()

    for cycle in range(max_cycles):
        stats.total_cycles = cycle + 1
        inst_word = mem.fetch(pc)
        if inst_word == 0: break
        d = decode(inst_word)

        # Predict
        pred_taken, pred_target, snap = bp.predict(pc)

        # Execute
        rs1v = regs[d.rs1] if d.rs1 else 0
        rs2v = regs[d.rs2] if d.rs2 else 0
        src1 = rs1v if d.alu_src1_sel == 0 else (pc if d.alu_src1_sel == 1 else 0)
        src2 = d.imm if d.alu_src2_sel else rs2v
        alu_r = alu_exec(d.alu_op, src1, src2)

        # Branch/Jump resolution
        actual_taken = False; actual_target = (pc + 4) & 0xFFFF_FFFF
        if d.is_jal:    actual_taken = True; actual_target = alu_r
        elif d.is_jalr: actual_taken = True; actual_target = alu_r & ~1
        elif d.is_branch:
            taken = eval_branch(d.branch_cond, rs1v, rs2v)
            actual_taken = taken
            actual_target = alu_r if taken else (pc + 4) & 0xFFFF_FFFF

        # Misprediction
        is_call = d.is_jal and d.rd == 1
        is_ret = d.is_jalr and d.rs1 == 1 and d.rd == 0
        is_jnc = d.is_jal and d.rd != 1
        misp = False
        if d.is_branch or d.is_jal or d.is_jalr:
            dw = (actual_taken != pred_taken)
            tw = actual_taken and pred_taken and (actual_target != pred_target)
            misp = dw or tw

        if d.is_branch:
            stats.total_branches += 1
            if not misp: stats.correct_branches += 1
        if is_call:
            stats.total_call += 1
            if not misp: stats.correct_call += 1
        elif is_jnc:
            stats.total_jal += 1
            if not misp: stats.correct_jal += 1
        if is_ret:
            stats.total_ret += 1
            if not misp: stats.correct_ret += 1
        elif d.is_jalr and not is_ret:
            stats.total_jalr += 1
            if not misp: stats.correct_jalr += 1

        if misp: stats.flush_cycles += 2

        # Update predictor
        at = actual_target if actual_taken else (pc + 4) & 0xFFFF_FFFF
        bp.update(pc, d.is_branch, d.is_jal, d.is_jalr, d.rd, d.rs1, actual_taken, at, snap)

        # Memory
        load_val = 0
        if d.is_load:   load_val = mem.load_mem(alu_r, d.mem_size, d.mem_unsigned)
        elif d.is_store: mem.store_mem(alu_r, rs2v, d.mem_size)

        # Write-back
        if d.reg_write and d.rd:
            if d.wb_sel == 0:   regs[d.rd] = alu_r & 0xFFFF_FFFF
            elif d.wb_sel == 1: regs[d.rd] = load_val & 0xFFFF_FFFF
            elif d.wb_sel == 2: regs[d.rd] = (pc + 4) & 0xFFFF_FFFF

        # Next PC
        next_pc = actual_target if actual_taken else (pc + 4) & 0xFFFF_FFFF
        if next_pc == pc: break  # infinite loop = halt
        pc = next_pc

    return stats

# ============================================================
#  Main
# ============================================================
def find_programs(coe_dir):
    progs = []
    for name in sorted(os.listdir(coe_dir)):
        d = os.path.join(coe_dir, name)
        if os.path.isdir(d):
            ir = os.path.join(d, 'irom.coe'); dr = os.path.join(d, 'dram.coe')
            if os.path.exists(ir) and os.path.exists(dr): progs.append((name, ir, dr))
    return progs

def print_stats(name, s):
    tc = s.total_branches + s.total_jal + s.total_call + s.total_ret + s.total_jalr
    cc = s.correct_branches + s.correct_jal + s.correct_call + s.correct_ret + s.correct_jalr
    rate = cc / tc * 100 if tc else 0

    print(f"\n{'='*64}")
    print(f"  Program: {name}")
    print(f"{'='*64}")
    print(f"  Total instructions executed: {s.total_cycles:>12,}")
    print(f"  Flush penalty (2 cyc each):  {s.flush_cycles:>12,}")
    print(f"  {'':32s} {'Total':>8s}  {'Correct':>8s}  {'Rate':>8s}")
    print(f"  {'─'*58}")

    def row(lb, t, c):
        r = f"{c/t*100:.1f}%" if t else "N/A"
        print(f"  {lb:32s} {t:>8,}  {c:>8,}  {r:>8s}")

    row("Conditional branches", s.total_branches, s.correct_branches)
    row("JAL (non-call)", s.total_jal, s.correct_jal)
    row("CALL (JAL rd=ra)", s.total_call, s.correct_call)
    row("RET (JALR rs1=ra, rd=x0)", s.total_ret, s.correct_ret)
    row("JALR (other)", s.total_jalr, s.correct_jalr)
    print(f"  {'─'*58}")
    row("OVERALL", tc, cc)

    if s.total_cycles:
        cpi = 1.0 + s.flush_cycles / s.total_cycles
        print(f"\n  Estimated CPI (branch-only): {cpi:.4f}")
        print(f"  Misprediction penalty:       {s.flush_cycles:,} cycles ({s.flush_cycles/s.total_cycles*100:.2f}%)")

def main():
    coe_dir = "/home/anokyai/桌面/CPU_Workspace/02_Design/coe"
    programs = find_programs(coe_dir)
    if not programs: print("No programs found!"); return

    print(f"Found {len(programs)} programs: {[p[0] for p in programs]}")
    print("Simulating with cold-start (all predictor state reset per program)...\n")

    all_stats = []
    for name, irom, dram in programs:
        print(f"Running {name}...", end=" ", flush=True)
        s = simulate(irom, dram)
        print(f"done ({s.total_cycles:,} instructions)")
        all_stats.append((name, s))

    for name, s in all_stats:
        print_stats(name, s)

    print(f"\n\n{'='*74}")
    print(f"  SUMMARY TABLE (cold start)")
    print(f"{'='*74}")
    print(f"  {'Program':10s} {'Insts':>10s} {'Branch':>8s} {'JAL':>6s} {'CALL':>6s} {'RET':>6s} {'JALR':>6s} {'Overall':>8s} {'CPI':>6s}")
    print(f"  {'─'*72}")
    for name, s in all_stats:
        tc = s.total_branches + s.total_jal + s.total_call + s.total_ret + s.total_jalr
        cc = s.correct_branches + s.correct_jal + s.correct_call + s.correct_ret + s.correct_jalr
        def r(t,c): return f"{c/t*100:.1f}" if t else "N/A"
        overall = f"{cc/tc*100:.1f}" if tc else "N/A"
        cpi = f"{1.0+s.flush_cycles/s.total_cycles:.3f}" if s.total_cycles else "N/A"
        print(f"  {name:10s} {s.total_cycles:>10,} {r(s.total_branches,s.correct_branches):>7s}% "
              f"{r(s.total_jal,s.correct_jal):>5s}% {r(s.total_call,s.correct_call):>5s}% "
              f"{r(s.total_ret,s.correct_ret):>5s}% {r(s.total_jalr,s.correct_jalr):>5s}% "
              f"{overall:>7s}% {cpi:>6s}")

if __name__ == "__main__":
    main()
