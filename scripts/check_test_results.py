"""Fail even if a simulator/cocotb make version reports success on test failure."""

import sys
import xml.etree.ElementTree as ET


def main():
    root = ET.parse(sys.argv[1]).getroot()
    cases = list(root.iter("testcase"))
    if not cases or any(
        case.find(tag) is not None
        for case in cases
        for tag in ("failure", "error", "skipped")
    ):
        raise SystemExit("FAIL: missing, failed, errored, or skipped cocotb tests")
    print(f"PASS: {len(cases)} cocotb test(s)")


if __name__ == "__main__":
    main()
