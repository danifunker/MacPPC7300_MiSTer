#!/usr/bin/env python3
"""Cross-checks the disassemblers used for the listings against independent
ones on the same bytes:
  PowerPC: dingusppc's disassembler (listings) vs MAME's PowerPC disassembler
  68k:     MAME's 68k disassembler (listings) vs binutils' (QEMU's copy)
and writes a report with agreement rates and every kind of disagreement.

    python3 crosscheck.py --rom ROM --out crosscheck.txt [--build DIR]
"""

import argparse
import collections
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m68klist  # noqa: E402
import ppclist   # noqa: E402

PPC_REGIONS = [
    ('boot code', 0x300000, 0x305000),
    ('NanoKernel', 0x310000, 0x315C00),
    ('HWInit', 0x320000, 0x322000),
    ('Open Firmware kernel', 0x33003C, 0x3367E4),
    ('68k emulator', 0x360000, 0x377400),
    ('opcode table (first 64 KB)', 0x380000, 0x390000),
    ('InterfaceLib code', 0x12D170 + 0x107C0, 0x12D170 + 0x107C0 + 0x26190),
    ('NQD code', 0x1A2130 + 0x2630, 0x1A2130 + 0x2630 + 0x33E80),
    ('CodeFragmentMgr code', 0x1151A0 + 0x910, 0x1151A0 + 0x910 + 0x110EC),
]

NUM = re.compile(r'(?<![A-Za-z_])-?(?:0x[0-9a-fA-F]+|\$[0-9a-fA-F]+|\d+)')
CC = {'lt': 0, 'gt': 1, 'eq': 2, 'so': 3, 'un': 3}


def nums(text):
    """Immediate values in a text (registers excluded), normalised so that
    sign-extended 16-bit forms and upper-half forms (x << 16) compare equal."""
    out = []
    for m in NUM.findall(text):
        neg = m.startswith('-')
        t = m.lstrip('-')
        v = int(t[2:], 16) if t.startswith('0x') else (int(t[1:], 16) if t.startswith('$') else int(t))
        if neg:
            v = -v
        v = v & 0xFFFF if -0x10000 < v < 0x10000 else v & 0xFFFFFFFF
        if v >= 0xFFFF8000:                  # sign-extended 16-bit immediate
            v &= 0xFFFF
        if v >= 0x10000 and not v & 0xFFFF:
            v >>= 16
        out.append(v)
    return sorted(out)


def ppc_fields(text):
    """(registers, CR bits, immediates) of a PowerPC instruction text in
    either disassembler's notation."""
    t = text.lower()
    crb = []
    for n, cc in re.findall(r'4\*cr(\d)\+(lt|gt|eq|so|un)', t):
        crb.append(4 * int(n) + CC[cc])
    t = re.sub(r'4\*cr\d\+(lt|gt|eq|so|un)', ' ', t)
    for n, cc in re.findall(r'cr(\d)\[(lt|gt|eq|so|un)\]', t):
        crb.append(4 * int(n) + CC[cc])
    t = re.sub(r'cr\d\[(lt|gt|eq|so|un)\]', ' ', t)
    for n in re.findall(r'crb(\d+)', t):
        crb.append(int(n))
    t = re.sub(r'crb\d+', ' ', t)
    t = re.sub(r'(?<![a-z])sr(\d+)', r' \1', t)          # mfsr r0,sr0 == mfsr r0,0
    parts = t.split(None, 1)
    ops = parts[1] if len(parts) > 1 else ''
    for cc in re.findall(r'(?<![a-z])(lt|gt|eq|so|un)(?![a-z])', ops):
        crb.append(CC[cc])
    ops = re.sub(r'(?<![a-z])(lt|gt|eq|so|un)(?![a-z])', ' ', ops)
    regs = re.findall(r'(?<![a-z0-9])([rf]\d+|cr\d)(?![0-9])', ops)
    regs = [r for r in regs if r != 'cr0']
    ops = re.sub(r'(?<![a-z0-9])([rf]\d+|cr\d)(?![0-9])', ' ', ops)
    return sorted(regs), sorted(crb), nums(ops)


