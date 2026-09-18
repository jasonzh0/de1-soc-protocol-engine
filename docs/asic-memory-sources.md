# CMOS5L SRAM source check

Checked 2026-09-18. This is a source-based feasibility assessment, not a completed
macro integration, placement/routing result, or tapeout approval.

## Finding

**Suitable hard SRAM views are present in the exact PDK currently installed by
the Tiny Tapeout CMOS5L action.** This is stronger evidence than assuming the
SG13G2 memory table applies to CMOS5L: the CMOS5L PDK explicitly aliases its SRAM
library to the SG13G2 SRAM library. Its metal usage and voltage range are also
compatible with the inspected CMOS5L configuration. Physical integration still
needs to be proved in this project.

The inspected [Tiny Tapeout install script][install] pins IHP-Open-PDK commit
`2bbec755dc67ca3db0261c3d6163e15735d66710`. At that revision,
[`ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram`][alias] is a symlink to
`../../ihp-sg13g2/libs.ref/sg13g2_sram`. Use both trees from that pinned checkout;
copying only the CMOS5L directory would leave the reference unresolved.

## Concrete candidates

Dimensions below are **width × height** from the pinned IHP macro datasheets,
not tile-count estimates. All listed macros have one read/write port and a
synchronous, one-cycle data access.

| Purpose / option | Exact macro | Storage | Size (µm) | Area (µm²) |
| --- | --- | --- | --- | --- |
| Existing baseline program | `RM_IHPSG13_1P_64x16_c2` | 128 B | 236.80 × 64.36 | 15,240.45 |
| Larger baseline program | `RM_IHPSG13_1P_256x16_c2_bm_bist` | 512 B | 236.80 × 118.78 | 28,127.10 |
| Half of USB program / banking option | `RM_IHPSG13_1P_1024x16_c2_bm_bist` | 2 KiB | 236.80 × 336.46 | 79,673.73 |
| Packed USB program candidate | `RM_IHPSG13_1P_1024x32_c2_bm_bist` | 4 KiB | 416.64 × 336.46 | 140,182.69 |
| USB scratch candidate | `RM_IHPSG13_1P_256x8_c3_bm_bist` | 256 B | 236.80 × 74.10 | 17,546.88 |

Sources: IHP datasheets for [64×16][m64], [256×16][m256],
[1024×16][m1024x16], [1024×32][m1024x32], and [256×8][m256x8].
The 1024×32 library includes actual [LEF][lef], [GDS][gds],
[typical Liberty][sramlib], and [Verilog][model] views at the pinned revision.
The wider library directory supplies fast/slow timing and other macro sizes.

**Architecture inference:** pack two 16-bit instructions into each 32-bit word,
address the macro with `PC[10:1]`, and select the fetched half using a registered
`PC[0]`. Its bit write mask permits independent half-word programming. This
holds the present 2048-word USB program capacity without wasting half of a
2048×32 macro. It is a proposal, not implemented RTL. A separate 256×8 SRAM
avoids instruction-versus-scratch port arbitration, but does not remove the
scratch read latency.

In particular, the extension's `FEaa` instruction currently reads an indexed
scratch byte, writes it to a different scratch address, and updates the CRC in
one execution edge. A single-port synchronous scratch macro cannot perform that
two-address operation in the same edge. Split it into defined micro-operations,
or select a different memory/port architecture, then re-budget the tight USB
response paths and rerun the timing tests. [Local extension contract](isa-extended.md)

## Timing, power, and metal contracts

- Address, enables, data, and bit write mask are sampled on the positive clock
  edge. The output is registered by the behavioral model; it is **not** an
  asynchronous read. In the mask, a one enables that bit's write. A combined
  read/write is write-through. The model provides no reset or initialized
  memory contents. [IHP behavioral model][behavior]
- The 1024×32 and 256×8 datasheets require `A_DLY=1`. BIST has a separate
  interface selected by `A_BIST_EN`; normal operation should tie that select
  and unused BIST controls appropriately. A BIST interface is not a second
  simultaneous application port. [Program macro][m1024x32],
  [scratch macro][m256x8]
- The documented supply operating range is 1.08–1.32 V, with typical 1.20 V;
  the macro has logic and array supplies. LEF power pins are spelled `VDD!`,
  `VDDARRAY!`, and `VSS!`, so macro PDN hookups must match these names, not just
  the core's `VPWR`/`VGND`. Do not assume the SRAM can use the standard cells'
  optional 1.5 V corner. [Datasheet][m1024x32], [LEF][lef]
- Macro metal usage ends at M4. CMOS5L is M1–M4–TM1; Tiny Tapeout's user routing
  ceiling is Metal4. This establishes stack compatibility, **not** sufficient
  routing/PDN access or DRC clearance. [Macro datasheet][m1024x32],
  [PDK flow configuration][pdkconfig], [Tiny Tapeout technology settings][tech]
