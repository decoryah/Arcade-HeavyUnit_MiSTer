# Heavy Unit (Kaneko/Taito, 1988) � MiSTer core: architecture

Status: **built, verified against MAME, ready for hardware test** (2026-10-14). Sections 1�6
are the hardware as read from MAME's driver (`ref/mame/hvyunit.cpp`, `kan_pand.cpp`);
�7 is the layout of what was built, �8 the milestones (all met in simulation), �12 the
implementation notes (timing, fast load, CRT Adjust, Scale).

## 1. What the board is

Heavy Unit is Kaneko hardware (PCB `M6100391A/M6100392A`, "KNA-001"); Taito
published it. It is the ancestor of the DJ Boy / Air Buster boards.

| block | part | clock | notes |
|---|---|---|---|
| main CPU | Z80 ("Z80-1") | 6 MHz | IM2, 128 KB ROM in 8× 16 KB banks |
| sub CPU | Z80 ("Z80-2") | 6 MHz | video RAM, palette, scroll; 64 KB ROM, 4 banks |
| sound CPU | Z80 ("Z80-3") | 6 MHz | 64 KB ROM, 4 banks, 2 KB RAM |
| MCU "Mermaid" | Kaneko DIP40 8751, 0x0E00-byte dump | 6 MHz | coin counters/lockouts, input + DIP mux, resets the sub CPU, relays main↔sub |
| FM | YM2203 (+YM3014 DAC) | 3 MHz | mono; IRQ → sound CPU. **No OKI M6295** (DJ Boy/Air Buster have one) |
| sprites | Kaneko Pandora PX79C480FP-3 | — | 512 × 16×16 4bpp, framebuffered |
| background | 1 tilemap, 32×32 of 16×16, 4bpp | — | opaque; always under sprites |

Crystals on the PCB: 15, 16 and 12 MHz. Everything above divides from 12 MHz.
A 96 MHz system clock gives exact 6 MHz (÷16) and 3 MHz (÷32) enables.

**Corrections to what I told you earlier in the conversation**

* The palette is **512 CPU-visible entries**, not 2048. MAME allocates 0x800
  entries but the sub CPU only maps 0x200 bytes of low and 0x200 bytes of
  high palette RAM (§3.2).
* Sand Scorpion's `pandora.sv` is **not** drop-in: it is wired for a 68000
  (word addressing, one byte per word), uses 13-bit sprite codes / a 1 MB
  sprite ROM, and holds the CPU with `cpu_hold`. Heavy Unit needs a Z80 byte
  interface with a transposed address (§6.1), 14-bit codes, 2 MB.

## 2. Memory maps (all from `hvyunit.cpp`)

### 2.1 Main Z80
| range | |
|---|---|
| 0000–7FFF | ROM |
| 8000–BFFF | ROM bank, `OUT 00h`/`OUT 01h` data[2:0] → 8 banks of 16 KB |
| C000–CFFF | Pandora sprite RAM (address-swapped, §6.1) |
| D000–DFFF | RAM |
| E000–FFFF | **shared RAM** with sub CPU |

I/O (8-bit decode): `00`,`01` bank select · `02` pulse NMI on the sub CPU.

Interrupts (IM2, vector low byte supplied on the bus, `I` gives the high byte):
vector **0xFD** at scanline 240 (vblank-out), vector **0xFF** at scanline 64
(MAME: "Pandora sprite-end DMA irq? timing is likely off" — *verify*).
`HOLD_LINE`: asserted until the Z80 acknowledges.

### 2.2 Sub Z80
| range | |
|---|---|
| 0000–7FFF | ROM |
| 8000–BFFF | ROM bank, data[1:0] of `OUT 00h` → 4 banks |
| C000–C3FF | BG video RAM (tile code low byte) |
| C400–C7FF | BG colour RAM (`[7:4]` palette bank, `[3:0]` code high nibble) |
| D000–D1FF | palette **high** byte ("ext") |
| D800–D9FF | palette **low** byte |
| D200–D7FF, DA00–DFFF | plain RAM |
| E000–FFFF | shared RAM |

I/O: `00` bank select + scroll high bits · `02` → sound latch · `04` read
sub-latch / write Mermaid-latch · `06` scrollY · `08` scrollX · `0C` read
Mermaid status · `0E` acknowledge sub IRQ (any data).

