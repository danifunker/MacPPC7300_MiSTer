#!/usr/bin/env python3
"""Programs for the DSPPC604 pipeline test bench (core_tb).

    python progs.py golden OUT [results.csv]   the real-604 integer vectors as code
    python progs.py random OUT COUNT [SEED]    random instruction stream for lockstep

The file format is described at the top of core_main.cpp.
"""

import csv
import os
import random
import sys

CODE_BASE = 0x00010000
DATA_A = 0x00800000          # base register r1
DATA_B = 0x00900001          # base register r2: deliberately unaligned
DATA_SPAN = 0x1000           # bytes initialised either side of each base


# ---- encoders ------------------------------------------------------------------
def D(op, rt, ra, imm):
    return (op << 26) | (rt << 21) | (ra << 16) | (imm & 0xFFFF)


def X(rt, ra, rb, xo, rc=0):
    return (31 << 26) | (rt << 21) | (ra << 16) | (rb << 11) | (xo << 1) | rc


def M(op, rs, ra, sh, mb, me, rc=0):
    return (op << 26) | (rs << 21) | (ra << 16) | (sh << 11) | (mb << 6) | (me << 1) | rc


def li32(r, v):
    """Load a 32-bit constant, in one instruction when it fits."""
    v &= 0xFFFFFFFF
    if v < 0x8000 or v >= 0xFFFF8000:
        return [D(14, r, 0, v)]                       # li
    if v & 0xFFFF == 0:
        return [D(15, r, 0, v >> 16)]                 # lis
    return [D(15, r, 0, v >> 16), D(24, r, r, v)]     # lis, ori


def mtspr(spr, rs):
    return (31 << 26) | (rs << 21) | ((spr & 31) << 16) | ((spr >> 5) << 11) | (467 << 1)


def mfspr(spr, rd):
    return (31 << 26) | (rd << 21) | ((spr & 31) << 16) | ((spr >> 5) << 11) | (339 << 1)


def mtcrf(mask, rs):
    return (31 << 26) | (rs << 21) | (mask << 12) | (144 << 1)


B_SELF = 0x48000000
XER, LR, CTR = 1, 8, 9


class Program:
    def __init__(self):
        self.words = []          # code
        self.checks = []         # (index into words, text)
        self.data = {}           # addr -> word

    def pc(self):
        return CODE_BASE + 4 * len(self.words)

    def write(self, path):
        with open(path, "w", newline="\n") as fh:
            fh.write("R %08X\n" % CODE_BASE)
            for a in sorted(self.data):
                fh.write("M %08X %08X\n" % (a, self.data[a]))
            for i, w in enumerate(self.words):
                fh.write("M %08X %08X\n" % (CODE_BASE + 4 * i, w))
            for i, text in self.checks:
                fh.write("C %08X %s\n" % (CODE_BASE + 4 * i, text))
            fh.write("E %08X\n" % (CODE_BASE + 4 * (len(self.words) - 1)))


# ---- the golden vectors as one program -----------------------------------------
def golden(out, path):
    p = Program()
    n = 0
    with open(path) as fh:
        for r in csv.DictReader(fh):
            insn = int(r["insn"], 16)
            if (insn >> 26) in (59, 63):
                continue                              # floating point joins in M4
            v = {k: int(r[k], 16) for k in r if k.startswith(("in_", "out_")) and "_f" not in k}
            setup = [
                li32(3, v["in_r3"]), li32(4, v["in_r4"]), li32(5, v["in_r5"]), li32(6, v["in_r6"]),
                li32(7, v["in_cr"]) + [mtcrf(0xFF, 7)],
                li32(8, v["in_xer"]) + [mtspr(XER, 8)],
                li32(9, v["in_ctr"]) + [mtspr(CTR, 9)],
            ]
            # vary which values are produced just ahead of the instruction
            k = n % len(setup)
            for group in setup[k:] + setup[:k]:
                p.words += group
            p.checks.append((len(p.words), "%08X %08X %08X %08X %08X %08X %08X %s#%s" % (
                v["out_r3"], v["out_r4"], v["out_r5"], v["out_r6"],
                v["out_cr"], v["out_xer"], v["out_ctr"], r["name"], r["index"])))
            p.words.append(insn)
            n += 1
    p.words.append(B_SELF)
    p.write(out)
    print("%d vectors, %d instructions -> %s" % (n, len(p.words), out))


