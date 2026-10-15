#!/usr/bin/env python3
"""Compare the 8751's internal RAM, frame by frame, between MAME and the RTL.

    mcu_cmp.py MAME_MCU_DIR RTL_STATE_DIR [--first N]

MAME_MCU_DIR holds m<F>.bin (sim/oracle/hvyunit_capture.lua, HV_MCU=1);
RTL_STATE_DIR holds mcu_m<F>.bin (sim/m1 testbench).  128 bytes each, taken at
vblank start.  Prints the first frames where they differ and which bytes.
"""
import argparse
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("rtl")
    ap.add_argument("--first", type=int, default=6, help="how many differing frames to list")
    ap.add_argument("--from", dest="lo", type=int, default=0)
    ap.add_argument("--to", dest="hi", type=int, default=10 ** 9)
    a = ap.parse_args()

    frames = sorted(int(n[1:-4]) for n in os.listdir(a.mame) if n.startswith("m") and n.endswith(".bin"))
    frames = [f for f in frames if a.lo <= f <= a.hi]
    shown = same = total = 0
    first_diff = None
    for f in frames:
        pm = os.path.join(a.mame, "m%05d.bin" % f)
        pr = os.path.join(a.rtl, "mcu_m%05d.bin" % f)
        if not os.path.exists(pr):
            continue
        m, r = open(pm, "rb").read(), open(pr, "rb").read()
        if len(m) != 128 or len(r) != 128:
            continue
        total += 1
        d = [i for i in range(128) if m[i] != r[i]]
        if not d:
            same += 1
            continue
        if first_diff is None:
            first_diff = f
        if shown < a.first:
            shown += 1
            print("frame %4d: %d bytes differ: %s" % (
                f, len(d), "  ".join("[%02x] M=%02x R=%02x" % (i, m[i], r[i]) for i in d[:12])))
    print("frames compared %d, identical %d, first difference at frame %s" % (total, same, first_diff))
    return 0 if same == total and total else 1


if __name__ == "__main__":
    sys.exit(main())