def ppc_mame(build, data, base, tmp):
    path = os.path.join(tmp, 'xc.bin')
    with open(path, 'wb') as f:
        f.write(data)
    out = subprocess.run([os.path.join(build, 'mamedis'), 'ppc', path, '0', str(len(data)), '0x%X' % base],
                         capture_output=True, check=True).stdout.decode('latin-1')
    os.unlink(path)
    res = []
    for line in out.split('\n'):
        if not line:
            continue
        head, _, text = line.partition('\t')
        res.append(text.strip())
    return res


def ppc_check(args, rom, out):
    tools = ppclist.Tools(args.build, args.tmp)
    out.append('PowerPC: dingusppc (listings) vs MAME, word by word')
    out.append('-' * 76)
    total = collections.Counter()
    samples = collections.defaultdict(list)
    for name, s, e in PPC_REGIONS:
        data = rom[s:e]
        base = 0xFFC00000 + s
        d = tools.dingus(data, base)
        m = ppc_mame(args.build, data, base, args.tmp)
        c = collections.Counter()
        for i, ((w, dt, _, _), mt) in enumerate(zip(d, m)):
            dt = ppclist.fix_text(w, dt)
            dv = ppclist.is_valid(w, dt)
            mv = not (mt.startswith('?') or mt == '')
            if not dv and not mv:
                c['both invalid'] += 1
                continue
            if dv != mv:
                k = 'only dingusppc decodes' if dv else 'only MAME decodes'
                c[k] += 1
                op = w >> 26
                key = (k, op)
                if len(samples[key]) < 3:
                    samples[key].append('%08X %08X  dingus: %-36s MAME: %s' % (base + 4 * i, w, dt, mt))
                continue
            dm, mm = dt.split()[0].rstrip('+-'), mt.split()[0]
            dr, dc, dn = ppc_fields(dt)
            mr, mc, mn = ppc_fields(mt)
            op = w >> 26
            if dm == mm and (dr, dc, dn) == (mr, mc, mn):
                c['agree'] += 1
            elif dr == mr and dc == mc and dn == mn:
                c['agree, other mnemonic for the same instruction (simplified forms)'] += 1
                key = ('mnemonic', dm, mm)
                if len(samples[key]) < 1:
                    samples[key].append('%08X %08X  dingus: %-36s MAME: %s' % (base + 4 * i, w, dt, mt))
            elif op in (20, 21, 23) and dr == mr:
                c['agree on registers, rotate written as fields vs mask'] += 1
                key = ('rotate', dm, mm)
                if len(samples[key]) < 1:
                    samples[key].append('%08X %08X  dingus: %-36s MAME: %s' % (base + 4 * i, w, dt, mt))
            elif (op == 16 and dr == mr and dn and mn and max(dn) == max(mn)) or (op == 19 and dr == mr):
                c['agree on target, BO/BI written differently'] += 1
                key = ('branch', dm, mm)
                if len(samples[key]) < 1:
                    samples[key].append('%08X %08X  dingus: %-36s MAME: %s' % (base + 4 * i, w, dt, mt))
            elif op == 31 and ((w >> 1) & 0x3FF) in (339, 467) and dr == mr:
                c['agree, SPR names spelled differently'] += 1
            elif (op == 3 or (op == 31 and ((w >> 1) & 0x3FF) == 4)) and dr == mr:
                c['agree, trap condition written differently'] += 1
            elif op == 31 and ((w >> 1) & 0x3FF) == 144 and dr == mr:
                c['agree, mtcr vs mtcrf 0xFF'] += 1
            elif op == 31 and ((w >> 1) & 0x3FF) == 124 and set(dr) == set(mr):
                c['agree, nor vs not'] += 1
            else:
                c['differ'] += 1
                key = ('differ', dm, mm)
                if len(samples[key]) < 2:
                    samples[key].append('%08X %08X  dingus: %-36s MAME: %s' % (base + 4 * i, w, dt, mt))
        n = sum(c.values())
        out.append('%-30s %6d words: %s' % (name, n, ', '.join('%s %d' % kv for kv in c.most_common())))
        total.update(c)
    n = sum(total.values())
    out.append('%-30s %6d words: %s' % ('TOTAL', n, ', '.join('%s %d (%.2f%%)' % (k, v, 100.0 * v / n) for k, v in total.most_common())))
    out.append('')
    out.append('Samples of each kind of difference (one line per instruction class):')
    for key in sorted(samples, key=str):
        for line in samples[key]:
            out.append('  [%s] %s' % ('/'.join(str(x) for x in key), line))
    out.append('')


