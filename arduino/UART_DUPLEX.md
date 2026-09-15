# UART duplex bench test: DE1-SoC H1 + Arduino Uno R3

This tests both directions concurrently: FPGA sends `0x55` continuously while
the Uno sends `0x3C` every 250 ms. It is not an echo or keyboard-to-UART bridge.

## 1. Prepare the software

Use the current repository on both programming computers. If your checkout is
clean, update it with `git pull --ff-only`. Preserve any local edits first.

In Arduino IDE:

1. Install **AltSoftSerial by Paul Stoffregen**, version 1.4.0, using Library Manager.
2. Select **Arduino Uno** and the Uno's USB port (tested AVR Boards core: 1.8.6).
3. Open [uno_protocol_tester.ino](uno_protocol_tester/uno_protocol_tester.ino)
   and upload it. Leave D0/D1 unconnected; USB uses that hardware UART.

In Quartus Prime:

1. Open `quartus/de1_soc_demo.qpf`; verify the top entity is `de1_protocol_top`.
2. Run **Processing → Start Compilation**. Do not reuse an old CHUD bitstream.
3. After wiring and powering the boards as below, use **Tools → Programmer**
   to program the newly generated `quartus/output_files/de1_soc_demo.sof`.
   See [the H1 Quartus guide](../docs/quartus.md#open-and-program) for JTAG setup.
   The SOF must be reloaded after FPGA power loss.

## 2. Wire with both boards powered off

**Do not connect the Uno's 5 V TX directly to the FPGA's 3.3 V GPIO.** Use a
UART/push-pull-compatible level translator, configured for the two directions
below. Follow its datasheet for supplies, enable/direction pins and power order.
Do not join the 5 V and 3.3 V rails. If you do not have suitable translation,
stop before connecting the signal wires.

| Source | Through translator | Destination |
| --- | --- | --- |
| FPGA `GPIO_0[0]` TX | 3.3 V → 5 V | Uno **D8** RX |
| Uno **D9** TX | 5 V → 3.3 V | FPGA `GPIO_0[1]` RX |
| FPGA GND | Common ground, including translator GND | Uno GND |

Connect only UART wiring, not the SPI/I2C groups. `GPIO_0[n]` means the Verilog
signal index, **not the physical header pin number**. Identify these signals
using the board pinout; do not count connector positions from these indices.
Do not connect TX to TX or short the two UART signals together.

The fixed Uno D8/D9 assignments and simultaneous RX/TX support are documented
by [AltSoftSerial](https://www.pjrc.com/teensy/td_libs_AltSoftSerial.html).
See also the [Uno R3 pinout](https://docs.arduino.cc/resources/pinouts/A000066-full-pinout.pdf).

## 3. Start in this order

1. Set FPGA **SW9=1** (reset held). Set **SW2=1, SW1=0, SW0=0**.
   SW8:3 and the KEY buttons are unused by this demo.
2. Power up and program the FPGA with the new SOF, keeping SW9=1.
3. Open the Uno's **Serial Monitor at 115200 baud**. Opening it may reset the
   Uno; wait for the tester's startup menu. Select **No line ending** for clarity
   (the sketch also ignores CR/LF).
4. Send lowercase **`u`**. Wait for the message beginning
   `UART: D8=RX D9=TX, 31250.`
5. Set **SW9=0** to run the FPGA. The leftmost display, **HEX5**, must show `4`.
   This confirms the latched Uno UART profile, binary `100`.
6. Wait about two seconds, then send **`c`** once to clear startup counters.
7. Watch both the USB status and FPGA indicators for at least 30 seconds.
   Do not keep clearing counters during this observation period.

The FPGA↔Uno link is **31250 baud, 8 data bits, no parity, 1 stop bit (8N1)**.
The Uno↔computer USB monitor remains **115200 baud**. These are separate ports;
do not change the monitor to 31250 or select FPGA mode `000` (115200 link).

## 4. Confirm both directions

Example USB status (counts vary):

```text
U rx=3120 bad=0 tx=4 e=0 55
```

| Check | Expected observation | What it demonstrates |
| --- | --- | --- |
| USB `rx` and last field | `rx` keeps increasing; last field is `55` | Uno receives FPGA TX |
| USB `bad` / `e` | Both stay `0` after the one startup clear | No detected wrong bytes / timing-error indications |
| USB `tx` | Increases by about four per second | Uno queues outgoing test bytes |
| FPGA HEX1:0 | Rightmost two digits show `3C` | FPGA received the Uno's byte |
| FPGA LEDR2 | Toggles about every 250 ms | FPGA continues capturing new bytes |
| FPGA LEDR0 / LEDR1 | Running LED on / fault LED off | Engine has not faulted |

Pass this smoke test only if the receive count increases while the FPGA keeps
capturing `3C`, with no new errors. A rising `tx` count alone does not prove FPGA
reception. LEDR3 may remain mostly on while RX waits; TX continues independently.
LEDR9 is only a heartbeat, not proof of communication.

The display shows hex bytes, not the text `3C` sent as two ASCII characters.
The USB menu does not forward arbitrary typed characters to the FPGA.

## 5. If something is wrong

| Symptom | Check / recovery |
| --- | --- |
| No menu or garbled USB text | Uno port, uploaded sketch, Serial Monitor 115200 |
| HEX5 shows `0`, or still shows CHUD | Set SW2:0=100 and reset; verify you compiled/programmed the current SOF |
| `rx` stays zero | FPGA running, GPIO_0[0] → D8 path, translator enable/direction, common ground |
| `rx` rises but `tx` remains zero | Update/re-upload the Uno sketch: an older version wrongly gated TX on AltSoftSerial's inherited zero-return `availableForWrite()`; no FPGA rebuild is needed for this fix |
| `tx` rises but HEX1:0 stays `00` | D9 → GPIO_0[1] path and translator; UART mode must be 100 |
| `bad` or `e` keeps rising | Matching baud, wiring/noise, translation, no Timer1-conflicting libraries; do not dismiss recurring errors as startup |
| LEDR1 turns on | A bad UART stop bit faults both contexts; correct the cause, then SW9=1 followed by SW9=0 |
| Test stops after reopening Serial Monitor | Uno may have reset to idle; hold SW9=1, send `u`, wait for confirmation, then lower SW9 |

To stop, set SW9=1, then send `q` to release the Uno test pins. Power down before
rewiring. After a restart, repeat the startup-clear and observation procedure.

## Limits

The sketch was compiled for Uno R3, and matching RTL simulations passed. This
procedure has not yet been validated on physical boards here. Constant-byte
traffic and a latest-byte FPGA register cannot establish lossless delivery;
zero error counters do not prove no bytes were dropped. This is a functional
duplex smoke test, not a throughput or timing-closure certification.
