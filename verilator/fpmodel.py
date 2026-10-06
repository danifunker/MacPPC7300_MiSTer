#!/usr/bin/env python3
"""Bit-exact software model of the PowerPC 604 floating-point unit.

The executable specification for DSPPC604_fpu. It is written for clarity, with
exact integer arithmetic, and is checked against the vectors recorded on a
real 604 (two runs on a Power Macintosh 7600, one on a 7300; the 7300 run
covers non-IEEE mode, the enabled exceptions, the loads and stores and the
FPSCR instructions):

    python fpmodel.py check [results.csv]      compare with real-hardware data
    python fpmodel.py random N SEED x.csv      vectors with modelled results,
                                               in the same CSV format

The random vectors exercise datapath corners the hardware set does not reach;
replay them with `run.py --csv x.csv`.
"""

import csv
import os
import random
import sys

# ---- FPSCR ---------------------------------------------------------------------
FX, FEX, VX, OX = 0x80000000, 0x40000000, 0x20000000, 0x10000000
UX, ZX, XX, VXSNAN = 0x08000000, 0x04000000, 0x02000000, 0x01000000
VXISI, VXIDI, VXZDZ, VXIMZ = 0x00800000, 0x00400000, 0x00200000, 0x00100000
VXVC, FR, FI = 0x00080000, 0x00040000, 0x00020000
FPRF, FPCC = 0x0001F000, 0x0000F000
VXSOFT, VXSQRT, VXCVI = 0x00000400, 0x00000200, 0x00000100
VE, OE, UE, ZE, XE, NI, RN = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x03
VX_ALL = VXSNAN | VXISI | VXIDI | VXZDZ | VXIMZ | VXVC | VXSOFT | VXSQRT | VXCVI
STICKY = OX | UX | ZX | XX | VX_ALL

SIGN = 1 << 63
FRAC = (1 << 52) - 1
QBIT = 1 << 51
QNAN = 0x7FF8000000000000
INF = 0x7FF0000000000000


def cls(x):
    e, f = (x >> 52) & 0x7FF, x & FRAC
    if e == 0x7FF:
        return "inf" if f == 0 else ("qnan" if f & QBIT else "snan")
    if e == 0:
        return "zero" if f == 0 else "den"
    return "norm"


def is_nan(x):
    return cls(x) in ("qnan", "snan")


def value(x):
    """Finite non-zero x as (M, E): magnitude M * 2**E."""
    e, f = (x >> 52) & 0x7FF, x & FRAC
    return (f | (1 << 52), e - 1075) if e else (f, -1074)


def fprf_of(x, single, den=False):
    """The result class. den: the result was denormalised in its own format
    (a single-precision denormal is held as a normalised double, so it cannot
    be told from its bits). A result an enabled underflow scaled into range
    is a normal number whatever its exponent, as the 604 reports it."""
    s, c = x >> 63, cls(x)
    if c in ("qnan", "snan"):
        return 0x11
    if c == "inf":
        return 0x09 if s else 0x05
    if c == "zero":
        return 0x12 if s else 0x02
    if c == "den" or den:
        return 0x18 if s else 0x14
    return 0x08 if s else 0x04


# Nothing this model computes is undefined any more: the 7300 run recorded
# every case the architecture leaves open (the exponent of an enabled
# overflow or underflow in single precision that is still out of range after
# the adjustment, see pack_exponent), and the model follows the 604. The flag
# stays for the vector generators that read it.
UNDEFINED = False


def pack_exponent(e):
    """The exponent field for the biased exponent e, as the 604 forms it from
    its wider internal exponent: bits 9-0 as they are, bit 10 as bit 11 XOR
    bit 10 (in two's complement). The identity for every exponent in range;
    measured on the 7300 for the single-precision enabled underflows and
    overflows whose adjusted exponent is still outside the double range
    (biased -883 to -717 and 2841 to 2853)."""
    return (e & 0x3FF) | ((((e >> 11) ^ (e >> 10)) & 1) << 10)


