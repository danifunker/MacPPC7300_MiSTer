#!/usr/bin/env python3
"""Write the model-predicted part of the version-4 vector set.

    python v4gen.py            ->  v4/model_random.csv, v4/model_targeted.csv,
                                   v4/MANIFEST.txt

Both files are in the results-CSV format, with the outputs verilator/fpmodel.py
predicts. `ppctest.py build` puts them on the disk as expected values, so the
`miss` count the Mac prints is the number of vectors on which processor and
model disagree. fpmodel.py is only imported, never changed; its SHA-256 at the
time of writing is noted in the manifest, and a results file can be compared
with a later model at any time (`python verilator/fpmodel.py check FILE`).

  model_random.csv    fpmodel.py's own random generator.
  model_targeted.csv  model-enable  overflow / underflow / zero divide / inexact /
                                    invalid with the matching enable bits set
                      model-ni      FPSCR[NI] set, denormal operands and results
                      model-ni0     the same vectors with NI clear
                      model-rsqrte  frsqrte: every table entry, both exponent parities
                      model-sweep   frsqrte and fres over the top 8 fraction bits
                      model-mem     lfs / stfs / stfiwx through the memory buffer
A row whose result the architecture leaves undefined (the model says so) has
the verdict `undefined` and goes on the disk without an expected value.
"""

import csv
import hashlib
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.normpath(os.path.join(HERE, "..", "verilator"))
sys.path.insert(0, MODEL_DIR)
import fpmodel as M                                    # noqa: E402

from vectors import CSV_COLUMNS, V4_DIR                # noqa: E402

RANDOM_COUNT, RANDOM_SEED = 20000, 604
SEED = 2026

FRAC = (1 << 52) - 1
SIGN = 1 << 63
VE, OE, UE, ZE, XE, NI = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04
STICKY_ETC = M.STICKY | M.FR | M.FI | M.FPRF

# mnemonic: (opcode, extended opcode, operands used)
OPS = {
    "FADD": (63, 21, "ab"), "FSUB": (63, 20, "ab"), "FMUL": (63, 25, "ac"), "FDIV": (63, 18, "ab"),
    "FADDS": (59, 21, "ab"), "FSUBS": (59, 20, "ab"), "FMULS": (59, 25, "ac"), "FDIVS": (59, 18, "ab"),
    "FMADD": (63, 29, "abc"), "FMSUB": (63, 28, "abc"), "FNMADD": (63, 31, "abc"),
    "FNMSUB": (63, 30, "abc"), "FMADDS": (59, 29, "abc"), "FMSUBS": (59, 28, "abc"),
    "FNMADDS": (59, 31, "abc"), "FNMSUBS": (59, 30, "abc"),
    "FRES": (59, 24, "b"), "FRSQRTE": (63, 26, "b"), "FRSP": (63, 12, "b"),
    "FCTIW": (63, 14, "b"), "FCTIWZ": (63, 15, "b"), "FCMPU": (63, 0, "ab"), "FCMPO": (63, 32, "ab"),
}
FMA = ("FMADD", "FMSUB", "FNMADD", "FNMSUB")


