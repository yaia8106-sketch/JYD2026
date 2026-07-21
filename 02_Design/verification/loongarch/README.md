# LoongArch verification

Run the phase-2 ordinary-integer verification gate with:

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

This phase intentionally excludes PRELD, LL.W/SC.W, DBAR/IBAR, counter reads,
SYSCALL/BREAK, CSR/TLB/cache-maintenance instructions, precise ALE/INE/ADEF
handling, and the NSCSCC AXI/platform wrapper.
