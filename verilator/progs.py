#!/usr/bin/env python3
"""Programs for the DSPPC604 pipeline test bench (core_tb).

    python progs.py golden OUT [results.csv]     the real-604 integer vectors as code
    python progs.py goldenfp OUT [results.csv]   the real-604 floating-point vectors as code
    python progs.py random OUT COUNT [SEED]      random instruction stream for lockstep
    python progs.py fprandom OUT COUNT [SEED]    random floating-point program, with the
                                                 state fpmodel.py expects after every instruction
    python progs.py exctest OUT                  each exception once, with what its handler must see
    python progs.py irqtest OUT [LOOPS]          a computation that interrupts must not disturb
                                                 (run with --irq-every and --tb-run)

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
POOL_BASE = 0x00400000       # constants for the floating-point programs


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


def mtmsr(rs):
    return (31 << 26) | (rs << 21) | (146 << 1)


B_SELF = 0x48000000
RFI = 0x4C000064
XER, LR, CTR = 1, 8, 9
SRR0, SRR1 = 26, 27
MSR_FP, MSR_PR, MSR_EE = 0x2000, 0x4000, 0x8000


def set_msr(value, scratch=0):
    """The core leaves reset with MSR = 0x40 (vectors at FFFxxxxx, no floating point)."""
    return li32(scratch, value) + [mtmsr(scratch)]


def install_handlers(p):
    """Exception handlers at the vectors. They leave SRR0 (advanced) and SRR1
    in r30 and r31, where a lockstep run compares them.
      program, FP unavailable, alignment: step over the instruction
      system call: switch between user and supervisor mode"""
    skip = [mfspr(SRR0, 30), mfspr(SRR1, 31), D(14, 30, 30, 4), mtspr(SRR0, 30), RFI]
    for vec in (0x600, 0x700, 0x800):
        for i, w in enumerate(skip):
            p.data[vec + 4 * i] = w
    toggle = [mfspr(SRR0, 30), mfspr(SRR1, 31), D(26, 31, 31, MSR_PR), mtspr(SRR1, 31), RFI]
    for i, w in enumerate(toggle):
        p.data[0xC00 + 4 * i] = w


class Program:
    def __init__(self):
        self.words = []          # code
        self.checks = []         # (index into words, text)
        self.data = {}           # addr -> word
        self.expect = {}         # addr -> word memory must hold at the end

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
            for a in sorted(self.expect):
                fh.write("X %08X %08X\n" % (a, self.expect[a]))
            fh.write("E %08X\n" % (CODE_BASE + 4 * (len(self.words) - 1)))


# ---- the golden vectors as one program -----------------------------------------
def golden(out, path):
    p = Program()
    p.words += set_msr(0)
    n = 0
    with open(path) as fh:
        for r in csv.DictReader(fh):
            insn = int(r["insn"], 16)
            if (insn >> 26) in (59, 63):
                continue                              # see goldenfp
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
            p.checks.append((len(p.words), "%08X %08X %08X %08X %08X %08X %08X %08X 0 0 0 0 %s#%s" % (
                v["out_r3"], v["out_r4"], v["out_r5"], v["out_r6"],
                v["out_cr"], v["out_xer"], v["out_ctr"], 0, r["name"], r["index"])))
            p.words.append(insn)
            n += 1
    p.words.append(B_SELF)
    p.write(out)
    print("%d vectors, %d instructions -> %s" % (n, len(p.words), out))


def lfd(fr, ra, d):
    return D(50, fr, ra, d)


def mtfsf(fm, frb, rc=0):
    return (63 << 26) | (fm << 17) | (frb << 11) | (711 << 1) | rc


def check_text(r, cr, xer, ctr, fpscr, f, tag):
    return "%08X %08X %08X %08X %08X %08X %08X %08X %016X %016X %016X %016X %s" % (
        r[0], r[1], r[2], r[3], cr, xer, ctr, fpscr, f[0], f[1], f[2], f[3], tag)


def goldenfp(out, path):
    """Each vector: f4-f6 and FPSCR loaded from a constant pool, f3 zeroed, CR
    set, then the instruction. r10 points at the vector's constants."""
    p = Program()
    p.words += set_msr(MSR_FP)
    n = 0
    with open(path) as fh:
        for r in csv.DictReader(fh):
            insn = int(r["insn"], 16)
            if (insn >> 26) not in (59, 63):
                continue
            v = {k: int(r[k], 16) for k in r if k.startswith(("in_", "out_"))}
            block = POOL_BASE + 40 * n
            for i, d in enumerate((v["in_f4"], v["in_f5"], v["in_f6"], v["in_fpscr"], 0)):
                p.data[block + 8 * i] = d >> 32
                p.data[block + 8 * i + 4] = d & 0xFFFFFFFF
            setup = [
                [lfd(4, 10, 0)], [lfd(5, 10, 8)], [lfd(6, 10, 16)], [lfd(3, 10, 32)],
                [lfd(7, 10, 24), mtfsf(0xFF, 7)],
                li32(7, v["in_cr"]) + [mtcrf(0xFF, 7)],
            ]
            k = n % len(setup)
            p.words += [D(15, 10, 0, block >> 16), D(24, 10, 10, block)]
            for group in setup[k:] + setup[:k]:
                p.words += group
            p.checks.append((len(p.words), check_text(
                [v["out_r3"], v["out_r4"], v["out_r5"], v["out_r6"]], v["out_cr"], v["out_xer"],
                v["out_ctr"], v["out_fpscr"], [v["out_f3"], v["out_f4"], v["out_f5"], v["out_f6"]],
                "%s#%s" % (r["name"], r["index"]))))
            p.words.append(insn)
            n += 1
    p.words.append(B_SELF)
    p.write(out)
    print("%d vectors, %d instructions -> %s" % (n, len(p.words), out))