`OUT 00h` byte: `[1:0]` ROM bank, **`[6]` = scrollX bit 8, `[7]` = scrollY bit 8**.
IRQ: level IRQ0 asserted at vblank start, cleared by `OUT 0Eh`. Default
mode — the data bus must read 0xFF during the acknowledge (RST 38h).

### 2.3 Sound Z80
| range | |
|---|---|
| 0000–7FFF | ROM |
| 8000–BFFF | ROM bank, `OUT 00h` data[1:0] |
| C000–C7FF | RAM |

I/O: `02`/`03` YM2203 address/data (r/w) · `04` read sound latch.
NMI = sound-latch "data pending" (clears on read). IRQ = YM2203 IRQ pin (data
bus reads 0xFF on acknowledge).

## 3. Registers and glue that are easy to get wrong

### 3.1 Latches (MAME `generic_latch_8`)
Three 8-bit latches, each with a *pending* flag set on write, cleared on read:

| latch | writer | reader | side effect |
|---|---|---|---|
| sound latch | sub `OUT 02h` | sound `IN 04h` | pending → sound NMI |
| Mermaid latch | sub `OUT 04h` | Mermaid (P0.0 low) | pending → 8051 INT0 |
| sub latch | Mermaid (P0.1 rising edge, value = P1) | sub `IN 04h` | — |

Status the sub CPU reads at `IN 0Ch`:
`bit2 = !sublatch.pending`, `bit3 = mermaidlatch.pending`.

### 3.2 Palette
Entry *i* (0–511) = `{ext[i], lo[i]}`: **R = ext[3:0], G = lo[7:4], B = lo[3:0]**
(`xRGB_444`; confirm against a MAME capture). Indices 0x000–0x0FF are
background (`colour_bank*16 + pen`), 0x100–0x1FF are sprites (`bank*16 + pen`).

## 4. Mermaid (8751) — pin-level behaviour, from `mermaid_p*_w/r`

| port | direction | meaning |
|---|---|---|
| P0 out | | `[0]` low → latch `mermaidlatch` into P1 (clears pending) · `[1]` rising → write P1 into **sublatch** · `[3:2]` input mux select · `[6:5]` DIP nibble select · `[4]` rising → latch coin counters/lockouts from P2 |
| P1 | bidirectional | data bus to/from the latches (MAME keeps a shadow byte) |
| P2 in | | `P0[3:2]`: 0 → `IN1`, 1 → `IN2`, 2 → `IN0`, 3 → 0xFF |
| P2 out | | `[0]`,`[1]` coin counters 1/2 · `[2]`,`[3]` coin lockouts 1/2 (active-low) — latched by P0.4 rising |
| P3 in | | `[7:4]` = DIP nibble selected by `P0[6:5]` (bit *n* of DSW1 low/high nibble and DSW2, §below) · `[3]` = sublatch.pending · `[2]` = !mermaidlatch.pending |
| P3 out | | **`[1]` = sub-CPU run (1) / reset (0)** |
| INT0 | in | mermaidlatch.pending |

DIP nibble for select *s* (`P0[6:5]`): `{dsw2[4+s], dsw2[0+s], dsw1[4+s], dsw1[0+s]}`.

`IN0`: start1, start2, coin1, coin2, –, –, service, –. `IN1`/`IN2`: joystick
U D L R, B1, B2 (all active-low). Heavy Unit's cabinet DIP and flip-screen
are **broken in MAME** (`MACHINE_NO_COCKTAIL`); do not target them first.

## 5. ROMs and the SDRAM image

Generated by `tools/hvyunit_roms.py` (the single source of truth — it resolves
files by **CRC** because a merged MAME zip stores each unique CRC once; e.g.
`hvyunitja`'s `b73_22.2c` is the zip's `hvyunitj/b73_28.2c`).

```
0x000000 main    128 KB      0x040000 tiles    512 KB
0x020000 sub      64 KB      0x0C0000 sprites    2 MB (gaps = 0x00)
0x030000 sound    64 KB      0x2C0000 mermaid    4 KB (0x0E00 used)
                              total   0x2C1000
```

Five sets; all produce this same layout. `hvyunitja` stores the sprite art as
four 128 KB ROMs at 0x180000+ (verified: they are the quarters of `b73_08.2f`),
so its sprite *codes* address a different region of the image than the others.

