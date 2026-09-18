# CMOS5L template alignment

Reference: [TinyTapeout CMOS5L template](https://github.com/TinyTapeout/ttihp-verilog-template/tree/cmos5l),
checked at commit `b86a2a781484bcab7ba522dc5de540086695a430`.
We use its source/metadata/workflow contracts, replacing the example adder
with our engine. FPGA adapters, firmware and local regressions live alongside.

| Contract | Implementation |
| --- | --- |
| Digital top | Standard eight ports on tt_um_jasonzh0_protocol_engine |
| Metadata | info.yaml schema 6; submission sources all in src/ |
| Allocation | 6x4 per competition, not the template example's 1x1 |
| Physical config | src/config.json unchanged from reference; 20 ns target |
| GDS/precheck/GL/viewer | Official @ihp-cmos5l actions, PDK ihp-sg13cmos5l |
| Tests | test/Makefile, tb.v, test.py and template-pinned Cocotb dependencies |
| Documentation | docs/info.md and template-derived docs workflow |

## Deliberate differences

- All CI stays paused: manual-only triggers AND literal false job guards.
  Even a manual dispatch cannot execute a job. The original simulation workflow
  is also disabled in GitHub settings. Resume only at the user's request.
- Top/source names and behavioral tests are ours. Gate-level testing retains
  the template's GATES=yes, cell-model paths and gate_level_netlist.v convention.
- Quartus targets DE1-SoC, so the optional template ICE40UP5K workflow is omitted.
- The optional devcontainer is omitted: its pinned Dockerfile still defaults
  to ihp-sg13g2/support-tools main, unlike the CMOS5L GDS workflow.
- Template provenance is pinned here; action references follow the template's
  moving ihp-cmos5l branch. Record resolved action/PDK revisions for the actual
  physical build when CI is explicitly resumed.

## Checks

Install test/requirements.txt in a virtual environment, then run:

```sh
make check-template
make test
make test-template
```

With uv: `uv run --with-requirements test/requirements.txt make check-template test-template`.

check-template validates metadata, ports, source lists, both Quartus profiles,
the default USB attach guard, config identity, clock consistency and the CI
pause. It is not the physical Tiny Tapeout precheck.
test-template checks public-pin loader/UART at RTL; the same harness is wired
for the official gate-level action. Full protocol regression currently runs
in make test-protocols at RTL, not against a mapped netlist.

Still required: CMOS5L mapped area/fit, placement/routing, timing closure,
DRC/LVS/precheck, gate-level protocol coverage, FPGA hardware validation and
final rules review. 50 MHz and 6x4 are targets, not verified physical results.