class Writer:
    def __init__(self, fh):
        self.w = csv.writer(fh, lineterminator="\n")
        self.w.writerow(CSV_COLUMNS)
        self.n = 0
        self.counts = {}

    def row(self, name, src, insn, verdict, r=(0, 0, 0, 0), cr=0, xer=0, fpscr=0, f=(0, 0, 0),
            out_r=None, out_cr=None, out_fpscr=None, out_f=None):
        out_r = r if out_r is None else out_r
        out_cr = cr if out_cr is None else out_cr
        out_fpscr = fpscr if out_fpscr is None else out_fpscr
        out_f = (0,) + tuple(f) if out_f is None else out_f
        h8, h16 = (lambda v: "%08X" % v), (lambda v: "%016X" % v)
        self.w.writerow([self.n, name, src, h8(insn)] + [h8(v) for v in r]
                        + [h8(cr), h8(xer), h8(0), h8(fpscr)] + [h16(v) for v in f]
                        + [h8(v) for v in out_r] + [h8(out_cr), h8(xer), h8(0), h8(out_fpscr)]
                        + [h16(v) for v in out_f] + [verdict])
        self.n += 1
        self.counts[src] = self.counts.get(src, 0) + 1

    def fp(self, src, name, a, b, c, fpscr, rc=0, cr=0):
        """One floating-point instruction with the model's prediction."""
        op, xo, uses = OPS[name]
        M.UNDEFINED = False
        res, new, crf = M.execute(name, a, b, c, fpscr)
        verdict = "undefined" if M.UNDEFINED else "model"
        if crf is not None:                                  # compare: crfD = 1
            insn = (op << 26) | (4 << 21) | (4 << 16) | (5 << 11) | (xo << 1)
            out_cr, rc = (cr & ~0x0F000000) | (crf << 24), 0
        else:
            fa, fb, fc = (4 if "a" in uses else 0), (5 if "b" in uses else 0), (6 if "c" in uses else 0)
            insn = (op << 26) | (3 << 21) | (fa << 16) | (fb << 11) | (fc << 6) | (xo << 1) | rc
            out_cr = ((cr & ~0x0F000000) | ((new >> 28) << 24)) if rc else cr
        f3 = 0 if res is None else res
        self.row(name + ("." if rc else ""), src, insn, verdict, cr=cr, fpscr=fpscr, f=(a, b, c),
                 out_cr=out_cr, out_fpscr=new, out_f=(f3, a, b, c))


# ---- operands --------------------------------------------------------------------
def frac(rnd):
    f = rnd.getrandbits(52)
    k = rnd.random()
    if k < 0.20:
        f &= ~0x1FFFFFFF                                 # exactly a single
    elif k < 0.30:
        f = (f & ~0x1FFFFFFF) | rnd.choice((0x10000000, 0x0FFFFFFF, 0x10000001, 0x18000000,
                                            0x08000000))
    elif k < 0.40:
        f = rnd.choice((0, FRAC, 1, FRAC - 1, FRAC & ~0x1FFFFFFF, 1 << rnd.randrange(52)))
    elif k < 0.48:
        f >>= rnd.randrange(52)                          # few significant bits
    return f


def mk(rnd, e, sign=None):
    """A double whose leading one has weight 2**e; a denormal when e < -1022."""
    s = (rnd.getrandbits(1) if sign is None else sign) << 63
    e = min(e, 1023)
    if e >= -1022:
        return s | ((e + 1023) << 52) | frac(rnd)
    sh = -1022 - e
    m = ((1 << 52) | frac(rnd)) >> sh if sh <= 52 else 0
    return s | (m or 1)


def split(rnd, te):
    """Two exponents that add up to te, both representable."""
    lo, hi = max(-1060, te - 1023), min(1023, te + 1060)
    ea = rnd.randint(lo, hi)
    return ea, te - ea


def arith_at(rnd, te, single):
    """An instruction whose exact result has an exponent near te.
    Returns (name, a, b, c)."""
    k = rnd.random()
    sfx = "S" if single else ""
    if k < 0.30:
        ea, ec = split(rnd, te)
        return "FMUL" + sfx, mk(rnd, ea), 0, mk(rnd, ec)
    if k < 0.55:
        ea, eb = split(rnd, te)
        return "FDIV" + sfx, mk(rnd, ea), mk(rnd, -eb), 0
    if k < 0.70:
        a = mk(rnd, te)
        b = mk(rnd, te - rnd.choice((0, 0, 1, 1, 2, 3, 30, 60)))
        return rnd.choice(("FADD", "FSUB")) + sfx, a, b, 0
    if k < 0.90 or not single:
        ea, ec = split(rnd, te)
        b = mk(rnd, te - rnd.choice((0, 1, 2, 5, 40, 80, -1, -3)))
        if rnd.random() < 0.15:
            b = rnd.choice((0, SIGN))
        return rnd.choice(FMA) + sfx, mk(rnd, ea), b, mk(rnd, ec)
    return "FRSP", 0, mk(rnd, te), 0


