# Experimental low-speed USB protocol emulation

This is a **firmware-driven USB device experiment**, not a USB-to-UART bridge,
USB host controller, fixed USB RTL peripheral, or a tapeout-ready USB block.
It reuses `src/protocol_engine.v`. Enumeration, descriptors, packet PIDs,
endpoint state, CRC selection, transfers and HID behavior are instruction sequences
emitted by `firmware/usb_ls/build_firmware.cpp`.

The first profile is a low-speed boot-compatible keyboard: KEY0 sends the HID
usage for **A** while held and a release report when released. It does not type
anything automatically. The host determines the character from its keyboard layout.
The C++ image builder is a small label resolver; no Python library is required.

## Boundaries and status

- FPGA experimental profile: 2,048 writable 16-bit words, 256 scratch bytes,
  single context, optional [generic byte-processing ISA](isa-extended.md).
  The current image uses about 1,300 words; the build prints the exact count.
- Default ASIC and existing UART/SPI/I²C FPGA profile: still 64 words,
  extensions disabled, unchanged host interface and legacy instruction timing.
  USB firmware does **not** fit or run in that default profile.
- Simulation covers enumeration, multi-packet descriptors, CRC/bit stuffing,
  address/configuration changes, retries, keyboard reports, HID idle/protocol/
  report requests, reset and malformed-packet recovery.
- No physical USB enumeration, Quartus timing closure, USB certification,
  foundry mapping or 6x4-tile fit has been demonstrated for this profile.
  Program storage is asynchronous-read RTL, **not an integrated SRAM**. Do not
  infer an area improvement from the larger memory declaration.

This is a deliberately limited device implementation: endpoint 0 control and
endpoint 1 interrupt-IN, eight-byte packets, no strings, no other endpoint types,
no remote wakeup or complete suspend handling, and no endpoint-halt feature
management. Request validation is not exhaustive. ACKs are associated with the
last outstanding response until another packet/reset, without a strict ACK
timeout. Do not treat this as a production/compliant USB stack. A USB compliance
test suite and real-host testing remain necessary.

## Build and simulate

From the repository root, with a C++17 compiler, Make and Icarus Verilog:

```sh
make usb-firmware
make test-extended
make test-usb
make test-usb-board
make test
```

The generator writes `build/usb_ls.hex` and the address/label listing
`build/usb_ls.lst`. These are reproducible build artifacts, not checked-in
firmware binaries. Generate them **before opening/compiling the USB Quartus
project**, including on Windows (e.g. from a Make/C++ environment).

`test-usb` drives independent host packets through the core's public ports and
decodes the resulting line states; it does not assert private firmware registers.
It repeats at 658, 667 and 676 ns host bit periods, with minimum two-bit
inter-packet gaps plus a 17 ns phase offset. It checks response starts against
an internal 1,320–4,200 ns budget. `test-usb-board` runs the same transactions
through the actual FPGA ROM loader and GPIO/PHY adapter, also checking the
disabled-by-default attach gate and VBUS loss. This is an ideal digital PHY
model, not an analog cable/PHY simulation.

For packet traces: `vvp build/tb_usb_ls +TRACE`.

## Open in Quartus Prime

1. Generate the image above.
2. Open **`quartus/de1_soc_usb.qpf`**, top entity **`de1_usb_top`**,
   Cyclone V **5CSEMA5F31C6**. The original `de1_soc_demo.qpf` is untouched.
3. Compile. Output: `quartus/output_files/de1_soc_usb.sof`.
   Command-line equivalent: `make quartus-usb`.
4. Program over the DE1's normal USB-Blaster/JTAG connection. This programming
   USB connector is **not** the emulated USB device port.
5. Raise SW9, then lower it to load the image. In the default build LEDR0
   shows loading completed, but the USB pull-up and transmit enable remain off.

The board must be separately powered. The descriptor advertises self-powered,
zero bus-power draw. If the PHY adapter takes VBUS power, revise its descriptor
and power design accordingly; do not falsely advertise zero bus power.

## Before attachment to a real host

**Do not connect D+ or D− directly to DE1 GPIO. Do not connect USB 5 V VBUS to
GPIO. The Uno R3 tester is not a USB host/PHY for this experiment.**

