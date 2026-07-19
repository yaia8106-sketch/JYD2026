# C++ Architecture Explorer

This directory contains a pure C++ architecture explorer for frontend branch
prediction ideas.  It executes the contest COE images with a functional RV32IM
machine and evaluates predictor configurations online.  It does not require an
RTL-generated branch trace.

The functional machine implements the instructions and platform behavior used
by the six images, including RV32I, RV32M, machine CSRs, ECALL/MRET, DRAM, the
testbench MMIO mirror, and timer MMIO.

## Mandatory workloads

Every full result covers all six programs under `02_Design/coe/single_issue`:

1. `current`
2. `src0`
3. `src1`
4. `src2`
5. `new_without_Mext`
6. `new_with_Mext`

Each program starts with zeroed histories and a weakly-not-taken PHT.  The
entry self-loop stop PC is derived from the COE image in the same way as the
RTL long-performance flow.

## Build and run

From the workspace root:

```bash
cmake -S 02_Design/cpp_arch_explorer \
      -B 02_Design/cpp_arch_explorer/build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build 02_Design/cpp_arch_explorer/build -j
02_Design/cpp_arch_explorer/build/bp_explorer
```

For the direction-predictor capacity/history/TAGE study:

```bash
02_Design/cpp_arch_explorer/build/direction_study \
    --delays 0,6 --jobs 6
```

`direction_study` compares PC-only bimodal, GShare with 256/512/1024/2048
entries and several history lengths, and two small committed-history mini-TAGE
designs.  Its default delay-6 run is the implementation-oriented result;
delay 0 is the no-update-latency upper bound.  It emits `per_program.csv`,
`aggregate.csv`, `per_pc.csv`, and `diagnostics.csv`; the last two identify the
static branch PCs responsible for misses and separate provider/final-source
accuracy, alternate use, PC[2] bank pressure, alias switches, and allocation
pressure.

The default `target-history` experiment evaluates 12 architectures at update
delays 0, 2, 4, and 6 dynamic instructions for all six programs. Independent
program/delay tasks run in parallel. Results are written to the ignored
`results/` directory:

- `per_program.csv`: raw per-program/configuration results;
- `aggregate.csv`: summed six-program results and worst-program accuracy.

Useful development options:

```text
--programs current,src0
--delays 0,4,6
--configs GSHARE_256_H8,TAGE2_B256_T64_H4_8
--jobs 8
--max-instructions 1000000
--progress 100000000
--no-mispredict-barrier
--experiment first-round
```

A run using `--max-instructions` is sampled/incomplete and must not be reported
as a full result.

## Functional execution and update delay

The architectural path is always the actual path.  Forwarding, caches, stalls,
and wrong-path instruction execution are intentionally omitted because they do
not change architectural branch outcomes.

Predictor updates are not necessarily immediate.  Every conditional prediction
captures its prediction-time PHT index and counter.  The PHT, committed GHR,
and path history update together after the configured number of dynamic
instructions.  PHT training uses the captured counter, matching the current
RTL's prediction-time metadata behavior.

With the default misprediction barrier, a direction misprediction forces that
branch and all older pending updates to resolve before the next actual-path CFI.
This approximates redirect recovery without executing wrong-path instructions.
It is still an abstract timing model: fixed instruction delay cannot reproduce
all pipeline stalls or ABTB ownership effects.  Results must therefore be
checked across several delays rather than trusted at one selected value.

## Current baseline

`GSHARE` models the Stage-1 direction predictor:

- 256-entry PHT;
- two-bit saturating counters, initially weakly not-taken;
- 8-bit committed, non-speculative GHR;
- `index = branch_pc[9:2] ^ ghr`;
- prediction-time index and counter used for training.

`BIMODAL` is the PC-only calibration model.

## Direction-study resource rules

