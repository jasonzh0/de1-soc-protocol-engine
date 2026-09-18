# Synchronous program-memory redesign

Implemented as an opt-in SRAM-backed ASIC candidate and the default USB FPGA
memory backend. **The released 64-word Tiny Tapeout configuration stays the
default until macro physical integration is closed.** No workflow was enabled
and the template physical configuration was not changed.

## Architecture

One execution core remains in `src/protocol_engine.v`. Its private
`program_store` module owns program data, read latency, half-word packing and
initialization. Firmware still owns all protocol behavior. Scratch stays as
256 bytes of registers for now, avoiding a second operand-latency change.

| PROGRAM_MEMORY | Program-store implementation | Initialization | Read |
| --- | --- | --- | --- |
| 0 (default) | Legacy 16-bit register array and per-word valid bits | Reset invalidates bitmap | Asynchronous |
| 1 | Packed 32-bit synchronous inferred RAM | Clocked zero scrub | Registered |
| 2 | Explicit `RM_IHPSG13_1P_1024x32_c2_bm_bist` | Same zero scrub | Registered |

Backend 2 requires `PROGRAM_ADDR_WIDTH=11`: 2048 instructions, 4096 bytes.
Backend 1 supports the existing 6–12 address-bit range. Backend choice is a
synthesis/elaboration parameter, not runtime state. The generic model has one
registered read port and one masked write port sharing the same selected address;
reads and writes are mutually exclusive. Yosys memory inference confirms one
1024×32 memory with clocked read/write for backend 1 at width 11. Actual Quartus
M10K placement and timing have not been run here.

The selected IHP macro and its source/physical contracts are documented in
[the memory source check](asic-memory-sources.md). `program_store` explicitly
instantiates it with A_DLY high and BIST inactive. It does not synthesize a
behavioral macro model as logic or silently fall back to flops in backend 2.
Missing macro models/Liberty must fail elaboration/synthesis.

## Fetch timing: one startup clock, no steady-state bubbles

In the synchronous profiles, RUN first performs one prefetch clock. Instruction
zero executes on the following clock. After that, normal instruction timing is
unchanged: one issue per clock in single-context mode; fixed round-robin when
two contexts are active; WAIT N still consumes N+1 context opportunities.

The current instruction computes `execute_pc_next` combinationally. That single
value drives both the PC update and the next memory address; PC control is not
duplicated in a separate predictive decoder. On the execution edge the SRAM
samples the next address and returns the next word for the following edge.
Branches/calls/returns/skips are resolved before that edge, not guessed. The
registered half-word selector accompanies the returned 32-bit word.

For two contexts the following fetch normally reads the other context's PC.
START_CTX redirects that fetch to the new child's entry address. WAIT, pin waits
and tick waits retain their existing context scheduling. HALT clears the prefetch
state, so every new RUN gets the same one-clock startup even after programming.
The legacy backend keeps its original RUN latency.

This meets the **RTL cycle contract**, not timing closure. The physical critical
path can now include SRAM clock-to-output, instruction decode/branch selection,
and setup of the next SRAM address. It must meet 20 ns at the relevant PVT/load
corners. The official functional model has no timing delays; behavioral passing
is not a substitute for Liberty STA or gate-level timing simulation.

## Initialization and write safety

The synchronous profiles eliminate the 2048-bit validity bitmap. Reset starts
a hardware scrub that writes zero to every 32-bit word using the normal SRAM
port. Opcode `0000` is invalid with or without the ISA extension. Thus sparse
loading remains supported: an untouched instruction faults on execution, rather
than reading uninitialized contents. Scratch initialization remains firmware's
responsibility.

- `program_ready` is low through reset and the scrub. At width 11 the scrub
  takes **1024 rising edges / 20.48 µs at 50 MHz** after reset release.
- Direct core callers must wait for `program_ready` before writing. Writes
  during scrub are ignored; RUN waits without driving pins until initialization
  and prefetch complete. The TT loader instead rejects early WRITE/RUN with its
  sticky host error, making missed writes visible to a host.
- A final scrub write is not also a host write. Begin host writes only on an
  edge after observing ready high. USB's boot adapter follows this rule.
- Programming is accepted only with RUN low. Halt/deselection retain program
  contents; reset scrubs them. Reset during scrub restarts the complete sweep.
- Even and odd instruction writes independently mask the low and high 16 bits
  of a packed word. No read/modify/write transaction is needed.
- Unwritten addresses, deliberately written invalid instructions, nested calls
  and other existing faults still release output enables.

