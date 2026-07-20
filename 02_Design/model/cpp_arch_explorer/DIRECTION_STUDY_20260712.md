# Direction Predictor Study — 2026-07-12

## Scope

This study changes only the C++ architecture explorer.  RTL is untouched.  All
six contest COE programs run to their architectural stop PC; sampled runs are
not used in the conclusions below.

The study compares the current 256-entry, 8-bit-history GShare against larger
GShare tables and small committed-history mini-TAGE predictors.  The model
captures prediction-time indices, tags, providers, alternate predictions, and
counter values, then trains them after a fixed dynamic-instruction delay.

## RTL calibration

The current GShare model was checked against the `Stage1 PHT wrong` counters in
the 2026-07-04 RTL performance logs.  A single fixed dynamic-instruction delay
cannot reproduce every cycle-level stall, but the closest tested delays are:

| Program | RTL PHT wrong | Closest C++ delay | C++ wrong | Difference |
| --- | ---: | ---: | ---: | ---: |
| current | 1,730,618 | 6 | 1,725,836 | 0.28% |
| src0 | 61,756,763 | 10 | 61,509,158 | 0.40% |
| src1 | 32,290,834 | 8 | 32,778,271 | 1.51% |
| src2 | 108,075,037 | 10 | 110,786,731 | 2.51% |
| new_without_Mext | 38,818,975 | 10 | 39,248,017 | 1.11% |
| new_with_Mext | 133,018 | 8 | 133,018 | 0.00% |

Delay 6 is retained as the optimistic/current-program comparison.  Delay 10 is
the primary implementation-oriented result because it best represents the
long-running programs that dominate total cycles.

## Corrected full results

An initial TAGE sweep exposed a folding bug: a short tagged table could see
history bits beyond its declared history length.  Those initial TAGE numbers
were discarded.  History is now truncated before folding and a regression test
distinguishes H2 from H4 tables.  The numbers here are from the corrected rerun.

| Predictor | Logical bits | Two-read bits | Delay 6 misses | Delay 10 misses |
| --- | ---: | ---: | ---: | ---: |
| Current GShare-256 H8 | 520 | 1,032 | 225,619,852 | 247,939,678 |
| GShare-1024 H12 | 2,060 | 4,108 | 211,251,329 | 231,929,329 |
| GShare-2048 H12 | 4,108 | 8,204 | 203,398,764 | 228,983,716 |
| TAGE2 B256 + T64 H4/H8 | 1,992 | 3,976 | 199,544,133 | 219,003,913 |
| TAGE3 B256 + T64 H3/H8/H24 | 2,840 | 5,656 | 199,495,838 | 217,654,362 |

At delay 10, TAGE2 reduces direction misses by 28,935,765 (11.67%) versus the
current predictor.  It improves all six programs.  Against the nearly
equal-resource GShare-1024 H12, it removes another 12,925,416 misses (5.57%)
while using 68 fewer logical state bits.

| Program | Current GShare misses | TAGE2 misses | Reduction |
| --- | ---: | ---: | ---: |
| current | 1,972,396 | 1,514,994 | 23.19% |
| src0 | 61,509,158 | 56,701,630 | 7.82% |
| src1 | 34,290,358 | 25,234,423 | 26.41% |
| src2 | 110,786,731 | 97,661,812 | 11.85% |
| new_without_Mext | 39,248,017 | 37,758,145 | 3.80% |
| new_with_Mext | 133,018 | 132,909 | 0.08% |

TAGE3 removes only 1,349,551 additional misses versus TAGE2 at delay 10, while
adding 848 logical bits, a third tagged lookup, a longer history, and a wider
provider selection.  It is not the preferred first RTL candidate.

## History-length conclusion

Eight GHR bits are not excessive for the current GShare.  H8 remains the best
tested history length at 256 entries.  For a small TAGE, the best two-table
combination is H4/H8: H2/H8, H4/H12, and H4/H16 all lose at both realistic
delays.  Thus the useful change is multiple distinct histories, not increasing
the single global history indiscriminately.

## Static-PC evidence

At delay 10, the largest TAGE2 improvements over the current GShare occur in
the software multiply/shift loops, including `src2` PCs `0x80001f18` and
`0x80001f28`, and `src0` PCs `0x80001fb4` and `0x80001fc4`.  These four PCs
alone remove about 9.66 million direction misses.  The largest single-PC
regression is only 179,313 misses (`src2`, `0x80001e8c`), much smaller than the
major improvements.  Full per-PC counts are emitted by `per_pc.csv`.

## Base capacity, PC index, and physical-bank follow-up

