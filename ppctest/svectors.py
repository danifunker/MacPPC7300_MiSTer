"""Second-stage sequences: supervisor-mode behaviour of the CPU.

Each sequence is a few instructions run by stage2.py under a chosen MSR; the
record of what happened (registers, scratch buffer, exceptions taken) is
decoded here into the sresults CSV. Nothing here has expected values: the
real machine is the reference.

Register convention for a sequence: r3..r8 from the record, r9..r12 = 0,
r0 = the MSR it was entered with, r4 may be made the scratch buffer's address
(SF_R4_SCRATCH), LR = the end of the sequence. The scratch buffer holds the
record's 16 words followed by zeros, 256 bytes in all; its first 64 bytes
are recorded afterwards. A sequence must leave r1 and r2 alone.
"""

import struct
from dataclasses import dataclass, field

from ppcasm import *
from layout import *
from stage2 import (MSR_SAFE, MSR_REAL, DSISR, DAR, DEC, SDR1, SRR0, SRR1, SPRG0, IBAT0U,
                    DBAT0U, MMCR0, IABR, DABR, mfsr, mtsr, rfi, lmw, stmw, oris)

MSR_USER = MSR_SAFE | 0x4000
MSR_NOFP = MSR_SAFE & ~0x2000
MSR_FE0, MSR_FE1, MSR_EE, MSR_SE, MSR_BE = 0x800, 0x100, 0x8000, 0x400, 0x200
IBAT3U, IBAT3L, DBAT3U, DBAT3L = 534, 535, 542, 543
PMC1, SIA = 953, 955
PATTERNS = ((0xFFFFFFFF, 0x00000000), (0xA5A5A5A5, 0x5A5A5A5A))
SCRATCH_PATTERN = [0x11111111 * ((i % 15) + 1) for i in range(16)]


# --- encoders ---------------------------------------------------------------
def tw(to, ra, rb):          return x_form(31, to, ra, rb, 4)
def twi(to, ra, si):         return d_form(3, to, ra, si & 0xFFFF)
def lhz(rt, d, ra):          return d_form(40, rt, ra, d & 0xFFFF)
def lwarx(rt, ra, rb):       return x_form(31, rt, ra, rb, 20)
def stwcx(rs, ra, rb):       return x_form(31, rs, ra, rb, 150, 1)
def dcbz(ra, rb):            return x_form(31, 0, ra, rb, 1014)
def dcbi(ra, rb):            return x_form(31, 0, ra, rb, 470)
def tlbie(rb):               return x_form(31, 0, 0, rb, 306)
def eciwx(rt, ra, rb):       return x_form(31, rt, ra, rb, 310)
def ecowx(rs, ra, rb):       return x_form(31, rs, ra, rb, 438)
def lswi(rt, ra, nb):        return x_form(31, rt, ra, nb, 597)
def lswx(rt, ra, rb):        return x_form(31, rt, ra, rb, 533)
def stswi(rs, ra, nb):       return x_form(31, rs, ra, nb, 725)
def stswx(rs, ra, rb):       return x_form(31, rs, ra, rb, 661)
def mftb(rt, tbr=268):       return (31 << 26) | (rt << 21) | ((tbr & 0x1F) << 16) | ((tbr >> 5) << 11) | (371 << 1)
def fadd(frt, fra, frb):     return a_form(63, frt, fra, frb, 0, 21)
def fdiv(frt, fra, frb):     return a_form(63, frt, fra, frb, 0, 18)
def fmul(frt, fra, frc):     return a_form(63, frt, fra, 0, frc, 25)
def mtfsb1(bt):              return x_form(63, bt, 0, 0, 38)
def mtfsb0(bt):              return x_form(63, bt, 0, 0, 70)
def b_rel(off, link=0):      return (18 << 26) | (off & 0x03FFFFFC) | link
def bclr(bo, bi):            return (19 << 26) | (bo << 21) | (bi << 16) | (16 << 1)
ILLEGAL = 0x00000000


