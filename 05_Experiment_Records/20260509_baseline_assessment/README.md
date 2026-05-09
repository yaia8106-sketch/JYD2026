# 20260509 Baseline Assessment

## Purpose

Establish a clean performance and timing baseline before any new RTL work.

The goal is to decide the next optimization direction from data, not from intuition:

- official small perf cycles
- COE software-model CPI/stall attribution
- dynamic hot PCs for branch misses, load-use stalls, and dual-issue blockers
- Vivado baseline timing at the current RTL

## Baseline

- Branch: `perf/assess-before-rtl`
- Design commit: `b035609`
- RTL changes: none
- Parallelism: 18 jobs where supported

## Commands

See `commands.sh`.

## Raw Logs

Raw outputs are kept locally under `raw/`:

- `run_perf_default.log`
- `cpi_attribution_current_src0_src1_src2.log`
- `coe_hotspots_src0_src1_src2.log`
- `vivado_flow_current_18.log`
- `stage_timing_report.txt`
- `top_timing_summary_routed.rpt`
- `top_route_status.rpt`
- `top_utilization_placed.rpt`

`raw/` is intentionally ignored by git.

## Results Summary

### Official Perf

| test | cycles | CPI | dual issue | main observed cost |
|------|--------|-----|------------|--------------------|
| `bp_stress` | 2009 | 1.112 | 22.8% | branch mispredict 26.3%, load-use 53 cycles |
| `dcache_stress` | 1135 | 1.528 | 25.5% | load-use 466 cycles, DCache miss 308 cycles |
| `counter_stress` | 389 | 0.911 | 56.4% | load-use 55 cycles, repair wait 37 cycles |
| `sb_stress` | 112 | 1.000 | 60.0% | DCache miss 26 cycles, load-use 6 cycles |
| **total** | **3645** | | | |

### COE CPI Attribution

Software-model attribution for `src0/src1/src2`, weighted by instruction count:

| metric | value |
|--------|-------|
| adjusted CPI | 0.957 |
| raw CPI | 0.780 |
| branch flush dCPI | 0.149 |
| load-use dCPI | 0.066 |
| small frontend queue upper-bound dCPI | 0.045 |
| DCache miss dCPI | 0.028 |
| dual issue rate | 28.2% |
| branch mispredict rate | 27.1% |
| DCache miss rate | 1.7% |

Dual-issue blockers on `src0/src1/src2`:

| blocker | count | share of S0 |
|---------|-------|-------------|
| slot1 not ALU | 2049953 | 34.2% |
| not sequential | 1191953 | 19.9% |
| same-pair RAW | 745647 | 12.4% |
| slot0 jump | 320042 | 5.3% |

The software model did not run these programs to LED completion under this command; the data is a prefix-based attribution sample.

### Hotspots

The dominant branch-mispredict PCs are concentrated in division/modulo helper loops:

| program | top branch-mispredict PCs |
|---------|---------------------------|
| `src0` | `0x80001fb4 beqz`, `0x80001fc4 bnez`, `0x80001f28 bltu`, `0x80001f3c bnez`, `0x80001f20 bltu` |
| `src1` | `0x80001d30 bltu`, `0x80001d44 bnez`, `0x80001d28 bltu`, `0x80001dcc bnez`, `0x80001dbc beqz` |
| `src2` | `0x80001f18 beqz`, `0x80001e8c bltu`, `0x80001f28 bnez`, `0x80001ea0 bnez`, `0x80001e84 bltu` |

Slot1-not-ALU blockers are also concentrated around these helper loops, especially `andi ..., 1` followed by a branch and nearby shift/compare instructions.

### Vivado Timing

`./run_vivado_flow.sh current 18` completed successfully.

| metric | value |
|--------|-------|
| post-route WNS | +0.049ns |
| post-route TNS | 0.000ns |
| post-route WHS | +0.082ns |
| failing endpoints | 0 |
| placed Slice LUTs | 8618 |
| placed Slice Registers | 4727 |
| Block RAM Tile | 73 |
| DSPs | 0 |

Tightest stage-level paths:

| rank | path | slack | data path | levels |
|------|------|-------|-----------|--------|
| 1 | `ID/EX -> ID/EX` | +0.049ns | 4.895ns | 24 |
| 2 | `Pre_IF(PC) -> IROM(BRAM)` | +0.109ns | 4.447ns | 9 |
| 3 | `IF/ID -> ID/EX` | +0.124ns | 4.793ns | 10 |
| 4 | `IROM(BRAM) -> IF/ID` | +0.142ns | 4.702ns | 9 |
| 5 | `RegFile -> ID/EX` | +0.171ns | 4.617ns | 14 |

Global worst path:

```text
u_cpu/u_id_ex_reg/ex_alu_src1_reg[5]/C
-> u_cpu/u_id_ex_reg/ex_branch_taken_reg/D
slack +0.049ns, data path 4.895ns, 24 logic levels
```

## Decision

Do not start RTL from this record alone. The next step is a focused software-model estimate for branch-heavy helper-loop improvements.

Candidate ranking from this baseline:

1. Branch-side work has the largest measured headroom (`dCPI~0.149`), but zero-cycle ID actual redirect is already rejected. Any new attempt must avoid adding logic to the IF/IROM address path.
2. Load-use work has meaningful headroom (`dCPI~0.066`) but must be separated by consumer class; previous broad MEM-ready changes were not timing-safe.
3. Frontend queue style decoupling is not attractive (`Q<=0.045` upper bound and previous RTL result was only -3 cycles with severe WNS loss).
4. DCache miss work is lower priority for CPU RTL (`dCPI~0.028`) unless a very small, timing-neutral change appears.

Concrete next experiment:

- Build a software-model estimate for branch helper-loop options, especially local-history or pattern-targeted prediction around the hot `bltu/bnez/beqz` loops.
- Include an explicit timing risk note before any RTL: no zero-cycle ID actual redirect, no new IF/IROM address-path logic.
