#!/usr/bin/env python3
"""
Branch Predictor Configuration Sweep.

Sweeps BTB size, GHR width, and RAS depth across all contest programs.
Reuses ISA trace (collected once) and replays through each BP config.

Models the Tournament BP architecture from branch_predictor.sv:
  - BTB: direct-mapped, TAG_W=5, variable entries
  - BHT: 2-bit per BTB entry (Bimodal)
  - GShare: variable GHR XOR PC → variable PHT (2-bit)
  - Selector: variable sel_table indexed by GHR (2-bit)
  - RAS: variable depth shift stack
  - IF (L0): bht[1] for BRANCH direction
  - ID (L1): Tournament (Bimodal vs GShare via Selector)
  - EX: all state updates
"""
import os, sys, struct
from collections import defaultdict
import time
from multiprocessing import Pool, cpu_count

# ==============================
# RV32I Simulator (trace collection)
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
            # Match RTL: only JAL can be CALL, JALR with rd=1 is non-RET JALR
            is_ret = (rs1 == 1 and rd == 0)
            if is_ret:
                self.trace.append((self.pc, 'RET', True, target, rd, rs1))
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

    def run(self, max_cycles=5000000):
        while self.cycle_count < max_cycles and not self.halted:
            self.step()
        return self.trace


# ==============================
# Parameterizable Tournament BP
# ==============================

