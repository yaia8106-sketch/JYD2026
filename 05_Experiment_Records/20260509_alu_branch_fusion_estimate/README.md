# 20260509 ALU Branch Fusion Estimate

## Purpose

Estimate whether ALU+branch same-pair fusion is worth RTL work.

This targets the hot helper-loop pattern seen in the baseline record, especially
sequences like:

```text
andi ..., 1
beqz/bnez ...
```

The question is whether issuing an ALU in slot0 and a dependent branch in slot1
can reduce runtime enough to justify the control/branch-prediction RTL risk.

## Scope

- No RTL changes.
- Functional COE issue-stream estimate only.
- Programs: `src0/src1/src2`, 3,000,000 instructions each.
- The model does not claim new Vivado timing.
- DCache and load-use behavior are assumed unchanged; the estimate focuses on
  issue-cycle savings and fused-branch redirect penalties.

## Policies

- `all_alu_branch`: any slot0 ALU followed by a conditional branch.  This is a
  broad slot1-branch upper bound.
- `raw_alu_branch`: slot0 ALU writes a register consumed by the following
  conditional branch.  This is the main fusion target.
- `zero_eqne_raw`: raw ALU->branch where the branch is BEQ/BNE against x0.
  This is the easiest-looking hardware subset.

## Prediction Assumptions

The result table reports dCPI gain under four assumptions:

- `ideal`: fused slot1 branch keeps current L1/tournament prediction quality and
  current redirect penalty.
- `l1+1`: fused slot1 branch keeps current L1/tournament prediction quality, but
  branch misses cost one extra cycle.
- `l0+1`: fused slot1 branch only gets L0-quality prediction and misses cost
  three cycles.
- `noBP`: fused slot1 branch has no slot1 prediction; fetch falls through and
  taken fused branches redirect.

`l1+1` is the main conservative-but-still-interesting model.

## Baseline

- Branch: `perf/assess-before-rtl`
- Starting commit: `2f669ff`
- Script under test: `02_Design/sim/riscv_tests/alu_branch_fusion_estimator.py`
- COE baseline adjusted CPI from previous record: `0.957`
- Parallelism: 18 jobs where supported

## Commands

See `commands.sh`.

## Raw Logs

Raw outputs are kept locally under `raw/`:

- `alu_branch_fusion_estimator.log`

`raw/` is intentionally ignored by git.

## Results Summary

Formal run completed at `2026-05-09T18:28:31+08:00`.

Weighted aggregate across `src0/src1/src2`, 3,000,000 instructions per program:

| policy | candidates | taken | L1 misses | ideal dCPI gain | `l1+1` dCPI gain | `l0+1` dCPI gain | `noBP` dCPI gain | same-clock speedup, `l1+1` | max period for same runtime |
|--------|------------|-------|-----------|-----------------|------------------|------------------|-----------------|-----------------------------|-----------------------------|
| `all_alu_branch` | 983925 | 596933 | 321501 | 0.1093 | 0.0736 | 0.0651 | 0.0481 | 7.69% | 5.417ns |
| `raw_alu_branch` | 463117 | 212378 | 237478 | 0.0515 | 0.0251 | 0.0193 | 0.0570 | 2.62% | 5.135ns |
| `zero_eqne_raw` | 462992 | 212301 | 237475 | 0.0514 | 0.0251 | 0.0193 | 0.0570 | 2.62% | 5.134ns |

Per-program `zero_eqne_raw` result:

| program | candidates | taken | L1 misses | ideal dCPI gain | `l1+1` dCPI gain | `l0+1` dCPI gain | `noBP` dCPI gain |
|---------|------------|-------|-----------|-----------------|------------------|------------------|-----------------|
| `src0` | 167355 | 80531 | 96993 | 0.0558 | 0.0235 | 0.0223 | 0.0668 |
| `src1` | 44240 | 16796 | 19465 | 0.0147 | 0.0083 | 0.0071 | 0.0165 |
| `src2` | 251397 | 114974 | 121017 | 0.0838 | 0.0435 | 0.0284 | 0.0878 |

Hot `zero_eqne_raw` PCs:

| program | dominant fused branch PCs |
|---------|---------------------------|
| `src0` | `0x80001fb4 beqz a3,0x80001fbc` occurred 167345 times |
| `src1` | `0x80001dbc beqz a3,0x80001dc4` occurred 29562 times; `0x800004a4`, `0x800004cc`, `0x8000047c` also contribute |
| `src2` | `0x80001f18 beqz a3,0x80001f20` occurred 251387 times |

Interpretation:

- The easy-looking subset, `zero_eqne_raw`, captures essentially the same
  opportunity count as `raw_alu_branch`: `462992` vs `463117` candidates.
  Therefore a first RTL design does not need full branch-condition fusion to
  reach the main opportunity.
- Under the conservative `l1+1` model, `zero_eqne_raw` still gives
  `0.0251 dCPI`, about `2.62%` same-clock runtime improvement against the
  previous `0.957` COE baseline CPI.
- The `ideal` upper bound is `0.0514 dCPI`, about `5.37%` same-clock runtime.
- The `noBP` column is unexpectedly positive for the raw/zero subset because
  the dominant branches are often fallthrough/exit-test branches and current
  L1 prediction misses many of them.  This should be treated as a model result,
  not a license to remove prediction blindly.
- The broad `all_alu_branch` policy has a larger upper bound, but it implies a
  general slot1-branch design and more control/flush complexity.  It should not
  be the first implementation target.

## Decision

This is not too small.  `zero_eqne_raw` is worth a design proposal.

Do not start with general slot1 branch support.  Start with the narrow pattern:

```text
slot0: ALU writes rd
slot1: BEQ/BNE uses rd and x0
```

The next step should be a design contract before RTL:

- exact fuse eligibility in ID,
- how slot1 branch prediction/redirect is represented,
- whether fused branch miss penalty is same as current or `+1`,
- how slot1 branch flush kills younger work and slot1 writeback,
- proof that no new logic is added to the IF/IROM address path,
- early timing gate: the `l1+1` model can tolerate period up to about
  `5.134ns`, but any new negative WNS at 5ns should trigger immediate review.