## 6. Video

MAME: 256×256 frame, visible 256×224 (rows 16–239), 58 Hz, Pandora then
tilemap composited as `black → BG tilemap (opaque) → sprites (pen 0 clear)`.
PCB measurement says HSync 15.59 kHz → ≈269 lines/frame, so **MAME's line
numbers (64, 240) are in a 256-line model** *(verify against a capture)*.

* BG scroll: `X = ((p0 & 0x40) << 2) + scrollX + 96`, `Y = ((p0 & 0x80) << 1) + scrollY`;
  both are MAME `TODO`s *(verify)*. Tile index = `row*32 + col`;
  code = `vram + ((cram & 0x0F) << 8)`, 12 bits; colour = `cram >> 4`.
* Tile pixels (BG and sprites): `gfx_8x8x4_row_2x2_group_packed_msb` —
  128 bytes per 16×16 tile = four 8×8 blocks TL, TR, BL, BR (32 bytes each),
  4 bytes per row, **high nibble = left pixel**. (Confirmed in Sand Scorpion's
  `pandora.sv` header and its `tools/decode_kaneko_gfx.py`.)

### 6.1 Pandora

4 KB RAM, 512 entries × 8 bytes (`kan_pand.cpp`):

```
byte 3  [7:4] palette bank   [2] relative position   [1] Y bit 8   [0] X bit 8
byte 4  X low        byte 5  Y low
byte 6  code low     byte 7  [7] flip X  [6] flip Y  [5:0] code high   → 14-bit code
```
`sx = sext9(x)`; with bit 2 set, `x += previous x` instead of replacing it.
Rendering happens **once per frame at vblank start** into a cleared,
double-buffered 256×256 plane; the other plane is on screen, so sprites lag
RAM by one frame. Pen 0 is transparent; later entries overwrite earlier ones.
Hvyunit never touches the clear-bitmap flag, so no sprite trails.

**Z80 address swap (the thing Sand Scorpion does not have):** CPU offset
`o = addr − 0xC000` maps to internal `{o[11], o[7:0], o[10:8]}` — i.e. sprite
`s = {o[11], o[7:0]}`, byte `b = o[10:8]`. From the CPU the table looks like 8
byte-planes of 256 sprites.

Heavy Unit uses 2 MB / 128 B = **16384 sprites → 14-bit code**. Sand Scorpion's
engine masks to 13 bits and jtgals' `CW=13`; both need widening.

## 7. Module layout

```
HeavyUnit.sv                 MiSTer `emu`: clocks, hps_io, controls, DIPs, memory, video chain, DDR3
rtl/hvyunit/
  hvyunit_core.sv            3x Z80 (T80s), RAMs, latches, IRQ/NMI, YM2203, palette, input mux
  hvyunit_mermaid.sv         8751 port glue (section 4), coin counters, sub-CPU run/reset
  hvyunit_mcu.sv             jt8051 + 4 KB program ROM + 128 B RAM, everything on cen
  hvyunit_timing.sv          390 x 264 raster: vblank line 240, sprite IRQ line 64
  hvyunit_pandora.sv         sprite engine: snapshot, per-entry fetch/draw into a plane
  hvyunit_video.sv           BG tilemap line fetch, plane read, palette -> RGB, sync/blank
  hvyunit_ram.sv             single / dual-port RAM wrappers (no_rw_check)
target/mister/
  hvyunit_mem.sv             program ROMs in BRAM, graphics in SDRAM, write FIFO, client ports
  hvyunit_fastload.sv        DDR3 -> loader replay for MRA address= (docs/fast-load.md)
  sdram_ctrl.sv              multi-port SDRAM controller (from the Gaiapolis Pocket core)
modules/crt-adjust/          rmonic79's MiSTer-CRT-Adjust (modules/VENDOR.md)
rtl/third_party/             T80s, jt8051 (+ patch), jt12/jt03, jt49 (PROVENANCE.txt)
rtl/patches/                 jt8051-hvyunit.patch (3 fixes found by the oracle)
sim/oracle/                  MAME capture script (pixels + state + I/O taps)
sim/m1/  sim/video/  sim/emu/   CPU-side bench, video-only bench, whole-`emu` bench
tools/                       ROM image, MRA generator, oracle comparison tools, release packaging
```

