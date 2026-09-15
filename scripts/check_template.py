"""Offline repository checks, NOT Tiny Tapeout's physical precheck."""
import hashlib
import json
from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def main():
    metadata = yaml.safe_load((ROOT / "info.yaml").read_text())
    project = metadata["project"]
    require(metadata["yaml_version"] == 6, "expected yaml_version 6")
    require(project["tiles"] == "6x4", "competition allocation must remain 6x4")
    top = project["top_module"]
    require(top.startswith("tt_um_"), "top name must start with tt_um_")
    require(set(metadata["pinout"]) == {
        f"{group}[{bit}]" for group in ("ui", "uo", "uio") for bit in range(8)
    }, "pinout must contain exactly the template's 24 pins")
    sources = project["source_files"]
    require(len(sources) == len(set(sources)), "duplicate source file")
    for source in sources:
        path = ROOT / "src" / source
        require(path.resolve().is_relative_to((ROOT / "src").resolve()), "source escapes src/")
        require(path.is_file(), f"missing source: {source}")
    source_line = re.search(r"^PROJECT_SOURCES\s*=\s*(.*)$",
                            (ROOT / "test/Makefile").read_text(), re.M)
    require(source_line is not None and source_line[1].split() == sources,
            "test/Makefile source list differs from info.yaml")
    synth = (ROOT / "scripts/synth.ys").read_text()
    synth_line = re.search(r"^read_verilog\s+(.*)$", synth, re.M)
    require(synth_line is not None and synth_line[1].split() == [f"src/{s}" for s in sources],
            "synthesis source list differs from info.yaml")
    require(f"-top {top}" in synth, "synthesis top mismatch")
    qsf = (ROOT / "quartus/de1_soc_demo.qsf").read_text()
    require("-name TOP_LEVEL_ENTITY de1_protocol_top" in qsf, "wrong active Quartus top")
    board_sources = re.findall(r"-name VERILOG_FILE (\S+)", qsf)
    require(board_sources == ["../src/protocol_engine.v", "../rtl/firmware_bootloader.v",
                              "../rtl/de1_protocol_top.v"], "Quartus source list drift")
    for source in board_sources:
        require((ROOT / "quartus" / source).is_file(), f"missing Quartus source: {source}")
    require(all("firmware_bootloader" not in s for s in sources),
            "FPGA-only boot ROM must not be part of ASIC")
    rtl = (ROOT / "src" / f"{top}.v").read_text()
    ports = re.findall(r"\b(input|output)\s+wire\s*(\[7:0\])?\s*(\w+)", rtl)
    expected = {
        "ui_in": ("input", "[7:0]"), "uo_out": ("output", "[7:0]"),
        "uio_in": ("input", "[7:0]"), "uio_out": ("output", "[7:0]"),
        "uio_oe": ("output", "[7:0]"), "ena": ("input", ""),
        "clk": ("input", ""), "rst_n": ("input", ""),
    }
    require({name: (direction, width) for direction, width, name in ports} == expected,
            "Tiny Tapeout top-level port contract changed")
    raw = (ROOT / "src/config.json").read_bytes()
    require(hashlib.sha256(raw).hexdigest() ==
            "4b192dffa877dcefa4ab969af9dedf105375921aa179c677524fa88ac94bb510",
            "template config changed; review/document before updating this guard")
    require(project["clock_hz"] * json.loads(raw)["CLOCK_PERIOD"] == 1_000_000_000,
            "metadata/config clock targets disagree")
    for workflow in (ROOT / ".github/workflows").iterdir():
        if workflow.suffix not in (".yml", ".yaml"):
            continue
        # BaseLoader avoids YAML 1.1 interpreting GitHub's `on` key as True.
        data = yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)
        require(set(data["on"]) == {"workflow_dispatch"}, f"automatic trigger: {workflow.name}")
        for name, job in data["jobs"].items():
            require(job.get("if") == "${{ false }}", f"CI not paused: {workflow.name}/{name}")
            for step in job.get("steps", []):
                action = step.get("uses", "")
                if action.startswith("TinyTapeout/tt-gds-action"):
                    require(action.endswith("@ihp-cmos5l"), "wrong TT action branch")
    gds = yaml.load((ROOT / ".github/workflows/gds.yaml").read_text(), Loader=yaml.BaseLoader)
    require(set(gds["jobs"]) == {"gds", "precheck", "gl_test", "viewer"}, "incomplete GDS workflow")
    require(any(s.get("with", {}).get("pdk") == "ihp-sg13cmos5l"
                for s in gds["jobs"]["gds"]["steps"]), "wrong GDS PDK")
    print("PASS: CMOS5L metadata, ports, sources, unchanged config and paused workflows")


if __name__ == "__main__":
    main()
