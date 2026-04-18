"""多核并行全参数扫描"""
import os, sys, datetime, multiprocessing as mp
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bp_simulator import RV32ISim, load_coe

def sim_bp(args):
    trace, btb_size, bht_mode, bht_size, ras_depth, assoc, base_penalty, total_cycles, name = args
    n_sets = btb_size // assoc
    btb = [[None]*assoc for _ in range(n_sets)]
    lru = [0] * n_sets
    if bht_mode == 'embedded':
        bht_arr = [[1]*assoc for _ in range(n_sets)]
    else:
        bht_arr = [1] * bht_size
    ras = []
    total = 0; correct = 0; flush_needed = 0
    for pc, itype, actual_taken, actual_target in trace:
        if itype == 'JALR': flush_needed += 1; continue
        total += 1
        si = (pc >> 2) & (n_sets - 1)
        tg = pc >> (2 + (n_sets - 1).bit_length())
        hw = -1
        for w in range(assoc):
            e = btb[si][w]
            if e and e[0] == tg: hw = w; break
        pt = False; pp = pc + 4
        if hw >= 0:
            e = btb[si][hw]
            et = e[2]
            if et == 3:
                if ras: pt = True; pp = ras[-1]
            elif et <= 1:
                pt = True; pp = e[1]
            elif et == 2:
                cnt = bht_arr[si][hw] if bht_mode == 'embedded' else bht_arr[(pc>>2)&(bht_size-1)]
                if cnt >= 2: pt = True; pp = e[1]
            if assoc == 2: lru[si] = 1 - hw
        ok = (pt and pp == actual_target) if actual_taken else (not pt)
        if ok: correct += 1
        else: flush_needed += 1
        if actual_taken or itype == 'BRANCH':
            uw = hw if hw >= 0 else (lru[si] if assoc == 2 else 0)
            TYPE_MAP = {'JAL':0,'CALL':1,'BRANCH':2,'RET':3}
            btb[si][uw] = (tg, actual_target, TYPE_MAP.get(itype,0))
            if assoc == 2: lru[si] = 1 - uw
            if bht_mode == 'embedded' and itype == 'BRANCH':
                bht_arr[si][uw] = min(3, bht_arr[si][uw]+1) if actual_taken else max(0, bht_arr[si][uw]-1)
        if bht_mode == 'separate' and itype == 'BRANCH':
            bi = (pc>>2) & (bht_size-1)
            bht_arr[bi] = min(3, bht_arr[bi]+1) if actual_taken else max(0, bht_arr[bi]-1)
        if itype == 'CALL':
            ras.append(pc+4)
            if len(ras) > ras_depth: ras.pop(0)
        elif itype == 'RET' and ras: ras.pop()
    hr = correct/total*100 if total else 0
    cs = (base_penalty - flush_needed*2)/total_cycles if total_cycles else 0
    return name, hr, cs

if __name__ == '__main__':
    base = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(base, 'sim_output')
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, 'bp_sweep.txt')
    outfile = open(outpath, 'w', encoding='utf-8')

    def out(s=''):
        print(s, flush=True)
        outfile.write(s + '\n')

    ncpu = mp.cpu_count()
    out(f"使用 {ncpu} 个 CPU 核心并行")

    # 生成 trace
    traces = {}
    for prog in ['current','src0','src1','src2']:
        irom = load_coe(os.path.join(base, prog, 'irom.coe'))
        dram = load_coe(os.path.join(base, prog, 'dram.coe'))
        sim = RV32ISim(irom, dram); trace = sim.run(5000000)
        bp = sum(1 for _,_,t,_ in trace if t) * 2
        traces[prog] = (trace, bp, sim.cycle_count)
        out(f"  {prog}: {sim.cycle_count:,} cycles, {len(trace):,} 跳转")

    # 配置列表
    configs = []
    for btb_sz in [32, 64]:
        for assoc in [1, 2]:
            for bht_mode in ['embedded', 'separate']:
                bht_szs = [btb_sz] if bht_mode == 'embedded' else [128, 256]
                for bht_sz in bht_szs:
                    for ras_d in [0, 2, 4, 8]:
                        n = f"BTB{btb_sz}{'x2' if assoc==2 else ''} BHT{'内' if bht_mode=='embedded' else str(bht_sz)} RAS{ras_d}"
                        configs.append((n, btb_sz, assoc, bht_mode, bht_sz, ras_d))

    out(f"\n测试 {len(configs)} 种配置 x 4 程序 = {len(configs)*4} 次模拟...")

    # 构建任务列表
    tasks = []
    for prog in ['current','src0','src1','src2']:
        trace, bp, tc = traces[prog]
        for name, btb_sz, assoc, bht_mode, bht_sz, ras_d in configs:
            key = f"{prog}|{name}"
            tasks.append((trace, btb_sz, bht_mode, bht_sz, ras_d, assoc, bp, tc, key))

    # 并行执行
    with mp.Pool(ncpu) as pool:
        results = pool.map(sim_bp, tasks)

    # 整理结果
    result_map = {}
    for key, hr, cs in results:
        result_map[key] = (hr, cs)

    # 汇总
    summary = []
    for name, btb_sz, assoc, bht_mode, bht_sz, ras_d in configs:
        row = {'name': name}
        for prog in ['current','src0','src1','src2']:
            key = f"{prog}|{name}"
            hr, cs = result_map[key]
            row[prog+'_hr'] = hr
            row[prog+'_cpi'] = cs
        row['avg_cpi'] = sum(row[p+'_cpi'] for p in ['current','src0','src1','src2']) / 4
        row['avg_hr'] = sum(row[p+'_hr'] for p in ['current','src0','src1','src2']) / 4
        summary.append(row)

    summary.sort(key=lambda x: -x['avg_cpi'])

    out(f"\n{'='*100}")
    out(f" Top 15（按平均 CPI 节省排序）")
    out(f"{'='*100}")
    out(f" {'#':>2} {'配置':<28} {'cur':>7} {'s0':>7} {'s1':>7} {'s2':>7} {'平均命中':>7} {'平均CPI省':>9}")
    out(f" {'':>2} {'-'*28} {'-'*7} {'-'*7} {'-'*7} {'-'*7} {'-'*7} {'-'*9}")
    for i, r in enumerate(summary[:15]):
        out(f" {i+1:>2} {r['name']:<28} {r['current_hr']:>6.1f}% {r['src0_hr']:>6.1f}% {r['src1_hr']:>6.1f}% {r['src2_hr']:>6.1f}% {r['avg_hr']:>6.1f}% {r['avg_cpi']:>+8.4f}")

    out(f"\n 最差 5：")
    for r in summary[-5:]:
        out(f"    {r['name']:<28} {r['current_hr']:>6.1f}% {r['src0_hr']:>6.1f}% {r['src1_hr']:>6.1f}% {r['src2_hr']:>6.1f}% {r['avg_hr']:>6.1f}% {r['avg_cpi']:>+8.4f}")

    outfile.close()
    print(f"\n结果已保存到: {outpath}")