Memory (Cyclone V 5CSEBA6): 443 / 553 M10K blocks (3.36 Mbit, 59 %), 14.6 k ALMs (35 %),
35 DSP. Tiles (0.5 MB) and sprites (2 MB) live in SDRAM at word `(image offset - 0x40000) / 2`.

## 8. Milestones

| # | gate | |
|---|---|---|
| M0 | toolchains; ROM image tool; `jt8051` builds; MAME headless; **oracle capture + independent renderer, pixel-exact on 5 sets** (docs/oracle.md) | done |
| M1 | three Z80s + real 8751 firmware run the real ROMs; **tilemap / palette / scroll / sprite RAM identical to MAME at every frame 54-299**, 3 624 sub-CPU protocol events identical | done |
| M2 | real 8751 firmware passes: P0 handshake, DIP/input mux, sub-CPU run release (COIN ERROR was a `jt8051` bit-instruction bug, three patches) | done |
| M3 | BG + palette + Pandora: video block pixel-exact against MAME dumps; **whole `emu` through the real SDRAM controller pixel-exact against the independent renderer** (tools/emu_cmp.py) | done |
| M4 | YM2203 + mix: runs and produces samples; *not* yet compared with MAME audio | partly |
| M5 | MiSTer wrapper, SDRAM timing, 5 MRAs, Quartus fit meeting timing; **hardware bring-up pending** | partly |

## 9. Open questions

1. ~~8051 core~~ **Resolved 2026-10-14: `jt8051`.** It cannot be used from a
   bare checkout: its RTL includes `jt8051.vh` / `jt8051_param.vh`, generated by
   `jtframe ucode` (Go). Go 1.23.4 is now at `~/tools/go1.23.4` (WSL),
   `tools/gen_8051_ucode.sh` builds jtframe and generates the headers, and
   Verilator lints the whole core clean. The generator needs `JTROOT`, `CORES`,
   `JTBIN`, `JTFRAME` and `MODULES` set (the script does). The generated files
   are build outputs under `ref/`; regenerate rather than commit them.
   Fallback if ever needed: `mc8051` (VHDL) or T51, simulated with `ghdl`.
2. Real video timing and where IRQ 64/240 fall in a ≈269-line frame. No
   board is available (the KNA-001 photo is internet reference material), so
   this can only come from MAME's driver, the PCB notes in `hvyunit.cpp`
   (58 Hz / 15.59 kHz) and, if one turns up, community measurements.
3. ~~BG scroll origin (`+96`) and the sprite/BG relative offset.~~ **Resolved
   against MAME** — exact on 499 + 145 frames, including all scroll high bits
   and wrap (docs/oracle.md). MAME's own `TODO` on these is about the *real
   board*, which no capture here can settle.
4. ~~Eof→display latency.~~ **Resolved:** the sprite RAM at vblank N is drawn at
   `eof` N and shown by render N+1 (one frame). The oracle's two-frame
   appearance is `screen:pixels()` being one render stale; see docs/oracle.md.
5. ~~Is MAME installed?~~ **Yes:** 0.289 at
   `C:\repos\taitol-mister\mister\tools\mame\mame.exe` (same version as the ROM
   set; all five sets known; `hvyunit` verifies good; boots to the title screen
   headless at ~2.4× real time). `tools/mame_run.ps1` runs it with every
   writable directory redirected into `build\mame`.

## 10. Toolchain (verified 2026-10-14)

| tool | where | use |
|---|---|---|
| Quartus Prime Lite 17.0.2 | `C:\intelFPGA_lite\17.0\quartus\bin64` (not on PATH) | synthesis — `. tools\env.ps1` |
| Verilator 5.053, Icarus 14.0, ghdl, yosys | WSL Ubuntu `~/tools/oss-cad-suite/bin` | sim — `source tools/env.sh` |
| ModelSim ASE | `C:\intelFPGA_lite\17.0\modelsim_ase` | alt. simulator |
| Go 1.23.4 | WSL `~/tools/go1.23.4/go/bin` (installed 2026-10-14, SHA-256 checked against go.dev) | builds jtframe for `jt8051` microcode |
| jtframe | WSL `~/tools/jtframe-hvyunit/jtframe` (built from `ref/jtcores`) | `ucode` generator |
| MAME 0.289 | `C:\repos\taitol-mister\mister\tools\mame\mame.exe` (borrowed) | reference frames — `tools\mame_run.ps1` |
| Python | `py -3` (3.8.1), WSL `python3` | tools |

