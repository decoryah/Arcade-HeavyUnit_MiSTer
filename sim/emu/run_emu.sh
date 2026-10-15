#!/bin/bash
# End-to-end bench of the MiSTer top level (HeavyUnit.sv): hps_io and the PLL stubbed, everything else real.
#
#   sim/emu/run_emu.sh [image] [frames, default 120] [out dir, default build/emu]
#
# image defaults to build/hvyunit.rom (py -3 tools/hvyunit_roms.py build hvyunit ...).  Environment:
#   DUMP=a:b[:step]  frames to write as <out>/f<F>.rgb, in the MAME oracle's numbering (tools/video_cmp.py compares)
#   PLAY=1           replay the oracle's coin / start / right / fire stimulus (COIN=420 START=480)
#   FAST=1           model the MRA's address= attribute (build 2; build with HAS_FAST=1)
#   REBUILD=0        reuse the last Verilator build
#   VDEFS=+define+PLANE_RDW_NEW   make the sprite plane RAM behave like the M10K (a read of a written address
#                    returns the new data); without it a simulator gives the old data
#   SCALE / AR / HW / HH / FX / CRT   OSD options and the scaler's size (build 2)
#
# The Verilator build tree lives in the WSL home (the /mnt/c mount is far slower for the C++ Verilator emits).
set -eu
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG="${1:-$REPO/build/hvyunit.rom}"
FR="${2:-120}"
OUT="${3:-$REPO/build/emu}"
OBJ="${OBJ:-$HOME/hvyunit-sim/emu}"
TP="$REPO/rtl/third_party"
S="$REPO/sys"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
mkdir -p "$OBJ" "$OUT"
[ -f "$IMG" ] || { echo "no image $IMG"; exit 2; }
[ -f "$TP/jt8051/jt8051.uc" ] || { echo "run tools/bootstrap_rtl.sh first"; exit 1; }

if [ "${REBUILD:-1}" = "1" ]; then
  # The framework's video_mixer.sv declares R_in/G_in/B_in inside an unnamed generate block and uses them outside it.
  # Quartus accepts that (every MiSTer core builds with it); Verilator takes them for undeclared implicit wires nothing
  # drives, and the picture comes out black.  The bench builds a copy with the wires declared at module level (for
  # GAMMA=1, HALF_DEPTH=0 -- arcade_video with DW=24): sys/ is untouched.
  python3 - "$S/video_mixer.sv" "$OBJ/video_mixer_sim.sv" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
  cp -f "$TP/jt8051/jt8051.uc" "$OBJ/jt8051.uc"
  # jt8051.vh does $readmemb("jt8051.uc") relative to the simulator's cwd (the run below)
  verilator --cc --exe --build -j "${JOBS:-8}" -O2 -CFLAGS -O2 \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-PROCASSWIRE -Wno-INITIALDLY -Wno-BLKSEQ \
    +define+SIMULATION ${VDEFS:-} --x-assign fast --x-initial fast \
    -I"$REPO" -I"$REPO/rtl" -I"$TP/jt8051" \
    -y "$TP/jt12" -y "$TP/jt12/adpcm" -y "$TP/jt12/dac" -y "$TP/jt12/mixer" -y "$TP/jt49" -y "$TP/jt49/filter" \
    ${HAS_FAST:+-CFLAGS -DHAS_FAST} \
    --top-module tb_emu_top --prefix Vtb_emu_top -Mdir "$OBJ" -o Vtb_emu_top \
    "$REPO/HeavyUnit.sv" \
    "$REPO"/rtl/hvyunit/hvyunit_ram.sv "$REPO"/rtl/hvyunit/hvyunit_timing.sv \
    "$REPO"/rtl/hvyunit/hvyunit_mcu.sv "$REPO"/rtl/hvyunit/hvyunit_mermaid.sv \
    "$REPO"/rtl/hvyunit/hvyunit_pandora.sv "$REPO"/rtl/hvyunit/hvyunit_video.sv "$REPO"/rtl/hvyunit/hvyunit_core.sv \
    "$TP"/t80/T80s.v "$TP"/jt8051/jt8051.v "$TP"/jt8051/jt8051_alu.v "$TP"/jt8051/jt8051_ctrl.v \
    "$TP"/jt8051/jt8051_regs.v "$TP"/jt8051/jt8051_periph.v "$TP"/jt8051/jt8051_serial.v "$TP"/jt12/jt03.v \
    "$REPO"/target/mister/hvyunit_mem.sv "$REPO"/target/mister/sdram_ctrl.sv "$REPO"/target/mister/hvyunit_fastload.sv \
    "$REPO"/modules/crt-adjust/crt_adjust.sv \
    "$S"/arcade_video.v "$OBJ"/video_mixer_sim.sv "$S"/scandoubler.v "$S"/scanlines.v "$S"/gamma_corr.sv \
    "$S"/hq2x.sv "$S"/video_freezer.sv "$S"/video_freak.sv "$S"/math.sv \
    "$REPO"/sim/emu/hps_io_stub.sv "$REPO"/sim/emu/pll_stub.sv "$REPO"/sim/emu/sync_fix.sv "$REPO"/sim/sdram_model.sv "$REPO"/sim/ddr_model.sv \
    "$REPO"/sim/emu/tb_emu_top.sv "$REPO"/sim/emu/tb_emu.cpp \
    > "$OBJ.log" 2>&1 || { grep -E "%Error" "$OBJ.log" | head -30; tail -5 "$OBJ.log"; exit 1; }
fi

cd "$OBJ"        # jt8051.uc is read relative to the cwd
echo "=== running $FR frames of $IMG (out $OUT) ==="
stdbuf -oL "$OBJ/Vtb_emu_top" "$IMG" "$FR" "$OUT"
