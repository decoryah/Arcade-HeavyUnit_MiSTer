#!/usr/bin/env python3
"""Compare the whole-top-level bench's pictures with the independent renderer.

    emu_cmp.py CAPDIR RGBDIR FIRST LAST [--roms DIR] [--png DIR]

RGBDIR holds f<J>.rgb (256 x 224 x 3 bytes) from sim/emu/run_emu.sh (DUMP=a:b);
J counts the raster's frames from the machine's reset release (the picture
scanned out in line-frame J).  CAPDIR is an oracle capture with state/s<F>.bin
(tools/capture.ps1).

What the monitor shows in line-frame J is, on the real board and in the RTL:

    tilemap RAM + scroll   live RAM, = the dump taken at vblank J (before the ISR)
    sprites                the Pandora snapshot of vblank J-1, drawn during the
                           vblank and shown in the next frame
    palette                live, one entry at a time, as the game writes it

which is MAME's render at vblank J.  The oracle's pixel file f<J+1> is the same
picture, except that MAME's screen:pixels() colours it with the palette of the
instant it is read, a frame later (docs/oracle.md), so f<J+1> and the bench
differ by one palette step when the game is fading.  This tool therefore
compares with the model rendered from  tilemap dump J, sprite dump J-1,
palette dump J  (hv_oracle.py's renderer, which shares no code with the RTL).
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
    ap.add_argument("first", type=int)
    ap.add_argument("last", type=int)
    ap.add_argument("--roms", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "work", "hvyunit"))
    ap.add_argument("--png")
    a = ap.parse_args()

    gt = H.Gfx(open(os.path.join(a.roms, "tiles.bin"), "rb").read())
    gs = H.Gfx(open(os.path.join(a.roms, "sprites.bin"), "rb").read())
    bad = []
    n = 0
    for j in range(a.first, a.last + 1):
        path = os.path.join(a.rgbdir, "f%05d.rgb" % j)
        if not os.path.exists(path):
            continue
        raw = open(path, "rb").read()
        if len(raw) != 256 * 224 * 3:
            bad.append((j, -1))
            continue
        rtl = [(raw[3 * i] << 16) | (raw[3 * i + 1] << 8) | raw[3 * i + 2] for i in range(256 * 224)]
        st_t, st_s = H.load_state(a.capdir, j), H.load_state(a.capdir, j - 1)
        img = H.compose(H.render_bg(st_t, gt), H.render_plane(st_s, gs), st_t.palette)
        d = sum(1 for x, y in zip(img, rtl) if x != y)
        n += 1
        if d:
            bad.append((j, d))
            if a.png:
                os.makedirs(a.png, exist_ok=True)
                H.write_png(os.path.join(a.png, "f%05d_model.png" % j), 256, 224, H.pixels_to_rgb(img))
                H.write_png(os.path.join(a.png, "f%05d_rtl.png" % j), 256, 224, H.pixels_to_rgb(rtl))
    print("frames %d..%d: %d compared, %d exact%s" % (
        a.first, a.last, n, n - len(bad),
        ("; differing: " + ", ".join("%d(%d)" % b for b in bad[:20])) if bad else ""))
    return 1 if bad or n == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
