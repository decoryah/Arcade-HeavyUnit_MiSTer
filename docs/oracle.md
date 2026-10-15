# MAME oracle

Reference data for verifying the core: pixels MAME rendered, plus the exact
machine state those pixels were rendered from, captured from MAME 0.289.

```
MAME 0.289 --sim/oracle/hvyunit_capture.lua-->  frames/f<F>.raw   visible 256x224 pixels
                                                state/s<F>.bin    sprite RAM, BG RAM, palette, scroll
                                                taps.log          Z80 I/O + video RAM writes, with raster line
                                                index.txt
                         tools/hv_oracle.py  --  independent Python renderer + exactness check
                         tools/hv_coverage.py -- which features a capture actually exercises
```

## Running it

```powershell
.\tools\capture.ps1 -Frames 600                          # attract mode
.\tools\capture.ps1 -Frames 1500 -Play -NoTaps -Out build\oracle\play   # coin, start, hold right + autofire
.\tools\capture.ps1 -Frames 400 -Stim -StimFrom 100 -NoTaps -Out build\oracle\stim   # randomised stimulus

py -3 tools\hvyunit_roms.py split hvyunit build\hvyunit  # ROM regions the model reads
py -3 tools\hv_oracle.py check build\oracle\play --step 5 --pair 1,0,2
py -3 tools\hv_oracle.py png   build\oracle\play --frames 700:700 --out build\oracle\png
py -3 tools\hv_coverage.py build\oracle\play
```

