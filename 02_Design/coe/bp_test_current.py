#!/usr/bin/env python3
"""
Test current Tournament branch predictor accuracy against all COE programs.
Matches the RTL in branch_predictor.sv exactly:
  - BTB: 64-entry direct-mapped, 7-bit tag (PC[14:8]), idx=PC[7:2]
  - BHT: 2-bit saturating counter embedded in BTB entry (Bimodal)
  - GShare: 8-bit GHR XOR PC[9:2] → 256-entry PHT (2-bit)
  - Selector: 256-entry sel_table indexed by GHR (2-bit)
  - RAS: 4-deep stack
  - IF (L0): uses bht[1] for BRANCH direction (Bimodal fast path)
  - ID (L1): Tournament verification (Bimodal vs GShare via Selector)
  - EX: all state updates
"""
import os, sys, struct
from collections import defaultdict

# ==============================
# RV32I Simulator (same as bp_simulator.py)
# ==============================

def sign_ext(val, bits):
    if val & (1 << (bits - 1)):
        val -= (1 << bits)
    return val & 0xFFFFFFFF

def to_signed(val):
    val &= 0xFFFFFFFF
    if val & 0x80000000:
        return val - 0x100000000
    return val

class RV32ISim:
    TEXT_BASE = 0x80000000
    DRAM_BASE = 0x80100000
    DRAM_SIZE = 256 * 1024
    DRAM_END  = DRAM_BASE + DRAM_SIZE

    def __init__(self, irom_words, dram_words):
        self.regs = [0] * 32
        self.pc = self.TEXT_BASE
        self.irom = irom_words
        self.dram = bytearray(self.DRAM_SIZE)
        for i, w in enumerate(dram_words):
            addr = i * 4
            if addr + 4 <= self.DRAM_SIZE:
                struct.pack_into('<I', self.dram, addr, w)
        self.trace = []
        self.cycle_count = 0
        self.halted = False

    def read_reg(self, r): return self.regs[r] if r != 0 else 0
    def write_reg(self, r, val):
        if r != 0: self.regs[r] = val & 0xFFFFFFFF

    def fetch(self):
        offset = (self.pc - self.TEXT_BASE) >> 2
        if 0 <= offset < len(self.irom): return self.irom[offset]
        return 0

    def mem_read(self, addr, size):
        addr &= 0xFFFFFFFF
        if self.DRAM_BASE <= addr < self.DRAM_END:
            offset = addr - self.DRAM_BASE
            if offset + size > self.DRAM_SIZE: return 0
            if size == 1: return self.dram[offset]
            elif size == 2: return struct.unpack_from('<H', self.dram, offset)[0]
            elif size == 4: return struct.unpack_from('<I', self.dram, offset)[0]
        return 0

    def mem_write(self, addr, val, size):
        addr &= 0xFFFFFFFF
        if addr >= 0x80200000: return
        if not (self.DRAM_BASE <= addr < self.DRAM_END): return
        offset = addr - self.DRAM_BASE
        if offset + size > self.DRAM_SIZE: return
        if size == 1: self.dram[offset] = val & 0xFF
        elif size == 2: struct.pack_into('<H', self.dram, offset, val & 0xFFFF)
        elif size == 4: struct.pack_into('<I', self.dram, offset, val & 0xFFFFFFFF)

    def step(self):
        if self.halted: return False
        inst = self.fetch()
        opcode = inst & 0x7F
        rd  = (inst >> 7) & 0x1F
        f3  = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7  = (inst >> 25) & 0x7F
        next_pc = self.pc + 4

        if opcode == 0x37:  # LUI
            self.write_reg(rd, inst & 0xFFFFF000)
        elif opcode == 0x17:  # AUIPC
            self.write_reg(rd, (self.pc + to_signed(inst & 0xFFFFF000)) & 0xFFFFFFFF)
        elif opcode == 0x6F:  # JAL
            imm = (((inst>>31)&1)<<20 | ((inst>>12)&0xFF)<<12 | ((inst>>20)&1)<<11 | ((inst>>21)&0x3FF)<<1)
            imm = sign_ext(imm, 21) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            is_call = (rd == 1)
            self.trace.append((self.pc, 'CALL' if is_call else 'JAL', True, target, rd, 0))
            next_pc = target
        elif opcode == 0x67:  # JALR
            imm = sign_ext((inst >> 20) & 0xFFF, 12) & 0xFFFFFFFF
            base = self.read_reg(rs1)
            target = (to_signed(base) + to_signed(imm)) & 0xFFFFFFFE & 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            is_ret = (rs1 == 1 and rd == 0)
            is_call = (rd == 1)
            if is_ret:
                self.trace.append((self.pc, 'RET', True, target, rd, rs1))
            elif is_call:
                self.trace.append((self.pc, 'CALL', True, target, rd, rs1))
            else:
                self.trace.append((self.pc, 'JALR', True, target, rd, rs1))
            next_pc = target
        elif opcode == 0x63:  # B-type
            imm = (((inst>>31)&1)<<12 | ((inst>>7)&1)<<11 | ((inst>>25)&0x3F)<<5 | ((inst>>8)&0xF)<<1)
            imm = sign_ext(imm, 13) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            a, b = to_signed(self.read_reg(rs1)), to_signed(self.read_reg(rs2))
            ua, ub = self.read_reg(rs1), self.read_reg(rs2)
            taken = False
            if   f3==0: taken = (a==b)
            elif f3==1: taken = (a!=b)
            elif f3==4: taken = (a<b)
            elif f3==5: taken = (a>=b)
            elif f3==6: taken = (ua<ub)
            elif f3==7: taken = (ua>=ub)
            self.trace.append((self.pc, 'BRANCH', taken, target, 0, 0))
            if taken: next_pc = target
        elif opcode == 0x03:  # Load
            imm = sign_ext((inst>>20)&0xFFF, 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            if f3==0: val = sign_ext(self.mem_read(addr,1),8)&0xFFFFFFFF
            elif f3==1: val = sign_ext(self.mem_read(addr,2),16)&0xFFFFFFFF
            elif f3==2: val = self.mem_read(addr,4)
            elif f3==4: val = self.mem_read(addr,1)
            elif f3==5: val = self.mem_read(addr,2)
            else: val = 0
            self.write_reg(rd, val)
        elif opcode == 0x23:  # Store
            imm = sign_ext(((f7<<5)|rd), 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            val = self.read_reg(rs2)
            if f3==0: self.mem_write(addr, val, 1)
            elif f3==1: self.mem_write(addr, val, 2)
            elif f3==2: self.mem_write(addr, val, 4)
        elif opcode == 0x13:  # ALU-I
            imm_raw = (inst>>20)&0xFFF
            imm = sign_ext(imm_raw, 12) & 0xFFFFFFFF
            a = self.read_reg(rs1); shamt = imm_raw & 0x1F
            if   f3==0: res=(to_signed(a)+to_signed(imm))&0xFFFFFFFF
            elif f3==1: res=(a<<shamt)&0xFFFFFFFF
            elif f3==2: res=1 if to_signed(a)<to_signed(imm) else 0
            elif f3==3: res=1 if a<(imm&0xFFFFFFFF) else 0
            elif f3==4: res=(a^imm)&0xFFFFFFFF
            elif f3==5: res=(to_signed(a)>>shamt)&0xFFFFFFFF if f7&0x20 else (a>>shamt)&0xFFFFFFFF
            elif f3==6: res=(a|imm)&0xFFFFFFFF
            elif f3==7: res=(a&imm)&0xFFFFFFFF
            else: res=0
            self.write_reg(rd, res)
        elif opcode == 0x33:  # ALU-R
            a, b = self.read_reg(rs1), self.read_reg(rs2)
            if   f3==0: res=(to_signed(a)-to_signed(b))&0xFFFFFFFF if f7&0x20 else (to_signed(a)+to_signed(b))&0xFFFFFFFF
            elif f3==1: res=(a<<(b&0x1F))&0xFFFFFFFF
            elif f3==2: res=1 if to_signed(a)<to_signed(b) else 0
            elif f3==3: res=1 if a<b else 0
            elif f3==4: res=(a^b)&0xFFFFFFFF
            elif f3==5: res=(to_signed(a)>>(b&0x1F))&0xFFFFFFFF if f7&0x20 else (a>>(b&0x1F))&0xFFFFFFFF
            elif f3==6: res=(a|b)&0xFFFFFFFF
            elif f3==7: res=(a&b)&0xFFFFFFFF
            else: res=0
            self.write_reg(rd, res)
        elif opcode == 0x73:
            self.halted = True; return False

        if next_pc == self.pc:
            self.halted = True; return False
        self.pc = next_pc & 0xFFFFFFFF
        self.cycle_count += 1
        return True

    def run(self, max_cycles=2000000):
        while self.cycle_count < max_cycles and not self.halted:
            self.step()
        return self.trace

# ==============================
# Tournament BP Simulator (matches RTL exactly)
# ==============================

class TournamentBP:
    """
    Exact RTL match of branch_predictor.sv:
      BTB: 64-entry direct-mapped, tag=PC[14:8] (7 bits), idx=PC[7:2]
      BHT: 2-bit per BTB entry (Bimodal)
      GShare: GHR(8) XOR PC[9:2] → PHT[256] (2-bit)
      Selector: sel_table[256] indexed by GHR (2-bit)
      RAS: 4-deep shift stack
    """
    BTB_ENTRIES = 64
    BTB_IDX_W = 6
    BTB_TAG_W = 7
    GHR_W = 8
    PHT_SIZE = 256
    SEL_SIZE = 256
    RAS_DEPTH = 4

    TYPE_JAL = 0
    TYPE_CALL = 1
    TYPE_BRANCH = 2
    TYPE_RET = 3

    def __init__(self):
        # BTB
        self.btb_valid = [False] * self.BTB_ENTRIES
        self.btb_tag   = [0] * self.BTB_ENTRIES
        self.btb_tgt   = [0] * self.BTB_ENTRIES  # 30-bit (PC[31:2])
        self.btb_type  = [0] * self.BTB_ENTRIES
        self.btb_bht   = [0] * self.BTB_ENTRIES  # 2-bit Bimodal
        # GShare
        self.ghr = 0
        self.pht = [1] * self.PHT_SIZE  # initial: weakly not-taken
        # Selector
        self.sel_table = [1] * self.SEL_SIZE  # initial: weakly bimodal
        # RAS
        self.ras = [0] * self.RAS_DEPTH
        self.ras_count = 0
        # Stats
        self.stats = {
            'total': 0, 'correct': 0,
            'branch_total': 0, 'branch_correct': 0,
            'jal_total': 0, 'jal_correct': 0,
            'call_total': 0, 'call_correct': 0,
            'ret_total': 0, 'ret_correct': 0,
            'jalr_total': 0,
            'l0_branch_correct': 0,  # L0 (Bimodal bht[1]) accuracy
            'l1_branch_correct': 0,  # L1 (Tournament) accuracy
            'bimodal_correct': 0,
            'gshare_correct': 0,
            'selector_chose_bimodal': 0,
            'selector_chose_gshare': 0,
        }

    def _idx(self, pc): return (pc >> 2) & (self.BTB_ENTRIES - 1)
    def _tag(self, pc): return (pc >> 8) & ((1 << self.BTB_TAG_W) - 1)
    def _pht_idx(self, ghr, pc): return (ghr ^ ((pc >> 2) & 0xFF)) & (self.PHT_SIZE - 1)

    def predict_and_update(self, pc, itype, actual_taken, actual_target, rd, rs1):
        """Simulate one IF→(ID)→EX cycle."""

        # Non-RET JALR: not predictable by our BTB
        is_jalr_nr = (itype == 'JALR')
        if is_jalr_nr:
            self.stats['jalr_total'] += 1
            return  # always mispredicts, but we don't store in BTB

        self.stats['total'] += 1

        # ---- IF stage: L0 Prediction ----
        idx = self._idx(pc)
        tag = self._tag(pc)
        r_valid = self.btb_valid[idx]
        r_tag   = self.btb_tag[idx]
        r_tgt   = self.btb_tgt[idx]
        r_type  = self.btb_type[idx]
        r_bht   = self.btb_bht[idx]
        btb_hit = r_valid and (r_tag == tag)

        # GShare PHT read
        pht_idx = self._pht_idx(self.ghr, pc)
        pht_val = self.pht[pht_idx]

        # Selector read
        sel_val = self.sel_table[self.ghr & (self.SEL_SIZE - 1)]

        # RAS top
        ras_top = self.ras[0]
        ras_valid = (self.ras_count > 0)

        # L0 prediction (IF stage, uses bht[1] for BRANCH)
        l0_taken = False
        l0_target = pc + 4
        if btb_hit:
            if r_type == self.TYPE_JAL or r_type == self.TYPE_CALL:
                l0_taken = True
                l0_target = r_tgt << 2
            elif r_type == self.TYPE_BRANCH:
                l0_taken = (r_bht >> 1) & 1  # bht[1]
                l0_target = r_tgt << 2
            elif r_type == self.TYPE_RET:
                if ras_valid:
                    l0_taken = True
                    l0_target = ras_top

        # Snapshot for EX update
        snap_ghr = self.ghr
        snap_btb_hit = btb_hit
        snap_btb_bht = r_bht
        snap_pht_cnt = pht_val
        snap_sel_cnt = sel_val

        # ---- Evaluate L0 prediction ----
        l0_correct = False
        if actual_taken:
            l0_correct = (l0_taken and l0_target == actual_target)
        else:
            l0_correct = (not l0_taken)

        # ---- L1 Tournament (ID stage verification for BRANCH) ----
        # In RTL, ID stage does Tournament and may redirect if L0 was wrong
        # For accuracy counting, we check what Tournament would predict
        l1_taken = l0_taken  # default same as L0
        if btb_hit and r_type == self.TYPE_BRANCH:
            bimodal_pred = (r_bht >= 2)
            gshare_pred = (pht_val >= 2)
            # Selector: sel >= 2 → use bimodal, else gshare
            if sel_val >= 2:
                tournament_pred = bimodal_pred
                self.stats['selector_chose_bimodal'] += 1
            else:
                tournament_pred = gshare_pred
                self.stats['selector_chose_gshare'] += 1
            l1_taken = tournament_pred
            # Track individual predictor accuracy
            if bimodal_pred == actual_taken:
                self.stats['bimodal_correct'] += 1
            if gshare_pred == actual_taken:
                self.stats['gshare_correct'] += 1

        l1_correct = False
        if actual_taken:
            l1_correct = (l1_taken and l0_target == actual_target) if btb_hit else False
        else:
            l1_correct = (not l1_taken)

        # ---- Record stats ----
        # The actual prediction used by the CPU is L1 (Tournament) for BRANCH
        # and L0 for JAL/CALL/RET
        if itype == 'BRANCH':
            final_correct = l1_correct
            self.stats['branch_total'] += 1
            if l0_correct: self.stats['l0_branch_correct'] += 1
            if l1_correct:
                self.stats['l1_branch_correct'] += 1
                self.stats['branch_correct'] += 1
        elif itype == 'JAL':
            final_correct = l0_correct
            self.stats['jal_total'] += 1
            if l0_correct: self.stats['jal_correct'] += 1
        elif itype == 'CALL':
            final_correct = l0_correct
            self.stats['call_total'] += 1
            if l0_correct: self.stats['call_correct'] += 1
        elif itype == 'RET':
            final_correct = l0_correct
            self.stats['ret_total'] += 1
            if l0_correct: self.stats['ret_correct'] += 1
        else:
            final_correct = l0_correct

        if final_correct:
            self.stats['correct'] += 1

        # ---- EX stage: Update ----
        # Determine instruction classification (same as RTL)
        ex_is_branch = (itype == 'BRANCH')
        ex_is_jal = (itype in ('JAL', 'CALL'))
        ex_is_jalr = (itype in ('RET', 'JALR'))
        ex_is_call = (itype == 'CALL')
        ex_is_ret = (itype == 'RET')
        ex_is_jal_nc = ex_is_jal and not ex_is_call
        ex_is_jalr_nr = (itype == 'JALR')

        ex_update = (ex_is_branch or ex_is_jal or ex_is_jalr)

        # BTB write decision (mirrors RTL exactly)
        ex_btb_write = ex_update and (not ex_is_jalr_nr) and \
                       (ex_is_jal or ex_is_ret or
                        (ex_is_branch and (actual_taken or snap_btb_hit)))

        if ex_btb_write:
            # Type
            if ex_is_jal_nc:
                wr_type = self.TYPE_JAL
            elif ex_is_call:
                wr_type = self.TYPE_CALL
            elif ex_is_ret:
                wr_type = self.TYPE_RET
            else:
                wr_type = self.TYPE_BRANCH

            # BHT
            if ex_is_branch:
                if snap_btb_hit:
                    if actual_taken:
                        wr_bht = min(3, snap_btb_bht + 1)
                    else:
                        wr_bht = max(0, snap_btb_bht - 1)
                else:
                    wr_bht = 2 if actual_taken else 1
            else:
                wr_bht = 3

            self.btb_valid[idx] = True
            self.btb_tag[idx] = tag
            self.btb_tgt[idx] = actual_target >> 2
            self.btb_type[idx] = wr_type
            self.btb_bht[idx] = wr_bht

        # GShare PHT update (BRANCH only)
        if ex_is_branch:
            ex_pht_idx = self._pht_idx(snap_ghr, pc)
            if actual_taken:
                self.pht[ex_pht_idx] = min(3, snap_pht_cnt + 1)
            else:
                self.pht[ex_pht_idx] = max(0, snap_pht_cnt - 1)

        # GHR shift (BRANCH only)
        if ex_is_branch:
            self.ghr = ((self.ghr << 1) | (1 if actual_taken else 0)) & ((1 << self.GHR_W) - 1)

        # Selector update (BRANCH + BTB hit + bimodal != gshare)
        if ex_is_branch and snap_btb_hit:
            bimodal_pred = (snap_btb_bht >= 2)
            gshare_pred = (snap_pht_cnt >= 2)
            if bimodal_pred != gshare_pred:
                bimodal_ok = (bimodal_pred == actual_taken)
                ex_sel_idx = snap_ghr & (self.SEL_SIZE - 1)
                if bimodal_ok:
                    self.sel_table[ex_sel_idx] = min(3, snap_sel_cnt + 1)
                else:
                    self.sel_table[ex_sel_idx] = max(0, snap_sel_cnt - 1)

        # RAS update
        if ex_is_call:
            self.ras[3] = self.ras[2]
            self.ras[2] = self.ras[1]
            self.ras[1] = self.ras[0]
            self.ras[0] = pc + 4
            if self.ras_count < 4:
                self.ras_count += 1
        elif ex_is_ret:
            self.ras[0] = self.ras[1]
            self.ras[1] = self.ras[2]
            self.ras[2] = self.ras[3]
            self.ras[3] = 0
            if self.ras_count > 0:
                self.ras_count -= 1


def load_coe(filepath):
    words = []
    with open(filepath) as f:
        in_data = False
        for line in f:
            line = line.strip().rstrip(';').rstrip(',')
            if 'memory_initialization_vector' in line:
                parts = line.split('=')
                if len(parts) > 1 and parts[1].strip():
                    line = parts[1].strip().rstrip(';').rstrip(',')
                    if line:
                        words.append(int(line, 16))
                in_data = True
                continue
            if in_data and line:
                try: words.append(int(line, 16))
                except ValueError: pass
    return words


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    programs = ['current', 'src0', 'src1', 'src2']

    print("=" * 80)
    print(" Tournament Branch Predictor Accuracy Test")
    print(" (Matches branch_predictor.sv RTL exactly)")
    print("=" * 80)

    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if not os.path.exists(irom_path):
            print(f"\n  [{prog}] irom.coe not found, skipping.")
            continue

        print(f"\n{'─' * 80}")
        print(f"  Program: {prog}")
        print(f"{'─' * 80}")

        irom = load_coe(irom_path)
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []

        # Run ISA simulation
        sim = RV32ISim(irom, dram)
        trace = sim.run(max_cycles=5000000)

        # Count trace types
        type_cnt = defaultdict(int)
        branch_taken = 0
        for _, itype, taken, _, _, _ in trace:
            type_cnt[itype] += 1
            if itype == 'BRANCH' and taken:
                branch_taken += 1

        print(f"  Instructions executed: {sim.cycle_count:,}")
        print(f"  Branch/Jump trace:     {len(trace):,}")
        print(f"    BRANCH: {type_cnt['BRANCH']:,} (taken={branch_taken}, not-taken={type_cnt['BRANCH']-branch_taken})")
        print(f"    JAL:    {type_cnt['JAL']:,}")
        print(f"    CALL:   {type_cnt['CALL']:,}")
        print(f"    RET:    {type_cnt['RET']:,}")
        print(f"    JALR:   {type_cnt['JALR']:,}")

        # Run Tournament BP simulation
        bp = TournamentBP()
        for entry in trace:
            bp.predict_and_update(*entry)

        s = bp.stats
        total = s['total']
        if total == 0:
            print("  No predictable instructions, skipping.")
            continue

        # Overall
        overall_rate = s['correct'] / total * 100
        print(f"\n  ┌─────────────────────────────────────────────────────────┐")
        print(f"  │  Overall Prediction Accuracy:  {overall_rate:6.2f}%  ({s['correct']}/{total})  │")
        print(f"  └─────────────────────────────────────────────────────────┘")

        # Per-type breakdown
        print(f"\n  Per-type breakdown:")
        for label, tot_key, cor_key in [
            ('BRANCH', 'branch_total', 'branch_correct'),
            ('JAL',    'jal_total',    'jal_correct'),
            ('CALL',   'call_total',   'call_correct'),
            ('RET',    'ret_total',    'ret_correct'),
        ]:
            t = s[tot_key]
            c = s[cor_key]
            if t > 0:
                print(f"    {label:8s}: {c/t*100:6.2f}%  ({c}/{t})")

        # BRANCH: L0 vs L1 comparison
        bt = s['branch_total']
        if bt > 0:
            l0_rate = s['l0_branch_correct'] / bt * 100
            l1_rate = s['l1_branch_correct'] / bt * 100
            bim_chose = s['selector_chose_bimodal']
            gsh_chose = s['selector_chose_gshare']
            bim_cor = s['bimodal_correct']
            gsh_cor = s['gshare_correct']
            print(f"\n  BRANCH detail (L0 vs L1 Tournament):")
            print(f"    L0 (Bimodal bht[1]): {l0_rate:6.2f}%")
            print(f"    L1 (Tournament):     {l1_rate:6.2f}%  (improvement: {l1_rate-l0_rate:+.2f}%)")
            print(f"    Bimodal accuracy:    {bim_cor/bt*100:6.2f}%  (selected {bim_chose} times)")
            print(f"    GShare accuracy:     {gsh_cor/bt*100:6.2f}%  (selected {gsh_chose} times)")

        # CPI estimation (flush penalty = 3 cycles with delayed flush)
        FLUSH_PENALTY = 3  # MEM-stage flush: 3 cycles
        mispred = total - s['correct'] + s['jalr_total']  # JALR always mispredicts
        total_insts = sim.cycle_count
        penalty_cycles = mispred * FLUSH_PENALTY
        est_cpi = 1.0 + penalty_cycles / total_insts if total_insts else 1.0
        print(f"\n  CPI estimation (flush penalty={FLUSH_PENALTY} cycles):")
        print(f"    Mispredictions:  {mispred:,}")
        print(f"    Penalty cycles:  {penalty_cycles:,}")
        print(f"    Estimated CPI:   {est_cpi:.3f}")

    print(f"\n{'=' * 80}")
    print(" Done.")


if __name__ == '__main__':
    main()
