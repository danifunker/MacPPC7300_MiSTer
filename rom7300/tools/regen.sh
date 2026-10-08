#!/bin/bash
# Regenerates everything in rom7300/ (WSL/Linux), the 7300's ROM (077D.34F2)
# taken apart with the 7600 ROM's tools (copied here, titles changed):
#   bash regen.sh [ROM7300] [COVDIR]
# 1. builds the tools (build.sh; the same binaries as rom7600's), 2. runs the
# coverage machine as a 7300 for 10^9 instructions with RAM dumps
# (run_cov.sh), 3. moves the 7600 ROM's hand-written notes to this ROM's
# addresses (remap_annotations.py), 4. writes the listings (romdis.py), the
# device-access summary (hwsummary.py) and the disassembler cross-check
# (crosscheck.py). Set SKIP_COV=1 to reuse an existing COVDIR.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROM=${1:-$HERE/../../ppctest/runs/my7300.rom}
ROM7600=$HERE/../../ppctest/runs/my7600.rom
COV=${2:-$HOME/.cache/ppcmac/romdisasm/cov7300}
export TMPDIR=$HOME/.cache/ppcmac/romdisasm/tmp
mkdir -p "$TMPDIR"
bash "$HERE/build.sh"
if [ -z "$SKIP_COV" ]; then
    bash "$HERE/run_cov.sh" "$ROM" "$COV" 1000000000 --machine pm7300 --dump-at 2500000 --dump-at 27400000 --dump-at 40000000
fi
python3 "$HERE/remap_annotations.py" "$ROM7600" "$ROM"
python3 "$HERE/romdis.py" --rom "$ROM" --cov "$COV" --out "$HERE/.."
python3 "$HERE/hwsummary.py" "$COV/devices.log" "$HERE/../hw_access.txt"
python3 "$HERE/crosscheck.py" --rom "$ROM" --out "$HERE/../crosscheck.txt"