## 11. Reference material (`ref/`, git-ignored)

`Arcade-SandScrp_MiSTer` (GPL-3.0), `jtcores` sparse (cores/gals, jtframe,
jt8051; GPL-3.0), `jt12`, `jt6295`, `mame/*.cpp` (BSD-3 / LGPL-2.1+).
Clone note: `git` here needs `-c http.sslBackend=schannel` (Windows cert store).
Reusing any of the above makes this project **GPL-3.0**.

## 12. Implementation notes

**Clocking.** One 96 MHz `clk_sys`; `cen6` (/16) steps the three Z80s, the 8751's oscillator and the
dot clock, `cen3` (/32) the YM2203. A pixel is sixteen clocks wide, so the scandoubler's `ce_x4` of the
framework fires four clocks apart (HeavyUnit.sdc relies on that for the HQ2x paths).

**Raster.** Two rasters are built in and the OSD's Video timing (status[11]) picks one, taken at the start of a
frame (`hvyunit_timing` alt / alt_q, mirrored in `hvyunit_video`; CRT Adjust's V-Shift counts negative delays from
256 instead of 264 in the second): visible 256 x 224 at rows 16-239, vblank (main IRQ 0xFD) at line 240, sprite
IRQ 0xFF at line 64, vsync 8 lines from line 245, the picture 97 pixels after the hsync pulse, in both.

| Video timing | line x lines | frame | line | hsync pixels |
|---|---|---|---|---|
| TV (default) | 390 x 264 | 58.275 Hz | 15.38 kHz | 293-324 |
| MAME | 404 x 256 | 58.014 Hz | 14.85 kHz | 307-338 |

