#!/bin/bash
# Runs the coverage machine on the ROM (WSL/Linux).
#   bash run_cov.sh ROM OUTDIR MAXINSTR [extra romcov options]
# Writes OUTDIR/{rom_first,rom_ea,ram_first,ram_ea}.bin, pages.txt,
# m68k_pcs.txt, RAM dumps, devices.log and summary.txt.
set -e
export TMPDIR=$HOME/.cache/ppcmac/romdisasm/tmp
mkdir -p "$TMPDIR"
ROM=$1; OUT=$2; MAX=$3; shift 3
BIN=${ROMCOV:-$HOME/.cache/ppcmac/romdisasm/build/romcov}
ROM=$(realpath "$ROM")
mkdir -p "$OUT"
OUT=$(realpath "$OUT")
# run inside OUT: dingusppc looks for nvram.bin/pram.bin in the current
# directory, and a fresh directory has none, so every run starts the same
cd "$OUT"
rm -f nvram.bin pram.bin
time "$BIN" --rom "$ROM" --out "$OUT" --max "$MAX" --m68k-reg 24 --log "$OUT/devices.log" --sample 100000 "$@"
cat "$OUT/summary.txt"
