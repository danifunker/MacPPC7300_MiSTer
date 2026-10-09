#!/usr/bin/env python3
"""The CPU's cycle accounting from the trace's performance records (kind 12:
a PERF = 1, TRACE = 1 build; DSPPC604's perf_cnt, MacPPC7300_system's records
every 2^23 cycles).

    python syn\\perf.py                      the ring on the MiSTer (the last ~4 minutes)
    python syn\\perf.py --file trace.bin     a capture (mister.py trace-capture, trace-fetch)
    python syn\\perf.py ... --sum A B        one account over the intervals A to B (as numbered)
    python syn\\perf.py ... --every N        one line per N intervals (120 ms each at 70 MHz)
    python syn\\perf.py ... --csv OUT.csv    every interval's counters

Each line is an interval between two snapshots: the cycles per instruction
and, of every 100 cycles, how many an operation left EX in and how many went
on each wait (MEM gnt: the cycle an access is granted, answered in the next;
nognt: the cache not granting; gap: the memory unit between the two accesses
of a double or a misaligned operand; busy: the data cache in a miss, a
write-back or a snoop; LU: a load's data; mul, div, FPU; redir: EX empty
after a redirect; fetch: EX empty for the fetch), then the branches'
mispredict rate, the loads, stores and doubles per 100 instructions, the
caches' memory transactions per 1,000 instructions, and the fetch's wait
cycles.
"""
import base64
import csv
import subprocess
import sys

import mister

NAMES = ["cycles", "ops", "instr", "w_mem_gnt", "w_mem_nognt", "w_mem_gap", "w_busy", "w_lduse", "w_mul", "w_div",
         "w_fpu", "w_else", "e_redir", "e_fetch", "e_id", "br", "br_taken", "br_mp", "br_mp_tnp", "exc", "refetch",
         "loads", "stores", "doubles", "dc_mem", "ic_mem", "fetch_wait", "fetch_nognt"]
N = len(NAMES)
PARTS = 5
CPU_HZ = 70_000_000


def records(fname):
    """(index, record) for every record, from a capture or the ring."""
    if fname:
        raw = open(fname, "rb").read()
        return [(int.from_bytes(raw[k:k + 4], "little"), raw[k + 4:k + 36]) for k in range(0, len(raw) - 35, 36)]
    size = 64 + mister.TRACE_RECS * 32
    script = ("import mmap,os,base64,sys;f=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC);"
              "m=mmap.mmap(f,%d,mmap.MAP_SHARED,mmap.PROT_READ,offset=%d);"
              "sys.stdout.write(base64.b64encode(m[:%d]).decode())" % (size, mister.TRACE_BASE, size))
    args = ["ssh"] + mister.ssh_args() + ["root@" + mister.host(), "python3 -c \"%s\"" % script]
    raw = base64.b64decode(subprocess.check_output(args, timeout=60))
    head = int.from_bytes(raw[0:8], "little")
    if head >> 32 != 0x54524345:
        sys.exit("no trace (header %016x): a core without MacPPC7300_trace, or nothing written yet" % head)
    n = head & 0xFFFFFFFF
    lo = max(0, n - mister.TRACE_RECS)
    return [(i, raw[64 + (i % mister.TRACE_RECS) * 32:][:32]) for i in range(lo, n)]


def snapshots(recs):
    """The counters of every complete snapshot (the parts in order), as lists of N."""
    out, cur = [], {}
    for i, r in recs:
        if r[0] != 12:
            continue
        part = r[1]
        words = [int.from_bytes(r[8 + 4 * k:12 + 4 * k], "little") for k in range(6)]
        cycles = int.from_bytes(r[4:8], "little")
        if part == 0:
            cur = {0: (cycles, words)}
        elif part - 1 in cur:
            cur[part] = (cycles, words)
        else:
            cur = {}
            continue
        if part == PARTS - 1 and len(cur) == PARTS:
            c = [cur[0][0]]
            for p in range(PARTS):
                c += cur[p][1]
            out.append(c[:N])
            cur = {}
    return out


def delta(a, b):
    return [(y - x) & 0xFFFFFFFF for x, y in zip(a, b)]


def line(label, d):
    cyc, ops, ins = d[0], d[1], d[2]
    if cyc == 0 or ins == 0:
        return "%s  (nothing retired)" % label
    p = lambda i: 100.0 * d[i] / cyc
    br = d[15]
    return ("%s CPI %5.2f | EX leaves %4.1f  MEM gnt %4.1f nognt %4.1f gap %4.1f busy %4.1f LU %4.1f mul %4.1f "
            "div %4.1f FPU %4.1f else %4.1f redir %4.1f fetch %4.1f ID %4.1f | br %4.1f%% of instr, mispredicted "
            "%4.1f%% (taken unpredicted %4.1f%%) | ld %4.1f st %4.1f dbl %4.1f /100 instr | dc %5.1f ic %5.1f "
            "mem/1000 instr, fetch wait %4.1f%% nognt %4.1f%%, exc %d"
            % (label, cyc / ins, p(1), p(3), p(4), p(5), p(6), p(7), p(8), p(9), p(10), p(11), p(12), p(13), p(14),
               100.0 * br / ins, 100.0 * d[17] / br if br else 0.0, 100.0 * d[18] / br if br else 0.0,
               100.0 * d[21] / ins, 100.0 * d[22] / ins, 100.0 * d[23] / ins, 1000.0 * d[24] / ins,
               1000.0 * d[25] / ins, p(26), p(27), d[19]))


def main():
    a = sys.argv[1:]
    fname = a[a.index("--file") + 1] if "--file" in a else None
    every = int(a[a.index("--every") + 1]) if "--every" in a else 1
    csv_out = a[a.index("--csv") + 1] if "--csv" in a else None
    snaps = snapshots(records(fname))
    if len(snaps) < 2:
        print("%d snapshots: nothing to account (a PERF = 1 build writes one every 2^23 cycles)" % len(snaps))
        return 1
    deltas = [delta(snaps[k], snaps[k + 1]) for k in range(len(snaps) - 1)]
    if csv_out:
        with open(csv_out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["interval"] + NAMES)
            for k, d in enumerate(deltas):
                w.writerow([k] + d)
        print("%d intervals to %s" % (len(deltas), csv_out))
    if "--sum" in a:
        lo, hi = int(a[a.index("--sum") + 1]), int(a[a.index("--sum") + 2])
        tot = [sum(d[i] for d in deltas[lo:hi + 1]) for i in range(N)]
        print(line("intervals %d-%d (%.1f s):" % (lo, hi, tot[0] / CPU_HZ), tot))
        return 0
    t = 0.0
    for k in range(0, len(deltas), every):
        grp = deltas[k:k + every]
        tot = [sum(d[i] for d in grp) for i in range(N)]
        print(line("%4d %7.2f s" % (k, t), tot))
        t += tot[0] / CPU_HZ
    return 0


if __name__ == "__main__":
    sys.exit(main())
