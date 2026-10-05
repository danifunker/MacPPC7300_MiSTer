"""Minimal 32-bit PowerPC encoder and label-resolving assembler.

Only what the on-target test program and the vector generators need. Pure
Python so the whole tool chain runs without a cross-compiler.
"""

import struct

# ---------------------------------------------------------------------------
# SPR numbers
# ---------------------------------------------------------------------------
XER, LR, CTR = 1, 8, 9
PVR = 287
IBAT3U, IBAT3L = 534, 535
DBAT3U, DBAT3L = 542, 543
HID0 = 1008

# branch BO values / CR0 bit numbers
BO_TRUE, BO_FALSE, BO_DNZ, BO_ALWAYS = 12, 4, 16, 20
LT, GT, EQ, SO = 0, 1, 2, 3


def _u16(v):
    if not -0x8000 <= v <= 0xFFFF:
        raise ValueError("immediate out of range: %#x" % v)
    return v & 0xFFFF


def _s16(v):
    if not -0x8000 <= v <= 0x7FFF:
        raise ValueError("signed immediate out of range: %#x" % v)
    return v & 0xFFFF


def d_form(op, rt, ra, imm):
    return (op << 26) | (rt << 21) | (ra << 16) | (imm & 0xFFFF)


def x_form(op, rt, ra, rb, xo, rc=0):
    return (op << 26) | (rt << 21) | (ra << 16) | (rb << 11) | (xo << 1) | rc


def xo_form(rt, ra, rb, xo, oe=0, rc=0):
    return (31 << 26) | (rt << 21) | (ra << 16) | (rb << 11) | (oe << 10) | (xo << 1) | rc


def a_form(op, frt, fra, frb, frc, xo, rc=0):
    return (op << 26) | (frt << 21) | (fra << 16) | (frb << 11) | (frc << 6) | (xo << 1) | rc


def m_form(op, rs, ra, sh, mb, me, rc=0):
    return (op << 26) | (rs << 21) | (ra << 16) | (sh << 11) | (mb << 6) | (me << 1) | rc


def _spr(n):
    return ((n & 0x1F) << 16) | ((n >> 5) << 11)


# --- instruction encoders (return a 32-bit word) ---------------------------
def addi(rt, ra, si):   return d_form(14, rt, ra, _s16(si))
def addis(rt, ra, si):  return d_form(15, rt, ra, _u16(si))
def li(rt, si):         return addi(rt, 0, si)
def lis(rt, si):        return addis(rt, 0, si)
def ori(ra, rs, ui):    return d_form(24, rs, ra, _u16(ui))
def andi_(ra, rs, ui):  return d_form(28, rs, ra, _u16(ui))
def lwz(rt, d, ra):     return d_form(32, rt, ra, _s16(d))
def lbz(rt, d, ra):     return d_form(34, rt, ra, _s16(d))
def stw(rs, d, ra):     return d_form(36, rs, ra, _s16(d))
def stb(rs, d, ra):     return d_form(38, rs, ra, _s16(d))
def lfd(frt, d, ra):    return d_form(50, frt, ra, _s16(d))
def stfd(frs, d, ra):   return d_form(54, frs, ra, _s16(d))
def cmpwi(ra, si):      return d_form(11, 0, ra, _s16(si))
def cmplwi(ra, ui):     return d_form(10, 0, ra, _u16(ui))
def cmpw(ra, rb):       return x_form(31, 0, ra, rb, 0)
def cmplw(ra, rb):      return x_form(31, 0, ra, rb, 32)
def add(rt, ra, rb):    return xo_form(rt, ra, rb, 266)
def subf(rt, ra, rb):   return xo_form(rt, ra, rb, 40)
def or_(ra, rs, rb):    return x_form(31, rs, ra, rb, 444)
def mr(ra, rs):         return or_(ra, rs, rs)
def xor(ra, rs, rb):    return x_form(31, rs, ra, rb, 316)
def lbzx(rt, ra, rb):   return x_form(31, rt, ra, rb, 87)
def lwzx(rt, ra, rb):   return x_form(31, rt, ra, rb, 23)
def stwx(rs, ra, rb):   return x_form(31, rs, ra, rb, 151)
def rlwinm(ra, rs, sh, mb, me): return m_form(21, rs, ra, sh, mb, me)
def slwi(ra, rs, n):    return rlwinm(ra, rs, n, 0, 31 - n)
def srwi(ra, rs, n):    return rlwinm(ra, rs, 32 - n, n, 31)
def rotlwi(ra, rs, n):  return rlwinm(ra, rs, n, 0, 31)
def mfspr(rt, spr):     return (31 << 26) | (rt << 21) | _spr(spr) | (339 << 1)
def mtspr(spr, rs):     return (31 << 26) | (rs << 21) | _spr(spr) | (467 << 1)
def mflr(rt):           return mfspr(rt, LR)
def mtlr(rs):           return mtspr(LR, rs)
def mfctr(rt):          return mfspr(rt, CTR)
def mtctr(rs):          return mtspr(CTR, rs)
def mfxer(rt):          return mfspr(rt, XER)
def mtxer(rs):          return mtspr(XER, rs)
def mfcr(rt):           return x_form(31, rt, 0, 0, 19)
def mtcrf(fxm, rs):     return (31 << 26) | (rs << 21) | (fxm << 12) | (144 << 1)
def mfmsr(rt):          return x_form(31, rt, 0, 0, 83)
def mtmsr(rs):          return x_form(31, rs, 0, 0, 146)
def mffs(frt):          return x_form(63, frt, 0, 0, 583)
def mtfsf(fm, frb):     return (63 << 26) | (fm << 17) | (frb << 11) | (711 << 1)
def dcbf(ra, rb):       return x_form(31, 0, ra, rb, 86)
def icbi(ra, rb):       return x_form(31, 0, ra, rb, 982)
def sync():             return x_form(31, 0, 0, 0, 598)
def isync():            return x_form(19, 0, 0, 0, 150)
def blr():              return 0x4E800020
def bctrl():            return 0x4E800421
def sc():               return 0x44000002
def nop():              return 0x60000000


