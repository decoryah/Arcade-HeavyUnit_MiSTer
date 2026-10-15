#!/bin/bash
# The build-2 regression set of the whole-top-level bench: fast load, CRT Adjust, Scale, scandoubler.
#   bash sim/emu/run_b2_tests.sh [outdir]       (rebuilds the bench once, then runs every case)
# Each case writes <outdir>/<case>.log; a summary of PASS / FAIL lines is printed at the end.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO/build/emu2}"
IMG="$REPO/build/hvyunit.rom"
RUN="$REPO/sim/emu/run_emu.sh"
export OBJ="${OBJ:-$HOME/hvyunit-sim/emu2}"
mkdir -p "$OUT"

# build once
HAS_FAST=1 JOBS=${JOBS:-3} bash "$RUN" "$IMG" 1 "$OUT/build" > "$OUT/build.log" 2>&1 || true
export REBUILD=0

# name | frames | environment
case_run() {
    local name="$1" frames="$2"; shift 2
    mkdir -p "$OUT/$name"
    echo "=== $name ($frames frames) $*" >> "$OUT/summary.txt"
    env "$@" bash "$RUN" "$IMG" "$frames" "$OUT/$name" > "$OUT/$name.log" 2>&1
    grep -E "^(PASS|FAIL)|FAIL:|scale:|CRT Adjust:|fast load:|geometry|loader check|frame period" "$OUT/$name.log" >> "$OUT/summary.txt"
}

: > "$OUT/summary.txt"
# the picture cases: a few frames at the point where the attract mode has content
case_run base_fast    80 FAST=1 DUMP=76:79
case_run crt0         80 FAST=1 CRT=1 DUMP=76:79
case_run crt_adj      80 FAST=1 CRT=1 HSIZE=3 HPOS=-20 VSHIFT=5 DUMP=76:79
case_run crt_neg      80 FAST=1 CRT=1 HSIZE=-8 HPOS=12 VSHIFT=-6 DUMP=76:79
case_run sd_fx2       80 FAST=1 FX=2 DUMP=76:79
case_run sd_hq2x      80 FAST=1 FX=1 DUMP=76:79
# the Scale cases: only the size the core asks for matters, a few frames suffice
for sc in 0 1 2 3 4; do
  for ar in 0 1 2; do
    case_run scale_${sc}_ar${ar}     6 FAST=1 SCALE=$sc AR=$ar HW=1920 HH=1080
  done
  case_run scale_${sc}_720p          6 FAST=1 SCALE=$sc AR=0 HW=1280 HH=720
done
echo; cat "$OUT/summary.txt"
