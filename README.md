# Programmable Protocol Engine

One programmable Verilog engine for FPGA prototyping and a Tiny Tapeout ASIC.
UART, SPI and I2C behavior comes from replaceable instructions—not three fixed
protocol peripherals. The Python library and UART program uploader are deferred.

The default profile has **64×16-bit writable instructions**, eight I/O pins, synchronized
inputs, byte shifts, counted loops, pin waits/branches, one-level calls per context,
and a captured-byte result register. A generic second instruction context enables
full-duplex UART without fixed UART hardware. See [ISA](docs/isa.md).

**Experimental USB protocol emulation:** a separate FPGA profile runs low-speed
HID keyboard firmware on this same core, with optional generic byte-processing
instructions and larger memory. See the [USB guide](docs/usb.md) for simulation,
`quartus/de1_soc_usb.qpf`, external-PHY requirements and current limitations.
Physical attachment is disabled by default; this is not yet ASIC USB support.

**SRAM-backed ASIC candidate:** the shared core now supports synchronous program
memory and an explicit IHP 4 KiB SRAM. The USB FPGA project uses the clocked RAM
backend; the default submission remains the tested 64-word profile pending
physical integration. See [SRAM redesign, loader contract and area](docs/sram-redesign.md).

## Build profiles

All profiles use the same core; memory and board/pad adapters differ.

| Profile | Program memory | Entry point | Status |
| --- | --- | --- | --- |
| UART/SPI/I2C FPGA and default ASIC | 64×16-bit registers | `quartus/de1_soc_demo.qpf`; `info.yaml` | Existing protocol examples; default submission |
| Experimental USB FPGA | 2048×16-bit synchronous RAM | `quartus/de1_soc_usb.qpf` | Simulated; external PHY required, attachment disabled |
| SRAM ASIC candidate | 2048×16-bit in one IHP 1024×32 SRAM | `make synth-sram` | Model-tested and mapped; physical integration pending |

## Run on DE1-SoC H1

The existing Quartus project now boots the protocol engine, **not the CHUD demo**.

1. Open **quartus/de1_soc_demo.qpf** in Quartus Prime Lite/Standard with Cyclone V
   support. The top-level entity should be **de1_protocol_top**.
2. Compile, then program **quartus/output_files/de1_soc_demo.sof** using
   USB-Blaster II/JTAG. On H/H1, use SW17.1=1 and SW17.2=0 for FPGA JTAG.
3. Raise **SW9** to reset, set **SW2:0** from the table, then lower SW9 to boot.
   Changing mode switches without resetting does not change the running program.

| SW2:0 | Mode | GPIO_0 signals | Default behavior |
| --- | --- | --- | --- |
| 000 | UART full duplex | [0]=TX, [1]=RX | Repeats 0x55 while receiving; nominal 115200 baud, 8N1 |
| 100 | Uno R3 duplex test | [0]=TX, [1]=RX | Same behavior at 31250 baud for the Arduino tester |
| 001 | Standalone UART RX | [0]=RX | Receives one byte at 115200, 8N1 |
| 010 | SPI mode 0 | [0]=SCK, [1]=MOSI, [2]=MISO, [3]=CS_n | Exchanges 0xA5 at 100 kHz, MSB first |
| 011 | I2C write | [0]=SDA, [1]=SCL | Writes 0xA5 to address 0x50; checks ACKs/stretching |
| 111 | I2C read | [0]=SDA, [1]=SCL | Reads one byte from address 0x50, sends NACK then STOP |

SPI/I2C and standalone UART RX are one-shot examples: reset to repeat.
Duplex UART receives repeatedly without reset; its latest-byte register can
be overwritten, so read promptly (no RX FIFO). SW2 is ignored in SPI/standalone RX.
I2C needs external
pull-ups and a responding device; a NACK faults and releases the bus. No peer,
missing pull-ups or a stuck line can prevent success. Use compatible 3.3 V
signals and common ground; no 5 V or RS-232 levels on FPGA GPIO.

**Status:** LEDR0=engine running, LEDR1=fault, LEDR2=capture toggle,
LEDR3=at least one context waiting for a pin, LEDR6:4=latched mode,
LEDR9=heartbeat (~0.67 s per toggle).
HEX5 shows mode 0,1,2,3,4 or 7; HEX1:0 show the last received byte in hexadecimal.
The heartbeat proves clocked execution, not external communication.

For full UART, connect GPIO_0[0] to a 3.3 V USB-UART adapter's RX and its TX to
GPIO_0[1]. The onboard
USB-Blaster programs the FPGA; it is not the protocol UART connection.
For a simple SPI loopback test, jumper GPIO_0[1] to GPIO_0[2] before resetting
into mode 010: the expected captured/displayed byte is A5.

