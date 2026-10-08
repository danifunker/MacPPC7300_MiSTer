#!/usr/bin/env python3
"""Look into a raw RAM dump of the machine bench (--dump-bin) with Mac OS's
NanoKernel running: the hashed page table (base and mask from the kernel
data at physical 00FEE6A4 / 00FEE6A0), the PTEs by VSID, a logical
address's translation, low-memory globals, and hex dumps.

    python3 ramdump.py DUMP ptes [VSID]         list the PTEs (of one VSID)
    python3 ramdump.py DUMP xlate VSID EA       translate (VSID of the segment)
    python3 ramdump.py DUMP lowmem              MemTop, BufPtr, vectors...
    python3 ramdump.py DUMP hex PHYS LEN        a hex dump of physical memory
    python3 ramdump.py DUMP find HEXBYTES       search physical memory
"""
import struct
import sys

KDATA = 0x00FEE000


def rd32(m, a):
    return struct.unpack(">I", m[a:a + 4])[0]


def ptes(m):
    base = rd32(m, KDATA + 0x6A4)
    mask = rd32(m, KDATA + 0x6A0)
    out = []
    size = (mask | 0xFFFF) + 1 if mask else 0x10000
    for off in range(0, size, 8):
        a = base + off
        if a + 8 > len(m):
            break
        w0, w1 = rd32(m, a), rd32(m, a + 4)
        if w0 & 0x80000000:
            out.append((a, w0, w1))
    return base, mask, out


def hash_pteg(base, mask, vsid, ea, secondary=False):
    page = (ea >> 12) & 0xFFFF
    h = (vsid & 0x7FFFF) ^ page
    if secondary:
        h = ~h & 0x7FFFF
    hi = (h >> 10) & (mask & 0x1FF) if False else ((h >> 10) & 0x1FF) & (mask & 0x1FF)
    lo = h & 0x3FF
    # HTABORG | (((h >> 10) & HTABMASK) << 16) | ((h & 0x3FF) << 6)
    return (base & 0xFFFF0000) | ((((h >> 10) & 0x1FF) & (mask & 0x1FF)) << 16) | (lo << 6)


def xlate(m, vsid, ea):
    base, mask, _ = ptes(m)
    api = (ea >> 22) & 0x3F
    for sec in (False, True):
        pteg = hash_pteg(base, mask, vsid, ea, sec)
        for i in range(8):
            a = pteg + 8 * i
            w0, w1 = rd32(m, a), rd32(m, a + 4)
            if (w0 & 0x80000000) and ((w0 >> 7) & 0xFFFFFF) == vsid and (w0 & 0x3F) == api and ((w0 >> 6) & 1) == sec:
                return a, w0, w1, (w1 & 0xFFFFF000) | (ea & 0xFFF)
    return None


def main():
    m = open(sys.argv[1], "rb").read()
    cmd = sys.argv[2]
    if cmd == "ptes":
        base, mask, lst = ptes(m)
        print("hash table at %08X, mask %08X: %d valid PTEs" % (base, mask, len(lst)))
        want = int(sys.argv[3], 16) if len(sys.argv) > 3 else None
        byv = {}
        for a, w0, w1 in lst:
            v = (w0 >> 7) & 0xFFFFFF
            byv.setdefault(v, []).append((a, w0, w1))
        for v in sorted(byv):
            print("VSID %06X: %d PTEs" % (v, len(byv[v])))
        if want is not None:
            for a, w0, w1 in byv.get(want, []):
                print("  %08X: %08X %08X  api %02X h %d rpn %05X R%d C%d WIMG %X pp %d" % (
                    a, w0, w1, w0 & 0x3F, (w0 >> 6) & 1, w1 >> 12, (w1 >> 8) & 1, (w1 >> 7) & 1, (w1 >> 3) & 0xF, w1 & 3))
    elif cmd == "xlate":
        vsid, ea = int(sys.argv[3], 16), int(sys.argv[4], 16)
        r = xlate(m, vsid, ea)
        print("no PTE" if r is None else "PTE at %08X: %08X %08X -> physical %08X" % r)
    elif cmd == "lowmem":
        for name, a in (("MemTop", 0x108), ("BufPtr", 0x10C), ("SysZone", 0x2A6), ("ApplZone", 0x2AA), ("ROMBase", 0x2AE),
                        ("RAMBase", 0x2B2), ("HeapEnd", 0x114), ("ApplLimit", 0x130), ("CurrentA5", 0x904), ("vector 2 (bus error)", 0x8),
                        ("vector 3 (address error)", 0xC), ("MemErr", 0x220), ("SysEvtMask", 0x144), ("BootDrive", 0x210), ("Ticks", 0x16A)):
            print("  %-24s %08X" % (name, rd32(m, a)))
    elif cmd == "hex":
        a, n = int(sys.argv[3], 16), int(sys.argv[4], 16)
        for o in range(a, a + n, 16):
            print("%08X  %s  %s" % (o, " ".join("%02X" % b for b in m[o:o + 16]),
                                     "".join(chr(b) if 32 <= b < 127 else "." for b in m[o:o + 16])))
    elif cmd == "find":
        pat = bytes.fromhex(sys.argv[3])
        i = m.find(pat)
        n = 0
        while i >= 0 and n < 40:
            print("  %08X" % i)
            n += 1
            i = m.find(pat, i + 1)


if __name__ == "__main__":
    main()
