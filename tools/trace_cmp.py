#!/usr/bin/env python3
"""Compare two Z80 I/O traces in taps.log format (MAME capture vs RTL testbench).

Per CPU it aligns the sequences of (r|w, port, data) and reports the first
divergence with context, how many events agree before it, and how far apart
in raster position the agreeing events were.

    trace_cmp.py MAME_TAPS.log RTL_TRACE.log [--cpu main,sub,snd] [--context N]
                 [--ignore-read-data PORTS]    e.g.  sub:0c   to skip a status port

Line format:  <r|w> <main|sub|snd> F vpos port data pc
Anything else (F markers, 's'/'v' video-write taps, RESET) is ignored.
Standard library only.
"""
import argparse
import collections
import sys


def parse(path, collapse=False, drop=()):
    """cpu -> [(kind, port, data, F, vpos)].  With collapse, a run of identical
    READS (a polling loop) becomes one event: how many times a Z80 spins on a
    status port depends on exact instruction timing, which MAME's coarse
    scheduler and an RTL clock edge do not share, whereas the SEQUENCE of
    values it observes is protocol and must agree."""
    ev = collections.defaultdict(list)
    with open(path) as fh:
        for ln in fh:
            p = ln.split()
            if len(p) < 6 or p[0] not in ("r", "w") or p[1] not in ("main", "sub", "snd"):
                continue
            try:
                e = (p[0], int(p[4], 16), int(p[5], 16), int(p[2]), int(p[3]))
            except ValueError:
                continue
            if (p[1], e[1]) in drop:        # e.g. ("sub", 0x0c): a status port
                continue
            lst = ev[p[1]]
            if collapse and e[0] == "r" and lst and lst[-1][:3] == e[:3]:
                continue
            lst.append(e)
    return ev


def fmt(e):
    return "%s port %02x data %02x   (frame %d line %d)" % (e[0], e[1], e[2], e[3], e[4])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref")
    ap.add_argument("dut")
    ap.add_argument("--cpu", default="main,sub,snd")
    ap.add_argument("--context", type=int, default=4)
    ap.add_argument("--ignore-read-data", default="", help="comma list of cpu:port (hex) whose READ data is not compared")
    ap.add_argument("--collapse", action="store_true", help="merge runs of identical reads (polling loops)")
    ap.add_argument("--drop", default="", help="comma list of cpu:port (hex) removed entirely, e.g. sub:0c for status polling")
    a = ap.parse_args()
    drop = set()
    for item in [x for x in a.drop.split(",") if x]:
        c, _, pt = item.partition(":")
        drop.add((c, int(pt, 16)))

    ignore = set()
    for item in [x for x in a.ignore_read_data.split(",") if x]:
        c, _, pt = item.partition(":")
        ignore.add((c, int(pt, 16)))

    ref, dut = parse(a.ref, a.collapse, drop), parse(a.dut, a.collapse, drop)
    rc = 0
    for cpu in a.cpu.split(","):
        r, d = ref.get(cpu, []), dut.get(cpu, [])
        n = min(len(r), len(d))
        first = None
        for i in range(n):
            x, y = r[i], d[i]
            same = x[0] == y[0] and x[1] == y[1] and (
                x[2] == y[2] or (x[0] == "r" and (cpu, x[1]) in ignore))
            if not same:
                first = i
                break
        agree = first if first is not None else n
        print("== %s: MAME %d events, RTL %d events, %d agree from the start%s" % (
            cpu, len(r), len(d), agree, "" if first is not None else "  (no divergence in the common range)"))
        # raster-line offset of agreeing events (same frame number assumed comparable)
        if agree:
            offs = [d[i][4] - r[i][4] for i in range(agree) if d[i][3] == r[i][3]]
            if offs:
                offs.sort()
                print("   line offset RTL-MAME over agreeing events: min %d  median %d  max %d  (n=%d)" % (
                    offs[0], offs[len(offs) // 2], offs[-1], len(offs)))
        if first is not None:
            rc = 1
            lo = max(0, first - a.context)
            print("   first divergence at event #%d:" % first)
            for i in range(lo, min(n, first + a.context + 1)):
                mark = ">>" if i == first else "  "
                print("   %s #%d  MAME %-48s | RTL %s" % (mark, i, fmt(r[i]), fmt(d[i])))
        elif len(r) != len(d):
            rc = rc  # a length difference alone is just a different run length
    return rc


if __name__ == "__main__":
    sys.exit(main())
