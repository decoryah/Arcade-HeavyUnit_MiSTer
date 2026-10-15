# Package a build for the MiSTer: the RBF named the way the MiSTer's loader wants it
# (heavyunit_<date>.rbf, matching <rbf>heavyunit</rbf> in the MRAs) and the MRAs.
#
#   .\tools\release.ps1 -Out releases\build1               # plain MRAs, work with any Main_MiSTer
#   .\tools\release.ps1 -Out releases\build2 -Fast         # MRAs with address="0x32000000" (fast load)
#
# Copy to the MiSTer:
#   heavyunit_<date>.rbf        -> /media/fat/_Arcade/cores/
#   *.mra                       -> /media/fat/_Arcade/
#   hvyunit.zip (MAME 0.289)    -> /media/fat/games/mame/        (the parent set; the clones reuse it)
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [switch]$Fast,
    [string]$Rbf = "output_files\HeavyUnit.rbf",
    [string]$Date = (Get-Date -Format "yyyyMMdd")
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not (Test-Path $Rbf)) { throw "no ${Rbf} - run the Quartus compile first" }
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $dst = Join-Path $Out ("heavyunit_{0}.rbf" -f $Date)
    Copy-Item -Force $Rbf $dst
    $mraDir = Join-Path $Out "mra"
    Get-ChildItem $mraDir -Filter *.mra -ErrorAction SilentlyContinue | Remove-Item -Force
    $args = @("-3", "tools\gen_hvyunit_mra.py", "--out", $mraDir)
    if ($Fast) { $args += "--fast" }
    & py @args
    if ($LASTEXITCODE -ne 0) { throw "MRA generation failed" }
    $sum = (Get-FileHash -Algorithm SHA256 $dst).Hash
    $notes = @(
        "Heavy Unit (Kaneko / Taito, 1988) for MiSTer",
        "",
        "  heavyunit_$Date.rbf   ->  /media/fat/_Arcade/cores/",
        "  mra\*.mra             ->  /media/fat/_Arcade/",
        "  hvyunit.zip           ->  /media/fat/games/mame/   (MAME 0.289 merged set; the clones use it as parent)",
        "",
        ("MRAs: " + $(if ($Fast) { "fast load (address=0x32000000): needs a recent Main_MiSTer; an older one loads at the old speed" } else { "plain streamed load (any Main_MiSTer)" })),
        "RBF SHA-256: $sum",
        "",
        "RetroTINK 4K on HDMI direct video: the RT4K sorts the signal into a class by its raster (System Status page 1,",
        "'Detected Mode': MiSTer 240p, 288p, ... or MiSTer Gen.). Builds up to 20261015 (raster 385 x 269) were 'MiSTer Gen.'",
        "and the RT4K squashed the picture while the MiSTer OSD was open. This build's raster is 390 x 264 like the other",
        "cores'; 'Detected Mode' should read 'MiSTer 240p'. If it does not, the MiSTer.ini switch that stops the MiSTer",
        "sending its 'menu present' flag is a fix per core:",
        "",
        "    [hvyunit]",
        "    spd_quirk=2",
        "",
        "Video timing (OSD): TV 58.3 Hz (default, 390 x 264) or MAME 58.0 Hz (404 x 256, MAME's model of the board).",
        "The picture is the same; the raster changes at the start of the next frame.",
        "",
        "CRT Adjust (OSD): H-Size +11 fills 77 % of the line, close to a TV picture (+15 is the most the line holds); H-Size and",
        "H-Position are centred, CRT Adjust is Off by default."
    )
    $notes | Set-Content -Encoding ascii (Join-Path $Out "README.txt")
    Write-Host ("released {0} ({1} bytes) + {2} MRAs in {3}" -f $dst, (Get-Item $dst).Length, (Get-ChildItem $mraDir -Filter *.mra).Count, $Out)
} finally { Pop-Location }