There is no extra internal clock, no one-bit validity RAM, and no assumption
that power-on SRAM values are zero. Ready indicates memory initialization, not
that a complete or semantically valid user program has been loaded.

## Extended host addressing

The standard Tiny Tapeout pins and strobe timing are unchanged. The wrapper and
loader now parameterize address width. Commands 0–6 retain their meanings;
READ_SELECT is handled by the wrapper as before.

| Command | Default six-bit profile | Eleven-bit SRAM profile |
| --- | --- | --- |
| 1 ADDR_LO | Address [3:0] | Address [3:0] |
| 2 ADDR_HI | Address [5:4], data must be 0–3 | Address [7:4], data may be 0–15 |
| 7 ADDR_BANK | Invalid (unchanged) | Address [10:8], data must be 0–7 |
| Status bit 7 | Zero after reset | Initialization busy |

All address-setting commands preserve the other address fields. WRITE increments
the full address and wraps at the configured program size. HALT/reset/deselection
clear the loader address and error state. A partial 16-bit word or a sticky host
error blocks RUN. READ_SELECT=1 still returns the captured byte, so poll readiness
with status selected. RUN/write commands during execution remain rejected.

The wider store does not change encoded target sizes: JMP/LOOP use the configured
PC width, legacy CALL/JMP_PIN/START_CTX stay six-bit, and extended CALL stays
ten-bit. Existing USB firmware already places its called routines accordingly.

## Build profiles and checks

The existing `de1_soc_demo.qpf` and default TT top preserve backend 0.
`de1_soc_usb.qpf` now uses backend 1, with its boot loader waiting for scrub.
USB firmware, pin mapping and physical-attach safety gate are unchanged.

```sh
make test                  # Legacy suite, store/loader safety, fetch comparisons
make test-sync             # Clocked model: extended ISA, UART/SPI/I2C, USB rates
make test-usb-board        # Actual USB FPGA boot/PHY adapter
make test-ihp-memory       # Pinned IHP models: memory/host/core/all protocols
make synth-sram YOSYS='uvx --from yowasp-yosys yowasp-yosys'
```

The last two targets download only pinned Apache-2.0 IHP simulation/Liberty
files into ignored `build/ihp-sram/`, not a full PDK or application installation.
Their script pins the same PDK commit used in the evaluation. The mapped netlist
is `build/asic_sram_mapped.v`; it is **not** a submission GDS or a timing-closed netlist.

Tests include 24,000 cycle-by-cycle public-port comparisons against the legacy
backend, after offsetting RUN by the documented prefetch clock. They exercise
two contexts and deterministic randomized high-bank byte-processing programs.
Other regressions cover masking and every program address, reset interruption,
busy writes/RUN, sparse holes, high banks/wrap, errors, HALT/ena retention,
extended calls/flags/CRC, and independent UART/SPI/I²C/USB peers. The IHP USB test
also loads the entire image through the actual Tiny Tapeout host pins before
enumerating; it does not bypass the widened loader. No test inspects private
execution registers. These are finite regressions, not an exhaustive proof.

## Preliminary mapped area (2026-09-18)

The complete SRAM candidate, including host/pad adapter and the unchanged
256-byte scratch register array, mapped to **390,024.74 µm² (0.390025 mm²)**:

| Part | Area |
| --- | ---: |
| One 1024×32 SRAM | 140,182.69 µm² |
| Standard-cell logic, including 2499 flops | 249,842.05 µm² |
| Total cells + macro | 390,024.74 µm² |

This compares with **3.053980 mm² for the earlier USB core alone**, without its
host adapter: about an 87% reduction despite the wider comparison scope.
The current 6×4 template rectangle is 0.916214 mm². That leaves credible area
headroom for physical integration; it does not establish routed fit. Mapping
used typical 1.2 V/25°C Liberty, default ABC optimization, no physical parasitics
and no explicit 20 ns constraint, as in the [evaluation](asic-memory-evaluation.md).
Clock/tie/hold cells, macro halos and PDN overhead still need budgeting.

**Next gate:** pin full-flow revisions, supply all macro corners/LEF/GDS, create
and validate macro placement/PDN hookups for `VDD!`, `VDDARRAY!`, `VSS!`, then run
placement/routing, 50 MHz STA, DRC/LVS/precheck and mapped protocol regressions.
Only then select the SRAM profile as the submission default. Scratch SRAM is
deferred unless measured physical area warrants its operand-latency complexity.
