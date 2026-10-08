#!/usr/bin/env python3
"""Summarises the coverage run's device log (romcov --log, machref's format)
into a table of every I/O register the ROM touched: how often, when first
and last, from which code, and with which values.

    python3 hwsummary.py DEVICES.LOG OUT.TXT
"""

import collections
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hwmap  # noqa: E402

PHASES = [(0, 'boot code'), (1436733, 'Open Firmware'), (27954966, 'NanoKernel / Mac OS')]


def phase(ic):
    name = PHASES[0][1]
    for start, n in PHASES:
        if ic >= start:
            name = n
    return name


def where(pc):
    if 0xFFF00000 <= pc < 0xFFF0C000:
        return 'boot'
    if 0xFFF10000 <= pc < 0xFFF20000:
        return 'kernel'
    if 0xFFF20000 <= pc < 0xFFF30000:
        return 'hwinit'
    if 0xFFF30000 <= pc < 0xFFF50000 or 0xFF800000 <= pc < 0xFF900000 or 0x00400000 <= pc < 0x00500000:
        return 'OF'
    if 0x68060000 <= pc < 0x68100000:
        return 'emulator'
    if 0xFFC00000 <= pc < 0xFFF00000:
        return 'ROM PEF'
    return 'RAM code'


def main():
    log, out_path = sys.argv[1], sys.argv[2]
    stats = collections.OrderedDict()
    devices = []
    video = collections.Counter()
    video_first = {}
    first_dev = collections.OrderedDict()
    total = 0
    with open(log) as f:
        for line in f:
            if line.startswith('# device'):
                devices.append(line[2:].strip())
                continue
            if not line.startswith('A '):
                continue
            p = line.split()
            ic, pc, rw, size, addr, val, dev = int(p[1]), int(p[2], 16), p[3], int(p[4]), int(p[5], 16), p[6], p[7]
            m68k = int(p[8][4:], 16) if len(p) > 8 and p[8].startswith('68k=') else None
            total += 1
            first_dev.setdefault(dev, (ic, pc, addr))
            if 0x90000000 <= addr < 0x94000000:
                k = (addr & ~0xFFFFF, rw)
                video[k] += 1
                video_first.setdefault(k, ic)
                continue
            key = (dev, addr, rw, size)
            s = stats.get(key)
            if s is None:
                s = stats[key] = {'n': 0, 'first': ic, 'last': ic, 'pcs': collections.Counter(), 'vals': collections.Counter(),
                                  'phases': collections.Counter(), 'm68k': collections.Counter()}
            s['n'] += 1
            s['last'] = ic
            s['pcs'][pc] += 1
            if len(s['vals']) < 64 or val in s['vals']:
                s['vals'][val] += 1
            s['phases'][phase(ic)] += 1
            if m68k is not None:
                s['m68k'][m68k] += 1
    out = ['I/O accesses of the 7600 ROM in the coverage run (dingusppc 7600, 32 MB, 604 PVR 00040303,',
           '10^9 instructions: boot code, Open Firmware, then the Mac OS ROM up to the point where it',
           'waits for a boot disk). From romcov\'s device log; %d accesses in total.' % total,
           'Columns: device, physical address, name, R/W and size, count, first and last instruction',
           'count, where the accesses came from (code region: count), then the PowerPC instructions',
           'making them, the most common values, and for accesses by the 68k emulator the 68k',
           "instructions behind them (the emulator's r24 - 2: the opcode or up to a few bytes past).",
           'Phases by instruction count: boot code < 1436733 <= Open Firmware < 27954966 <= NanoKernel/Mac OS.',
           "Values are as dingusppc's device models receive them (its device interface byte order:",
           'Grand Central registers written with stwbrx appear byte-reversed here).',
           '']
    out.append('Devices in the map (as dingusppc places them):')
    out += ['  ' + d for d in devices]
    out.append('')
    out.append('First access per device:')
    for dev, (ic, pc, addr) in first_dev.items():
        out.append('  %-22s instruction %-10d pc %08X address %08X' % (dev, ic, pc, addr))
    out.append('')
    out.append('%-20s %-8s %-34s %-3s %9s %10s %10s  %s' % ('device', 'address', 'name', 'op', 'count', 'first', 'last', 'from / values'))
    for (dev, addr, rw, size), s in sorted(stats.items(), key=lambda kv: (kv[0][1], kv[0][2])):
        nm = hwmap.hw_name(addr) or ''
        wh = collections.Counter()
        for pc, c in s['pcs'].items():
            wh[where(pc)] += c
        pcs = sorted(s['pcs'], key=lambda p: -s['pcs'][p])[:4]
        vals = ' '.join('%s:%d' % kv for kv in s['vals'].most_common(6))
        out.append('%-20s %08X %-34s %s%d %9d %10d %10d  %s' % (
            dev[:20], addr, nm[:34], rw, size, s['n'], s['first'], s['last'],
            ', '.join('%s:%d' % kv for kv in wh.most_common())))
        out.append('%-20s %8s %-34s %3s %9s %10s %10s  pcs %s; values %s' % (
            '', '', '', '', '', '', '', ' '.join('%08X' % p for p in pcs), vals))
        if s['m68k']:
            out.append('%-20s %8s %-34s %3s %9s %10s %10s  68k code %s' % (
                '', '', '', '', '', '', '', ' '.join('%08X:%d' % kv for kv in s['m68k'].most_common(6))))
    out.append('')
    out.append('Control video frame buffer / registers (aggregated per MB):')
    for (base, rw), n in sorted(video.items()):
        out.append('  %08X-%08X %s %d accesses, first at instruction %d' % (base, base + 0xFFFFF, rw, n, video_first[(base, rw)]))
    out.append('')
    out.append('Most polled registers (reads > 1000):')
    polled = [(s['n'], k) for k, s in stats.items() if k[2] == 'R' and s['n'] > 1000]
    for n, (dev, addr, rw, size) in sorted(polled, reverse=True):
        out.append('  %08X %-34s %9d reads' % (addr, hwmap.hw_name(addr) or dev, n))
    with open(out_path, 'w', newline='\n') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