def exponent(rnd, kind, single):
    k = rnd.random()
    if kind == "overflow":
        if single:
            return (rnd.randint(125, 130) if k < 0.45 else
                    rnd.randint(131, 319) if k < 0.85 else rnd.randint(320, 1100))
        return rnd.randint(1021, 1026) if k < 0.55 else rnd.randint(1027, 1900)
    if single:
        return (rnd.randint(-129, -124) if k < 0.35 else rnd.randint(-150, -130) if k < 0.75 else
                rnd.randint(-320, -151) if k < 0.90 else rnd.randint(-1000, -321))
    return (rnd.randint(-1026, -1020) if k < 0.35 else rnd.randint(-1075, -1027) if k < 0.80 else
            rnd.randint(-1200, -1076))


def enables(rnd, main, p_main=0.7):
    f = rnd.getrandbits(2)
    if rnd.random() < p_main:
        f |= main
    for bit, p in ((VE, 0.15), (OE, 0.15), (UE, 0.15), (ZE, 0.15), (XE, 0.30)):
        if rnd.random() < p:
            f |= bit
    if rnd.random() < 0.25:                              # status left by earlier instructions
        f |= rnd.getrandbits(32) & STICKY_ETC
        f = M.summarise(f)
        if rnd.getrandbits(1) or (f & M.STICKY and rnd.getrandbits(2)):
            f |= M.FX
    return f


def rc_cr(rnd):
    return rnd.getrandbits(1), (rnd.getrandbits(32) if rnd.random() < 0.3 else 0)


# ---- the targeted groups -------------------------------------------------------------
def gen_enables(w, rnd):
    src = "model-enable"
    for kind, main in (("overflow", OE), ("underflow", UE)):
        for single in (False, True):
            for _ in range(1500):
                name, a, b, c = arith_at(rnd, exponent(rnd, kind, single), single)
                rc, cr = rc_cr(rnd)
                w.fp(src, name, a, b, c, enables(rnd, main), rc, cr)
    zero = lambda: rnd.choice((0, SIGN))
    for _ in range(1000):                                # zero divide
        k = rnd.random()
        rc, cr = rc_cr(rnd)
        f = enables(rnd, ZE, 0.75)
        if k < 0.55:
            a = rnd.choice((mk(rnd, rnd.randint(-1074, 1023)), mk(rnd, rnd.randint(-60, 60)),
                            M.INF | zero(), zero(), M.QNAN, 0x7FF4000000000000))
            w.fp(src, rnd.choice(("FDIV", "FDIVS")), a, zero(), 0, f, rc, cr)
        elif k < 0.80:
            w.fp(src, "FRES", 0, zero(), 0, f, rc, cr)
        else:
            w.fp(src, "FRSQRTE", 0, zero(), 0, f, rc, cr)
    for _ in range(800):                                 # inexact
        k = rnd.random()
        rc, cr = rc_cr(rnd)
        f = enables(rnd, XE, 0.8)
        if k < 0.70:
            name, a, b, c = arith_at(rnd, rnd.randint(-100, 100), rnd.random() < 0.5)
            w.fp(src, name, a, b, c, f, rc, cr)
        elif k < 0.85:
            w.fp(src, rnd.choice(("FCTIW", "FCTIWZ")), 0, mk(rnd, rnd.randint(-5, 30)), 0, f, rc, cr)
        else:
            w.fp(src, "FRSP", 0, mk(rnd, rnd.randint(-140, 126)), 0, f, rc, cr)
    inf = lambda: M.INF | zero()
    snan = lambda: 0x7FF0000000000000 | zero() | (rnd.getrandbits(51) or 1)
    num = lambda: mk(rnd, rnd.randint(-40, 40))
    for _ in range(700):                                 # invalid operation
        rc, cr = rc_cr(rnd)
        f = enables(rnd, VE, 0.75)
        sfx = rnd.choice(("", "S"))
        k = rnd.randrange(12)
        if k == 0:
            x = inf()
            w.fp(src, "FADD" + sfx, x, x ^ SIGN, 0, f, rc, cr)
        elif k == 1:
            x = inf()
            w.fp(src, "FSUB" + sfx, x, x, 0, f, rc, cr)
        elif k == 2:
            w.fp(src, "FMUL" + sfx, inf(), 0, zero(), f, rc, cr)
        elif k == 3:
            w.fp(src, "FDIV" + sfx, zero(), zero(), 0, f, rc, cr)
        elif k == 4:
            w.fp(src, "FDIV" + sfx, inf(), inf(), 0, f, rc, cr)
        elif k == 5:
            name = rnd.choice(("FADD", "FSUB", "FMUL", "FDIV") + FMA) + sfx
            ops = [num(), num(), num()]
            ops[rnd.randrange(3)] = snan()
            if rnd.random() < 0.3:
                ops[rnd.randrange(3)] = M.QNAN | rnd.getrandbits(20)
            w.fp(src, name, ops[0], ops[1], ops[2], f, rc, cr)
        elif k == 6:
            b = rnd.choice((snan(), M.QNAN, inf(), mk(rnd, rnd.randint(31, 70)),
                            0x41DFFFFFFFE00000, 0xC1E0000000100000))
            w.fp(src, rnd.choice(("FCTIW", "FCTIWZ")), 0, b, 0, f, rc, cr)
        elif k == 7:
            w.fp(src, "FRSQRTE", 0, rnd.choice((mk(rnd, rnd.randint(-1074, 1023), 1),
                                                M.INF | SIGN, snan())), 0, f, rc, cr)
        elif k == 8:
            a, b = rnd.choice(((M.QNAN, num()), (num(), M.QNAN), (snan(), num()), (num(), snan()),
                               (snan(), M.QNAN)))
            w.fp(src, rnd.choice(("FCMPO", "FCMPU")), a, b, 0, f, 0, cr)
        elif k == 9:                                     # inf * 0 + x
            w.fp(src, rnd.choice(FMA) + sfx, inf(), rnd.choice((num(), inf(), M.QNAN)), zero(),
                 f, rc, cr)
        elif k == 10:                                    # inf * x -/+ inf
            a, c = inf(), num()
            name = rnd.choice(FMA)
            b = M.INF | ((((a ^ c) >> 63) ^ (0 if name in ("FMSUB", "FNMSUB") else 1)) << 63)
            w.fp(src, name + sfx, a, b, c, f, rc, cr)
        else:
            w.fp(src, rnd.choice(("FRSP", "FRES")), 0, snan(), 0, f, rc, cr)


