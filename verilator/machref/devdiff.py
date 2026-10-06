#!/usr/bin/env python3
"""Compare two device-access logs: the RTL machine's (machine_tb --dev-log)
and dingusppc's whole machine (machref --log).

    python devdiff.py RTL_LOG MACHREF_LOG [--context N] [--all-space]

Both logs have lines "A icount pc R|W size address value ...". Only device
space (F0000000 and up, less the ROM) is compared unless --all-space is
given: below it the RTL machine logs RAM beyond the installed size, which
dingusppc does not treat as a device. Runs of the same access (a polling
loop) are collapsed to one entry with a count, because the two machines
poll for different numbers of iterations. The first entry where the two
differ in pc, direction, size, address or value is reported, with the
entries before it.
"""

import argparse
import sys


NO_VALUES = False


def load(path, all_space):
    out = []
    with open(path) as f:
        for line in f:
            if not line.startswith("A "):
                continue
            p = line.split()
            icount, pc, rw, size, addr, value = int(p[1]), p[2], p[3], p[4], p[5], p[6]
            a = int(addr, 16)
            if not all_space and (a < 0xF0000000 or a >= 0xFFC00000):
                continue
            key = (pc, rw, size, addr, "-" if NO_VALUES else value)
            if out and out[-1][0] == key:
                out[-1][2] += 1
            else:
                out.append([key, icount, 1])
    return out


def show(e):
    (pc, rw, size, addr, value), icount, n = e
    return "%10d  %s %s %s %s = %s%s" % (icount, pc, rw, size, addr, value, ("  x%d" % n) if n > 1 else "")


def hunks(r, d, count, context):
    """Every stretch where the two logs differ, the two resynchronised after
    each (difflib on the collapsed entries), the first `count` of them."""
    import difflib
    a = [e[0] for e in r]
    b = [e[0] for e in d]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    shown = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        shown += 1
        print("difference %d: RTL entries %d-%d, dingusppc entries %d-%d (%s)" % (shown, i1, i2, j1, j2, tag))
        for k in range(max(0, i1 - context), i1):
            print("  same      " + show(r[k]))
        for k in range(i1, min(i2, i1 + 3 * context)):
            print("  RTL       " + show(r[k]))
        if i2 - i1 > 3 * context:
            print("  RTL       ... %d more" % (i2 - i1 - 3 * context))
        for k in range(j1, min(j2, j1 + 3 * context)):
            print("  dingusppc " + show(d[k]))
        if j2 - j1 > 3 * context:
            print("  dingusppc ... %d more" % (j2 - j1 - 3 * context))
        if shown >= count:
            break
    if shown == 0:
        print("no differences")
    return 1 if shown else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rtl")
    ap.add_argument("ref")
    ap.add_argument("--context", type=int, default=8)
    ap.add_argument("--all-space", action="store_true")
    ap.add_argument("--hunks", type=int, default=0, help="list this many differences, resynchronising after each")
    ap.add_argument("--rtl-first", type=int, default=0, help="ignore RTL entries before this instruction count")
    ap.add_argument("--ref-first", type=int, default=0, help="ignore dingusppc entries before this instruction count")
    ap.add_argument("--no-values", action="store_true", help="compare where the accesses go, not their values")
    a = ap.parse_args()
    global NO_VALUES
    NO_VALUES = a.no_values
    r = [e for e in load(a.rtl, a.all_space) if e[1] >= a.rtl_first]
    d = [e for e in load(a.ref, a.all_space) if e[1] >= a.ref_first]
    if a.hunks:
        print("RTL machine: %d entries, dingusppc: %d entries (runs of one access collapsed)" % (len(r), len(d)))
        return hunks(r, d, a.hunks, a.context)
    n = min(len(r), len(d))
    i = 0
    while i < n and r[i][0] == d[i][0]:
        i += 1
    print("RTL machine: %d entries, dingusppc: %d entries (runs of one access collapsed)" % (len(r), len(d)))
    if i == n:
        print("identical for all %d entries the shorter log has" % n)
        return 0
    print("first difference at entry %d" % i)
    for k in range(max(0, i - a.context), i):
        print("  same      " + show(r[k]))
    print("  RTL       " + show(r[i]))
    print("  dingusppc " + show(d[i]))
    for k in range(i + 1, min(i + 1 + a.context, n)):
        print("  next RTL  " + show(r[k]))
        print("  next ref  " + show(d[k]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