def round_pack(sign, m, e, sticky, single, rn, oe=False, ue=False, ni=False):
    """Round the exact value m * 2**e (plus a sticky fraction) to the target
    precision. Returns (bits, flags); flags has ox, ux, xx, fr, fi and den
    (the result was delivered denormalised)."""
    p, emin, emax, adj = (24, -126, 127, 192) if single else (53, -1022, 1023, 1536)
    fl = dict(ox=False, ux=False, xx=False, fr=False, fi=False, den=False)
    top = e + m.bit_length() - 1            # exponent of the leading one
    tiny = top < emin
    scaled = tiny and ue                    # an enabled underflow: delivered with the exponent adjusted
    if scaled:
        fl["ux"] = True
        e += adj
        top += adj
        tiny = False
    q = (emin if tiny else top) - (p - 1)   # weight of the result's last place
    sh = q - e
    if sh <= 0:
        kept, rem, half = m << -sh, 0, 1
    else:
        kept, rem, half = m >> sh, m & ((1 << sh) - 1), 1 << (sh - 1)
    inexact = rem != 0 or sticky
    if rn == 0:
        up = rem > half or (rem == half and (sticky or (kept & 1)))
    elif rn == 1:
        up = False
    elif rn == 2:
        up = inexact and not sign
    else:
        up = inexact and bool(sign)
    if up:
        kept += 1
    fl["fr"], fl["fi"], fl["xx"] = up, inexact, inexact
    if tiny and inexact:
        fl["ux"] = True
    if tiny and ni:
        # Non-IEEE mode: a result that would be denormalised is flushed to
        # zero and reported as an inexact underflow, exact or not (measured on
        # the 7300; denormal operands are not touched, whatever the 604
        # manual's Table 2-7 says)
        fl["ux"] = fl["xx"] = fl["fi"] = True
        fl["fr"] = False
        return (sign << 63), fl
    if kept == 0:
        return (sign << 63), fl
    if kept >> p:               # rounded up to the next power of two
        kept >>= 1
        q += 1
    top = q + kept.bit_length() - 1
    if top > emax:
        fl["ox"] = True
        if oe:
            q -= adj
            top -= adj
            scaled = True
        else:
            fl["xx"] = fl["fi"] = True
            to_inf = rn == 0 or (rn == 2 and not sign) or (rn == 3 and sign)
            # FR on a disabled overflow is "undefined"; the 604 leaves it as the
            # rounding of the significand set it, before the exponent was seen
            # to be out of range
            if to_inf:
                return (sign << 63) | INF, fl
            big = 0x47EFFFFFE0000000 if single else 0x7FEFFFFFFFFFFFFF
            return (sign << 63) | big, fl
    fl["den"] = tiny and top < emin         # (rounding can carry into the smallest normal)
    if top >= -1022 or scaled:
        frac = (kept << (52 - (kept.bit_length() - 1))) & FRAC
        return (sign << 63) | (pack_exponent(top + 1023) << 52) | frac, fl
    return (sign << 63) | (kept << (q + 1074)), fl


def update_fpscr(fpscr, set_bits, fr=False, fi=False, fprf=None, keep_frfi=False):
    """Apply an instruction's exception bits and status to FPSCR."""
    new = fpscr
    if not keep_frfi:
        new &= ~(FR | FI)
        if fr:
            new |= FR
        if fi:
            new |= FI
    if fprf is not None:
        new = (new & ~FPRF) | (fprf << 12)
    if set_bits & ~fpscr & STICKY:
        new |= FX
    new |= set_bits
    return summarise(new)


def summarise(fpscr):
    """Recompute the summary bits VX and FEX."""
    fpscr &= ~(VX | FEX)
    if fpscr & VX_ALL:
        fpscr |= VX
    if ((fpscr & VX) and (fpscr & VE)) or ((fpscr & OX) and (fpscr & OE)) or \
       ((fpscr & UX) and (fpscr & UE)) or ((fpscr & ZX) and (fpscr & ZE)) or \
       ((fpscr & XX) and (fpscr & XE)):
        fpscr |= FEX
    return fpscr


def quiet(x, single):
    """A NaN operand as it appears in a result: quiet, and for single-precision
    instructions with the payload bits a single cannot hold cleared."""
    x |= QBIT
    return x & ~0x1FFFFFFF if single else x


def nan_result(ops, single):
    """The NaN operand that propagates: first NaN in the given order."""
    for x in ops:
        if is_nan(x):
            return quiet(x, single)
    return QNAN


