# Working on this repository

- Read `docs/architecture.md` before changing module interfaces or source layout.
- Keep one portable core in `src/protocol_engine.v`. Both FPGA and Tiny Tapeout
  use it; do not fork/copy its implementation for a target.
- Keep ISA execution, host loading, and board/pad adapters separate. Introduce
  new seams only for concrete implementation differences.
- Document interface timing, reset/enable behavior, and error handling alongside
  any change. Never silently change instruction cycle counts.
- Keep submission RTL in `src/`. Update applicable source lists in `info.yaml`,
  `Makefile`, `test/Makefile`, `scripts/synth.ys`, and Quartus settings when files change.
- Use public module ports for behavioral verification. Prefer end-to-end tests
  that demonstrate observable behavior over private-register assertions.
- Run the relevant local tests after RTL changes. `make test` covers both targets;
  `make synth` checks generic synthesis when Yosys is available.
- GitHub CI is intentionally paused. Do not enable it without the user's request.
- Keep protocol behavior in firmware for the shared engine, not separate fixed
  UART/SPI/I2C hardware. Document ISA changes in `docs/isa.md`.
- Context scheduling is generic, fixed round-robin after START_CTX. Preserve
  single-context timing; never add UART-specific scheduling or hidden pin ownership.
- Preserve template alignment (`docs/template.md`). The Python compiler/library
  and UART uploading transport are deferred; template Cocotb tests are separate.
- Distinguish simulation/generic synthesis from actual Quartus builds and
  CMOS5L physical verification. Do not claim tapeout readiness without evidence.
