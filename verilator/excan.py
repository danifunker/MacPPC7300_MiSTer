#!/usr/bin/env python3
"""Analyse the machine bench's exception log (--exc-log).

    python excan.py LOG [--from N] [--to N] [--show N] [--dar]

Lines: E count vector pc_before srr0 srr1 dar dsisr; R count pc srr0 srr1.
Pairs each exception with the rfi that follows it (the first R after it at
the same nesting) and flags those whose rfi does not return to the
exception's SRR0: the handler went elsewhere (a fatal fault handed to the
68k emulator, a context switch...). Counts by vector, and the DSIs' DARs by
megabyte.
"""
import sys
from collections import Counter


def main():
    args = sys.argv[1:]
    path = args[0]
    lo = 0
    hi = 1 << 62
    show = 40
    dar = False
    i = 1
    while i < len(args):
        if args[i] == "--from":
            lo = int(args[i + 1]); i += 2
        elif args[i] == "--to":
            hi = int(args[i + 1]); i += 2
        elif args[i] == "--show":
            show = int(args[i + 1]); i += 2
        elif args[i] == "--dar":
            dar = True; i += 1
        else:
            i += 1
    byvec = Counter()
    dars = Counter()
    stack = []          # exceptions not yet returned from
    odd = []            # (E, R) where R's srr0 != E's srr0
    unreturned = []
    n = 0
    last_e = None
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            cnt = int(p[1])
            if cnt < lo:
                continue
            if cnt > hi:
                break
            if p[0] == "E":
                vec = int(p[2], 16)
                e = dict(count=cnt, vec=vec, pc=p[3], srr0=p[4], srr1=p[5], dar=p[6], dsisr=p[7])
                byvec[vec] += 1
                if vec == 0x300:
                    dars[int(p[6], 16) >> 20] += 1
                stack.append(e)
                last_e = e
                if len(stack) > 8:
                    stack.pop(0)
            elif p[0] == "R":
                r = dict(count=cnt, pc=p[2], srr0=p[3], srr1=p[4])
                if stack:
                    e = stack.pop()
                    if e["srr0"] != r["srr0"]:
                        odd.append((e, r))
            n += 1
    print("vectors:", " ".join("%X:%d" % (v, c) for v, c in sorted(byvec.items())))
    if dar:
        print("DSI DARs by MB:", " ".join("%03X:%d" % (m, c) for m, c in sorted(dars.items())))
    print("%d exceptions whose rfi went elsewhere; the last %d:" % (len(odd), min(show, len(odd))))
    for e, r in odd[-show:]:
        print("  E %d vec %X from %s srr0 %s srr1 %s dar %s dsisr %s -> R %d at %s to %s srr1 %s" % (
            e["count"], e["vec"], e["pc"], e["srr0"], e["srr1"], e["dar"], e["dsisr"], r["count"], r["pc"], r["srr0"], r["srr1"]))
    if stack:
        print("%d exceptions not returned from at the end; the last:" % len(stack))
        for e in stack[-5:]:
            print("  E %d vec %X from %s srr0 %s srr1 %s dar %s dsisr %s" % (
                e["count"], e["vec"], e["pc"], e["srr0"], e["srr1"], e["dar"], e["dsisr"]))


if __name__ == "__main__":
    main()