**Using an Arduino Uno R3?** The [test sketch and safe wiring guide](arduino/README.md)
cover all three protocols. The Uno requires **5 V↔3.3 V level translation**.
Its UART test uses mode 100 at 31250 baud, while USB Serial Monitor stays 115200.

See [Quartus setup and wiring](docs/quartus.md) and
[firmware configuration](firmware/README.md). The project name is retained so
existing Quartus users can open the same QPF. The old key demo remains in
`rtl/de1_soc_top.v` and its regression, but is no longer a Quartus source.

## Tiny Tapeout / ASIC

The ASIC uses the **same core**, through the standard
`tt_um_jasonzh0_protocol_engine` interface. It starts with invalid/empty
instruction memory; upload firmware using the synchronous nibble host bus.
The FPGA-only boot ROM is not part of the ASIC submission.

[Host commands](docs/info.md) · [Architecture](docs/architecture.md) ·
[CMOS5L template alignment](docs/template.md)

The repository follows the official CMOS5L template contracts: schema 6,
submission RTL in `src/`, unchanged physical config, **6x4** tiles, and
template-derived GDS/precheck/gate-level/docs workflows. **CI remains paused**:
manual-only triggers and disabled job guards prevent execution.

## Configuration and files

Edit instruction words in `firmware/` to change payload/address/timing.
Recompile Quartus after changing these files; the FPGA boot adapter embeds them.
On the ASIC, upload replacement words through the host interface without
changing hardware. See the firmware guide for exact configuration locations.

| Path | Purpose |
| --- | --- |
| src/protocol_engine.v | Shared programmable execution core |
| src/program_store.v | Interchangeable program-memory backends and initialization |
| src/program_loader.v | Host program staging and run control |
| src/tt_um_jasonzh0_protocol_engine.v | ASIC pad adapter, status/result selection |
| rtl/de1_protocol_top.v | H1 reset, mode, GPIO, LEDs and displays |
| rtl/firmware_bootloader.v | FPGA-only firmware ROM and load sequence |
| rtl/de1_usb_top.v, rtl/usb_firmware_bootloader.v | Experimental USB board adapter and ROM loader |
| firmware/ | UART TX/RX, SPI and I2C images; USB firmware generator |
| arduino/uno_protocol_tester/ | Uno R3 UART, SPI-peripheral and I2C-device test sketch |
| quartus/de1_soc_demo.qpf | Active Quartus project |
| info.yaml, src/config.json | Tiny Tapeout submission metadata/config |

## Verify locally

Install Icarus Verilog, Make and a C++17 compiler. Plain `make` prints help;
it does not download dependencies or start a hardware build.

```sh
make help
make test
```

`make test` runs the active FPGA boot/mode regression, legacy key demo, TT loader,
public-pin UART/SPI/I2C peers, Arduino host regression, extended ISA, and memory
safety/fetch-equivalence tests. It does not include the longer USB or IHP suites:

| Command | Additional coverage |
| --- | --- |
| `make test-sync` | Clocked RAM: extended ISA, UART/SPI/I2C, USB at three host rates |
| `make test-usb` | USB using the legacy asynchronous memory backend |
| `make test-usb-board` | Actual USB FPGA boot/PHY adapter with clocked RAM |
| `make test-ihp-memory` | Pinned IHP SRAM model, all protocols, USB through TT host pins |

`test-ihp-memory` and `synth-sram` explicitly download pinned IHP model/Liberty
files into ignored `build/ihp-sram/`. Generated firmware, executables, waveforms,
and synthesis reports stay under ignored `build/`; template simulation outputs
stay under `test/sim_build/`. Keep checked-in `firmware/*.hex`: these are source
images used by the FPGA and tests, not disposable build products.

With `test/requirements.txt` installed, `make check-template test-template`
checks the template contract and Cocotb harness. Cocotb is for official-flow
verification, not a Python compiler/library dependency for the engine.
`make synth` runs generic Yosys checks; `make quartus` runs Quartus if installed.

Local RTL regressions and generic synthesis are verification steps, **not ASIC
signoff**. Still required: actual Quartus compilation/board tests, CMOS5L mapped
area/6x4 fit, physical design, timing closure, DRC/LVS and gate-level protocol
verification. No tapeout readiness or support for every protocol mode is claimed.
FIFO streaming, I2C repeated-START/arbitration/recovery and faster protocols remain future work.

License: Apache-2.0; see [LICENSE](LICENSE).
