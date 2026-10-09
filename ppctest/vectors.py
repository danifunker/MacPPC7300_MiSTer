"""Test vectors: dingusppc's CSV sets, generated cases without expectations,
and vectors read from a results-format CSV (hardware results used as golden
values, or a model's predictions).

Register convention (dingusppc's): integer operands in r3 (rA) and r4 (rB),
result in r3; floating point frA = f4, frB = f5, frC = f6, result in f3.
A memory vector (F_MEM) gets the address of an 8-byte buffer in r6; the buffer
starts as the f6 pattern and is recorded in f6's place.
"""

import csv
import os
import struct
from dataclasses import dataclass, field
from typing import Optional

from ppcasm import xo_form, x_form, a_form, m_form, d_form
from layout import F_HAS_EXPECTED, F_MEM

HERE = os.path.dirname(os.path.abspath(__file__))
V4_DIR = os.path.join(HERE, "v4")
GOLDEN_604 = os.path.join(HERE, "runs", "results_604_run2.csv")

DINGUS_DEFAULT = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "dingusppc", "cpu", "ppc", "test"))

SNAN, QNAN = 0x7FF4000000000000, 0x7FF8000000000000
# CPUs on which fsel / fres / frsqrte are illegal (the test program cannot
# survive an exception, so they must not be on the disk for those CPUs)
NO_GRAPHICS_FP = {"601"}
CPUS = ("601", "603", "603e", "604", "604e", "750")


@dataclass
class Vector:
    name: str
    insn: int
    src: str
    r: list = field(default_factory=lambda: [0, 0, 0, 0])      # r3..r6
    cr: int = 0
    xer: int = 0
    ctr: int = 0
    fpscr: int = 0
    f: list = field(default_factory=lambda: [0, 0, 0])         # f4..f6 as bit patterns
    exp: Optional[dict] = None                                 # complete output state
    mem: bool = False                                          # r6 -> buffer (F_MEM)

    def pack_input(self):
        flags = (F_HAS_EXPECTED if self.exp is not None else 0) | (F_MEM if self.mem else 0)
        return struct.pack(">2I4I4I3Q", self.insn, flags, *self.r,
                           self.cr, self.xer, self.ctr, self.fpscr, *self.f)

    def pack_expected(self):
        if self.exp is None:
            return bytes(64)
        x = self.exp
        return struct.pack(">4I4I4Q", *x["r"], x["cr"], x["xer"], x["ctr"], x["fpscr"], *x["f"])


OUT_FIELDS = ("r3", "r4", "r5", "r6", "cr", "xer", "ctr", "fpscr", "f3", "f4", "f5", "f6")


def unpack_output(rec):
    v = struct.unpack(">4I4I4Q", rec)
    return dict(zip(OUT_FIELDS, v))


def expected_as_output(x):
    return dict(zip(OUT_FIELDS, (*x["r"], x["cr"], x["xer"], x["ctr"], x["fpscr"], *x["f"])))


def dbl(value):
    return struct.unpack(">Q", struct.pack(">d", value))[0]


_FLT_MAX = struct.unpack(">f", bytes.fromhex("7f7fffff"))[0]
_FLT_MIN = struct.unpack(">f", bytes.fromhex("00800000"))[0]
_NAMED = {
    "snan": SNAN, "qnan": QNAN,
    "FLT_MAX": dbl(_FLT_MAX), "-FLT_MAX": dbl(-_FLT_MAX),
    "FLT_MIN": dbl(_FLT_MIN), "-FLT_MIN": dbl(-_FLT_MIN),
    "DBL_MAX": 0x7FEFFFFFFFFFFFFF, "-DBL_MAX": 0xFFEFFFFFFFFFFFFF,
    "DBL_MIN": 0x0010000000000000, "-DBL_MIN": 0x8010000000000000,
}


def _fp_token(tok):
    return _NAMED[tok] if tok in _NAMED else dbl(float(tok))


_ROUND = {"RTN": 0, "RTZ": 1, "RPI": 2, "RNI": 3, "VEN": 0x80}


