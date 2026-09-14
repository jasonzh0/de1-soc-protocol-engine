# Quartus Prime setup

## Requirements

- Terasic DE1-SoC with Cyclone V `5CSEMA5F31C6`.
- Quartus Prime Lite or Standard with Cyclone V device support.
- A supported Windows or Linux host. Quartus has no native macOS build.
- USB-Blaster driver/access configured for programming.

## Open, compile, program

1. Download this repository to the computer running Quartus.
2. Select **File → Open Project → quartus/de1_soc_demo.qpf**.
3. Confirm the project hierarchy shows `de1_soc_top`.
4. Select **Processing → Start Compilation**. Review errors and timing reports.
5. Connect the board's USB-Blaster port and power on the board.
6. Select **Tools → Programmer → Hardware Setup → USB-Blaster** (the displayed
   name may include II), and select JTAG mode.
7. Add `quartus/output_files/de1_soc_demo.sof`. If you use Auto Detect, assign
   the SOF to the FPGA device rather than adding a duplicate device entry.
8. Check Program/Configure and click Start.
9. Press and release KEY[0] to reload the demonstration program.

Loading a SOF configures volatile FPGA memory; program again after power loss.
The included project does not configure flash boot or the ARM HPS.

## Pin assignments and source

All 51 top-level bits have explicit package locations and 3.3-V LVTTL standards:
one clock, four buttons, ten LEDs, and 36 GPIO signals. Other device pins are
reserved as tri-stated inputs.

Selected assignments:

| Signal | FPGA package pin | Function |
| --- | --- | --- |
| CLOCK_50 | AF14 | 50 MHz oscillator |
| KEY[0] | AA14 | Active-low reset |
| LEDR[0] | V16 | Program loaded |
| LEDR[1] | W16 | Invalid instruction |
| GPIO_0[0] | AC18 | UART TX |

These are FPGA package pins, not GPIO connector pin numbers.

Pin locations and I/O standards were checked against Terasic's official
[DE1-SoC Rev. F/G System CD v5.1.3](https://download.terasic.com/downloads/cd-rom/de1-soc/DE1-SoC_v.5.1.3_HWrevF.revG_SystemCD.zip),
specifically `Demonstrations/FPGA/DE1_SOC_golden_top/DE1_SOC_golden_top.qsf`.
See [Terasic's download index](https://download.terasic.com/downloads/cd-rom/de1-soc/)
for other board revisions. The checked-in pin map is verified for F/G; compare
the signals used by this project with your revision's manual before programming
another revision.

## Timing constraints

- CLOCK_50 has a 20 ns period.
- Clock uncertainty is derived by Quartus.
- KEY[0] is asynchronous to the two-register reset synchronizer. Only its path
  to those synchronizer registers is excluded from timing; internal reset paths
  remain subject to recovery/removal checks.
- UART TX and LEDs have no externally related sampling clock. Their external
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
| Source file missing | Keep `rtl` and `quartus` in their original relative locations |
| No USB-Blaster detected | Check programming port, cable, power, driver, and OS permissions |
| Terminal is blank | Use an external 3.3 V USB-UART adapter on GPIO_0[0], common ground, 115200 8N1; press reset |
| Board has another revision | Compare its official pin table with `de1_soc_pins.qsf` |

## Command-line build

In a Quartus command shell, from the `quartus` directory:

```sh
quartus_sh --flow compile de1_soc_demo
```

From the repository root with Make installed, the equivalent command is
`make quartus`. Simulation uses `make test` and requires Icarus Verilog, not
Quartus. Simulation and hardware compilation are separate checks.