def gen_ni(w, rnd):
    """Each case twice: FPSCR[NI] set, and the identical vector with it clear."""
    def both(name, a, b, c, f, rc, cr):
        w.fp("model-ni", name, a, b, c, f | NI, rc, cr)
        w.fp("model-ni0", name, a, b, c, f & ~NI, rc, cr)

    def mode():
        f = rnd.getrandbits(2)
        for bit, p in ((UE, 0.15), (OE, 0.08), (XE, 0.10)):
            if rnd.random() < p:
                f |= bit
        return f

    den = lambda: (rnd.getrandbits(1) << 63) | rnd.choice(
        (1, FRAC, 1 << 51, rnd.getrandbits(52) or 1, (rnd.getrandbits(52) >> rnd.randrange(52)) or 1))
    for single in (False, True):                         # results in the denormal range
        for _ in range(1000):
            name, a, b, c = arith_at(rnd, exponent(rnd, "underflow", single), single)
            rc, cr = rc_cr(rnd)
            both(name, a, b, c, mode(), rc, cr)
    for _ in range(2000):                                # denormal operands
        rc, cr = rc_cr(rnd)
        sfx = rnd.choice(("", "S"))
        k = rnd.randrange(10)
        far = lambda: mk(rnd, rnd.choice((rnd.randint(-1022, -960), rnd.randint(-60, 60),
                                          rnd.randint(900, 1023))))
        if k == 0:
            both("FMUL" + sfx, den(), 0, far(), mode(), rc, cr)
        elif k == 1:
            both("FDIV" + sfx, den(), far(), 0, mode(), rc, cr)
        elif k == 2:
            both("FDIV" + sfx, far(), den(), 0, mode(), rc, cr)
        elif k == 3:
            both(rnd.choice(("FADD", "FSUB")) + sfx, den(), rnd.choice((den(), far(), 0)), 0,
                 mode(), rc, cr)
        elif k == 4:
            ops = [far(), far(), far()]
            ops[rnd.randrange(3)] = den()
            both(rnd.choice(FMA) + sfx, ops[0], ops[1], ops[2], mode(), rc, cr)
        elif k == 5:
            both("FRSP", 0, rnd.choice((den(), mk(rnd, rnd.randint(-160, -120)))), 0, mode(), rc, cr)
        elif k == 6:
            both(rnd.choice(("FCTIW", "FCTIWZ")), 0, den(), 0, mode(), rc, cr)
        elif k == 7:
            both(rnd.choice(("FCMPU", "FCMPO")), den(), rnd.choice((den(), 0, SIGN, far())), 0,
                 mode(), 0, cr)
        elif k == 8:
            both("FRSQRTE", 0, den() & ~SIGN, 0, mode(), rc, cr)
        else:
            both(rnd.choice(("FRES", "FMUL" + sfx)), den(), den(), den(), mode(), rc, cr)


