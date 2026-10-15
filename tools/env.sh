# Source me inside WSL:   source tools/env.sh
# Puts the simulators on PATH. Verilator/iverilog/vvp live in the OSS CAD Suite
# in the WSL home; they are NOT on the default PATH of either shell.
export OSS_CAD=$HOME/tools/oss-cad-suite
export PATH="$OSS_CAD/bin:$PATH"

# Windows tools reachable from WSL (Quartus has no Linux install here).
export QUARTUS_WIN='C:\intelFPGA_lite\17.0\quartus\bin64'

# Where the merged MAME zips live, as WSL sees them.
export HVYUNIT_ZIP="/mnt/r/Games/Arcade/MAME 0.289 ROMs (merged)/hvyunit.zip"

echo "verilator: $(verilator --version 2>&1 | head -1)"
echo "iverilog:  $(iverilog -V 2>&1 | head -1)"
