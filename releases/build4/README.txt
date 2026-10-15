Heavy Unit (Kaneko / Taito, 1988) for MiSTer

  heavyunit_20261017.rbf   ->  /media/fat/_Arcade/cores/
  mra\*.mra             ->  /media/fat/_Arcade/
  hvyunit.zip           ->  /media/fat/games/mame/   (MAME 0.289 merged set; the clones use it as parent)

MRAs: fast load (address=0x32000000): needs a recent Main_MiSTer; an older one loads at the old speed
RBF SHA-256: 12ED07751DD41713E7F3B6D67E90420C3093626F9B7CEB089236F0F3D269D6E7

RetroTINK 4K on HDMI direct video: the RT4K sorts the signal into a class by its raster (System Status page 1,
'Detected Mode': MiSTer 240p, 288p, ... or MiSTer Gen.). Builds up to 20261015 (raster 385 x 269) were 'MiSTer Gen.'
and the RT4K squashed the picture while the MiSTer OSD was open. This build's raster is 390 x 264 like the other
cores'; 'Detected Mode' should read 'MiSTer 240p'. If it does not, the MiSTer.ini switch that stops the MiSTer
sending its 'menu present' flag is a fix per core:

    [hvyunit]
    spd_quirk=2

Video timing (OSD): TV 58.3 Hz (default, 390 x 264) or MAME 58.0 Hz (404 x 256, MAME's model of the board).
The picture is the same; the raster changes at the start of the next frame.

CRT Adjust (OSD): H-Size +11 fills 77 % of the line, close to a TV picture (+15 is the most the line holds); H-Size and
H-Position are centred, CRT Adjust is Off by default.
