#!/usr/bin/env python3
"""The VRAM combiner's records (trace kind 15, TRACE builds) from a capture.

    python syn/vramstat.py CAPTURE [--every N]

Every 2^20 cycles the core records the combiner's counts (stores taken,
drains done, loads answered, cycles the port waited) and its state. This
prints them, one line per N records.
"""
import sys
f = sys.argv[1]
every = int(sys.argv[sys.argv.index("--every") + 1]) if "--every" in sys.argv else 1
raw = open(f, "rb").read()
n = 0
for k in range(0, len(raw) - 35, 36):
    r = raw[k + 4:k + 36]
    if r[0] != 15:
        continue
    n += 1
    if n % every:
        continue
    cyc = int.from_bytes(r[4:8], "little")
    dbg = int.from_bytes(r[8:28], "little")
    st, dr, ld, wt = (dbg >> 128) & 0xFFFFFFFF, (dbg >> 96) & 0xFFFFFFFF, (dbg >> 64) & 0xFFFFFFFF, (dbg >> 32) & 0xFFFFFFFF
    cnt, head, tail = (dbg >> 24) & 0xFF, (dbg >> 16) & 0xFF, (dbg >> 8) & 0xFF
    bits = dbg & 0xFF
    names = ["a_req", "b_req", "s_we", "s_v", "r_done", "r_wait", "d_sent", "d_v"]
    state = " ".join(nm for i, nm in enumerate(names) if (bits >> i) & 1)
    print("%12u cyc  stores %9u drains %9u loads %7u waited %9u | count %d head %d tail %d | %s" % (cyc, st, dr, ld, wt, cnt, head, tail, state))
print("%d records" % n)
