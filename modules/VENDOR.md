# Vendored modules

Third-party HDL copied into the tree (no submodules), each with its own LICENSE
alongside, so the build is self-contained and reproducible. The cores the
machine itself is built on (T80, jt8051, jt12, jt49) are listed with their
upstream commits in `rtl/third_party/PROVENANCE.txt`.

| module | upstream | via | licence |
|---|---|---|---|
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`; one local fix, below) | rmonic79 (Umberto Parisi), with Andrea Bogazzi (asturur); taken from the Metamorphic Force core | GPL-3.0 or later |

To update one: re-copy from upstream at the new commit and record it here.

## Local change to `crt-adjust/crt_adjust.sv`

One line, `hoff_s`: the conditional mixes `$signed(hoffset)` with an unsigned
replication, so by the Verilog rules (and in Verilator) the result is unsigned
and a negative H-Position is zero-extended (-1 becomes 511), which moves the
picture window out of the line and blanks the picture. The line now
sign-extends `hoffset` explicitly, which is what the module is meant to do and
gives the same result in every tool. Nothing else differs from upstream.
