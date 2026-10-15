#!/usr/bin/env python3
"""Compare per-frame state dumps (state/s<F>.bin) between the MAME oracle and
the RTL testbench.  Both use the layout documented in
sim/oracle/hvyunit_capture.lua, taken at vblank start.

    state_cmp.py MAME_CAPDIR/state RTL_STATE_DIR [--frames A:B] [--show N]
"""
import argparse
import os
import sys

REGIONS = [
    ("sprite RAM", 0x0000, 0x1000),
    ("BG video RAM", 0x1000, 0x0400),
    ("BG colour RAM", 0x1400, 0x0400),
    ("palette hi", 0x1800, 0x0200),
    ("palette lo", 0x1A00, 0x0200),
    ("scrollX/scrollY/port0", 0x1C00, 0x0003),
]
SIZE = 0x1C10


def load(d, f):
    p = os.path.join(d, "s%05d.bin" % f)
    if not os.path.exists(p):
        return None
    b = open(p, "rb").read()
    return b if len(b) == SIZE else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("rtl")
    ap.add_argument("--frames")
    ap.add_argument("--show", type=int, default=12, help="list this many differing frames")
    a = ap.parse_args()

    nums = sorted(int(n[1:-4]) for n in os.listdir(a.rtl) if n.startswith("s") and n.endswith(".bin"))
    if a.frames:
        lo, _, hi = a.frames.partition(":")
        nums = [n for n in nums if (not lo or n >= int(lo)) and (not hi or n <= int(hi))]
    exact = 0
    shown = 0
    per_region = {r[0]: 0 for r in REGIONS}
    total = 0
    for f in nums:
        m, r = load(a.mame, f), load(a.rtl, f)
        if m is None or r is None:
            continue
        total += 1
        diffs = []
        for name, off, size in REGIONS:
            n = sum(1 for i in range(off, off + size) if m[i] != r[i])
            if n:
                per_region[name] += 1
                diffs.append("%s: %d bytes" % (name, n))
        if not diffs:
            exact += 1
        elif shown < a.show:
            shown += 1
            print("frame %4d  differs: %s" % (f, "; ".join(diffs)))
    print("frames compared: %d   identical: %d" % (total, exact))
    print("frames with a difference, by region: " + ", ".join(
        "%s=%d" % (k, v) for k, v in per_region.items() if v) if total - exact else "all regions identical in every frame")
    return 0 if total and exact == total else 1


if __name__ == "__main__":
    sys.exit(main())
