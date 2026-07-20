# IROM64 COE Files

This directory contains the 64-bit IROM initialization files used by the FTQ frontend.

Each subdirectory mirrors a program under `../single_issue/` and contains:

- `irom64.coe`: 4096 entries of 64-bit IROM data.
- `dram.coe`: unchanged DRAM initialization data copied from the source program.

`irom64.coe` packs two sequential 32-bit instructions per entry:

```
entry[n] = { inst[2*n + 1], inst[2*n] }
```

The low 32 bits are the instruction at the lower PC, and the high 32 bits are the instruction at `PC+4`. Empty space is padded with `00000013` NOPs.

Regenerate all files with:

```bash
python3 02_Design/verification/riscv/coe/convert_irom64_coe.py
```
