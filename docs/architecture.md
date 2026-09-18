# Architecture and extension guide

## Intent

Keep the same execution behavior on FPGA and ASIC. Board wiring, host commands,
and instruction execution are separate modules with explicit interfaces.
Keep the interfaces small; add an abstraction when a real implementation needs
it, rather than introducing a configurable framework in advance.

```text
DE1 mode switches -> firmware_bootloader ------------+
                                                    |
Tiny Tapeout pins                                    v
  -> strobe adapter -> program_loader -> programming interface
                                                    |
                                             protocol_engine
                                                    |
                                              pin_out / pin_oe
                                                    |
                                      board I/O or Tiny Tapeout pads
```

## Module ownership

| Module / files | Owns | Must not own |
| --- | --- | --- |
| `src/protocol_engine.v` | ISA, shared memory, optional two-context scheduling, private context state, pins/capture/timing/faults | Board pins, protocol-specific logic, host encoding, vendor primitives |
| `src/program_loader.v` | Address/data staging, host commands, run control, loader errors | Pad names, clocks derived from host strobes, instruction execution |
| `src/tt_um_jasonzh0_protocol_engine.v` | TT ports, strobe detection, status/result selection, output-enable gating | ISA logic, vendor I/O buffers |
| `firmware/` | Protocol-specific instruction sequences and basic configurations | Fixed-function protocol hardware or host transport |
| `rtl/de1_protocol_top.v` | Active board reset, mode synchronization, GPIO, LEDs/displays | ISA or host command execution |
| `rtl/firmware_bootloader.v` | FPGA-only example ROMs, boot-mode latch, program upload | ASIC power-on memory or protocol execution |
| `rtl/de1_soc_top.v` | Legacy key demo board adapter, retained for regression | A second copy of the engine |
| `rtl/button_events.v` | Input synchronization and debounced key-down events | UART or character mapping |
| `rtl/uart_program_sender.v` | One-byte UART instruction generation and execution window | Button names, physical pins, a duplicate UART execution core |
| `quartus/` | DE1 device, pin mapping, timing constraints | ASIC settings |
| `info.yaml`, `src/config.json` | Tiny Tapeout source list and ASIC flow configuration | FPGA source/pin settings |

The core programming interface has a boot-ROM adapter for FPGA, a host-controlled
loader for ASIC, and the legacy UART sender. This is the useful seam for a future
UART, SPI, or processor host. The current program_loader accepts one command
per asserted `command_valid` clock; a new transport converts its packets to
those commands, or drives the core's word-write interface directly.

## Core interface contract

- One rising-edge clock. All programming and `run` inputs are synchronous.
- Active-low reset asserts asynchronously; the caller must release it with
  proper clock timing. The DE1 wrapper supplies a reset synchronizer.
- With `run=0`, `prog_we=1` writes one 16-bit word at `prog_addr` on that edge.
  Programming while running is ignored. The write port has no backpressure.
- Keep `run=0` during the final write edge; assert run on a later edge.
- Taking `run` low restarts PC/wait/output/fault state; it is a restart, not a
  resumable pause. Program words and validity survive a halt.
- Reset invalidates all 64 words. Unwritten memory cannot execute, even though
  the 1024 data bits themselves have no reset. An invalid address fetch or opcode
  latches fault and releases the output enables.
- `pin_out` is a value and `pin_oe` is a drive mask. The caller implements the
  physical tri-state. The core contains no `inout` or device-specific cells.
- In single-context mode WAIT N takes N+1 clocks; SET/DIR/JMP take one. Changes to fetch latency or
  instruction timing are ISA changes and require updating firmware/tests.
- Full opcode, scheduling, sampling, ownership, capture and stall contracts: [ISA v1.1](isa.md).
  Pin inputs cross two flops; no vendor-specific I/O logic is inside the core.
  HALT preserves the last captured byte/toggle. CAPTURE overwrites one result
  register without backpressure; this first version has no TX/RX FIFO.

## Where future changes go

| Change | Expected place |
| --- | --- |
| New board / pinout | New board adapter and its constraints; reuse the core |
| UART/SPI host transport | Transport adapter to program_loader or core write port |
| New instruction | Core ISA and timing contract, firmware and behavioral tests |
| New protocol firmware | Instruction words, without replacing the core |
| SRAM implementation | Internal program-store seam, once an actual macro is selected |
| Larger instruction memory | Coordinated address width, loader, firmware, tests, and physical-flow change |

