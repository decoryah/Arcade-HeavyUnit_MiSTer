#!/bin/bash
# Generate jt8051's microcode headers (jt8051.vh, jt8051_param.vh, jt8051.uc).
#
# jt8051 cannot be used straight from a git checkout: its RTL includes headers
# that `jtframe ucode` (a Go tool) generates from modules/jt8051/ucode/8051.yaml.
#
# Run inside WSL:   bash tools/gen_8051_ucode.sh
# Needs:  Go >= 1.22 (go1.23.4 is installed at ~/tools/go1.23.4/go),
#         ref/jtcores checked out with modules/jtframe and modules/jt8051.
set -eu

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GO_ROOT="${GO_ROOT:-$HOME/tools/go1.23.4/go}"
TOOL_DIR="${TOOL_DIR:-$HOME/tools/jtframe-hvyunit}"
export PATH="$GO_ROOT/bin:$PATH"

# every one of these is checked by jtframe's main.go or by the ucode generator
export JTROOT="$REPO/ref/jtcores"
export JTFRAME="$JTROOT/modules/jtframe"
export MODULES="$JTROOT/modules"
export CORES="$JTROOT/cores"
export JTBIN="$TOOL_DIR/jtbin"          # unused by `ucode`, must merely be set
mkdir -p "$TOOL_DIR" "$JTBIN"

if [ ! -x "$TOOL_DIR/jtframe" ]; then
  echo "building jtframe (go downloads the modules pinned in go.mod/go.sum)"
  (cd "$JTFRAME/src/jtframe" && go build -o "$TOOL_DIR/jtframe" .)
fi

cd "$MODULES/jt8051/hdl"
"$TOOL_DIR/jtframe" ucode --output jt8051 jt8051 8051
ls -la jt8051.vh jt8051_param.vh jt8051.uc
