# 02_Design directory ownership

The design tree is split by dependency boundary:

- `rtl/`: platform-independent CPU, memory, and ISA RTL.
- `platform/jyd/`: JYD integration RTL and immutable official sources.
- `platform/nscscc/`: NSCSCC integration RTL and future official sources.
- `verification/common/`: ISA-independent directed RTL tests.
- `verification/riscv/`: RISC-V programs, integration regression, performance,
  COE data, and utilities.
- `verification/platform/`: board-wrapper smoke tests and behavioral IP models.
- `model/`: architectural exploration models.
- `docs/`: design notes.

The active core currently selects the RISC-V implementation. Its instruction
encoding, immediate extraction, frontend predecode, and privileged state live
under `rtl/isa/riscv/`; the common pipeline consumes semantic structures from
`rtl/common/cpu_defs.sv`. The LoongArch ISA files and the NSCSCC CPU top remain
scaffolds until that ISA is implemented.

Build selection is made by platform filelists, not SystemVerilog ISA macros.
RISC-V builds include `rtl/filelists/riscv_cpu.f`, which combines the common
pipeline with the selected `rtl/isa/riscv/riscv.f` adapter modules.