UART, SPI and I2C are firmware configurations of one engine, not three
peripherals. A generic START_CTX instruction enables two independent contexts
on one decoder/datapath; it is not a UART enable bit or a second UART block.
Round-robin timing is fixed even while either context waits. All pin ownership
and single-result publication rules are explicit in the ISA contract.
The examples support full-duplex UART, one-byte SPI mode 0, and one-byte
single-master I2C read/write. FIFO streaming,
UART program upload and a Python compiler/library are deferred, not hidden
dependencies. Keep a future uploader separate from protocol-pin execution.

The current asynchronous instruction read is part of the timing design. A
synchronous SRAM is not a drop-in replacement: it changes fetch scheduling.
Keep storage internal until a real FPGA/ASIC implementation difference requires
a separate module, then document the latency contract explicitly.

## One clock, two contexts, asynchronous external pins

There is one execution unit with two sets of thread state, not two parallel
execution units. The scheduler alternates them on the same clock. At 50 MHz,
each active context gets an execution opportunity every 40 ns; the clock still
has a 20 ns period. Output registers retain their values between instructions,
so firmware can transmit and receive concurrently without issuing two
instructions on one edge. This saves duplicated execution resources in intent,
but mux/scheduling overhead and the actual area tradeoff require mapped results.

True parallel issue would also need two instruction fetches (or buffered
instructions) and rules for simultaneous pin/result writes. It is an ISA/timing
and memory-interface change, not a scheduler toggle. Keep the current deterministic
schedule until throughput requirements and area measurements justify changing it.