@dataclass
class SVector:
    name: str
    group: str
    code: list
    msr: int = MSR_SAFE
    r: list = field(default_factory=lambda: [0, 0, 0, 0, 0, 0])      # r3..r8
    cr: int = 0
    xer: int = 0
    ctr: int = 0
    scratch: list = field(default_factory=lambda: list(SCRATCH_PATTERN))
    flags: int = 0

    def pack(self):
        if len(self.code) > S_CODE_MAX:
            raise ValueError("%s: %d instructions, limit %d" % (self.name, len(self.code), S_CODE_MAX))
        rec = bytearray(SREC)
        struct.pack_into(">3I", rec, SI_FLAGS, self.flags, self.msr & 0xFFFFFFFF, len(self.code))
        struct.pack_into(">6I", rec, SI_R3, *[x & 0xFFFFFFFF for x in self.r])
        struct.pack_into(">3I", rec, SI_CR, self.cr, self.xer, self.ctr)
        struct.pack_into(">16I", rec, SI_SCRATCH, *self.scratch)
        struct.pack_into(">%dI" % len(self.code), rec, SI_CODE, *[w & 0xFFFFFFFF for w in self.code])
        return bytes(rec)


def unpack_input(rec):
    flags, msr, ncode = struct.unpack_from(">3I", rec, SI_FLAGS)
    ncode = min(ncode, S_CODE_MAX)
    return {
        "flags": flags, "msr": msr, "ncode": ncode,
        "r": list(struct.unpack_from(">6I", rec, SI_R3)),
        "cr": struct.unpack_from(">I", rec, SI_CR)[0], "xer": struct.unpack_from(">I", rec, SI_XER)[0],
        "ctr": struct.unpack_from(">I", rec, SI_CTR)[0],
        "scratch": list(struct.unpack_from(">16I", rec, SI_SCRATCH)),
        "code": list(struct.unpack_from(">%dI" % ncode, rec, SI_CODE)),
    }


def unpack_output(rec):
    status, msr = struct.unpack_from(">2I", rec, SO_STATUS)
    out = {
        "status": status & 0xFF, "nexc": status >> 8, "msr": msr,
        "r": list(struct.unpack_from(">10I", rec, SO_R3)),
        "cr": struct.unpack_from(">I", rec, SO_CR)[0], "xer": struct.unpack_from(">I", rec, SO_XER)[0],
        "ctr": struct.unpack_from(">I", rec, SO_CTR)[0], "lr": struct.unpack_from(">I", rec, SO_LR)[0],
        "scratch": list(struct.unpack_from(">16I", rec, SO_SCRATCH)),
        "slot": struct.unpack_from(">I", rec, SO_SLOT)[0],
        "scratchaddr": struct.unpack_from(">I", rec, SO_SCRATCHADDR)[0],
        "exc": [],
    }
    for k in range(min(out["nexc"], SO_EXC_MAX)):
        vec, srr0, srr1, dar, dsisr, hmsr = struct.unpack_from(">6I", rec, SO_EXC + k * SO_EXC_SIZE)
        out["exc"].append(dict(vec=vec, srr0=srr0, srr1=srr1, dar=dar, dsisr=dsisr, msr=hmsr))
    return out


def rel(addr, base, size, prefix):
    """An address relative to a known buffer, when it falls inside it."""
    if base and base <= addr < base + size:
        return "%s+%02X" % (prefix, addr - base)
    return "%08X" % addr


CSV_COLUMNS = (["index", "group", "name", "in_msr", "flags", "code",
                "in_r3", "in_r4", "in_r5", "in_r6", "in_r7", "in_r8", "in_cr", "in_xer", "in_ctr",
                "status", "nexc", "out_msr"]
               + ["r%d" % n for n in range(3, 13)] + ["cr", "xer", "ctr", "lr", "scratch"]
               + ["exc%d_%s" % (k, f) for k in range(1, SO_EXC_MAX + 1)
                  for f in ("vec", "srr0", "srr1", "dar", "dsisr", "msr")])
STATUS_NAMES = {0: "not run", SS_RAN: "ran", SS_RAN | SS_RECOVERED: "ABANDONED", SS_SKIPPED: "skipped"}


def csv_row(i, sv, inp, out):
    status = STATUS_NAMES.get(out["status"], "%02X" % out["status"])
    row = [str(i), sv.group, sv.name, "%08X" % inp["msr"], "%X" % inp["flags"],
           " ".join("%08X" % w for w in inp["code"])]
    row += ["%08X" % x for x in inp["r"]] + ["%08X" % inp["cr"], "%08X" % inp["xer"], "%08X" % inp["ctr"]]
    row += [status, str(out["nexc"]), "%08X" % out["msr"]]
    row += ["%08X" % x for x in out["r"]]
    row += ["%08X" % out["cr"], "%08X" % out["xer"], "%08X" % out["ctr"],
            rel(out["lr"], out["slot"], SREC, "C"), " ".join("%08X" % w for w in out["scratch"])]
    for k in range(SO_EXC_MAX):
        if k < len(out["exc"]):
            x = out["exc"][k]
            row += ["%04X" % x["vec"], rel(x["srr0"], out["slot"], SREC, "C"), "%08X" % x["srr1"],
                    rel(x["dar"], out["scratchaddr"], 256, "S"), "%08X" % x["dsisr"], "%08X" % x["msr"]]
        else:
            row += [""] * 6
    return row


