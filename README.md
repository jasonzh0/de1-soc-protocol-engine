# DE1-SoC Protocol Engine

A small programmable Verilog pin engine with a ready-to-open Quartus Prime
project for the Terasic DE1-SoC. The included demo repeatedly sends ASCII `U`
(`0x55`) over GPIO UART at approximately 115200 baud, 8N1.

## Open in Quartus Prime

1. Install **Quartus Prime Lite or Standard** with **Cyclone V** device support
   on a supported Windows or Linux computer.
2. Clone this repository or download and extract its ZIP.
3. In Quartus, select **File → Open Project** and open
   **[`quartus/de1_soc_demo.qpf`](quartus/de1_soc_demo.qpf)**.
4. Select **Processing → Start Compilation**.
5. Open **Tools → Programmer**, select the board's USB-Blaster in Hardware
   Setup, and use JTAG mode. Add `quartus/output_files/de1_soc_demo.sof`, select
   Program/Configure for the FPGA, and click Start.
6. Press and release **KEY[0]**. LEDR[0] indicates the program is loaded;
   LEDR[1] indicates an invalid instruction.

The project already selects `5CSEMA5F31C6`, the two RTL files, the top-level
module, the 50 MHz clock constraint, and all 51 top-level pin assignments.
No New Project Wizard or manual source-file setup is needed.

The pin map is verified against **Terasic's Rev. F/G System CD**. Check the
mapping against your manual if you have another revision. See
[the Quartus guide](docs/quartus.md) for wiring, sources, and troubleshooting.

## See the UART output

Connect **GPIO_0[0]** to the RX input of a **3.3 V USB-UART adapter**, and connect
grounds. Find the physical header position in your board's manual; the signal
index is not a header pin number. Open a terminal at **115200, 8N1, no flow
control**. Expect repeated `UUUU...`.

The onboard USB-Blaster is the programming connection. The serial demo uses
the separate adapter. Do not connect 5 V or RS-232 signal levels to FPGA GPIO.

## What is here?

| Path | Purpose |
| --- | --- |
| `rtl/protocol_engine.v` | 32-word writable instruction memory and eight output channels |
| `rtl/de1_soc_top.v` | Board wrapper, reset synchronizer, fixed UART demo loader |
| `quartus/de1_soc_demo.qpf` | Open this file in Quartus |
| `quartus/de1_soc_demo.qsf` | FPGA device, source files, and build settings |
| `quartus/de1_soc_pins.qsf` | Board pin locations and 3.3 V I/O standards |
| `quartus/de1_soc_demo.sdc` | Clock and demo-specific timing exceptions |
| `test/tb_uart.v` | UART receiver simulation checking three frames |

## Run simulation

Install Icarus Verilog and Make, then run from the repository root:

```sh
make test
```

Expected result: `PASS: decoded three UART frames of 0x55`.
GitHub Actions runs the same test on pushes and pull requests.

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
every reachable instruction before running; instruction memory is not reset.
Invalid opcodes latch `fault` and release output enables.

The demo alternates SET and WAIT 432 instructions, producing 434-clock bit
intervals at 50 MHz (about 115207 baud). JMP adds one clock to the stop bit;
initial output-enable startup also extends the first start bit by one clock.

## Status and next steps

This is a standalone FPGA starter with output timing only. The board loads a
fixed demonstration program. Input sampling, conditional branching, shifting,
FIFOs, and an external program loader are future work.

The UART simulation passes. Full Quartus compilation, timing closure, and
physical board testing have not yet been performed. Inspect timing reports
after compilation, especially reset recovery/removal. The output timing
exceptions are specific to this asynchronous UART/LED demo.

This is not an ASIC submission yet. To pursue the
[Jane Street competition](https://blog.janestreet.com/protocol-emulator-asic-competition/),
adapt the portable core to the required Tiny Tapeout interface and verify
memory implementation, area, and timing using the competition's CMOS5L flow.

License: Apache-2.0; see [LICENSE](LICENSE).