class TournamentBP:
    """Parameterizable Tournament Branch Predictor.

    Architecture matches branch_predictor.sv structure:
      BTB: direct-mapped, TAG_W bits of tag
      BHT: 2-bit per BTB entry (Bimodal)
      GShare: GHR(ghr_w) XOR PC → PHT (2-bit)
      Selector: sel_table indexed by GHR (2-bit)
      RAS: shift stack of configurable depth
    """

    TYPE_JAL = 0
    TYPE_CALL = 1
    TYPE_BRANCH = 2
    TYPE_RET = 3

    def __init__(self, btb_entries=64, btb_tag_w=5, ghr_w=8, ras_depth=4):
        self.btb_entries = btb_entries
        self.btb_idx_w = (btb_entries - 1).bit_length()
        self.btb_tag_w = btb_tag_w
        self.ghr_w = ghr_w
        self.pht_size = 1 << ghr_w
        self.sel_size = 1 << ghr_w
        self.ras_depth = ras_depth

        # BTB
        self.btb_valid = [False] * btb_entries
        self.btb_tag   = [0] * btb_entries
        self.btb_tgt   = [0] * btb_entries
        self.btb_type  = [0] * btb_entries
        self.btb_bht   = [0] * btb_entries
        # GShare
        self.ghr = 0
        self.pht = [1] * self.pht_size
        # Selector
        self.sel_table = [1] * self.sel_size
        # RAS
        self.ras = [0] * ras_depth
        self.ras_count = 0

        # Counters
        self.total = 0
        self.correct = 0
        self.branch_total = 0
        self.branch_correct = 0
        self.jal_total = 0
        self.jal_correct = 0
        self.call_total = 0
        self.call_correct = 0
        self.ret_total = 0
        self.ret_correct = 0
        self.jalr_total = 0
        # BRANCH sub-counters
        self.l0_branch_correct = 0
        self.l1_branch_correct = 0
        self.bimodal_correct = 0
        self.gshare_correct = 0
        self.selector_chose_bimodal = 0
        self.selector_chose_gshare = 0
        # Misprediction breakdown
        self.br_btb_miss_taken = 0
        self.br_btb_miss_nt = 0
        self.br_dir_wrong = 0
        self.br_tgt_wrong = 0
        self.br_btb_hit_correct = 0

    def _idx(self, pc):
        return (pc >> 2) & (self.btb_entries - 1)

    def _tag(self, pc):
        return (pc >> (2 + self.btb_idx_w)) & ((1 << self.btb_tag_w) - 1)

    def _pht_idx(self, ghr, pc):
        pc_bits = (pc >> 2) & ((1 << self.ghr_w) - 1)
        return (ghr ^ pc_bits) & (self.pht_size - 1)

    def run_trace(self, trace):
        """Process entire trace in one call (optimized: local var caching)."""
        # Cache all state as locals for speed
        btb_valid = self.btb_valid
        btb_tag_a = self.btb_tag
        btb_tgt_a = self.btb_tgt
        btb_type_a = self.btb_type
        btb_bht_a = self.btb_bht
        pht = self.pht
        sel_table = self.sel_table
        ras = self.ras
        ghr = self.ghr
        ras_count = self.ras_count

        btb_mask = self.btb_entries - 1
        tag_shift = 2 + self.btb_idx_w
        tag_mask = (1 << self.btb_tag_w) - 1
        ghr_w = self.ghr_w
        ghr_mask = (1 << ghr_w) - 1
        pht_mask = self.pht_size - 1
        sel_mask = self.sel_size - 1
        ras_depth = self.ras_depth

        T_JAL = 0; T_CALL = 1; T_BRANCH = 2; T_RET = 3

        # Counters as locals
        total = 0; correct = 0
        branch_total = 0; branch_correct = 0
        jal_total = 0; jal_correct = 0
        call_total = 0; call_correct = 0
        ret_total = 0; ret_correct = 0
        jalr_total = 0
        l0_branch_correct = 0; l1_branch_correct = 0
        bimodal_correct_cnt = 0; gshare_correct_cnt = 0
        sel_chose_bim = 0; sel_chose_gsh = 0
        br_btb_miss_taken = 0; br_btb_miss_nt = 0
        br_dir_wrong = 0; br_tgt_wrong = 0; br_btb_hit_correct = 0

        for pc, itype, actual_taken, actual_target, rd, rs1 in trace:
            if itype == 'JALR':
                jalr_total += 1
                continue

            total += 1

            # IF: L0 prediction
            idx = (pc >> 2) & btb_mask
            tag = (pc >> tag_shift) & tag_mask
            btb_hit = btb_valid[idx] and (btb_tag_a[idx] == tag)

            pht_idx = (ghr ^ ((pc >> 2) & ghr_mask)) & pht_mask
            pht_val = pht[pht_idx]
            sel_val = sel_table[ghr & sel_mask]

            l0_taken = False
            l0_target = pc + 4
            if btb_hit:
                r_type = btb_type_a[idx]
                r_bht = btb_bht_a[idx]
                r_tgt = btb_tgt_a[idx]
                if r_type == T_JAL or r_type == T_CALL:
                    l0_taken = True
                    l0_target = r_tgt << 2
                elif r_type == T_BRANCH:
                    l0_taken = (r_bht >> 1) & 1
                    l0_target = r_tgt << 2
                elif r_type == T_RET:
                    if ras_count > 0 and ras_depth > 0:
                        l0_taken = True
                        l0_target = ras[0]
            else:
                r_bht = 0

            snap_ghr = ghr
            snap_btb_hit = btb_hit
            snap_btb_bht = r_bht
            snap_pht_cnt = pht_val
            snap_sel_cnt = sel_val

            # Evaluate L0
            if actual_taken:
                l0_correct = (l0_taken and l0_target == actual_target)
            else:
                l0_correct = (not l0_taken)

            # ID: L1 Tournament (BRANCH only)
            l1_taken = l0_taken
            if btb_hit and btb_type_a[idx] == T_BRANCH:
                bimodal_pred = (r_bht >= 2)
                gshare_pred = (pht_val >= 2)
                if sel_val >= 2:
                    l1_taken = bimodal_pred
                    sel_chose_bim += 1
                else:
                    l1_taken = gshare_pred
                    sel_chose_gsh += 1
                if bimodal_pred == actual_taken:
                    bimodal_correct_cnt += 1
                if gshare_pred == actual_taken:
                    gshare_correct_cnt += 1

            # Evaluate final prediction
            if itype == 'BRANCH':
                branch_total += 1
                if l0_correct: l0_branch_correct += 1
                if actual_taken:
                    l1_correct = btb_hit and l1_taken and l0_target == actual_target
                else:
                    l1_correct = not l1_taken
                if l1_correct:
                    l1_branch_correct += 1
                    branch_correct += 1
                    correct += 1
                # Misprediction breakdown
                if not btb_hit:
                    if actual_taken: br_btb_miss_taken += 1
                    else: br_btb_miss_nt += 1
                else:
                    if l1_taken != actual_taken: br_dir_wrong += 1
                    elif l1_taken and l0_target != actual_target: br_tgt_wrong += 1
                    else: br_btb_hit_correct += 1
            elif itype == 'JAL':
                jal_total += 1
                if l0_correct: jal_correct += 1; correct += 1
            elif itype == 'CALL':
                call_total += 1
                if l0_correct: call_correct += 1; correct += 1
            elif itype == 'RET':
                ret_total += 1
                if l0_correct: ret_correct += 1; correct += 1
            else:
                if l0_correct: correct += 1

            # EX: Update state
            is_branch = (itype == 'BRANCH')
            is_jal = (itype in ('JAL', 'CALL'))
            is_call = (itype == 'CALL')
            is_ret = (itype == 'RET')

            # BTB write
            do_btb_write = (is_jal or is_ret or
                            (is_branch and (actual_taken or snap_btb_hit)))
            if do_btb_write:
                if is_jal and not is_call:   wr_type = T_JAL
                elif is_call:               wr_type = T_CALL
                elif is_ret:                wr_type = T_RET
                else:                       wr_type = T_BRANCH

                if is_branch:
                    if snap_btb_hit:
                        wr_bht = min(3, snap_btb_bht + 1) if actual_taken else max(0, snap_btb_bht - 1)
                    else:
                        wr_bht = 2 if actual_taken else 1
                else:
                    wr_bht = 3

                btb_valid[idx] = True
                btb_tag_a[idx] = tag
                btb_tgt_a[idx] = actual_target >> 2
                btb_type_a[idx] = wr_type
                btb_bht_a[idx] = wr_bht

            # GShare PHT + GHR + Selector
            if is_branch:
                ex_pht_idx = (snap_ghr ^ ((pc >> 2) & ghr_mask)) & pht_mask
                pht[ex_pht_idx] = min(3, snap_pht_cnt + 1) if actual_taken else max(0, snap_pht_cnt - 1)
                ghr = ((ghr << 1) | (1 if actual_taken else 0)) & ghr_mask

                if snap_btb_hit:
                    bimodal_pred = (snap_btb_bht >= 2)
                    gshare_pred = (snap_pht_cnt >= 2)
                    if bimodal_pred != gshare_pred:
                        ex_sel_idx = snap_ghr & sel_mask
                        if bimodal_pred == actual_taken:
                            sel_table[ex_sel_idx] = min(3, snap_sel_cnt + 1)
                        else:
                            sel_table[ex_sel_idx] = max(0, snap_sel_cnt - 1)

            # RAS
            if is_call and ras_depth > 0:
                for i in range(ras_depth - 1, 0, -1):
                    ras[i] = ras[i-1]
                ras[0] = pc + 4
                if ras_count < ras_depth: ras_count += 1
            elif is_ret and ras_depth > 0:
                for i in range(ras_depth - 1):
                    ras[i] = ras[i+1]
                ras[ras_depth - 1] = 0
                if ras_count > 0: ras_count -= 1

        # Write back to self
        self.ghr = ghr
        self.ras_count = ras_count
        self.total = total; self.correct = correct
        self.branch_total = branch_total; self.branch_correct = branch_correct
        self.jal_total = jal_total; self.jal_correct = jal_correct
        self.call_total = call_total; self.call_correct = call_correct
        self.ret_total = ret_total; self.ret_correct = ret_correct
        self.jalr_total = jalr_total
        self.l0_branch_correct = l0_branch_correct
        self.l1_branch_correct = l1_branch_correct
        self.bimodal_correct = bimodal_correct_cnt
        self.gshare_correct = gshare_correct_cnt
        self.selector_chose_bimodal = sel_chose_bim
        self.selector_chose_gshare = sel_chose_gsh
        self.br_btb_miss_taken = br_btb_miss_taken
        self.br_btb_miss_nt = br_btb_miss_nt
        self.br_dir_wrong = br_dir_wrong
        self.br_tgt_wrong = br_tgt_wrong
        self.br_btb_hit_correct = br_btb_hit_correct


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


