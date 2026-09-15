# Quartus Prime setup

## Requirements

- Target board: Terasic DE1-SoC revision H1, Cyclone V `5CSEMA5F31C6`.
- Quartus Prime Lite or Standard with Cyclone V device support.
- A supported Windows or Linux host. Quartus has no native macOS build.
- USB-Blaster driver/access configured for programming.

## Open, compile, program

1. Download this repository to the computer running Quartus.
2. Select **File → Open Project → quartus/de1_soc_demo.qpf**.
3. Confirm the project hierarchy shows `de1_soc_top`.
4. Select **Processing → Start Compilation**. Review errors and timing reports.
5. For Rev. H/H1, select the FPGA JTAG path with **SW17.1 = 1, SW17.2 = 0**.
   Connect the board's USB-Blaster II port (J13) and power on the board.
6. Select **Tools → Programmer → Hardware Setup → USB-Blaster** (the displayed
   name may include II), and select JTAG mode.
7. Add `quartus/output_files/de1_soc_demo.sof`. If you use Auto Detect, assign
   the SOF to the FPGA device rather than adding a duplicate device entry.
8. Check Program/Configure and click Start.
9. Set SW9 to **1**, then **0** to reset and enable the demo. Press KEY3 for C,
   KEY2 for H, KEY1 for U, or KEY0 for D. Each debounced key-down sends one byte;
   holding and releasing send nothing extra. UART is 115200 baud, 8N1, no flow
   control, with no appended newline. HEX3–HEX0 display `C H U d` continuously;
   HEX5–HEX4 are blank.

With no external receiver, check **LEDR[0] on, LEDR[1] off**. LEDR[2] toggles
once per completed byte, so it changes when a key is pressed and stays steady
while the key is held. LEDR[9:6] show the last accepted key (KEY3..KEY0).
LEDR[3] indicates busy; a frame lasts only about 87 microseconds, so that LED
may be too brief to see. These indicators do not validate the external wiring.

Loading a SOF configures volatile FPGA memory; program again after power loss.
The included project does not configure flash boot or the ARM HPS.

## Pin assignments and source

All 103 top-level bits have explicit package locations and 3.3-V LVTTL standards:
one clock, four buttons, ten switches, ten LEDs, 42 display segments, and 36 GPIO signals. Other device pins are
reserved as tri-stated inputs.

Selected assignments:

| Signal | FPGA package pin | Function |
| --- | --- | --- |
| CLOCK_50 | AF14 | 50 MHz oscillator |
| SW[9] | AE12 | Reset (1) / run (0) |
| KEY[0] | AA14 | Active-low D key |
| LEDR[0] | V16 | Demo enabled |
| LEDR[1] | W16 | Invalid instruction |
| LEDR[2] | V17 | Toggles per transmitted byte |
| GPIO_0[0] | AC18 | UART TX |

These are FPGA package pins, not GPIO connector pin numbers.

All 103 pin locations and all 103 I/O standards were compared with Terasic's
official [DE1-SoC Rev. H System CD v6.0.0](https://download.terasic.com/downloads/cd-rom/de1-soc/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip),
specifically `Demonstrations/FPGA/DE1_SOC_golden_top/DE1_SOC_golden_top.qsf`.
There are no differences for the signals used by this project. The device
selection is also unchanged. The original clock/key/LED/GPIO assignments also match the previously checked
[Rev. F/G System CD v5.1.3](https://download.terasic.com/downloads/cd-rom/de1-soc/DE1-SoC_v.5.1.3_HWrevF.revG_SystemCD.zip).

The user's board is marked H1; Terasic labels this published support package
Rev. H. This records verification against that reference, not a physical test
of an H1 board. See [Terasic's download index](https://download.terasic.com/downloads/cd-rom/de1-soc/)
for the official packages.

The Rev. H package's `UserManual/DE1-SoC_User_manual.pdf` (January 9, 2022),
section 3.2, page 17, specifies **SW17.1 = 1, SW17.2 = 0** for FPGA JTAG
programming. This selects the Cyclone V path; it is not the SW10 boot-mode switch.

## Timing constraints

- CLOCK_50 has a 20 ns period.
- Clock uncertainty is derived by Quartus.
- SW[9] is asynchronous to the two-register reset synchronizer. Only its path
  to those synchronizer registers is excluded from timing; internal reset paths
  remain subject to recovery/removal checks.
- KEY inputs are asynchronous and feed two-register synchronizers before the
  10 ms debounce counters. Only input paths to the first register stage are
  excluded from timing; the inter-stage paths remain timed.
- UART TX, LEDs and displays have no externally related sampling clock. Their external
  output paths are false-pathed; internal engine paths remain timed at 50 MHz.
- Revisit GPIO timing exceptions when adding SPI or any other clocked interface.

The constraints express the demo's intent; a passing hardware timing result
still requires a full Quartus compilation. Do not interpret simulation success
as timing closure or board verification.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Device not installed | Install Cyclone V device support for your Quartus version |
| Top-level entity missing | Open the QPF; the entity is `de1_soc_top` |
| Source file missing | Keep `src`, `rtl`, and `quartus` in their original relative locations |
| No USB-Blaster detected | Check J13, cable, power, driver, and OS permissions |
| USB-Blaster detected but FPGA missing | On Rev. H/H1, check SW17.1 = 1 and SW17.2 = 0, then Auto Detect |
| Terminal is blank | Use 3.3 V USB-UART RX on GPIO_0[0], common ground, 115200 8N1; reset with SW9=1 then 0; press a key |
| Board has another revision | Compare its official pin table with `de1_soc_pins.qsf` |

## Command-line build

In a Quartus command shell, from the `quartus` directory:

```sh
quartus_sh --flow compile de1_soc_demo
```

From the repository root with Make installed, the equivalent command is
`make quartus`. Simulation uses `make test` and requires Icarus Verilog, not
Quartus. Simulation and hardware compilation are separate checks.
