#!/bin/bash
# The OSD's Video timing option (status[11]): 0 = "TV" 390 x 264, 1 = "MAME" 404 x 256, taken at a frame's start.
# Every case checks the frame period, the rows and lines of the picture, and (with DUMP) the picture itself against
# tools/emu_cmp.py. The CRT Adjust cases check that V-Shift moves the picture by the same number of lines in both.
#   bash sim/emu/run_raster_tests.sh [outdir]       (rebuilds the bench once, then runs every case)
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO/../work/emu8}"
IMG="$REPO/../work/hvyunit.rom"
RUN="$REPO/sim/emu/run_emu.sh"
export OBJ="${OBJ:-$HOME/hvyunit-sim/emu8}"
mkdir -p "$OUT"
HAS_FAST=1 JOBS=${JOBS:-3} bash "$RUN" "$IMG" 1 "$OUT/build" > "$OUT/build.log" 2>&1 || true
export REBUILD=0
: > "$OUT/summary.txt"
run_case() {
    local name="$1" frames="$2"; shift 2
    mkdir -p "$OUT/$name"
    echo "=== $name ($frames frames) $*" >> "$OUT/summary.txt"
    env "$@" bash "$RUN" "$IMG" "$frames" "$OUT/$name" > "$OUT/$name.log" 2>&1
    grep -E "^(PASS|FAIL)|FAIL:|CRT Adjust:|geometry|frame period|frame periods|loader check|frames after" "$OUT/$name.log" >> "$OUT/summary.txt"
}
# the pictures: TV (default) and MAME
run_case tv     154 FAST=1 DUMP=100:150
run_case mame   154 FAST=1 RASTER=1 DUMP=100:150
# the scandoubler and the CRT Adjust paths in the MAME raster
run_case mame_sd   12 FAST=1 RASTER=1 FX=2
run_case mame_crt0 12 FAST=1 RASTER=1 CRT=1 HSIZE=11
for vs in 5 -6; do
    run_case tv_crt_vs$vs   12 FAST=1 CRT=1 HSIZE=11 VSHIFT=$vs
    run_case mame_crt_vs$vs 12 FAST=1 RASTER=1 CRT=1 HSIZE=11 VSHIFT=$vs
done
# a change of the option while the machine runs: a whole frame of the first raster, then the second, no broken picture
run_case switch 60 FAST=1 RASTER_AT=25
cat "$OUT/summary.txt"
