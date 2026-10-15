#!/usr/bin/env python3
"""Heavy Unit oracle tools: MAME capture -> PNG, and an independent renderer.

The renderer is a direct transcription of MAME's hvyunit.cpp screen_update,
kan_pand.cpp draw() and emupal's xRGB_444.  It shares no code with the RTL.
It exists to make a disagreement *attributable* (same idea as Sand Scorpion's
ss_refrender.py):

    RTL != model                       -> RTL bug
    RTL == model, model != MAME pixels -> the dump does not describe what MAME
                                          drew (a capture problem, not a core one)

Capture convention (measured, 100% pixel-exact; see docs/oracle.md).  For the
pixel file f<F> written at frame_done F:

    tilemap RAM + scroll registers  <- state dump s<F-1>
    sprite RAM (Pandora)            <- state dump s<F-2>
    palette                         <- state dump s<F>

i.e. screen:pixels() hands back the bitmap rendered at the PREVIOUS vblank,
coloured with the palette current when it is read.  `check` re-derives this
every time by trying each pairing, so a change in MAME shows up immediately.

    hv_oracle.py png   CAPDIR [--frames A:B] [--out DIR]
    hv_oracle.py check CAPDIR [--frames A:B] [--step N] [--pair 1,0,2]
                       [--roms DIR] [--save-bad DIR]

--roms is a directory made by `hvyunit_roms.py split` (tiles.bin, sprites.bin).
Standard library only; runs on Python 3.5+.
"""
import argparse
import collections
import os
import struct
import sys
import zlib

W, H = 256, 224          # visible area
VIS_Y0 = 16              # first visible row of MAME's 256-row bitmap
STATE_SIZE = 0x1C10
FRAME_BYTES = W * H * 4

# ----------------------------------------------------------------- file I/O

def write_png(path, w, h, rgb):
    """rgb: bytes, w*h*3."""
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)


def raw_to_pixels(raw):
    """u32 host-endian xRGB (little endian: B,G,R,x) -> list of 0xRRGGBB."""
    if len(raw) != FRAME_BYTES:
        raise ValueError("frame is %d bytes, expected %d" % (len(raw), FRAME_BYTES))
    out = [0] * (W * H)
    for i in range(W * H):
        j = i * 4
        out[i] = (raw[j + 2] << 16) | (raw[j + 1] << 8) | raw[j]
    return out


def pixels_to_rgb(pix):
    b = bytearray(len(pix) * 3)
    for i, p in enumerate(pix):
        b[i * 3] = (p >> 16) & 255
        b[i * 3 + 1] = (p >> 8) & 255
        b[i * 3 + 2] = p & 255
    return bytes(b)


def frame_numbers(capdir, spec):
    names = sorted(n for n in os.listdir(os.path.join(capdir, "frames")) if n.endswith(".raw"))
    nums = [int(n[1:-4]) for n in names]
    if spec:
        a, _, b = spec.partition(":")
        lo = int(a) if a else nums[0]
        hi = int(b) if b else nums[-1]
        nums = [n for n in nums if lo <= n <= hi]
    return nums


def read_frame(capdir, f):
    with open(os.path.join(capdir, "frames", "f%05d.raw" % f), "rb") as fh:
        return raw_to_pixels(fh.read())

# ------------------------------------------------------------------- state

class State(object):
    """One state/s<F>.bin.  Layout: see sim/oracle/hvyunit_capture.lua."""

    def __init__(self, blob):
        if len(blob) != STATE_SIZE:
            raise ValueError("state is %d bytes, expected %d" % (len(blob), STATE_SIZE))
        cpu_spr = blob[0x0000:0x1000]
        self.vram = blob[0x1000:0x1400]
        self.cram = blob[0x1400:0x1800]
        self.pal_ext = blob[0x1800:0x1A00]
        self.pal_lo = blob[0x1A00:0x1C00]
        self.scrollx, self.scrolly, self.port0 = blob[0x1C00], blob[0x1C01], blob[0x1C02]
        # the main Z80 reaches the Pandora RAM through an address swap:
        # CPU offset o -> internal {o[11], o[7:0], o[10:8]}
        spr = bytearray(0x1000)
        for o in range(0x1000):
            spr[((o >> 11) << 11) | ((o & 0xff) << 3) | ((o >> 8) & 7)] = cpu_spr[o]
        self.spr = bytes(spr)
        self.palette = [self._rgb(i) for i in range(0x200)]

    def _rgb(self, i):
        hi, lo = self.pal_ext[i], self.pal_lo[i]
        r, g, b = hi & 0x0f, lo >> 4, lo & 0x0f
        return ((r * 17) << 16) | ((g * 17) << 8) | (b * 17)   # pal4bit