def arith(op, a, b, c, fpscr, single):
    """fadd fsub fmul fdiv fmadd fmsub fnmadd fnmsub. Returns (result or None, fpscr)."""
    rn = fpscr & RN
    fma = op in ("fmadd", "fmsub", "fnmadd", "fnmsub")
    negate = op in ("fnmadd", "fnmsub")
    if op == "fmul":
        ops = (a, c)
    elif fma:
        ops = (a, b, c)
    else:
        ops = (a, b)
    ca, cb, cc = cls(a), cls(b), cls(c)
    sa, sb, sc = a >> 63, b >> 63, c >> 63
    vx = 0
    if any(cls(x) == "snan" for x in ops):
        vx |= VXSNAN

    result = None           # a special result, when there is one
    exact = None            # (sign, m, e, sticky) otherwise
    zx = False

    if op in ("fadd", "fsub"):
        if op == "fsub":
            sb ^= 1
        if is_nan(a) or is_nan(b):
            result = nan_result(ops, single)
        elif ca == "inf" and cb == "inf":
            if sa != sb:
                vx |= VXISI
                result = QNAN
            else:
                result = (sa << 63) | INF
        elif ca == "inf":
            result = (sa << 63) | INF
        elif cb == "inf":
            result = (sb << 63) | INF
        else:
            exact = add_exact(sa, a, ca, sb, b, cb, rn)
    elif op == "fmul":
        sp = sa ^ sc
        if is_nan(a) or is_nan(c):
            result = nan_result(ops, single)
        elif (ca == "inf" and cc == "zero") or (ca == "zero" and cc == "inf"):
            vx |= VXIMZ
            result = QNAN
        elif ca == "inf" or cc == "inf":
            result = (sp << 63) | INF
        elif ca == "zero" or cc == "zero":
            result = sp << 63
        else:
            (ma, ea), (mc, ec) = value(a), value(c)
            exact = (sp, ma * mc, ea + ec, False)
    elif op == "fdiv":
        sq = sa ^ sb
        if is_nan(a) or is_nan(b):
            result = nan_result(ops, single)
        elif ca == "inf" and cb == "inf":
            vx |= VXIDI
            result = QNAN
        elif ca == "zero" and cb == "zero":
            vx |= VXZDZ
            result = QNAN
        elif ca == "inf":
            result = (sq << 63) | INF
        elif cb == "inf":
            result = sq << 63
        elif cb == "zero":
            zx = True
            result = (sq << 63) | INF
        elif ca == "zero":
            result = sq << 63
        else:
            (ma, ea), (mb, eb) = value(a), value(b)
            quo, rem = divmod(ma << 120, mb)
            exact = (sq, quo, ea - eb - 120, rem != 0)
    else:
        if op in ("fmsub", "fnmsub"):
            sb ^= 1
        sp = sa ^ sc
        imz = (ca == "inf" and cc == "zero") or (ca == "zero" and cc == "inf")
        if imz:
            vx |= VXIMZ
        if is_nan(a) or is_nan(b) or is_nan(c):
            result = nan_result(ops, single)
        elif imz:
            result = QNAN
        elif ca == "inf" or cc == "inf":
            if cb == "inf" and sb != sp:
                vx |= VXISI
                result = QNAN
            else:
                result = (sp << 63) | INF
        elif cb == "inf":
            result = (sb << 63) | INF
        else:
            if ca == "zero" or cc == "zero":
                pm, pe, pc = 0, 0, "zero"
            else:
                (ma, ea), (mc, ec) = value(a), value(c)
                pm, pe, pc = ma * mc, ea + ec, "norm"
            exact = add_exact(sp, (pm, pe), pc, sb, b, cb, rn)

    return finish(result, exact, vx, zx, fpscr, single, negate)


def add_exact(sx, x, cx, sy, y, cy, rn):
    """Exact sum of two finite signed values. x and y are doubles, or (m, e)."""
    def mag(v, c):
        if c == "zero":
            return 0, 0
        return v if isinstance(v, tuple) else value(v)
    (mx, ex), (my, ey) = mag(x, cx), mag(y, cy)
    if mx == 0 and my == 0:
        s = sx if sx == sy else (1 if rn == 3 else 0)
        return (s, 0, 0, False)
    e = min(ex, ey) if mx and my else (ex if mx else ey)
    vx = (mx << (ex - e)) if mx else 0
    vy = (my << (ey - e)) if my else 0
    total = (-vx if sx else vx) + (-vy if sy else vy)
    if total == 0:
        return (1 if rn == 3 else 0, 0, 0, False)
    return (1 if total < 0 else 0, abs(total), e, False)