def load_dingus(directory=DINGUS_DEFAULT):
    """dingusppc's ppcinttests.csv and ppcfloattests.csv, with full expected state."""
    out = []
    with open(os.path.join(directory, "ppcinttests.csv")) as fh:
        for line in fh:
            t = line.strip().split(",")
            if len(t) < 5 or t[0].startswith("#"):
                continue
            kv = dict(x.split("=", 1) for x in t[2:])
            ra, rb = int(kv.get("rA", "0"), 16), int(kv.get("rB", "0"), 16)
            rd = int(kv["rD"], 16) if "rD" in kv else ra
            out.append(Vector(
                t[0], int(t[1], 16), "dingus-int", r=[ra, rb, 0, 0],
                exp={"r": [rd, rb, 0, 0], "cr": int(kv["CR"], 16), "xer": int(kv["XER"], 16),
                     "ctr": 0, "fpscr": 0, "f": [0, 0, 0, 0]}))
    with open(os.path.join(directory, "ppcfloattests.csv")) as fh:
        for line in fh:
            t = line.strip().split(",")
            if len(t) < 5 or t[0].startswith("#"):
                continue
            kv = dict(x.split("=", 1) for x in t[2:])
            f = [_fp_token(kv[k]) if k in kv else 0 for k in ("frA", "frB", "frC")]
            frd = int(kv["frD"], 16) if "frD" in kv else 0
            out.append(Vector(
                t[0], int(t[1], 16), "dingus-fp", fpscr=_ROUND[kv.get("round", "RTN")], f=f,
                exp={"r": [0, 0, 0, 0], "cr": int(kv["CR"], 16), "xer": 0, "ctr": 0,
                     "fpscr": int(kv["FPSCR"], 16), "f": [frd] + f}))
    return out


# --- encoders in the convention above ----------------------------------------
def _fp2(op, xo, rc=0):  return a_form(op, 3, 4, 5, 0, xo, rc)      # frD, frA, frB
def _fpm(op, xo, rc=0):  return a_form(op, 3, 4, 0, 6, xo, rc)      # frD, frA, frC
def _fp3(op, xo, rc=0):  return a_form(op, 3, 4, 5, 6, xo, rc)      # frD, frA, frB, frC
def _fp1(op, xo, rc=0):  return x_form(op, 3, 0, 5, xo, rc)         # frD, frB

FP_BINARY = {"FADD": (_fp2, 21), "FSUB": (_fp2, 20), "FDIV": (_fp2, 18), "FMUL": (_fpm, 25)}
FP_FMA = {"FMADD": 29, "FMSUB": 28, "FNMADD": 31, "FNMSUB": 30}
FP_UNARY = {"FRSP": (63, 12), "FCTIW": (63, 14), "FCTIWZ": (63, 15), "FNEG": (63, 40),
            "FMR": (63, 72), "FNABS": (63, 136), "FABS": (63, 264),
            "FRES": (59, 24), "FRSQRTE": (63, 26)}
GRAPHICS_FP = {"FRES", "FRSQRTE", "FSEL"}
INT_XO = {"DIVW": 491, "DIVWU": 459, "MULLW": 235, "ADDE": 138, "SUBFE": 136,
          "ADDZE": 202, "SUBFZE": 200, "ADDME": 234, "SUBFME": 232}
INT_NO_RB = {"ADDZE", "SUBFZE", "ADDME", "SUBFME"}

FP_SPECIALS = [
    0x0000000000000000, 0x8000000000000000,          # +-0
    0x3FF0000000000000, 0xBFF0000000000000,          # +-1
    0x7FF0000000000000, 0xFFF0000000000000,          # +-inf
    QNAN, SNAN, 0xFFF8000000000001,                  # NaNs, one with sign and payload
    0x0000000000000001, 0x800FFFFFFFFFFFFF,          # smallest / largest denormal
    0x0010000000000000, 0x7FEFFFFFFFFFFFFF,          # DBL_MIN, DBL_MAX
    0x3FE0000000000000, 0x3FF8000000000000,          # 0.5, 1.5
    0x400921FB54442D18,                              # pi
    0x41DFFFFFFFC00000, 0x41E0000000000000,          # 2^31-1, 2^31
    0xC1E0000000000000, 0xC1E0000000200000,          # -2^31, -2^31-1
    0x41DFFFFFFFE00000, 0x3FDFFFFFFFFFFFFF,          # 2^31-0.5, just under 0.5
    0x47EFFFFFE0000000, 0x47EFFFFFF0000000,          # FLT_MAX, halfway above it
    0x36A0000000000000, 0x3690000000000000,          # smallest float denormal, half of it
    0x3FF0000000000001, 0x3FF0000010000000,          # 1+ulp(double), 1+half ulp(float)
    0x7E37E43C8800759C, 0x01A56E1FC2F8F359,          # 1e300, 1e-300
]
FP_CROSS = FP_SPECIALS[:16] + [0x47EFFFFFE0000000, 0x36A0000000000000,
                               0x3FF0000010000000, 0x7E37E43C8800759C]