# ---- random instruction streams ------------------------------------------------
# r0: small index, r1 and r2: data bases. None is ever a random destination, so
# every access stays inside the initialised data.
def gen_random(out, count, seed):
    rnd = random.Random(seed)
    p = Program()

    for base in (DATA_A & ~3, DATA_B & ~3):
        for a in range(base - DATA_SPAN, base + DATA_SPAN, 4):
            p.data[a] = rnd.getrandbits(32)

    def interesting():
        k = rnd.random()
        if k < 0.25:
            return rnd.choice((0, 1, 2, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x80000001, 0xFFFF, 0x10000))
        if k < 0.45:
            return rnd.getrandbits(rnd.randrange(1, 33))
        return rnd.getrandbits(32)

    # prologue: every register and CR, XER, LR, CTR defined
    p.words += li32(0, rnd.randrange(0, 40))
    p.words += li32(1, DATA_A)
    p.words += li32(2, DATA_B)
    for r in range(3, 32):
        p.words += li32(r, interesting())
    p.words += li32(3, rnd.getrandbits(32)) + [mtcrf(0xFF, 3)]
    p.words += li32(3, rnd.choice((0, 0x20000000, 0x80000000, 0xC0000000, 0xE0000000))) + [mtspr(XER, 3)]
    p.words += li32(3, rnd.getrandbits(32)) + [mtspr(LR, 3)]
    p.words += li32(3, rnd.getrandbits(32)) + [mtspr(CTR, 3)]
    p.words += li32(3, interesting())

    rd = lambda: rnd.randrange(3, 32)        # destination
    rs = lambda: rnd.randrange(0, 32)        # source
    base = lambda: rnd.choice((1, 2))
    bit = lambda: rnd.getrandbits(1)

    def simple(keep_ctr=False):
        """One instruction with no memory access and no branch."""
        k = rnd.randrange(16)
        if k <= 2:
            xo = rnd.choice((266, 10, 138, 40, 8, 136))          # add addc adde subf subfc subfe
            return X(rd(), rs(), rs(), xo, bit()) | (bit() << 10)
        if k == 3:
            xo = rnd.choice((202, 234, 200, 232, 104))           # addze addme subfze subfme neg
            return X(rd(), rs(), 0, xo, bit()) | (bit() << 10)
        if k == 4:
            xo = rnd.choice((28, 60, 124, 284, 316, 412, 444, 476))
            return X(rs(), rd(), rs(), xo, bit())
        if k == 5:
            return X(rs(), rd(), rs(), rnd.choice((24, 536, 792)), bit())            # slw srw sraw
        if k == 6:
            return X(rs(), rd(), rnd.randrange(32), 824, bit())                       # srawi
        if k == 7:
            op = rnd.choice((20, 21, 23))
            return M(op, rs(), rd(), rs() if op == 23 else rnd.randrange(32),
                     rnd.randrange(32), rnd.randrange(32), bit())
        if k == 8:
            op = rnd.choice((14, 15, 12, 13, 8, 7))              # addi addis addic addic. subfic mulli
            return D(op, rd(), rs(), rnd.getrandbits(16))
        if k == 9:
            return D(rnd.choice((24, 25, 26, 27, 28, 29)), rs(), rd(), rnd.getrandbits(16))
        if k == 10:
            crf = rnd.randrange(8) << 2
            if bit():
                return X(crf, rs(), rs(), rnd.choice((0, 32)))   # cmp cmpl
            return D(rnd.choice((10, 11)), crf, rs(), rnd.getrandbits(16))
        if k == 11:
            return X(rs(), rd(), 0, rnd.choice((26, 922, 954)), bit())                # cntlzw extsh extsb
        if k == 12:
            xo = rnd.choice((235, 235, 75, 11, 491, 459))        # mullw mulhw mulhwu divw divwu
            oe = bit() if xo in (235, 491, 459) else 0
            return X(rd(), rs(), rs(), xo, bit()) | (oe << 10)
        if k == 13:
            j = rnd.randrange(5)
            if j == 0:                                           # CR logic
                xo = rnd.choice((33, 129, 193, 225, 257, 289, 417, 449))
                return (19 << 26) | (rnd.randrange(32) << 21) | (rnd.randrange(32) << 16) | \
                       (rnd.randrange(32) << 11) | (xo << 1)
            if j == 1:
                return (19 << 26) | (rnd.randrange(8) << 23) | (rnd.randrange(8) << 18)   # mcrf
            if j == 2:
                return X(rd(), 0, 0, 19)                         # mfcr
            if j == 3:
                return mtcrf(rnd.getrandbits(8), rs())
            return X(rnd.randrange(8) << 2, 0, 0, 512)           # mcrxr
        if k == 14:
            j = rnd.randrange(5)
            if j < 3:
                return mfspr((XER, LR, CTR)[j], rd())
            return mtspr(LR if (j == 3 or keep_ctr) else CTR, rs())
        return D(14, rd(), 0, rnd.getrandbits(16))               # li

    def memory():
        """A group that loads or stores."""
        k = rnd.randrange(12)
        d = rnd.randrange(-256, 256)
        if k == 0:
            return [D(rnd.choice((32, 34, 40, 42)), rd(), base(), d)]                 # lwz lbz lhz lha
        if k == 1:
            return [D(rnd.choice((36, 38, 44)), rs(), base(), d)]                     # stw stb sth
        if k == 2:
            return [D(rnd.choice((33, 35, 41, 43)), rd(), base(), rnd.randrange(-12, 13))]
        if k == 3:
            return [D(rnd.choice((37, 39, 45)), rs(), base(), rnd.randrange(-12, 13))]
        if k == 4:
            xo = rnd.choice((23, 87, 279, 343, 534, 790))        # lwzx lbzx lhzx lhax lwbrx lhbrx
            return [X(rd(), base(), 0, xo) if bit() else X(rd(), 0, base(), xo)]
        if k == 5:
            xo = rnd.choice((151, 215, 407, 662, 918))           # stwx stbx sthx stwbrx sthbrx
            return [X(rs(), base(), 0, xo) if bit() else X(rs(), 0, base(), xo)]
        if k == 6:
            return [X(rd(), base(), 0, rnd.choice((55, 119, 311, 375)))]              # update, indexed
        if k == 7:
            return [X(rs(), base(), 0, rnd.choice((183, 247, 439)))]
        if k == 8:
            # lmw stmw: the 604 takes an alignment exception unless the address is
            # word-aligned, so go through a copy of the base with the low bits cleared
            t = rnd.randrange(3, 20)
            return [M(21, base(), t, 0, 0, 29),
                    D(46 if bit() else 47, rnd.randrange(20, 32), t, 4 * rnd.randrange(-16, 16))]
        if k == 9:
            first = rnd.randrange(3, 28)                         # lswi stswi: up to 4 registers
            return [X(first, base(), rnd.randrange(1, 17), 597 if bit() else 725)]
        # lswx stswx: byte count from XER
        first, t = rnd.randrange(3, 28), rd()
        count = rnd.randrange(0, 17)
        flags = rnd.choice((0, 0x20000000, 0x80000000, 0xA0000000))
        while first <= t <= first + 4:
            t = rd()
        return li32(t, flags | count) + [mtspr(XER, t), X(first, base(), 0, 533 if bit() else 661)]

    # groups: ('code', words) or ('br', kind, skip)
    groups = []
    total = 0
    while total < count:
        k = rnd.random()
        if k < 0.55:
            g = ("code", [simple()])
        elif k < 0.80:
            g = ("code", memory())
        elif k < 0.90:
            g = ("br", rnd.choice(("bc", "bc", "b", "bl", "bcctr_dec")), rnd.randrange(1, 6))
        elif k < 0.95:
            g = ("br", rnd.choice(("blr", "bctr")), rnd.randrange(1, 6))
        else:
            body = [simple(keep_ctr=True) for _ in range(rnd.randrange(1, 4))]
            t = rd()
            words = li32(t, rnd.randrange(1, 6)) + [mtspr(CTR, t)] + body
            words.append((16 << 26) | (16 << 21) | ((-4 * len(body)) & 0xFFFC))       # bdnz back
            g = ("code", words)
        groups.append(g)
        total += len(g[1]) if g[0] == "code" else 4

    # lay out: branch groups have a fixed size, so targets are known
    def size(g):
        if g[0] == "code":
            return len(g[1])
        return {"bc": 1, "b": 1, "bl": 1, "bcctr_dec": 1, "blr": 4, "bctr": 4}[g[1]]

    starts = []
    at = len(p.words)
    for g in groups:
        starts.append(at)
        at += size(g)
    end = at

    for i, g in enumerate(groups):
        if g[0] == "code":
            p.words += g[1]
            continue
        _, kind, skip = g
        target = starts[i + skip] if i + skip < len(groups) else end
        here = len(p.words)
        if kind in ("bc", "bcctr_dec"):
            if kind == "bc":
                bo = rnd.choice((12, 4, 12, 4, 20))              # if set, if clear, always
            else:
                bo = rnd.choice((16, 18, 8, 10, 0, 2))           # count CTR down, maybe test a bit
            p.words.append((16 << 26) | (bo << 21) | (rnd.randrange(32) << 16) | ((4 * (target - here)) & 0xFFFC))
        elif kind in ("b", "bl"):
            p.words.append((18 << 26) | ((4 * (target - here)) & 0x03FFFFFC) | (1 if kind == "bl" else 0))
        else:
            t = rd()
            addr = CODE_BASE + 4 * target
            spr, xo = (LR, 16) if kind == "blr" else (CTR, 528)
            bo = rnd.choice((20, 12, 4))
            p.words += [D(15, t, 0, addr >> 16), D(24, t, t, addr), mtspr(spr, t),
                        (19 << 26) | (bo << 21) | (rnd.randrange(32) << 16) | (xo << 1) | bit()]
    assert len(p.words) == end
    p.words.append(B_SELF)
    p.write(out)
    print("%d instructions -> %s" % (len(p.words), out))


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    a = sys.argv[1:]
    if len(a) >= 2 and a[0] == "golden":
        golden(a[1], a[2] if len(a) > 2 else os.path.join(here, "..", "ppctest", "runs", "results_604_run2.csv"))
    elif len(a) >= 3 and a[0] == "random":
        gen_random(a[1], int(a[2]), int(a[3]) if len(a) > 3 else 1)
    else:
        print(__doc__)
        sys.exit(2)
