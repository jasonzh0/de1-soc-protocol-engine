# Programmable engine ISA v1

One engine executes firmware for one protocol at a time. There are no dedicated
UART, SPI, or I2C controllers. FPGA and ASIC share `src/protocol_engine.v`.

## State and timing

- 64 writable 16-bit instructions, six-bit PC, eight pins, eight-bit TX/RX
  shift registers, one eight-bit loop counter, one return slot.
- Instructions take one clock except WAIT N (N+1 clocks) and WAIT_PIN (one or
  more clocks, until its condition matches). There is no fetch pipeline.
- Pin inputs cross two synchronizer flip-flops. An asynchronous transition
  has roughly 2–3 clocks of observation latency, plus any delay until firmware
  samples it. Independent pin synchronizers do not provide atomic bus sampling.
- HALT resets execution state and releases pins, retaining program contents
  and the last published result/toggle. Reset invalidates every program word
  and clears execution/result state; program data bits themselves are not reset.
- Invalid instructions, invalid SYS operands, unwritten fetches, unmatched
  returns and nested calls latch fault and release pins until HALT/reset.

## Instructions

Words are `(opcode << 12) | operand`. p=pin 0–7, v=0/1, a=address 0–63.
Unused operand bits are ignored except SYS, whose encodings are checked exactly.

| Opcode | Instruction | Operand / behavior |
| --- | --- | --- |
| 0 | FAULT | Deliberately invalid; releases pins |
| 1 | SET | Low eight bits replace all output values |
| 2 | WAIT | Low 12 bits: additional wait clocks |
| 3 | DIR | Low eight bits replace output-enable mask |
| 4 | JMP | a: unconditional jump |
| 5 | LOAD_TX | Low eight bits replace TX shift register |
| 6 | OUT | `p | (open_drain << 3) | (msb_first << 4)`; output one TX bit and shift |
| 7 | IN | `p | (msb_first << 4)`; sample one pin and shift into RX |
| 8 | COUNT | Low eight bits load loop counter |
| 9 | LOOP | If count >1: decrement and jump to a; otherwise clear count and continue |
| A | WAIT_PIN | `p | (v << 3)`; wait until synchronized pin equals v |
| B | JMP_PIN | `p | (v << 3) | (a << 4)`; branch if synchronized pin equals v |
| C | SET_PIN | `p | (v << 3)`; update one output value |
| D | DIR_PIN | `p | (v << 3)`; update one output enable |
| E | CAPTURE | Publish RX register and invert sample_toggle |
| F | SYS | `F000` clear RX; `F100 | a` call; `F200` return |

OUT push-pull changes a value but not its enable. Open-drain OUT forces the
value to zero and enables drive only for a zero data bit. Use external pull-ups.
IN MSB-first shifts `{RX[6:0], pin}`; LSB-first shifts `{pin, RX[7:1]}`. Eight
samples produce a normal numeric byte. COUNT 0 does not mean 256: LOOP falls
through. The loop counter is shared across calls; calls cannot nest.

CAPTURE is one overwriteable register, **not a FIFO**; there is no backpressure.
Observe each toggle before another capture, or two captures can cancel the
indication. SPI and UART RX capture once then idle. I2C captures once after its
two ACKs and STOP. A previous result remains until another CAPTURE/reset.

WAIT_PIN has no timeout. A stuck bus stalls with pin state retained; HALT/reset
can abort. I2C firmware waits with SCL released during stretching. Autonomous
recovery needs a future bounded-wait/watchdog mechanism.

## Compatibility

Original SET/WAIT/DIR/JMP timing is unchanged, preserving the FPGA key demo.
Addresses now span 0–63: ADDR_HI accepts 0–3, WRITE/PC wrap at 64, jumps use six
bits. Host command 6 selects status/result readback; 7 remains invalid.
Loading still uses the synchronous TT nibble bus or FPGA core write port.
There is **no UART upload transport or Python library** in this version.
