# Quartus Prime: protocol engine on DE1-SoC H1

## Open and program

Use Quartus Prime Lite or Standard with Cyclone V support on Windows/Linux.
Target device: **5CSEMA5F31C6**. Native Quartus is not available on this Mac.

1. Keep `src/`, `rtl/`, `firmware/` and `quartus/` together.
2. Open **quartus/de1_soc_demo.qpf**. The active top is **de1_protocol_top**.
   The project filename is retained for compatibility; it no longer boots CHUD.
3. Select **Processing → Start Compilation** and review errors/timing reports.
4. On H/H1 set **SW17.1=1, SW17.2=0** for the FPGA JTAG path. Connect the
   board's USB-Blaster II port J13, power up, and open **Tools → Programmer**.
5. Choose USB-Blaster/JTAG, add **quartus/output_files/de1_soc_demo.sof**,
   enable Program/Configure for the FPGA, then Start.
6. Raise SW9, set SW1:0, then lower SW9. The firmware is loaded automatically.

| SW1 | SW0 | Mode | Wiring / behavior |
| --- | --- | --- | --- |
| 0 | 0 | UART TX | GPIO_0[0] → receiver RX; repeats 0x55 (`U`), 115200 8N1 |
| 0 | 1 | UART RX | Sender TX → GPIO_0[0]; receives one byte, checks stop bit |
| 1 | 0 | SPI mode 0 | GPIO_0[0]=SCK, [1]=MOSI, [2]=MISO, [3]=active-low CS; 100 kHz |
| 1 | 1 | I2C write | GPIO_0[0]=SDA, [1]=SCL; address 0x50, payload 0xA5, <=100 kHz |

Mode switches are latched at boot. Change them while SW9 is high; reset again
to switch protocols or repeat a one-shot RX/SPI/I2C transaction. KEY buttons are
unused. GPIO_0[7:0] connect to the engine; unused outputs stay released, and
GPIO_0[35:8] are always tri-stated.

Use **3.3 V-compatible** logic, common ground, and no RS-232/5 V signals.
I2C needs external pull-ups on both lines to the compatible board supply.
Check wiring before switching modes: the same header positions change roles.
The USB-Blaster is not a UART upload or protocol-data connection.

## Status without a receiver

| Indicator | Meaning |
| --- | --- |
| LEDR0 | Engine is running without a fault (including firmware idle loops) |
| LEDR1 | Fault; reset to recover |
| LEDR2 | Toggles once per captured result; one capture in RX/SPI/I2C examples |
| LEDR3 | WAIT_PIN condition not yet met |
| LEDR5:4 | Latched SW1:0 mode |
| LEDR9 | Heartbeat, toggles every ~0.67 s while running without fault |
| HEX5 | Mode 0, 1, 2 or 3 |
| HEX1:0 | Last captured byte in hexadecimal |
| HEX4:2, LEDR8:6 | Blank/off |

Heartbeat indicates clocked execution, not successful protocol communication.
UART RX normally waits with LEDR3 on until a sender supplies a start bit.
A disconnected I2C target NACKs if pull-ups are present; LEDR1 then turns on.
A stuck-low bus waits indefinitely until SW9 resets it.

For a no-external-device data test, jumper **GPIO_0[1] to GPIO_0[2]** for SPI
MOSI→MISO loopback. Reset into mode 10. Expect HEX1:0=`A5`, LEDR2 on and
LEDR1 off. The pin indices are signal indices, not physical header positions.

## Change firmware

Edit the checked-in `firmware/*.hex` programs, then recompile and reprogram.
The FPGA-only boot adapter embeds these as ROMs and writes the selected program
through the normal core programming port after reset. It loads the last word
before asserting RUN. The ASIC does not contain these boot ROMs.

See [firmware configuration](../firmware/README.md). The boot adapter's ROM
lengths must be updated if a program gains/loses instructions. All supplied
firmware assumes a 50 MHz clock. The loader waits four clocks for synchronized
mode inputs and loads a word per clock; it is not an asynchronous UART receiver.

SOF programming is volatile; reload after power loss. This project does not
configure flash boot or the ARM HPS.

## H1 pin/reference checks

All 103 top-level bits retain explicit locations and 3.3-V LVTTL standards:
CLOCK_50, four KEY inputs, ten switches, ten LEDs, six seven-segment displays
and 36 GPIO signals. Unused device pins are reserved as tri-stated inputs.

| Signal | FPGA package pin |
| --- | --- |
| CLOCK_50 | AF14 |
| SW[9] | AE12 |
| GPIO_0[0] | AC18 |

Package pins are not connector pin numbers. The pin mapping was compared with
[Terasic Rev. H System CD v6.0.0](https://download.terasic.com/downloads/cd-rom/de1-soc/DE1-SoC_v.6.0.0_HWrevH_SystemCD.zip),
`Demonstrations/FPGA/DE1_SOC_golden_top/DE1_SOC_golden_top.qsf`; all 103
locations/standards match. Terasic names the package Rev. H, while this board
is marked H1. This is reference verification, not a physical board test.
The included manual (January 9, 2022), section 3.2, specifies the JTAG switch
settings above.

## Timing and verification limits

CLOCK_50 is constrained to 20 ns with derived uncertainty. SW9 feeds the reset
synchronizer; mode switches and GPIO inputs feed two-stage synchronizers.
Only asynchronous input paths to first stages are false-pathed; inter-stage
and internal reset recovery/removal paths remain timed.

LED/display outputs are false-pathed. Register-to-GPIO outputs instead have a
20 ns maximum path budget. This is a prototype routing constraint, **not** an
external device/cable setup-hold model. Firmware provides microsecond-scale
timing at these initial SPI/I2C rates; inspect actual board loads, clock/data
skew and peer specifications before increasing speed.

No Quartus compilation/timing closure or board test has been performed here.
Icarus board-wrapper simulations and generic synthesis are separate checks.

## Commands and troubleshooting

```sh
make quartus
make test-fpga
```

The equivalent Quartus command inside `quartus/` is
`quartus_sh --flow compile de1_soc_demo`. FPGA simulation runs from that
directory so the firmware ROM paths match Quartus.

| Symptom | Check |
| --- | --- |
| Top missing/wrong | Reopen QPF; active entity must be de1_protocol_top |
| Firmware file missing | Keep firmware/ beside quartus/; compile from the project directory |
| No USB-Blaster | J13, cable, power, driver and OS permissions |
| FPGA not found | SW17.1=1, SW17.2=0, JTAG Auto Detect |
| UART terminal blank | Mode 00, GPIO_0[0] to adapter RX, common ground, 115200 8N1 |
| RX waiting forever | Mode 01 needs an external sender and idle-high RX |
| I2C fault | Correct address/device, power, pull-ups; NACK intentionally faults |
| Mode did not change | Raise SW9 before changing SW1:0, then lower it |
| Still showing CHUD | Recompile and program the new SOF, not an older bitstream |

The old key-demo RTL/test remain for regression only; the active QSF excludes them.
