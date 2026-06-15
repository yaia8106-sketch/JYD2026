# Stage-1 Frontend Predictor Design Prompt

## Role

You are working on the stage-1 frontend predictor of the CPU in this repository.
Read the existing RTL before editing, especially:

- `02_Design/rtl/core/frontend_ftq.sv`
- `02_Design/rtl/core/frontend_abtb.sv`
- `02_Design/rtl/core/frontend_stage1_direction.sv`
- `02_Design/rtl/core/cpu_top.sv`
- `02_Design/rtl/core/id_stage_derive.sv`
- `02_Design/rtl/core/redirect_ctrl.sv`

The XiangShan frontend under `reference_cores/XiangShan` is an architectural
reference, not code to copy directly. The target is a much smaller FPGA-friendly
predictor for a 64-bit fetch, dual-issue RV32 core.

Do not change RTL merely because this document describes a future design. When
implementation is requested, first compare this specification with the current
RTL, identify the affected contracts, and preserve functional behavior outside
the requested scope.

## Objective

Build a lightweight stage-1 predictor consisting of:

- a two-bank Ahead BTB (ABTB) for CFI presence, type, and target;
- a two-bank PHT plus an 8-bit GHR for conditional branch direction;
- a small uRAS for return targets;
- an FTQ interface that decouples prediction, instruction fetch, and issue;
- a unified redirect path shared by backend redirect and stage-2 override.

The primary goals are:

1. Keep the stage-1 prediction path short enough for the FPGA timing target.
2. Predict both 32-bit instruction positions in one 64-bit aligned fetch block.
3. Keep target prediction independent from global branch history.
4. Avoid speculative predictor-state recovery in the first implementation.
5. Allow redirect recovery fetch and predictor restart to begin in parallel.

## Current Implementation Boundary

The legacy predictor has been retired from the active frontend. Stage-1
prediction is produced by:

- `frontend_abtb.sv`
- `frontend_stage1_direction.sv`
- `frontend_ftq.sv`

ABTB miss fetches the sequential PC. There is no BP1 correction path and no
registered BP1 configuration. The only frontend correction source is the
backend/EX redirect path. The historical `bp_*` training metadata snapshots
(`ghr_snap`, BTB hit/type/BHT, PHT counter, selector counter, and slot1 copies)
are no longer carried through FTQ/FQ, IF/ID, ID/EX, or EX.

Pipeline prediction signals use `if/id/ex_pred_taken` and
`if/id/ex_pred_target` naming. They carry canonical Stage-1 prediction payload,
not legacy predictor state.

## Terminology

- `predict_pc`: PC used to start the next stage-1 predictor lookup.
- `block_pc`: `predict_pc` aligned down to 8 bytes.
- `slot0_pc`: `block_pc`.
- `slot1_pc`: `block_pc + 4`.
- `bank0`: ABTB/PHT bank corresponding to slot 0.
- `bank1`: ABTB/PHT bank corresponding to slot 1.
- `frontend redirect`: flush wrong-path frontend state and restart from a
  corrected PC.
- `predictor-state recovery`: restore speculative GHR/uRAS state. This is not
  needed in the initial design because GHR and uRAS are not speculatively
  updated.

Do not use "recovery" ambiguously. State whether it means frontend redirect or
predictor-state recovery.

## Confirmed Architecture

### Fetch Block and Bank Mapping

The physical instruction fetch width is 64 bits and the fetch block is 8-byte
aligned:

```text
block_pc = predict_pc & ~7
bank0    = instruction at block_pc
bank1    = instruction at block_pc + 4
```

Each bank stores prediction information for one 32-bit instruction position.
The bank number therefore encodes the CFI position; an explicit `cfi_pos` field
is not required inside an ABTB entry.

If `predict_pc[2] == 1`, bank0 is before the requested PC and must be masked.
Bank1 remains eligible.

The two banks solve both of these cases:

- the CFI may be in slot0 or slot1;
- both slots may contain CFIs.

Both bank candidates must be computed in parallel. Do not serialize the bank1
lookup behind the bank0 result.

### Direction Rules

Stage-1 direction behavior is:

```text
direct J/CALL: taken = 1
RET:           taken = uras_valid
conditional B: taken = PHT counter MSB
ABTB miss:     taken = 0
```

An ordinary non-return indirect JALR is not predicted by the initial ABTB
design. It is handled by stage 2 or by the backend redirect path. A later tiny
indirect-target structure may be added only if profiling justifies it.

The eligible predictions are selected in program order:

```text
if bank0 is eligible and predicts taken:
    select bank0
else if bank1 predicts taken:
    select bank1
else:
    select fall-through
```

Therefore, a not-taken conditional branch in bank0 does not hide a taken CFI in
bank1. If both predict taken, bank0 wins because it is older.

The sequential next PC is:

```text
predict_pc[2] == 0: predict_pc + 8
predict_pc[2] == 1: predict_pc + 4
```

### Target Rules

- Conditional B target: stored in the corresponding ABTB bank.
- Direct J/CALL target: stored in the corresponding ABTB bank.
- RET target: taken from uRAS; the ABTB entry marks the instruction as RET but
  its target field is ignored.
- ABTB target is initially stored as a full 32-bit address. Target compression
  is a later optimization.

Target lookup must not use GHR as part of the ABTB identity. A target is a
property of the CFI PC, not of the dynamic branch history.

### ABTB Indexing and Organization

Initial organization:

```text
2 banks
64 entries total
32 entries per bank
2 ways per bank
16 sets per bank
```

Both banks use the same set index derived from `block_pc`; the physical bank is
selected by the instruction position. The tag is derived from the remaining
aligned PC bits.

The exact PC hash and tag width must be chosen from the implemented address
range and alias measurements. Start with a simple stable PC-only index. Do not
put GHR in the ABTB index.

Minimum ABTB entry:

```systemverilog
typedef struct packed {
    logic        valid;
    logic [TAG_W-1:0] tag;
    logic [1:0]  cfi_type;  // B, direct J, direct CALL, RET
    logic [31:0] target;    // ignored for RET
} abtb_entry_t;
```

Replacement state is per set. A one-bit LRU policy is sufficient for two ways.

The final implementation may use LUTRAM, BRAM, or registers. Do not decide this
from intuition alone. Compare synthesis and implementation results, including
inferred memory shape, utilization, placement, WNS, and the predictor critical
path.

Banking is not assumed to improve timing automatically. It reduces local table
width and fanout, but adds a second lookup, a second tag comparison, and final
arbitration. Judge the result from implementation reports.

### PHT and GHR

Implemented shadow direction predictor:

```text
GHR: 8 bits
PHT: 256 two-bit counters total
```

The RTL exposes two parallel asynchronous query ports over one logical
256-entry PHT. For the accepted fetch block:

```text
block_pc   = {predict_pc[31:3], 3'b000}
bank0_pc   = block_pc
bank1_pc   = block_pc + 4
bank0_index = bank0_pc[9:2] ^ committed_ghr
bank1_index = bank1_pc[9:2] ^ committed_ghr
```

This keeps an 8-bit index and permits both physical instruction positions to
query direction without waiting for an ABTB hit. Preserve these properties:

- PC and GHR both influence direction indexing.
- ABTB and PHT reads run in parallel.
- PHT bank0 and bank1 query ports run in parallel.
- ABTB output must not be needed to start the PHT read.

PHT counter encoding:

```text
00 strongly not taken
01 weakly not taken
10 weakly taken
11 strongly taken
```

Prediction uses the counter MSB. PHT updates on every resolved conditional
branch, including not-taken branches and mispredicted branches.

GHR updates only when a valid conditional branch reaches the confirmed EX
update point:

```text
ghr_next = {ghr[6:0], actual_taken}
```

There is no speculative GHR update in the initial implementation. Consequently,
frontend redirect does not restore GHR.

### uRAS

uRAS supplies the target for a predicted RET. ABTB stores RET type but not the
return address.

Initial uRAS policy:

- no speculative push or pop;
- confirmed direct CALL pushes its architectural return PC;
- confirmed RET pops;
- updates occur at the EX-confirmed update point;
- wrong-path younger instructions never update uRAS.