def gen_estimates(w, rnd):
    # frsqrte: each of the 16 top-fraction values, first / middle / last operand
    # of its interval, both exponent parities, two exponents each
    for e in (1023, 1123, 1024, 922):                    # unbiased 0, 100 (even); 1, -101 (odd)
        for n in range(16):
            for low in (0, 1 << 47, (1 << 48) - 1):
                w.fp("model-rsqrte", "FRSQRTE", 0, (e << 52) | (n << 48) | low, 0, 0)
    for lz in (0, 1, 2, 3, 4, 10, 30, 50, 51):           # denormal operands
        top = 1 << (51 - lz)
        for low in (0, top - 1, rnd.getrandbits(52) & (top - 1)):
            w.fp("model-rsqrte", "FRSQRTE", 0, top | low, 0, 0)
    for rn in range(4):
        for rc in (0, 1):
            for b in (0x3FF8000000000000, 0x4000000000000001, 0x7FEFFFFFFFFFFFFF,
                      0x0010000000000000):
                w.fp("model-rsqrte", "FRSQRTE", 0, b, 0, rn, rc)
    # finer sweeps: the top 8 fraction bits, first and last operand of each step
    for e in (1023, 1024):
        for n in range(256):
            for low in (0, (1 << 44) - 1):
                w.fp("model-sweep", "FRSQRTE", 0, (e << 52) | (n << 44) | low, 0, 0)
    for n in range(256):
        for low in (0, (1 << 44) - 1):
            w.fp("model-sweep", "FRES", 0, (1023 << 52) | (n << 44) | low, 0, 0)
    for rn in range(4):
        for _ in range(32):
            w.fp("model-sweep", "FRES", 0, mk(rnd, rnd.randint(-126, 126)), 0, rn)


BUF_STORE = 0x5A5A5A5AA5A5A5A5


