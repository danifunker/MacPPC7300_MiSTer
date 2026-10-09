#!/bin/bash
# Regenerates everything in rom7600/ (WSL/Linux):
#   bash regen.sh [ROM] [COVDIR]
# 1. builds the tools (build.sh), 2. runs the coverage machine for 10^9
# instructions with RAM dumps (run_cov.sh), 3. writes the listings (romdis.py),
# the device-access summary (hwsummary.py) and the disassembler cross-check
# (crosscheck.py). Set SKIP_COV=1 to reuse an existing COVDIR.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROM=${1:-$HERE/../../ppctest/runs/my7600.rom}
COV=${2:-$HOME/.cache/macppc7300/romdisasm/cov}
export TMPDIR=$HOME/.cache/macppc7300/romdisasm/tmp
mkdir -p "$TMPDIR"
bash "$HERE/build.sh"
if [ -z "$SKIP_COV" ]; then
    bash "$HERE/run_cov.sh" "$ROM" "$COV" 1000000000 --dump-at 2500000 --dump-at 27400000 --dump-at 40000000
fi
python3 "$HERE/romdis.py" --rom "$ROM" --cov "$COV" --out "$HERE/.."
python3 "$HERE/hwsummary.py" "$COV/devices.log" "$HERE/../hw_access.txt"
python3 "$HERE/crosscheck.py" --rom "$ROM" --out "$HERE/../crosscheck.txt"
