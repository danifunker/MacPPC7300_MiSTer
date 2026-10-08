#!/bin/bash
# Builds the tools (WSL/Linux). Usage: bash build.sh [make targets]
# Keeps temporary files and build output under ~/.cache/ppcmac/romdisasm.
set -e
export TMPDIR=$HOME/.cache/ppcmac/romdisasm/tmp
mkdir -p "$TMPDIR"
cd "$(dirname "$0")"
make -j4 "$@"
