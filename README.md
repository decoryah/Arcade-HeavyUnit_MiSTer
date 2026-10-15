# Heavy Unit for MiSTer

Kaneko / Taito's **Heavy Unit** (1988, Kaneko hardware; sets `hvyunit`, `hvyunitj`, `hvyunitja`, `hvyunitjo`, `hvyunitu`)
for the MiSTer FPGA platform.

```
3x Z80 @ 6 MHz  +  8751 "Mermaid"  +  YM2203  +  Kaneko Pandora sprites
```

The board is a main Z80, a sub Z80 and a sound Z80 around a shared RAM, an 8751 "Mermaid" microcontroller (its firmware is
in the set), a YM2203, an opaque 32 x 32 tilemap of 16 x 16 tiles and the Pandora sprite generator, with a 512-entry
xRGB444 palette. The machine here is written from MAME 0.289's `hvyunit.cpp` and
`kan_pand.cpp` and checked against MAME; the CPUs, the 8751 and the FM chip are existing open cores (T80s, jt8051, jt03 /
jt12 and jt49 from jotego's repositories, with the local patches in `rtl/patches`), and everything around them is the
MiSTer platform layer: memories, clocks, video, audio, controls and ROM loading (`HeavyUnit.sv`, `target/mister/`,
`rtl/pll*`, `mra/`).

No ROMs or other copyrighted data are in this repository; you supply your own MAME `hvyunit.zip`.

## Status

**Run on a real MiSTer, by one tester so far.** The repository owner has played the test builds on a DE10-Nano, on a 15 kHz analog output and on HDMI direct video through a RetroTINK 4K (firmware 1.87.3): the game, sound and
controls work, and so do CRT Adjust, the Scale options and the fast loading. With the default Video timing the RT4K
classifies the signal as `MiSTer 240p` and does not squash the picture when the MiSTer OSD opens. That is one person's
test on one board, not a comparison with the arcade PCB (none was available), so please report what yours shows. The
MAME setting of Video timing, and the switch between the two, have been checked in simulation only.

Everything else below is simulation and the Quartus tool flow, against MAME 0.289 (the reference for every comparison):

* **CPU side.** The three Z80s and the 8751 match MAME's RAM state frame for frame (tilemap, palette, scroll, sprite RAM)
  through the attract mode (`sim/m1`, `tools/state_match.py`). The 8751 is jt8051 with three fixes (the port write
  strobes, a not-taken JBC, bit instructions on SFRs; `rtl/patches/jt8051-hvyunit.patch`); without them the game stopped
  at its COIN ERROR.
* **Video.** The finished picture of the whole MiSTer top level (`sim/emu`, through the SDRAM and the framework's video
  chain) is bit-exact against an independent renderer that shares no code with the RTL (`tools/hv_oracle.py`,
  `tools/emu_cmp.py`): 51 of 51 frames of the attract mode in each Video timing setting, and 45 of 45 around a switch of
  the setting while running. A gameplay run (coin, start, hold right, autofire) sampled every third frame from 100 to 400
  is bit-exact in 99 of 101 frames with the MAME setting and 97 of 101 with TV (see "Known differences from MAME").
* **Timing.** Quartus 17.0.2 Lite meets 96 MHz: setup +0.464 ns, hold +0.252 ns (`releases/*.sta.summary`).
* **RAM.** `tools/check_ram_depth.py` checks the memories Quartus built against the depths the RTL declares
  (`releases/*.ram_depths.txt`).

## Release history

**20261014** -- a test build, the first on a MiSTer: the backgrounds scrolled and the sound was right, but there were no
sprites and no text. The sprite plane was read and cleared in one clock; a Verilog simulator returns the old value for a
same-address read-and-write and the block RAM returns the new one, so every sprite pixel read as zero. It was in none of
the benches for that reason.

**20261015** -- test builds. The plane is cleared a clock after the read (and the benches run with
`+define+PLANE_RDW_NEW`, which makes the simulation behave like the block RAM). Fast loading (the MRAs carry
`address="0x32000000"`), the Scale option and rmonic79's CRT Adjust are added; H-Size runs 0..+15 and grows the picture
about its own centre, so +11 gives about 77 % of the line. Run on a MiSTer by the repository owner: they work.

**20261016** -- the raster is 390 x 264 (58.27 Hz, 15.38 kHz, vsync 8 lines) instead of the 385 x 269 the earlier builds
took from the PCB's measured figures. The RT4K sorts a direct-video signal into a class by its raster and keeps its
settings per class; the first builds were `MiSTer Gen.`, a class in which it forces square pixels and so squashed the picture
when the MiSTer OSD opened (it drops the decimation from 16 to 4 for the menu). The new raster is `MiSTer 240p`, like
the other MiSTer arcade cores', and the picture stays as it is. Checked in simulation (51 of 51 frames exact) and run
on a MiSTer with an RT4K by the repository owner.

**20261017** -- the first release. The OSD's **Video timing** chooses between that raster (TV, the default, so the behaviour
of 20261016) and MAME's own model of the board, 404 x 256 = 58.01 Hz (see the OSD options). The raster is taken at the
start of a frame, so a change never cuts one; CRT Adjust's V-Shift counts from the frame in force. Checked in simulation
(attract mode exact in both settings, 45 of 45 frames exact across a switch while running, gameplay 99 / 101 and 97 / 101,
timing +0.464 ns); the TV setting was run on a MiSTer by the repository owner and behaves as 20261016. The fitter and
timing summaries are `releases/heavyunit_20261017.fit.summary` and `.sta.summary`.

