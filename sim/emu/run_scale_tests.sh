#!/bin/bash
# The Scale option's cases of the whole-top-level bench: for every Scale / Aspect ratio / scaler size, the size
# the core asks of the scaler (VIDEO_ARX / VIDEO_ARY) must equal what the framework's rule gives for the picture
# (tb_emu.cpp). Only a few frames are needed; uses the bench build run_b2_tests.sh made (REBUILD=0).
#   bash sim/emu/run_scale_tests.sh [outdir]
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO/../work/emu2s}"
IMG="$REPO/../work/hvyunit.rom"
export OBJ="${OBJ:-$HOME/hvyunit-sim/emu2}"
export REBUILD=0
mkdir -p "$OUT"
: > "$OUT/summary.txt"
fail=0
run_case() {
    local name="$1"; shift
    env "$@" bash "$REPO/sim/emu/run_emu.sh" "$IMG" 6 "$OUT/$name" > "$OUT/$name.log" 2>&1
    grep -E "^(PASS|FAIL)|FAIL:|scale:" "$OUT/$name.log" | sed "s/^/$name: /" >> "$OUT/summary.txt"
}
for sc in 0 1 2 3 4; do
  for ar in 0 1 2 3; do
    run_case "scale${sc}_ar${ar}_1080p" FAST=1 SCALE=$sc AR=$ar HW=1920 HH=1080
  done
  run_case "scale${sc}_ar0_720p" FAST=1 SCALE=$sc AR=0 HW=1280 HH=720
  run_case "scale${sc}_ar0_4k"   FAST=1 SCALE=$sc AR=0 HW=3840 HH=2160
done
cat "$OUT/summary.txt"
grep -c "FAIL" "$OUT/summary.txt" | sed 's/^/failing lines: /'