FP_FMA_SET = [0x0000000000000000, 0x8000000000000000, 0x3FF0000000000000, 0xBFF8000000000000,
              0x7FF0000000000000, QNAN, SNAN, 0x3FF0000000000001, 0x7FEFFFFFFFFFFFFF,
              0x0010000000000000]
INT_SPECIALS = [0, 1, 2, 3, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE,
                0x0000FFFF, 0x00010000, 0x12345678, 0xDEADBEEF]


def _check_against_dingus(dingus):
    """The generated encodings must agree with dingusppc's opcode words."""
    seen = {v.name: v.insn for v in dingus}
    mine = {}
    for name, (enc, xo) in FP_BINARY.items():
        for single, op in (("", 63), ("S", 59)):
            for rc, dot in ((0, ""), (1, ".")):
                mine[name + single + dot] = enc(op, xo, rc)
    for name, xo in FP_FMA.items():
        for single, op in (("", 63), ("S", 59)):
            for rc, dot in ((0, ""), (1, ".")):
                mine[name + single + dot] = _fp3(op, xo, rc)
    for name, xo in INT_XO.items():
        for oe, o in ((0, ""), (1, "O")):
            for rc, dot in ((0, ""), (1, ".")):
                mine[name + o + dot] = xo_form(3, 3, 0 if name in INT_NO_RB else 4, xo, oe, rc)
    bad = [n for n, w in mine.items() if n in seen and seen[n] != w]
    if bad:
        raise AssertionError("encoder disagrees with dingusppc for: " + ", ".join(sorted(bad)))
    return sum(1 for n in mine if n in seen)


def generate_extras(cpu):
    """Cases dingusppc's files do not cover. No expected values: results from
    real hardware are what we are after."""
    out = []
    graphics = cpu not in NO_GRAPHICS_FP

    def add(name, insn, src, **kw):
        out.append(Vector(name, insn, src, **kw))

    # FP unary, every special value, every rounding mode, with and without Rc
    for name, (op, xo) in FP_UNARY.items():
        if name in GRAPHICS_FP and not graphics:
            continue
        for rc, dot in ((0, ""), (1, ".")):
            for b in FP_SPECIALS:
                for rn in range(4):
                    add(name + dot, _fp1(op, xo, rc), "gen-fp-unary", fpscr=rn, f=[0, b, 0])
    if graphics:
        for a in (0, 0x8000000000000000, 0x3FF0000000000000, 0xBFF0000000000000,
                  QNAN, SNAN, 0x7FF0000000000000, 0xFFF0000000000000):
            add("FSEL", _fp3(63, 23), "gen-fsel",
                f=[a, 0x4004000000000000, 0x3FF8000000000000])
    # compares, with invalid-operation exceptions disabled and enabled
    for name, insn in (("FCMPU", 0xFC842800), ("FCMPO", 0xFC842840)):
        for a in FP_SPECIALS[:12]:
            for b in FP_SPECIALS[:12]:
                for fpscr in (0, 0x80):
                    add(name, insn, "gen-fcmp", fpscr=fpscr, f=[a, b, 0])
    # two-operand arithmetic across the special values, all rounding modes
    for name, (enc, xo) in FP_BINARY.items():
        for single, op in (("", 63), ("S", 59)):
            for a in FP_CROSS:
                for b in FP_CROSS:
                    for rn in range(4):
                        f = [a, 0, b] if enc is _fpm else [a, b, 0]
                        add(name + single, enc(op, xo), "gen-fp-binary", fpscr=rn, f=f)
    # fused multiply-add: a*c+b on a smaller cross, round-to-nearest
    for name, xo in FP_FMA.items():
        for single, op in (("", 63), ("S", 59)):
            for a in FP_FMA_SET:
                for c in FP_FMA_SET:
                    for b in FP_FMA_SET:
                        add(name + single, _fp3(op, xo), "gen-fma", f=[a, b, c])
    # divide and multiply corners, including the architecturally undefined ones
    for name in ("DIVW", "DIVWU", "MULLW"):
        for oe, o in ((0, ""), (1, "O")):
            for rc, dot in ((0, ""), (1, ".")):
                for a in INT_SPECIALS:
                    for b in INT_SPECIALS:
                        add(name + o + dot, xo_form(3, 3, 4, INT_XO[name], oe, rc),
                            "gen-muldiv", r=[a, b, 0, 0])
    for name, xo in (("MULHW", 75), ("MULHWU", 11)):
        for rc, dot in ((0, ""), (1, ".")):
            for a in INT_SPECIALS:
                for b in INT_SPECIALS:
                    add(name + dot, xo_form(3, 3, 4, xo, 0, rc), "gen-muldiv", r=[a, b, 0, 0])
    # extended arithmetic with carry-in and sticky overflow already set
    for name in ("ADDE", "SUBFE", "ADDZE", "SUBFZE", "ADDME", "SUBFME"):
        for oe, o in ((0, ""), (1, "O")):
            for rc, dot in ((0, ""), (1, ".")):
                for xer in (0x20000000, 0x80000000, 0xC0000000, 0xE0000000):
                    for a in INT_SPECIALS[:9]:
                        for b in ([0] if name in INT_NO_RB else INT_SPECIALS[:9]):
                            add(name + o + dot,
                                xo_form(3, 3, 0 if name in INT_NO_RB else 4, INT_XO[name], oe, rc),
                                "gen-carry", r=[a, b, 0, 0], xer=xer)
    # rotate with a register shift count
    for mb, me in ((0, 31), (8, 23), (24, 7), (31, 0)):
        for a in (0x12345678, 0x80000001, 0xFFFFFFFF):
            for sh in (0, 1, 4, 31, 32, 33, 0xFFFFFFFF):
                add("RLWNM", m_form(23, 3, 3, 4, mb, me), "gen-rotate", r=[a, sh, 0, 0])
    return out