def finish(result, exact, vx, zx, fpscr, single, negate=False):
    rn = fpscr & RN
    if vx:
        if fpscr & VE:
            return None, update_fpscr(fpscr, vx)
        if result is None:
            result = QNAN
        return result, update_fpscr(fpscr, vx, fprf=fprf_of(result, single))
    if zx:
        if fpscr & ZE:
            return None, update_fpscr(fpscr, ZX)
        if negate:
            result ^= SIGN
        return result, update_fpscr(fpscr, ZX, fprf=fprf_of(result, single))
    if result is not None:
        if negate and not is_nan(result):
            result ^= SIGN
        return result, update_fpscr(fpscr, 0, fprf=fprf_of(result, single))
    sign, m, e, sticky = exact
    if m == 0:
        result = sign << 63
        fl = dict(ox=False, ux=False, xx=False, fr=False, fi=False, den=False)
    else:
        result, fl = round_pack(sign, m, e, sticky, single, rn, bool(fpscr & OE), bool(fpscr & UE),
                                bool(fpscr & NI))
    if negate:
        result ^= SIGN
    bits = (OX if fl["ox"] else 0) | (UX if fl["ux"] else 0) | (XX if fl["xx"] else 0)
    return result, update_fpscr(fpscr, bits, fl["fr"], fl["fi"], fprf_of(result, single, fl["den"]))


def frsp(b, fpscr):
    cb = cls(b)
    if cb == "snan":
        return finish(quiet(b, True), None, VXSNAN, False, fpscr, True)
    if cb == "qnan":
        return finish(quiet(b, True), None, 0, False, fpscr, True)
    if cb in ("inf", "zero"):
        return finish(b, None, 0, False, fpscr, True)
    m, e = value(b)
    return finish(None, (b >> 63, m, e, False), 0, False, fpscr, True)


def fres(b, fpscr):
    """Reciprocal estimate. The 604 does not estimate: it divides 1.0 by the
    operand and rounds to single precision, with every status bit a divide
    would set."""
    return arith("fdiv", 0x3FF0000000000000, b, 0, fpscr, True)


# Reciprocal square root estimate: 7 fraction bits from a 32-entry table,
# indexed by the low bit of the exponent and the top four fraction bits.
# Each entry is 1/sqrt at the middle of its interval, rounded to nearest.
# Eight entries are confirmed by real-604 results (marked); the rest follow
# from the same rule and await a hardware sweep.
RSQRTE_TABLE = (
    # even exponent: 2/sqrt(m), m in [1,2)
    0x7C, 0x75, 0x6E, 0x68, 0x62, 0x5D, 0x58, 0x53,   # [0] and [7] confirmed
    0x4F, 0x4B, 0x47, 0x43, 0x40, 0x3D, 0x39, 0x36,   # [8] and [15] confirmed
    # odd exponent: sqrt(2/m)
    0x32, 0x2D, 0x28, 0x24, 0x20, 0x1C, 0x19, 0x15,   # [0] and [5] confirmed
    0x12, 0x0F, 0x0D, 0x0A, 0x08, 0x05, 0x03, 0x01,   # [9] and [15] confirmed
)


def frsqrte(b, fpscr):
    cb, s = cls(b), b >> 63
    if cb == "snan":
        return finish(quiet(b, False), None, VXSNAN, False, fpscr, False)
    if cb == "qnan":
        return finish(b, None, 0, False, fpscr, False)
    if cb == "zero":
        return finish((s << 63) | INF, None, 0, True, fpscr, False)
    if s:
        return finish(QNAN, None, VXSQRT, False, fpscr, False)
    if cb == "inf":
        return finish(0, None, 0, False, fpscr, False)
    m, e = value(b)
    top = e + m.bit_length() - 1                 # b = 1.f * 2**top
    frac4 = ((m << (53 - m.bit_length())) >> 48) & 0xF
    odd = top & 1
    est = RSQRTE_TABLE[odd * 16 + frac4]
    exp = -(top + 1) // 2 if odd else -top // 2 - 1
    result = ((exp + 1023) << 52) | (est << 45)
    return result, update_fpscr(fpscr, 0, fprf=fprf_of(result, False))