# ---- exceptions, one at a time ---------------------------------------------------
NOP = 0x60000000
DAR, DSISR, DEC, SPRG0, SPRG1 = 19, 18, 22, 272, 273


def exctest(out):
    """Raises each exception the core has, once. The handler copies SRR0, SRR1,
    DAR and DSISR to r3-r6 and returns past the instruction (with the
    floating-point trap enables off), so the check on the following nop sees
    exactly what the exception delivered."""
    p = Program()
    body = [mfspr(SRR0, 3), mfspr(SRR1, 4), mfspr(DAR, 5), mfspr(DSISR, 6)]
    tail = [D(14, 31, 0, 0x900), X(4, 31, 31, 60), mtspr(SRR1, 31), RFI]      # SRR1 &= ~(FE0|FE1)
    skip = body + [D(14, 30, 3, 4), mtspr(SRR0, 30)] + tail
    for vec in (0x600, 0x700, 0x800):
        for i, w in enumerate(skip):
            p.data[vec + 4 * i] = w
    for i, w in enumerate(body + tail):                                        # sc: SRR0 is already past it
        p.data[0xC00 + 4 * i] = w

    st = {"dar": 0, "dsisr": 0, "fpscr": 0, "msr": 0}

    def setm(v):
        p.words.extend(set_msr(v, 7))
        st["msr"] = v

    def expect(insn, info, pc_after=False, align_ea=None, xer=0):
        """insn raises an exception; the nop after it is checked."""
        at = p.pc()
        p.words.append(insn)
        if align_ea is not None:
            st["dar"] = align_ea
            if insn >> 26 == 31:
                st["dsisr"] = (((insn >> 1) & 3) << 15) | (((insn >> 6) & 1) << 14) | (((insn >> 7) & 15) << 10)
            else:
                st["dsisr"] = (((insn >> 26) & 1) << 14) | (((insn >> 27) & 15) << 10)
            st["dsisr"] |= ((insn >> 21) & 31) << 5 | ((insn >> 16) & 31)
        srr1 = (st["msr"] & 0x87C0FFFF) | info
        st["seen"] = [at + 4 if pc_after else at, srr1, st["dar"], st["dsisr"]]
        p.words.append(NOP)
        p.checks.append((len(p.words) - 1, check_text(
            st["seen"], 0, xer, 0, st["fpscr"], [0, 0, 0, 0], "exc%X" % len(p.checks))))
        st["msr"] &= ~0x900                    # the handler returns with FE0 and FE1 off

    def no_exc(insn, xer=0):
        """insn must execute without an exception: what the last handler left
        in r3-r6 is still there afterwards."""
        p.words.append(insn)
        p.words.append(NOP)
        p.checks.append((len(p.words) - 1, check_text(
            st["seen"], 0, xer, 0, st["fpscr"], [0, 0, 0, 0], "noexc%X" % len(p.checks))))

    setm(0)
    p.words += li32(1, DATA_A)
    expect(0x44000002, 0, pc_after=True)                          # sc
    expect(D(3, 31, 0, 0), 0x00020000)                            # twi 31,r0,0: trap always
    expect(0x00000000, 0x00080000)                                # not an instruction
    expect(mfspr(1023, 9), 0x00080000)                            # an SPR that does not exist
    expect(0xFC201090, 0)                                         # fmr with MSR[FP] off
    setm(MSR_FP)
    expect(D(46, 29, 1, 2), 0, align_ea=DATA_A + 2)               # lmw at an odd address
    expect(D(47, 29, 1, 6), 0, align_ea=DATA_A + 6)               # stmw
    expect(D(50, 1, 1, 1), 0, align_ea=DATA_A + 1)                # lfd
    p.words += li32(8, 3)
    expect(X(2, 1, 8, 663), 0, align_ea=DATA_A + 3)               # stfsx
    # a string operation that is not word-aligned and crosses a 4 KB boundary,
    # or is word-aligned and crosses a 256 MB boundary, is not performed either
    p.words += li32(8, DATA_A + 0xFFE)
    expect(X(29, 8, 4, 597), 0, align_ea=DATA_A + 0xFFE)          # lswi r29,r8,4: bytes FFE-1001
    no_exc(X(29, 8, 2, 725))                                      # stswi r29,r8,2: ends at FFF
    p.words += li32(0, 0) + li32(9, 3) + [mtspr(XER, 9)]
    expect(X(29, 8, 0, 533), 0, align_ea=DATA_A + 0xFFE, xer=3)   # lswx r29,r8,r0: XER says 3 bytes
    p.words += li32(9, 2) + [mtspr(XER, 9)]
    no_exc(X(29, 8, 0, 661), xer=2)                               # stswx, 2 bytes
    p.words += li32(9, 0) + [mtspr(XER, 9)]
    p.words += li32(8, DATA_A + 0xFFC)
    no_exc(X(29, 8, 8, 597))                                      # lswi, word-aligned across 4 KB
    p.words += li32(8, 0x0FFFFFFC)
    expect(X(29, 8, 8, 725), 0, align_ea=0x0FFFFFFC)              # stswi across 256 MB
    setm(MSR_FP | MSR_PR)
    expect(X(9, 0, 0, 83), 0x00040000)                            # mfmsr in user mode
    expect(mfspr(SRR0, 9), 0x00040000)                            # a supervisor SPR in user mode
    expect(mfspr(1023, 9), 0x00040000)                            # ... even one that does not exist
    expect(0x44000002, 0, pc_after=True)                          # sc from user mode
    p.words.append(B_SELF)
    p.write(out)
    print("%d instructions, %d checks -> %s" % (len(p.words), len(p.checks), out))