Use a reviewed low-speed USB transceiver adapter with 3.3 V digital I/O, appropriate
termination, connector/ESD protection, decoupling, common ground and a conditioned
3.3 V VBUS-present signal. The logical adapter mapping below matches a
**TUSB1106-style differential digital interface**, not ULPI. Check the specific
package/board schematic and [TI datasheet](https://www.ti.com/lit/gpn/TUSB1106).
It is not a complete construction schematic or a validation of a particular module.

| DE1 signal (logical GPIO index, not header position) | External PHY signal | Direction |
| --- | --- | --- |
| GPIO_0[0] | VP, sensed D+ | PHY → FPGA |
| GPIO_0[1] | VM, sensed D− | PHY → FPGA |
| GPIO_0[2] | VPO, driven D+ value | FPGA → PHY |
| GPIO_0[3] | VMO, driven D− value | FPGA → PHY |
| GPIO_0[4] | OE_n, active-low transmit enable | FPGA → PHY |
| GPIO_0[5] | SOFTCON, low-speed pull-up control | FPGA → PHY |
| GPIO_0[6] | Externally conditioned VBUS-present, 3.3 V maximum | Adapter → FPGA |
| GPIO_0[7] | SPEED = 0 (low speed) | FPGA → PHY |
| GPIO_0[8] | SUSPND = 0 (normal operation) | FPGA → PHY |

The PHY's controlled pull-up belongs on **D−** for low speed. Supply and pull-up
connections must follow the selected PHY design; GPIO5 is only its digital
enable, not a USB pull-up supply. Provide external safe biasing so OE_n stays
inactive and SOFTCON stays low while the FPGA is unconfigured/reset/powered off.
Prevent back-powering from either supply. Do not use a bidirectional I²C level
shifter as a substitute USB PHY.

The default firmware uses **FFFF:FFFF solely as simulation placeholders**, not
identifiers to ship or attach with. After obtaining legitimately usable IDs:

```sh
# Replace these shell variables with your legitimately usable numeric IDs.
make usb-firmware USB_IDS="$USB_VID $USB_PID"
```

Then change `USB_ATTACH_ALLOWED` to `1` in `quartus/de1_soc_usb.qsf` and recompile
with that image. `make quartus-usb USB_IDS="$USB_VID $USB_PID"` preserves the ID
arguments while rebuilding. Running `make usb-firmware` without IDs later restores
the simulation placeholders; rebuild intentionally and verify the listing/image.
The gate is a deliberate opt-in, **not automatic validation of VID ownership**.

With approved hardware/IDs and the rebuilt image, SW8 requests attachment only
when VBUS-present is high. After loading and an initialization delay, the adapter
enables the pull-up. SW8 low, VBUS loss, SW9 reset or a core fault detaches and
disables transmission. Dropping attachment restarts execution state on re-enable.
Use a disposable text editor for the KEY0 test; keyboard input goes to the host's
focused application. Button bounce is not filtered by this experimental wrapper.

USB-project indicators differ from the original demo:

| Indicator | Meaning |
| --- | --- |
| LEDR0 / LEDR1 | Boot image loaded / execution fault |
| LEDR2 / LEDR3 / LEDR4 | Running / pull-up attached / transmitting |
| LEDR5 / LEDR6 | Configured (value 1) / configuration publication toggle |
| LEDR9 | Execution heartbeat; not proof of USB communication |
| HEX5 / HEX0 | U / configuration value 0 or 1 |

## Timing and next ASIC step

The 50 MHz core emits one bit every 33 clocks (660 ns, about 1.515 Mbit/s).
Receive firmware uses an edge-aligned periodic sampler and synchronizes external
pins; there is still only one internal clock. A sampler tick is not a new clock
domain. The firmware checks/decodes each sampled bit with generic instructions.

USB low-speed signaling and turnaround requirements come from the
[USB 2.0 specification](https://www.usb.org/document-library/usb-20-specification),
especially sections 7.1.11 and 7.1.18.1. Detachable-cable devices have a 6.5-bit
maximum response turnaround, measured from the host's EOP SE0→J edge to the
device's SOP J→K edge. The internal test budget leaves some room for I/O paths,
but does not prove the combined PHY, cable, board and FPGA timing. The SDC's
20 ns GPIO budget is provisional. Review actual timing reports and PHY delays.
HID requests/descriptors follow the relevant subset of
[HID 1.11](https://www.usb.org/document-library/device-class-definition-hid-111).

The two minimum-gap bugs found in simulation were firmware work performed too
late: SETUP parsing after its ACK, and re-arming reception after ACK processing.
SETUP is now parsed before ACK, ACK dispatch has a short path, and reception
returns at the EOP J edge. Keep minimum-gap tests when changing instruction
timing, firmware layout or sampler behavior.

Before ASIC USB support: measure the extension's mapped area, choose a CMOS5L
memory implementation, define synchronous-fetch timing if SRAM is used, update
the external loader/addressing, close timing with the chosen PHY, and run USB
compliance/host interoperability tests. Do not enable this FPGA memory profile
in `info.yaml` and assume it fits. CI remains paused.

## Recorded local verification (2026-09-18)

Passed: `make test`, `make test-usb`, `make test-usb-board`, template Cocotb RTL
test, template metadata/paused-workflow check, and Yosys generic synthesis/check
of both profiles. Maximum observed digital response start across the three USB
host rates was 3.926 µs. These are finite directed regressions, not exhaustive
verification or hardware measurements.

Generic `synth -noabc` of the extended core reports 108,838 primitive cells,
including 34,816 non-reset enabled data flops (32,768 program bits plus 2,048
scratch bits), 2,433 resettable enabled flops and 40,646 muxes. The default core
reports 3,910 cells and retains 1,024 non-reset program data flops; the complete
default Tiny Tapeout hierarchy reports 4,183 cells. These counts are not LUT/ALM
utilization or IHP cell area. They make the memory cost explicit and reinforce
why the larger USB profile must stay out of the ASIC submission for now.

Reproduce the extended structural check with Yosys (or `yowasp-yosys`):

```sh
yosys -p 'read_verilog src/protocol_engine.v; chparam -set PROGRAM_ADDR_WIDTH 11 -set EXTENDED_ISA 1 protocol_engine; synth -top protocol_engine -noabc; check -assert; stat'
```
