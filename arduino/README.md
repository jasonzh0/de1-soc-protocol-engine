# Arduino Uno R3 protocol tester

Open [uno_protocol_tester.ino](uno_protocol_tester/uno_protocol_tester.ino).
This sketch targets the **Uno R3 / ATmega328P at 16 MHz**, not Mega, R4, or ESP32.
It tests one selected protocol at a time, with the FPGA as SPI/I2C master.

## Electrical safety first

**Uno R3 signals are 5 V; DE1-SoC GPIO is 3.3 V. Do not connect Uno outputs
directly to FPGA inputs.** Use suitable 5 V/3.3 V logic level translation on
the signal paths below, and connect grounds. Use push-pull-compatible translation
for UART/SPI and a bidirectional open-drain I2C translator with pull-ups on both
voltage sides. Never pull the FPGA side up to 5 V or join the 5 V and 3.3 V rails.
See the [official Uno R3 pinout](https://docs.arduino.cc/resources/pinouts/A000066-full-pinout.pdf)
and [datasheet](https://docs.arduino.cc/resources/datasheets/A000066-datasheet.pdf).

Hold FPGA **SW9=1** while selecting modes. Power down before changing wiring;
connect only the row group for the protocol under test, not all groups together.
Do not use a 5 V shield/pull-up on the FPGA side. The sketch disables Wire's
internal pull-ups, but this does not replace the required external level shifter.

## Install and upload

1. In Arduino IDE, select **Arduino Uno**, then your board's port.
2. Install **AltSoftSerial by Paul Stoffregen** (tested version 1.4.0) through
   Library Manager. Wire comes with Arduino AVR Boards (tested core 1.8.6).
3. Upload the sketch. D0/D1 remain reserved for USB; do not connect FPGA to them.
4. Recompile/program the updated Quartus project, including the new firmware ROMs.
5. Open Arduino Serial Monitor at **115200 baud**, send a lowercase menu command
   below, wait for its setup message, then lower FPGA SW9 to run.

| Command | Arduino role | FPGA SW2:0 | Expected FPGA HEX1:0 |
| --- | --- | --- | --- |
| `u` | Simultaneous UART RX/TX, 31250 baud | **100** | `3C` after Arduino sends |
| `s` | SPI mode-0 peripheral, reply `3C` | **010** | `3C` |
| `i` | I2C device at 7-bit address `50` | **011** write / **111** read | `00` on write success / `96` on read |
| `q` | Release test pins | Keep SW9 high | No transaction |
| `c` | Clear counters without restarting the active interface | Leave selected mode running | Clears startup/transient counts |

The Uno has one hardware UART shared with USB. This tester retains USB logging
and uses AltSoftSerial's simultaneous RX/TX on **D8/D9 at 31250 baud**, its
conservative documented 16 MHz AVR rate. Ordinary SoftwareSerial cannot test
simultaneous TX/RX. [AltSoftSerial documentation](https://www.pjrc.com/teensy/td_libs_AltSoftSerial.html)

**The Serial Monitor stays at 115200; only the FPGA data link is 31250.**
FPGA mode 000 still provides normal 115200 duplex UART for a suitable tester;
do not select it with this sketch. AltSoftSerial owns Timer1, so avoid Servo,
TimerOne, or PWM on D9/D10. SPI is tested in a separate mode with Timer1 stopped.

## Wiring (all signal connections through level translation)

GPIO numbers below are Verilog signal indices, not physical connector positions.

| Test | FPGA signal | Uno R3 signal | Direction |
| --- | --- | --- | --- |
| UART | GPIO_0[0], TX | D8, AltSoftSerial RX | FPGA → Uno |
| UART | GPIO_0[1], RX | D9, AltSoftSerial TX | Uno → FPGA |
| SPI | GPIO_0[0], SCK | D13, SCK | FPGA → Uno |
| SPI | GPIO_0[1], MOSI | D11, COPI/MOSI | FPGA → Uno |
| SPI | GPIO_0[2], MISO | D12, CIPO/MISO | Uno → FPGA |
| SPI | GPIO_0[3], CS_n | D10, SS | FPGA → Uno |
| I2C | GPIO_0[0], SDA | A4 / SDA | Bidirectional open drain |
| I2C | GPIO_0[1], SCL | A5 / SCL | Bidirectional (clock stretching) |
| All | GND | GND | Common ground |

For SPI, keep CS_n high during FPGA reset using a pull-up to **3.3 V on the
FPGA side**. Do not use the Uno's built-in LED as an output during this test:
it shares D13/SCK. FPGA drives SPI clock; this sketch deliberately configures
AVR SPI as a peripheral, not Arduino SPI.begin() master mode.

## What to look for

### UART: both directions at once

Send `u`, set SW2:0=100 while SW9=1, then lower SW9. FPGA continuously sends
`55` while Arduino sends `3C` every 250 ms. Status lines resemble:

```text
U rx=3120 bad=0 tx=4 e=0 55
```

Counts are cumulative. `bad` counts non-55 received bytes; `e` counts
AltSoftSerial timing-error indications; the final hex field is the last byte.
After startup/FPGA reset has settled, send `c` to clear any startup garbage
without restarting UART. Require RX to increase and bad/e to stay zero. No received bytes means WAIT,
not PASS. FPGA HEX1:0 should show `3C`, with LEDR2 toggling on each capture.
LEDR3 may be on while RX waits between bytes; TX still runs independently.

This is not an echo test: FPGA TX stays 55 regardless of RX. Arduino's TX count
proves a byte was queued, not that FPGA received it; confirm the FPGA display.
The FPGA has a latest-byte register, not a FIFO. Neither a zero error count nor
this constant-byte pattern proves that no bytes were dropped.

### SPI: transmit and receive in one exchange

Send `s`, reset FPGA into 010. Arduino should report `S rx=1 bad=0 ... last=A5`;
FPGA HEX1:0 should show `3C`. Reset FPGA again for another transaction. `requests`
in an S line is unused. The sketch preloads the reply before the first clock;
logging is outside the interrupt handler. This example is one byte per CS pulse.

### I2C: write then read

Send `i`, reset FPGA into 011. Expect `I rx=1 bad=0 requests=0 last=A5` and
FPGA HEX1:0=00 with LEDR1 off. Keep the I2C wiring and Arduino mode, then reset
FPGA into 111. `requests` should increase; FPGA HEX1:0 should become `96`.
The request counter records callback invocation, not proof of the final FPGA
sample, so check the display too. Hardware/Wire supplies address ACKs and may
stretch SCL while servicing callbacks; the engine waits for actual SCL high.

These are raw one-byte read/write examples, not register-index/repeated-START
transactions. A NACK faults the FPGA and releases outputs; reset to retry.

## Command-line compile / verification limits

```sh
arduino-cli core install arduino:avr@1.8.6
arduino-cli lib install AltSoftSerial@1.4.0
make test-arduino
```

The sketch is compile-checked for Uno R3 with AVR core 1.8.6 and AltSoftSerial
1.4.0; it has not been run on physical hardware here. HDL tests exercise the matching firmware and serial
peers, including full duplex at both baud rates and I2C read/write. They do not
prove Arduino ISR timing, electrical wiring, level-shifter quality or board timing.