The mini-TAGE model has a PC-indexed two-bit bimodal base and two or three
tagged tables.  Tagged counters are signed three-bit counters, useful state is
one bit, and prediction selects the longest matching history.  Allocation is
on a misprediction into a longer-history entry with zero useful state.  All
indices, tags, providers, counter values, and alternate predictions are
captured at prediction time and applied after the selected fixed update delay.

Storage comparisons include counters, tags, useful/valid bits, and history.
`logical_storage_bits` counts one copy.  `two_read_storage_bits` conservatively
counts two copies of every prediction table to represent two simultaneous
instruction-slot lookups, while history is counted once.  In particular,
`TAGE2_B256_T64_H4_8` is 1992 logical bits, close to
`GSHARE_1024_H12` at 2060 bits, so this pair is the primary equal-resource
comparison.

The base-index study additionally supports low-PC, folded-IROM-PC, and
PC[2]-banked low/folded organizations at 128/256/512 entries.  Tagged tables
can remain shared or be physically constrained to two PC[2] banks.  A banked
table's two-read storage cost does not include full-table replication.  The
folded base hashes all twelve 16-KiB IROM word-address bits into the configured
row width; the PC[2]-banked variant keeps PC[2] as the bank and folds the
remaining eleven bits into the row.

This is deliberately a screening model, not a claim of cycle-exact TAGE RTL.
It uses committed history and a fixed dynamic-instruction update delay.  Any
winning configuration still needs an RTL feasibility/timing review before it
is selected.

## First-round candidates

All path candidates keep the same 256-entry PHT and add one precomputed 8-bit
path register.  Lookup is limited to `PC ^ GHR ^ path`; target folding and path
updates are off the lookup path.

| Family | Path update |
| --- | --- |
| `LAST_TARGET` | `path = H(actual_target)` |
| `SOURCE_PATH` | `path = rol1(path) ^ H(source_pc)` |
| `TARGET_PATH` | `path = rol1(path) ^ H(actual_target)` |
| `NEXT_PC_PATH` | `path = rol1(path) ^ H(actual_next_pc)` |
| `EDGE_PATH` | `path = rol1(path) ^ H(source_pc) ^ H(actual_next_pc)` |

The simple update-side address hash is:

```text
H(address) = address[9:2] ^ zero_extend(address[13:10])
```

Each path family has a conditional-branch-only and an all-CFI update scope.
Target-based histories ignore a not-taken conditional target because that
address was not part of the executed path.

## Target-history replacement candidates

The default second-round experiment records a compressed actual target only
when a conditional branch resolves taken. It compares:

- `PC ^ GHR` (`GSHARE`);
- `PC ^ last_target` (`TARGET_LAST_*`);
- `PC ^ rolling_target_history` (`TARGET_ROLL_*`);
- `PC ^ GHR ^ last_target` (`GSHARE_PLUS_LAST_TARGET*`).

Target compression includes the low eight word-address bits, an eight-bit
address fold, and two/four-bit address folds spread across the eight-bit PHT
index. Use `--experiment first-round` to reproduce the original path-family
sweep described above.

## Metrics and selection rules

The CSV reports raw direction counts, accuracy, mispredictions per thousand
instructions, simple alias indicators, indices used per static branch, state
bits, and lookup XOR operands.  Aggregate rates are computed from summed raw
counts, never by averaging six percentages.

Architecture selection must consider:

- all six programs and the worst single-program regression;
- sensitivity to update delay;
- full-program misprediction reduction, not only accuracy percentage;
- PHT capacity and replicated asynchronous read storage;
- added state, lookup XOR/fanout, and update-side logic;
- final RTL cycles and post-implementation WNS/Fmax.

A C++ accuracy gain is only a screening result.  The best one or two robust
candidates must still be implemented in RTL and tested with all six COE images
before any architecture decision.

## Scope of the first version

The first version uses a perfect-BTB direction view: every architectural
conditional branch is evaluated.  It does not yet model ABTB allocation,
ownership, replacement, or wrong-path LRU touches.  A future current-ABTB mode
can separate intrinsic PHT accuracy from direction predictions that actually
steer the implemented frontend.