Because uRAS is not speculatively updated, frontend redirect does not restore
uRAS.

If a redirect target predictor lookup starts in the same cycle as the
redirecting CALL/RET update, the lookup must either:

1. use a correctly computed `uras_next` bypass; or
2. wait until the following cycle.

Do not silently use stale uRAS state while claiming zero-cycle predictor
restart.

### Predictor PC Sources

The predictor PC has these priority-ordered sources:

```text
1. backend/EX redirect target
2. stage-2 prediction override target
3. normal stage-1 predicted next PC
4. hold current PC when allocation cannot proceed
```

The normal predicted next PC is the selected taken target or sequential
fall-through.

Prediction is driven by `predict_pc`, not by the number of instructions issued
by the backend. Fetch prediction, FTQ consumption, and instruction issue are
separate flows:

```text
predictor advances prediction blocks
FTQ/IFU advances fetch requests
instruction queue advances by one or two issued instructions
```

### FTQ Role

The FTQ stores prediction blocks and metadata needed for instruction fetch,
later verification, training, and redirect control. It is not merely the
current issue PC.

Minimum block-level FTQ state:

```text
block_pc
start_slot / fetch-valid mask
predicted_next_pc
selected_bank
block_pred_taken
epoch or equivalent wrong-path discriminator
GHR snapshot
```

Minimum per-slot metadata:

```text
ABTB hit
ABTB way
predicted CFI type
predicted taken
predicted target
PHT row index
PHT counter snapshot
```

ABTB set and bank can be recomputed from the instruction PC. Preserve a way
identifier when it avoids a second associative lookup during training.

The initial implementation may carry the prediction-time ABTB way to EX without
revalidating its tag. An intervening replacement can make that way metadata
stale. Updating the stale way is acceptable because ABTB contents are
microarchitectural predictor state: the result is at worst a lost entry and
temporary performance degradation, not an architectural-state error. Do not
restore an update-side associative payload/tag lookup solely to recover stale
way metadata. The update bank is always recomputed from the resolved CFI PC:

```text
update_bank = update_pc[2]
```

### FTQ Metadata and Training Boundary

The first whole-frontend integration was shadow-only. The current frontend uses
ABTB/PHT as the Stage-1 steering source, but still does not use the standalone
`frontend_abtb.pred_next_pc` output. `frontend_ftq` consumes the ABTB raw
per-bank hit/type/target metadata and the parallel Stage-1 PHT direction to
build one canonical prediction.

An ABTB lookup is consumed only when the frontend accepts a new BP0 block:

```text
lookup_valid = bp0_fire
```

Each physical bank result is captured with that block and converted into
instruction-bound metadata when its slot is written into the FQ:

```text
abtb_hit
abtb_way
```

The current shadow implementation keeps only `abtb_hit` and `abtb_way` in the
synthesizable FQ sidecar because EX training only needs prediction-time hit/way
plus decode-confirmed update qualification/type. Future steering/debug fields
such as predicted CFI type, target, predicted taken, and predicted target are
simulation-only unless a later steering stage consumes them.

The implementation stores the compact metadata in parity-banked FQ sidecar
arrays rather than adding it to the main FQ payload. Even and odd FQ entries use
separate sidecars, preserving one write and one asynchronous read per physical
memory. Sidecar payloads are not reset or flush-muxed; the existing FQ
valid/count state makes stale payload contents unobservable. Slot1 sidecar
writes must be qualified with the real slot1 enqueue valid so a slot0 taken CFI
cannot leave a killed slot1 metadata entry that is later dequeued as valid.

Sidecar leakage verification must be keyed by physical FQ entry identity, not
instruction PC. A redirect can legally refetch the same PC, so treating any
later appearance of a killed slot PC as leakage is a false positive. The
integration reference model mirrors only real parity-banked sidecar writes,
indexed by write row and entry select, and compares metadata only for currently
valid `fq_head`/`fq_head_p1` entries. Redirect clears model validity while
leaving stale reference payload intact, matching the RTL visibility contract.
Slot0 CFI kill cases separately assert that slot1 has payload but no enqueue
valid and no slot1 sidecar write enable.

