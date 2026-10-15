# Capture a MAME oracle (pixels + state + I/O taps) for a Heavy Unit set.
#
#   .\tools\capture.ps1 -Frames 120                      # attract mode
#   .\tools\capture.ps1 -Frames 1800 -Play -Out build\oracle\play
#
# Output goes to build\oracle\<set> by default (git-ignored). Layout is
# documented in sim\oracle\hvyunit_capture.lua.
param(
    [string]$Set    = "hvyunit",
    [int]   $Frames = 600,
    [string]$Out    = "",
    [switch]$Play,
    [int]   $PlayCoin  = 420,
    [int]   $PlayStart = 480,
    [switch]$NoTaps,
    [switch]$Mcu,                 # also dump the 8751's internal RAM every frame
    [switch]$Stim,
    [int]   $StimFrom = 200
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Out) { $Out = Join-Path $root ("build\oracle\" + $Set) }
elseif (-not [System.IO.Path]::IsPathRooted($Out)) { $Out = Join-Path $root $Out }

New-Item -ItemType Directory -Force -Path (Join-Path $Out "frames") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Out "state")  | Out-Null
Get-ChildItem (Join-Path $Out "frames"), (Join-Path $Out "state") -File -ErrorAction SilentlyContinue | Remove-Item -Force

$env:HV_OUT        = $Out
$env:HV_FRAMES     = "$Frames"
$env:HV_PLAY       = $(if ($Play) { "1" } else { "0" })
$env:HV_PLAY_COIN  = "$PlayCoin"
$env:HV_PLAY_START = "$PlayStart"
$env:HV_TAPS       = $(if ($NoTaps) { "0" } else { "1" })
$env:HV_STIM       = $(if ($Stim) { "1" } else { "0" })
$env:HV_MCU        = $(if ($Mcu) { "1" } else { "0" })
$env:HV_STIM_FROM  = "$StimFrom"

# the script exits MAME itself after $Frames; this is only a safety stop
$secs = [int][math]::Ceiling($Frames / 50.0) + 10
$lua  = Join-Path $root "sim\oracle\hvyunit_capture.lua"
& (Join-Path $PSScriptRoot "mame_run.ps1") -Set $Set -Seconds $secs -Extra @("-autoboot_script", $lua)
$rc = $LASTEXITCODE
$n = (Get-ChildItem (Join-Path $Out "frames") -File -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host ("capture: {0} frames in {1} (mame exit {2})" -f $n, $Out, $rc)
exit $rc
