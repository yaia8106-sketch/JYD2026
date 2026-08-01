# LoongArch verification

Run the ordinary-integer decode/execute gate with:

```bash
bash functional/run_decode_contract.sh
```

The gate now has three layers:

- the decoded-uop contract covers all 46 ordinary LA32R integer encodings,
  immediate/register edge cases, named out-of-scope containment, every one of
  the 131072 possible `inst[31:15]` opcode prefixes, full/predecode
  consistency, and the shared ALU's NOR operation;
- the frontend test carries semantic multiply/divide metadata through
  F0 -> FTQ -> IF/ID and checks LoongArch-specific pairing dependencies;
- the `cpu_top` execution smoke runs a real instruction stream through dual
  issue, forwarding, MUL/DIV, branch/JIRL redirects, load/store, and r0 write
  suppression.

Shared microarchitecture unit tests remain under `../common/`.

For the competition-facing regression, including caches, AXI, interrupts,
privileged boundary cases and the exact NSCSCC `core_top`, run:

```bash
bash ../platform/nscscc/functional/run_rtl_regression.sh
```

The privileged boundary layer deliberately backpressures MEM while CSR,
SYSCALL and ERTN flow through the backend. It checks that older instructions
are drained first, that a legal privileged token commits exactly once without
depending on DCache readiness, and that misaligned load/store/fetch, Slot-1
alignment replay and wrong-path flush cases retain precise behavior.

Unsupported architectural features remain outside this gate unless the core
advertises them: PRELD, LL.W/SC.W, DBAR/IBAR, TLB operations and CACOP cache
maintenance. The gate does cover the implemented counter/CPUCFG, CSR,
SYSCALL/BREAK, ERTN, ALE/INE/ADEF and NSCSCC AXI behavior.