def gen_mem(w, rnd):
    """lfs, stfs and stfiwx through the 8-byte buffer at (r6). The buffer's
    contents travel in f6's columns."""
    src = "model-mem"
    d = lambda op, rt, disp: (op << 26) | (rt << 21) | (6 << 16) | disp
    x = lambda rt, xo: (31 << 26) | (rt << 21) | (6 << 11) | (xo << 1)     # rA = 0

    def store(name, insn, value, single, at=0, fpscr=0):
        buf = bytearray(BUF_STORE.to_bytes(8, "big"))
        buf[at:at + 4] = single.to_bytes(4, "big")
        w.row(name, src, insn, "model", fpscr=fpscr, f=(value, 0, BUF_STORE),
              out_r=(0, 0, 0, at), out_f=(0, value, 0, int.from_bytes(buf, "big")))

    def load(name, insn, single, at=0, fpscr=0):
        buf = bytearray((0xDEADBEEF0BADF00D).to_bytes(8, "big"))
        buf[at:at + 4] = single.to_bytes(4, "big")
        buf = int.from_bytes(buf, "big")
        w.row(name, src, insn, "model", fpscr=fpscr, f=(0, 0, buf),
              out_r=(0, 0, 0, at), out_f=(M.single_to_double(single), 0, 0, buf))

    fracs = lambda: (0, FRAC, 1 << 51, FRAC & ~0x1FFFFFFF, 0x10000000, rnd.getrandbits(52))
    values = []
    for e in list(range(874, 898)) + [873, 872, 850, 700, 1, 0, 1022, 1023, 1150, 1151, 1200, 2046]:
        for fr in fracs():
            values.append((rnd.getrandbits(1) << 63) | (e << 52) | fr)
    values += [0, SIGN, M.INF, M.INF | SIGN, M.QNAN, 0x7FF4000000000000, 0xFFF8000000000001,
               0x7FF0000000000001, 0x7FF000001FFFFFFF, 0xFFF7FFFFFFFFFFFF]
    values += [rnd.getrandbits(64) for _ in range(100)]
    for v in values:
        store("STFS", d(52, 4, 0), v, M.double_to_single(v))
    for v in values[::17]:
        store("STFSX", x(4, 663), v, M.double_to_single(v))
        store("STFSU", d(53, 4, 4), v, M.double_to_single(v), at=4)
        store("STFIWX", x(4, 983), v, v & 0xFFFFFFFF)
    for v in (0xFFF8000012345678, 0xFFF8000080000000, 0xFFF800007FFFFFFF, 0x00000000FFFFFFFF):
        store("STFIWX", x(4, 983), v, v & 0xFFFFFFFF)
    # a rounding mode and enables must make no difference to a store
    for v in values[5::29]:
        store("STFS", d(52, 4, 0), v, M.double_to_single(v), fpscr=0x000000FB)

    singles = [0x00000001, 0x007FFFFF, 0x00400000, 0x00000100, 0x00800000, 0x7F7FFFFF,
               0x3F800000, 0x7F800000, 0xFF800000, 0x00000000, 0x80000000,
               0x7F800001, 0x7FA00000, 0xFFBFFFFF, 0x7F8FFFFF,          # signalling NaNs
               0x7FC00000, 0x7FFFFFFF, 0xFFC00001]                      # quiet NaNs
    singles += [(rnd.getrandbits(1) << 31) | rnd.getrandbits(23) for _ in range(40)]     # denormals
    singles += [(rnd.getrandbits(1) << 31) | (rnd.getrandbits(23) >> rnd.randrange(23)) or 1
                for _ in range(20)]
    singles += [rnd.getrandbits(32) for _ in range(40)]
    for s in singles:
        load("LFS", d(48, 3, 0), s)
    for s in singles[::5]:
        load("LFSX", x(3, 535), s)
        load("LFSU", d(49, 3, 4), s, at=4)
        load("LFS", d(48, 3, 0), s, fpscr=0x000000FB)
    # lfd and stfd move 64 bits unchanged
    for v in values[3::37]:
        w.row("LFD", src, d(50, 3, 0), "model", f=(0, 0, v), out_f=(v, 0, 0, v))
        w.row("STFD", src, d(54, 4, 0), "model", f=(v, 0, BUF_STORE), out_f=(0, v, 0, v))


def sha256(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def main():
    os.makedirs(V4_DIR, exist_ok=True)
    random_csv = os.path.join(V4_DIR, "model_random.csv")
    with open(random_csv, "w", newline="") as fh:
        M.gen_random(RANDOM_COUNT, RANDOM_SEED, fh)
    targeted_csv = os.path.join(V4_DIR, "model_targeted.csv")
    rnd = random.Random(SEED)
    with open(targeted_csv, "w", newline="") as fh:
        w = Writer(fh)
        gen_enables(w, rnd)
        gen_ni(w, rnd)
        gen_estimates(w, rnd)
        gen_mem(w, rnd)
    lines = ["Model-predicted vectors of the version-4 set, written by v4gen.py.",
             "fpmodel.py SHA-256: " + sha256(os.path.join(MODEL_DIR, "fpmodel.py")),
             "model_random.csv:   %d vectors, fpmodel.py random, seed %d" % (RANDOM_COUNT, RANDOM_SEED),
             "model_targeted.csv: %d vectors, seed %d" % (w.n, SEED)]
    lines += ["  %-13s %6d" % kv for kv in sorted(w.counts.items())]
    with open(os.path.join(V4_DIR, "MANIFEST.txt"), "w", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