The two input flip-flops per protocol pin serve a different purpose: a remote
UART transmitter, switches, and externally driven bus signals need not meet
setup/hold against our clock. They synchronize asynchronous inputs into that
single internal domain. They are not context-to-context synchronizers. Keep
inter-stage paths timed; the Quartus constraints cut only asynchronous pin paths
to the first stage. See [Intel's synchronizer guidance](https://www.intel.com/content/www/us/en/docs/programmable/683068/18-1/metastability-analysis.html).

The Tiny Tapeout **host command bus** instead has an explicitly synchronous
interface and no CDC adapter. Independent bit synchronizers would not make
that command bus coherent. An asynchronous host would need a separate, defined
transfer protocol. Firmware must also budget protocol-input synchronization
latency; synchronizers are not a substitute for external bus timing analysis.

## Area and program-memory gate before tapeout

The store is **64 x 16-bit instruction words = 128 bytes**, not 64 general-purpose
registers and not 64 words per context. Both contexts share it. The duplex UART
image occupies addresses 0 through 43 including padding; the I2C-read image uses
47 words. These examples fit, but richer protocol state machines may not.

Generic `synth -noabc` currently maps the program data to 1,024 enabled flip-flops;
the core also has 64 validity bits, thread state and substantial mux logic. This
is a structural warning, not a foundry-cell area estimate or evidence of 6x4 fit.
The FPGA-only boot ROMs are excluded from ASIC sources.

Next physical-design checks, before committing to a memory architecture:

1. Measure the current design with the exact CMOS5L flow/PDK: mapped cell area,
   placed utilization, routing and timing. CI remains paused; generic synthesis
   alone cannot settle the area question.
2. Identify a hard SRAM supported by that flow, including simulation model,
   Liberty timing, LEF/GDS, supply connections, metal-stack compatibility and
   placement/PDN clearances. Tiny Tapeout documents IHP SRAM options but warns
   integration is nontrivial; its SG13G2 table is not a CMOS5L fit guarantee.
   See [Tiny Tapeout memory guidance](https://www.tinytapeout.com/specs/memory/).
3. Compare total placed cost, not just bits: macro + read controller + validity
   mechanism + execution logic. At only 128 bytes, macro minimum size and
   peripheral overhead matter; more SRAM capacity may be useful nonetheless.
4. Design synchronous fetch around the chosen read latency. Alternating contexts
   may allow fetch/execute overlap, but branches, waits, reset, start-up and
   single-context mode need explicit treatment and cycle-level tests. Do not
   merely change the Verilog array and assume SRAM inference or preserved timing.
5. If capacity grows, update PC widths, branch/call encodings, host addressing,
   validity handling and firmware together. Current six-bit targets cannot reach
   a larger memory just by increasing its array depth.

No hard SRAM has been integrated or physical fit established. Named opcode
constants in the core are a readability change, not an area optimization.

## Verification and source lists

`make test-fpga` exercises the actual Quartus top: six configurations, simultaneous UART
TX/RX, SPI loopback, I2C read/write, received-byte displays, fault recovery and
mode latching until reset. `make test-fpga-legacy` checks key mappings, bounce rejection, one byte per press,
held/released keys, simultaneous presses, LED status and display glyphs. Only
debounce duration is reduced in simulation; UART timing is real. `make test-tt` loads and runs
programs entirely through the Tiny Tapeout ports, including rewriting UART
firmware, command errors, high addresses/wrap, invalid instructions, reset,
deselection, and drive masks. Tests do not reach into private registers.
`make test-protocols` loads the checked-in firmware through TT pins, driving
independent serial peers including I2C NACK/stretch, asynchronous overlapping
UART traffic, exact TX intervals, independent context return slots and faults.
`make test-template` is the official-style Cocotb RTL/GL-compatible harness.
`make check-template` checks local metadata/port/source/config consistency.
`make synth` checks generic synthesizability and structural consistency; it does
not use the IHP library or prove 50 MHz/6x4-tile fit.

Tiny Tapeout expects submission RTL in `src/`. That is why the shared core lives
there. Keep a single copy and reference it from Quartus. If files move or modules
are added, update each applicable explicit source list: `info.yaml`, Makefile,
`scripts/synth.ys`, `test/Makefile`, and `quartus/de1_soc_demo.qsf` as applicable.

GitHub CI is paused by user request. Keep it paused until explicitly requested.

## Experimental USB profile

The [USB experiment](usb.md) uses this same core with `PROGRAM_ADDR_WIDTH=11`
and `EXTENDED_ISA=1`. It is single-context firmware over generic byte-processing,
CRC, NRZI/stuffing and pin-sampling instructions. USB requests, descriptors and
endpoint state live in `firmware/usb_ls/build_firmware.cpp`, not in RTL.
The [extension contract](isa-extended.md) defines widths, timing and errors.

`rtl/usb_firmware_bootloader.v` loads a generated FPGA ROM through the existing
programming port; `rtl/de1_usb_top.v` gates an external PHY and implements board
controls. `quartus/de1_soc_usb.qpf` owns the separate source/timing configuration.
These files are not part of `info.yaml`. The existing board project and ASIC
wrapper retain their 64-word defaults and unchanged loader interface.

The wider asynchronous store and scratch RAM are not hard SRAMs. Physical fit,
memory/fetch redesign and host-loader expansion are prerequisites to enabling
USB on the ASIC. This FPGA-first profile must not be described as fitting 6x4.

## Active FPGA boot contract

The QSF selects `de1_protocol_top`, which connects the shared engine to the
first eight GPIO pins. SW9 resets; SW1:0 selects duplex UART/RX/SPI/I2C.
SW2 selects I2C read/write or duplex UART 31250/115200 baud; it is ignored in
standalone RX and SPI. Four settling
clocks follow reset release before mode capture; selected firmware is loaded
one instruction per clock. The final write occurs with run low; execution
starts on the following edge. Mode stays latched until reset.

The boot ROMs and their `$readmemh` initialization are FPGA-only, in `rtl/`.
Do not add them to `info.yaml`. ASIC program memory is still externally loaded
after reset. ROM file paths are relative to the Quartus project directory.
HEX5 shows mode (0,1,2,3,4 for Uno UART, or 7 for I2C read); HEX1:0 show the result.
LEDR6 indicates alternate UART/I2C firmware selection. KEY inputs are unused.
The Uno tester is in `arduino/`, outside both FPGA and ASIC execution RTL.
Its conservative baud profile is firmware, not special UART logic in the core.
GPIO output timing has a prototype 20 ns register-to-pin path budget; it is
not a complete peer/board timing model. See the Quartus guide before changing rates.

## Legacy FPGA key-down demo contract

This RTL remains tested but is no longer included in the active Quartus project.

`button_events` emits one clock pulse after each key remains low for 10 ms at
50 MHz. A release must also debounce before that key can press again. A key
held during reset counts as one press after reset release and debounce.

The board keeps one pending event per key and services simultaneous presses in
KEY3..KEY0 order. Four UART transfers take under 0.4 ms, much less than the
default debounce interval, so the queue drains before another press from the
same key. If changing baud rate or debounce duration, reassess this queue bound;
arbitrarily fast simulated same-key events can coalesce in this bounded queue.

`uart_program_sender` accepts a byte on `valid && ready`. It programs 23 words
through the normal core write interface, executes the UART program, and pulses
`sent` after an 11-bit-time execution window that includes the full stop bit
and idle gap. The program ends with JMP-to-self while TX is high. This window
depends on the documented ISA timing; update it if fetch/instruction timing
changes. A fault stays latched until reset, blocks new sends, and leaves TX idle.

SW9=1 resets the board; SW9=0 runs. All four KEY inputs are character inputs.
Display segment patterns and key-to-character mapping belong to the board
adapter; they do not change the portable core or Tiny Tapeout host interface.
