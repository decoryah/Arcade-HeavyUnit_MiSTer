# Dot-source me in PowerShell:   . .\tools\env.ps1
# Quartus 17.0.2 Lite is installed but is not on PATH (QUARTUS_ROOTDIR is set).
$env:PATH = "C:\intelFPGA_lite\17.0\quartus\bin64;C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem;$env:PATH"
$env:HVYUNIT_ZIP = "R:\Games\Arcade\MAME 0.289 ROMs (merged)\hvyunit.zip"
Write-Host ("quartus_sh: " + ((quartus_sh --version | Select-Object -Skip 1 -First 1)))
Write-Host "Verilator and iverilog are in WSL: run  source tools/env.sh  there."