The fields move through IF/ID and ID/EX under the same valid, stall, epoch, and
flush rules as the instruction. A flush may leave stale payload bits in wide
registers only when the corresponding instruction valid bit is cleared.

Decode carries an explicit confirmed ABTB CFI type to EX. The initial
classification and allocation policy is:

```text
taken conditional branch: write BRANCH
not-taken branch:          no ABTB write
direct JAL x1/x5:          write CALL
other direct JAL:          write JAL
JALR x1/x5:                write CALL
JALR x0, 0(x1/x5):         write RET
other indirect JALR:       no ABTB write
```

The EX update must reuse one common confirmed CFI slot arbitration,
pipeline-fire qualification, and wrong-path-suppression signal for ABTB and
Stage-1 PHT/GHR updates. CFI candidate selection must remain independent of
`mem_allowin`; the final shared `train_valid` applies
`ex_ready_go && mem_allowin && !older_flush`. A redirecting CFI may redirect and
train in the same cycle. An older slot0 CFI prevents a younger slot1 CFI from
using the single update port.

Historical shadow-convergence snapshot from 2026-06-12: ABTB remained in shadow
mode and `frontend_abtb.pred_next_pc` was intentionally not connected to the
real PC mux, IROM address, redirect path, or FTQ steering control. The current
status is recorded under `Current Implementation Status` below.

Verification status must distinguish configured coverage from executed
simulation. If VCS cannot check out a license, do not report the standalone ABTB
test, integration TB, `functional/run_all.sh`, CPU regression, or 81/81 program
set as PASS. The integration model covers
JAL/JALR/taken-branch slot1 kills, even/odd heads, single/dual dequeue, backend
stall, redirect/refetch of the same PC, pointer wrap-around, and update-token
tracking.

If the implementation clears the complete speculative FTQ/FQ on redirect, the
redirect control metadata can remain small:

```text
redirect_valid
redirect_target
new_epoch
```

If partial rollback is introduced later, add an FTQ pointer and ahead-read
metadata deliberately. Do not add complex rollback state before it is needed.

### Redirect Broadcast

When EX/backend confirms a redirect, broadcast the corrected target to both:

```text
redirect_target
  -> FTQ/IFU/IROM recovery fetch
  -> stage-1 predictor restart lookup
```

This permits instruction fetch and prediction of the corrected block to start
in parallel.

The FTQ may create a provisional recovery entry containing:

```text
start_pc = redirect_target
epoch = new_epoch
prediction_pending = 1
```

The new target block's ABTB/PHT/uRAS metadata must come from a new lookup at
`redirect_target`. Never reuse the old redirecting CFI's training metadata as
the new block's prediction metadata.

The provisional entry must not be consumed as a complete predicted block until
the required prediction metadata is available.

If a conditional branch redirect and GHR update occur together, an immediate
predictor restart should index the PHT with:

```text
ghr_after_ex = {ghr[6:0], actual_taken}
```

Use a next-state bypass or accept a one-cycle delay. Do not accidentally index
the corrected path with stale history.

### Redirect Timing Optimization

The current design registers redirect for timing. The desired optimization is
to reduce redirect penalty without placing a long arithmetic/control chain on
the EX-to-frontend path.

Preferred structure:

```text
ID or an earlier post-decode stage:
    precompute direct branch target
    precompute direct jump target
    precompute fall-through PC

EX:
    resolve branch condition
    compare actual result with prediction
    late-select one precomputed actual_next_pc
    generate redirect_valid

EX update edge:
    apply frontend redirect
    register/apply predictor training
```

Compute independent address candidates in parallel and use EX only for a small
late selector. Preserve exception, trap, and redirect priority.

Do not remove the existing registered redirect stage until implementation
timing proves that the direct path closes. If it does not close, retain the
registered redirect while keeping the candidate-address precomputation.

An ahead FTQ metadata read is useful only if the selected recovery policy needs
data that is not already carried with the instruction. With full frontend
flush and no speculative predictor update, do not invent unnecessary recovery
metadata.

## Training Semantics

