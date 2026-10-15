# Heavy Unit for MiSTer — v1.0

Kaneko / Taito, 1988. Sets: `hvyunit` (World), `hvyunitj` (Japan, newer), `hvyunitjo` (Japan, older), `hvyunitja`
(Japan, alternate ROM format), `hvyunitu` (US). Core file `heavyunit_20261017.rbf`, five MRAs, GPL-3.0.

SHA-256 of the RBF: `12ED07751DD41713E7F3B6D67E90420C3093626F9B7CEB089236F0F3D269D6E7`

## What is in it

* The whole board: three Z80s at 6 MHz, the 8751 "Mermaid" MCU (jt8051, with the bit-instruction fixes in
  `rtl/patches`), YM2203 (jt03), the opaque 32 x 32 tilemap and the Kaneko Pandora sprites, all running from
  the 96 MHz system clock on clock enables.
* ROMs from the MAME 0.289 merged set (`hvyunit.zip` in `/media/fat/games/mame/`), loaded through the MRA's
  `address="0x32000000"` fast path (about a second on a recent Main_MiSTer; an older one loads at the old speed).
* OSD: Aspect ratio, Scale (V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx
  (HQ2x, CRT 25 / 50 / 75 %), **Video timing**, CRT Adjust (H-Size, H-Position, V-Shift), DIP switches from the
  MRA, SDRAM read capture, Reset.
* CRT Adjust is rmonic79's module (`modules/crt-adjust`, GPL-3.0, see `modules/VENDOR.md`). H-Size 0..+15 grows
  the picture about its own centre; +11 is about 77 % of the line, close to a TV picture.
* **Video timing:** `TV 58.3 Hz` (default) is a 390 x 264 raster, 15.38 kHz. `MAME 58.0 Hz` is MAME's own model of
  the board, 404 x 256, 14.85 kHz. The picture is the same; only blanking and sync differ, and the change takes
  place at the start of the next frame.

## How it was checked

* **Against MAME (simulation):** the CPUs, MCU and video match MAME's RAM state frame for frame through the
  attract mode; the finished picture of the whole MiSTer top level is bit-exact against an independent renderer
  that shares no code with the RTL (51 of 51 frames in each timing setting). A gameplay run (coin, start, hold
  right, autofire) sampled every third frame from 100 to 400 is bit-exact in 99 of 101 frames with the MAME
  setting and 97 of 101 with TV; the others differ by 12-20 pixels at the right edge, a beam sprite that the
  game writes to the sprite table microseconds before the vblank and that shows a frame late depending on the
  CPU's phase (docs/ARCHITECTURE.md section 14).
* **On hardware:** a DE10-Nano MiSTer, analog output to a CRT and HDMI direct video into a RetroTINK 4K
  (firmware 1.87.3). The game, sound, controls and the OSD features (fast load, CRT Adjust, Scale) were reported
  working; with TV timing the RT4K classifies the signal as `MiSTer 240p` and the picture is not squashed when
  the MiSTer OSD opens.
* **Timing closure:** Quartus 17.0.2 Lite, setup +0.464 ns, hold +0.252 ns (`releases/build4/timing_summary.txt`).

## Known limits and open points

* **No real PCB was available.** The raster figures come from the driver notes (15.59 kHz / 58 Hz); where the
  two interrupts sit in the real board's frame is not known (MAME itself marks the line-64 timing "likely off").
  TV timing is +0.5 % in frame rate and -1.3 % in line rate against those figures; the MAME setting is MAME's
  own 58 Hz.
* **RetroTINK 4K with the MAME timing setting** has not been tried; the RT4K may label that raster `MiSTer Gen.`
  and squash the picture while the MiSTer OSD is open. `[hvyunit] spd_quirk=2` in MiSTer.ini removes the
  menu flag per core if that matters.
* The MAME timing setting and the live switch between the two are checked in simulation only.
* The sprite plane relies on read-before-write behaviour that block RAM does not give; the design clears a clock
  late for that reason (docs/ARCHITECTURE.md section 14). Any further RAM inferred in the video path should be
  checked in the synthesis report the same way.

## Earlier test builds

Builds 1-3 (streamed load only; fast load + CRT Adjust + Scale; the 390 x 264 raster) are superseded by this
release and are not part of it.
