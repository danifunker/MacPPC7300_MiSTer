#!/usr/bin/env python3
"""The CPU's samples (trace kind 14, PERF builds) from a trace capture.

    python syn/cpusample.py CAPTURE [--from SECONDS] [--to SECONDS] [--top N]

A capture is what `syn/mister.py trace-capture` / `trace-fetch` bring back.
Every 65536 CPU cycles the core records EX's address and instruction, MSR,
how many exceptions of each kind were taken since the last sample, and the
last one's vector and saved address. This prints the most frequent sample
addresses (where the CPU spends its time), the exception counts, and the
most frequent addresses exceptions were taken at.
"""

import argparse
import collections
import sys

KINDS = ["DSI 300", "ext 500", "align 600", "prog 700", "FPunav 800", "dec 900", "sc C00", "other"]


def records(fname):
    raw = open(fname, "rb").read()
    for k in range(0, len(raw) - 35, 36):
        r = raw[k + 4:k + 36]
        if r[0] == 14:
            yield r


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--mhz", type=float, default=60.0, help="the CPU's clock, for the times shown")
    ap.add_argument("--from", dest="t0", type=float, default=0.0)
    ap.add_argument("--to", dest="t1", type=float, default=1e9)
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args()

    pcs, exc_pcs, insns = collections.Counter(), collections.Counter(), {}
    counts = [0] * 8
    n, wraps, last_cyc = 0, 0, None
    for r in records(a.capture):
        cyc = int.from_bytes(r[4:8], "little")
        if last_cyc is not None and cyc < last_cyc:
            wraps += 1
        last_cyc = cyc
        t = (wraps * 2**32 + cyc) / (a.mhz * 1e6)
        if not (a.t0 <= t <= a.t1):
            continue
        n += 1
        pc = int.from_bytes(r[8:12], "little")
        epc = int.from_bytes(r[12:16], "little")
        vec = int.from_bytes(r[16:18], "little") & 0xFFF
        insn = int.from_bytes(r[28:32], "little")
        pcs[pc] += 1
        insns[pc] = insn
        exc_pcs[(vec, epc)] += 1
        for i in range(8):
            counts[i] += r[20 + i]
    if not n:
        print("no CPU samples (kind 14) in that range")
        return 1
    print("%d samples" % n)
    print("exceptions taken: " + ", ".join("%s %d" % (KINDS[i], counts[i]) for i in range(8)))
    print("most frequent EX addresses:")
    for pc, c in pcs.most_common(a.top):
        print("  %08X  %08X  %5d  %5.1f%%" % (pc, insns[pc], c, 100.0 * c / n))
    print("last exception per sample (vector, saved address):")
    for (vec, epc), c in exc_pcs.most_common(a.top):
        print("  %03X  %08X  %5d" % (vec, epc, c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