def eval_bp(trace, total_insts, btb_entries, btb_tag_w, ghr_w, ras_depth):
    """Evaluate one BP config against a trace. Returns result dict."""
    bp = TournamentBP(btb_entries=btb_entries, btb_tag_w=btb_tag_w,
                       ghr_w=ghr_w, ras_depth=ras_depth)
    bp.run_trace(trace)

    total = bp.total
    if total == 0:
        return None

    mispred = total - bp.correct + bp.jalr_total
    FLUSH_PENALTY = 3
    penalty_cycles = mispred * FLUSH_PENALTY
    est_cpi = 1.0 + penalty_cycles / total_insts if total_insts else 1.0

    bt = bp.branch_total
    branch_acc = bp.branch_correct / bt * 100 if bt else 0
    call_acc = bp.call_correct / bp.call_total * 100 if bp.call_total else 100
    ret_acc = bp.ret_correct / bp.ret_total * 100 if bp.ret_total else 100
    overall_acc = bp.correct / total * 100

    l0_br_acc = bp.l0_branch_correct / bt * 100 if bt else 0
    l1_br_acc = bp.l1_branch_correct / bt * 100 if bt else 0

    # Resource estimate (LUTRAM bits)
    btb_bits = btb_entries * (1 + btb_tag_w + 30 + 2 + 2)  # valid+tag+target+type+bht
    pht_bits = (1 << ghr_w) * 2
    sel_bits = (1 << ghr_w) * 2
    ras_bits = ras_depth * 32
    total_bits = btb_bits + pht_bits + sel_bits + ras_bits + ghr_w

    return {
        'overall_acc': overall_acc,
        'branch_acc': branch_acc,
        'call_acc': call_acc,
        'ret_acc': ret_acc,
        'l0_br_acc': l0_br_acc,
        'l1_br_acc': l1_br_acc,
        'mispred': mispred,
        'penalty_cycles': penalty_cycles,
        'cpi': est_cpi,
        'total_bits': total_bits,
        'btb_miss_taken': bp.br_btb_miss_taken,
        'btb_miss_nt': bp.br_btb_miss_nt,
        'dir_wrong': bp.br_dir_wrong,
        'tgt_wrong': bp.br_tgt_wrong,
        'bimodal_correct': bp.bimodal_correct,
        'gshare_correct': bp.gshare_correct,
        'branch_total': bt,
        'jalr_total': bp.jalr_total,
    }