def fctiw(b, fpscr, to_zero):
    """Returns (result or None, fpscr). FPRF is left alone."""
    cb, s = cls(b), b >> 63
    rn = 1 if to_zero else (fpscr & RN)
    vx, fr, fi = 0, False, False
    if cb in ("qnan", "snan"):
        vx = VXCVI | (VXSNAN if cb == "snan" else 0)
        val = 0x80000000
    elif cb == "inf":
        vx = VXCVI
        val = 0x80000000 if s else 0x7FFFFFFF
    elif cb == "zero":
        val = 0
    else:
        m, e = value(b)
        if e >= 0:
            kept, rem, half = m << e, 0, 1
        else:
            sh = -e
            kept, rem, half = m >> sh, m & ((1 << sh) - 1), 1 << (sh - 1)
        fi = rem != 0
        if rn == 0:
            fr = rem > half or (rem == half and (kept & 1))
        elif rn == 1:
            fr = False
        elif rn == 2:
            fr = fi and not s
        else:
            fr = fi and bool(s)
        if fr:
            kept += 1
        v = -kept if s else kept
        if v > 0x7FFFFFFF:
            vx, val, fr, fi = VXCVI, 0x7FFFFFFF, False, False
        elif v < -0x80000000:
            vx, val, fr, fi = VXCVI, 0x80000000, False, False
        else:
            val = v & 0xFFFFFFFF
    # The upper word of the result is undefined. The 604 writes FFF80000, with
    # the lowest bit set when a negative operand converts to zero.
    high = 0xFFF80000 | (1 if (s and val == 0) else 0)
    if vx:
        if fpscr & VE:
            return None, update_fpscr(fpscr, vx)
        return (high << 32) | val, update_fpscr(fpscr, vx)
    return (high << 32) | val, update_fpscr(fpscr, XX if fi else 0, fr, fi)


def fcmp(a, b, fpscr, ordered):
    """Returns (cr field, fpscr)."""
    ca, cb = cls(a), cls(b)
    vx = 0
    if is_nan(a) or is_nan(b):
        c = 0x1
        if ca == "snan" or cb == "snan":
            vx |= VXSNAN
            if ordered and not (fpscr & VE):
                vx |= VXVC
        elif ordered:
            vx |= VXVC
    else:
        def key(x, cx):
            if cx == "zero":
                return 0
            mag = x & ~SIGN
            return -mag if x >> 63 else mag
        ka, kb = key(a, ca), key(b, cb)
        c = 0x8 if ka < kb else 0x4 if ka > kb else 0x2
    new = (fpscr & ~FPCC) | (c << 12)
    new = update_fpscr(new, vx, keep_frfi=True)
    return c, new


def execute(name, a, b, c, fpscr):
    """One instruction by mnemonic (no dot). Returns (result|None, fpscr, cr field|None)."""
    n = name.lower()
    single = n.endswith("s") and n not in ("fabs", "fnabs", "fres")
    base = n[:-1] if single else n
    if base in ("fadd", "fsub", "fmul", "fdiv", "fmadd", "fmsub", "fnmadd", "fnmsub"):
        r, f = arith(base, a, b, c, fpscr, single)
        return r, f, None
    if n == "frsp":
        r, f = frsp(b, fpscr)
        return r, f, None
    if n == "fres":
        r, f = fres(b, fpscr)
        return r, f, None
    if n == "frsqrte":
        r, f = frsqrte(b, fpscr)
        return r, f, None
    if n in ("fctiw", "fctiwz"):
        r, f = fctiw(b, fpscr, n == "fctiwz")
        return r, f, None
    if n in ("fcmpu", "fcmpo"):
        cr, f = fcmp(a, b, fpscr, n == "fcmpo")
        return None, f, cr
    if n == "fmr":
        return b, fpscr, None
    if n == "fneg":
        return b ^ SIGN, fpscr, None
    if n == "fabs":
        return b & ~SIGN, fpscr, None
    if n == "fnabs":
        return b | SIGN, fpscr, None
    if n == "fsel":
        ge = not is_nan(a) and (cls(a) == "zero" or not (a >> 63))
        return (c if ge else b), fpscr, None
    raise KeyError(name)


# ---- loads, stores and the FPSCR instructions ----------------------------------
# Measured on the 7300: lfs of every class (SNaNs and denormals included),
# stfs down to and below the single range, stfiwx, and every FPSCR
# instruction with every bit (2,989 vectors). mffs delivers FFF80000 in the
# upper word, as fctiw does.
def single_to_double(w):
    """lfs: the double holding the same value as single w (exact, NaNs untouched)."""
    s, e, f = w >> 31, (w >> 23) & 0xFF, w & 0x7FFFFF
    if e == 0:
        if f == 0:
            return s << 63
        nb = f.bit_length()                       # denormal: f * 2**-149
        return (s << 63) | ((nb - 1 - 149 + 1023) << 52) | ((f << (53 - nb)) & FRAC)
    if e == 255:
        return (s << 63) | INF | (f << 29)
    return (s << 63) | ((e - 127 + 1023) << 52) | (f << 29)