def fpexctest(out):
    """Enabled floating-point exceptions: one raised by the instruction itself,
    and one pending when the trap enable is switched on."""
    p = Program()
    body = [mfspr(SRR0, 3), mfspr(SRR1, 4), mfspr(DAR, 5), mfspr(DSISR, 6)]
    tail = [D(14, 31, 0, 0x900), X(4, 31, 31, 60), mtspr(SRR1, 31), RFI]
    for i, w in enumerate(body + [D(14, 30, 3, 4), mtspr(SRR0, 30)] + tail):
        p.data[0x700 + 4 * i] = w
    FE0 = 0x800
    p.words += set_msr(MSR_FP | FE0, 7)
    p.words.append((63 << 26) | (6 << 23) | (8 << 12) | (134 << 1))      # mtfsfi 6,8: FPSCR[VE] on
    at = p.pc()
    p.words.append((63 << 26) | (3 << 21) | (0 << 16) | (0 << 11) | (18 << 1))   # fdiv f3,f0,f0: 0/0
    fpscr = 0x80000000 | 0x40000000 | 0x20000000 | 0x00200000 | 0x80     # FX FEX VX VXZDZ, VE
    srr1 = (MSR_FP | FE0) | 0x00100000
    p.words.append(NOP)
    p.checks.append((len(p.words) - 1, check_text([at, srr1, 0, 0], 0, 0, 0, fpscr, [0, 0, 0, 0], "own")))
    # FEX is still set and the handler returned with the enables off: switching
    # them on again must trap on the next instruction, before it executes
    p.words += set_msr(MSR_FP | FE0, 7)
    at = p.pc()
    p.words.append(D(14, 9, 0, 0x55))                                    # li r9,0x55: must not execute
    p.words.append(NOP)
    p.checks.append((len(p.words) - 1, check_text([at, srr1, 0, 0], 0, 0, 0, fpscr, [0, 0, 0, 0], "pending")))
    p.words.append(B_SELF)
    p.write(out)
    print("%d instructions, %d checks -> %s" % (len(p.words), len(p.checks), out))