Builds up to 20261015 used 385 x 269 (57.93 Hz / 15.59 kHz, the PCB's figures, vsync 3 lines); the reason for
the TV raster is in section 14. MAME's own timing is a 256-line frame at 58 Hz, so the MAME setting puts the
two interrupts at the same fractions of the frame (64/256, 240/256) and the same cycles per frame to 0.03 %.

**What the monitor shows in line-frame J** (and what `tools/emu_cmp.py` checks): tilemap RAM live (= MAME
dump at vblank J), sprites = the Pandora snapshot of vblank J-1, palette live. MAME's pixel file J+1
is the same render coloured with the palette of one frame later; see docs/oracle.md.

**Timing closure (HeavyUnit.sdc).** The machine is built from cores designed for slower clocks that step
on enables, so the analyser's single-cycle view of their internals is 15-25 ns pessimistic at 96 MHz:

* paths whose launching *and* capturing registers are on the same cen get 8 clocks of the 16 they have
  (jt8051, the T80s, jt03), and so do the memories' read ports into the Z80 data input;
* the 8751's reset and port inputs are registered **on cen** (hvyunit_mcu.sv), so their fan-out has the
  whole interval and every register sees the release before the first enable after it;
* the SDRAM chip's clock is modelled as the machine clock inverted (generated clock, 180 degrees) with a
  two-cycle capture, as in the other MiSTer builds of this controller;
* the framework's HQ2x gets 3 clocks.

Everything sampled at the full clock rate (wrapper registers, video, the T80s' outputs into the board's
decode) stays single-cycle. Build 1 closed at +0.49 ns setup / +0.18 ns hold.

**Fast load** (docs/fast-load.md), **CRT Adjust** and **Scale** (HeavyUnit.sv, build 2): CRT Adjust is
rmonic79's module between the finished picture and `arcade_video`; with the picture 256 pixels in a
line starting 97 pixels after the hsync pulse, H-Size runs 0..+15 / -16..-1 (the end of the picture may not
pass the next line) and H-Position 0..+28 / -64..-1. Scale feeds
`video_freak` after `arcade_video` (V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+); Full Screen
with an integer Scale uses the size of the scaler as its proportions.

## 13. Test benches

| bench | what | run |
|---|---|---|
| `sim/m1` | CPUs + 8751 + YM2203 (no video): I/O trace, per-frame state dumps | `wsl bash sim/m1/run.sh 300` |
| `sim/video` | one frame of the video block from MAME state dumps | `wsl bash sim/video/run.sh CAP F...` |
| `sim/emu` | **the real `emu`** with stubbed HPS/PLL, behavioural SDRAM and DDR3: image load (streamed or fast), frames, raster geometry, CRT Adjust, Scale rule, scandoubler | `wsl bash sim/emu/run_emu.sh`, `run_b2_tests.sh` |

Compare: `tools/state_match.py`, `tools/mcu_cmp.py` (CPU side); `tools/video_cmp.py` (video block vs MAME's
pixel files); `tools/emu_cmp.py` (whole top vs the independent renderer).

## 14. What simulation cannot see (found on the first hardware run)

* **Read-during-write of inferred RAM.** The sprite plane was read and cleared in one clock. A Verilog simulator
  returns the old value; the M10K port returned the new data (Quartus reports
  `READ_DURING_WRITE_MODE_PORT_B = NEW_DATA_NO_NBE_READ` in the synthesis report), so every sprite pixel
  read as zero: backgrounds and sound were fine, no sprite, no text. The clear now happens a clock after
  the read. `+define+PLANE_RDW_NEW` (`VDEFS=` for `sim/video/run.sh` and `sim/emu/run_emu.sh`) makes the
  simulation return the new data like the block RAM, and both benches are run with it.
  Rule: never depend on which value a same-address read-and-write returns; check the RAM tables of
  `output_files/*.map.rpt` after a build.
* The OSD has "SDRAM read capture: Normal / Late" (status[10]) for SDRAM modules whose read data wants
  one more clock; the default is the setting the other cores of this controller ship with.

* **The RetroTINK 4K sorts the signal into a class by its raster.** With MiSTer direct video and the DV1
  infoframe the RT4K names the input "MiSTer 240p", "MiSTer 288p", "MiSTer 480i", "MiSTer 576i" or
  "MiSTer Gen." (generic; RT4K firmware 1.0.4 notes), and keeps settings per class. For a known class it
  compensates the decimation change that happens when the MiSTer menu opens (flag bit 2 of the DV1 SPD
  infoframe: decimation 16 -> 4); for the generic class "PAR is forced" (firmware 1.0.6 notes) and a picture
  decimated by 4 is shown with square pixels, i.e. squashed to the full width. On the first hardware run this
  core was "MiSTer Gen." (6160 x 269, 261 lines in the HDMI picture, 57.93 Hz) while Metamorphic Force is
  "MiSTer 240p" (6144 x 264, 251 lines, 59.19 Hz); both have the same DV1 flags and pixel repeat (16).
  Which of the numbers the RT4K looks at is not documented, so the raster was moved inside the envelope of
  the cores that do get "240p": 264 lines, 8 lines of vsync (251 lines in the HDMI picture, as Metamorphic
  Force), a 390-pixel line (15.38 kHz, between Metro's 15.31 and Metamorphic Force's 15.63) and a frame rate
  of 58.27 Hz (Metro: 58.23). The cost against the PCB's measured 15.59 kHz / 58 Hz is a line 1.3 % longer and
  a frame 0.5 % shorter. `[hvyunit] spd_quirk=2` in MiSTer.ini (no menu flag) remains the workaround for
  anything else that reacts to the flag.

* **Gameplay against MAME, by raster (sim/emu, PLAY=1 COIN=60 START=120, frames 100..400 every third, against
  `tools/capture.ps1 -Play -PlayCoin 60 -PlayStart 120`).** The inputs are applied in the clock the line counter
  reaches the vblank line, as the capture's frame_done does (the vsync pulse that reaches the monitor is moved by
  the framework's sync_fix by up to a line and is no reference: a press landing a few hundred clocks after the
  vblank interrupt is seen a frame later by the game's input polling, which made an earlier run diverge from
  frame 487). MAME raster (404 x 256): 99 of 101 frames bit-exact; TV raster (390 x 264): 97 of 101. The
  differing frames are 12-20 pixels on two scanlines at the right edge: the "beam" sprite (entry 0, tile 0x40)
  that the game writes to the sprite table within microseconds of the vblank, so that the snapshot takes its new
  position or the previous one depending on the Z80's phase against the vblank, and the picture shows it a frame
  late. That phase is not something MAME's CPU scheduling and the T80 reproduce to the microsecond; the PCB's
  own phase is unknown. Attract mode (frames 100..150) is exact in both rasters, and switching the raster while
  running leaves every picture exact (45 of 45 around the switch).
