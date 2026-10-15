#!/usr/bin/env python3
"""Does the RTL reach the same machine states MAME does?

The RTL's CPUs interleave at cycle level while MAME runs them in 166 us slices,
so the same boot takes a different number of frames in each and frame numbers do
not line up.  This asks the question that does not depend on that: for each
MAME state dump, is there an RTL dump with identical content?

    state_match.py MAME_STATE_DIR RTL_STATE_DIR [--regions bg,pal,spr,scroll]

Regions (layout of sim/oracle/hvyunit_capture.lua):
    bg      video RAM + colour RAM       0x1000..0x1800
    pal     palette hi + lo              0x1800..0x1C00
    spr     sprite RAM                   0x0000..0x1000
    scroll  scrollX, scrollY, port 0     0x1C00..0x1C03
"""
import argparse
import os
import sys

REG = {"bg": (0x1000, 0x1800), "pal": (0x1800, 0x1C00), "spr": (0x0000, 0x1000), "scroll": (0x1C00, 0x1C03)}


def load_all(d):
    out = {}
    for n in sorted(os.listdir(d)):
        if n.startswith("s") and n.endswith(".bin"):
            b = open(os.path.join(d, n), "rb").read()
            if len(b) == 0x1C10:
                out[int(n[1:-4])] = b
    return out


def key(b, regions):
    return b"".join(b[REG[r][0]:REG[r][1]] for r in regions)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("rtl")
    ap.add_argument("--regions", default="bg,pal,scroll")
    a = ap.parse_args()
    regions = a.regions.split(",")

    m, r = load_all(a.mame), load_all(a.rtl)
    rkeys = {}
    for f in sorted(r):
        rkeys.setdefault(key(r[f], regions), f)        # first RTL frame with this content

    # distinct MAME states, in order of first appearance
    seen = {}
    for f in sorted(m):
        seen.setdefault(key(m[f], regions), f)
    hit = miss = 0
    rows = []
    for k, f in seen.items():
        rf = rkeys.get(k)
        if rf is None:
            miss += 1
            rows.append((f, None))
        else:
            hit += 1
            rows.append((f, rf))
    print("MAME frames: %d (%d distinct states of %s);  RTL frames: %d" % (len(m), len(seen), "+".join(regions), len(r)))
    print("distinct MAME states the RTL also reaches: %d / %d" % (hit, len(seen)))
    print()
    print("MAME frame -> first RTL frame with identical content   (first 15 and last 8 distinct states)")
    show = rows[:15] + ([("...", "...")] if len(rows) > 23 else []) + rows[-8:] if len(rows) > 23 else rows
    for f, rf in show:
        print("  %6s -> %s" % (f, rf if rf is not None else "NOT REACHED"))
    return 0 if miss == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
