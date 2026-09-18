# Experimental byte-processing ISA (opt-in)

This profile extends the **same** `protocol_engine`, not a second execution
implementation. It supplies generic scratch/ALU, programmable CRC, NRZI/stuffing,
periodic pin sampling and interval primitives. It contains no USB PID, endpoint,
descriptor, packet-length or protocol state machine. USB behavior is firmware.
This is an experimental encoding, not a frozen ASIC ABI.

## Configuration and timing contract

- Default `PROGRAM_ADDR_WIDTH=6`, `EXTENDED_ISA=0`, `CLOCK_HZ=50000000` keeps
  [ISA v1.1](isa.md). Opcode `0xxx` remains invalid in that profile.
- The FPGA USB profile uses width 11 (2,048 words) and extensions enabled.
  Supported width range is 6–12. Programming address, PC and return slots widen
  together; JMP/LOOP use that many low instruction bits. PC wraps at memory size.
  Old JMP_PIN, CALL and START_CTX retain **six-bit** targets.
- `CLOCK_HZ` must be an integer multiple of 1,000 and at least 2,000; the interval
  clock divides it to 1 ms. It must describe the real input clock.
- Extensions execute only in single-context mode. Attempting an extended
  instruction after START_CTX faults and releases pins. Legacy two-context
  operation is unchanged. These are not two parallel USB engines.
- All new operations take one clock, except WAIT_TICK, which stalls at the same
  PC until a sample is pending. Existing WAIT and other legacy timings are
  unchanged. No new clock or vendor primitive is introduced.
- HALT/reset clears ALU, timing, CRC and serial state; HALT retains the published
  result as before. Program validity resets with reset, not HALT. Scratch bytes
  are **not reset**, and firmware must initialize them before use. Unwritten
  instructions and unsupported encodings still fault. The default memory backend
  is asynchronous; the [synchronous/SRAM profile](sram-redesign.md) substitutes
  reset-time zero scrubbing for validity bits, gates loading with program_ready,
  and adds one prefetch clock to RUN without changing steady-state ISA timing.

State: byte accumulator `A`, byte index `I`, 256 scratch bytes `M`, zero flag `Z`,
carry/borrow flag `C`. Byte/index arithmetic wraps modulo 256. Comparisons leave
A unchanged and set C for unsigned **less than**. Addition sets C for overflow.
Unless listed, an operation preserves flags. All loads into A below set Z;
stores/index/timing/serial/CRC updates preserve flags.

## Byte and control instructions

Hex notation: `ii` immediate, `aa` scratch address, `oo` unsigned indexed offset.

| Word | Effect |
| --- | --- |
| 01ii / 02aa / 03aa | A=ii / A=M[aa] / M[aa]=A |
| 04ii | A=A+ii; Z,C |
| 05ii / 06ii / 07ii | A AND / XOR / OR immediate; Z |
| 08ii | Compare A with ii; Z,C |
| 09ii | I=ii |
| 0Aoo / 0Boo | A=M[I+oo] / M[I+oo]=A (address wraps) |
| 0Cii | I=I+ii |
| F8aa / F9aa / FAaa | A XOR M[aa] (Z) / A ADD M[aa] (Z,C) / compare (Z,C) |
| F400–F7FF | CALL low ten-bit target (0–1023), one return slot; F200 returns |
| FEaa | M[aa]=M[I], A=M[I], CRC updates from M[I], I++; preserves flags |
| 0E00 / 0E01 / 0E02 | A=synchronized pins / pin_out=A / pin_oe=A |
| 0E03 / 0E04 | A=RX shift register / TX=A and serial_count=0 |
| 0E05 / 0E06 | I=A / A=I |
| 0E07 | A=NOT A; Z |
| 0E08 / 0E09 | Shift A right / left once; shifted-out bit to C, Z |
| 0E40–0E47 / 0E48–0E4F | Shift A right / left 0–7 places; Z, C preserved |
| 0E18 | Publish A to sample_data and invert sample_toggle |
| 0E1D | Legacy context-0 LOOP counter=A |

Wide CALL truncates to the configured PC width if smaller than ten bits;
firmware must supply a fitting target. Nested calls fault instead of overwriting
the return slot. FEaa deliberately fuses a generic checked-byte copy to keep
packet preparation inside tight timing budgets; it is not descriptor-aware.

