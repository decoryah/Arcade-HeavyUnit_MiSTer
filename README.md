# Heavy Unit — MiSTer FPGA core

Kaneko / Taito 1988 horizontal shooter (`hvyunit`, `hvyunitj`, `hvyunitja`,
`hvyunitjo`, `hvyunitu`).

```
3x Z80 @ 6 MHz  +  8751 "Mermaid"  +  YM2203  +  Kaneko Pandora sprites
```

Status: **v1.0** (RBF `heavyunit_20261017.rbf`). Verified against MAME in simulation and running on a
MiSTer (DE10-Nano) with a CRT and with HDMI direct video into a RetroTINK 4K; not compared with a real
PCB (none was available). The CPU side matches MAME's RAM state frame for frame (tilemap, palette, scroll,
sprite RAM), the video is pixel-exact against an independent renderer, and the Quartus fit meets timing at
96 MHz. See [RELEASE_NOTES.md](RELEASE_NOTES.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/oracle.md](docs/oracle.md).

## Install (DE10-Nano)

| file | goes to |
|---|---|
| `heavyunit_<date>.rbf` | `/media/fat/_Arcade/cores/` |
| `mra/*.mra` | `/media/fat/_Arcade/` |
| `hvyunit.zip` (MAME 0.289, merged) | `/media/fat/games/mame/` |

The release is `releases/build4` (and `releases/heavyunit_v1.0_20261017.zip`, which unpacks onto the SD card
in that layout). Its MRAs carry `address="0x32000000"` (docs/fast-load.md): a recent Main_MiSTer loads the
game in about a second, an older one loads at the old speed. The ROM zip is not part of the release.

OSD: Aspect ratio, Scale (Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx,
Video timing (TV / MAME), CRT Adjust (H-Size, H-Position, V-Shift), DIP switches (from the MRA), SDRAM read
capture, Reset. Controls: joystick + Fire / Bomb / Start 1P / Start 2P / Coin; keyboard 1, 2 start, 5, 6 coin,
F2 service.

## Notes for particular setups

* **RetroTINK 4K, HDMI direct video:** the RT4K sorts a direct-video signal into a class by its raster (RT4K
  System Status, page 1, "Detected Mode": `MiSTer 240p`, `MiSTer 288p`, ... or `MiSTer Gen.`). The first test
  builds (raster 385 x 269) were `MiSTer Gen.`, and in that class the RT4K squashes the picture while the MiSTer
  OSD is open (it drops the decimation from 16 to 4 for the menu and keeps square pixels). The release's default
  Video timing, TV, is a 390 x 264 raster like the other cores' and the RT4K says `MiSTer 240p` (see
  docs/ARCHITECTURE.md section 14). If your RT4K still
  says `MiSTer Gen.` the old workaround is Main_MiSTer's own switch for not sending the menu flag; add to
  `MiSTer.ini`:

  ```ini
  [hvyunit]
  spd_quirk=2
  ```

  (confirmed on an RT4K, firmware 1.87.3, Auto-Decimate: Infoframe, Auto-Crop: On).
* **Video timing:** `TV 58.3 Hz` (default) is the 390 x 264 raster the RT4K likes (15.38 kHz, vsync 8
  lines, 251 lines in the HDMI picture). `MAME 58.0 Hz` is MAME's own model of the board, 404 x 256 = 58.01 Hz /
  14.85 kHz, with the vblank and sprite interrupts at the same fractions of the frame as in MAME. Only the raster
  changes (the pictures are identical); the change takes place at the start of the next frame, and the display
  may re-sync. The RT4K may classify the MAME raster as `MiSTer Gen.` again (its menu squash comes back with it);
  that has not been tried.
* **Picture size on a CRT:** the core keeps the board's proportions, 256 of 390 pixel times per line (66 %),
  smaller than a TV picture (80 %). Use the monitor's width control or the OSD's CRT Adjust (H-Size +11 for
  about 77 %). CRT Adjust is Off by default.

## Build

```powershell
py -3 tools\hvyunit_roms.py check                                  # the ROM image tool
py -3 tools\hvyunit_roms.py build hvyunit build\hvyunit.rom        # 0x2C1000-byte image
py -3 tools\gen_hvyunit_mra.py --out mra [--fast]                  # the MRAs
. .\tools\env.ps1                                                  # Quartus 17.0.2 Lite
quartus_sh --flow compile HeavyUnit
.\tools\release.ps1 -Out releases\build4 -Fast                     # RBF + MRAs
```

Set `HVYUNIT_ZIP` (or pass `--zip`) if your `hvyunit.zip` is elsewhere.
`bash tools/bootstrap_rtl.sh` (WSL) vendors the third-party cores into
`rtl/third_party` and applies `rtl/patches`.

## Verify

```powershell
.\tools\capture.ps1 -Frames 300 -Mcu -Out build\oracle\m1ref       # MAME oracle (pixels + state)
wsl bash sim/m1/run.sh 300                                         # CPUs + 8751 + YM2203
py -3 tools\state_match.py build\oracle\m1ref\state build\m1\state
wsl bash sim/emu/run_emu.sh                                        # the whole emu, through the SDRAM
py -3 tools\emu_cmp.py build\oracle\m1ref build\emu 100 150
```

## Layout

| path | |
|---|---|
| `HeavyUnit.sv`, `HeavyUnit.sdc`, `files.qip` | MiSTer top level, constraints, file list |
| `rtl/hvyunit/` | the machine |
| `target/mister/` | memory subsystem, SDRAM controller, fast-load reader |
| `modules/crt-adjust/` | rmonic79's CRT Adjust (see `modules/VENDOR.md`) |
| `rtl/third_party/`, `rtl/patches/` | T80s, jt8051 (patched), jt12, jt49 |
| `sim/` | oracle capture script and the three benches |
| `tools/` | ROM image, MRA generator, oracle/compare tools, release packaging |
| `docs/` | architecture, oracle, fast load |
| `releases/` | packaged builds (RBF, MRAs, README) |
| `ref/`, `build/` | reference checkouts and derived data (git-ignored) |

Licence: GPL-3.0 (see [LICENSE](LICENSE)), as required by the GPL-3.0 cores
this project builds on — see ARCHITECTURE.md §11 and `rtl/third_party/PROVENANCE.txt`.
