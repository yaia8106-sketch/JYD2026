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
        self.mem_trace = []  # (addr, 'R'|'W', size, inst_idx)
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
            self.mem_trace.append((addr, 'R', size, self.cycle_count))
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
        self.mem_trace.append((addr, 'W', size, self.cycle_count))
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
    """N-way set-associative Write-Through + Write-Allocate DCache with 1-entry Store Buffer.

    Models the RTL dcache.sv behavior:
      - Hit detection per access
      - Store Buffer (1-entry): store hit enqueues SB, next access with SB
        pending may stall (SB conflict on store hit, SB drain before refill)
      - Miss: refill LINE_WORDS + DRAM_LATENCY + 1 cycles, plus SB drain if pending
    """

    def __init__(self, name, total_bytes, line_bytes, assoc=1,
                 line_words=4, dram_latency=4):
        self.name = name
        self.line_bytes = line_bytes
        self.assoc = assoc
        self.n_lines = total_bytes // line_bytes
        self.n_sets = self.n_lines // assoc
        self.offset_bits = (line_bytes - 1).bit_length()
        self.index_bits = (self.n_sets - 1).bit_length() if self.n_sets > 1 else 0
        self.index_mask = self.n_sets - 1

        # RTL timing parameters
        self.line_words = line_words
        self.dram_latency = dram_latency
        # LINE_WORDS + DRAM_LATENCY + 1  (burst + drain + DONE_RD + DONE)
        self.refill_cycles = line_words + dram_latency + 1
        # SB drain adds 2 cycles: S_SB_DRAIN(1) + re-enter S_IDLE(1)
        self.sb_drain_cycles = 2

        # Cache state: each set has `assoc` ways, each way = (valid, tag)
        self.cache = [[(False, 0) for _ in range(assoc)] for _ in range(self.n_sets)]
        self.lru = [[0] * assoc for _ in range(self.n_sets)]  # LRU counters
        self.lru_counter = 0

        # Hit/miss counters
        self.hits = 0
        self.misses = 0
        self.load_hits = 0
        self.load_misses = 0
        self.store_hits = 0
        self.store_misses = 0

        # Cycle-accurate stall counters
        self.refill_stall_cycles = 0      # stall from cache line refill
        self.sb_drain_stall_cycles = 0    # stall from SB drain (before refill or SB conflict)
        self.sb_conflict_stalls = 0       # count of SB conflicts (store hit while SB valid)

        # Store Buffer state
        self.sb_valid = False
        self.last_mem_inst_idx = -100  # large negative so first access doesn't false-trigger

    def _decompose(self, addr):
        idx = (addr >> self.offset_bits) & self.index_mask
        tag = addr >> (self.offset_bits + self.index_bits)
        return idx, tag

    def access(self, addr, rw, inst_idx=0):
        idx, tag = self._decompose(addr)
        s = self.cache[idx]

        # SB background drain: if there have been non-memory instruction cycles
        # since the last memory access, the FSM had time to drain SB (1 cycle).
        # RTL: S_SB_DRAIN takes 1 cycle, then returns to S_IDLE.
        if self.sb_valid and (inst_idx - self.last_mem_inst_idx) >= 2:
            self.sb_valid = False  # drained in background

        self.last_mem_inst_idx = inst_idx

        # Check for hit
        hit = False
        for w in range(self.assoc):
            if s[w][0] and s[w][1] == tag:
                hit = True
                self.hits += 1
                if rw == 'R':
                    self.load_hits += 1
                else:
                    self.store_hits += 1
                self.lru_counter += 1
                self.lru[idx][w] = self.lru_counter
                break

        if hit:
            if rw == 'W':
                # Store hit: enqueue SB → DRAM (WT)
                # If SB already valid → SB conflict → need S_SB_DRAIN first (2 cyc stall)
                if self.sb_valid:
                    self.sb_conflict_stalls += 1
                    self.sb_drain_stall_cycles += self.sb_drain_cycles
                self.sb_valid = True
            else:
                # Load hit: no stall for the load itself.
                # RTL: cpu_ready = cache_hit & ~sb_conflict = 1 (load, not sb_conflict).
                # FSM goes to S_SB_DRAIN next cycle if sb_valid, but load completes.
                # If NEXT memory access is the very next instruction, it sees
                # FSM in S_SB_DRAIN → cpu_ready=0 for 1 cycle (handled by gap check above
                # and by the "next access" logic when that access arrives).
                # For simplicity: SB drain after load takes 1 FSM cycle, so if next
                # mem access is ≥2 instructions away, SB is drained. If exactly 1
                # instruction away, the next access sees S_SB_DRAIN:
                #   - next is store hit → treated as sb_conflict (handled above)
                #   - next is load hit → 1-cycle stall (FSM in S_SB_DRAIN, cpu_ready=0)
                #   - next is miss → SB drain before refill (handled below)
                # We keep sb_valid=True; the gap check at the top handles the free drain.
                pass
            return True

        # Miss — need refill
        self.misses += 1
        if rw == 'R':
            self.load_misses += 1
        else:
            self.store_misses += 1

        # RTL: must drain SB before refill if SB valid
        if self.sb_valid:
            self.sb_drain_stall_cycles += self.sb_drain_cycles
            self.sb_valid = False

        # Refill stall
        self.refill_stall_cycles += self.refill_cycles

        # Install line in cache (LRU replacement)
        min_lru = min(self.lru[idx])
        victim = self.lru[idx].index(min_lru)
        s[victim] = (True, tag)
        self.lru_counter += 1
        self.lru[idx][victim] = self.lru_counter

        # After refill, if it was a store, the data is also written (SB enqueued)
        if rw == 'W':
            self.sb_valid = True

        return False

    def total_stall_cycles(self):
        return self.refill_stall_cycles + self.sb_drain_stall_cycles

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
        self.refill_stall_cycles = 0
        self.sb_drain_stall_cycles = 0
        self.sb_conflict_stalls = 0
        self.sb_valid = False
        self.last_mem_inst_idx = -100


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