Training and frontend redirect are independent events. A mispredicted CFI must
normally do both:

```text
redirect = 1
train = 1
```

Examples:

- B predicted not-taken, actually taken: redirect, allocate/update ABTB, update
  PHT toward taken, update GHR with taken.
- B predicted taken, actually not-taken: redirect, update PHT toward not-taken,
  update GHR with not-taken.
- CALL target mispredicted: redirect, update ABTB, push uRAS.
- RET target mispredicted: redirect, retain/update RET classification, pop
  uRAS.
- trap/interrupt/MRET redirect: redirect without branch-predictor training.

Valid training condition:

```text
train_valid = ex_valid && ex_fire && !older_flush
```

If an older slot redirects, a younger slot in the same cycle must not train.
The initial implementation may support one CFI training event per cycle. If
multiple confirmed CFI updates become possible, preserve program order or
serialize them explicitly.

ABTB allocation policy:

- allocate taken conditional B;
- allocate direct J;
- allocate supported direct CALL;
- allocate RET type;
- do not allocate an ABTB miss for a not-taken B;
- on an existing B hit, update/correct its target only when a taken resolution
  provides a meaningful target;
- ordinary indirect JALR is excluded from initial allocation.

PHT policy:

- update every confirmed B;
- use the prediction-time PHT row and counter snapshot carried in metadata;
- saturate normally at `00` and `11`.

Initial implementation has no ABTB/PHT write-to-read bypass. A recently trained
entry may be observed one prediction later. Add bypass only after measurement
shows a meaningful loss or a correctness issue.

## Stage-1 and Stage-2 Boundary

Stage 1 and stage 2 share a unified redirect/flush infrastructure, but they are
not semantically identical.

Priority:

```text
backend/EX redirect > stage-2 override > stage-1 normal prediction
```

- Stage 1 is the fast, lightweight steering prediction described here.
- Stage 2 verifies or improves stage-1 direction/target and may override it
  before backend resolution.
- Backend redirect is authoritative.
- Flush scope and metadata source must match the redirect source.

Represent the source explicitly when it is needed for correct arbitration,
flush range, or performance accounting.

## Timing Implementation Rules

- Read both ABTB banks in parallel.
- Read both PHT banks in parallel.
- Compute J/B target, uRAS target, and fall-through candidates in parallel.
- Reduce late control to eligibility checks and one program-order selector.
- Keep late redirect/kill signals off wide payload paths when validity can
  safely suppress consumption.
- Do not assume banking, LUTRAM, or BRAM improves timing without implementation
  evidence.
- Do not disable bank1, dual issue, target checks, or redirect checks merely to
  improve WNS.
- Do not add false paths or multicycle constraints over real synchronous logic.

## Current Implementation Status

As of 2026-06-14 after Stage 4, the frontend has one supported build-time mode:

- ABTB + PHT owns Stage-1 steering for `TYPE_JAL`, `TYPE_CALL`, and
  `TYPE_BRANCH`.
- ABTB miss fetches sequentially.
- EX/backend redirect is the final correction point.

The historical shadow-only, J/CALL-only, branch-wrapper, and registered frontend
correction variants have been retired. Do not reintroduce old steering defines
in RTL, testbench, functional scripts, or performance scripts.

The old predictor instance, source-file compile entry, and legacy `bp_*`
training metadata pipe have been retired. Stage-1 steering and training now use
ABTB, Stage-1 PHT/GHR, canonical `pred_taken/pred_target`, ABTB hit/way/type,
and prediction-time `stage1_pht_index/stage1_pht_counter`.

The canonical Stage-1 result is:

```text
stage1_steer_valid
stage1_steer_source_abtb
stage1_steer_taken
stage1_steer_bank
stage1_steer_cfi_type
stage1_steer_target
stage1_steer_next_pc
```

`current_pc` consumes this result only on `bp0_fire`. Backend/EX redirects
remain highest priority and are the only frontend redirect source. There is no
ID-stage or F0 legacy correction path back into frontend PC steering.

Default program-order arbitration is:

