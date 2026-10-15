#!/usr/bin/env python3
"""Heavy Unit ROM image builder / checker.

The ROM table below is transcribed from MAME's kaneko/hvyunit.cpp (see
ref/mame/hvyunit.cpp, ROM_START blocks).  It is the ONE place in this project
that knows the ROM layout; the SDRAM image, the sim images and (later) the
.mra files must all be generated from it.

Source is a MAME *merged* set (hvyunit.zip).  A merged zip stores each unique
CRC once -- a clone's b73_22.2c, for instance, is the same bytes as the file
the zip holds as hvyunitj/b73_28.2c -- so files are resolved by CRC32, never
by name.  A wrong or missing file therefore fails loudly.

Image layout (one flat byte stream, identical for every set):

    0x000000  maincpu   128 KB   Z80, 16 KB banks at 0x8000
    0x020000  subcpu     64 KB   Z80, 16 KB banks at 0x8000
    0x030000  soundcpu   64 KB   Z80, 16 KB banks at 0x8000
    0x040000  tiles     512 KB   background, 16x16 4bpp
    0x0C0000  sprites     2 MB   Pandora, 16x16 4bpp (gaps are 0x00, as MAME)
    0x2C0000  mermaid     4 KB   8751 firmware (0x0E00 bytes, zero padded)
    ---------
    0x2C1000  total

Usage:
    hvyunit_roms.py list
    hvyunit_roms.py check [--zip PATH]
    hvyunit_roms.py build SET OUT.bin [--zip PATH]
    hvyunit_roms.py split SET OUTDIR  [--zip PATH]

Written to run on Python 3.5+ (no f-strings).
"""
import argparse
import os
import sys
import zipfile
import zlib

DEFAULT_ZIP = r"R:\Games\Arcade\MAME 0.289 ROMs (merged)\hvyunit.zip"

# region -> (base in image, size)
REGIONS = [
    ("main",    0x000000, 0x020000),
    ("sub",     0x020000, 0x010000),
    ("sound",   0x030000, 0x010000),
    ("tiles",   0x040000, 0x080000),
    ("sprites", 0x0C0000, 0x200000),
    ("mermaid", 0x2C0000, 0x001000),
]
IMAGE_SIZE = 0x2C1000
REGION = dict((n, (b, s)) for n, b, s in REGIONS)

K64, K128, K512 = 0x10000, 0x20000, 0x80000

# (region, mame file name, offset inside region, size, crc32)
_COMMON_SOUND = ("sound", "b73_12.7e", 0, K64, 0xd1d24fab)
_MERMAID      = ("mermaid", "mermaid.bin", 0, 0x0e00, 0x88c5dd27)
_TILES        = ("tiles", "b73_09.2p", 0, K512, 0x537c647f)

# sprite ROMs shared by hvyunit / hvyunitjo
_SPR_OLD = [
    ("sprites", "b73_08.2f", 0x000000, K512, 0xf83dd808),
    ("sprites", "b73_07.2c", 0x100000, K64,  0x5cffa42c),
    ("sprites", "b73_06.2b", 0x120000, K64,  0xa98e4aea),
    ("sprites", "b73_01.1b", 0x140000, K64,  0x3a8a4489),
    ("sprites", "b73_02.1c", 0x160000, K64,  0x025c536c),
    ("sprites", "b73_03.1d", 0x180000, K64,  0xec6020cf),
    ("sprites", "b73_04.1f", 0x1a0000, K64,  0xf7badbb2),
    ("sprites", "b73_05.1h", 0x1c0000, K64,  0xb8e829d2),
]
# sprite ROMs shared by hvyunitj / hvyunitu
_SPR_NEW = [
    ("sprites", "b73_08.2f", 0x000000, K512, 0xf83dd808),
    ("sprites", "b73_28.2c", 0x100000, K128, 0xa02e08d6),
    ("sprites", "b73_27.2b", 0x120000, K128, 0x8708f97c),
    ("sprites", "b73_25.0b", 0x140000, K128, 0x2f13f81e),
    ("sprites", "b73_26.0c", 0x160000, K64,  0xb8e829d2),
]

SETS = {
    "hvyunit": {   # Heavy Unit (World)
        "title": "Heavy Unit (World)",
        "roms": [
            ("main", "b73_10.5c", 0, K128, 0xca52210f),
            ("sub",  "b73_11.5p", 0, K64,  0xcb451695),
            _COMMON_SOUND, _MERMAID, _TILES,
        ] + _SPR_OLD,
    },
    "hvyunitj": {  # Japan, newer
        "title": "Heavy Unit (Japan, newer)",
        "roms": [
            ("main", "b73_30.5c", 0, K128, 0x600af545),
            ("sub",  "b73_14.5p", 0, K64,  0x0dfb51d4),
            _COMMON_SOUND, _MERMAID, _TILES,
        ] + _SPR_NEW,
    },
    "hvyunitja": { # Japan, alternate ROM format (sprite data moved to 0x180000+)
        "title": "Heavy Unit (Japan, alternate ROM format)",
        "roms": [
            ("main", "b73_24.5c", 0, K128, 0x60122f5a),
            ("sub",  "b73_14.5p", 0, K64,  0x0dfb51d4),
            _COMMON_SOUND, _MERMAID,
            ("tiles", "b73_23.2p", 0, K512, 0x537c647f),
            ("sprites", "b73_22.2c", 0x100000, K128, 0xa02e08d6),
            ("sprites", "b73_21.2b", 0x120000, K128, 0x8708f97c),
            ("sprites", "b73_15.0b", 0x140000, K128, 0x2f13f81e),
            ("sprites", "b73_16.0c", 0x160000, K64,  0xb8e829d2),
            ("sprites", "b73_17.0d", 0x180000, K128, 0xa8ec5309),
            ("sprites", "b73_18.0f", 0x1a0000, K128, 0xdc955a69),
            ("sprites", "b73_19.0h", 0x1c0000, K128, 0x2fb1b3e3),
            ("sprites", "b73_20.0k", 0x1e0000, K128, 0x0662d0dd),
        ],
    },
    "hvyunitjo": { # Japan, older
        "title": "Heavy Unit (Japan, older)",
        "roms": [
            ("main", "b73_13.5c", 0, K128, 0xe2874601),
            ("sub",  "b73_14.5p", 0, K64,  0x0dfb51d4),
            _COMMON_SOUND, _MERMAID, _TILES,
        ] + _SPR_OLD,
    },
    "hvyunitu": {  # USA
        "title": "Heavy Unit -U.S.A. Version- (US)",
        "roms": [
            ("main", "b73_34.5c", 0, K128, 0x05c30a90),
            ("sub",  "b73_35.6p", 0, K64,  0xaed1669d),
            _COMMON_SOUND, _MERMAID, _TILES,
        ] + _SPR_NEW,
    },
}