def count_load_use_stalls(irom, dram, max_cycles=5000000):
    """Count load-use hazards by replaying execution.

    RTL (forwarding.sv):
      load_in_ex:  load in EX, consumer in ID uses load rd → 2-cycle stall
      load_in_mem: load in MEM, consumer in ID uses load rd → 1-cycle stall
    MEM forwarding excludes loads (~mem_is_load), so load data only available at WB.

    IMPORTANT: When a load MISSES the cache, the pipeline stalls from
    mem_ready_go=0 (DCache refill). The load-use stall is absorbed into
    the cache miss stall and costs 0 extra cycles. Only stalls from
    cache-HITTING loads are additive. Caller must scale by load hit rate.

    Returns: (total_instructions, n1_stalls, n2_stalls)
      n1_stalls: immediate successor depends on load (2-cycle stall each)
      n2_stalls: two-back successor depends on load (1-cycle stall each)
    """
    sim = RV32ISim(irom, dram)
    n1_stalls = 0  # load_in_ex: consumer is next instruction
    n2_stalls = 0  # load_in_mem: consumer is 2 instructions after load
    prev_load_rd = 0       # rd of instruction at i-1 if it was a load
    prev_prev_load_rd = 0  # rd of instruction at i-2 if it was a load

    while sim.cycle_count < max_cycles and not sim.halted:
        inst = sim.fetch()
        opcode = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F

        uses_rs1 = opcode in (0x03, 0x13, 0x33, 0x23, 0x63, 0x67)  # Load/ALU-I/ALU-R/Store/Branch/JALR
        uses_rs2 = opcode in (0x33, 0x23, 0x63)                     # ALU-R/Store/Branch

        # load_in_ex: previous instruction was a load, current depends on it
        if prev_load_rd != 0:
            if (uses_rs1 and rs1 == prev_load_rd) or \
               (uses_rs2 and rs2 == prev_load_rd):
                n1_stalls += 1

        # load_in_mem: two-back instruction was a load (and i-1 was NOT a stall
        # on the same load — that case is already counted as n1 with 2 cycles).
        # Only count if i-1 did NOT also depend on this load (otherwise absorbed).
        if prev_prev_load_rd != 0 and prev_prev_load_rd != prev_load_rd:
            if (uses_rs1 and rs1 == prev_prev_load_rd) or \
               (uses_rs2 and rs2 == prev_prev_load_rd):
                n2_stalls += 1

        # Shift history
        prev_prev_load_rd = prev_load_rd
        if opcode == 0x03 and rd != 0:
            prev_load_rd = rd
        else:
            prev_load_rd = 0

        sim.step()

    return sim.cycle_count, n1_stalls, n2_stalls


