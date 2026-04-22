#!/usr/bin/env python3
"""
DCache Architecture Sweep Simulator (Parallel)
================================================
Uses multiprocessing to evaluate 864 cache configs across 4 programs.
"""

import os, struct, sys
from collections import defaultdict
from itertools import product
from multiprocessing import Pool, cpu_count

# ==============================
# RV32I Simulator
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
        self.mem_trace = []
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
            self.mem_trace.append((addr, 'R'))
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
        self.mem_trace.append((addr, 'W'))
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
            if taken: next_pc = target
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
# Single-pass Cache Simulator
# ==============================

def sim_one_config(args):
    """
    Simulate one cache config on one program trace.
    Single pass: counts hits/misses/events AND computes stall cycles simultaneously.

    Returns dict with all results, for all dram_cpw values.
    """
    (cap, assoc, lsz, wp, wa, cwf, wbuf, dram_cpw_list,
     prog_name, trace, n_insts) = args

    words_per_line = lsz // 4
    n_lines = cap // lsz
    n_sets = n_lines // assoc
    offset_bits = (lsz - 1).bit_length()
    index_bits = (n_sets - 1).bit_length() if n_sets > 1 else 0
    index_mask = n_sets - 1
    fsm_overhead = 2

    # Cache state: array of (valid, dirty, tag) per way per set
    cache = [[(False, False, 0) for _ in range(assoc)] for _ in range(n_sets)]
    lru = [[0] * assoc for _ in range(n_sets)]
    lru_counter = 0

    # Counters
    load_hits = 0
    load_misses = 0
    store_hits = 0
    store_misses = 0
    dirty_evictions = 0

    # Event counters for stall computation
    refill_count = 0          # number of refill events
    nwa_store_miss_count = 0  # NWA store misses (write directly to DRAM)
    wt_store_hit_count = 0    # WT store hits (write through to DRAM)
    dirty_wb_count = 0        # dirty evictions requiring writeback

    for addr, rw in trace:
        idx = (addr >> offset_bits) & index_mask
        tag = addr >> (offset_bits + index_bits)
        s = cache[idx]

        # Check hit
        hit_way = -1
        for w in range(assoc):
            if s[w][0] and s[w][2] == tag:
                hit_way = w
                break

        if hit_way >= 0:
            # HIT
            lru_counter += 1
            lru[idx][hit_way] = lru_counter
            if rw == 'R':
                load_hits += 1
            else:
                store_hits += 1
                if wp == 'WB':
                    s[hit_way] = (True, True, tag)
                else:  # WT
                    wt_store_hit_count += 1
        else:
            # MISS
            if rw == 'R':
                load_misses += 1
            else:
                store_misses += 1

            # Allocate?
            if rw == 'W' and not wa:
                # NWA store miss: write to DRAM, no cache update
                nwa_store_miss_count += 1
                continue

            # Find LRU victim
            min_lru = lru[idx][0]
            victim = 0
            for w in range(1, assoc):
                if lru[idx][w] < min_lru:
                    min_lru = lru[idx][w]
                    victim = w

            # Check dirty eviction (WB only)
            if s[victim][0] and s[victim][1] and wp == 'WB':
                dirty_evictions += 1
                dirty_wb_count += 1

            # Install
            dirty = (rw == 'W' and wp == 'WB')
            s[victim] = (True, dirty, tag)
            lru_counter += 1
            lru[idx][victim] = lru_counter
            refill_count += 1
            if rw == 'W' and wp == 'WT':
                wt_store_hit_count += 1  # WT also writes to DRAM on allocate

    # Compute results for each dram_cpw
    total_accesses = load_hits + load_misses + store_hits + store_misses
    total_hits = load_hits + store_hits
    hit_rate = total_hits / total_accesses * 100 if total_accesses else 0
    load_hr = load_hits / (load_hits + load_misses) * 100 if (load_hits + load_misses) else 0
    store_hr = store_hits / (store_hits + store_misses) * 100 if (store_hits + store_misses) else 0

    strat = _strategy_name(wp, wa, cwf, wbuf)
    results = []

    for cpw in dram_cpw_list:
        # Stall from refills
        refill_words = 1 if cwf else words_per_line
        stall_refill = refill_count * (fsm_overhead + refill_words * cpw)

        # Stall from dirty writebacks
        if wbuf:
            stall_dirty = 0  # write buffer absorbs
        else:
            stall_dirty = dirty_wb_count * (words_per_line * cpw)

        # Stall from NWA store misses (write 1 word to DRAM)
        stall_nwa = nwa_store_miss_count * (fsm_overhead + 1 * cpw)

        # Stall from WT store hits (write 1 word to DRAM)
        if wbuf:
            stall_wt = 0  # store buffer absorbs
        else:
            stall_wt = wt_store_hit_count * (1 * cpw)

        total_stall = stall_refill + stall_dirty + stall_nwa + stall_wt
        cpi = 1.0 + total_stall / n_insts if n_insts else 999
        speedup = (250.0 / cpi) / 200.0

        results.append({
            'cap': cap, 'assoc': assoc, 'line': lsz,
            'strategy': strat,
            'wp': wp, 'wa': wa, 'cwf': cwf, 'wbuf': wbuf,
            'dram_cpw': cpw,
            'prog': prog_name,
            'hit_rate': hit_rate,
            'load_hr': load_hr,
            'store_hr': store_hr,
            'misses': load_misses + store_misses,
            'dirty_evict': dirty_evictions,
            'stall': total_stall,
            'cpi': cpi,
            'speedup': speedup,
        })

    return results