def load_by_crc(zip_path):
    """Return {crc32: bytes} for every member of the zip (directories skipped)."""
    out = {}
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if info.filename.endswith("/"):
                continue
            data = z.read(info.filename)
            crc = zlib.crc32(data) & 0xffffffff
            if crc != info.CRC:
                raise SystemExit("zip member %s fails its own CRC" % info.filename)
            out[crc] = data
    return out


def build_regions(setname, by_crc):
    """Return {region: bytearray} for one set; raises SystemExit on any problem."""
    if setname not in SETS:
        raise SystemExit("unknown set %r (have: %s)" % (setname, ", ".join(sorted(SETS))))
    regions = dict((n, bytearray(s)) for n, (b, s) in REGION.items())
    used = dict((n, []) for n in regions)          # (start, end, name) to catch overlaps
    for region, name, off, size, crc in SETS[setname]["roms"]:
        data = by_crc.get(crc)
        if data is None:
            raise SystemExit("%s: %s (crc %08x) not found in zip" % (setname, name, crc))
        if len(data) != size:
            raise SystemExit("%s: %s is %d bytes, table says %d" % (setname, name, len(data), size))
        if off + size > len(regions[region]):
            raise SystemExit("%s: %s overruns region %s" % (setname, name, region))
        for s0, s1, other in used[region]:
            if off < s1 and s0 < off + size:
                raise SystemExit("%s: %s overlaps %s in %s" % (setname, name, other, region))
        used[region].append((off, off + size, name))
        regions[region][off:off + size] = data
    return regions


def build_image(regions):
    img = bytearray(IMAGE_SIZE)
    for name, base, size in REGIONS:
        img[base:base + size] = regions[name]
    return img


def cmd_list(args):
    for s in sorted(SETS):
        print("%-10s %s" % (s, SETS[s]["title"]))
        for region, name, off, size, crc in SETS[s]["roms"]:
            print("    %-8s %-10s +%06x  %6x  %08x" % (region, name, off, size, crc))


def cmd_check(args):
    by_crc = load_by_crc(args.zip)
    print("%s: %d unique CRCs" % (args.zip, len(by_crc)))
    ok = True
    first_sprites = None
    for s in sorted(SETS):
        regions = build_regions(s, by_crc)
        img = build_image(regions)
        crc = zlib.crc32(bytes(img)) & 0xffffffff
        print("  %-10s ok   image crc32 %08x  (%d bytes)" % (s, crc, len(img)))
    # the alternate-format set carries the SAME sprite art as the parent, moved:
    # b73_17..20 are the four 128 KB quarters of b73_08.2f
    p = by_crc[0xf83dd808]
    q = b"".join(by_crc[c] for c in (0xa8ec5309, 0xdc955a69, 0x2fb1b3e3, 0x0662d0dd))
    same = (p == q)
    print("  b73_17..20 == b73_08.2f : %s" % ("yes" if same else "NO"))
    return 0 if same else 1


def cmd_build(args):
    img = build_image(build_regions(args.set, load_by_crc(args.zip)))
    with open(args.out, "wb") as f:
        f.write(img)
    print("%s -> %s (%d bytes, crc32 %08x)" % (
        args.set, args.out, len(img), zlib.crc32(bytes(img)) & 0xffffffff))
    return 0


def cmd_split(args):
    regions = build_regions(args.set, load_by_crc(args.zip))
    os.makedirs(args.outdir, exist_ok=True)
    for name, base, size in REGIONS:
        path = os.path.join(args.outdir, "%s.bin" % name)
        with open(path, "wb") as f:
            f.write(regions[name])
        print("%-8s %7d bytes -> %s" % (name, size, path))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    sub.required = True

    def add_zip(p):
        p.add_argument("--zip", default=os.environ.get("HVYUNIT_ZIP", DEFAULT_ZIP),
                       help="merged hvyunit.zip (default: $HVYUNIT_ZIP or %s)" % DEFAULT_ZIP)

    sub.add_parser("list").set_defaults(fn=cmd_list)
    p = sub.add_parser("check"); add_zip(p); p.set_defaults(fn=cmd_check)
    p = sub.add_parser("build"); p.add_argument("set"); p.add_argument("out"); add_zip(p); p.set_defaults(fn=cmd_build)
    p = sub.add_parser("split"); p.add_argument("set"); p.add_argument("outdir"); add_zip(p); p.set_defaults(fn=cmd_split)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
