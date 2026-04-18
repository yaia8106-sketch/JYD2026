#!/usr/bin/env python3
"""
RV32I 功能仿真器 + 分支预测器准确率测试

流程:
1. 加载 IROM/DRAM COE 文件
2. 逐条执行 RV32I 指令，生成动态分支 trace
3. 在 trace 上模拟不同的预测器配置，输出命中率
"""
import sys, os, struct, datetime
from collections import defaultdict

# ============================================================
#  RV32I Functional Simulator
# ============================================================

def sign_ext(val, bits):
    """Sign-extend a value from 'bits' width to 32 bits."""
    if val & (1 << (bits - 1)):
        val -= (1 << bits)
    return val & 0xFFFFFFFF

def to_signed(val):
    """Interpret 32-bit unsigned as signed."""
    val &= 0xFFFFFFFF
    if val & 0x80000000:
        return val - 0x100000000
    return val

class RV32ISim:
    TEXT_BASE = 0x80000000
    DRAM_BASE = 0x80100000     # perip_bridge: 0x8010_0000 ~ 0x8014_0000
    DRAM_SIZE = 256 * 1024     # 256KB
    DRAM_END  = DRAM_BASE + DRAM_SIZE
    # MMIO addresses
    MMIO_SW0  = 0x80200000
    MMIO_SW1  = 0x80200004
    MMIO_KEY  = 0x80200010
    MMIO_SEG  = 0x80200020
    MMIO_LED  = 0x80200040
    MMIO_CNT  = 0x80200050

    def __init__(self, irom_words, dram_words):
        self.regs = [0] * 32
        self.pc = self.TEXT_BASE
        self.irom = irom_words  # list of 32-bit words
        self.dram = bytearray(self.DRAM_SIZE)
        # Initialize DRAM
        for i, w in enumerate(dram_words):
            addr = i * 4
            if addr + 4 <= self.DRAM_SIZE:
                struct.pack_into('<I', self.dram, addr, w)
        self.trace = []  # (pc, inst_type, taken, target)
        self.cycle_count = 0
        self.halted = False

    def read_reg(self, r):
        return self.regs[r] if r != 0 else 0

    def write_reg(self, r, val):
        if r != 0:
            self.regs[r] = val & 0xFFFFFFFF

    def fetch(self):
        offset = (self.pc - self.TEXT_BASE) >> 2
        if 0 <= offset < len(self.irom):
            return self.irom[offset]
        return 0  # NOP for out-of-range

    def mem_read(self, addr, size):
        addr &= 0xFFFFFFFF
        # DRAM range
        if self.DRAM_BASE <= addr < self.DRAM_END:
            offset = addr - self.DRAM_BASE
            if offset + size > self.DRAM_SIZE:
                return 0
            if size == 1:
                return self.dram[offset]
            elif size == 2:
                return struct.unpack_from('<H', self.dram, offset)[0]
            elif size == 4:
                return struct.unpack_from('<I', self.dram, offset)[0]
        # MMIO reads - return 0 for simplicity
        return 0

    def mem_write(self, addr, val, size):
        addr &= 0xFFFFFFFF
        # MMIO writes - ignore
        if addr >= 0x80200000:
            return
        # DRAM range
        if not (self.DRAM_BASE <= addr < self.DRAM_END):
            return
        offset = addr - self.DRAM_BASE
        if offset + size > self.DRAM_SIZE:
            return
        if size == 1:
            self.dram[offset] = val & 0xFF
        elif size == 2:
            struct.pack_into('<H', self.dram, offset, val & 0xFFFF)
        elif size == 4:
            struct.pack_into('<I', self.dram, offset, val & 0xFFFFFFFF)

    def step(self):
        if self.halted:
            return False

        inst = self.fetch()
        opcode = inst & 0x7F
        rd  = (inst >> 7) & 0x1F
        f3  = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7  = (inst >> 25) & 0x7F

        next_pc = self.pc + 4

        if opcode == 0x37:  # LUI
            imm = inst & 0xFFFFF000
            self.write_reg(rd, imm)

        elif opcode == 0x17:  # AUIPC
            imm = inst & 0xFFFFF000
            self.write_reg(rd, (self.pc + to_signed(imm)) & 0xFFFFFFFF)

        elif opcode == 0x6F:  # JAL
            imm = (((inst >> 31) & 1) << 20 |
                   ((inst >> 12) & 0xFF) << 12 |
                   ((inst >> 20) & 1) << 11 |
                   ((inst >> 21) & 0x3FF) << 1)
            imm = sign_ext(imm, 21) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            # Determine type: CALL if rd=ra(x1), else plain JAL
            is_call = (rd == 1)
            self.trace.append((self.pc, 'CALL' if is_call else 'JAL', True, target))
            next_pc = target

        elif opcode == 0x67:  # JALR
            imm = sign_ext((inst >> 20) & 0xFFF, 12) & 0xFFFFFFFF
            base = self.read_reg(rs1)
            target = (to_signed(base) + to_signed(imm)) & 0xFFFFFFFE
            target &= 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            # RET: rs1=x1, rd=x0
            is_ret = (rs1 == 1 and rd == 0)
            is_call = (rd == 1)
            if is_ret:
                self.trace.append((self.pc, 'RET', True, target))
            elif is_call:
                self.trace.append((self.pc, 'CALL', True, target))
            else:
                self.trace.append((self.pc, 'JALR', True, target))
            next_pc = target

        elif opcode == 0x63:  # B-type
            imm = (((inst >> 31) & 1) << 12 |
                   ((inst >> 7) & 1) << 11 |
                   ((inst >> 25) & 0x3F) << 5 |
                   ((inst >> 8) & 0xF) << 1)
            imm = sign_ext(imm, 13) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            a = to_signed(self.read_reg(rs1))
            b = to_signed(self.read_reg(rs2))
            ua = self.read_reg(rs1)
            ub = self.read_reg(rs2)
            taken = False
            if   f3 == 0: taken = (a == b)   # BEQ
            elif f3 == 1: taken = (a != b)   # BNE
            elif f3 == 4: taken = (a < b)    # BLT
            elif f3 == 5: taken = (a >= b)   # BGE
            elif f3 == 6: taken = (ua < ub)  # BLTU
            elif f3 == 7: taken = (ua >= ub) # BGEU
            self.trace.append((self.pc, 'BRANCH', taken, target))
            if taken:
                next_pc = target

        elif opcode == 0x03:  # Load
            imm = sign_ext((inst >> 20) & 0xFFF, 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            if f3 == 0:    # LB
                val = sign_ext(self.mem_read(addr, 1), 8) & 0xFFFFFFFF
            elif f3 == 1:  # LH
                val = sign_ext(self.mem_read(addr, 2), 16) & 0xFFFFFFFF
            elif f3 == 2:  # LW
                val = self.mem_read(addr, 4)
            elif f3 == 4:  # LBU
                val = self.mem_read(addr, 1)
            elif f3 == 5:  # LHU
                val = self.mem_read(addr, 2)
            else:
                val = 0
            self.write_reg(rd, val)

        elif opcode == 0x23:  # Store
            imm = sign_ext(((f7 << 5) | rd), 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            val = self.read_reg(rs2)
            if f3 == 0:    self.mem_write(addr, val, 1)  # SB
            elif f3 == 1:  self.mem_write(addr, val, 2)  # SH
            elif f3 == 2:  self.mem_write(addr, val, 4)  # SW

        elif opcode == 0x13:  # ALU-I
            imm_raw = (inst >> 20) & 0xFFF
            imm = sign_ext(imm_raw, 12) & 0xFFFFFFFF
            a = self.read_reg(rs1)
            shamt = imm_raw & 0x1F
            if   f3 == 0: res = (to_signed(a) + to_signed(imm)) & 0xFFFFFFFF  # ADDI
            elif f3 == 1: res = (a << shamt) & 0xFFFFFFFF                      # SLLI
            elif f3 == 2: res = 1 if to_signed(a) < to_signed(imm) else 0      # SLTI
            elif f3 == 3: res = 1 if a < (imm & 0xFFFFFFFF) else 0             # SLTIU
            elif f3 == 4: res = (a ^ imm) & 0xFFFFFFFF                         # XORI
            elif f3 == 5:
                if f7 & 0x20:  # SRAI
                    res = (to_signed(a) >> shamt) & 0xFFFFFFFF
                else:          # SRLI
                    res = (a >> shamt) & 0xFFFFFFFF
            elif f3 == 6: res = (a | imm) & 0xFFFFFFFF                         # ORI
            elif f3 == 7: res = (a & imm) & 0xFFFFFFFF                         # ANDI
            else: res = 0
            self.write_reg(rd, res)

        elif opcode == 0x33:  # ALU-R
            a = self.read_reg(rs1)
            b = self.read_reg(rs2)
            if   f3 == 0:
                res = (to_signed(a) - to_signed(b)) & 0xFFFFFFFF if (f7 & 0x20) else (to_signed(a) + to_signed(b)) & 0xFFFFFFFF
            elif f3 == 1: res = (a << (b & 0x1F)) & 0xFFFFFFFF                # SLL
            elif f3 == 2: res = 1 if to_signed(a) < to_signed(b) else 0       # SLT
            elif f3 == 3: res = 1 if a < b else 0                              # SLTU
            elif f3 == 4: res = (a ^ b) & 0xFFFFFFFF                           # XOR
            elif f3 == 5:
                if f7 & 0x20:  # SRA
                    res = (to_signed(a) >> (b & 0x1F)) & 0xFFFFFFFF
                else:          # SRL
                    res = (a >> (b & 0x1F)) & 0xFFFFFFFF
            elif f3 == 6: res = (a | b) & 0xFFFFFFFF                           # OR
            elif f3 == 7: res = (a & b) & 0xFFFFFFFF                           # AND
            else: res = 0
            self.write_reg(rd, res)

        elif opcode == 0x0F:  # FENCE - NOP
            pass
        elif opcode == 0x73:  # ECALL/EBREAK - halt
            self.halted = True
            return False
        else:
            pass  # Unknown opcode, treat as NOP

        # Dead loop detection
        if next_pc == self.pc:
            self.halted = True
            return False

        self.pc = next_pc & 0xFFFFFFFF
        self.cycle_count += 1
        return True

    def run(self, max_cycles=2000000):
        while self.cycle_count < max_cycles and not self.halted:
            self.step()
        return self.trace


# ============================================================
#  Branch Predictor Models
# ============================================================

class PredictorConfig:
    def __init__(self, name, btb_size, bht_mode, bht_size, ras_depth, assoc=1, tag_bits=8):
        """
        btb_size: total BTB entries
        bht_mode: 'embedded' (BHT in BTB) or 'separate' (standalone BHT)
        bht_size: only used when bht_mode='separate'
        assoc: associativity (1=direct-mapped, 2=2-way)
        tag_bits: number of tag bits (default 8)
        """
        self.name = name
        self.btb_size = btb_size
        self.bht_mode = bht_mode
        self.bht_size = bht_size
        self.ras_depth = ras_depth
        self.assoc = assoc
        self.tag_bits = tag_bits


def simulate_predictor(trace, cfg):
    """Simulate a predictor config against a branch trace, return stats."""
    btb_size = cfg.btb_size
    assoc = cfg.assoc
    n_sets = btb_size // assoc
    bht_size = cfg.bht_size if cfg.bht_mode == 'separate' else btb_size
    ras_depth = cfg.ras_depth
    tag_bits = cfg.tag_bits
    tag_mask = (1 << tag_bits) - 1

    # BTB: n_sets x assoc ways, each entry = {tag, target, type}
    btb = [[None]*assoc for _ in range(n_sets)]
    # LRU: per-set, for 2-way: 0=evict way0, 1=evict way1
    lru = [0] * n_sets
    # BHT: 2-bit saturating counters (0-3, >=2 means predict taken)
    if cfg.bht_mode == 'embedded':
        bht = [[1]*assoc for _ in range(n_sets)]  # per BTB entry
    else:
        bht = [1] * bht_size  # separate

    # RAS
    ras = []

    stats = {
        'total': 0,
        'correct': 0,
        'by_type': defaultdict(lambda: {'total': 0, 'correct': 0}),
        'flush_saved': 0,
        'flush_needed': 0,
    }

    idx_bits = (n_sets - 1).bit_length()

    for pc, itype, actual_taken, actual_target in trace:
        # 非 RET 的 JALR 不预测，直接跳过
        if itype == 'JALR':
            stats['by_type']['JALR']['total'] += 1
            stats['flush_needed'] += 1
            continue

        stats['total'] += 1
        stats['by_type'][itype]['total'] += 1

        # --- Predict phase (IF stage) ---
        set_idx = (pc >> 2) & (n_sets - 1)
        full_tag = pc >> (2 + idx_bits)
        tag = full_tag & tag_mask

        # Lookup: check all ways
        hit_way = -1
        for w in range(assoc):
            e = btb[set_idx][w]
            if e and e['valid'] and e['tag'] == tag:
                hit_way = w
                break

        pred_taken = False
        pred_target = pc + 4

        if hit_way >= 0:
            entry = btb[set_idx][hit_way]
            entry_type = entry['type']
            if entry_type == 'RET':
                if ras:
                    pred_taken = True
                    pred_target = ras[-1]
            elif entry_type in ('JAL', 'CALL'):
                pred_taken = True
                pred_target = entry['target']
            elif entry_type == 'BRANCH':
                if cfg.bht_mode == 'embedded':
                    counter = bht[set_idx][hit_way]
                else:
                    counter = bht[(pc >> 2) & (bht_size - 1)]
                pred_taken = (counter >= 2)
                if pred_taken:
                    pred_target = entry['target']

            # Update LRU (MRU = hit_way)
            if assoc == 2:
                lru[set_idx] = 1 - hit_way

        # --- Evaluate prediction ---
        correct = False
        if actual_taken:
            correct = (pred_taken and pred_target == actual_target)
        else:
            correct = (not pred_taken)

        if correct:
            stats['correct'] += 1
            stats['by_type'][itype]['correct'] += 1
            if actual_taken:
                stats['flush_saved'] += 1
        else:
            stats['flush_needed'] += 1

        # --- Update phase (EX stage) ---

        # Update BTB (不存非 RET 的 JALR)
        if (actual_taken or itype == 'BRANCH') and itype != 'JALR':
            if hit_way >= 0:
                uw = hit_way
            else:
                uw = lru[set_idx] if assoc == 2 else 0
            btb[set_idx][uw] = {
                'valid': True,
                'tag': tag,
                'target': actual_target,
                'type': itype
            }
            if assoc == 2:
                lru[set_idx] = 1 - uw

            # Update embedded BHT
            if cfg.bht_mode == 'embedded' and itype == 'BRANCH':
                if actual_taken:
                    bht[set_idx][uw] = min(3, bht[set_idx][uw] + 1)
                else:
                    bht[set_idx][uw] = max(0, bht[set_idx][uw] - 1)

        # Update separate BHT
        if cfg.bht_mode == 'separate' and itype == 'BRANCH':
            bht_idx = (pc >> 2) & (bht_size - 1)
            if actual_taken:
                bht[bht_idx] = min(3, bht[bht_idx] + 1)
            else:
                bht[bht_idx] = max(0, bht[bht_idx] - 1)

        # Update RAS
        if itype == 'CALL':
            ras.append(pc + 4)
            if len(ras) > ras_depth:
                ras.pop(0)
        elif itype == 'RET' and ras:
            ras.pop()

    return stats


# ============================================================
#  COE Loader
# ============================================================

def load_coe(filepath):
    """Load a COE file, return list of 32-bit words."""
    words = []
    with open(filepath) as f:
        in_data = False
        for line in f:
            line = line.strip().rstrip(';').rstrip(',')
            if 'memory_initialization_vector' in line:
                # Check if data is on the same line after '='
                parts = line.split('=')
                if len(parts) > 1 and parts[1].strip():
                    line = parts[1].strip().rstrip(';').rstrip(',')
                    if line:
                        words.append(int(line, 16))
                in_data = True
                continue
            if in_data and line:
                try:
                    words.append(int(line, 16))
                except ValueError:
                    pass
    return words


# ============================================================
#  Main
# ============================================================

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(base, 'sim_output')
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, 'bp_simulator.txt')
    outfile = open(outpath, 'w', encoding='utf-8')

    def out(s=''):
        print(s)
        outfile.write(s + '\n')

    # Test all programs
    programs = ['current', 'src0', 'src1', 'src2']

    # Predictor configurations to test
    #   最终确认架构: BTB64×2路组相联, BHT内嵌, tag=8bit
    configs = [
        PredictorConfig("无预测 (baseline)",           0, 'embedded', 0, 0),
        # --- BTB 单独（RAS=0）---
        PredictorConfig("BTB64×2路 仅BTB (无RAS)",     64, 'embedded', 64, 0, assoc=2),
        # --- BTB + RAS ---
        PredictorConfig("BTB64×2路 RAS2",              64, 'embedded', 64, 2, assoc=2),
        PredictorConfig("BTB64×2路 RAS4",              64, 'embedded', 64, 4, assoc=2),
    ]

    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if not os.path.exists(irom_path):
            continue

        out(f"\n{'='*75}")
        out(f" 程序: {prog}")
        out(f"{'='*75}")

        irom = load_coe(irom_path)
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []

        # Run simulation to get trace
        sim = RV32ISim(irom, dram)
        trace = sim.run(max_cycles=2000000)

        # Count dynamic instruction types
        type_counts = defaultdict(int)
        for _, itype, taken, _ in trace:
            type_counts[itype] += 1
            if itype == 'BRANCH':
                if taken:
                    type_counts['BRANCH_TAKEN'] += 1
                else:
                    type_counts['BRANCH_NOT_TAKEN'] += 1

        total_dynamic = sim.cycle_count
        out(f" 执行周期数: {total_dynamic:,}")
        out(f" 动态跳转/分支: {len(trace):,} 条")
        out(f" 类型分布:")
        for t in ['JAL', 'CALL', 'RET', 'JALR', 'BRANCH', 'BRANCH_TAKEN', 'BRANCH_NOT_TAKEN']:
            if t in type_counts:
                pct = type_counts[t] / len(trace) * 100 if trace else 0
                marker = "   " if t.startswith("BRANCH_") else ""
                out(f"   {marker}{t}: {type_counts[t]:,} ({pct:.1f}%)")

        # Test each predictor config
        out(f"\n {'配置':<30} {'命中率':>8} {'CPI节省':>10} {'各类型命中率'}")
        out(f" {'-'*30} {'-'*8} {'-'*10} {'-'*40}")

        for cfg in configs:
            if cfg.btb_size == 0:
                # Baseline: no prediction, all taken branches cause 2-cycle penalty
                taken_count = sum(1 for _, _, t, _ in trace if t)
                penalty = taken_count * 2
                cpi = 1.0 + penalty / total_dynamic if total_dynamic else 1.0
                out(f" {cfg.name:<30} {'N/A':>8} {'(base)':>10}")
                base_penalty = penalty
                continue

            stats = simulate_predictor(trace, cfg)
            hit_rate = stats['correct'] / stats['total'] * 100 if stats['total'] else 0

            # CPI impact: misprediction = 2 cycles, correct taken prediction = 0 cycles
            mispred_penalty = stats['flush_needed'] * 2
            saved_cycles = base_penalty - mispred_penalty
            cpi_saved = saved_cycles / total_dynamic if total_dynamic else 0

            type_details = []
            for t in ['CALL', 'JAL', 'RET', 'BRANCH']:
                s = stats['by_type'][t]
                if s['total'] > 0:
                    r = s['correct'] / s['total'] * 100
                    type_details.append(f"{t}={r:.0f}%")

            out(f" {cfg.name:<30} {hit_rate:>7.1f}% {cpi_saved:>+9.3f}  {', '.join(type_details)}")

        out()

    outfile.close()
    print(f"\n结果已保存到: {outpath}")


if __name__ == '__main__':
    main()