def _strategy_name(wp, wa, cwf, wbuf):
    parts = [wp]
    parts.append('WA' if wa else 'NWA')
    if cwf: parts.append('CWF')
    if wbuf: parts.append('WBuf')
    return '+'.join(parts)


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


# ==============================
# Main
# ==============================

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    programs = ['current', 'src0', 'src1', 'src2']
    n_cores = min(cpu_count(), 24)

    # Parameter space
    capacities = [1024, 2048, 4096]
    assocs     = [1, 2, 4]
    line_sizes = [4, 8, 16, 32]
    dram_cpw   = [1, 2, 3]

    strategies = [
        ('WT', True,  False, True),
        ('WT', True,  True,  True),
        ('WT', False, False, True),
        ('WT', False, True,  True),
        ('WB', True,  False, False),
        ('WB', True,  True,  False),
        ('WB', True,  False, True),
        ('WB', True,  True,  True),
    ]

    # Load traces
    program_data = {}
    for prog in programs:
        irom_path = os.path.join(base, prog, 'irom.coe')
        dram_path = os.path.join(base, prog, 'dram.coe')
        if not os.path.exists(irom_path):
            continue
        irom = load_coe(irom_path)
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []
        sim = RV32ISim(irom, dram)
        trace = sim.run(max_cycles=5000000)
        # Convert to simple list of tuples for pickling
        trace_simple = [(a, rw) for a, rw in trace]
        program_data[prog] = {
            'trace': trace_simple,
            'insts': sim.cycle_count,
            'loads': sum(1 for _, rw in trace_simple if rw == 'R'),
            'stores': sum(1 for _, rw in trace_simple if rw == 'W'),
        }
        print(f"[Trace] {prog}: {sim.cycle_count:,} insts, "
              f"{len(trace_simple):,} DRAM accesses "
              f"(L={program_data[prog]['loads']:,}, S={program_data[prog]['stores']:,})")

    if not program_data:
        print("ERROR: No programs found!")
        return

    # Build task list
    tasks = []
    for cap, assoc, lsz in product(capacities, assocs, line_sizes):
        if lsz > cap // assoc or cap // (lsz * assoc) < 1:
            continue
        for wp, wa, cwf, wbuf in strategies:
            for prog_name, pdata in program_data.items():
                tasks.append((
                    cap, assoc, lsz, wp, wa, cwf, wbuf, dram_cpw,
                    prog_name, pdata['trace'], pdata['insts']
                ))

    n_configs = len(tasks)
    print(f"\nDispatching {n_configs} tasks across {n_cores} cores...\n")

    # Parallel execution
    with Pool(n_cores) as pool:
        raw_results = pool.map(sim_one_config, tasks, chunksize=4)

    # Flatten results
    results = []
    for batch in raw_results:
        results.extend(batch)

    print(f"Collected {len(results)} result entries. Aggregating...\n")

    # Aggregate across programs
    agg = defaultdict(list)
    for r in results:
        key = (r['cap'], r['assoc'], r['line'], r['strategy'], r['dram_cpw'])
        agg[key].append(r)

    agg_results = []
    for key, entries in agg.items():
        cap, assoc, line, strat, cpw = key
        n = len(entries)
        agg_results.append({
            'cap': cap, 'assoc': assoc, 'line': line,
            'strategy': strat, 'dram_cpw': cpw,
            'avg_hr': sum(e['hit_rate'] for e in entries) / n,
            'avg_cpi': sum(e['cpi'] for e in entries) / n,
            'avg_speedup': sum(e['speedup'] for e in entries) / n,
            'avg_stall': sum(e['stall'] for e in entries) / n,
            'avg_dirty': sum(e['dirty_evict'] for e in entries) / n,
        })

    agg_results.sort(key=lambda x: x['avg_cpi'])

    # Print results grouped by dram_cpw
    print("=" * 120)
    print(" DCache Architecture Sweep Results (averaged across programs)")
    print(" Sorted by Effective CPI (lower = better)")
    print("=" * 120)

    for cpw in dram_cpw:
        subset = [r for r in agg_results if r['dram_cpw'] == cpw]
        if not subset:
            continue
        subset.sort(key=lambda x: x['avg_cpi'])
        print(f"\n{'─' * 120}")
        print(f"  DRAM = {cpw} cycle(s)/word")
        print(f"{'─' * 120}")
        print(f"  {'Rank':>4}  {'Cap':>5}  {'Assoc':>5}  {'Line':>5}  {'Strategy':<20}  "
              f"{'HitRate':>7}  {'AvgCPI':>7}  {'Speedup':>8}  {'AvgStall':>10}  {'DirtyEvict':>10}")
        print(f"  {'─'*4}  {'─'*5}  {'─'*5}  {'─'*5}  {'─'*20}  "
              f"{'─'*7}  {'─'*7}  {'─'*8}  {'─'*10}  {'─'*10}")

        for rank, r in enumerate(subset[:30], 1):
            cap_s = f"{r['cap']//1024}KB"
            assoc_s = f"{r['assoc']}W" if r['assoc'] > 1 else "DM"
            line_s = f"{r['line']}B"
            sp_pct = f"{(r['avg_speedup']-1)*100:+.1f}%"
            print(f"  {rank:>4}  {cap_s:>5}  {assoc_s:>5}  {line_s:>5}  {r['strategy']:<20}  "
                  f"{r['avg_hr']:6.2f}%  {r['avg_cpi']:7.3f}  {sp_pct:>8}  "
                  f"{r['avg_stall']:>10.0f}  {r['avg_dirty']:>10.0f}")

    # Best per dram_cpw
    print(f"\n{'=' * 120}")
    print(f"  BEST CONFIG per DRAM latency")
    print(f"{'=' * 120}")
    for cpw in dram_cpw:
        subset = [r for r in agg_results if r['dram_cpw'] == cpw]
        if subset:
            subset.sort(key=lambda x: x['avg_cpi'])
            best = subset[0]
            cap_s = f"{best['cap']//1024}KB"
            assoc_s = f"{best['assoc']}W" if best['assoc'] > 1 else "DM"
            sp_pct = f"{(best['avg_speedup']-1)*100:+.1f}%"
            print(f"  DRAM {cpw} cyc/word → {cap_s}/{assoc_s}/{best['line']}B "
                  f"{best['strategy']:<20} CPI={best['avg_cpi']:.3f}  {sp_pct}")

    # Per-program detail for top 5 @ dram=2
    print(f"\n{'=' * 120}")
    print(f"  Per-program detail (Top 5 configs @ DRAM=2 cyc/word)")
    print(f"{'=' * 120}")
    subset_2 = [r for r in agg_results if r['dram_cpw'] == 2]
    subset_2.sort(key=lambda x: x['avg_cpi'])
    top5_keys = [(r['cap'], r['assoc'], r['line'], r['strategy'], 2)
                 for r in subset_2[:5]]

    for key in top5_keys:
        cap, assoc, line, strat, cpw = key
        cap_s = f"{cap//1024}KB"
        assoc_s = f"{assoc}W" if assoc > 1 else "DM"
        print(f"\n  Config: {cap_s}/{assoc_s}/{line}B  {strat}")
        print(f"  {'Program':<12} {'HitRate':>7} {'LoadHR':>7} {'StoreHR':>7} "
              f"{'Misses':>8} {'Stall':>8} {'CPI':>7} {'Speedup':>8}")
        print(f"  {'─'*12} {'─'*7} {'─'*7} {'─'*7} {'─'*8} {'─'*8} {'─'*7} {'─'*8}")
        entries = [r for r in results
                   if r['cap']==cap and r['assoc']==assoc and r['line']==line
                   and r['strategy']==strat and r['dram_cpw']==cpw]
        for e in entries:
            sp_pct = f"{(e['speedup']-1)*100:+.1f}%"
            print(f"  {e['prog']:<12} {e['hit_rate']:6.2f}% {e['load_hr']:6.2f}% "
                  f"{e['store_hr']:6.2f}% {e['misses']:>8,} {e['stall']:>8,} "
                  f"{e['cpi']:>7.3f} {sp_pct:>8}")

    print()


if __name__ == '__main__':
    main()