def load_state(capdir, f):
    with open(os.path.join(capdir, "state", "s%05d.bin" % f), "rb") as fh:
        return State(fh.read())

# ---------------------------------------------------------------- renderer

class Gfx(object):
    """gfx_8x8x4_row_2x2_group_packed_msb: 128 bytes per 16x16 tile, four 8x8
    blocks TL,TR,BL,BR of 32 bytes, 4 bytes per row, high nibble = left."""

    def __init__(self, data):
        self.data = data
        self.count = len(data) // 128
        self.cache = {}

    def tile(self, code):
        code %= self.count
        t = self.cache.get(code)
        if t is None:
            d, base = self.data, code * 128
            t = [0] * 256
            for py in range(16):
                for px in range(16):
                    b = d[base + (((py >> 3) << 1) | (px >> 3)) * 32 + (py & 7) * 4 + ((px & 7) >> 1)]
                    t[py * 16 + px] = (b >> 4) if (px & 1) == 0 else (b & 15)
            self.cache[code] = t
        return t


def render_bg(st, gfx):
    """-> W*H list of palette indices 0..255 (opaque layer)."""
    sxt = ((st.port0 & 0x40) << 2) + st.scrollx + 96
    syt = ((st.port0 & 0x80) << 1) + st.scrolly
    out = [0] * (W * H)
    vram, cram = st.vram, st.cram
    for vy in range(H):
        ty = (vy + VIS_Y0 + syt) & 511
        rowbase = (ty >> 4) * 32
        py16 = (ty & 15) * 16
        o = vy * W
        for vx in range(W):
            tx = (vx + sxt) & 511
            i = rowbase + (tx >> 4)
            c = cram[i]
            pens = gfx.tile(vram[i] + ((c & 0x0f) << 8))
            out[o + vx] = (c >> 4) * 16 + pens[py16 + (tx & 15)]
    return out


def render_plane(st, gfx):
    """kan_pand draw(): 256x256, value 0 = empty, else 0x100 + bank*16 + pen."""
    plane = [0] * (256 * 256)
    x = y = 0
    spr = st.spr
    for offs in range(0, 0x1000, 8):
        col, dx, dy = spr[offs + 3], spr[offs + 4], spr[offs + 5]
        code, attr = spr[offs + 6], spr[offs + 7]
        if col & 1:
            dx |= 0x100
        if col & 2:
            dy |= 0x100
        if col & 4:
            x += dx
            y += dy
        else:
            x, y = dx, dy
        sx, sy = x & 0x1ff, y & 0x1ff
        if sx >= 256:
            sx -= 512
        if sy >= 256:
            sy -= 512
        if sx <= -16 or sx >= 256 or sy <= -16 or sy >= 256:
            continue
        flipx, flipy = attr & 0x80, attr & 0x40
        pens = gfx.tile(((attr & 0x3f) << 8) | code)
        base = 0x100 + ((col & 0xf0) >> 4) * 16
        for py in range(16):
            ty = sy + py
            if ty < 0 or ty > 255:
                continue
            srow = ((15 - py) if flipy else py) * 16
            for px in range(16):
                tx = sx + px
                if tx < 0 or tx > 255:
                    continue
                pen = pens[srow + ((15 - px) if flipx else px)]
                if pen:
                    plane[ty * 256 + tx] = base + pen
    return plane


def compose(bg, plane, palette):
    out = [0] * (W * H)
    for vy in range(H):
        pbase = (vy + VIS_Y0) * 256
        o = vy * W
        for vx in range(W):
            v = plane[pbase + vx]
            out[o + vx] = palette[v if v else bg[o + vx]]
    return out

# ------------------------------------------------------------------ commands

def cmd_png(args):
    os.makedirs(args.out, exist_ok=True)
    n = 0
    for f in frame_numbers(args.capdir, args.frames):
        write_png(os.path.join(args.out, "f%05d.png" % f), W, H, pixels_to_rgb(read_frame(args.capdir, f)))
        n += 1
    print("wrote %d PNGs to %s" % (n, args.out))
    return 0