The follow-up holds T0/T1 at 64 entries and H4/H8 while varying only the
bimodal base.  It also distinguishes a shared logical table from a physical
PC[2] split.  `FOLD` XOR-folds all twelve 16-KiB IROM word-address bits into
the base index; `PC2BANK_FOLD` fixes PC[2] as the bank and folds the remaining
eleven bits into the row.

| TAGE2 base organization | Logical bits | Two-read bits | Delay 6 misses | Delay 10 misses |
| --- | ---: | ---: | ---: | ---: |
| B256 low, shared | 1,992 | 3,976 | 199,544,133 | 219,003,913 |
| B256 low, PC[2]-banked base | 1,992 | 3,464 | 199,544,133 | 219,003,913 |
| B256 folded, shared | 1,992 | 3,976 | 199,444,111 | 219,023,345 |
| B128 low, shared | 1,736 | 3,464 | 199,489,470 | 219,005,828 |
| B128 folded, PC[2]-banked base | 1,736 | 3,208 | 199,500,178 | 219,012,060 |
| B256 folded, all tables PC[2]-banked | 1,992 | 1,992 | 207,180,073 | 219,697,703 |
| B128 folded, all tables PC[2]-banked | 1,736 | 1,736 | 207,169,696 | 219,720,000 |

The base is not capacity-limited.  At delay 10, changing B128/B256/B512 and
low/folded indexing moves the total by only thousands to tens of thousands of
misses out of 1.079 billion branches.  B128 folded plus a banked base has
essentially the same result as B256 while removing 256 logical bits and 768
two-read bits from the original shared organization.

PC folding does remove measured owner switching: the B256 standalone bimodal
base drops from about 256 thousand dynamic alias switches with low indexing to
551 with shared folded indexing.  This changes total misses by only about 20
thousand, showing that most remaining base errors are intrinsic behavior or
delayed training, not PC capacity conflict.

Physically banking only the base is safe.  Low-PC B256 and PC[2]-banked-low
B256 are prediction-equivalent by construction and match bit-for-bit in the
full runs.  Banking the tagged tables is not robust: it adds 7.67 million
misses at delay 6 (3.84% relative to shared TAGE2) and 0.72 million at delay 10
(0.33%).  It also increases allocation failures and shifts more final
predictions back to the base.  The large delay sensitivity makes two 32-entry
tagged banks a poor default despite eliminating table replication.

For B128 folded with only the base banked, the base is the longest matching
provider for 27.4% of delay-10 branches and is 97.72% correct on that
conditional subset.  Its final-source accuracy and total TAGE accuracy are
effectively unchanged from B256, explaining why extra base entries have no
value in this workload set.  `diagnostics.csv` records provider accuracy,
final-source accuracy, alternate use, per-bank misses, alias switches, and
allocation pressure separately.

## Estimated processor-level value

As a screening estimate, apply each program's C++ direction-miss reduction to
the RTL log's redirect component of its CPI stack.  This estimates a 0.742%
reduction in summed cycles for TAGE2, versus 0.415% for GShare-1024 and 0.489%
for GShare-2048.  TAGE3 reaches about 0.775%, only 0.033 percentage points above
TAGE2.  These are inferences, not RTL measurements.

## Recommendation and remaining risks

The conservative feasibility target is TAGE2 with a PC[2]-banked 256-entry
low-PC bimodal base and two shared 64-entry tagged tables at H4/H8.  Base
banking is prediction-equivalent and reduces the conservative two-read cost
from 3,976 to 3,464 bits without adding a PC fold on the lookup path.

The lean target is a 128-entry PC[2]-banked folded base with the same shared
tagged tables: 1,736 logical bits and 3,208 two-read bits, with effectively the
same full-program accuracy.  This saves little in absolute FPGA resource, so
the conservative B256 version remains preferable unless synthesis shows that
the smaller base removes a real LUTRAM/timing boundary.  Do not split each
64-entry tagged table into fixed 2x32 banks without another port/scheduling
strategy.

Before any RTL implementation decision, review whether both instruction slots
really require independent tagged-table reads and whether table/tag comparison
fits the frontend timing budget.  The C++ model also assumes a perfect BTB for
direction evaluation and uses committed history with a fixed instruction
delay; ABTB ownership, wrong-path activity, stalls, and exact pipeline update
ordering remain RTL-only effects.

## Reproduction

Build and test:

```bash
cmake -S 02_Design/model/cpp_arch_explorer \
      -B 02_Design/model/cpp_arch_explorer/build \
      -DCMAKE_BUILD_TYPE=Release
cmake --build 02_Design/model/cpp_arch_explorer/build -j16
ctest --test-dir 02_Design/model/cpp_arch_explorer/build --output-on-failure
```

The independent `direction_study` executable supports `--delays`, `--configs`,
`--programs`, `--jobs` (hard-capped at 16), and `--max-instructions`.  A run
using `--max-instructions` is a sample and must not be presented as full data.
