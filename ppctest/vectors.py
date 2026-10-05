"""Test vectors: dingusppc's CSV sets plus generated cases without expectations.

Register convention (dingusppc's): integer operands in r3 (rA) and r4 (rB),
result in r3; floating point frA = f4, frB = f5, frC = f6, result in f3.
"""

import os
import struct
from dataclasses import dataclass, field
from typing import Optional

from ppcasm import xo_form, x_form, a_form, m_form

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

    def pack_input(self):
        flags = 1 if self.exp is not None else 0
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
    if cpu not in CPUS:
        raise ValueError("unknown cpu %r (choose from %s)" % (cpu, ", ".join(CPUS)))
    vectors = load_dingus(dingus_dir)
    _check_against_dingus(vectors)
    if extras:
        vectors += generate_extras(cpu)
    return vectors


if __name__ == "__main__":
    d = load_dingus()
    print("dingusppc vectors:", len(d), "| encodings cross-checked:", _check_against_dingus(d))
    for cpu in ("604e", "601"):
        vs = build_set(cpu)
        by = {}
        for v in vs:
            by[v.src] = by.get(v.src, 0) + 1
        print(cpu, len(vs), by)
