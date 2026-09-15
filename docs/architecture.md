# Architecture and extension guide

## Intent

Keep the same execution behavior on FPGA and ASIC. Board wiring, host commands,
and instruction execution are separate modules with explicit interfaces.
Keep the interfaces small; add an abstraction when a real implementation needs
it, rather than introducing a configurable framework in advance.

```text
DE1 buttons -> event queue -> uart_program_sender ----+
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
| `src/protocol_engine.v` | ISA, program memory, validity, cycle timing, fault behavior | Board pins, host command encoding, vendor primitives |
| `src/program_loader.v` | Address/data staging, host commands, run control, loader errors | Pad names, clocks derived from host strobes, instruction execution |
| `src/tt_um_jasonzh0_protocol_engine.v` | TT port names, strobe detection, status packing, output-enable gating | ISA logic, vendor I/O buffers |
| `rtl/de1_soc_top.v` | Board reset, key mapping/queue, GPIO buffers, LEDs and displays | A second copy of the engine |
| `rtl/button_events.v` | Input synchronization and debounced key-down events | UART or character mapping |
| `rtl/uart_program_sender.v` | One-byte UART instruction generation and execution window | Button names, physical pins, a duplicate UART execution core |
| `quartus/` | DE1 device, pin mapping, timing constraints | ASIC settings |
| `info.yaml`, `src/config.json` | Tiny Tapeout source list and ASIC flow configuration | FPGA source/pin settings |

The core programming interface already has two adapters: the one-byte UART
program sender and the host-controlled loader. This is the useful seam for a future
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
- Reset invalidates all 32 words. Unwritten memory cannot execute, even though
  the 512 data bits themselves have no reset. An invalid address fetch or opcode
  latches fault and releases the output enables.
- `pin_out` is a value and `pin_oe` is a drive mask. The caller implements the
  physical tri-state. The core contains no `inout` or device-specific cells.
- WAIT N takes N+1 clocks; SET/DIR/JMP take one. Changes to fetch latency or
  instruction timing are ISA changes and require updating firmware/tests.

## Where future changes go

| Change | Expected place |
| --- | --- |
| New board / pinout | New board adapter and its constraints; reuse the core |
| UART/SPI host transport | Transport adapter to program_loader or core write port |
| New pin-input instruction | Core interface/ISA plus input synchronization rules; connect TT `uio_in` and FPGA input path |
| New protocol firmware | Instruction words, without replacing the core |
| SRAM implementation | Internal program-store seam, once an actual macro is selected |
| Larger instruction memory | Coordinated address width, loader, firmware, tests, and physical-flow change |

The current asynchronous instruction read is part of the timing design. A
synchronous SRAM is not a drop-in replacement: it changes fetch scheduling.
Keep storage internal until a real FPGA/ASIC implementation difference requires
a separate module, then document the latency contract explicitly.

## Verification and source lists

`make test-fpga` checks key mappings, bounce rejection, one byte per press,
held/released keys, simultaneous presses, LED status and display glyphs. Only
debounce duration is reduced in simulation; UART timing is real. `make test-tt` loads and runs
programs entirely through the Tiny Tapeout ports, including rewriting UART
firmware, command errors, high addresses/wrap, invalid instructions, reset,
deselection, and drive masks. Tests do not reach into private registers.
`make synth` checks generic synthesizability and structural consistency; it does
not use the IHP library or prove 50 MHz/6x4-tile fit.

Tiny Tapeout expects submission RTL in `src/`. That is why the shared core lives
there. Keep a single copy and reference it from Quartus. If files move or modules
are added, update each applicable explicit source list: `info.yaml`, Makefile,
`scripts/synth.ys`, and `quartus/de1_soc_demo.qsf`.

GitHub CI is paused by user request. Keep it paused until explicitly requested.

## FPGA key-down demo contract

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