def double_to_single(d):
    """stfs: no rounding. A value whose exponent field is 896 or less is
    denormalised: the 24-bit significand is shifted right by 897 - exponent
    places and truncated, so below the single denormal range (exponent 873
    and under, double denormals included) a signed zero is stored. Anything
    else stores its top bits. The architecture leaves exponents below 874
    undefined; the shift to zero is what the 604 does (7300 run, 92 vectors)."""
    s, e, f = d >> 63, (d >> 52) & 0x7FF, d & FRAC
    if e <= 896:
        m = ((1 << 52) | f) >> (897 - e)
        return (s << 31) | ((m >> 29) & 0x7FFFFF)
    return ((d >> 62) << 30) | ((d >> 29) & 0x3FFFFFFF)


FPSCR_WRITABLE = 0x9FFFF7FF        # everything but FEX, VX and the reserved bit
FPSCR_EXC = FX | STICKY


def fpscr_instr(kind, fpscr, fm=0, value=0, field=0, bit=0):
    """mtfsf, mtfsfi, mtfsb0, mtfsb1, mcrfs. bit and field count from the most
    significant end, as the instructions do. Returns (fpscr, CR field or None)."""
    cr = None
    if kind == "mtfsf":
        mask = 0
        for i in range(8):
            if fm & (0x80 >> i):
                mask |= 0xF0000000 >> (4 * i)
        mask &= FPSCR_WRITABLE
        new = (fpscr & ~mask) | (value & mask)
    elif kind == "mtfsfi":
        mask = (0xF0000000 >> (4 * field)) & FPSCR_WRITABLE
        new = (fpscr & ~mask) | ((value * 0x11111111) & mask)
    elif kind == "mtfsb0":
        new = fpscr & ~((0x80000000 >> bit) & FPSCR_WRITABLE)
    elif kind == "mtfsb1":
        b = 0x80000000 >> bit
        new = fpscr | (b & FPSCR_WRITABLE)
        if b & FPSCR_EXC & ~fpscr:
            new |= FX
    elif kind == "mcrfs":
        mask = 0xF0000000 >> (4 * field)
        cr = (fpscr & mask) >> (28 - 4 * field)
        new = fpscr & ~(mask & FPSCR_EXC)
    else:
        raise KeyError(kind)
    return summarise(new & 0xFFFFFFFF), cr


# ---- checking against recorded hardware results --------------------------------
def check(path, show=6, only=None):
    total = bad = skipped = 0
    per = {}
    with open(path) as fh:
        for r in csv.DictReader(fh):
            insn = int(r["insn"], 16)
            if (insn >> 26) not in (59, 63):
                continue
            name = r["name"]
            rc = name.endswith(".")
            base = name.rstrip(".")
            if only and base not in only:
                continue
            a, b, c = (int(r[k], 16) for k in ("in_f4", "in_f5", "in_f6"))
            fpscr = int(r["in_fpscr"], 16)
            try:
                res, new, crf = execute(base, a, b, c, fpscr)
            except KeyError:
                skipped += 1
                continue
            want_f3, want_fpscr, want_cr = int(r["out_f3"], 16), int(r["out_fpscr"], 16), int(r["out_cr"], 16)
            got_f3 = 0 if res is None else res
            got_cr = int(r["in_cr"], 16)
            if crf is not None:
                fld = (insn >> 23) & 7
                got_cr = (got_cr & ~(0xF << (28 - 4 * fld))) | (crf << (28 - 4 * fld))
            elif rc:
                got_cr = (got_cr & ~0x0F000000) | ((new >> 28) << 24)
            total += 1
            st = per.setdefault(base, [0, 0])
            st[0] += 1
            if (got_f3, new, got_cr) != (want_f3, want_fpscr, want_cr):
                bad += 1
                st[1] += 1
                if st[1] <= show:
                    print("%-8s #%s fpscr=%08X a=%016X b=%016X c=%016X" % (name, r["index"], fpscr, a, b, c))
                    print("    want f3=%016X fpscr=%08X cr=%08X" % (want_f3, want_fpscr, want_cr))
                    print("    got  f3=%016X fpscr=%08X cr=%08X" % (got_f3, new, got_cr))
    print()
    for base, (n, f) in per.items():
        print("%-9s %6d vectors %6d differ" % (base, n, f))
    print("\n%d vectors modelled, %d differ, %d not modelled yet" % (total, bad, skipped))
    return 1 if bad else 0