def _collect_trace_worker(args):
    """Worker for parallel trace collection."""
    prog, irom_path, dram_path = args
    irom = load_coe(irom_path)
    dram = load_coe(dram_path) if os.path.exists(dram_path) else []
    sim = RV32ISim(irom, dram)
    trace = sim.run(max_cycles=5000000)
    return prog, trace, sim.cycle_count


def _eval_bp_worker(args):
    """Worker for parallel BP evaluation."""
    key, trace, total_insts, btb, tag_w, ghr, ras = args
    r = eval_bp(trace, total_insts, btb, tag_w, ghr, ras)
    return key, r


def main():
    NPROC = min(24, cpu_count())
    base = os.path.dirname(os.path.abspath(__file__))
    programs = ['current', 'src0', 'src1', 'src2']

    # Sweep parameters
    btb_sizes = [32, 64, 128, 256]
    ghr_widths = [4, 6, 8, 10, 12, 14]
    ras_depths = [2, 4, 8, 16]
    BTB_TAG_W = 5
    FIXED_RAS = 4
    CURRENT = (64, 8, 4)  # (btb, ghr, ras)
    FLUSH_PENALTY = 3

    print("=" * 120)
    print(f" Tournament Branch Predictor Configuration Sweep  (using {NPROC} cores)")
    print(" (Architecture matches branch_predictor.sv)")
    print("=" * 120)

    # ── Collect traces in parallel ──
    t0_all = time.time()
    trace_args = []
    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if os.path.exists(irom_path):
            trace_args.append((prog, irom_path, dram_path))

    print(f"  Collecting traces ({len(trace_args)} programs) in parallel...", flush=True)
    with Pool(NPROC) as pool:
        trace_results = pool.map(_collect_trace_worker, trace_args)

    traces = {}
    for prog, trace, total_insts in trace_results:
        traces[prog] = (trace, total_insts)
        print(f"    {prog}: {len(trace):,} events, {total_insts:,} instructions")
    dt_trace = time.time() - t0_all
    print(f"  Traces collected in {dt_trace:.1f}s")

    # ── Build ALL evaluation tasks for Sweep 1-4 ──
    all_tasks = []  # (task_key, trace, total_insts, btb, tag_w, ghr, ras)

    # Sweep 1: BTB size (GHR=8, RAS=4)
    for btb in btb_sizes:
        for prog in programs:
            if prog in traces:
                tr, ni = traces[prog]
                all_tasks.append((('s1', btb, prog), tr, ni, btb, BTB_TAG_W, 8, 4))

    # Sweep 2: GHR width (BTB=64, RAS=4)
    for ghr in ghr_widths:
        for prog in programs:
            if prog in traces:
                tr, ni = traces[prog]
                all_tasks.append((('s2', ghr, prog), tr, ni, 64, BTB_TAG_W, ghr, 4))

    # Sweep 3: RAS depth (BTB=64, GHR=8)
    for ras in ras_depths:
        for prog in programs:
            if prog in traces:
                tr, ni = traces[prog]
                all_tasks.append((('s3', ras, prog), tr, ni, 64, BTB_TAG_W, 8, ras))

    # Sweep 4: BTB × GHR cross-product (RAS=4)
    for btb in btb_sizes:
        for ghr in ghr_widths:
            for prog in programs:
                if prog in traces:
                    tr, ni = traces[prog]
                    all_tasks.append((('s4', btb, ghr, prog), tr, ni, btb, BTB_TAG_W, ghr, FIXED_RAS))

    # ── Run ALL evaluations in parallel ──
    print(f"\n  Running {len(all_tasks)} BP evaluations across {NPROC} cores...", flush=True)
    t0_eval = time.time()
    with Pool(NPROC) as pool:
        eval_results = pool.map(_eval_bp_worker, all_tasks)
    dt_eval = time.time() - t0_eval
    print(f"  Done in {dt_eval:.1f}s")

    # Index results by key
    results = {}
    for key, r in eval_results:
        results[key] = r

    # ================================================================
    # Sweep 1: BTB size
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Sweep 1: BTB Entries  (GHR=8, RAS=4 fixed)")
    print(f"{'=' * 120}")

    hdr = f"  {'BTB':>5s}"
    for prog in programs:
        if prog in traces:
            hdr += f"  {'':>2s}{prog:>8s}Acc  {prog:>8s}CPI  {prog:>7s}BTBmt"
    hdr += f"  {'AvgAcc':>7s} {'AvgCPI':>7s} {'Bits':>6s}"
    print(hdr)
    print(f"  {'-'*5}" + f"  {'-'*11} {'-'*11} {'-'*11}" * len(traces) + f"  {'-'*7} {'-'*7} {'-'*6}")

    for btb in btb_sizes:
        line = f"  {btb:>5d}"
        accs = []; cpis = []; bits = 0
        for prog in programs:
            if prog not in traces: continue
            r = results.get(('s1', btb, prog))
            if r is None: continue
            line += f"  {r['branch_acc']:>8.2f}%  {r['cpi']:>8.3f}  {r['btb_miss_taken']:>8,}"
            accs.append(r['branch_acc']); cpis.append(r['cpi'])
            bits = r['total_bits']
        avg_acc = sum(accs)/len(accs) if accs else 0
        avg_cpi = sum(cpis)/len(cpis) if cpis else 0
        marker = " ◄" if btb == CURRENT[0] else ""
        line += f"  {avg_acc:>6.2f}% {avg_cpi:>7.3f} {bits:>6,}{marker}"
        print(line)

    # ================================================================
    # Sweep 2: GHR width
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Sweep 2: GHR Width  (BTB=64, RAS=4 fixed)")
    print(f"{'=' * 120}")

    hdr = f"  {'GHR':>5s} {'PHT':>5s}"
    for prog in programs:
        if prog in traces:
            hdr += f"  {prog:>8s}BrAcc  {prog:>8s}CPI"
    hdr += f"  {'AvgBrAcc':>9s} {'AvgCPI':>7s} {'Bits':>6s}"
    print(hdr)
    print(f"  {'-'*5} {'-'*5}" + f"  {'-'*13} {'-'*11}" * len(traces) + f"  {'-'*9} {'-'*7} {'-'*6}")

    for ghr in ghr_widths:
        pht_sz = 1 << ghr
        line = f"  {ghr:>5d} {pht_sz:>5d}"
        accs = []; cpis = []; bits = 0
        for prog in programs:
            if prog not in traces: continue
            r = results.get(('s2', ghr, prog))
            if r is None: continue
            line += f"  {r['branch_acc']:>10.2f}%  {r['cpi']:>8.3f}"
            accs.append(r['branch_acc']); cpis.append(r['cpi'])
            bits = r['total_bits']
        avg_acc = sum(accs)/len(accs) if accs else 0
        avg_cpi = sum(cpis)/len(cpis) if cpis else 0
        marker = " ◄" if ghr == CURRENT[1] else ""
        line += f"  {avg_acc:>8.2f}% {avg_cpi:>7.3f} {bits:>6,}{marker}"
        print(line)

    # ================================================================
    # Sweep 3: RAS depth
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Sweep 3: RAS Depth  (BTB=64, GHR=8 fixed)")
    print(f"{'=' * 120}")

    hdr = f"  {'RAS':>5s}"
    for prog in programs:
        if prog in traces:
            hdr += f"  {prog:>8s}RetAcc  {prog:>8s}CPI"
    hdr += f"  {'AvgRetAcc':>10s} {'AvgCPI':>7s}"
    print(hdr)
    print(f"  {'-'*5}" + f"  {'-'*14} {'-'*11}" * len(traces) + f"  {'-'*10} {'-'*7}")

    for ras in ras_depths:
        line = f"  {ras:>5d}"
        accs = []; cpis = []
        for prog in programs:
            if prog not in traces: continue
            r = results.get(('s3', ras, prog))
            if r is None: continue
            line += f"  {r['ret_acc']:>11.2f}%  {r['cpi']:>8.3f}"
            accs.append(r['ret_acc']); cpis.append(r['cpi'])
        avg_acc = sum(accs)/len(accs) if accs else 0
        avg_cpi = sum(cpis)/len(cpis) if cpis else 0
        marker = " ◄" if ras == CURRENT[2] else ""
        line += f"  {avg_acc:>9.2f}% {avg_cpi:>7.3f}{marker}"
        print(line)

    # ================================================================
    # Sweep 4: BTB × GHR cross-product
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Sweep 4: BTB × GHR Cross-Product (RAS=4 fixed, ranked by average CPI)")
    print(f"{'=' * 120}")

    combos = []
    for btb in btb_sizes:
        for ghr in ghr_widths:
            results_per_prog = {}
            for prog in programs:
                if prog not in traces: continue
                r = results.get(('s4', btb, ghr, prog))
                if r: results_per_prog[prog] = r
            if len(results_per_prog) == len(traces):
                avg_cpi = sum(r['cpi'] for r in results_per_prog.values()) / len(results_per_prog)
                avg_acc = sum(r['overall_acc'] for r in results_per_prog.values()) / len(results_per_prog)
                avg_br_acc = sum(r['branch_acc'] for r in results_per_prog.values()) / len(results_per_prog)
                bits = results_per_prog[programs[0]]['total_bits']
                combos.append({
                    'btb': btb, 'ghr': ghr, 'ras': FIXED_RAS,
                    'avg_cpi': avg_cpi, 'avg_acc': avg_acc, 'avg_br_acc': avg_br_acc,
                    'bits': bits, 'per_prog': results_per_prog,
                })

    combos.sort(key=lambda c: c['avg_cpi'])

    print(f"\n  {'#':>3s} {'BTB':>4s} {'GHR':>4s} {'RAS':>4s} ", end='')
    for prog in programs:
        if prog in traces:
            print(f" {prog:>7s}CPI", end='')
    print(f"  {'AvgCPI':>7s} {'AvgBrAcc':>9s} {'Bits':>6s}")
    print(f"  {'-'*3} {'-'*4} {'-'*4} {'-'*4} " + f" {'-'*10}" * len(traces) + f"  {'-'*7} {'-'*9} {'-'*6}")

    shown = 0
    for c in combos[:25]:
        shown += 1
        is_current = (c['btb'] == CURRENT[0] and c['ghr'] == CURRENT[1] and c['ras'] == CURRENT[2])
        marker = " ◄" if is_current else ""
        line = f"  {shown:>3d} {c['btb']:>4d} {c['ghr']:>4d} {c['ras']:>4d} "
        for prog in programs:
            if prog in c['per_prog']:
                line += f" {c['per_prog'][prog]['cpi']:>9.3f}"
        line += f"  {c['avg_cpi']:>7.3f} {c['avg_br_acc']:>8.2f}% {c['bits']:>6,}{marker}"
        print(line)

    # Show current config rank if not in top 25
    for i, c in enumerate(combos):
        if c['btb'] == CURRENT[0] and c['ghr'] == CURRENT[1] and c['ras'] == CURRENT[2]:
            if i >= 25:
                print(f"  ...")
                print(f"  {i+1:>3d} {c['btb']:>4d} {c['ghr']:>4d} {c['ras']:>4d} ", end='')
                for prog in programs:
                    if prog in c['per_prog']:
                        print(f" {c['per_prog'][prog]['cpi']:>9.3f}", end='')
                print(f"  {c['avg_cpi']:>7.3f} {c['avg_br_acc']:>8.2f}% {c['bits']:>6,} ◄ CURRENT")
            break

    # ================================================================
    # Detailed comparison: Current vs Top configs
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Detailed: Current vs Top Configs")
    print(f"{'=' * 120}")

    current_combo = None
    for c in combos:
        if c['btb'] == CURRENT[0] and c['ghr'] == CURRENT[1] and c['ras'] == CURRENT[2]:
            current_combo = c
            break

    top_n = list(combos[:5])
    if current_combo and current_combo not in top_n:
        top_n.append(current_combo)

    for c in top_n:
        is_current = (c['btb'] == CURRENT[0] and c['ghr'] == CURRENT[1] and c['ras'] == CURRENT[2])
        label = f"BTB={c['btb']} GHR={c['ghr']} RAS={c['ras']}"
        if is_current:
            label += " ◄ CURRENT"

        print(f"\n  ── {label} ── (LUTRAM: {c['bits']:,} bits = {c['bits']//8:,} bytes)")
        print(f"  {'Program':<10s} {'Overall%':>9s} {'Branch%':>9s} {'Call%':>7s} {'Ret%':>7s} "
              f"{'Mispred':>8s} {'Penalty':>9s} {'CPI':>7s} {'BTBm+T':>7s} {'DirErr':>7s}")
        print(f"  {'-'*10} {'-'*9} {'-'*9} {'-'*7} {'-'*7} "
              f"{'-'*8} {'-'*9} {'-'*7} {'-'*7} {'-'*7}")

        for prog in programs:
            if prog not in c['per_prog']: continue
            r = c['per_prog'][prog]
            print(f"  {prog:<10s} {r['overall_acc']:>8.2f}% {r['branch_acc']:>8.2f}% "
                  f"{r['call_acc']:>6.2f}% {r['ret_acc']:>6.2f}% "
                  f"{r['mispred']:>8,} {r['penalty_cycles']:>9,} {r['cpi']:>7.3f} "
                  f"{r['btb_miss_taken']:>7,} {r['dir_wrong']:>7,}")

        if not is_current and current_combo:
            delta = c['avg_cpi'] - current_combo['avg_cpi']
            bits_delta = c['bits'] - current_combo['bits']
            print(f"  → vs current: AvgCPI {delta:+.4f}, LUTRAM {bits_delta:+,} bits")

    # ================================================================
    # Recommendation
    # ================================================================
    print(f"\n{'=' * 120}")
    print(f" Recommendation")
    print(f"{'=' * 120}")

    best = combos[0]
    current_bits = current_combo['bits'] if current_combo else 0
    best_budget = None
    for c in combos:
        if c['bits'] <= current_bits * 2.5:
            best_budget = c
            break

    if best_budget:
        b = best_budget
        print(f"\n  Best within 2.5× resource budget:")
        print(f"    Config: BTB={b['btb']}, GHR={b['ghr']}, RAS={b['ras']}")
        print(f"    AvgCPI: {b['avg_cpi']:.4f} (current: {current_combo['avg_cpi']:.4f}, "
              f"delta: {b['avg_cpi'] - current_combo['avg_cpi']:+.4f})")
        print(f"    AvgBranchAcc: {b['avg_br_acc']:.2f}% (current: {current_combo['avg_br_acc']:.2f}%)")
        print(f"    LUTRAM: {b['bits']:,} bits ({b['bits']/current_bits:.1f}× current)")

    print(f"\n  Overall best (no resource limit):")
    print(f"    Config: BTB={best['btb']}, GHR={best['ghr']}, RAS={best['ras']}")
    print(f"    AvgCPI: {best['avg_cpi']:.4f} (current: {current_combo['avg_cpi']:.4f})")
    print(f"    LUTRAM: {best['bits']:,} bits ({best['bits']/current_bits:.1f}× current)")

    dt_total = time.time() - t0_all
    print(f"\n  Total time: {dt_total:.1f}s ({NPROC} cores)")
    print()


if __name__ == '__main__':
    main()