def build_set(cpu="604e", dingus_dir=DINGUS_DEFAULT, extras=True):
    """The version-3 set: dingusppc's vectors plus the generated extras."""
    if cpu not in CPUS:
        raise ValueError("unknown cpu %r (choose from %s)" % (cpu, ", ".join(CPUS)))
    vectors = load_dingus(dingus_dir)
    _check_against_dingus(vectors)
    if extras:
        vectors += generate_extras(cpu)
    return vectors


# --- results-format CSV ---------------------------------------------------------
CSV_IN = ("r3", "r4", "r5", "r6", "cr", "xer", "ctr", "fpscr", "f4", "f5", "f6")
CSV_COLUMNS = (["index", "name", "source", "insn"] + ["in_" + f for f in CSV_IN]
               + ["out_" + f for f in OUT_FIELDS] + ["verdict"])


def is_mem_source(src):
    """Memory vectors are recognised by a `mem` part in their source name."""
    return "mem" in src.split("-")


def load_csv(path, expect="model"):
    """Vectors from a CSV in the format `ppctest.py results` writes.

    expect="all": every row's recorded outputs become the expected values
    (a hardware results file used as the reference).
    expect="model": only rows whose verdict is `model` carry expected values
    (what verilator/fpmodel.py and v4gen.py write)."""
    out = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            h = lambda k: int(r[k], 16)
            exp = None
            if expect == "all" or r["verdict"] == "model":
                exp = {"r": [h("out_r3"), h("out_r4"), h("out_r5"), h("out_r6")],
                       "cr": h("out_cr"), "xer": h("out_xer"), "ctr": h("out_ctr"),
                       "fpscr": h("out_fpscr"),
                       "f": [h("out_f3"), h("out_f4"), h("out_f5"), h("out_f6")]}
            out.append(Vector(
                r["name"], h("insn"), r["source"],
                r=[h("in_r3"), h("in_r4"), h("in_r5"), h("in_r6")],
                cr=h("in_cr"), xer=h("in_xer"), ctr=h("in_ctr"), fpscr=h("in_fpscr"),
                f=[h("in_f4"), h("in_f5"), h("in_f6")], exp=exp, mem=is_mem_source(r["source"])))
    return out


# --- version 4 additions ----------------------------------------------------------
FPSCR_FEX, FPSCR_VX = 0x40000000, 0x20000000
_VX_BITS = 0x01F80700


