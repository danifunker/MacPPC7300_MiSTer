#!/usr/bin/env python3
"""Writes rom7300/tools/annotations.py from rom7600/tools/annotations.py:
the hand-written notes of the 7600 ROM (077D.28F2) moved to the addresses
the same code has in the 7300 ROM (077D.34F2).

The two ROMs' PowerPC code (boot FFF00000-FFF0BFFF, NanoKernel
FFF10000-FFF1FFFF, HWInit FFF20000-FFF2FFFF) is aligned word by word with
branch displacements masked (difflib); an address in a key or in a note's
text moves to where its word went. Open Firmware, the 68k emulator, its
opcode table and the trap tables are byte-identical, and the 68k code
differs in 13 bytes in place, so their notes stay where they are.

    python3 remap_annotations.py ROM7600 ROM7300
"""
import difflib
import importlib.util
import os
import pprint
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 0xFFC00000
REGIONS = [(0x300000, 0x30C000), (0x310000, 0x320000), (0x320000, 0x330000)]


def mask(w):
    op = w >> 26
    if op == 18:
        return w & 0xFC000003
    if op == 16:
        return w & 0xFFFF0003
    return w


def align(a, b):
    m = {}
    for s, e in REGIONS:
        n = (e - s) // 4
        wa = [mask(w) for w in struct.unpack('>%dI' % n, a[s:e])]
        wb = [mask(w) for w in struct.unpack('>%dI' % n, b[s:e])]
        for i, j, k in difflib.SequenceMatcher(None, wa, wb, autojunk=False).get_matching_blocks():
            for x in range(k):
                m[BASE + s + 4 * (i + x)] = BASE + s + 4 * (j + x)
    return m


def main():
    a = open(sys.argv[1], 'rb').read()
    b = open(sys.argv[2], 'rb').read()
    amap = align(a, b)
    spec = importlib.util.spec_from_file_location('ann7600', os.path.join(HERE, '..', '..', 'rom7600', 'tools', 'annotations.py'))
    ann = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ann)
    lost = []

    def mv(x):
        if 0xFFF00000 <= x < 0xFFF30000 and x in amap:
            return amap[x]
        if 0xFFF00000 <= x < 0xFFF30000 and not (0xFFF0C000 <= x < 0xFFF10000):
            lost.append(x)
        return x

    def mvtext(t):
        return re.sub(r'\bFFF[0-2][0-9A-F]{4}\b', lambda mo: '%08X' % mv(int(mo.group(0), 16)), t)

    out = ['"""Hand-written notes for the 7300 ROM (077D.34F2): rom7600/tools/annotations.py',
           'moved to this ROM\'s addresses by remap_annotations.py (generated; do not edit)."""', '']
    for name in ('BOOT', 'BOOT_INLINE', 'KERNEL', 'HWINIT', 'EMULATOR', 'OF_ROM', 'OF_RAM', 'M68K'):
        if not hasattr(ann, name):
            continue
        d = getattr(ann, name)
        nd = {}
        for k, v in d.items():
            nk = mv(k) if name in ('BOOT', 'BOOT_INLINE', 'KERNEL', 'HWINIT') else k
            nv = [mvtext(x) for x in v] if isinstance(v, list) else mvtext(v) if isinstance(v, str) else v
            nd[nk] = nv
        out.append('%s = %s' % (name, pprint.pformat(nd, width=110)))
        out.append('')
    for name in dir(ann):
        if not name.startswith('_') and name not in ('BOOT', 'BOOT_INLINE', 'KERNEL', 'HWINIT', 'EMULATOR', 'OF_ROM', 'OF_RAM', 'M68K'):
            v = getattr(ann, name)
            if isinstance(v, (dict, list, str, int)):
                out.append('%s = %s' % (name, pprint.pformat(v, width=110)))
                out.append('')
    open(os.path.join(HERE, 'annotations.py'), 'w').write('\n'.join(out))
    if lost:
        print('addresses with no matching word (kept as they were):', ' '.join('%08X' % x for x in sorted(set(lost))))


if __name__ == '__main__':
    main()
