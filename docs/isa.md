# Programmable engine ISA v1.1

One execution engine supports one or two independent instruction contexts.
There are no dedicated UART, SPI, or I2C controllers. FPGA and ASIC share
`src/protocol_engine.v`. The scheduling feature is not tied to any protocol.

## State and timing

- 64 shared writable 16-bit instructions and eight shared pins. Each context
  has a six-bit PC, eight-bit TX/RX shifts and loop counter, wait counter and
  one return slot. One decoder executes one context per physical clock.
- Instructions take one **context tick** except WAIT N (N+1 ticks) and WAIT_PIN
  (one or more ticks). A tick is one clock normally, or two clocks after
  START_CTX. There is no fetch pipeline. Original single-context timing is unchanged.
- Pin inputs cross two synchronizer flip-flops. An asynchronous transition
  has roughly 2–3 clocks of observation latency, plus any delay until firmware
  samples it. Independent pin synchronizers do not provide atomic bus sampling.
- HALT resets execution state and releases pins, retaining program contents
  and the last published result/toggle. Reset invalidates every program word
  and clears execution/result state; program data bits themselves are not reset.
- Invalid instructions, invalid SYS operands, unwritten fetches, unmatched
  returns, nested calls and attempts to start a third context latch a global
  fault and release pins until HALT/reset. Either context can fault both.

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
| F | SYS | `F000` clear RX; `F100 | a` call; `F200` return; `F300 | a` START_CTX |

## Independent contexts and shared-resource ownership

Only context 0 runs after reset/HALT. START_CTX starts context 1 at address a,
with register state already cleared by reset/HALT. If START_CTX executes at
clock n, context 1 runs at n+1, context 0 at n+2, then they alternate strictly.
Waits do not lend slots to the sibling: both always receive one tick every two
clocks, so one waiting for input cannot jitter the other's output timing.
At 50 MHz, dual-context firmware therefore has a 25 MHz tick rate. WAIT 0 takes
one tick, not zero. Both-waiting contexts still retain this schedule.

This is **interleaved execution**, not two instructions executing in parallel:
after START_CTX the schedule is `child, parent, child, parent, ...`. Both are
clocked by the same 50 MHz clock; 25 million context ticks/second is an execution
rate, not a second clock domain. UART TX and RX overlap in real time because
each keeps its own progress while the other executes or waits. The tradeoff is
half the instruction bandwidth per context in exchange for a shared execution
unit and one instruction read per clock. The area saving versus two units has
not been measured in CMOS5L. Stealing idle slots would break fixed tick timing.

START_CTX is permitted only once per RUN. A later attempt from either context
faults. HALT/reset disables the child and restores single-context scheduling.
The context count is intentionally bounded at two; there is no stack of contexts
or promise of arbitrarily many concurrent streams.

Program memory, pin values/enables, fault, and the published result register are
shared. Firmware assigns disjoint output pins to contexts. Configure shared
SET/DIR masks before START_CTX, then use per-pin writes to preserve the sibling's
signals. Conflicting writes are serialized, last write wins; hardware does not
enforce pin ownership. Inputs may be observed by both contexts.

Each context has its own return slot and loop/shift/wait state. Calls remain
one level deep within each context. Designate a single CAPTURE publisher unless
your firmware provides its own ordering: the shared result has no source tag,
queue, or backpressure. This explicit ownership/timing contract also allows
other protocol programs to use the scheduler without UART-specific RTL.

The `stalled` status is now the OR of registered per-context WAIT_PIN states.
It updates when the relevant context executes; a matching input clears that
context's wait flag on its next tick. It means **at least one context is waiting**,
not that the whole engine stopped. LEDR3 can stay on while duplex TX continues.

OUT push-pull changes a value but not its enable. Open-drain OUT forces the
value to zero and enables drive only for a zero data bit. Use external pull-ups.
IN MSB-first shifts `{RX[6:0], pin}`; LSB-first shifts `{pin, RX[7:1]}`. Eight
samples produce a normal numeric byte. COUNT 0 does not mean 256: LOOP falls
through. A context's loop counter is shared across its calls; calls cannot nest.

CAPTURE is one overwriteable register, **not a FIFO**; there is no backpressure.
Observe each toggle before another capture, or two captures can cancel the
indication. SPI, the standalone UART RX example, and I2C capture once then idle.
Duplex UART captures every received byte, overwriting the previous result.
The host must read every byte before the next capture (~87 us at 115200 8N1,
320 us at 31250).
A previous result remains until another CAPTURE/reset. This is not lossless
buffered streaming to an arbitrarily slow host.

WAIT_PIN has no timeout. A stuck bus stalls with pin state retained; HALT/reset
can abort. I2C firmware waits with SCL released during stretching. Autonomous
recovery needs a future bounded-wait/watchdog mechanism.

## Compatibility

Without START_CTX, original SET/WAIT/DIR/JMP timing is unchanged, preserving the FPGA key demo.
Addresses now span 0–63: ADDR_HI accepts 0–3, WRITE/PC wrap at 64, jumps use six
bits. Host command 6 selects status/result readback; 7 remains invalid.
Loading still uses the synchronous TT nibble bus or FPGA core write port.
There is **no UART upload transport or Python library** in this version.

The opt-in FPGA [byte-processing extension](isa-extended.md) adds wider memory,
scratch/ALU, generic serial coding, CRC and sampling operations for experimental
USB firmware. It is disabled in this default ISA/Tiny Tapeout configuration.
