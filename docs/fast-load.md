# Fast load

The ROM image is 0x2C1000 bytes (2.7 MB). Streamed through the HPS download
port a byte at a time it takes 23–25 s; with `address="0x32000000"` on the
MRA's `<rom index="0">` it takes about a second.

## What Main_MiSTer does

For a `<rom>` with an `address=` attribute Main_MiSTer assembles the image as
usual, copies the whole thing into the DDR3 at that physical address in one
go, and then ends a download that carries **no data bytes**: the download
starts with `ioctl_addr` set to the image's length (an ordinary download starts
at 0) and ends one count later. It needs a recent Main_MiSTer; an older one
ignores the attribute and streams the bytes as before, at the old speed — the
core takes both paths.

## What the core does (`HeavyUnit.sv`, `target/mister/hvyunit_fastload.sv`)

* at the start of an index-0 download, `ioctl_addr != 0` marks it as a fast one
  (`fast_dl`) and latches the length;
* the machine stays in reset from then until the replay is done (`fl_done`);
* when the empty download ends, `hvyunit_fastload` reads the image back from
  DDR3 byte 0x32000000 in 32-beat (256-byte) Avalon bursts into a small
  buffer and writes it, byte by byte, into the same loader port the HPS
  streams through (`hvyunit_mem` `dl_*`), honouring its `dl_wait`. The layout
  in the SDRAM, the block-RAM ROMs and the 8751's firmware port are therefore
  those of a streamed load, byte for byte;
* the replay is paced by the loader's SDRAM write path (a word every few
  clocks), not by the DDR3: about 0.1 s of the second.

The DDR3 window is the core's 256 MB at byte 0x30000000 (`DDRAM_ADDR[28:25]
== 3`); 0x32000000 is 0x400000 64-bit beats into it.

## Verification

`sim/emu/run_emu.sh` models the HPS side (`FAST=1`, build with `HAS_FAST=1`):
the image is copied into the behavioural DDR3 model, the empty download is
played, and the bench then checks every graphics word in the SDRAM chip model
against the image and runs frames. The picture must equal the streamed load's
frame for frame (`tools/video_cmp.py` against MAME).

## MRAs

`mra/*.mra` are written with `tools/gen_hvyunit_mra.py --fast`; the same
generator without `--fast` writes the plain ones, which work with any
Main_MiSTer.
