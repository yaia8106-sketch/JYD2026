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

The common pipeline consumes semantic structures from
`rtl/common/cpu_defs.sv`. RISC-V instruction encoding, immediate extraction,
frontend predecode, and privileged state live under `rtl/isa/riscv/`.
`rtl/isa/loongarch/` implements the phase-2 LA32R ordinary-integer boundary:
46 real instruction encodings plus the architectural NOP alias. LoongArch
exceptions/privileged state and the NSCSCC platform/AXI top remain later-phase
work.

Build selection is made by platform filelists, not SystemVerilog ISA macros.
RISC-V builds include `rtl/filelists/riscv_cpu.f`, which combines the common
pipeline with `rtl/isa/riscv/riscv.f`. LA32R ordinary-integer builds use
`rtl/filelists/loongarch_cpu.f` and `rtl/isa/loongarch/loongarch.f`.
