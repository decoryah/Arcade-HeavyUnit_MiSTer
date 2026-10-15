#!/bin/bash
# Video-only bench.   bash sim/video/run.sh CAPDIR FRAME [FRAME ...]
#
# Builds the bench once, then renders each requested frame from the MAME oracle
# state dumps and writes ../work/video/f<F>.rgb; tools/video_cmp.py compares.
set -eu
CAP="$1"; shift
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROMDIR="${ROMDIR:-$REPO/../work/hvyunit}"
OBJ="${OBJ:-$HOME/hvyunit-sim/video}"
OUT="$REPO/../work/video"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
mkdir -p "$OBJ" "$OUT"

if [ "${REBUILD:-1}" = "1" ]; then
  verilator --cc --exe --build -j 0 -O2 -CFLAGS -O2 \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-MULTIDRIVEN -Wno-IMPLICIT \
    -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-BLKSEQ -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
    --x-assign fast --x-initial fast ${VDEFS:-} \
    -Mdir "$OBJ" --top-module tb_video -o tb_video \
    "$REPO/sim/video/tb_video.sv" "$REPO/sim/video/sim_main.cpp" \
    "$REPO/rtl/hvyunit/hvyunit_timing.sv" "$REPO/rtl/hvyunit/hvyunit_pandora.sv" \
    "$REPO/rtl/hvyunit/hvyunit_video.sv"
fi

for F in "$@"; do
  "$OBJ/tb_video" +cap="$CAP" +roms="$ROMDIR" +frame="$F" +out="$OUT/f$(printf %05d "$F").rgb"
done
