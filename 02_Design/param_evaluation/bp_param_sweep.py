#!/usr/bin/env python3
"""Quick parameter sweep for branch predictor optimization (parallel)."""
import os, sys
import multiprocessing as mp
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bp_test_current import RV32ISim, TournamentBP, load_coe

def run_one(args):
    """Run single (config, program) combination. Designed for multiprocessing."""
    prog, trace, ghr_w, pht_size, sel_size, btb_entries, btb_tag_w, ras_depth, jalr_total_from_trace = args

    bp = TournamentBP()
    bp.BTB_ENTRIES = btb_entries
    bp.BTB_IDX_W = (btb_entries - 1).bit_length()
    bp.BTB_TAG_W = btb_tag_w
    bp.GHR_W = ghr_w
    bp.PHT_SIZE = pht_size
    bp.SEL_SIZE = sel_size
    bp.RAS_DEPTH = ras_depth
    bp.btb_valid = [False] * btb_entries
    bp.btb_tag   = [0] * btb_entries
    bp.btb_tgt   = [0] * btb_entries
    bp.btb_type  = [0] * btb_entries
    bp.btb_bht   = [0] * btb_entries
    bp.pht        = [1] * pht_size
    bp.sel_table  = [1] * sel_size
    bp.ras        = [0] * ras_depth
    bp.ras_count  = 0

    for entry in trace:
        bp.predict_and_update(*entry)

    s = bp.stats
    total = s['total']
    br_total = s['branch_total']
    return {
        'prog': prog,
        'overall': s['correct'] / total * 100 if total else 0,
        'branch': s['branch_correct'] / br_total * 100 if br_total else 0,
        'br_dir_wrong': s['br_dir_wrong'],
        'br_btb_miss_taken': s['br_btb_miss_taken'],
        'mispred': total - s['correct'] + s['jalr_total'],
    }

def main():
    base = os.path.dirname(os.path.abspath(__file__))
    programs = ['current', 'src0', 'src1', 'src2']
    NCPU = min(24, mp.cpu_count())

    # Load traces (serial — I/O bound)
    print(f"Loading traces (will use {NCPU} cores for sweep)...")
    traces = {}
    instr_counts = {}
    jalr_counts = {}
    for prog in programs:
        irom = load_coe(os.path.join(base, prog, 'irom.coe'))
        dram_path = os.path.join(base, prog, 'dram.coe')
        dram = load_coe(dram_path) if os.path.exists(dram_path) else []
        sim = RV32ISim(irom, dram)
        traces[prog] = sim.run(max_cycles=5000000)
        instr_counts[prog] = sim.cycle_count
        jalr_counts[prog] = sum(1 for _, t, _, _, _, _ in traces[prog] if t == 'JALR')
    print("Done.\n")

    # Configs: (label, ghr_w, pht_size, sel_size, btb_entries, btb_tag_w, ras_depth)
    configs = [
        ("Current (baseline)",     8,   256,   256,  64, 5, 4),
        ("GHR=10, PHT=1024",     10,  1024,  1024,  64, 5, 4),
        ("GHR=12, PHT=4096",     12,  4096,  4096,  64, 5, 4),
        ("GHR=14, PHT=16384",    14, 16384, 16384,  64, 5, 4),
        ("GHR=12 + BTB=128",     12,  4096,  4096, 128, 5, 4),
        ("GHR=12 + BTB=256",     12,  4096,  4096, 256, 5, 4),
        ("GHR=12 + BTB=128 + RAS=8", 12, 4096, 4096, 128, 5, 8),
    ]

    # Build all jobs: (config_idx, prog, trace, params...)
    jobs = []
    for ci, (label, ghr_w, pht_size, sel_size, btb_n, btb_tag, ras_d) in enumerate(configs):
        for prog in programs:
            jobs.append((prog, traces[prog], ghr_w, pht_size, sel_size, btb_n, btb_tag, ras_d, jalr_counts[prog]))

    # Run in parallel
    print(f"Running {len(jobs)} jobs on {NCPU} cores...")
    with mp.Pool(NCPU) as pool:
        raw_results = pool.map(run_one, jobs)
    print("Done.\n")

    # Reorganize: results[config_idx][prog] = {...}
    idx = 0
    all_results = []
    for ci in range(len(configs)):
        cfg_res = {}
        for prog in programs:
            cfg_res[prog] = raw_results[idx]
            idx += 1
        all_results.append(cfg_res)

    # === Print Overall accuracy ===
    print(f"{'Config':<32s}", end="")
    for prog in programs:
        print(f" {prog:>10s}", end="")
    print(f"  {'Avg':>8s}  {'AvgCPI':>7s}")
    print("-" * 105)

    for ci, (label, *_) in enumerate(configs):
        accs, cpis = [], []
        print(f"{label:<32s}", end="")
        for prog in programs:
            r = all_results[ci][prog]
            print(f"  {r['overall']:7.2f}%", end="")
            accs.append(r['overall'])
            cpi = 1.0 + r['mispred'] * 3 / instr_counts[prog]
            cpis.append(cpi)
        print(f"  {sum(accs)/len(accs):7.2f}%  {sum(cpis)/len(cpis):7.3f}")

    # === Print BRANCH accuracy ===
    print(f"\n{'--- BRANCH accuracy ---':<32s}", end="")
    for prog in programs:
        print(f" {prog:>10s}", end="")
    print(f"  {'Avg':>8s}")
    print("-" * 95)

    for ci, (label, *_) in enumerate(configs):
        accs = []
        print(f"{label:<32s}", end="")
        for prog in programs:
            r = all_results[ci][prog]
            print(f"  {r['branch']:7.2f}%", end="")
            accs.append(r['branch'])
        print(f"  {sum(accs)/len(accs):7.2f}%")


if __name__ == '__main__':
    main()