class Asm:
    """Collects words, resolves branch and base-relative label references."""

    def __init__(self, base_reg=None):
        self.words = []
        self.labels = {}
        self.fixups = []        # (index, kind, label, extra)
        self.base_reg = base_reg

    @property
    def pos(self):
        return len(self.words) * 4

    def label(self, name):
        if name in self.labels:
            raise ValueError("duplicate label " + name)
        self.labels[name] = self.pos

    def emit(self, *ws):
        for w in ws:
            self.words.append(w & 0xFFFFFFFF)

    # data -----------------------------------------------------------------
    def data(self, b):
        b = bytes(b)
        b += b"\0" * (-len(b) % 4)
        self.emit(*struct.unpack(">%dI" % (len(b) // 4), b))

    def asciz(self, name, text):
        self.label(name)
        self.data(text.encode("ascii") + b"\0")

    # branches -------------------------------------------------------------
    def b(self, label):
        self.fixups.append((len(self.words), "b", label, 0)); self.emit(18 << 26)

    def bl(self, label):
        self.fixups.append((len(self.words), "b", label, 1)); self.emit(18 << 26)

    def bc(self, bo, bi, label):
        self.fixups.append((len(self.words), "bc", label, 0))
        self.emit((16 << 26) | (bo << 21) | (bi << 16))

    def beq(self, l): self.bc(BO_TRUE, EQ, l)
    def bne(self, l): self.bc(BO_FALSE, EQ, l)
    def blt(self, l): self.bc(BO_TRUE, LT, l)
    def bge(self, l): self.bc(BO_FALSE, LT, l)
    def bgt(self, l): self.bc(BO_TRUE, GT, l)
    def ble(self, l): self.bc(BO_FALSE, GT, l)
    def bdnz(self, l): self.bc(BO_DNZ, 0, l)

    def la(self, rt, label):
        """rt = run-time address of label (base register + offset)."""
        self.fixups.append((len(self.words), "la", label, rt)); self.emit(0)

    def li32(self, rt, value):
        value &= 0xFFFFFFFF
        self.emit(lis(rt, value >> 16), ori(rt, rt, value & 0xFFFF))

    # output ---------------------------------------------------------------
    def assemble(self):
        words = list(self.words)
        for idx, kind, label, extra in self.fixups:
            if label not in self.labels:
                raise ValueError("undefined label " + label)
            target = self.labels[label]
            rel = target - idx * 4
            if kind == "b":
                if not -0x2000000 <= rel < 0x2000000:
                    raise ValueError("branch out of range to " + label)
                words[idx] |= (rel & 0x03FFFFFC) | extra
            elif kind == "bc":
                if not -0x8000 <= rel < 0x8000:
                    raise ValueError("conditional branch out of range to " + label)
                words[idx] |= rel & 0xFFFC
            elif kind == "la":
                words[idx] = addi(extra, self.base_reg, target)
        return struct.pack(">%dI" % len(words), *words)
