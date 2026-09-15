# Programmable protocol engine

## How it works

A 32-word, 16-bit programmable engine drives eight pins. Its SET, DIR, WAIT,
and JMP instructions generate timed digital waveforms. Program data comes from
the dedicated Tiny Tapeout inputs; all eight bidirectional pins are reserved
for protocol signals. The current ISA produces outputs only and does not sample
`uio_in`. The DE1-SoC demo and this wrapper share `src/protocol_engine.v`.

Top module: `tt_um_jasonzh0_protocol_engine`.

## Host interface

All host signals are synchronous to `clk`. Update the input bus on a falling
edge (or otherwise meet rising-edge setup/hold). The wrapper has no asynchronous
host clock-domain crossing circuit. Do not treat `host_strobe` as a clock.

| Pins | Meaning |
| --- | --- |
| `ui_in[3:0]` | Four-bit command data |
| `ui_in[6:4]` | Three-bit command code |
| `ui_in[7]` | Command strobe |
| `uo_out[0]` | Running and not faulted |
| `uo_out[1]` | Core fault: invalid opcode or unwritten instruction |
| `uo_out[2]` | Sticky loader error |
| `uo_out[3]` | Four data nibbles staged, ready for WRITE |
| `uo_out[4]` | Toggles once per command strobe, including rejected commands |
| `uo_out[7:5]` | Always zero |
| `uio_out[7:0]` | Engine output values |
| `uio_oe[7:0]` | Per-pin drive enable: 1 drives, 0 releases |
| `uio_in[7:0]` | Reserved input path; currently unused |

A command is processed when strobe changes from sampled low to sampled high.
Hold the command/data stable for that sampling edge. Keep strobe low for at
least one rising edge between commands. Holding strobe high does not repeat a
command. The acknowledgment toggles on the processing edge; outputs settle
after that edge. Inspect loader_error as acknowledgment alone does not mean
the command was valid.

### Commands

| Code | Name | Data / effect |
| --- | --- | --- |
| 0 | HALT | Stop; reset write address to 0; discard partial word; clear loader error |
| 1 | ADDR_LO | Set write-address bits 3:0 |
| 2 | ADDR_HI | Set address bit 4; only data 0 or 1 is valid |
| 3 | DATA | Append a nibble, most-significant nibble first; exactly four per word |
| 4 | WRITE | Commit staged word; clear word_ready; increment address modulo 32 |
| 5 | RUN | Start at instruction 0, provided no partial word or loader error exists |
| 6–7 | Reserved | Set loader error |

Command data is ignored for HALT, WRITE and RUN. Address selection does not
discard a staged word. A fifth DATA nibble and a WRITE with fewer than four
nibbles set loader_error without changing the staged word or program memory.
While running (including a core fault), only HALT is accepted. Other commands
set loader_error without changing the program or stopping the core.

Loader errors remain until HALT, reset, or clocked deselection. Valid loading
commands can still modify the staging registers/memory after a loader error,
but RUN remains blocked. The recommended recovery is HALT and reload.

### Minimal program example

This program drives all eight protocol pins to `0xA5`:

```text
Address  Instruction
0        10A5          SET A5
1        30FF          DIR FF
2        4002          JMP 2
```

Send the following `(command, data)` pairs, pulsing strobe for each:

```text
(0,0)                         HALT, write address = 0
(3,1) (3,0) (3,A) (3,5) (4,0) write 10A5
(3,3) (3,0) (3,F) (3,F) (4,0) write 30FF
(3,4) (3,0) (3,0) (3,2) (4,0) write 4002
(5,0)                         RUN
```

For each pair, construct the low-strobe bus value as `(command << 4) | data`;
the high-strobe value is that value OR `0x80`. Example: DATA A uses `ui_in=0x3A`
for a sampled low edge, then `0xBA` for a sampled high edge, then `0x3A` again.

To reprogram, HALT, load new words, then RUN. Every instruction reachable in
the new program must be deliberately written; halting does not erase older
words. Assert reset to invalidate all previous instructions before a clean load.

## Reset, enable, and electrical behavior

- Assert `rst_n=0` before use. Release reset with valid clock timing and strobe
  low. Reset invalidates every instruction and releases all protocol outputs.
- `ena=0` immediately gates off the output enables. Hold it low across at least
  one rising clock edge to halt the core and clear the command interpreter.
  After this clocked deselection, reselecting preserves program memory but does
  not auto-start. If deselection stops the clock before an edge occurs, reset
  before reselecting; a brief ena pulse alone does not clear internal state.
- HALT releases outputs after its command edge. The core clears its PC/fault
  state on the next clock edge. Leave clocks running during halt/reload.
- `uo_out` is zero while reset or deselected. A core fault disables protocol
  outputs and remains latched until HALT, reset, or clocked deselection.
- Open-drain waveforms can use SET 0 and DIR to alternate drive-low/release;
  external pull-ups and appropriate voltage levels are required.

## How to test

Run `make test` from the repository root. The tests check the FPGA key-down
demo and upload UART firmware through only the Tiny Tapeout pins, decoding
three 0x55 frames followed by reprogramming and decoding two 0xAA frames.
They also check malformed commands, address 31 and wraparound, protected
running writes, output directions, faults, reset and deselection.

Run `make synth` with Yosys for a generic structural synthesis check. A portable
alternative is `make synth YOSYS="uvx --from yowasp-yosys yowasp-yosys"`.
The synthesis script deliberately omits technology-specific mapping.

## External hardware

A clock/reset source and synchronous host bus driver are needed to load and
run programs. Connect protocol pins to a compatible logic analyzer or UART
receiver as appropriate. Voltage levels depend on the actual Tiny Tapeout
carrier; the DE1-SoC board's 3.3 V specification is not a specification for the
eventual ASIC package/carrier.

## ASIC flow status

The standard Tiny Tapeout port interface and source metadata are present.
`info.yaml` requests the competition's `6x4` tile allocation and a 50 MHz target.
The source files are all in `src/`, as required by the template. The unchanged
`src/config.json` is from the official CMOS5L template at commit
`b86a2a781484bcab7ba522dc5de540086695a430`; it targets a 20 ns clock.

References: [CMOS5L template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/b86a2a781484bcab7ba522dc5de540086695a430)
and [competition requirements](https://blog.janestreet.com/protocol-emulator-asic-competition/).
The template's info.yaml comment lists older tile sizes; the competition
explicitly specifies `6x4`. The allocation here follows the competition rule.

Simulation and generic synthesis have passed. No CMOS5L mapped area, physical
design, DRC/LVS, timing closure, or fabricated-chip validation is claimed. The
instruction store currently infers 512 data flip-flops plus 32 resettable
validity bits; assess that cost in the real process before selecting SRAM.
This repository does not bundle the Tiny Tapeout toolchain or a GDS workflow;
use the official CMOS5L tooling for the physical-flow step. CI remains paused.
