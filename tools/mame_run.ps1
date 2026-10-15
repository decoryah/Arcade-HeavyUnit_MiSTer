# Run MAME headless on a Heavy Unit set with every writable directory redirected
# into build\mame, so nothing lands in the MAME install itself.
#
#   .\tools\mame_run.ps1                      # hvyunit, 5 s, snapshot at exit
#   .\tools\mame_run.ps1 -Set hvyunitu -Seconds 20
#
# MAME 0.289 is borrowed from the sibling taitol-mister repo (not installed
# separately). Override with -Mame or $env:MAME_EXE.
param(
    [string]$Set     = "hvyunit",
    [int]   $Seconds = 5,
    [string]$Mame    = $(if ($env:MAME_EXE) { $env:MAME_EXE } else { "C:\repos\taitol-mister\mister\tools\mame\mame.exe" }),
    [string]$RomPath = $(if ($env:HVYUNIT_ROMS) { $env:HVYUNIT_ROMS } else { "R:\Games\Arcade\MAME 0.289 ROMs (merged)" }),
    [string[]]$Extra = @()
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$b = Join-Path $root "build\mame"
foreach ($d in "run","cfg","nvram","snap","state","diff","inp","comment","home") {
    New-Item -ItemType Directory -Force -Path (Join-Path $b $d) | Out-Null
}
Push-Location (Join-Path $b "run")
try {
    & $Mame $Set -rompath $RomPath -video none -sound none -nothrottle -skip_gameinfo `
        -seconds_to_run $Seconds `
        -cfg_directory "$b\cfg" -nvram_directory "$b\nvram" -snapshot_directory "$b\snap" `
        -state_directory "$b\state" -diff_directory "$b\diff" -input_directory "$b\inp" `
        -comment_directory "$b\comment" -homepath "$b\home" @Extra
    exit $LASTEXITCODE
} finally { Pop-Location }
