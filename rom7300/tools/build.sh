#!/bin/bash
# Builds the tools (WSL/Linux). Usage: bash build.sh [make targets]
# Keeps temporary files and build output under ~/.cache/macppc7300/romdisasm.
set -e
export TMPDIR=$HOME/.cache/macppc7300/romdisasm/tmp
mkdir -p "$TMPDIR"
cd "$(dirname "$0")"
make -j4 "$@"
