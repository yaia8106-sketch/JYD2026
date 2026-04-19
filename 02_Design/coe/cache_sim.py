#!/usr/bin/env python3
"""
Data Cache Hit Rate Simulator for RV32I COE Programs.

Runs the ISA simulator, captures all DRAM load/store accesses,
then tests various cache configurations to estimate hit rates
and net performance impact at 250MHz vs 200MHz baseline.
"""
import os, struct
from collections import defaultdict

# ==============================
# RV32I Simulator (memory-trace version)
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
        self.mem_trace = []  # (addr, 'R'|'W', size)
        self.cycle_count = 0
        self.halted = False
        self.branch_count = 0
        self.branch_taken = 0

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
            self.mem_trace.append((addr, 'R', size))
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
        self.mem_trace.append((addr, 'W', size))
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

        if opcode == 0x37:
            self.write_reg(rd, inst & 0xFFFFF000)
        elif opcode == 0x17:
            self.write_reg(rd, (self.pc + to_signed(inst & 0xFFFFF000)) & 0xFFFFFFFF)
        elif opcode == 0x6F:
            imm = (((inst>>31)&1)<<20|((inst>>12)&0xFF)<<12|((inst>>20)&1)<<11|((inst>>21)&0x3FF)<<1)
            imm = sign_ext(imm, 21) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            next_pc = target
        elif opcode == 0x67:
            imm = sign_ext((inst >> 20) & 0xFFF, 12) & 0xFFFFFFFF
            base = self.read_reg(rs1)
            target = (to_signed(base) + to_signed(imm)) & 0xFFFFFFFE & 0xFFFFFFFF
            self.write_reg(rd, self.pc + 4)
            next_pc = target
        elif opcode == 0x63:
            imm = (((inst>>31)&1)<<12|((inst>>7)&1)<<11|((inst>>25)&0x3F)<<5|((inst>>8)&0xF)<<1)
            imm = sign_ext(imm, 13) & 0xFFFFFFFF
            target = (self.pc + to_signed(imm)) & 0xFFFFFFFF
            a, b = to_signed(self.read_reg(rs1)), to_signed(self.read_reg(rs2))
            ua, ub = self.read_reg(rs1), self.read_reg(rs2)
            taken = False
            if   f3==0: taken=(a==b)
            elif f3==1: taken=(a!=b)
            elif f3==4: taken=(a<b)
            elif f3==5: taken=(a>=b)
            elif f3==6: taken=(ua<ub)
            elif f3==7: taken=(ua>=ub)
            self.branch_count += 1
            if taken:
                self.branch_taken += 1
                next_pc = target
        elif opcode == 0x03:
            imm = sign_ext((inst>>20)&0xFFF, 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            if f3==0: val=sign_ext(self.mem_read(addr,1),8)&0xFFFFFFFF
            elif f3==1: val=sign_ext(self.mem_read(addr,2),16)&0xFFFFFFFF
            elif f3==2: val=self.mem_read(addr,4)
            elif f3==4: val=self.mem_read(addr,1)
            elif f3==5: val=self.mem_read(addr,2)
            else: val=0
            self.write_reg(rd, val)
        elif opcode == 0x23:
            imm = sign_ext(((f7<<5)|rd), 12) & 0xFFFFFFFF
            addr = (to_signed(self.read_reg(rs1)) + to_signed(imm)) & 0xFFFFFFFF
            val = self.read_reg(rs2)
            if f3==0: self.mem_write(addr, val, 1)
            elif f3==1: self.mem_write(addr, val, 2)
            elif f3==2: self.mem_write(addr, val, 4)
        elif opcode == 0x13:
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
        elif opcode == 0x33:
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
        return self.mem_trace


# ==============================
# Cache Simulator
# ==============================

class CacheSim:
    """Direct-mapped or N-way set-associative write-through cache."""

    def __init__(self, name, total_bytes, line_bytes, assoc=1):
        self.name = name
        self.line_bytes = line_bytes
        self.assoc = assoc
        self.n_lines = total_bytes // line_bytes
        self.n_sets = self.n_lines // assoc
        self.offset_bits = (line_bytes - 1).bit_length()
        self.index_bits = (self.n_sets - 1).bit_length() if self.n_sets > 1 else 0
        self.index_mask = self.n_sets - 1

        # Cache state: each set has `assoc` ways, each way = (valid, tag)
        self.cache = [[(False, 0) for _ in range(assoc)] for _ in range(self.n_sets)]
        self.lru = [[0] * assoc for _ in range(self.n_sets)]  # LRU counters
        self.lru_counter = 0

        self.hits = 0
        self.misses = 0
        self.load_hits = 0
        self.load_misses = 0
        self.store_hits = 0
        self.store_misses = 0

    def _decompose(self, addr):
        idx = (addr >> self.offset_bits) & self.index_mask
        tag = addr >> (self.offset_bits + self.index_bits)
        return idx, tag

    def access(self, addr, rw):
        idx, tag = self._decompose(addr)
        s = self.cache[idx]

        # Check for hit
        for w in range(self.assoc):
            if s[w][0] and s[w][1] == tag:
                # Hit
                self.hits += 1
                if rw == 'R':
                    self.load_hits += 1
                else:
                    self.store_hits += 1
                self.lru_counter += 1
                self.lru[idx][w] = self.lru_counter
                return True

        # Miss
        self.misses += 1
        if rw == 'R':
            self.load_misses += 1
        else:
            self.store_misses += 1

        # Find victim (LRU)
        min_lru = min(self.lru[idx])
        victim = self.lru[idx].index(min_lru)

        # Install
        s[victim] = (True, tag)
        self.lru_counter += 1
        self.lru[idx][victim] = self.lru_counter
        return False

    def hit_rate(self):
        total = self.hits + self.misses
        return self.hits / total * 100 if total else 0

    def reset(self):
        for i in range(self.n_sets):
            for w in range(self.assoc):
                self.cache[i][w] = (False, 0)
                self.lru[i][w] = 0
        self.lru_counter = 0
        self.hits = self.misses = 0
        self.load_hits = self.load_misses = 0
        self.store_hits = self.store_misses = 0


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

    # Cache configurations to test
    # (name, total_bytes, line_bytes, assoc)
    configs = [
        # Direct-mapped, 16B line (4 words)
        ("DM  1KB/16B",  1024, 16, 1),
        ("DM  2KB/16B",  2048, 16, 1),
        ("DM  4KB/16B",  4096, 16, 1),
        ("DM  8KB/16B",  8192, 16, 1),
        # Direct-mapped, 32B line (8 words)
        ("DM  2KB/32B",  2048, 32, 1),
        ("DM  4KB/32B",  4096, 32, 1),
        # 2-way, 16B line
        ("2W  2KB/16B",  2048, 16, 2),
        ("2W  4KB/16B",  4096, 16, 2),
        # 4-way, 16B line
        ("4W  4KB/16B",  4096, 16, 4),
    ]

    # Performance model parameters
    FREQ_BASE = 200  # MHz (current stable)
    FREQ_CACHE = 250  # MHz (target with cache)
    MISS_PENALTY = 3  # cycles to fetch from DRAM on miss
    BP_MISPRED_RATE = 0.10  # ~10% branch misprediction
    BP_FLUSH_PENALTY = 3  # cycles per misprediction

    print("=" * 90)
    print(" Data Cache Hit Rate & Performance Simulation")
    print(" (DRAM access trace from ISA simulation)")
    print("=" * 90)

    # Per-config summary across all programs
    summary = {c[0]: [] for c in configs}

    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if not os.path.exists(irom_path):
            continue

        print(f"\n{'─' * 90}")
        print(f"  Program: {prog}")
        print(f"{'─' * 90}")

        irom = load_coe(irom_path)
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []

        sim = RV32ISim(irom, dram)
        trace = sim.run(max_cycles=5000000)

        total_insts = sim.cycle_count
        n_loads = sum(1 for _, rw, _ in trace if rw == 'R')
        n_stores = sum(1 for _, rw, _ in trace if rw == 'W')

        # Unique addresses accessed
        unique_addrs = len(set((a >> 2) for a, _, _ in trace))
        addr_range = 0
        if trace:
            min_a = min(a for a, _, _ in trace)
            max_a = max(a for a, _, _ in trace)
            addr_range = max_a - min_a

        print(f"  Instructions:     {total_insts:,}")
        print(f"  DRAM accesses:    {len(trace):,} (loads={n_loads:,}, stores={n_stores:,})")
        print(f"  Unique words:     {unique_addrs:,}")
        print(f"  Address range:    {addr_range:,} bytes ({addr_range/1024:.1f} KB)")

        print(f"\n  {'Config':<16s} {'Hit%':>7s} {'LdHit%':>7s} {'StHit%':>7s} "
              f"{'Miss':>8s} {'MissCyc':>8s} {'CPI@250':>8s} {'vs200MHz':>9s}")
        print(f"  {'-'*16} {'-'*7} {'-'*7} {'-'*7} {'-'*8} {'-'*8} {'-'*8} {'-'*9}")

        # Baseline: no cache @ 200MHz
        # Estimate CPI with branch predictor
        base_bp_penalty = int(total_insts * BP_MISPRED_RATE * BP_FLUSH_PENALTY)
        base_cpi = 1.0 + base_bp_penalty / total_insts
        base_time_factor = base_cpi / FREQ_BASE  # relative execution time

        for name, total_b, line_b, assoc in configs:
            cache = CacheSim(name, total_b, line_b, assoc)

            for addr, rw, sz in trace:
                cache.access(addr, rw)

            hr = cache.hit_rate()
            lhr = cache.load_hits / (cache.load_hits + cache.load_misses) * 100 if (cache.load_hits + cache.load_misses) else 0
            shr = cache.store_hits / (cache.store_hits + cache.store_misses) * 100 if (cache.store_hits + cache.store_misses) else 0

            # CPI impact at 250MHz
            miss_cycles = cache.misses * MISS_PENALTY
            cache_bp_penalty = int(total_insts * BP_MISPRED_RATE * BP_FLUSH_PENALTY)
            cache_cpi = 1.0 + (miss_cycles + cache_bp_penalty) / total_insts
            cache_time_factor = cache_cpi / FREQ_CACHE

            speedup = base_time_factor / cache_time_factor if cache_time_factor > 0 else 0
            speedup_pct = (speedup - 1) * 100

            print(f"  {name:<16s} {hr:6.2f}% {lhr:6.2f}% {shr:6.2f}% "
                  f"{cache.misses:>8,} {miss_cycles:>8,} {cache_cpi:>7.3f}  "
                  f"{'%+.1f%%' % speedup_pct:>8s}")

            summary[name].append({
                'prog': prog, 'hit_rate': hr, 'misses': cache.misses,
                'miss_cycles': miss_cycles, 'cpi': cache_cpi,
                'speedup': speedup_pct
            })

    # ---- Summary across all programs ----
    print(f"\n{'=' * 90}")
    print(f"  Cross-program Summary (average)")
    print(f"{'=' * 90}")
    print(f"\n  {'Config':<16s} {'AvgHit%':>8s} {'AvgCPI':>8s} {'AvgSpeedup':>11s} {'BRAM':>6s}")
    print(f"  {'-'*16} {'-'*8} {'-'*8} {'-'*11} {'-'*6}")

    for name, total_b, line_b, assoc in configs:
        entries = summary[name]
        if not entries: continue
        avg_hr = sum(e['hit_rate'] for e in entries) / len(entries)
        avg_cpi = sum(e['cpi'] for e in entries) / len(entries)
        avg_sp = sum(e['speedup'] for e in entries) / len(entries)
        bram_count = total_b * 8 // 36864 + 1  # rough BRAM36 estimate
        print(f"  {name:<16s} {avg_hr:7.2f}% {avg_cpi:>7.3f}  "
              f"{'%+.1f%%' % avg_sp:>10s} {bram_count:>5}×")

    print(f"\n  Note: Speedup = (CPI@200MHz/200) / (CPI@250MHz/250)")
    print(f"        miss_penalty = {MISS_PENALTY} cycles, BP mispred = {BP_MISPRED_RATE*100:.0f}%")
    print(f"        Positive % = faster than current 200MHz baseline")
    print()


if __name__ == '__main__':
    main()
