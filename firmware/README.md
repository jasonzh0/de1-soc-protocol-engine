# Basic protocol configurations

These `.hex` files are instruction programs, not fixed peripheral RTL or ASIC
power-on ROMs. Load after reset. All assume a **50 MHz** engine clock; pin
numbers index the eight protocol pins.

| Firmware | Default configuration | Result / termination |
| --- | --- | --- |
| `uart_tx.hex` | TX=0, nominal 115200 baud (actual 115207), 8N1, byte 55 | Repeat until HALT |
| `uart_rx.hex` | RX=0, same baud/format | Capture one byte; bad stop faults |
| `spi_mode0.hex` | SCK=0, MOSI=1, MISO=2, CS_n=3; 100 kHz, MSB first, TX=A5 | Capture reply, deassert CS, idle |
| `i2c_write.hex` | SDA=0, SCL=1; <=100 kHz plus stretch time; address 50, payload A5 | START, address+write, ACK, data, ACK, STOP; capture 00 or fault on NACK |

I2C requires external pull-ups. This example is a single-master, one-byte
write: no reads, repeated START, multi-master arbitration, bus-clear recovery,
or autonomous timeout yet. SPI implements mode 0 here. UART RX receives one
frame per RUN, not a buffered stream. New firmware can add sequences without
changing fabricated logic, within the documented instruction/I/O limits.

## Change the configuration

Comments label decimal program addresses. Preserve addresses unless updating
jump/call targets too. Words and byte values below are hexadecimal.

- UART TX address 2: `5055` → `50xx` to transmit xx.
- SPI address 2: `50A5` → `50xx` to send xx.
- I2C address 8: `50A0` → `0x5000 | (seven_bit_address << 1)`.
  Address 10: `50A5` → `50xx` for payload. Do not shift an already shifted address.
- UART TX D clocks/bit: WAIT operands at addresses 5/10 = D−2, address 7 = D−3.
  Default D=434. Stop/idle is slightly longer due to byte/counter reload.
- SPI H clocks/half-period: WAIT operands at addresses 7/9 = H−4/H−3.
  Default H=250. Only the supplied 100 kHz timing has been tested.
- I2C WAIT operands 249 give conservative roughly 5 us half-periods, with
  instruction/synchronization overhead and optional stretching added.

For other pins, update SET/DIR masks and every pin operand; see [ISA](../docs/isa.md).
SPI samples MISO late in the high half-cycle while a mode-0 peer holds it stable.
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
external peers. It checks UART TX/RX/framing, SPI timing/replies, I2C ACK/NACK,
clock stretching, open-drain safety, stuck bus recovery via HALT, and readback.
No Python library is needed. The separate Cocotb harness exists only for the
official template's RTL/gate-level workflow.

The Quartus project boots these exact files through an FPGA-only ROM adapter.
Set SW9=1, select SW1:0 (00 TX, 01 RX, 10 SPI, 11 I2C), then lower SW9.
Recompile/reprogram after editing the files. If adding/removing instructions,
update the ROM bounds and last-word addresses in `rtl/firmware_bootloader.v`.
On the ASIC, upload through the TT host instead. UART uploading is still deferred;
the DE1-SoC USB-Blaster is not a serial upload connection.