# ---- random vectors with modelled results ----------------------------------------
def _a(op, d, a, b, c, xo, rc):
    return (op << 26) | (d << 21) | (a << 16) | (b << 11) | (c << 6) | (xo << 1) | rc


# mnemonic: (opcode, extended opcode, operands used)
GEN_OPS = {
    "FADD": (63, 21, "ab"), "FSUB": (63, 20, "ab"), "FMUL": (63, 25, "ac"), "FDIV": (63, 18, "ab"),
    "FADDS": (59, 21, "ab"), "FSUBS": (59, 20, "ab"), "FMULS": (59, 25, "ac"), "FDIVS": (59, 18, "ab"),
    "FMADD": (63, 29, "abc"), "FMSUB": (63, 28, "abc"), "FNMADD": (63, 31, "abc"), "FNMSUB": (63, 30, "abc"),
    "FMADDS": (59, 29, "abc"), "FMSUBS": (59, 28, "abc"), "FNMADDS": (59, 31, "abc"), "FNMSUBS": (59, 30, "abc"),
    "FSEL": (63, 23, "abc"), "FRES": (59, 24, "b"), "FRSQRTE": (63, 26, "b"),
    "FRSP": (63, 12, "b"), "FCTIW": (63, 14, "b"), "FCTIWZ": (63, 15, "b"),
    "FNEG": (63, 40, "b"), "FMR": (63, 72, "b"), "FNABS": (63, 136, "b"), "FABS": (63, 264, "b"),
    "FCMPU": (63, 0, "ab"), "FCMPO": (63, 32, "ab"),
}
GEN_WEIGHTS = {"FSEL": 1, "FNEG": 1, "FMR": 1, "FNABS": 1, "FABS": 1, "FCMPU": 2, "FCMPO": 2,
               "FRSQRTE": 2, "FRES": 3, "FRSP": 4, "FCTIW": 4, "FCTIWZ": 3}
SPECIAL_VALUES = (
    0x0000000000000000, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
    0x7FF0000000000000, 0xFFF0000000000000, 0x7FF8000000000000, 0x7FF4000000000000,
    0xFFF8000000000001, 0x0000000000000001, 0x800FFFFFFFFFFFFF, 0x0010000000000000,
    0x7FEFFFFFFFFFFFFF, 0x47EFFFFFE0000000, 0x47EFFFFFF0000000, 0x36A0000000000000,
    0x3690000000000000, 0x3810000000000000, 0x380FFFFFFFFFFFFF, 0x41DFFFFFFFC00000,
    0x41E0000000000000, 0xC1E0000000000000, 0xC1E0000000200000, 0x3FE0000000000000,
)


def _rand_double(rnd, near=None):
    """A double chosen to land on interesting paths. near: an exponent field to stay close to."""
    k = rnd.random()
    sign = rnd.getrandbits(1) << 63
    frac = rnd.getrandbits(52)
    shape = rnd.random()
    if shape < 0.15:
        frac &= ~0x1FFFFFFF                       # exactly a single
    elif shape < 0.25:
        frac = (frac & ~0x1FFFFFFF) | rnd.choice((0x10000000, 0x0FFFFFFF, 0x10000001, 0x18000000))
    elif shape < 0.32:
        frac = rnd.choice((0, FRAC, 1, FRAC - 1, 1 << rnd.randrange(52)))
    elif shape < 0.38:
        frac >>= rnd.randrange(52)                # few significant bits
    if near is not None and k < 0.6:
        step = rnd.choice((0, 0, 1, -1, 2, -2, rnd.randint(-60, 60), rnd.randint(-110, 110)))
        exp = min(2046, max(1, near + step))
    elif k < 0.30:
        exp = rnd.randint(1, 2046)
    elif k < 0.55:
        exp = 1023 + rnd.randint(-64, 64)
    elif k < 0.65:
        exp = 0                                   # denormal
    elif k < 0.75:
        exp = rnd.choice((1, 2, 3, 2044, 2045, 2046, 895, 896, 897, 898, 1149, 1150, 1151, 873, 874, 875))
    elif k < 0.85:
        exp = 1023 + rnd.randint(-150, 128)       # single range
    elif k < 0.95:
        return rnd.choice(SPECIAL_VALUES)
    else:
        return rnd.getrandbits(64)
    return sign | (exp << 52) | frac