def irqtest(out, loops):
    """A loop whose results are known, running with interrupts enabled. The
    external and decrementer handlers each count in memory (00FFFFE0 and
    00FFFFE4) and change nothing the loop can see; the external one also
    acknowledges by storing to 00FFFFF0."""
    p = Program()
    COUNT = 0x00FFFFE0
    save = [mtspr(SPRG0, 30), mtspr(SPRG1, 31), D(15, 30, 0, COUNT >> 16), D(24, 30, 30, COUNT)]
    back = [mfspr(SPRG0, 30), mfspr(SPRG1, 31), RFI]
    ext = save + [D(32, 31, 30, 0), D(14, 31, 31, 1), D(36, 31, 30, 0), D(36, 31, 30, 16)] + back
    dec = save + [D(32, 31, 30, 4), D(14, 31, 31, 1), D(36, 31, 30, 4),
                  D(14, 31, 0, 300), mtspr(DEC, 31)] + back
    for i, w in enumerate(ext):
        p.data[0x500 + 4 * i] = w
    for i, w in enumerate(dec):
        p.data[0x900 + 4 * i] = w

    p.words += set_msr(0, 7)
    p.words += li32(1, DATA_A) + li32(3, 1) + li32(4, 0) + li32(5, 0) + li32(6, 0)
    p.words += li32(7, 100) + [mtspr(DEC, 7)]
    p.words += li32(7, loops) + [mtspr(CTR, 7)]
    p.words += set_msr(MSR_EE, 7)
    body = [D(7, 3, 3, 33),            # mulli r3,r3,33
            D(14, 3, 3, 7),            # addi  r3,r3,7
            X(4, 4, 3, 266),           # add   r4,r4,r3
            D(36, 4, 1, 0),            # stw   r4,0(r1)
            D(32, 5, 1, 0),            # lwz   r5,0(r1)
            X(5, 6, 3, 316),           # xor   r6,r5,r3
            X(6, 6, 4, 459)]           # divwu r6,r6,r4 (a long instruction to interrupt)
    p.words += body
    p.words.append((16 << 26) | (16 << 21) | ((-4 * len(body)) & 0xFFFC))     # bdnz
    p.words += set_msr(0, 7)
    r3, r4, r5, r6 = 1, 0, 0, 0
    for _ in range(loops):
        r3 = (r3 * 33 + 7) & 0xFFFFFFFF
        r4 = (r4 + r3) & 0xFFFFFFFF
        r5 = r4
        r6 = r5 ^ r3
        r6 = (r6 // r4) if r4 else ((r6 << 4) | 0xF) & 0xFFFFFFFF
    p.words.append(NOP)
    p.checks.append((len(p.words) - 1, check_text([r3, r4, r5, r6], 0, 0, 0, 0, [0, 0, 0, 0], "loop")))
    p.expect[DATA_A] = r4
    p.words.append(B_SELF)
    p.write(out)
    print("%d instructions, %d loops -> %s" % (len(p.words), loops, out))


# ---- random floating-point programs, checked against fpmodel.py ------------------
SCRATCH = 0x00500000


def fprandom(out, count, seed):
    """Straight-line floating-point code. This script executes it as well, with
    fpmodel.py, and records the state every instruction must leave behind.
    f3-f6 are the only registers written, so the four the test bench checks
    are the whole floating-point state that changes."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import fpmodel as fm

    rnd = random.Random(seed)
    p = Program()
    mem = {}                                   # word address -> value, the model's memory

    def poke(addr, word):
        mem[addr] = word
        p.data[addr] = word

    doubles = [fm._rand_double(rnd) for _ in range(256)]
    singles = [rnd.choice((rnd.getrandbits(32), rnd.getrandbits(32) & 0x807FFFFF,
                           (rnd.getrandbits(32) & 0x807FFFFF) | 0x7F800000,
                           rnd.getrandbits(32) & 0x80000000, 0x7F800000, 0x00000001))
               for _ in range(256)]
    for i, d in enumerate(doubles):
        poke(POOL_BASE + 8 * i, d >> 32)
        poke(POOL_BASE + 8 * i + 4, d & 0xFFFFFFFF)
    for i, w in enumerate(singles):
        poke(POOL_BASE + 0x1000 + 4 * i, w)

    fpr = [0] * 32
    st = {"fpscr": 0, "cr": 0, "r11": SCRATCH}

    def emit(word):
        p.words.append(word)

    def check(tag):
        p.checks.append((len(p.words) - 1, check_text(
            [0, 0, 0, 0], st["cr"], 0, 0, st["fpscr"], fpr[3:7], tag)))

    def cr1():
        st["cr"] = (st["cr"] & ~0x0F000000) | ((st["fpscr"] >> 28) << 24)

    def set_crf(field, val):
        sh = 28 - 4 * field
        st["cr"] = (st["cr"] & ~(0xF << sh)) | (val << sh)

    # prologue: bases, an index, and every source register loaded
    p.words += set_msr(MSR_FP)
    p.words += li32(10, POOL_BASE) + li32(11, SCRATCH) + li32(12, 8) + li32(9, SCRATCH + 0x800)
    for r in range(0, 8):
        i = rnd.randrange(256)
        emit(lfd(r, 10, 8 * i))
        fpr[r] = doubles[i]

    dst = lambda: rnd.randrange(3, 7)
    src = lambda: rnd.randrange(0, 8)
    bit = lambda: rnd.getrandbits(1)
    arith = [n for n in fm.GEN_OPS if n not in ("FCMPU", "FCMPO")]

    done = 0
    while done < count:
        k = rnd.random()
        if k < 0.45:
            # arithmetic, moves, conversions
            name = rnd.choice(arith)
            op, xo, uses = fm.GEN_OPS[name]
            d, a, b, c = dst(), src(), src(), src()
            rc = 0 if name == "FSEL" else bit()
            fm.UNDEFINED = False
            res, new, _ = fm.execute(name, fpr[a], fpr[b], fpr[c], st["fpscr"])
            if fm.UNDEFINED:
                continue
            emit(fm._a(op, d, a if "a" in uses else 0, b if "b" in uses else 0,
                       c if "c" in uses else 0, xo, rc))
            if res is not None:
                fpr[d] = res
            st["fpscr"] = new
            if rc:
                cr1()
            check(name)
        elif k < 0.50:
            name = rnd.choice(("FCMPU", "FCMPO"))
            op, xo, _ = fm.GEN_OPS[name]
            a, b, crf = src(), src(), rnd.randrange(8)
            _, new, c = fm.execute(name, fpr[a], fpr[b], 0, st["fpscr"])
            emit(fm._a(op, crf << 2, a, b, 0, xo, 0))
            st["fpscr"] = new
            set_crf(crf, c)
            check(name)
        elif k < 0.62:
            # loads: displacement, indexed (r10 + r12), and with update through r11
            d, form = dst(), rnd.randrange(4)
            double = bit()
            if form == 0:
                i = rnd.randrange(256)
                addr = POOL_BASE + (8 * i if double else 0x1000 + 4 * i)
                emit(D(50 if double else 48, d, 10, addr - POOL_BASE))       # lfd, lfs
            elif form == 1:
                addr = POOL_BASE + 8                                         # r10 + r12
                emit(X(d, 10, 12, 599 if double else 535))                   # lfdx, lfsx
            else:
                # lfdu / lfsu from where r11 points after the update: move r11 within the scratch area
                step = 4 * rnd.randrange(-4, 5)
                addr = st["r11"] + step
                if addr < SCRATCH - 0x400 or addr > SCRATCH + 0x400:
                    continue
                st["r11"] = addr
                emit(D(51 if double else 49, d, 11, step))
            hi = mem.get(addr, 0)
            if double:
                fpr[d] = (hi << 32) | mem.get(addr + 4, 0)
            else:
                fpr[d] = fm.single_to_double(hi)
            check("load")
        elif k < 0.76:
            # stores into the scratch area
            s, form = src(), rnd.randrange(3)
            kind = rnd.choice(("d", "s", "iw"))
            if form == 0:
                off = 4 * rnd.randrange(-128, 128)
                addr = SCRATCH + 0x800 + off                             # r9 + off
                if kind == "iw":
                    emit(D(14, 8, 0, off))                               # li r8, off
                    emit(X(s, 9, 8, 983))                                # stfiwx
                else:
                    emit(D(54 if kind == "d" else 52, s, 9, off))
            elif form == 1:
                step = 4 * rnd.randrange(-4, 5)
                addr = st["r11"] + step
                if kind == "iw" or addr < SCRATCH - 0x400 or addr > SCRATCH + 0x400:
                    continue
                st["r11"] = addr
                emit(D(55 if kind == "d" else 53, s, 11, step))          # stfdu, stfsu
            else:
                addr = st["r11"] + 8                                     # r11 + r12
                if kind == "iw":
                    emit(X(s, 11, 12, 983))
                else:
                    emit(X(s, 11, 12, 727 if kind == "d" else 663))      # stfdx, stfsx
            v = fpr[s]
            if kind == "d":
                mem[addr], mem[addr + 4] = v >> 32, v & 0xFFFFFFFF
            elif kind == "s":
                mem[addr] = fm.double_to_single(v)
            else:
                mem[addr] = v & 0xFFFFFFFF
            check("store")
        else:
            # FPSCR instructions
            j = rnd.randrange(6)
            rc = bit()
            if j == 0:
                d = dst()
                emit((63 << 26) | (d << 21) | (583 << 1) | rc)           # mffs
                fpr[d] = 0xFFF8000000000000 | st["fpscr"]
            elif j == 1:
                b, mask = src(), rnd.choice((0xFF, 0xFF, rnd.getrandbits(8)))
                emit(mtfsf(mask, b, rc))
                st["fpscr"], _ = fm.fpscr_instr("mtfsf", st["fpscr"], fm=mask, value=fpr[b] & 0xFFFFFFFF)
            elif j == 2:
                fld, imm = rnd.randrange(8), rnd.getrandbits(4)
                emit((63 << 26) | (fld << 23) | (imm << 12) | (134 << 1) | rc)
                st["fpscr"], _ = fm.fpscr_instr("mtfsfi", st["fpscr"], field=fld, value=imm)
            elif j in (3, 4):
                b = rnd.randrange(32)
                emit((63 << 26) | (b << 21) | ((70 if j == 3 else 38) << 1) | rc)
                st["fpscr"], _ = fm.fpscr_instr("mtfsb0" if j == 3 else "mtfsb1", st["fpscr"], bit=b)
            else:
                rc = 0
                crf, fld = rnd.randrange(8), rnd.randrange(8)
                emit((63 << 26) | (crf << 23) | (fld << 18) | (64 << 1))  # mcrfs
                st["fpscr"], c = fm.fpscr_instr("mcrfs", st["fpscr"], field=fld)
                set_crf(crf, c)
            if rc:
                cr1()
            check("fpscr")
        done += 1

    for a, wv in mem.items():
        if a >= SCRATCH - 0x1000:
            p.expect[a] = wv
    p.words.append(B_SELF)
    p.write(out)
    print("%d instructions, %d checks -> %s" % (len(p.words), len(p.checks), out))


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

    install_handlers(p)

    # prologue: MSR, then every register and CR, XER, LR, CTR defined
    p.words += set_msr(0, 3)
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

    def system():
        """Supervisor instructions and things that raise exceptions. In user
        mode the privileged ones trap; the handlers step over them."""
        k = rnd.randrange(12)
        if k == 0:
            return [0x44000002]                                   # sc: switch mode
        if k == 1:
            return [D(3, rnd.randrange(32), rs(), rnd.getrandbits(16))]       # twi
        if k == 2:
            # tw: only conditions that do not care which operand is which
            return [X(rnd.choice((4, 31, 24, 3, 0)), rs(), rs(), 4)]
        if k == 3:
            return [(rnd.choice((0, 1, 5, 6)) << 26) | rnd.getrandbits(26)]   # not an instruction
        if k == 4:
            return [X(rd(), 0, 0, 83)]                            # mfmsr
        if k == 5:
            t = rd()
            v = rnd.choice((0, MSR_FP, 0x1000, 0x3000, MSR_EE, MSR_EE | MSR_FP, MSR_PR, MSR_PR | MSR_FP))
            return li32(t, v) + [mtmsr(t)]
        if k in (6, 7):
            spr = rnd.choice((272, 273, 274, 275, 26, 27, 19, 18))
            return [mtspr(spr, rs()) if k == 6 else mfspr(spr, rd())]
        if k == 8:
            return [mfspr(287, rd())]                             # PVR
        if k == 9:
            return [(31 << 26) | (rd() << 21) | ((268 & 31) << 16) | ((268 >> 5) << 11) | (371 << 1)]  # mftb
        if k == 10:
            n = rnd.randrange(16)
            if bit():
                return [(31 << 26) | (rs() << 21) | (n << 16) | (210 << 1)]   # mtsr
            return [(31 << 26) | (rd() << 21) | (n << 16) | (595 << 1)]       # mfsr
        return [0xFC201090]                                       # fmr f1,f2: traps when MSR[FP] is off

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
        # String operations: the 604 takes an alignment exception when one that
        # is not word-aligned crosses a 4 KB boundary (dingusppc does not), so
        # they go through a copy of the base with bits 5-11 cleared, which
        # keeps the whole string inside the first 128 bytes of its page.
        first, t = rnd.randrange(3, 28), rd()
        while first <= t <= first + 4:
            t = rd()
        inpage = [M(21, base(), t, 0, 27, 19)]                   # t = base & FFFFF01F
        if k == 9:
            return inpage + [X(first, t, rnd.randrange(1, 17), 597 if bit() else 725)]   # lswi stswi
        # lswx stswx: byte count from XER
        u = rd()
        while first <= u <= first + 4 or u == t:
            u = rd()
        count = rnd.randrange(0, 17)
        flags = rnd.choice((0, 0x20000000, 0x80000000, 0xA0000000))
        return inpage + li32(u, flags | count) + [mtspr(XER, u), X(first, t, 0, 533 if bit() else 661)]

    # groups: ('code', words) or ('br', kind, skip)
    groups = []
    total = 0
    while total < count:
        k = rnd.random()
        if k < 0.50:
            g = ("code", [simple()])
        elif k < 0.56:
            g = ("code", system())
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
    default_csv = os.path.join(here, "..", "ppctest", "runs", "results_604_run2.csv")
    if len(a) >= 2 and a[0] == "golden":
        golden(a[1], a[2] if len(a) > 2 else default_csv)
    elif len(a) >= 2 and a[0] == "goldenfp":
        goldenfp(a[1], a[2] if len(a) > 2 else default_csv)
    elif len(a) >= 2 and a[0] == "exctest":
        exctest(a[1])
    elif len(a) >= 2 and a[0] == "fpexctest":
        fpexctest(a[1])
    elif len(a) >= 2 and a[0] == "irqtest":
        irqtest(a[1], int(a[2]) if len(a) > 2 else 3000)
    elif len(a) >= 3 and a[0] == "fprandom":
        fprandom(a[1], int(a[2]), int(a[3]) if len(a) > 3 else 1)
    elif len(a) >= 3 and a[0] == "random":
        gen_random(a[1], int(a[2]), int(a[3]) if len(a) > 3 else 1)
    else:
        print(__doc__)
        sys.exit(2)