```text
first-instruction ABTB J/CALL taken
else first-instruction ABTB branch + PHT taken
else first-instruction ABTB-owned branch not-taken and younger bank1 CFI taken
else bank1 ABTB J/CALL taken
else bank1 ABTB branch + PHT taken
else sequential PC
```

When `current_pc[2] == 1`, bank1 is the first instruction and bank0 is
ineligible. For the same instruction, ABTB/PHT ownership is the Stage-1
direction decision. ABTB miss selects the sequential PC.

At `bp0_fire`, F0 locks the complete canonical result and uses that snapshot as
its sole prediction source. ID/EX receives the canonical
`pred_taken/pred_target` metadata directly; no ID-stage redirect can override
it.

The ABTB exposes a continuous per-bank raw tag-hit result separately from its
accepted `hit` metadata. J/CALL candidates use raw hit, CFI type, and stored
target because direct direction is intrinsic to the type. Branch ownership uses
raw hit, `TYPE_BRANCH`, and the parallel Stage-1 PHT direction. `lookup_valid`
continues to qualify accepted metadata, LRU touch, and counters.

`stage1_branch_owned` means Stage 1 owns the branch direction decision, whether
the PHT prediction is taken or not-taken.

- If the owned branch is predicted taken, the ABTB target steers fetch.
- If the owned branch is predicted not-taken, the first instruction remains
  owned by Stage 1, and program order continues to a younger bank1 CFI if it is
  eligible or otherwise to the sequential PC.
- `pred_source_abtb` remains a taken-source marker for the selected next PC; it
  must not be used as an ownership proxy.
- `stage1_abtb_owned_count` counts canonical fetch blocks with an ABTB-owned or
  ABTB-selected result. It is not a per-slot CFI count and increments at most
  once per accepted block.

Final `pred_taken`, `pred_target`, and `pred_source_abtb` are bound to the
selected physical instruction:

- bank0/first-slot taken ABTB result binds to slot0 and kills slot1;
- bank1 taken ABTB result from an aligned block binds to slot1;
- a fetch beginning at `pc[2] == 1` binds bank1 to slot0;
- sequential fallback binds not-taken metadata to the first physical slot and
  carries the sequential target.

ABTB update continues to use prediction-time `hit/way` metadata and never
performs an update-side tag/payload reread. Stale way metadata may overwrite a
predictor entry and affects performance only.

The Stage-1 direction predictor is now in the default steering path:

- both PHT query ports and both ABTB banks run in parallel;
- PHT index and counter snapshot are captured with the accepted fetch block and
  carried through FQ, IF/ID, and ID/EX;
- every confirmed conditional branch updates the prediction-time PHT index,
  including not-taken branches;
- the committed GHR shifts at the same confirmed EX edge;
- redirect does not restore GHR, and there is no speculative GHR update;
- there is no PHT write-to-read bypass;
- PHT training uses the prediction-time counter snapshot. If multiple
  in-flight branches alias to the same PHT row, later confirmed updates can be
  based on an older snapshot and lose precision. This is a prediction-quality
  risk only and is covered by the standalone direction test.
- FPGA configuration initializes the distributed PHT rows to weakly
  not-taken. Runtime `rst_n` resets GHR but does not scrub all PHT rows; a bulk
  reset inferred 512 flip-flops and was rejected because it destroyed LUTRAM
  inference.

The retired registered frontend correction experiment is no longer a supported
configuration. If a future frontend correction experiment is needed, introduce a
new name, new tests, and new documentation instead of reviving the retired path.

The FTQ pair eligibility path has been timing-refactored without changing the
pipeline boundary:

- `fq_pair_payload_ok()` now consumes compact pair metadata instead of the full
  FQ entry struct.
- RAW, structural, prediction, force-single, validity, and contiguous checks are
  generated in parallel and selected at the final AND stage.
- Cross-packet contiguity no longer recomputes `fq_tail_prev.pc + 4` on the
  `fq_pair_ok` write path. The FTQ tracks `fq_tail_next_pc` when the tail entry
  is written and compares that registered value against the next slot0 PC.
- `fq_mem.pc -> fq_pair_ok_reg` no longer has a reportable post-route path in
  the pair-optimized Vivado reports.