def _rand_fpscr(rnd):
    f = rnd.getrandbits(2)
    k = rnd.random()
    if k < 0.25:
        f |= rnd.getrandbits(5) << 3              # exception enables
    if 0.15 < k < 0.40:
        f |= rnd.getrandbits(32) & (STICKY | FR | FI | FPRF)
        f = summarise(f)
        if rnd.getrandbits(1) or (f & STICKY and rnd.getrandbits(2)):
            f |= FX
    return f


def gen_random(count, seed, out=sys.stdout):
    global UNDEFINED
    rnd = random.Random(seed)
    names = [n for n in GEN_OPS for _ in range(GEN_WEIGHTS.get(n, 8))]
    cols = ["index", "name", "source", "insn", "in_r3", "in_r4", "in_r5", "in_r6", "in_cr", "in_xer",
            "in_ctr", "in_fpscr", "in_f4", "in_f5", "in_f6", "out_r3", "out_r4", "out_r5", "out_r6",
            "out_cr", "out_xer", "out_ctr", "out_fpscr", "out_f3", "out_f4", "out_f5", "out_f6", "verdict"]
    w = csv.writer(out, lineterminator="\n")
    w.writerow(cols)
    index = 0
    while index < count:
        name = rnd.choice(names)
        op, xo, uses = GEN_OPS[name]
        a = _rand_double(rnd)
        ea = (a >> 52) & 0x7FF
        if "c" in uses and "b" in uses:
            c = _rand_double(rnd)
            near = min(2046, max(1, ea + ((c >> 52) & 0x7FF) - 1023))
            b = _rand_double(rnd, near)
        else:
            b = _rand_double(rnd, ea)
            c = _rand_double(rnd)
        if "a" in uses and "b" in uses and rnd.random() < 0.08:
            # near cancellation
            b = (a ^ (rnd.getrandbits(1) << 63)) ^ rnd.choice((0, 1, 2, 1 << 29, 3 << 28))
        fpscr = _rand_fpscr(rnd)
        cr = rnd.getrandbits(32) if rnd.random() < 0.3 else 0
        UNDEFINED = False
        res, new, crf = execute(name, a, b, c, fpscr)
        if UNDEFINED:
            continue
        compare = name in ("FCMPU", "FCMPO")
        rc = 0 if (compare or name == "FSEL") else rnd.getrandbits(1)
        if compare:
            insn = _a(op, 4, 4, 5, 0, xo, 0)          # crfD = 1
            out_cr = (cr & ~0x0F000000) | (crf << 24)
        else:
            fa = 4 if "a" in uses else 0
            fb = 5 if "b" in uses else 0
            fc = 6 if "c" in uses else 0
            insn = _a(op, 3, fa, fb, fc, xo, rc)
            out_cr = ((cr & ~0x0F000000) | ((new >> 28) << 24)) if rc else cr
        f3 = 0 if res is None else res
        w.writerow([index, name + ("." if rc else ""), "model", "%08X" % insn,
                    "00000000", "00000000", "00000000", "00000000", "%08X" % cr, "00000000", "00000000",
                    "%08X" % fpscr, "%016X" % a, "%016X" % b, "%016X" % c,
                    "00000000", "00000000", "00000000", "00000000", "%08X" % out_cr, "00000000", "00000000",
                    "%08X" % new, "%016X" % f3, "%016X" % a, "%016X" % b, "%016X" % c, "model"])
        index += 1


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, "..", "ppctest", "runs", "results_604_run2.csv")
    if len(sys.argv) >= 2 and sys.argv[1] == "check":
        rest = sys.argv[2:]
        path = rest[0] if rest and rest[0].endswith(".csv") else default
        only = set(x.upper() for x in rest if not x.endswith(".csv")) or None
        sys.exit(check(path, only=only))
    if len(sys.argv) >= 3 and sys.argv[1] == "random":
        count = int(sys.argv[2])
        seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
        if len(sys.argv) > 4:
            with open(sys.argv[4], "w", newline="") as fh:
                gen_random(count, seed, fh)
        else:
            gen_random(count, seed)
        sys.exit(0)
    print(__doc__)
    sys.exit(2)