`capture.ps1` runs MAME headless (`-video none -sound none -nothrottle`) with
every writable directory redirected into `build\mame`. A 1500-frame gameplay
capture takes about 25 s of wall clock and about 350 MB; everything under
`build\` is git-ignored because it is derived from copyrighted ROMs.

## The convention — read this before using the files

`frame_done F` fires at vblank start F, right after MAME renders. But
`screen:pixels()` hands back the bitmap rendered at the **previous** vblank,
coloured with the palette that is current when it is read. Measured, and
exact, the pixel file `f<F>.raw` is built from:

| input | taken from |
|---|---|
| tilemap RAM (video + colour RAM) and scroll registers | `state/s<F-1>.bin` |
| sprite RAM (Pandora) | `state/s<F-2>.bin` |
| palette | `state/s<F>.bin` |

The sprite lag is the one frame the driver implies: Pandora's `eof()` draws at
vblank N from RAM as it stands then, and render N+1 shows it. The tilemap/scroll
lag comes from the pixel file being the previous render. The palette is the odd
one out only because it is applied at read time.

`hv_oracle.py check` re-derives this on every run by trying all 12 pairings, so
if MAME ever changes, the table above stops winning and the tool says so.

### What the RTL bench's pictures correspond to

The whole-`emu` bench (`sim/emu`) numbers its pictures by raster frame J, counted from the machine's
reset release: the picture scanned out in line-frame J. It shows tilemap RAM live (= the state dump of
vblank J), the sprites of the Pandora snapshot of vblank J-1, and the palette live. That is MAME's render at
vblank J, i.e. the oracle's pixel file **J+1** with one difference: file J+1 is coloured with the palette of
one frame *later* (the read-time effect above). While the game fades the palette the two therefore differ by
one palette step in every pixel, which is why `tools/emu_cmp.py` compares the bench with the model rendered
from (tilemap dump J, sprite dump J-1, palette dump J) instead of with the pixel files. It matched
51 / 51 frames (100-150 of the attract mode) with no pixel different.

### Capture-order traps (all hit while building this)

* Tap handles must be globals — a local is garbage-collected and the tap stops.
* MAME re-runs `-autoboot_script` after a machine reset; the script guards with
  `_G.hv_capture_loaded`.
* `string.format("%.6f")` prints a **comma** on this machine's locale. Times in
  `index.txt` are integer microseconds for that reason.
* In stimulus mode the sprite table must be written *before* the state dump
  (Pandora's `eof()` follows `frame_done` in the same instant) and tilemap/scroll
  *after* it (the frame just rendered used their old values).

## Results

All against the model in `tools/hv_oracle.py`, which shares no code with any RTL.

| capture | set | frames checked | pixel-exact |
|---|---|---|---|
| attract + gameplay, 1500 frames | `hvyunit` | 499 (every 3rd) | **499 / 499** |
| gameplay, 600 frames each | `hvyunitj`, `hvyunitja`, `hvyunitjo`, `hvyunitu` | 40 each | **40 / 40** each |
| randomised stimulus, 400 frames | `hvyunit` | 145 | **145 / 145** |

Every one of those also confirmed what the model assumes about the hardware as
MAME implements it: BG scroll origin (`+96` X, `0` Y), the `{ext,lo}` →
`xRGB444` palette mapping, 12-bit tile codes, 14-bit sprite codes, 9-bit signed
sprite position wrap, relative-position chains, pen 0 transparent, later
entries overwrite earlier, BG opaque under sprites.

### What the captures exercise

| feature | gameplay capture | stimulus capture |
|---|---|---|
| sprite code ≥ 0x2000 (needs 14 bits) | 22,118 entries | 1,238 |
| relative-position entries | 9,341 | 1,069 |
| flip X | **0** | 1,189 |
| flip Y | 10,882 | 1,150 |
| X bit 8 / **Y bit 8** | 4,253 / **0** | 560 / 285 |
| clipped at left / right / top / bottom | 992 / 2,262 / 6 / 343 | 128 / 144 / 198 / 271 |
| scrollX bit 8 / **scrollY bit 8** | 124 frames / **0** | 12 / 9 frames |
| **scrollY** not 0/FF | **0** | 29 frames |
| sprite palette banks / tilemap palette banks | 6 of 16 / 2 of 16 | 16 / 16 |
| most sprites on screen in one frame | 137 | 92 |

Heavy Unit never uses flip X, Y bit 8 or vertical scroll in the stage the
autoplay reaches, so **only the stimulus capture covers them**. Treat the
gameplay capture as "what the real game does" and the stimulus capture as "what
the model must still get right".

## What this oracle does *not* tell you

* **It is MAME, not the board.** Where the driver is wrong or unsure
  (`TODO`s on scroll offsets, the line-64 interrupt timing, flip-screen and
  cocktail which hang MAME) the oracle inherits that.
* **MAME renders a whole frame at one instant.** Real hardware looks the palette
  up per pixel during scan-out and sees scroll changes mid-frame. The game
  rewrites **384 palette bytes spread evenly across every frame** (measured from
  `taps.log`), so an RTL that does a real-time lookup will legitimately differ
  from MAME's single-instant colours in palette-animated areas. Compare palette
  *indices* (before lookup) against the model, and verify the RAM → RGB mapping
  separately at a chosen instant.
* **Timing, not just pictures.** From the tap log, the sub CPU's vblank handler
  writes scroll and tile RAM at raster lines 1–3, the main CPU's "sprite"
  interrupt (line 64) rewrites sprite RAM, and the sub CPU acknowledges its IRQ
  between lines ~50 and ~106. Those are what a cycle-level RTL has to reproduce;
  the pixel oracle alone won't catch a wrong interrupt position until it moves a
  visible edge.
* **The Mermaid MCU is invisible here.** Its port traffic is not an address
  space, so there is no tap for it. The sub-CPU side of its latches (I/O ports
  `04h`, `0Ch`) is logged, which is enough to compare behaviour at the Z80
  boundary.

## Files

| path | |
|---|---|
| `sim/oracle/hvyunit_capture.lua` | the MAME-side script (header documents every file format) |
| `tools/capture.ps1` | runs it: `-Frames -Play -Stim -StimFrom -NoTaps -Out -Set` |
| `tools/hv_oracle.py` | `png`, `check` (renderer + pairing search) |
| `tools/hv_coverage.py` | feature coverage of a capture |
| `tools/mame_run.ps1` | sandboxed MAME launcher used by the above |
