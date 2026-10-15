#!/bin/bash
# Build and run the M1 testbench.   bash sim/m1/run.sh [frames] [extra plusargs...]
#
# The Verilator build tree lives in the WSL home (the /mnt/c 9p mount is several
# times slower for the thousands of small C++ files Verilator emits).  Needs the
# RTL tree from tools/bootstrap_rtl.sh and ROM regions from
#   py -3 tools/hvyunit_roms.py split hvyunit build/hvyunit
set -eu
FRAMES="${1:-20}"; shift || true

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TP="$REPO/rtl/third_party"
ROMDIR="${ROMDIR:-$REPO/build/hvyunit}"
OBJ="${OBJ:-$HOME/hvyunit-sim/m1}"
OUT="${OUT:-$REPO/build/m1}"

export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
mkdir -p "$OBJ" "$OUT" "$OUT/state"

if [ ! -f "$TP/jt8051/jt8051.uc" ]; then echo "run tools/bootstrap_rtl.sh first"; exit 1; fi
if [ ! -f "$ROMDIR/main.bin" ];     then echo "run hvyunit_roms.py split first ($ROMDIR)"; exit 1; fi

# jt8051.vh does $readmemb("jt8051.uc") relative to the simulator's cwd
cp -f "$TP/jt8051/jt8051.uc" "$OUT/jt8051.uc"

if [ "${REBUILD:-1}" = "1" ]; then
  verilator --cc --exe --build -j 0 -O2 -CFLAGS -O2 \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE \
    -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-INITIALDLY -Wno-BLKSEQ \
    +define+SIMULATION --x-assign fast --x-initial fast \
    -Mdir "$OBJ" --top-module tb_hvyunit -o tb_hvyunit \
    -I"$TP/jt8051" \
    -y "$TP/jt12" -y "$TP/jt12/adpcm" -y "$TP/jt12/dac" -y "$TP/jt12/mixer" \
    -y "$TP/jt49" -y "$TP/jt49/filter" \
    "$REPO/sim/m1/tb_hvyunit.sv" "$REPO/sim/m1/sim_main.cpp" \
    "$REPO"/rtl/hvyunit/hvyunit_ram.sv "$REPO"/rtl/hvyunit/hvyunit_timing.sv \
    "$REPO"/rtl/hvyunit/hvyunit_mcu.sv "$REPO"/rtl/hvyunit/hvyunit_mermaid.sv \
    "$REPO"/rtl/hvyunit/hvyunit_core.sv \
    "$TP"/t80/T80s.v "$TP"/jt8051/jt8051.v "$TP"/jt8051/jt8051_alu.v "$TP"/jt8051/jt8051_ctrl.v \
    "$TP"/jt8051/jt8051_regs.v "$TP"/jt8051/jt8051_periph.v "$TP"/jt8051/jt8051_serial.v \
    "$TP"/jt12/jt03.v
fi

cd "$OUT"
echo "=== running $FRAMES frames (cwd $OUT) ==="
TRACEARG=(); [ "${TRACE:-1}" = "1" ] && TRACEARG=(+trace="$OUT/trace.log")
"$OBJ/tb_hvyunit" +rom_dir="$ROMDIR" +frames="$FRAMES" "${TRACEARG[@]}" +dump_dir="$OUT/state" "$@"
