# ASIC memory evaluation

Evaluated 2026-09-18 against repository commit `f158a3f`.
No implementation change is made by this assessment. CI stays paused.

Subsequent implementation: [SRAM redesign and new mapped results](sram-redesign.md).
The measurements below are the pre-redesign baseline.

## Decision

**Keep the present 64-word implementation as the working baseline. Do not move
the USB profile into the ASIC as flip-flop memory. Proceed toward a hard-SRAM
program store if USB or substantially larger firmware is required.**

Preliminary mapping to the actual CMOS5L standard-cell library puts the baseline
at about **0.106 mm²**, versus **3.054 mm²** for the experimental USB core. The
current 6×4 template rectangle is about **0.916 mm²**. The USB implementation
therefore cannot fit as mapped, even before placement whitespace, clocks and
routing. The baseline has encouraging area headroom, but routed fit and 50 MHz
timing are still unproved.

## What memory we actually need

| Profile | Program data | Program validity | Scratch data | Firmware capacity |
| --- | --- | --- | --- | --- |
| Current ASIC / UART, SPI, I²C | 64×16 = 128 B | 64 bits = 8 B | None | Current examples fit |
| Hypothetical wider legacy core | 256×16 = 512 B | 256 bits = 32 B | None | More space, but no USB extension |
| Experimental USB core | 2048×16 = 4096 B | 2048 bits = 256 B | 256×8 = 256 B | USB image uses 1288 words = 2576 B |

The USB image uses 62.89% of program capacity, leaving 760 instructions / 1520 B.
Its descriptors are initialized into scratch by instruction sequences; the
reported instruction count already includes those initialization instructions.
This is one shared program store, **not** a separate store per context.

The current RTL reads instructions and scratch combinationally. It consequently
maps to flip-flops and mux/decoder logic, not a hard SRAM. Validity is separate
resettable storage. Merely changing `reg [15:0] program_mem [...]` or increasing
the address width cannot solve that physical implementation problem.

## Measurements

Tool: Yosys 0.69 / git `9f75ca1f9`, via YoWASP. Library: typical 1.20 V / 25°C
CMOS5L Liberty from the exact PDK revision pinned by the inspected Tiny Tapeout
action. [Pinned library and source provenance](asic-memory-sources.md)

| Measured design | Generic `synth -noabc` cells | CMOS5L mapped cell area | Scope |
| --- | ---: | ---: | --- |
| Default ASIC | 4183 | 106,345.08 µm² / 0.106345 mm² | Entire TT top including loader/pad adapter |
| 256-word, extensions disabled | 11,919 | 369,392.79 µm² / 0.369393 mm² | Core only; no widened host loader implemented |
| USB, 2048 words, extensions enabled | 108,838 | 3,053,979.67 µm² / 3.053980 mm² | Core only, without FPGA boot ROM or ASIC host adapter |

A separate 512-word legacy-core generic synthesis reported 22,502 primitives;
it was not technology-mapped in this evaluation. Generic cell counts are **not**
equivalent to physical cells, LUTs, or the contest's approximate cells-per-tile
guidance. The mapped columns are a better area estimate, with the limits below.

All three mapped designs passed Yosys `check -assert`. These runs are standalone
`synth -noabc; dfflibmap; abc; clean; stat` mappings, **not** the complete
LibreLane synthesis recipe or a place-and-route run. ABC used its default
mapping script without a 20 ns timing constraint, I/O loads, parasitics or PVT
closure. Clock-tree/tie/fill/hold-repair cells, macro halos, PDN and routing are
not included. Tool versions, mapping restrictions and physical optimization can
change the final area. No timing or power signoff is claimed.

The no-fit conclusion is not sensitive to small mapper differences: USB maps
37,266 flip-flops to 48.9888 µm² cells, totaling **1.825617 mm² of flops alone**.
Even its 32,768 program-data bits alone require **1.605265 mm²** in those cells,
without write-enable muxes, read muxes, validity, scratch or execution logic.
Shrinking only to the current 1288 used words still needs about **1.010 mm²**
of program data flops, and would remove future firmware growth capacity.

## SRAM candidates and staged recommendation

The pinned CMOS5L PDK explicitly aliases its SRAM directory to IHP's supplied
SG13G2 SRAM library. Actual models, timing and physical views exist; this is
not an assumption based only on matching the process node. Details and pinned
primary sources: [CMOS5L SRAM source check](asic-memory-sources.md).

| Candidate | Capacity / mapping | Macro area only |
| --- | --- | ---: |
| `RM_IHPSG13_1P_1024x32_c2_bm_bist` | 4 KiB, two 16-bit instructions per word | 0.140183 mm² |
| Two `RM_IHPSG13_1P_1024x16_c2_bm_bist` | 4 KiB, two program banks | 0.159347 mm² |
| `RM_IHPSG13_1P_256x8_c3_bm_bist` | 256 B scratch | 0.017547 mm² |

**Preferred program candidate: one 1024×32 macro.** Use word address PC[10:1]
and track PC[0] with the returned word. Its bit mask supports independently
writing either 16-bit half from the existing word-oriented programming seam.
Loading and execution are mutually exclusive today, so a single read/write
port is enough for program storage; dual-port SRAM is not inherently required
by two interleaved contexts.

