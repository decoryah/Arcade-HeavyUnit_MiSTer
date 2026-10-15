#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares.

    check_ram_depth.py <HeavyUnit.fit.rpt> [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always (a two-dimensional unpacked array
was built shallower than declared in another core of this family, and the bug was invisible in every bench).
Run this on every fit report; it exits 1 if a listed memory is shallower than its minimum, or is missing.
Instances are matched by the name fragment; widths are not checked (a wide RAM may be several blocks side by side).
"""
import sys

# (instance name fragment, minimum words, minimum width)
EXPECT = [
    ("hvyunit_dpram:u_vram|altsyncram:mem_rtl", 1024, 8),            # tilemap code RAM, 32 x 32
    ("hvyunit_dpram:u_cram|altsyncram:mem_rtl", 1024, 8),            # tilemap colour / code-high RAM
    ("hvyunit_dpram:u_pale|altsyncram:mem_rtl", 512, 8),             # palette, 512 entries, two bytes
    ("hvyunit_dpram:u_pall|altsyncram:mem_rtl", 512, 8),
    ("hvyunit_dpram:u_shared|altsyncram:mem_rtl", 8192, 8),          # main / sub shared RAM
    ("hvyunit_dpram:u_spr|altsyncram:mem_rtl", 4096, 8),             # sprite table, 512 x 8 bytes
    ("hvyunit_ram:u_mram|altsyncram:mem_rtl", 4096, 8),
    ("hvyunit_ram:u_sra|altsyncram:mem_rtl", 2048, 8),
    ("hvyunit_ram:u_srb|altsyncram:mem_rtl", 2048, 8),
    ("hvyunit_ram:u_zram|altsyncram:mem_rtl", 2048, 8),
    ("hvyunit_mcu:u_mcu|altsyncram:iram_rtl", 128, 8),
    ("hvyunit_mcu:u_mcu|altsyncram:prom_rtl", 4096, 8),
    ("hvyunit_video:g_video.u_video|altsyncram:lbuf_rtl", 512, 8),   # two lines of 256
    ("hvyunit_video:g_video.u_video|altsyncram:plane_rtl", 57344, 8),  # the sprite plane, 224 x 256
    ("hvyunit_pandora:u_pandora|altsyncram:shadow_rtl", 4096, 8),    # the vblank snapshot of the sprite table
    ("hvyunit_pandora:u_pandora|altsyncram:tbuf_rtl", 64, 16),       # one tile, 64 words
    ("hvyunit_mem:u_mem|altsyncram:rom_main_rtl", 131072, 8),
    ("hvyunit_mem:u_mem|altsyncram:rom_sub_rtl", 65536, 8),
    ("hvyunit_mem:u_mem|altsyncram:rom_snd_rtl", 65536, 8),
    ("crt_adjust:u_crt|altsyncram:mem_rtl", 512, 24),                # CRT Adjust's line buffer
]


def main():
    path = sys.argv[1]
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin, bmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING  %-56s (expected >= %d x %d)" % (frag, wmin, bmin))
            bad += 1
            continue
        for n, w, b in hits:
            ok = w >= wmin
            if not ok:
                bad += 1
            print("%s  %-56s %6d x %-3d (>= %d)" % ("ok         " if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