# --- the sequences ----------------------------------------------------------
def _readback_spr(spr, name, patterns, group="spr", **kw):
    out = []
    for i, (p1, p2) in enumerate(patterns):
        code = [mfspr(3, spr), sync(), mtspr(spr, 4), isync(), mfspr(5, spr),
                sync(), mtspr(spr, 6), isync(), mfspr(7, spr),
                sync(), mtspr(spr, 3), isync(), mfspr(8, spr)]
        out.append(SVector("%s-%d" % (name, i), group, code, r=[0, p1, 0, p2, 0, 0], **kw))
    return out


def _readback_sr(n):
    out = []
    for i, (p1, p2) in enumerate(PATTERNS):
        code = [mfsr(3, n), mtsr(n, 4), isync(), mfsr(5, n), mtsr(n, 6), isync(), mfsr(7, n),
                mtsr(n, 3), isync(), mfsr(8, n)]
        out.append(SVector("SR%d-%d" % (n, i), "sr", code, r=[0, p1, 0, p2, 0, 0]))
    return out


def build_set():
    vs = []
    add = lambda *a, **k: vs.append(SVector(*a, **k))

    # ---- what the program finds -------------------------------------------------
    add("null", "probe", [])
    add("mfmsr", "probe", [mfmsr(3), mfspr(4, SRR0), mfspr(5, SRR1), mfspr(6, PVR), mfspr(7, HID0)])
    add("mfmsr-user", "probe", [mfmsr(3), mfspr(4, PVR)], msr=MSR_USER)
    add("hid1", "probe", [mfspr(3, 1009)])
    add("l2cr", "probe", [mfspr(3, 1017)])
    add("tb", "probe", [mftb(3, 268), mftb(4, 269), mftb(5, 268), mfspr(6, 284), mfspr(7, 285)])
    add("tb-user", "probe", [mftb(3, 268), mftb(4, 269), mfspr(5, DEC)], msr=MSR_USER)
    for i in range(0, 16, 6):
        add("sr-dump-%d" % i, "probe", [mfsr(3 + k, i + k) for k in range(min(6, 16 - i))])
    add("dbat-dump", "probe", [mfspr(3 + k, DBAT0U + k) for k in range(6)] , msr=MSR_REAL)
    add("ibat-dump", "probe", [mfspr(3 + k, IBAT0U + k) for k in range(6)], msr=MSR_REAL)
    add("bat3-dump", "probe", [mfspr(3, DBAT3U), mfspr(4, DBAT3L), mfspr(5, IBAT3U), mfspr(6, IBAT3L),
                               mfspr(7, SDR1), mfspr(8, DEC)], msr=MSR_REAL)

    # ---- which bits each supervisor register keeps -------------------------------
    sprs = [(SPRG0, "SPRG0"), (SPRG0 + 1, "SPRG1"), (SPRG0 + 2, "SPRG2"), (SPRG0 + 3, "SPRG3"),
            (SRR0, "SRR0"), (SRR1, "SRR1"), (DAR, "DAR"), (DSISR, "DSISR"), (DEC, "DEC"),
            (SDR1, "SDR1"), (282, "EAR"), (1023, "PIR"), (IABR, "IABR"), (DABR, "DABR"),
            (MMCR0, "MMCR0"), (PMC1, "PMC1"), (954, "PMC2"), (SIA, "SIA"), (956, "MMCR1"),
            (957, "PMC3"), (958, "PMC4"), (959, "SDA"), (1020, "THRM1"), (1021, "THRM2"),
            (1022, "THRM3"), (1019, "ICTC")]
    for spr, name in sprs:
        vs += _readback_spr(spr, name, PATTERNS)
    for n in range(16):
        vs += _readback_sr(n)
    for spr, name in [(DBAT0U + k, "DBAT%d%s" % (k // 2, "UL"[k % 2])) for k in range(6)] + \
                     [(IBAT0U + k, "IBAT%d%s" % (k // 2, "UL"[k % 2])) for k in range(6)] + \
                     [(DBAT3U, "DBAT3U"), (DBAT3L, "DBAT3L"), (IBAT3U, "IBAT3U"), (IBAT3L, "IBAT3L")]:
        vs += _readback_spr(spr, name, PATTERNS, group="bat", msr=MSR_REAL)

    # ---- MSR: which bits mtmsr keeps, which bits rfi copies from SRR1 -----------------
    msr_bits = [0x8000, 0x4000, 0x2000, 0x800, 0x400, 0x200, 0x100, 0x20, 0x10, 0x4, 0x2]
    reserved = [1 << n for n in range(31, 18, -1)] + [0x20000, 0x80, 0x8]
    for bit in msr_bits + reserved:
        add("mtmsr-%08X" % bit, "msr", [mfmsr(3), mtmsr(4), isync(), mfmsr(5), mtmsr(3), isync()],
            r=[0, MSR_SAFE ^ bit, 0, 0, 0, 0])
    add("mtmsr-all", "msr", [mfmsr(3), mtmsr(4), isync(), mfmsr(5), mtmsr(3), isync()],
        r=[0, MSR_SAFE | 0x8000 | 0x800 | 0x100 | 0x4 | 0x2, 0, 0, 0, 0])
    for bit in [0x8000, 0x4000, 0x800 | 0x100, 0x4, 0x2, 0x20, 0x10]:
        add("entry-%08X" % bit, "msr", [mfmsr(3), mfspr(4, SRR0), mfspr(5, SRR1)], msr=MSR_SAFE ^ bit)
    rfi_code = [mfmsr(3), b_rel(4, 1), mflr(9), addi(9, 9, 20), mtspr(SRR0, 9), mtspr(SRR1, 4), rfi(),
                mfmsr(5), mtmsr(3), isync()]
    for bit in [1 << n for n in range(32)]:
        if bit & (0x00050041 | 0x1000):
            continue
        add("rfi-%08X" % bit, "rfi", rfi_code, r=[0, MSR_SAFE ^ bit, 0, 0, 0, 0])
    add("rfi-same", "rfi", rfi_code, r=[0, MSR_SAFE, 0, 0, 0, 0])

    # ---- what each exception saves -----------------------------------------------
    S = SF_R4_SCRATCH
    add("illegal-0", "exc", [ILLEGAL, addi(5, 5, 1)])
    add("illegal-ff", "exc", [0xFFFFFFFF, addi(5, 5, 1)])
    add("illegal-op4", "exc", [0x10000000, addi(5, 5, 1)])
    add("illegal-op1", "exc", [0x04000000, addi(5, 5, 1)])
    add("illegal-fsqrt", "exc", [a_form(63, 1, 0, 1, 0, 22), addi(5, 5, 1)])
    add("illegal-user", "exc", [ILLEGAL, addi(5, 5, 1)], msr=MSR_USER)
    for name, insn in [("mfmsr", mfmsr(3)), ("mtmsr", mtmsr(3)), ("mfsprg0", mfspr(3, SPRG0)),
                       ("mtsprg0", mtspr(SPRG0, 3)), ("mfsr", mfsr(3, 0)), ("tlbie", tlbie(5)),
                       ("dcbi", dcbi(0, 4)), ("rfi", rfi()), ("mfhid0", mfspr(3, HID0)),
                       ("mfpvr", mfspr(3, PVR)), ("mfdec", mfspr(3, DEC)), ("mftb", mftb(3)),
                       ("mfsrr0", mfspr(3, SRR0)), ("mfdar", mfspr(3, DAR))]:
        add("priv-" + name, "exc", [insn, addi(5, 5, 1)], msr=MSR_USER, flags=S, r=[MSR_SAFE, 0, 0, 0, 0, 0])
    add("trap-tw", "exc", [tw(31, 0, 0), addi(5, 5, 1)])
    add("trap-twi-taken", "exc", [twi(8, 3, 5), addi(5, 5, 1)], r=[10, 0, 0, 0, 0, 0])
    add("trap-twi-not", "exc", [twi(8, 3, 5), addi(5, 5, 1)], r=[1, 0, 0, 0, 0, 0])
    add("trap-user", "exc", [tw(31, 0, 0), addi(5, 5, 1)], msr=MSR_USER)
    add("sc", "exc", [sc(), addi(5, 5, 1)], r=[0x1234, 0, 0, 0, 0, 0])
    add("sc-user", "exc", [sc(), addi(5, 5, 1)], msr=MSR_USER, r=[0x1234, 0, 0, 0, 0, 0])
    add("sc-twice", "exc", [sc(), addi(5, 5, 1), sc(), addi(5, 5, 1)])
    for off in (1, 2, 3):
        add("align-lmw+%d" % off, "exc", [lmw(24, off, 4), stmw(24, 32, 4)], flags=S)
        add("align-stmw+%d" % off, "exc", [lmw(24, 0, 4), stmw(24, 32 + off, 4)], flags=S)
        add("align-lwz+%d" % off, "exc", [lwz(3, off, 4), lhz(5, off, 4)], flags=S)
        add("align-lfd+%d" % off, "exc", [lfd(1, off, 4), stfd(1, 32 + off, 4)], flags=S)
        add("align-lfd-real+%d" % off, "exc", [lfd(1, off, 4), stfd(1, 32 + off, 4)], flags=S, msr=MSR_REAL)
    add("align-lwarx", "exc", [addi(9, 4, 1), lwarx(3, 0, 9), stwcx(3, 0, 9), mfcr(5)], flags=S)
    add("lwarx-ci", "exc", [lwarx(3, 0, 4), addi(3, 3, 1), stwcx(3, 0, 4), mfcr(5)], flags=S)
    add("lwarx-real", "exc", [lwarx(3, 0, 4), addi(3, 3, 1), stwcx(3, 0, 4), mfcr(5)], flags=S, msr=MSR_REAL)
    add("stwcx-noresv", "exc", [stwcx(3, 0, 4), mfcr(5)], flags=S, r=[0x77, 0, 0, 0, 0, 0])
    add("dcbz-ci", "exc", [dcbz(0, 4), addi(5, 5, 1)], flags=S)
    add("dcbz-real", "exc", [dcbz(0, 4), addi(5, 5, 1)], flags=S, msr=MSR_REAL)
    add("dcbz-user", "exc", [dcbz(0, 4), addi(5, 5, 1)], flags=S, msr=MSR_USER)
    add("eciwx", "exc", [eciwx(3, 0, 4), ecowx(3, 0, 4), addi(5, 5, 1)], flags=S)
    add("lswx-misaligned", "exc", [addi(9, 4, 1), lswx(10, 0, 9)], flags=S, xer=5)
    for name, insn in [("fadd", fadd(1, 1, 1)), ("lfd", lfd(1, 0, 4)), ("mffs", mffs(1)), ("stfd", stfd(1, 0, 4))]:
        add("fpunavail-" + name, "exc", [insn, addi(5, 5, 1)], msr=MSR_NOFP, flags=S)
    zero_s = [0] * 16
    one = struct.unpack(">2I", struct.pack(">d", 1.0))
    fp_s = [0, 0, one[0], one[1]] + [0] * 12
    for mname, m in [("fe", MSR_FE0 | MSR_FE1), ("fe0", MSR_FE0), ("fe1", MSR_FE1), ("none", 0)]:
        add("fpexc-ve-" + mname, "exc", [lfd(1, 0, 4), mtfsf(0xFF, 1), mtfsb1(24), fdiv(2, 1, 1),
                                         mffs(3), stfd(3, 8, 4), mtfsf(0xFF, 1), addi(5, 5, 1)],
            msr=MSR_SAFE | m, flags=S, scratch=fp_s)
        add("fpexc-ze-" + mname, "exc", [lfd(1, 0, 4), lfd(3, 8, 4), mtfsf(0xFF, 1), mtfsb1(27), fdiv(2, 3, 1),
                                         mffs(3), stfd(3, 8, 4), mtfsf(0xFF, 1), addi(5, 5, 1)],
            msr=MSR_SAFE | m, flags=S, scratch=fp_s)
    # protection and page faults through our own BAT3 mapping
    add("dsi-ro-store", "exc", [mfspr(9, DBAT3L), ori(10, 9, 1), mtspr(DBAT3L, 10), isync(),
                                stw(3, 0, 4), lwz(5, 0, 4), mtspr(DBAT3L, 9), isync()], flags=S, r=[0x77, 0, 0, 0, 0, 0])
    add("dsi-noaccess", "exc", [mfspr(9, DBAT3L), rlwinm(10, 9, 0, 0, 29), mtspr(DBAT3L, 10), isync(),
                                lwz(5, 0, 4), stw(3, 0, 4), mtspr(DBAT3L, 9), isync()], flags=S, r=[0x77, 0, 0, 0, 0, 0])
    add("dsi-nobat", "exc", [mfspr(9, DBAT3U), rlwinm(10, 9, 0, 31, 29), mtspr(DBAT3U, 10), isync(),
                             lwz(5, 0, 4), stw(3, 0, 4), mtspr(DBAT3U, 9), isync()], flags=S, r=[0x77, 0, 0, 0, 0, 0])
    add("isi-noaccess", "exc", [mfspr(9, IBAT3L), rlwinm(10, 9, 0, 0, 29), mtspr(IBAT3L, 10), isync(),
                                addi(5, 5, 1), mtspr(IBAT3L, 9), isync()])
    add("isi-nobat", "exc", [mfspr(9, IBAT3U), rlwinm(10, 9, 0, 31, 29), mtspr(IBAT3U, 10), isync(),
                             addi(5, 5, 1), mtspr(IBAT3U, 9), isync()])
    # 240 MB: inside our mapping, beyond the installed RAM
    add("mem-hole", "exc", [lis(9, 0x0F00), lwz(3, 0, 9), addi(5, 5, 1)])
    # decrementer, trace, breakpoints, performance monitor
    add("dec", "exc", [mfspr(3, DEC), li(9, 2), mtspr(DEC, 9), mfmsr(5), ori(6, 5, 0x8000), mtmsr(6)]
        + [nop()] * 8 + [mtmsr(5), mfspr(7, DEC)])
    add("dec-neg", "exc", [mfspr(3, DEC), lis(9, 0x8000), mfmsr(5), ori(6, 5, 0x8000), mtmsr(6), mtspr(DEC, 9)]
        + [nop()] * 4 + [mtmsr(5), mfspr(7, DEC)])
    add("ee-only", "exc", [mfmsr(5), ori(6, 5, 0x8000), mtmsr(6)] + [nop()] * 8 + [mtmsr(5)])
    add("trace-se", "exc", [mfmsr(3), ori(4, 3, 0x400), mtmsr(4), addi(5, 5, 1), addi(6, 6, 1), mtmsr(3), isync()])
    add("trace-be", "exc", [mfmsr(3), ori(4, 3, 0x200), mtmsr(4), b_rel(8), nop(), addi(5, 5, 1), mtmsr(3), isync()])
    add("trace-be-bl", "exc", [mfmsr(3), ori(4, 3, 0x200), mtmsr(4), b_rel(8, 1), nop(), mflr(5), mtmsr(3), isync()])
    add("iabr", "exc", [b_rel(4, 1), mflr(9), addi(9, 9, 20), ori(9, 9, 3), mtspr(IABR, 9), isync(),
                        nop(), addi(5, 5, 1), li(0, 0), mtspr(IABR, 0)])
    add("iabr-note", "exc", [b_rel(4, 1), mflr(9), addi(9, 9, 20), ori(9, 9, 2), mtspr(IABR, 9), isync(),
                             nop(), addi(5, 5, 1), li(0, 0), mtspr(IABR, 0)])
    add("dabr", "exc", [ori(9, 4, 7), mtspr(DABR, 9), stw(3, 0, 4), lwz(5, 0, 4), li(0, 0), mtspr(DABR, 0)],
        flags=S | SF_ONLY_750, r=[0x77, 0, 0, 0, 0, 0])
    add("dabr-write", "exc", [ori(9, 4, 6), mtspr(DABR, 9), lwz(5, 0, 4), stw(3, 0, 4), li(0, 0), mtspr(DABR, 0)],
        flags=S | SF_ONLY_750, r=[0x77, 0, 0, 0, 0, 0])
    pm = [li(0, 0), mtspr(MMCR0, 0), mtspr(PMC1, 5), mtspr(MMCR0, 6)] + [nop()] * 12 + \
         [li(0, 0), mtspr(MMCR0, 0), mfspr(7, PMC1), mfspr(8, SIA)]
    add("pm", "exc", pm, r=[0, 0, 0x7FFFFFF8, 0x04008080, 0, 0])
    add("pm-ee", "exc", [mfmsr(3), ori(9, 3, 0x8000), mtmsr(9)] + pm + [mtmsr(3)], r=[0, 0, 0x7FFFFFF8, 0x04008080, 0, 0])

    # ---- lmw / stmw / string edge cases ---------------------------------------------
    add("lmw24", "lmw", [lmw(24, 0, 4), stmw(24, 32, 4)], flags=S)
    add("lmw29", "lmw", [lmw(29, 0, 4), stmw(29, 32, 4)], flags=S)
    add("lmw3-inrange", "lmw", [lmw(3, 0, 4)], flags=S)
    add("stmw3", "lmw", [stmw(3, 0, 4)], flags=S, r=[0x33, 0, 0x55, 0x66, 0x77, 0x88])
    add("lmw24-real", "lmw", [lmw(24, 0, 4), stmw(24, 32, 4)], flags=S, msr=MSR_REAL)
    add("lmw-user", "lmw", [lmw(24, 0, 4), stmw(24, 32, 4)], flags=S, msr=MSR_USER)
    add("lmw-cross", "lmw", [lmw(3, 200, 4)], flags=S)
    add("lswi11", "lmw", [lswi(10, 4, 11)], flags=S)
    add("lswi8", "lmw", [lswi(11, 4, 8)], flags=S)
    add("lswi0", "lmw", [lswi(10, 4, 0)], flags=S)
    add("lswx0", "lmw", [lswx(10, 0, 4)], flags=S, xer=0)
    add("lswx12", "lmw", [lswx(10, 0, 4)], flags=S, xer=12)
    add("lswx40", "lmw", [lswx(10, 0, 4), stmw(20, 32, 4)], flags=S, xer=40)
    add("stswi9", "lmw", [stswi(3, 4, 9)], flags=S, r=[0x11223344, 0, 0x55667788, 0x99AABBCC, 0, 0])
    add("stswx5", "lmw", [stswx(3, 0, 4)], flags=S, xer=5, r=[0x11223344, 0, 0x55667788, 0, 0, 0])
    add("stswx0", "lmw", [stswx(3, 0, 4)], flags=S, xer=0, r=[0x11223344, 0, 0, 0, 0, 0])

    # ---- which encodings trap: the extended-opcode space, both modes ------------------
    # r3 = the safe MSR (so a stray mtmsr changes nothing), r4 = scratch, r5 = 0:
    # every X-form memory operand is the scratch buffer; CTR and LR end the sequence
    sweep_r = [MSR_SAFE, 0, 0, 0x12345678, 0x9ABCDEF0, 0x0F0F0F0F]
    sweep_flags = S | SF_CTR_END
    for mode, msr in (("s", MSR_SAFE), ("u", MSR_USER)):
        for op in range(64):
            if op in (16, 18, 19, 31, 59, 63):
                continue
            add("op%02d-%s" % (op, mode), "sweep", [d_form(op, 3, 4, 0)], msr=msr, flags=sweep_flags,
                r=sweep_r, xer=4)
        for xo in range(1024):
            for rc in (0, 1):
                add("op31-%03X%s-%s" % (xo, "." if rc else "", mode), "sweep",
                    [x_form(31, 3, 4, 5, xo, rc)], msr=msr, flags=sweep_flags, r=sweep_r, xer=4)
        for xo in range(1024):
            if xo == 50 and mode == "s":
                continue                                        # rfi: tested on its own
            add("op19-%03X-%s" % (xo, mode), "sweep", [x_form(19, 3, 4, 5, xo)], msr=msr,
                flags=sweep_flags, r=sweep_r, xer=4)
        for xo in range(32):
            for rc in (0, 1):
                add("op59-%02X%s-%s" % (xo, "." if rc else "", mode), "sweep",
                    [a_form(59, 3, 4, 5, 6, xo, rc)], msr=msr, flags=sweep_flags, r=sweep_r, xer=4)
        for xo in range(1024):
            add("op63-%03X-%s" % (xo, mode), "sweep", [x_form(63, 3, 4, 5, xo)], msr=msr,
                flags=sweep_flags, r=sweep_r, xer=4)
        for n in range(1024):
            add("mfspr%d-%s" % (n, mode), "sprsweep", [mfspr(3, n)], msr=msr, flags=sweep_flags, r=sweep_r)
    return vs


if __name__ == "__main__":
    vs = build_set()
    groups = {}
    for v in vs:
        groups[v.group] = groups.get(v.group, 0) + 1
    print("%d sequences: %s" % (len(vs), ", ".join("%s %d" % kv for kv in groups.items())))
    print("records: %d bytes" % (len(vs) * SREC))
