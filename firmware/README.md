# Basic protocol configurations

These `.hex` files are instruction programs, not fixed peripheral RTL or ASIC
power-on ROMs. Load after reset. All assume a **50 MHz** engine clock; pin
numbers index the eight protocol pins.

| Firmware | Default configuration | Result / termination |
| --- | --- | --- |
| `uart_duplex.hex` | TX=0, RX=1, 115200 nominal, 8N1; two contexts, 217 ticks/bit | Continuous TX=55 plus simultaneous RX captures |
| `uart_duplex_31250.hex` | Same pins/directions, 31250 baud; 800 ticks/bit | Uno R3 AltSoftSerial test profile |
| `uart_tx.hex` | TX=0, nominal 115200 baud (actual 115207), 8N1, byte 55 | Repeat until HALT |
| `uart_rx.hex` | RX=0, same baud/format | Capture one byte; bad stop faults |
| `spi_mode0.hex` | SCK=0, MOSI=1, MISO=2, CS_n=3; 100 kHz, MSB first, TX=A5 | Capture reply, deassert CS, idle |
| `i2c_write.hex` | SDA=0, SCL=1; <=100 kHz plus stretch time; address 50, payload A5 | START, address+write, ACK, data, ACK, STOP; capture 00 or fault on NACK |
| `i2c_read.hex` | SDA=0, SCL=1; same clock/address | Address+read, ACK, receive byte, master NACK, STOP, capture byte |

I2C requires external pull-ups. Read and write are single-master, one-byte
transactions: no repeated START/register-address transaction, multi-master
arbitration, bus-clear recovery or autonomous timeout yet. SPI implements mode 0.
Standalone UART RX receives one frame per RUN; duplex UART continuously receives
while transmitting. The result register holds only the latest byte, not a FIFO.
New firmware can add sequences without
changing fabricated logic, within the documented instruction/I/O limits.

## Change the configuration

Comments label decimal program addresses. Preserve addresses unless updating
jump/call targets too. Words and byte values below are hexadecimal.

- UART TX address 2: `5055` → `50xx` to transmit xx.
- Duplex UART address 3: `5055` → `50xx` to configure the repeated TX byte.
  TX context occupies addresses 0–12; RX starts at 32. Addresses 13–31 are
  deliberate fault padding; preserve them when loading the contiguous file.
- SPI address 2: `50A5` → `50xx` to send xx.
- I2C address 8: `50A0` → `0x5000 | (seven_bit_address << 1)`.
  Address 10: `50A5` → `50xx` for payload. Do not shift an already shifted address.
- I2C read address 8: `50A1` → `0x5000 | (seven_bit_address << 1) | 1`.
- UART TX D clocks/bit: WAIT operands at addresses 5/10 = D−2, address 7 = D−3.
  Default D=434. Stop/idle is slightly longer due to byte/counter reload.
- Duplex UART uses 25 MHz context ticks on a 50 MHz clock. D=217 ticks/bit;
  TX WAIT operands are 215/214, not 432/431. RX uses 321 ticks to its first
  data sample, then 214-tick WAIT plus IN/LOOP for 217-tick bit intervals.
  Both contexts must use this timing; enabling a child halves each context's rate.
- Uno profile: the same program uses TX waits 798/797, RX initial wait 1196,
  and RX inter-bit wait 797 for 800-tick bit periods (31250 baud). Only timing
  words differ from the normal duplex file; no core or pin changes are needed.
- SPI H clocks/half-period: WAIT operands at addresses 7/10 = H−4/H−3.
  Default H=250. Only the supplied 100 kHz timing has been tested.
- I2C WAIT operands 249 give conservative roughly 5 us half-periods, with
  instruction/synchronization overhead and optional stretching added.

For other pins, update SET/DIR masks and every pin operand; see [ISA](../docs/isa.md).
SPI samples synchronized MISO near the leading edge after its long low-phase
settling interval, not at the end of the high phase when a peripheral may
already preload its next byte following the last sampling edge.
Input synchronization matters: changing clock/rate constants requires new tests.

## Load and test

Reset, HALT, then send four DATA nibbles MSB-first plus WRITE per instruction.
The address advances automatically. Send RUN. After CAPTURE, command `(6,1)`
presents the byte on uo_out; `(6,0)` returns to status. This is not serialized
UART readback. See [host guide](../docs/info.md) for the complete interface.

```sh
make test-protocols
make test
```

The Verilog testbench loads these exact files through TT ports and supplies
external peers. It checks overlapping UART TX/RX with back-to-back incoming
bytes and baud offsets, exact TX timing, SPI exchange, I2C reads/writes including
final master NACK, clock stretching, open-drain safety, and readback/errors.
No Python library is needed. The separate Cocotb harness exists only for the
official template's RTL/gate-level workflow.

The Quartus project boots these exact files through an FPGA-only ROM adapter.
Set SW9=1, select SW1:0 (00 duplex UART, 01 standalone RX, 10 SPI, 11 I2C),
set SW2 for I2C direction (0 write / 1 read) or duplex UART rate (0 115200 /
1 31250), then lower SW9. SW2 is ignored in standalone RX and SPI.
`uart_tx.hex` remains a standalone test/upload example; the FPGA
default now boots `uart_duplex.hex`. RX moves to pin 1 in duplex mode.
Recompile/reprogram after editing the files. If adding/removing instructions,
update the ROM bounds and last-word addresses in `rtl/firmware_bootloader.v`.
On the ASIC, upload through the TT host instead. UART uploading is still deferred;
the DE1-SoC USB-Blaster is not a serial upload connection.