## Periodic sampling and intervals

| Word | Effect |
| --- | --- |
| 0Dii | Set bit period in clocks (firmware uses 33; use 4–255) |
| FDii | Bit 7 enables edge alignment; bits 2:0 select input pin |
| 0E0E | Start/restart sampler; clear pending/overrun; first sample after period |
| 0E0F | WAIT_TICK: consume pending sample into A (Z), otherwise hold PC |
| 0E10 | Stop sampler and clear pending |
| 0E1C | Clear pending and sticky overrun without changing phase |
| 0E32 / 0E33 | Set interval limit low / high byte from A (milliseconds) |
| 0E34 | Set interval start timestamp to current milliseconds |

The sampler runs every clock while enabled, independently of instruction issue.
Each selected synchronized-input transition repositions the next sample to
`floor(period/2)` clocks after that transition; otherwise samples recur every
period. One pending sample is stored, not a FIFO. A new sample overwrites it
and latches overrun if the old pending bit was still set, including a simultaneous
consume; firmware must avoid that collision. WAIT_TICK is not included in the
legacy pin-wait-only `stalled` output. HALT/fault stops sampler progress.

The millisecond counter and elapsed subtraction are 16-bit wrapping values.
Interval-due is true when limit is nonzero and unsigned elapsed >= limit. Poll
within the wrap window (65.536 s); this is not an unbounded timer. USB HID idle
firmware scales the host's duration to its specified four-millisecond units.

## Generic serial coding and CRC

| Word | Effect |
| --- | --- |
| FBii | Output mask toggled for an encoded zero |
| FCii | Consecutive-one stuffing threshold = ii[2:0]; zero disables stuffing |
| 0E19 | Previous sampled serial bit=A[0]; clear count, ones and error |
| 0E1A | Clear serial count, ones and error (preserve previous sample) |
| 0E0A | Clear byte count and RX shift register, retaining ones/previous/error |
| 0E0B | NRZI-decode A[0] versus previous sample; destuff; shift into RX LSB-first |
| 0E0C | NRZI-encode TX LSB, toggle pin_out mask for zero, insert stuffed zero |
| 0E1E | A=decoded/transmitted non-stuffed bit count; Z |
| 0E11 / 0E12 | Write CRC state low / high byte from A |
| 0E13 / 0E14 | Write reflected CRC polynomial low / high byte from A |
| 0E15 | CRC-update A, eight LSB-first steps, no implicit inversion |
| 0E16 / 0E17 | A=CRC state low / high byte; Z |
| 0E20 / 0E21 | Save current CRC state and polynomial as preset 0 / 1 |
| 0E22 / 0E23 | Restore CRC state and polynomial from preset 0 / 1 |

No input transition means decoded one. After the configured run of ones, the
next received bit must decode as zero: it is discarded, with sticky error if it
instead decodes one. TX inserts that zero without shifting TX or incrementing
the bit count. Loading the next byte preserves the run of ones across byte
boundaries. Firmware handles packet boundaries, SYNC, EOP and a final required
stuffed bit. Firmware must drain/reset the byte count after eight bits; the
hardware does not frame bytes or packets autonomously.

The CRC recurrence is `(crc >> 1) XOR (polynomial if crc[0] XOR data_bit else 0)`.
Narrow reflected CRCs work by choosing a narrow seed/polynomial; final inversion
and residue interpretation belong to firmware. Presets are writable registers,
not hard-coded USB CRCs.

## Conditional skip

`0Fnn` skips exactly **one instruction** if the condition below is true,
otherwise falls through. A following full-width JMP makes a conditional branch.

| nn (hex) | Condition | Inverse nn |
| --- | --- | --- |
| 00 | Z | 01 |
| 02 | C | 03 |
| 04 | serial_count == 8 | 05 |
| 06 | serial_error | 07 |
| 08 | stuffing threshold reached (nonzero threshold) | 09 |
| 0A | sample overrun | 0B |
| 0C | interval due | 0D |

Non-USB regression: `make test-extended`. Integrated protocol/timer/serial
regression: `make test-usb`. Default profile regressions remain `make test` and
the Tiny Tapeout template harness. The FPGA USB adapters remain separate from
`info.yaml`. The internal program_store module is shared; physical TT ports are
unchanged and the submission defaults still disable the extension.
