#!/bin/bash
# CRT Adjust H-Size / H-Position geometry (build 2): the picture must grow and shrink about its own centre,
# keep every row, and stay inside the line.   bash sim/emu/run_hsize_tests.sh [outdir]
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$REPO/build/emu4}"
IMG="$REPO/build/hvyunit.rom"
RUN="$REPO/sim/emu/run_emu.sh"
export OBJ="${OBJ:-$HOME/hvyunit-sim/emu4}"
mkdir -p "$OUT"
HAS_FAST=1 JOBS=${JOBS:-3} bash "$RUN" "$IMG" 1 "$OUT/build" > "$OUT/build.log" 2>&1 || true
export REBUILD=0
: > "$OUT/summary.txt"
run_case() {
    local name="$1" frames="$2"; shift 2
    mkdir -p "$OUT/$name"
    echo "=== $name ($frames frames) $*" >> "$OUT/summary.txt"
    env "$@" bash "$RUN" "$IMG" "$frames" "$OUT/$name" > "$OUT/$name.log" 2>&1
    grep -E "^(PASS|FAIL)|FAIL:|CRT Adjust:|geometry" "$OUT/$name.log" >> "$OUT/summary.txt"
}
for hs in 0 5 11 15 -8 -16; do
    run_case "hs${hs}" 6 FAST=1 CRT=1 HSIZE=$hs
done
run_case hs15_pos28   6 FAST=1 CRT=1 HSIZE=15 HPOS=28
run_case hs11_posm20  6 FAST=1 CRT=1 HSIZE=11 HPOS=-20
# the picture itself: pixels unchanged with the size on
run_case hs11_pic    80 FAST=1 CRT=1 HSIZE=11 DUMP=76:79
cat "$OUT/summary.txt"
