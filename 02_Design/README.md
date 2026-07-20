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

Current RTL behavior is unchanged by this directory split. The active core is
still RISC-V; the LoongArch and competition-specific CPU tops remain scaffolds
until their interfaces and RTL are implemented.

Build selection is made by platform filelists, not SystemVerilog ISA macros.