The program-plus-scratch pair has a combined bare footprint of **0.157730 mm²**,
17.22% of the current template's 0.916214 mm² rectangle. That is **not the total
redesigned chip area**: controller, execution logic, validity policy, halos,
clocking and routing remain. At the repo's 60% placement-density target, raw
die area must not be treated as an equal-sized standard-cell budget. Exact
row and macro geometry are recorded in the source check; recheck the final
shuttle's resolved support-tools revision.

Implement and measure in stages if authorized:

1. Replace only the **program-store implementation**, behind an internal memory
   interface in the existing engine. Keep one shared core; use a latency-accurate
   model for FPGA/simulation and an explicit IHP macro adapter for ASIC.
2. Initially keep the 256-byte scratch register array to isolate the instruction
   fetch change. Measure remaining area before deciding whether scratch SRAM is
   necessary. It is far smaller than the 4 KiB program store, and retains the
   existing scratch-access timing.
3. If needed, introduce the 256×8 scratch macro with defined load/copy latency
   and revalidated firmware, rather than pretending it has asynchronous reads.

## Changes SRAM requires

**Fetch timing:** these macros are positive-edge, synchronous-read memories.
A naive fetch/execute alternation would change instruction timing and jeopardize
USB's existing response budget. Design explicit prefetch/next-address behavior,
cover branches/calls/waits/context switches and startup, then re-run cycle-exact
UART/SPI/I²C and minimum-gap USB tests. Sustaining one issue per clock is a design
goal, not established merely by choosing a fast SRAM. Check the path from SRAM
output through decode/next-address logic back to SRAM setup at slow PVT.

**Scratch timing/ports:** `FEaa` currently copies between two scratch addresses
and updates CRC on one execution edge. A single-port scratch SRAM cannot do that
same-edge two-address operation. It needs sequenced micro-operations or another
memory architecture. Even ordinary scratch loads acquire read latency.

**Validity/reset:** keeping 2048 valid bits would retain roughly 0.100329 mm²
of flip-flop area alone, plus logic. SRAM itself has no reset. A sequential image
loader with a completion fence and hardware bounds checks could replace the
bitmap with a small amount of metadata, but changes today's arbitrary/sparse
write contract. Alternatively clear all instruction words to the invalid opcode
before accepting RUN, costing 2048 word writes (40.96 µs at 50 MHz; packed full
32-bit clearing can use 1024 writes / 20.48 µs). Define reset interruption and
partial-image behavior; never permit uninitialized SRAM execution. These are
alternative designs, not optimizations already implemented.

**Host addressing:** the ASIC loader still exposes six address bits. Supporting
2048 instructions needs an 11-bit address protocol, coordinated metadata/tests,
and backward compatibility decisions. The core already parameterizes PC width,
but legacy CALL/JMP_PIN/START_CTX targets stay six-bit and extended CALL stays
ten-bit. Larger memory does not silently enlarge those instruction encodings.

**Physical integration:** instantiate the macro explicitly, supply LEF/GDS and
all Liberty corners to the pinned flow, tie `A_DLY` high, handle unused BIST,
connect both logic and array supplies, floorplan halos/PDN access and close
timing/DRC/LVS/precheck. The source check records the exact supply names and
metal limits. Do not enable CI or change `info.yaml` merely to assume fit.

**Fallback:** retaining 64 words is adequate for current demonstrations but
restricts future firmware. A 256-word flop-based legacy core is a plausible
intermediate capacity, not a USB solution. Fixed ROM would reduce flexibility;
external SPI memory adds pin/bandwidth/determinism problems and is better suited
to loading programs than direct timing-critical instruction fetch.

## Reproducing the area evaluation

From the repository root, obtain the [pinned typical Liberty](https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib)
as `build/cmos5l_typ_action.lib`. Its SHA-256 is
`34163f3e7de9f854afac57332ba06f1739b78e7ac35660a8a5ddd39c570124ad`.

```sh
uvx --from yowasp-yosys yowasp-yosys -Q -T -l build/asic_mapped_usb.log -p '
read_liberty -lib build/cmos5l_typ_action.lib
read_verilog src/protocol_engine.v
chparam -set PROGRAM_ADDR_WIDTH 11 -set EXTENDED_ISA 1 protocol_engine
synth -top protocol_engine -noabc
dfflibmap -liberty build/cmos5l_typ_action.lib
abc -liberty build/cmos5l_typ_action.lib
clean
check -assert
stat -liberty build/cmos5l_typ_action.lib
'
```

For the 256-word comparison, use width 8 and EXTENDED_ISA=0. For the default TT
comparison, omit `chparam`, read all three files listed in `info.yaml`, and use
`synth -top tt_um_jasonzh0_protocol_engine -flatten -noabc`. Raw logs are ignored
build artifacts: `build/asic_mapped_64.log`, `build/asic_mapped_256.log`, and
`build/asic_mapped_usb.log`. Repeat with the recorded tool/library revisions
when comparing changes; a future unpinned `uvx` install may use a different Yosys.