Current verification expectation:

- VCS ABTB standalone.
- VCS Stage-1 PHT/GHR standalone.
- VCS ABTB integration.
- VCS FTQ pair-policy directed test.
- VCS canonical steering directed test, 7 default Stage-3 cases.
- VCS ABTB/PHT branch steering directed test, default Stage-3 cases.
- VCS default CPU functional regression through `functional/run_all.sh`.

On the 19-program `run_perf.sh --set branch_diag` short workload, the latest
pre-cleanup branch-steering observation was cycles `15273`, IPC `0.7261`,
mispredicts `847`, frontend redirects `772`, Stage-1 owned selections `5465`,
and owned not-taken branch events `210`. Stage 3 renames sequential fallback
accounting to `stage1_sequential`; `stage1_abtb_owned_count` remains a
canonical block-level count, not a per-slot CFI count.

## Required Performance Counters

Add counters sufficient to answer:

- ABTB lookup count, hit count, and miss count per bank;
- ABTB replacement/allocation count per bank;
- blocks with zero, one, or two ABTB CFI hits;
- bank0-taken selection count;
- bank0-not-taken plus bank1-taken selection count;
- bank0 masked because `predict_pc[2] == 1`;
- PHT prediction count and direction misprediction count per bank;
- Stage-1 ABTB-owned prediction count and ABTB-owned not-taken branch count.
- Stage-1 sequential fallback count; it must exclude ABTB-owned not-taken
  branches.
- target misprediction count;
- ABTB type mismatch count;
- uRAS RET prediction count, valid count, invalid count, and target miss count;
- redirect count by backend, stage-2 override, direction, and target cause;
- redirect recovery cycles/bubbles;
- cases where prediction occurs immediately after a matching ABTB/PHT write,
  for evaluating future bypass;
- dual-CFI block frequency and the performance value of bank1.

Counters must not enter functional or timing-critical control paths.

## Verification Expectations

At minimum, add or reuse directed tests for:

- bank0 B taken/not-taken;
- bank1 B taken/not-taken;
- bank0 not-taken followed by bank1 J/B/RET taken;
- both banks predicting taken, confirming bank0 priority;
- `predict_pc[2] == 1`, confirming bank0 is ignored;
- ABTB alias and replacement behavior;
- PHT saturation and GHR indexing;
- redirect plus training in the same cycle;
- older redirect suppressing younger slot training;
- direct CALL push and RET pop;
- RET with invalid uRAS;
- redirect target broadcast to FTQ and predictor;
- provisional FTQ recovery entry cannot be consumed early;
- stage-2 override priority below backend redirect;
- no wrong-path ABTB/PHT/GHR/uRAS update.

Run focused functional regression first. Run performance suites only when
requested or when comparing predictor behavior. After RTL implementation,
inspect the real Vivado timing path and compare utilization and WNS before and
after the change.

## Deferred Decisions

Do not treat these as already decided:

- LUTRAM versus BRAM versus registers;
- exact ABTB PC hash and tag width;
- exact PHT PC bits and GHR folding function;
- target compression;
- ABTB/PHT write-to-read bypass;
- speculative GHR/uRAS update and snapshot recovery;
- partial FTQ rollback instead of full speculative flush;
- indirect JALR target predictor;
- future frontend correction experiments;
- larger ABTB capacity or additional ways.

Resolve these from correctness needs, profiling, utilization, placement, and
timing reports.

## Non-Negotiable Invariants

1. Target-table identity is PC-based, not GHR-based.
2. Conditional direction uses both PC and branch history.
3. Two slot candidates are evaluated in parallel and selected in program order.
4. A mispredicted valid CFI may redirect and train in the same cycle.
5. No speculative GHR/uRAS update means no GHR/uRAS rollback on redirect.
6. Wrong-path younger instructions must never train predictor state.
7. Redirect target may start FTQ recovery fetch and predictor lookup in
   parallel, but old-CFI metadata must not be reused for the new target block.
8. Backend redirect has priority over stage-2 override and stage-1 prediction.
9. Timing conclusions must come from implementation evidence.