- The 1024×32 datasheet summarizes rising clock-to-output as 4.37 ns typical
  and 7.32 ns slow; 256×8 gives 3.00 ns and 5.03 ns. Those summaries are not a
  50 MHz system timing signoff: use Liberty load/slew timing and the complete
  fetch/execute path. [Program timing][m1024x32], [scratch timing][m256x8]

The current engine's asynchronous reads cannot be changed to these macros
without a fetch/execute and scratch-access timing design. Changing the Verilog
array alone does not instantiate a hard macro or preserve firmware timing.

## 6×4 geometry and limits

Tiny Tapeout support-tools revision
`f6bf5c587fba4a4a8abd4c0a03234fccfbf6e61e` specifies a 6×4 die rectangle of
**1289.28 × 710.64 µm = 916,213.94 µm² (0.916214 mm²)**.
The [tile-size configuration][tiles] and [6×4 DEF][def] agree. It is not simply
24 times the 1×1 rectangle: the allocation includes inter-tile geometry.

The DEF contains 186 placement rows, each 2674 sites at 0.48 µm pitch and
3.78 µm row pitch. This gives about **902,417.24 µm² of raw row area**, before
macros, keepouts, power structures, routing, clock cells, fillers and density
limits. It is an upper geometric bound, not an available logic-area budget.

The proposed 1024×32 plus 256×8 pair occupies **157,729.57 µm²**, or **17.22% of
the die rectangle**, without halos or supporting logic. Their bounding boxes
can geometrically fit side by side. This makes hard-SRAM evaluation credible;
it does **not** demonstrate routed fit or power-grid feasibility.

## Flow support versus work still required

The [official action][action] selects CMOS5L support-tools and LibreLane
`3.1.0.dev3`. The PDK has SRAM-aware [LVS integration rules][lvs]. Those are
positive integration evidence, but the checked project has not run a macro
implementation through that flow. Tiny Tapeout itself warns that SRAM
integration is nontrivial and its published SG13G2 tile table is rough guidance.
[Tiny Tapeout memory guidance][memory]

Before choosing the implementation, prove explicit macro instantiation and
black-box synthesis, behavioral/timing simulation, all timing corners,
macro floorplan and halos, power to both supply pins, clock routing, placement,
DRC/LVS/precheck, and firmware timing under synchronous reads. Reset/validity
metadata must be designed separately because the SRAM itself is not resettable.
Keep CI paused unless explicitly requested otherwise.

For local standard-cell comparisons, use the [CMOS5L typical Liberty][stdlib]
from the **same pinned PDK**, rather than an unrelated SG13G2 or moving-main
library. Example cell areas there are `sg13cmos5l_dfrbpq_1` 48.9888 µm²,
`sg13cmos5l_mux2_1` 18.144 µm², and `sg13cmos5l_dlhq_1` 30.8448 µm². These are
individual cell areas, not complete memory-area estimates.

[install]: https://github.com/TinyTapeout/tt-gds-action/blob/3412659307918422f3f0727917cf9b499aaca588/install_sg13cmos5l.sh
[action]: https://github.com/TinyTapeout/tt-gds-action/blob/3412659307918422f3f0727917cf9b499aaca588/action.yml
[alias]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram
[m64]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_64x16_c2.txt
[m256]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_256x16_c2_bm_bist.txt
[m1024x16]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_1024x16_c2_bm_bist.txt
[m1024x32]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_1024x32_c2_bm_bist.txt
[m256x8]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/doc/RM_IHPSG13_1P_256x8_c3_bm_bist.txt
[lef]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/lef/RM_IHPSG13_1P_1024x32_c2_bm_bist.lef
[gds]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/gds/RM_IHPSG13_1P_1024x32_c2_bm_bist.gds
[sramlib]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x32_c2_bm_bist_typ_1p20V_25C.lib
[model]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x32_c2_bm_bist.v
[behavior]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v
[pdkconfig]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13cmos5l/libs.tech/librelane/config.tcl
[tech]: https://github.com/TinyTapeout/tt-support-tools/blob/f6bf5c587fba4a4a8abd4c0a03234fccfbf6e61e/tech.py
[tiles]: https://github.com/TinyTapeout/tt-support-tools/blob/f6bf5c587fba4a4a8abd4c0a03234fccfbf6e61e/tech/ihp-sg13cmos5l/tile_sizes.yaml
[def]: https://github.com/TinyTapeout/tt-support-tools/blob/f6bf5c587fba4a4a8abd4c0a03234fccfbf6e61e/tech/ihp-sg13cmos5l/def/tt_block_6x4_pgvdd.def
[lvs]: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13cmos5l/libs.tech/klayout/tech/lvs/rule_decks/sram_integration.lvs
[memory]: https://www.tinytapeout.com/specs/memory/
[stdlib]: https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/2bbec755dc67ca3db0261c3d6163e15735d66710/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
