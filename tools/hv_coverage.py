#!/usr/bin/env python3
"""Which hardware features does an oracle capture actually exercise?

Pixel-exactness only proves what the game used.  This counts, over a capture's
state dumps, how often each Pandora / tilemap feature appears in a *visible*
sprite entry or frame, so a "100% exact" claim can be read honestly.

    hv_coverage.py CAPDIR [--roms DIR] [--step N]
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hv_oracle as H


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capdir")
    ap.add_argument("--roms", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "hvyunit"))
    ap.add_argument("--step", type=int, default=1)
    a = ap.parse_args()

    gs = H.Gfx(open(os.path.join(a.roms, "sprites.bin"), "rb").read())
    nonempty = {}

    def tile_visible(code):
        v = nonempty.get(code)
        if v is None:
            v = any(gs.tile(code))
            nonempty[code] = v
        return v

    frames = H.frame_numbers(a.capdir, None)[::a.step]
    c = collections.Counter()
    banks, pals_used, codes = set(), set(), set()
    max_sprites = 0
    for f in frames:
        st = H.load_state(a.capdir, f)
        c["frames"] += 1
        if st.port0 & 0x40: c["frames with scrollX bit8 set"] += 1
        if st.port0 & 0x80: c["frames with scrollY bit8 set"] += 1
        if st.scrolly not in (0, 0xff): c["frames with scrollY not 0/FF"] += 1
        c["distinct bank bits seen p0&3=%d" % (st.port0 & 3)] += 0
        n = 0
        x = y = 0
        spr = st.spr
        for offs in range(0, 0x1000, 8):
            col, dx, dy, code, attr = spr[offs + 3], spr[offs + 4], spr[offs + 5], spr[offs + 6], spr[offs + 7]
            if col & 1: dx |= 0x100
            if col & 2: dy |= 0x100
            rel = bool(col & 4)
            if rel: x += dx; y += dy
            else: x, y = dx, dy
            sx, sy = x & 0x1ff, y & 0x1ff
            if sx >= 256: sx -= 512
            if sy >= 256: sy -= 512
            tile = ((attr & 0x3f) << 8) | code
            if not tile_visible(tile % gs.count):
                continue
            if sx <= -16 or sx >= 256 or sy <= -16 or sy >= 256:
                c["visible-tile entries fully off-screen"] += 1
                continue
            n += 1
            c["on-screen sprite entries"] += 1
            if rel: c["  relative-position entries"] += 1
            if attr & 0x80: c["  flip X"] += 1
            if attr & 0x40: c["  flip Y"] += 1
            if col & 1: c["  X bit 8 set"] += 1
            if col & 2: c["  Y bit 8 set"] += 1
            if sx < 0: c["  clipped at left edge"] += 1
            if sx > 240: c["  clipped at right edge"] += 1
            if sy < 16: c["  clipped at top of visible area"] += 1
            if sy > 224: c["  clipped at bottom of visible area"] += 1
            if tile >= 0x2000: c["  code >= 0x2000 (needs 14 bits)"] += 1
            banks.add((col >> 4) & 15)
            codes.add(tile)
        max_sprites = max(max_sprites, n)
        # palette banks the tilemap uses
        for i in range(1024):
            pals_used.add(st.cram[i] >> 4)
    print("capture: %s   (%d dumps)" % (a.capdir, c["frames"]))
    for k in sorted(c):
        if c[k] or not k.startswith("distinct"):
            if not k.startswith("distinct"):
                print("  %-44s %d" % (k, c[k]))
    print("  %-44s %d" % ("max on-screen sprites in one frame", max_sprites))
    print("  %-44s %s" % ("sprite palette banks used", " ".join("%x" % b for b in sorted(banks))))
    print("  %-44s %s" % ("tilemap palette banks used", " ".join("%x" % b for b in sorted(pals_used))))
    print("  %-44s %d" % ("distinct sprite codes drawn", len(codes)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
