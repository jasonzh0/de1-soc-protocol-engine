# DE1-SoC Protocol Engine

A small programmable Verilog pin engine shared by a ready-to-open Quartus
Prime project and a Tiny Tapeout wrapper. The DE1-SoC demo sends one ASCII
character per key-down at approximately 115200 baud, 8N1, and displays `C H U d`
on the rightmost four seven-segment displays.

| Key | UART character |
| --- | --- |
| KEY3 | C |
| KEY2 | H |
| KEY1 | U |
| KEY0 | D |

Holding or releasing a key sends nothing extra. Each input is debounced for
10 ms. Simultaneous presses are queued in KEY3 → KEY2 → KEY1 → KEY0 order.
Reset has moved to **SW9: 1 = reset, 0 = run**.

## Tiny Tapeout interface

The standard `tt_um_jasonzh0_protocol_engine` top-level module loads programs
through eight dedicated input pins and drives eight bidirectional protocol
pins. A separate host loader handles commands; the core owns instruction
execution. See [host commands and ASIC integration](docs/info.md) and
[architecture and extension points](docs/architecture.md).

## Open in Quartus Prime

1. Install **Quartus Prime Lite or Standard** with **Cyclone V** device support
   on a supported Windows or Linux computer.
2. Clone this repository or download and extract its ZIP.
3. In Quartus, select **File → Open Project** and open
   **[`quartus/de1_soc_demo.qpf`](quartus/de1_soc_demo.qpf)**.
4. Select **Processing → Start Compilation**.
5. On Rev. H/H1, set **SW17.1 = 1, SW17.2 = 0** to select the FPGA JTAG path.
   Open **Tools → Programmer**, select the board's USB-Blaster in Hardware
   Setup, and use JTAG mode. Add `quartus/output_files/de1_soc_demo.sof`, select
   Program/Configure for the FPGA, and click Start.
6. Set **SW9 to 1, then back to 0** to reset and enable the demo. Press a key
   to send its character. HEX3–HEX0 display `C H U d`; HEX5–HEX4 are blank.

The project already selects `5CSEMA5F31C6`, its four RTL source files, the
top-level module, the 50 MHz clock constraint, and all 103 top-level pin assignments.
No New Project Wizard or manual source-file setup is needed.

The target board is **DE1-SoC revision H1**. All 103 pin locations and I/O
standards match **Terasic's Rev. H System CD v6.0.0**; they also match the earlier
F/G reference for the original clock/key/LED/GPIO signals. Terasic labels the
checked support package Rev. H, not H1.
See [the Quartus guide](docs/quartus.md) for wiring, sources, and troubleshooting.

## Check execution without a receiver

After resetting with SW9 and returning it to 0, expect LEDR[0] on and LEDR[1]
off. **LEDR[2] changes state once per completed byte**: press a key and watch it
toggle; hold the key and it stays steady. LEDR[9:6] indicate the last accepted
key, in KEY3..KEY0 order. LEDR[3] is busy during the brief transmission.
The displays always show `C H U d`; the lowercase-style d is the available
seven-segment form of D. LEDs do not validate the external connector/wiring.
Recompile and reprogram the FPGA to get this updated behavior.

## See the UART output

Connect **GPIO_0[0]** to the RX input of a **3.3 V USB-UART adapter**, and connect
grounds. Find the physical header position in your board's manual; the signal
index is not a header pin number. Open a terminal at **115200, 8N1, no flow
control**. Press KEY3, KEY2, KEY1, KEY0 to receive `CHUD`, with no newline or
carriage return added. Idle, held keys, and releases produce no extra bytes.

The onboard USB-Blaster is the programming connection. The serial demo uses
the separate adapter. Do not connect 5 V or RS-232 signal levels to FPGA GPIO.

## What is here?

| Path | Purpose |
| --- | --- |
| `src/protocol_engine.v` | Shared core: 32-word instruction memory and eight output channels |
| `src/program_loader.v` | Host commands and program staging, independent of pad names |
| `src/tt_um_jasonzh0_protocol_engine.v` | Tiny Tapeout pin adapter and status outputs |
| `info.yaml`, `src/config.json` | Tiny Tapeout source metadata and CMOS5L flow settings |
| `rtl/de1_soc_top.v` | Board reset, key queue/mapping, GPIO buffers, LEDs and displays |
| `rtl/button_events.v` | Synchronized/debounced key-down events |
| `rtl/uart_program_sender.v` | One-byte UART program loader using the shared core |
| `quartus/de1_soc_demo.qpf` | Open this file in Quartus |
| `quartus/de1_soc_demo.qsf` | FPGA device, source files, and build settings |
| `quartus/de1_soc_pins.qsf` | Board pin locations and 3.3 V I/O standards |
| `quartus/de1_soc_demo.sdc` | Clock and demo-specific timing exceptions |
| `test/tb_uart.v` | Key-down UART, bounce/hold/release, queue, LED and display checks |
| `test/tb_tiny_tapeout.v` | Program loading, reprogramming, errors and UART through TT ports |

## Run simulation

Install Icarus Verilog and Make, then run from the repository root:

```sh
make test
```

Both the FPGA demo and Tiny Tapeout interface tests should report PASS. Use
`make test-fpga` or `make test-tt` to run one target. `make synth` with Yosys
performs a generic structural synthesis check, not an ASIC area/timing check.
The GitHub Actions workflow runs the tests when enabled. **CI is currently
paused** in this repository's Actions settings; local `make test` still works.

To compile with Quartus on your PATH:

```sh
make quartus
```

## Instruction set

Each instruction has a 4-bit opcode and a 12-bit operand.

| Encoding | Operation | Duration |
| --- | --- | --- |
| `0x10xx` | SET eight output values | 1 clock |
| `0x2nnn` | WAIT `nnn` additional clocks | 1 + `nnn` clocks |
| `0x30xx` | DIR: select which outputs are driven | 1 clock |
| `0x40aa` | JMP to the low five bits of `aa` | 1 clock |

Program writes are accepted with `run=0` and reset released. Taking `run` low
restarts execution state, releases the core outputs, and clears faults. Load
every reachable instruction before running. Reset invalidates every word;
the memory data bits themselves are not reset. Invalid opcodes or execution of
unwritten words latch `fault` and release output enables.

The FPGA UART adapter builds a program with SET and WAIT 432 instructions,
producing 434-clock bit intervals at 50 MHz (about 115207 baud). Each byte has
an idle-high setup, start bit, eight data bits least-significant first, and stop
bit. The core then loops idle-high until the adapter ends the execution window.

## Status and next steps

The core currently supports output timing only. The DE1 adapter loads a UART
program per key-down; the Tiny Tapeout wrapper supports external program loading and replacement.
Input sampling, conditional branching, shifting, and FIFOs are future work.

Both interface simulations and generic synthesis pass. Full Quartus compilation, timing closure, and
physical board testing have not yet been performed. Inspect timing reports
after compilation, especially reset recovery/removal. The output timing
exceptions are specific to this asynchronous UART/LED demo.

This is not a verified ASIC submission yet. To pursue the
[Jane Street competition](https://blog.janestreet.com/protocol-emulator-asic-competition/),
verify memory implementation, area, and timing using the competition's CMOS5L
flow. The Tiny Tapeout wrapper and `6x4` metadata are ready for that next step;
the complete physical-design toolchain is not bundled here.

License: Apache-2.0; see [LICENSE](LICENSE).
