#!/bin/bash
# Populate rtl/third_party/ from the reference checkouts under ref/.
#
#   bash tools/bootstrap_rtl.sh          (inside WSL; needs Go for the 8051 microcode)
#
# Everything here is GPL-3.0(-or-later) from jotego's repos; see PROVENANCE.txt
# written next to the copies.  rtl/third_party/ is git-ignored: it is
# regenerated, never edited by hand.  The one local change (port-write strobes
# on jt8051) lives in rtl/patches/ and is applied here.
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$REPO/ref"
OUT="$REPO/rtl/third_party"
PATCHES="$REPO/rtl/patches"

for d in jtcores jt12 jt49; do
  [ -d "$REF/$d" ] || { echo "missing $REF/$d -- see docs/ARCHITECTURE.md (Reference material)"; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/t80" "$OUT/jt8051" "$OUT/jt12" "$OUT/jt49"

# --- Z80: jtframe's Verilog netlist of the T80 VHDL core (Verilator cannot read VHDL)
cp "$REF/jtcores/modules/jtframe/hdl/cpu/t80/T80s.v" "$OUT/t80/"

# --- 8051: jt8051 + generated microcode headers (tools/gen_8051_ucode.sh makes them)
J8="$REF/jtcores/modules/jt8051/hdl"
if [ ! -f "$J8/jt8051.vh" ]; then
  echo "jt8051.vh missing -> generating microcode"; bash "$REPO/tools/gen_8051_ucode.sh"
fi
cp "$J8"/jt8051*.v "$J8"/jt8051.vh "$J8"/jt8051_param.vh "$J8"/jt8051.uc "$OUT/jt8051/"

# --- YM2203: jt12 (jt03 wrapper) and its nested jt49 PSG
cp -r "$REF/jt12/hdl/." "$OUT/jt12/"
rm -rf "$OUT/jt12/deprecated" "$OUT/jt12/alt"
cp -r "$REF/jt49/hdl/." "$OUT/jt49/"
mkdir -p "$OUT/jt49/filter" && cp -r "$REF/jt49/filter/." "$OUT/jt49/filter/" 2>/dev/null || true

# The Windows checkouts under ref/ are CRLF (core.autocrlf); normalise to LF so
# patches apply and so a git diff of this tree is stable across machines.
find "$OUT" -type f \( -name '*.v' -o -name '*.vh' -o -name '*.uc' -o -name '*.sv' -o -name '*.hex' \) \
     -exec sed -i 's/\r$//' {} +

( cd "$OUT/jt8051" && patch -p1 --no-backup-if-mismatch < "$PATCHES/jt8051-hvyunit.patch" )

{
  echo "Third-party sources copied by tools/bootstrap_rtl.sh -- do not edit."
  echo "jtcores  $(git -C "$REF/jtcores" rev-parse HEAD)  (modules/jtframe/hdl/cpu/t80/T80s.v, modules/jt8051/hdl)"
  echo "jt12     $(git -C "$REF/jt12"    rev-parse HEAD)"
  echo "jt49     $(git -C "$REF/jt49"    rev-parse HEAD)"
  echo "Licences: GPL-3.0 / GPL-3.0-or-later (see each repo's LICENSE)."
  echo "Local changes: rtl/patches/jt8051-hvyunit.patch -- (1) P0-P3 SFR write strobes, (2) a not-taken JBC no longer writes ACC/B/PSW/SP/DPTR, (3) bit instructions on ACC/B/PSW/SP/DPTR write the modified byte instead of the bit value."
} > "$OUT/PROVENANCE.txt"
echo "rtl/third_party ready:"; cat "$OUT/PROVENANCE.txt"
