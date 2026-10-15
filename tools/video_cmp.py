#!/usr/bin/env python3
"""Compare the RTL video bench's output with MAME's pixels.

    video_cmp.py CAPDIR RGBDIR FRAME [FRAME ...] [--png DIR]

RGBDIR holds f<F>.rgb (256 x 224 x 3 bytes) from sim/video/run.sh; CAPDIR is
the oracle capture whose frames/f<F>.raw they must equal.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hv_oracle as H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capdir")
    ap.add_argument("rgbdir")
    ap.add_argument("frames", nargs="+", type=int)
    ap.add_argument("--png")
    a = ap.parse_args()

    bad = 0
    for f in a.frames:
        path = os.path.join(a.rgbdir, "f%05d.rgb" % f)
        raw = open(path, "rb").read()
        if len(raw) != 256 * 224 * 3:
            print("frame %d: RTL output is %d bytes" % (f, len(raw)))
            bad += 1
            continue
        rtl = [(raw[3 * i] << 16) | (raw[3 * i + 1] << 8) | raw[3 * i + 2] for i in range(256 * 224)]
        mame = H.read_frame(a.capdir, f)
        diff = [i for i in range(256 * 224) if rtl[i] != mame[i]]
        nonblank = len(mame) - max(__import__("collections").Counter(mame).values())
        status = "EXACT" if not diff else "%d pixels differ" % len(diff)
        extra = ""
        if diff:
            ys = sorted(set(i // 256 for i in diff))
            xs = sorted(set(i % 256 for i in diff))
            extra = "  rows %d..%d cols %d..%d" % (ys[0], ys[-1], xs[0], xs[-1])
            bad += 1
        print("frame %5d: %s   (non-blank pixels in MAME's frame: %d)%s" % (f, status, nonblank, extra))
        if a.png and diff:
            os.makedirs(a.png, exist_ok=True)
            H.write_png(os.path.join(a.png, "f%05d_mame.png" % f), 256, 224, H.pixels_to_rgb(mame))
            H.write_png(os.path.join(a.png, "f%05d_rtl.png" % f), 256, 224, H.pixels_to_rgb(rtl))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