class Bu68k:
    def __init__(self, build, path, base):
        self.p = subprocess.Popen([os.path.join(build, 'bu68k'), '-s', path, '0x%X' % base],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)

    def batch(self, addrs):
        res = {}
        for k in range(0, len(addrs), 256):
            part = addrs[k:k + 256]
            self.p.stdin.write(b''.join(b'%X\n' % a for a in part))
            for a in part:
                line = self.p.stdout.readline().decode('latin-1').rstrip('\n')
                head, _, text = line.partition('\t')
                res[a] = (int(head.split()[1]), text.strip())
        return res

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def m68k_norm(mn):
    mn = mn.lower().replace('.', '')
    return mn


def m68k_check(args, rom, out, listing):
    out.append('68k: MAME (listings) vs binutils, at every instruction start of the 68k listing')
    out.append('-' * 76)
    starts = []
    for line in open(listing, encoding='utf-8'):
        if len(line) > 10 and line[8] in '* ?' and re.match(r'[0-9A-F]{8}[* ?] ', line):
            starts.append(int(line[:8], 16))
    mame = m68klist.M68kServer(args.build, args.rom, 0xFFC00000)
    mame.batch(starts)
    bu = Bu68k(args.build, args.rom, 0xFFC00000)
    b = bu.batch(starts)
    bu.close()
    c = collections.Counter()
    samples = collections.defaultdict(list)
    for a in starts:
        m = mame.cache[a]
        bl, bt = b[a]
        mt = m['text']
        if 'opcode 1010' in mt:
            c['A-line trap (both show raw)' if re.match(r'^0\d+$', bt) else 'A-line: binutils decodes'] += 1
            continue
        if bt.startswith('<error>') or re.match(r'^0\d+$', bt):
            c['only MAME decodes'] += 1
            k = ('only MAME', mt.split()[0] if mt else '')
            if len(samples[k]) < 3:
                samples[k].append('%08X  MAME: %-40s binutils: %s' % (a, mt, bt))
            continue
        if bl != m['len']:
            c['length differs'] += 1
            k = ('length', mt.split()[0])
            if len(samples[k]) < 3:
                samples[k].append('%08X  MAME(%d): %-36s binutils(%d): %s' % (a, m['len'], mt, bl, bt))
            continue
        mm = m68k_norm(mt.split()[0])
        bm = m68k_norm(bt.split()[0])
        if mm == bm or (mm.rstrip('bwls') == bm.rstrip('bwls')) or mm == bm[:-1] or bm == mm[:-1]:
            c['same length and mnemonic'] += 1
        else:
            c['same length, other mnemonic'] += 1
            k = ('mnemonic', mm, bm)
            if len(samples[k]) < 1:
                samples[k].append('%08X  MAME: %-40s binutils: %s' % (a, mt, bt))
    mame.close()
    n = sum(c.values())
    out.append('%d instruction starts: %s' % (n, ', '.join('%s %d (%.2f%%)' % (k, v, 100.0 * v / n) for k, v in c.most_common())))
    out.append('')
    out.append('Samples of each kind of difference:')
    for key in sorted(samples, key=str):
        for line in samples[key]:
            out.append('  [%s] %s' % ('/'.join(str(x) for x in key), line))
    out.append('')


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--rom', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--build', default=os.path.expanduser('~/.cache/ppcmac/romdisasm/build'))
    ap.add_argument('--tmp', default=os.environ.get('TMPDIR', os.path.expanduser('~/.cache/ppcmac/romdisasm/tmp')))
    ap.add_argument('--listing68k', default=os.path.join(os.path.dirname(here), '68k', '68k_main_FFC00000.lst'))
    args = ap.parse_args()
    rom = open(args.rom, 'rb').read()
    out = ['Disassembler cross-check', '=' * 76,
           'The listings use dingusppc\'s PowerPC disassembler and MAME\'s 68k disassembler. Here the',
           'same bytes go through an independent disassembler and the results are compared.',
           'Numbers are compared as values (hex/decimal, sign-extended 16-bit immediates folded),',
           'mnemonics as text; "simplified forms" are the same instruction written differently',
           '(e.g. mtsprg1 r1 vs mtspr sprg1,r1).', '']
    ppc_check(args, rom, out)
    if os.path.exists(args.listing68k):
        m68k_check(args, rom, out, args.listing68k)
    with open(args.out, 'w', newline='\n') as f:
        f.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