## Install

1. Unzip `HeavyUnit_MiSTer_20261017.zip` over the root of the SD card, or copy by hand the RBF
   (`releases/heavyunit_20261017.rbf`) to `/media/fat/_Arcade/cores/` and the `.mra` files from `mra/` to
   `/media/fat/_Arcade/`. Keep the RBF's `heavyunit_` name and date: MiSTer finds the core by the MRA's `<rbf>` name plus
   the date, and takes the newest if there are several, so delete older `heavyunit_*.rbf` files.
2. Put your MAME 0.289 `hvyunit.zip` in `/media/fat/games/mame/` (the parent set; the Japan and US versions' ROMs are in
   the merged set, or in `hvyunitj.zip` / `hvyunitja.zip` / `hvyunitjo.zip` / `hvyunitu.zip` next to it). No ROMs are
   distributed.
3. Start `Heavy Unit (World)` from the Arcade menu. The ROM image is 2.8 MB (`0x2C1000` bytes). With a recent
   Main_MiSTer (one that knows the MRA's `address=` attribute) it is copied to the DDR3 in one go and loaded in about a
   second; an older one streams it through the HPS port, as before, which takes longer.

### Fast loading

The five MRAs carry `address="0x32000000"` on the ROM image. A Main_MiSTer that supports that attribute copies the
assembled image into the DDR3 in one go instead of streaming it through the HPS port a byte at a time, and the core reads
it back from there into its loader (`target/mister/hvyunit_fastload.sv`). There is nothing to set. A Main_MiSTer that
ignores the attribute streams the image as before, with the same RBF and MRAs. How it works: `docs/fast-load.md`.

## OSD options

| Option | Values | |
|---|---|---|
| Aspect ratio | Original, Full Screen, [ARC1], [ARC2] | Original is 4:3 |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ | Integer scaling for the HDMI scaler (the framework's `video_freak`; the 15 kHz analog output is not touched). Normal leaves the picture as it was. |
| Scandoubler Fx | None, HQ2x, CRT 25%, CRT 50%, CRT 75% | |
| Video timing | TV 58.3 Hz, MAME 58.0 Hz | The raster; see below |
| CRT Adjust | submenu: CRT Adjust Off, On; CRT H-Size 0..+15 / -16..-1, CRT H-Position 0..+28 / -64..-1, CRT V-Shift -16..+15 | Fits the picture to a 15 kHz analog (CRT) output without the monitor losing sync: the pixel read-out rate, the picture's place in the line, and whole lines of vertical sync. Does nothing while the scandoubler is in use. Off by default. |
| DIP switches | from the MRA | The board's two DIP banks |
| SDRAM read capture | Normal, Late | Late samples SDRAM reads one clock later, for a module that answers slowly |
| Reset | | Restarts the machine (the ROM stays loaded) |

**Video timing.** `TV 58.3 Hz` (the default) is 390 x 264, 15.38 kHz, vsync 8 lines, 251 lines in the HDMI picture: inside
the range of the other cores' that the RT4K calls `MiSTer 240p`. `MAME 58.0 Hz` is MAME's own model of the board, a
256-line frame at 58 Hz (404 x 256, 14.85 kHz), with the vblank and sprite interrupts at the same fractions of the frame
as in MAME. The picture is the same; only the blanking and the sync differ, and the change takes place at the start of the
next frame (the display may re-sync). The board measures about 15.59 kHz / 58 Hz (the driver notes); TV is +0.5 % in
frame rate and -1.3 % in line rate against those figures. The RT4K may classify the MAME raster as `MiSTer Gen.` again;
that has not been tried.

**RetroTINK 4K.** If an RT4K still squashes the picture while the MiSTer OSD is open (System Status page 1, "Detected
Mode", says `MiSTer Gen.`), Main_MiSTer's switch for not sending the menu flag is a per-core fix; add to `MiSTer.ini`:

```ini
[hvyunit]
spd_quirk=2
```

**Picture size on a CRT.** The core keeps the board's proportions: 256 of 390 pixel times per line (66 %), smaller than a TV
picture (80 %). Use the monitor's width control or CRT Adjust (H-Size +11 for about 77 %; +15 is the most the line holds;
H-Size grows the picture about its own centre, H-Position moves it from there).

The game is horizontal (ROT0). On a gamepad the default mapping is A = Fire, B = Bomb, Start = Start 1P, Select = Start 2P,
R = Coin (remap it in MiSTer's usual way); from the keyboard: 1, 2 start, 5, 6 coin and F2 for the service switch, on top
of MiSTer's usual keyboard-as-joystick.

## Known differences from MAME

* **A beam sprite a frame late.** The game writes one thin sprite (entry 0, tile `0x40`) to the sprite table within
  microseconds of the vblank. Whether the vblank snapshot takes its new position or the previous one depends on the Z80's
  phase against the vblank, which neither MAME's CPU scheduling nor the T80 reproduces to the microsecond (the PCB's own
  phase is unknown), so in 2 of 101 sampled gameplay frames with the MAME setting and 4 of 101 with TV the picture shows it a
  frame late: 12-20 pixels on two scanlines at the right edge.
* **The raster.** MAME models the board as a 256-line frame at 58 Hz and has no line rate; the PCB's 15.59 kHz comes from
  the driver notes. Where the two interrupts sit in the real frame is not known (MAME itself marks the line-64 timing
  "likely off"), so the lines (64 and 240) are parameters, not facts (`rtl/hvyunit/hvyunit_timing.sv`).
* **No PCB.** Nothing here has been compared with a real Heavy Unit board.

## Repository layout

| Path | |
|---|---|
| `HeavyUnit.sv`, `HeavyUnit.q*`, `HeavyUnit.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/hvyunit/` | the machine: `hvyunit_core` (the board), `hvyunit_video`, `hvyunit_pandora`, `hvyunit_timing`, `hvyunit_mcu` / `hvyunit_mermaid` (the 8751), `hvyunit_ram` |
| `rtl/third_party/`, `rtl/patches/` | T80s, jt8051 (patched), jt12 / jt03, jt49 (`rtl/third_party/PROVENANCE.txt`) |
| `target/mister/` | the memory subsystem (`hvyunit_mem`), SDRAM controller, fast-load reader |
| `modules/` | vendored CRT Adjust (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework |
| `mra/` | the five MRAs, generated by `tools/gen_hvyunit_mra.py` |
| `sim/` | Verilator benches: the machine (`m1`), the video block (`video`), the MiSTer top level end to end (`emu`), the MAME capture script (`oracle`) |
| `tools/` | ROM image builder, MRA generator, oracle and comparison tools, `release.py` / `package.py` / `check_ram_depth.py` |
| `docs/` | `ARCHITECTURE.md`, `oracle.md`, `fast-load.md` |
| `releases/` | the tested RBFs with their fitter / timing summaries and RAM depth reports |

## Building

Quartus Prime Lite 17.0.2 (the version MiSTer's framework is built with):

```
quartus_sh --flow compile HeavyUnit
```

`tools/gen_hvyunit_mra.py --out mra --fast` regenerates the MRAs. The simulation benches need Verilator 5 and a C++
compiler, and a ROM image you build yourself from your own romset (it checks every part's CRC):

```
py -3 tools/hvyunit_roms.py build hvyunit ../work/hvyunit.rom    # 0x2C1000 bytes; HVYUNIT_ZIP or --zip names the romset
```

`tools/bootstrap_rtl.sh` (WSL) vendors the third-party cores into `rtl/third_party` and applies `rtl/patches`. To make a
release: `tools/release.py <YYYYMMDD>` copies the finished build and its summaries into `releases/`, and
`tools/package.py <YYYYMMDD>` writes the SD-card zip to `dist/` (not in the repository).

The scratch folder is `work/` beside the repository (`../work`): the ROM image, MAME captures and bench output. Nothing in it
is needed to build; the commands below regenerate it.

```
tools/capture.ps1 -Frames 300 -Mcu -Out ..\work\oracle\m1ref      # the MAME oracle (pixels + state)
wsl bash sim/m1/run.sh 300                                        # CPUs + 8751 + YM2203
py -3 tools/state_match.py ../work/oracle/m1ref/state ../work/m1/state
wsl bash sim/emu/run_emu.sh                                       # the whole MiSTer top, through the SDRAM
py -3 tools/emu_cmp.py ../work/oracle/m1ref ../work/emu 100 150
wsl bash sim/emu/run_raster_tests.sh                              # both Video timing settings, CRT Adjust, the switch
```

Run the benches from a Linux filesystem (WSL's own, not `/mnt/c`: the scripts keep their Verilator trees in `~/hvyunit-sim`);
the whole-top bench simulates at about a tenth of a MHz, so a hundred frames take about fifteen minutes.

## Credits

* **Jose Tejada (jotego)** -- T80s, jt8051, jt03 / jt12 and jt49 (GPL-3.0), the 8751 wrapper `hvyunit_mcu.sv` derived from
  JTFRAME's `jtframe_8751mcu`, and JTFRAME's MiSTer SDRAM clock phase and read-capture timing, which this core's PLL and
  controller settings follow.
* **plasticbugs** -- the Gaiapolis core for the Analogue Pocket, whose multi-port SDRAM controller (`target/mister/sdram_ctrl.sv`)
  this core takes, through the other MiSTer cores built on it.
* **Claude** (Anthropic's AI model, used through Claude Code) -- the Heavy Unit machine and the MiSTer layer, written
  together with the repository owner: the memory subsystem, the fast-load reader, the Video timing option, the MRAs, the
  simulation benches, the oracle tools and this documentation.
* **Sorgelig** and the MiSTer team -- the framework (`sys/`, GPL).
* **rmonic79** (Umberto Parisi) -- [MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust), the module behind
  the CRT Adjust options (`modules/crt-adjust/crt_adjust.sv`; GPL-3.0 or later).
* **The MAME team** -- `hvyunit.cpp` and `kan_pand.cpp`, the reference for every comparison.

## Licence

Copyright (C) 2026 decoryah. GPL-3.0, as the cores it is built on (see `LICENSE`). The vendored CRT Adjust (GPL-3.0 or later)
in `modules/` keeps its own licence (`modules/VENDOR.md`), the third-party cores in `rtl/third_party/` theirs
(`rtl/third_party/PROVENANCE.txt`), and the MiSTer framework in `sys/` is GPL (see the headers of its files).