def main():
    base = os.path.dirname(os.path.abspath(__file__))
    programs = ['current', 'src0', 'src1', 'src2']

    # Cache configurations to test
    # (name, total_bytes, line_bytes, assoc, line_words)
    configs = [
        # ---- Direct-mapped, 16B line (current line size) ----
        ("DM  1KB/16B",  1024, 16, 1, 4),
        ("DM  2KB/16B",  2048, 16, 1, 4),
        ("DM  4KB/16B",  4096, 16, 1, 4),
        ("DM  8KB/16B",  8192, 16, 1, 4),
        # ---- 2-way, 16B line ----
        ("2W  1KB/16B",  1024, 16, 2, 4),
        ("2W  2KB/16B",  2048, 16, 2, 4),  # ← current RTL config
        ("2W  4KB/16B",  4096, 16, 2, 4),
        ("2W  8KB/16B",  8192, 16, 2, 4),
        # ---- 4-way, 16B line ----
        ("4W  2KB/16B",  2048, 16, 4, 4),
        ("4W  4KB/16B",  4096, 16, 4, 4),
        # ---- 2-way, 32B line (larger line, more spatial locality) ----
        ("2W  2KB/32B",  2048, 32, 2, 8),
        ("2W  4KB/32B",  4096, 32, 2, 8),
    ]

    # Performance model parameters (matching RTL)
    FREQ_BASE = 200     # MHz (current stable, no DCache)
    FREQ_CACHE = 250    # MHz (target with DCache, pending timing closure)
    DRAM_LATENCY = 4    # registered addr(1) + BRAM read(1) + DOB_REG(1) + dram_rdata_r(1)

    print("=" * 110)
    print(" Data Cache Hit Rate & Cycle-Accurate Performance Simulation")
    print(" (Matches RTL dcache.sv: WT+WA, 1-entry SB, DRAM_LATENCY=4)")
    print("=" * 110)

    # Per-config summary across all programs
    summary = {c[0]: [] for c in configs}

    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if not os.path.exists(irom_path):
            continue

        print(f"\n{'─' * 110}")
        print(f"  Program: {prog}")
        print(f"{'─' * 110}")

        irom = load_coe(irom_path)
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []

        # Run ISA sim to collect memory trace
        sim = RV32ISim(irom, dram)
        trace = sim.run(max_cycles=5000000)

        total_insts = sim.cycle_count
        n_loads = sum(1 for _, rw, _, _ in trace if rw == 'R')
        n_stores = sum(1 for _, rw, _, _ in trace if rw == 'W')

        # Run load-use hazard analysis
        _, n1_stalls, n2_stalls = count_load_use_stalls(irom, dram, max_cycles=5000000)
        # Raw penalty: n1 = 2 cycles (load_in_ex), n2 = 1 cycle (load_in_mem)
        raw_lu_penalty = n1_stalls * 2 + n2_stalls * 1

        # Unique addresses accessed
        unique_addrs = len(set((a >> 2) for a, _, _, _ in trace))
        addr_range = 0
        if trace:
            min_a = min(a for a, _, _, _ in trace)
            max_a = max(a for a, _, _, _ in trace)
            addr_range = max_a - min_a

        # Count consecutive stores in trace (for SB pressure analysis)
        consec_stores = 0
        max_consec_st = 0
        cur_consec = 0
        for _, rw, _, _ in trace:
            if rw == 'W':
                cur_consec += 1
                if cur_consec >= 2:
                    consec_stores += 1
                max_consec_st = max(max_consec_st, cur_consec)
            else:
                cur_consec = 0

        print(f"  Instructions:     {total_insts:,}")
        print(f"  DRAM accesses:    {len(trace):,} (loads={n_loads:,}, stores={n_stores:,})")
        print(f"  Unique words:     {unique_addrs:,}")
        print(f"  Address range:    {addr_range:,} bytes ({addr_range/1024:.1f} KB)")
        print(f"  Consec store pairs: {consec_stores:,}  (max burst: {max_consec_st})")
        print(f"  Load-use hazards: {n1_stalls:,} (N+1, 2cyc) + {n2_stalls:,} (N+2, 1cyc) = {raw_lu_penalty:,} raw stall cycles")

        # ---- Baseline: no DCache @ 200MHz ----
        # Without cache, every DRAM access is a direct DRAM read/write.
        # DRAM read latency = DRAM_LATENCY cycles per load.
        # Stores go directly to DRAM (assume 1 cycle if no contention).
        # Load-use stalls are absorbed into DRAM read latency (every load stalls MEM).
        base_dram_penalty = n_loads * DRAM_LATENCY + n_stores * 1
        base_cpi = 1.0 + base_dram_penalty / total_insts
        base_time_factor = base_cpi / FREQ_BASE

        # ---- Table header ----
        W = 110
        print(f"\n  {'Config':<16s} {'Hit%':>7s} {'LdHit%':>7s} {'StHit%':>7s} "
              f"{'Refill':>8s} {'SBstall':>8s} {'TotStall':>9s} "
              f"{'CPI@250':>8s} {'vs200MHz':>9s}")
        print(f"  {'-'*16} {'-'*7} {'-'*7} {'-'*7} "
              f"{'-'*8} {'-'*8} {'-'*9} "
              f"{'-'*8} {'-'*9}")

        for name, total_b, line_b, assoc, lw in configs:
            cache = CacheSim(name, total_b, line_b, assoc,
                             line_words=lw, dram_latency=DRAM_LATENCY)

            for addr, rw, sz, iidx in trace:
                cache.access(addr, rw, inst_idx=iidx)

            hr = cache.hit_rate()
            lhr = cache.load_hits / (cache.load_hits + cache.load_misses) * 100 \
                if (cache.load_hits + cache.load_misses) else 0
            shr = cache.store_hits / (cache.store_hits + cache.store_misses) * 100 \
                if (cache.store_hits + cache.store_misses) else 0

            # CPI estimation at 250MHz with cache
            # Load-use stalls only cost extra cycles for cache-HITTING loads.
            # Cache-MISSING loads already stall the pipeline (refill), absorbing load-use.
            # Approximate: scale raw load-use penalty by load hit rate.
            dcache_stall = cache.total_stall_cycles()
            load_hr_frac = lhr / 100 if lhr > 0 else 0
            effective_lu = int(raw_lu_penalty * load_hr_frac)
            cache_cpi = 1.0 + (dcache_stall + effective_lu) / total_insts
            cache_time_factor = cache_cpi / FREQ_CACHE

            speedup = base_time_factor / cache_time_factor if cache_time_factor > 0 else 0
            speedup_pct = (speedup - 1) * 100

            is_current = (name == "2W  2KB/16B")
            marker = " ◄" if is_current else ""

            print(f"  {name:<16s} {hr:6.2f}% {lhr:6.2f}% {shr:6.2f}% "
                  f"{cache.refill_stall_cycles:>8,} {cache.sb_drain_stall_cycles:>8,} "
                  f"{dcache_stall:>9,} "
                  f"{cache_cpi:>7.3f}  "
                  f"{'%+.1f%%' % speedup_pct:>8s}{marker}")

            summary[name].append({
                'prog': prog, 'hit_rate': hr, 'misses': cache.misses,
                'refill_stall': cache.refill_stall_cycles,
                'sb_stall': cache.sb_drain_stall_cycles,
                'sb_conflicts': cache.sb_conflict_stalls,
                'total_stall': dcache_stall,
                'cpi': cache_cpi, 'speedup': speedup_pct,
            })

        # Show baseline info
        print(f"\n  Baseline (no cache @200MHz): CPI={base_cpi:.3f} "
              f"(DRAM penalty={base_dram_penalty:,}, load-use absorbed)")

    # ================================================================
    #  Cross-program Summary
    # ================================================================
    print(f"\n{'=' * 110}")
    print(f"  Cross-program Summary (average over {len(programs)} programs)")
    print(f"{'=' * 110}")
    print(f"\n  {'Config':<16s} {'AvgHit%':>8s} {'AvgCPI':>8s} {'AvgSpeedup':>11s} "
          f"{'AvgRefill':>10s} {'AvgSBstall':>11s} {'BRAM18':>7s}")
    print(f"  {'-'*16} {'-'*8} {'-'*8} {'-'*11} "
          f"{'-'*10} {'-'*11} {'-'*7}")

    for name, total_b, line_b, assoc, lw in configs:
        entries = summary[name]
        if not entries: continue
        n = len(entries)
        avg_hr = sum(e['hit_rate'] for e in entries) / n
        avg_cpi = sum(e['cpi'] for e in entries) / n
        avg_sp = sum(e['speedup'] for e in entries) / n
        avg_rf = sum(e['refill_stall'] for e in entries) / n
        avg_sb = sum(e['sb_stall'] for e in entries) / n
        # BRAM18 estimate: each way needs data_depth * 32b.
        # data_depth = (total_b / assoc) / 4 bytes_per_word = entries_per_way
        # Each BRAM18 = 1024 x 18b or 512 x 36b. For 32b width: 512 entries/BRAM18.
        data_bram18 = assoc * max(1, (total_b // assoc // 4) // 512)
        # Tag RAM: LUTRAM (no BRAM), so only count data BRAM
        is_current = (name == "2W  2KB/16B")
        marker = " ◄" if is_current else ""

        print(f"  {name:<16s} {avg_hr:7.2f}% {avg_cpi:>7.3f}  "
              f"{'%+.1f%%' % avg_sp:>10s} "
              f"{avg_rf:>10,.0f} {avg_sb:>11,.0f} "
              f"{data_bram18:>6}×{marker}")

    # ================================================================
    #  Performance model notes
    # ================================================================
    print(f"\n  ── Performance Model ──")
    print(f"  Refill penalty:   LINE_WORDS + DRAM_LATENCY + 1 = 4 + {DRAM_LATENCY} + 1 = "
          f"{4 + DRAM_LATENCY + 1} cycles/miss")
    print(f"  SB drain penalty: 2 cycles (S_SB_DRAIN + re-enter S_IDLE)")
    print(f"  SB conflict:      store hit while SB valid → drain first")
    print(f"  Load-use stall:   2 cycles (load_in_ex) or 1 cycle (load_in_mem)")
    print(f"                    Only effective for cache-hitting loads (miss absorbs stall)")
    print(f"  Baseline (no cache): every load costs {DRAM_LATENCY} cycles DRAM latency")
    print(f"  Speedup = (baseline_CPI/200) / (cache_CPI/250)")
    print(f"  ◄ = current RTL config (2W 2KB/16B)")
    print()


if __name__ == '__main__':
    main()