def fpscr_as_held(x):
    """A value written to the whole FPSCR, with the two summary bits as the
    architecture derives them (VX and FEX cannot be written)."""
    x &= 0x9FFFFFFF
    if x & _VX_BITS:
        x |= FPSCR_VX
    if ((x & FPSCR_VX and x & 0x80) or (x & 0x10000000 and x & 0x40) or
            (x & 0x08000000 and x & 0x20) or (x & 0x04000000 and x & 0x10) or
            (x & 0x02000000 and x & 0x08)):
        x |= FPSCR_FEX
    return x


FPSCR_STARTS = [0x00000000, 0xFFFFFFFF, 0x9FF80700, 0x000000FF, 0x60000000, 0x00000800,
                0x0007F000, 0xA5A5A5A5, 0x5A5A5A5A]
XER_PATTERNS = [0xFFFFFFFF, 0x00000000, 0x55555555, 0xAAAAAAAA, 0xE000007F, 0x1FFFFF80,
                0x0000FF00] + [1 << n for n in range(31, -1, -1)]
NOP = 0x60000000
MEM_A, MEM_B = 0x8123456789ABCDEF, 0xFEDCBA9876543210


def generate_v4_plain():
    """Version-4 vectors with no expected values: the processor's answers are
    the reference. FPSCR instructions, XER, and integer loads and stores."""
    out = []

    def add(name, insn, src, **kw):
        out.append(Vector(name, insn, src, **kw))

    # ---- XER: which bits does the register keep? ------------------------------
    for p in XER_PATTERNS:
        add("NOP", NOP, "v4-xer", xer=p)                       # the harness's own mtxer / mfxer
        add("MFXER", 0x7C6102A6, "v4-xer", xer=p)              # mfxer r3
        for before in (0, 0xFFFFFFFF):
            add("MTXER", 0x7C6103A6, "v4-xer", r=[p, 0, 0, 0], xer=before)   # mtxer r3
    for crfd in range(8):
        for xer in (0, 0xF0000000, 0xE000007F, 0xFFFFFFFF,
                    0x80000000, 0x40000000, 0x20000000, 0x10000000):
            for cr in (0, 0xFFFFFFFF):
                add("MCRXR", (31 << 26) | (crfd << 23) | (512 << 1), "v4-xer", xer=xer, cr=cr)

    # ---- FPSCR instructions ---------------------------------------------------
    src = "v4-fpscr"
    for start in FPSCR_STARTS + [1 << n for n in range(31, -1, -1)]:
        add("NOP", NOP, src, fpscr=start)                      # what mtfsf 0xFF made of it
    for start in FPSCR_STARTS:
        for rc, dot in ((0, ""), (1, ".")):
            add("MFFS" + dot, (63 << 26) | (3 << 21) | (583 << 1) | rc, src, fpscr=start)
        for f4 in (0xFFFFFFFFFFFFFFFF, 0x0123456789ABCDEF):    # target with old contents
            add("MFFS", (63 << 26) | (4 << 21) | (583 << 1), src, fpscr=start, f=[f4, 0, 0])
    for start in (0x00000000, 0xFFFFFFFF, 0x9FF80700, 0x000000FF, 0x0007F000):
        for fm in (0x00, 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01,
                   0xFF, 0x7F, 0xAA, 0x55, 0xF0, 0x0F):
            for value in (0x00000000, 0xFFFFFFFF, 0x55555555, 0xAAAAAAAA, 0x60000000,
                          0x90000000, 0x000000F8, 0x20000000):
                for rc, dot in ((0, ""), (1, ".")):
                    add("MTFSF" + dot, (63 << 26) | (fm << 17) | (5 << 11) | (711 << 1) | rc, src,
                        fpscr=start, f=[0, (0x12345678 << 32) | value, 0])
    for start in (0x00000000, 0xFFFFFFFF, 0x000000F8):
        for crfd in range(8):
            for imm in range(16):
                for rc, dot in ((0, ""), (1, ".")):
                    add("MTFSFI" + dot, (63 << 26) | (crfd << 23) | (imm << 12) | (134 << 1) | rc,
                        src, fpscr=start)
    for start in (0x00000000, 0xFFFFFFFF, 0x000000F8, 0x9FF80700):
        for name, xo in (("MTFSB0", 70), ("MTFSB1", 38)):
            for bit in range(32):
                for rc, dot in ((0, ""), (1, ".")):
                    add(name + dot, (63 << 26) | (bit << 21) | (xo << 1) | rc, src, fpscr=start)
    for start in FPSCR_STARTS:
        for crfd in (0, 3, 7):
            for crfs in range(8):
                for cr in (0, 0xFFFFFFFF):
                    add("MCRFS", (63 << 26) | (crfd << 23) | (crfs << 18) | (64 << 1), src,
                        fpscr=start, cr=cr)

    # ---- integer loads and stores through the 8-byte buffer at (r6) --------------
    src = "v4-mem"

    def mem(name, insn, **kw):
        kw.setdefault("f", [0, 0, MEM_A])
        add(name, insn, src, mem=True, **kw)

    for buf in (MEM_A, MEM_B):
        f = [0, 0, buf]
        for d in (0, 4):
            mem("LWZ", d_form(32, 3, 6, d), f=f)
        for d in (0, 2, 4, 6):
            mem("LHZ", d_form(40, 3, 6, d), f=f)
            mem("LHA", d_form(42, 3, 6, d), f=f)
        for d in range(8):
            mem("LBZ", d_form(34, 3, 6, d), f=f)
        for name, xo in (("LWZX", 23), ("LBZX", 87), ("LHZX", 279), ("LHAX", 343),
                         ("LWBRX", 534), ("LHBRX", 790)):
            mem(name, x_form(31, 3, 0, 6, xo), f=f)            # rA = 0: address is r6
        for name, op in (("LWZU", 33), ("LBZU", 35), ("LHZU", 41), ("LHAU", 43)):
            mem(name, d_form(op, 3, 6, 4), f=f)                # r6 moves on by 4
        # string loads: 1..8 bytes into r3 and r4, which start as all ones
        for n in range(1, 9):
            mem("LSWI", x_form(31, 3, 6, n, 597), f=f, r=[0xFFFFFFFF, 0xFFFFFFFF, 0, 0])
        for n in range(0, 9):                                   # n = 0: r3 is "undefined"
            mem("LSWX", x_form(31, 3, 0, 6, 533), f=f, r=[0xFFFFFFFF, 0xFFFFFFFF, 0, 0], xer=n)
    for r3 in (0x11223344, 0xAABBCCDD):
        r = [r3, 0x55667788, 0, 0]
        for name, op in (("STW", 36), ("STB", 38), ("STH", 44)):
            for d in (0, 4):
                mem(name, d_form(op, 3, 6, d), r=r)
        for name, xo in (("STWX", 151), ("STBX", 215), ("STHX", 407),
                         ("STWBRX", 662), ("STHBRX", 918)):
            mem(name, x_form(31, 3, 0, 6, xo), r=r)
        for name, op in (("STWU", 37), ("STBU", 39), ("STHU", 45)):
            mem(name, d_form(op, 3, 6, 4), r=r)
        for n in range(1, 9):
            mem("STSWI", x_form(31, 3, 6, n, 725), r=r)
        for n in range(0, 9):
            mem("STSWX", x_form(31, 3, 0, 6, 661), r=r, xer=n)
    return out


V4_MODEL_FILES = ("model_random.csv", "model_targeted.csv")


def build_v4(cpu="604e", golden=GOLDEN_604, v4_dir=V4_DIR):
    """The version-4 set. First the whole version-3 set in its original order,
    expecting what the real 604 returned for it; then the model-predicted
    vectors written by v4gen.py; then the vectors with no expectation."""
    if cpu in NO_GRAPHICS_FP:
        raise ValueError("the version-4 set is for the 604, 604e and 750")
    vectors = load_csv(golden, expect="all")
    for name in V4_MODEL_FILES:
        path = os.path.join(v4_dir, name)
        if not os.path.exists(path):
            raise FileNotFoundError("%s is missing: run `python v4gen.py` first" % path)
        vectors += load_csv(path, expect="model")
    return vectors + generate_v4_plain()


if __name__ == "__main__":
    d = load_dingus()
    print("dingusppc vectors:", len(d), "| encodings cross-checked:", _check_against_dingus(d))
    for cpu in ("604e", "601"):
        vs = build_set(cpu)
        by = {}
        for v in vs:
            by[v.src] = by.get(v.src, 0) + 1
        print(cpu, len(vs), by)
