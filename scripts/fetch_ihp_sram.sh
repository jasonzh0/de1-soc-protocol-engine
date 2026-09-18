#!/usr/bin/env bash
# Download only the pinned, Apache-2.0 IHP model/timing views for local checks.
# Build artifacts stay outside submission RTL. No PDK installation or CI change.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=2bbec755dc67ca3db0261c3d6163e15735d66710
base="https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/$revision"
destination=build/ihp-sram
mkdir -p "$destination"
for item in \
  ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_1024x32_c2_bm_bist.v \
  ihp-sg13g2/libs.ref/sg13g2_sram/verilog/RM_IHPSG13_1P_core_behavioral_bm_bist.v \
  ihp-sg13g2/libs.ref/sg13g2_sram/lib/RM_IHPSG13_1P_1024x32_c2_bm_bist_typ_1p20V_25C.lib \
  ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
do
  curl --fail --location --retry 2 --silent --show-error "$base/$item" -o "$destination/${item##*/}"
done