def cmd_check(args):
    tiles = open(os.path.join(args.roms, "tiles.bin"), "rb").read()
    sprites = open(os.path.join(args.roms, "sprites.bin"), "rb").read()
    gt, gs = Gfx(tiles), Gfx(sprites)
    nums = frame_numbers(args.capdir, args.frames)
    if args.step > 1:
        nums = nums[::args.step]
    have = set(frame_numbers(args.capdir, None))

    states, bgs, planes = {}, {}, {}

    def st(f):
        if f not in states:
            states[f] = load_state(args.capdir, f)
        return states[f]

    def bg(f):
        if f not in bgs:
            bgs[f] = render_bg(st(f), gt)
        return bgs[f]

    def plane(f):
        if f not in planes:
            planes[f] = render_plane(st(f), gs)
        return planes[f]

    # (a: tilemap RAM + scroll from dump F-a, p: palette from dump F-p,
    #  b: sprite RAM from dump F-b)
    combos = [(a, p, b) for a in (0, 1) for p in (0, 1) for b in (0, 1, 2)]
    if args.pair:
        combos = [tuple(int(x) for x in args.pair.split(","))]
    exact = collections.Counter()
    best_sum = collections.Counter()
    results = []
    for f in nums:
        mame = read_frame(args.capdir, f)
        counts = collections.Counter(mame)
        nonblank = len(mame) - counts.most_common(1)[0][1]
        row = {}
        for a, p, b in combos:
            if (f - a) not in have or (f - p) not in have or (f - b) not in have:
                continue
            img = compose(bg(f - a), plane(f - b), st(f - p).palette)
            diff = sum(1 for x, y in zip(img, mame) if x != y)
            row[(a, p, b)] = diff
            if diff == 0:
                exact[(a, p, b)] += 1
            best_sum[(a, p, b)] += diff
        results.append((f, nonblank, row))
        if args.save_bad and row:
            (a, p, b), d = min(row.items(), key=lambda kv: kv[1])
            if d:
                os.makedirs(args.save_bad, exist_ok=True)
                img = compose(bg(f - a), plane(f - b), st(f - p).palette)
                write_png(os.path.join(args.save_bad, "f%05d_mame.png" % f), W, H, pixels_to_rgb(mame))
                write_png(os.path.join(args.save_bad, "f%05d_model.png" % f), W, H, pixels_to_rgb(img))
        # keep memory bounded on long captures
        for old in [k for k in states if k < f - 3]:
            states.pop(old, None); bgs.pop(old, None); planes.pop(old, None)

    print("frames checked: %d   (non-blank pixels per frame: min %d, max %d)" % (
        len(results), min(r[1] for r in results), max(r[1] for r in results)))
    print()
    print("tilemap RAM+scroll from dump F-a, palette from F-p, sprite RAM from F-b:")
    print("   a  p  b   exact frames   total differing pixels")
    for a, p, b in combos:
        print("  %2d %2d %2d   %5d / %-5d  %d" % (a, p, b, exact[(a, p, b)], len(results), best_sum[(a, p, b)]))
    winner = max(combos, key=lambda c: (exact[c], -best_sum[c]))
    print()
    print("best pairing: tilemap+scroll = F-%d, palette = F-%d, sprites = F-%d  (%d/%d exact)" % (
        winner[0], winner[1], winner[2], exact[winner], len(results)))
    bad = [(f, r[winner]) for f, nb, r in results if winner in r and r[winner]]
    if bad:
        print("frames not exact under that pairing: %s" % ", ".join("%d(%d)" % x for x in bad[:20]))
    return 0 if exact[winner] == len(results) else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True
    p = sub.add_parser("png")
    p.add_argument("capdir"); p.add_argument("--frames"); p.add_argument("--out", default="png")
    p.set_defaults(fn=cmd_png)
    p = sub.add_parser("check")
    p.add_argument("capdir"); p.add_argument("--frames")
    p.add_argument("--step", type=int, default=1, help="check every Nth frame (renders are slow in pure Python)")
    p.add_argument("--pair", help="test only one a,p,b pairing, e.g. 1,0,2 (the measured convention); 6x faster")
    p.add_argument("--roms", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "hvyunit"))
    p.add_argument("--save-bad", dest="save_bad")
    p.set_defaults(fn=cmd_check)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
