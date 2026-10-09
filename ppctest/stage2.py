"""The second-stage test program: what a user-level program cannot test.

The boot program (harness.py) loads it 64 KB above itself and enters it with
r20 = its own base, r27 = the boot program's base (whose M_HDR holds this
run's slot header and M_HDRBLK that header's block), r26 = client interface,
r25 = console, r24 = disk. Position-independent, base register r20. It never
runs under Linux, and it does nothing on a CPU that is not a 604, 604e, 604ev
or 750 (the record in the slot header says so).

It does three things, in this order:

1. dumps the ROM (4 MB at physical FFC00000) to the disk, once per disk;
2. runs the sequences of svectors.py and writes a 256-byte record for each
   (layout.py, SI_* and SO_*);
3. writes its completion into the run's slot header.

A sequence is up to S_CODE_MAX instructions copied into `slot`, followed by
an `sc` the program appends. It runs under the MSR its record names (POW,
ILE, IP and LE are never changed and ME is always kept on), entered with
mtmsr for supervisor mode and with rfi for user mode. The sequence gets r0 =
that MSR, r3..r8, CR, XER and CTR from the record, r9..r12 = 0, LR = the
address of the appended sc (so a stray bclr ends the sequence; SF_CTR_END
gives CTR the same value), and SRR0/SRR1 pointing at that sc too, so a stray
rfi ends it as well. It may clobber anything except r1 and r2; the program's
own r13..r31 are saved in S_CTX.

While sequences run the program owns the exception vectors: it saves low
memory (LOW_SAVE_START..LOW_SAVE_END), writes a three-instruction stub at
each vector 0x200..0x1700 that saves r3 and jumps to `handler`, and puts the
original contents back before every disk call. The handler keeps a mailbox
in low memory (MB_*). For an exception that is not the appended sc it records
vector, SRR0, SRR1, DAR, DSISR and its own MSR (what the exception set) and
returns to the sequence; for synchronous faults it first adds 4 to SRR0, so
the faulting instruction is stepped over. On the appended sc it stores r0,
r3..r12, CR, XER, CTR, LR and SRR1 (the sequence's final MSR) instead and
leaves through `recover`, which re-establishes the identity BAT3 mapping and
the program's MSR before the program reads the mailbox out into the record.
An instruction-fetch fault, a machine check or the S_EXC_LIMIT-th exception
leaves the same way with SS_RECOVERED in the record.

Cache coherence: the program runs through the boot program's cache-inhibited
BAT3 mapping, but exception handlers, and sequences that turn translation
off, run in real mode, where accesses are cached. Every line the handler or a
sequence may have written (mailbox, scratch buffer) is flushed with dcbf
before the program reads it through the uncached mapping, the handler flushes
the mailbox before every rfi, and code written into `slot` or at the vectors
is flushed and icbi'd before it runs.
"""

from ppcasm import *
from layout import *

# SPRs beyond ppcasm's
DSISR, DAR, DEC, SDR1, SRR0, SRR1 = 18, 19, 22, 25, 26, 27
SPRG0 = 272
IBAT0U, DBAT0U = 528, 536
MMCR0, IABR, DABR = 952, 1010, 1013

MSR_SAFE = 0x3030            # FP | ME | IR | DR: the boot program's MSR
MSR_REAL = 0x3000            # the same with translation off
MSR_KEEP_OFF = 0x00050041    # POW, ILE, IP, LE: a sequence's MSR never sets these
MSR_ME = 0x1000
BAT3U_BOTH = 0x1FFF          # 256 MB at 0, valid in supervisor and user mode
BAT3L_CI_RW = 0x22           # cache-inhibited, read/write

# low-memory mailbox, absolute addresses reached with RA=0 addressing
MB = 0x2000
MB_R3 = MB                   # r3..r12 at MB_R3 + 4*(n-3)
MB_R0, MB_CR, MB_XER, MB_CTR, MB_LR, MB_SC_SRR1 = (MB + 0x28, MB + 0x2C, MB + 0x30,
                                                   MB + 0x34, MB + 0x38, MB + 0x3C)
MB_COUNT, MB_FLAGS, MB_END, MB_RECOVER, MB_BASE = (MB + 0x40, MB + 0x44, MB + 0x48,
                                                   MB + 0x4C, MB + 0x50)
MB_EXC = MB + 0x60           # S_EXC_LIMIT records of 24 bytes
MB_SIZE = 0x100
LOW_SAVE_START, LOW_SAVE_END = 0x100, 0x3000
LOW_LINES = (LOW_SAVE_END - LOW_SAVE_START) // 32
VECTORS = list(range(0x200, 0x1800, 0x100))
# synchronous faults whose instruction is stepped over
STEP_MASK = sum(1 << (v >> 8) for v in (0x300, 0x600, 0x700, 0x800, 0xA00, 0xB00, 0xE00, 0x1300))
LEAVE_MASK = (1 << 2) | (1 << 4)       # machine check, ISI: the sequence is abandoned

# RAM, offsets from the base; the code must end below CODE_MAX
CODE_MAX = 0x2000
S_CTX = 0x2000               # LR, r1, r2, r13..r31
S_SAVE = 0x2080              # SR0..15, DBAT0-2 U/L, IBAT0-2 U/L, SPRG0-3, DEC, SDR1, MMCR0, PMC1, PMC2
SV_SR, SV_DBAT, SV_IBAT, SV_SPRG, SV_DEC, SV_SDR1, SV_PM = 0, 64, 88, 112, 128, 132, 136
S_ZERO = 0x2180
S_HEX = 0x2190
S_ROMSUM, S_FLAGS, S_NEXC, S_SLOTADDR, S_ENDADDR = 0x21A0, 0x21A4, 0x21A8, 0x21AC, 0x21B0
S_ARGS = 0x2200
S_OPNAME, S_IOBUF, S_IOLEN = 0x2240, 0x2244, 0x2248
S_SCRATCH = 0x2400           # 256 bytes, the first 64 are recorded
S_SCRATCH_SIZE = 256
S_DRAINOUT = 0x2800          # output record of the drain sequence (discarded)
S_IN = 0x3000
S_OUT = 0x4000
S_LOWSAVE = 0x5000           # copy of LOW_SAVE_START..LOW_SAVE_END
S_SIZE = 0x8000
SLOT_WORDS = 40              # S_CODE_MAX instructions, the sc, branches back to it

CRLF = chr(13) + chr(10)
PVR_750, PVR_604 = (8,), (4, 9, 10)
CPU_750, CPU_604, CPU_PMC34 = 1, 2, 4    # bits of r23; PMC34: has MMCR1, PMC3, PMC4
MMCR1, PMC1, PMC2, PMC3, PMC4 = 956, 953, 954, 957, 958


# --- encoders ppcasm does not have -----------------------------------------
def slw(ra, rs, rb):        return x_form(31, rs, ra, rb, 24)
def and_(ra, rs, rb, rc=0): return x_form(31, rs, ra, rb, 28, rc)
def subfic(rt, ra, si):     return d_form(8, rt, ra, si & 0xFFFF)
def oris(ra, rs, ui):       return d_form(25, rs, ra, ui)
def lmw(rt, d, ra):         return d_form(46, rt, ra, d & 0xFFFF)
def stmw(rs, d, ra):        return d_form(47, rs, ra, d & 0xFFFF)
def mfsr(rt, sr):           return x_form(31, rt, sr, 0, 595)
def mtsr(sr, rs):           return x_form(31, rs, sr, 0, 210)
def rfi():                  return (19 << 26) | (50 << 1)
def ba_word(addr):          return (18 << 26) | (addr & 0x03FFFFFC) | 2


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


def build():
    a = Asm(base_reg=20)
    e = a.emit

    def flush_lines(start_reg, nlines, icbi_too=False):
        """dcbf (and icbi) nlines cache lines from the address in start_reg;
        uses CTR and the register itself."""
        e(li(0, nlines), mtctr(0))
        lbl = "fl%d" % a.pos
        a.label(lbl)
        e(dcbf(0, start_reg))
        if icbi_too:
            e(icbi(0, start_reg))
        e(addi(start_reg, start_reg, 32))
        a.bdnz(lbl)
        e(sync())

    # ---- entry -----------------------------------------------------------
    # stale instruction-cache lines for our addresses would be fatal in real mode
    e(mr(9, 20))
    flush_lines(9, CODE_MAX // 32, icbi_too=True)
    e(isync())
    a.la(3, "s_banner"); a.bl("puts")
    e(li(18, 0), li(19, 0), li(29, 0), li(0, 0))
    e(stw(0, S_ROMSUM, 20), stw(0, S_FLAGS, 20), stw(0, S_NEXC, 20))

    e(mfspr(8, PVR), srwi(8, 8, 16), li(23, 0))
    for fam in PVR_750:
        e(cmpwi(8, fam)); a.beq("is750")
    for fam in PVR_604:
        e(cmpwi(8, fam)); a.beq("is604")
    # another CPU: say so in the header and stop
    e(li(0, S2F_SKIPPED), stw(0, S_FLAGS, 20))
    a.la(3, "s_skip"); a.bl("puts")
    a.b("header")
    a.label("is750")
    e(li(23, CPU_750 | CPU_PMC34))
    a.b("cpu_ok")
    a.label("is604")
    e(li(23, CPU_604), cmpwi(8, 4))
    a.beq("cpu_ok")
    e(li(23, CPU_604 | CPU_PMC34))                # 604e, 604ev
    a.label("cpu_ok")

    # BAT3 (the boot program's identity mapping) also valid in user mode; the
    # mapping does not change, so it is rewritten in place
    e(li(9, BAT3U_BOTH), mtspr(DBAT3U, 9), mtspr(IBAT3U, 9), isync())
    # supervisor state to put back after every sequence
    for i in range(16):
        e(mfsr(9, i), stw(9, S_SAVE + SV_SR + 4 * i, 20))
    for i in range(6):
        e(mfspr(9, DBAT0U + i), stw(9, S_SAVE + SV_DBAT + 4 * i, 20))
        e(mfspr(9, IBAT0U + i), stw(9, S_SAVE + SV_IBAT + 4 * i, 20))
    for i in range(4):
        e(mfspr(9, SPRG0 + i), stw(9, S_SAVE + SV_SPRG + 4 * i, 20))
    e(mfspr(9, DEC), stw(9, S_SAVE + SV_DEC, 20), mfspr(9, SDR1), stw(9, S_SAVE + SV_SDR1, 20))
    for i, spr in enumerate((MMCR0, PMC1, PMC2)):
        e(mfspr(9, spr), stw(9, S_SAVE + SV_PM + 4 * i, 20))
    # the first stage leaves FPSCR as its last vector set it
    e(li(0, 0), stw(0, S_ZERO, 20), stw(0, S_ZERO + 4, 20), lfd(0, S_ZERO, 20), mtfsf(0xFF, 0))

    # ---- 1. the ROM, once per disk --------------------------------------------
    e(lwz(21, M_HDR + H_ROM2BLK, 27), cmpwi(21, 0))
    a.beq("rom_done")
    e(addi(3, 21, ROM2_BLKS), addi(4, 20, S_IN), li(5, BLOCK)); a.bl("disk_read")
    e(cmpwi(3, BLOCK))
    a.bne("e_read")
    e(lwz(8, S_IN, 20)); a.li32(9, ROM2_MAGIC); e(cmpw(8, 9))
    a.beq("rom_present")
    a.la(3, "s_rom"); a.bl("puts")
    e(li(13, 0)); a.li32(22, 0xFFC00000); e(li(28, 0x400000 // 4096))
    a.label("rom_chunk")
    # the ROM is read by physical address: data translation off while copying;
    # the stores then go through the cache, which is flushed before the write
    e(mfmsr(7), rlwinm(8, 7, 0, 28, 26), mtmsr(8), isync())
    e(addi(10, 20, S_OUT), li(9, 0), li(11, 1024), mtctr(11))
    a.label("rom_cpy")
    e(lwzx(0, 22, 9), stwx(0, 10, 9), rotlwi(13, 13, 1), add(13, 13, 0), addi(9, 9, 4))
    a.bdnz("rom_cpy")
    flush_lines(10, 4096 // 32)
    e(mtmsr(7), isync())
    e(mr(3, 21), addi(4, 20, S_OUT), li(5, 4096)); a.bl("disk_write")
    e(cmpwi(3, 4096))
    a.beq("rom_wok")
    e(li(18, 1))
    a.label("rom_wok")
    e(addi(21, 21, CHUNK_BLOCKS), addi(22, 22, 4096), addi(28, 28, -1))
    e(andi_(0, 28, 15))
    a.bne("rom_nodot")
    a.la(3, "s_dot"); a.bl("puts")                 # one dot per 64 KB
    a.label("rom_nodot")
    e(cmpwi(28, 0))
    a.bne("rom_chunk")
    # the marker block: magic, PVR, checksum, slot, write failures
    e(addi(10, 20, S_OUT), li(0, 0), li(9, BLOCK // 4), mtctr(9))
    a.label("rom_z")
    e(stw(0, 0, 10), addi(10, 10, 4))
    a.bdnz("rom_z")
    a.li32(0, ROM2_MAGIC)
    e(stw(0, S_OUT, 20), mfspr(0, PVR), stw(0, S_OUT + 4, 20), stw(13, S_OUT + 8, 20))
    e(lwz(0, M_HDR + H_SLOT, 27), stw(0, S_OUT + 12, 20), stw(18, S_OUT + 16, 20))
    e(mr(3, 21), addi(4, 20, S_OUT), li(5, BLOCK)); a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("rom_mok")
    e(li(18, 1))
    a.label("rom_mok")
    e(stw(13, S_ROMSUM, 20), li(0, S2F_ROM_DUMPED), stw(0, S_FLAGS, 20))
    e(mr(3, 13)); a.bl("puthex")
    a.b("rom_done")
    a.label("rom_present")
    e(li(0, S2F_ROM_PRESENT), stw(0, S_FLAGS, 20))
    a.la(3, "s_rompresent"); a.bl("puts")
    a.label("rom_done")

    # ---- 2. the sequences -----------------------------------------------------
    # r13 chunk block offset, r21 this run's result base block, r22 sequences
    # left, r17 in this chunk, r28 loop count, r29 index, r31/r30 records
    e(lwz(22, M_HDR + H_NSV, 27), li(13, 0))
    e(lwz(21, M_HDR + H_SLOT, 27), addi(21, 21, -1), lwz(9, M_HDR + H_SSTRIDE, 27))
    e(mullw(21, 21, 9), lwz(9, M_HDR + H_SRBLK, 27), add(21, 21, 9))
    a.la(3, "s_seq"); a.bl("puts")
    a.label("chunk")
    e(cmpwi(22, 0))
    a.ble("header")
    e(lwz(3, M_HDR + H_SVBLK, 27), add(3, 3, 13), addi(4, 20, S_IN), li(5, 4096))
    a.bl("disk_read")
    e(cmpwi(3, 4096))
    a.bne("e_read")
    e(li(17, SCHUNK_RECS), cmpw(22, 17))
    a.bge("n_ok")
    e(mr(17, 22))
    a.label("n_ok")
    a.bl("low_prepare")
    e(addi(31, 20, S_IN), addi(30, 20, S_OUT), mr(28, 17))
    a.label("one")
    a.bl("run_one")
    # checksum: sum = rotl(sum, 1) + word, over the 64 output words
    e(li(9, SREC // 4), mtctr(9), mr(8, 30))
    a.label("ck")
    e(lwz(0, 0, 8), rotlwi(19, 19, 1), add(19, 19, 0), addi(8, 8, 4))
    a.bdnz("ck")
    e(addi(29, 29, 1), addi(31, 31, SREC), addi(30, 30, SREC), addi(28, 28, -1), cmpwi(28, 0))
    a.bne("one")
    # the drain: a fixed sequence that enables external interrupts for a
    # moment, so that any request the sequences left behind (decrementer,
    # performance monitor) is taken by our handler and not by the firmware
    # once it has its memory back (a 604 in the 7300 was left with a
    # performance-monitor request that its firmware then caught endlessly)
    a.la(31, "drain_rec"); e(addi(30, 20, S_DRAINOUT))
    a.bl("run_one")
    a.bl("low_restore")
    e(add(3, 21, 13), addi(4, 20, S_OUT), li(5, 4096)); a.bl("disk_write")
    e(cmpwi(3, 4096))
    a.beq("w_ok")
    e(li(18, 1))
    a.label("w_ok")
    e(addi(13, 13, CHUNK_BLOCKS), subf(22, 17, 22))
    a.la(3, "s_dot"); a.bl("puts")
    a.b("chunk")

    # ---- 3. the slot header ---------------------------------------------------
    a.label("header")
    a.li32(0, DONE)
    e(stw(0, M_HDR + H_S2DONE, 27), stw(29, M_HDR + H_S2NRUN, 27), stw(19, M_HDR + H_S2SUM, 27))
    e(lwz(9, S_FLAGS, 20), cmpwi(18, 0))
    a.beq("f_ok")
    e(ori(9, 9, S2F_WRFAIL))
    a.label("f_ok")
    e(stw(9, M_HDR + H_S2FLAGS, 27), lwz(0, S_ROMSUM, 20), stw(0, M_HDR + H_S2ROMSUM, 27))
    e(lwz(3, M_HDRBLK, 27), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("h_ok")
    e(li(18, 1))
    a.label("h_ok")
    # Open Firmware 1.0.5 holds the last write until the next disk operation
    e(li(3, 0), addi(4, 20, S_IN), li(5, BLOCK)); a.bl("disk_read")
    a.la(3, "s_n"); a.bl("puts"); e(mr(3, 29)); a.bl("puthex")
    a.la(3, "s_sum"); a.bl("puts"); e(mr(3, 19)); a.bl("puthex")
    a.la(3, "s_exc"); a.bl("puts"); e(lwz(3, S_NEXC, 20)); a.bl("puthex")
    e(cmpwi(18, 0))
    a.la(3, "s_wok")
    a.beq("pw")
    a.la(3, "s_wfail")
    a.label("pw")
    a.bl("puts")
    # The DEC is left as the program set it (a large positive value). Putting
    # the firmware's value back raised a decrementer exception request that
    # the firmware caught after our exit (seen in the emulator). The
    # performance monitor goes back to what the firmware had.
    e(cmpwi(23, 0))
    a.beq("exit")
    for i, spr in enumerate((PMC1, PMC2, MMCR0)):
        e(lwz(9, S_SAVE + SV_PM + 4 * ((i + 1) % 3), 20), mtspr(spr, 9))
    a.b("exit")

    # ---- one sequence (r31 input record, r30 output record) -------------------
    a.label("run_one")
    e(mflr(0), stw(0, S_CTX, 20))
    e(lwz(8, SI_FLAGS, 31), andi_(9, 8, SF_ONLY_750))
    a.beq("chk604")
    e(andi_(9, 23, CPU_750))
    a.beq("skip")
    a.label("chk604")
    e(andi_(9, 8, SF_ONLY_604))
    a.beq("run")
    e(andi_(9, 23, CPU_604))
    a.beq("skip")
    a.label("run")
    # mailbox
    e(li(0, 0), stw(0, MB_COUNT, 0), stw(0, MB_FLAGS, 0), stw(0, MB_SC_SRR1, 0))
    e(li(9, MB_EXC), li(10, S_EXC_LIMIT * 6), mtctr(10))
    a.label("mb_z")
    e(stw(0, 0, 9), addi(9, 9, 4))
    a.bdnz("mb_z")
    a.la(9, "recover"); e(stw(9, MB_RECOVER, 0), stw(20, MB_BASE, 0))
    # the code into the slot, then the sc, then branches back to the sc
    e(lwz(10, SI_NCODE, 31), cmplwi(10, S_CODE_MAX))
    a.ble("n_code_ok")
    e(li(10, S_CODE_MAX))
    a.label("n_code_ok")
    a.la(11, "slot"); e(stw(11, S_SLOTADDR, 20), addi(12, 31, SI_CODE), cmpwi(10, 0))
    a.beq("no_code")
    e(mtctr(10))
    a.label("cp_code")
    e(lwz(0, 0, 12), stw(0, 0, 11), addi(12, 12, 4), addi(11, 11, 4))
    a.bdnz("cp_code")
    a.label("no_code")
    e(stw(11, S_ENDADDR, 20), addi(0, 11, 4), stw(0, MB_END, 0))
    a.li32(0, sc()); e(stw(0, 0, 11))
    e(subfic(9, 10, SLOT_WORDS - 1), cmpwi(9, 0))
    a.beq("filled")
    e(mtctr(9), li(12, -4))
    a.label("fill")
    e(addi(11, 11, 4), rlwinm(0, 12, 0, 6, 29), oris(0, 0, 0x4800), stw(0, 0, 11), addi(12, 12, -4))
    a.bdnz("fill")
    a.label("filled")
    a.la(9, "slot")
    flush_lines(9, SLOT_WORDS * 4 // 32 + 1, icbi_too=True)
    e(isync())
    # the scratch buffer: zeroed, the record's 16 words, flushed
    e(addi(9, 20, S_SCRATCH), li(0, 0), li(10, S_SCRATCH_SIZE // 4), mtctr(10))
    a.label("sc_z")
    e(stw(0, 0, 9), addi(9, 9, 4))
    a.bdnz("sc_z")
    e(addi(9, 20, S_SCRATCH), addi(12, 31, SI_SCRATCH), li(10, 16), mtctr(10))
    a.label("sc_cp")
    e(lwz(0, 0, 12), stw(0, 0, 9), addi(12, 12, 4), addi(9, 9, 4))
    a.bdnz("sc_cp")
    e(addi(9, 20, S_SCRATCH))
    flush_lines(9, S_SCRATCH_SIZE // 32)
    # our registers
    e(stw(1, S_CTX + 4, 20), stw(2, S_CTX + 8, 20), stmw(13, S_CTX + 12, 20))
    # the sequence's registers that need decisions, before CR is loaded
    e(lwz(0, SI_FLAGS, 31))
    e(lwz(4, SI_R3 + 4, 31), andi_(10, 0, SF_R4_SCRATCH))
    a.beq("r4_ok")
    e(addi(10, 20, S_SCRATCH), add(4, 4, 10))
    a.label("r4_ok")
    e(lwz(9, SI_CTR, 31), andi_(10, 0, SF_CTR_END))
    a.beq("ctr_ok")
    e(lwz(9, S_ENDADDR, 20))
    a.label("ctr_ok")
    e(mtctr(9), lwz(9, S_ENDADDR, 20), mtlr(9))
    e(lwz(12, SI_MSR, 31)); a.li32(10, ~MSR_KEEP_OFF & 0xFFFFFFFF)
    e(and_(12, 12, 10), ori(12, 12, MSR_ME))
    # SRR0/SRR1: a stray rfi lands on the appended sc, in the sequence's own MSR
    e(mtspr(SRR1, 12), lwz(9, S_ENDADDR, 20), andi_(11, 12, 0x4000))
    a.bne("enter_user")
    e(mtspr(SRR0, 9))

    def load_regs():
        e(lwz(9, SI_CR, 31), mtcrf(0xFF, 9), lwz(9, SI_XER, 31), mtxer(9))
        e(lwz(3, SI_R3, 31), lwz(5, SI_R3 + 8, 31), lwz(6, SI_R3 + 12, 31))
        e(lwz(7, SI_R3 + 16, 31), lwz(8, SI_R3 + 20, 31))
        e(mr(0, 12), li(9, 0), li(10, 0), li(11, 0), li(12, 0))

    load_regs()
    e(mtmsr(0), isync())
    while a.pos % 32:
        e(nop())
    a.label("slot")
    for _ in range(SLOT_WORDS):
        e(nop())
    a.label("enter_user")
    a.la(9, "slot"); e(mtspr(SRR0, 9))
    load_regs()
    e(rfi())

    # ---- back from the handler: real mode, nothing in the registers -------------
    a.label("recover")
    e(li(0, 0), mtspr(DBAT3U, 0), mtspr(IBAT3U, 0), isync())
    e(li(9, BAT3U_BOTH), li(10, BAT3L_CI_RW))
    e(mtspr(DBAT3L, 10), mtspr(DBAT3U, 9), mtspr(IBAT3L, 10), mtspr(IBAT3U, 9), isync())
    e(li(0, MSR_SAFE), mtmsr(0), isync())
    e(lwz(20, MB_BASE, 0))
    # lines real-mode code may have written
    e(li(9, MB))
    flush_lines(9, MB_SIZE // 32)
    e(addi(9, 20, S_SCRATCH))
    flush_lines(9, S_SCRATCH_SIZE // 32)
    e(lwz(1, S_CTX + 4, 20), lwz(2, S_CTX + 8, 20), lmw(13, S_CTX + 12, 20))
    # supervisor state the sequence may have changed
    for i in range(16):
        e(lwz(9, S_SAVE + SV_SR + 4 * i, 20), mtsr(i, 9))
    e(isync())
    for i in range(6):
        e(lwz(9, S_SAVE + SV_DBAT + 4 * i, 20), mtspr(DBAT0U + i, 9))
        e(lwz(9, S_SAVE + SV_IBAT + 4 * i, 20), mtspr(IBAT0U + i, 9))
    e(isync())
    for i in range(4):
        e(lwz(9, S_SAVE + SV_SPRG + 4 * i, 20), mtspr(SPRG0 + i, 9))
    e(lwz(9, S_SAVE + SV_SDR1, 20), mtspr(SDR1, 9))
    a.li32(9, 0x7FFFFFFF); e(mtspr(DEC, 9))
    # performance monitor off and its counters cleared (an overflowed counter
    # keeps its interrupt request alive otherwise), IABR and DABR off
    a.li32(9, 0x80000000); e(mtspr(MMCR0, 9))
    e(li(0, 0), mtspr(PMC1, 0), mtspr(PMC2, 0), mtspr(IABR, 0), mtxer(0), andi_(9, 23, CPU_PMC34))
    a.beq("no_pmc34")
    e(mtspr(MMCR1, 0), mtspr(PMC3, 0), mtspr(PMC4, 0))
    a.label("no_pmc34")
    e(andi_(9, 23, CPU_750))
    a.beq("no_dabr")
    e(mtspr(DABR, 0))
    a.label("no_dabr")
    e(lfd(0, S_ZERO, 20), mtfsf(0xFF, 0))
    # the record
    e(lwz(9, MB_FLAGS, 0), lwz(10, MB_COUNT, 0), slwi(10, 10, 8), or_(9, 9, 10))
    e(ori(9, 9, SS_RAN), stw(9, SO_STATUS, 30), lwz(9, MB_SC_SRR1, 0), stw(9, SO_MSR, 30))
    e(lwz(9, MB_COUNT, 0), lwz(10, S_NEXC, 20), add(10, 10, 9), stw(10, S_NEXC, 20))
    for i in range(10):
        e(lwz(9, MB_R3 + 4 * i, 0), stw(9, SO_R3 + 4 * i, 30))
    for i in range(4):
        e(lwz(9, MB_CR + 4 * i, 0), stw(9, SO_CR + 4 * i, 30))
    for i in range(16):
        e(lwz(9, S_SCRATCH + 4 * i, 20), stw(9, SO_SCRATCH + 4 * i, 30))
    e(li(9, MB_EXC), addi(10, 30, SO_EXC), li(11, SO_EXC_MAX * SO_EXC_SIZE // 4), mtctr(11))
    a.label("cp_exc")
    e(lwz(0, 0, 9), stw(0, 0, 10), addi(9, 9, 4), addi(10, 10, 4))
    a.bdnz("cp_exc")
    e(lwz(9, S_SLOTADDR, 20), stw(9, SO_SLOT, 30), addi(9, 20, S_SCRATCH), stw(9, SO_SCRATCHADDR, 30))
    a.b("one_done")
    a.label("skip")
    e(li(0, 0), mr(9, 30), li(10, SREC // 4), mtctr(10))
    a.label("sk_z")
    e(stw(0, 0, 9), addi(9, 9, 4))
    a.bdnz("sk_z")
    e(li(0, SS_SKIPPED), stw(0, SO_STATUS, 30))
    a.label("one_done")
    e(lwz(0, S_CTX, 20), mtlr(0), blr())

    # ---- the exception handler: real mode, r3 = vector, r3's value at MB_R3 -----
    def flush_mailbox():
        for i in range(MB_SIZE // 32):
            e(li(4, MB + 32 * i), dcbf(0, 4))
        e(sync())

    a.label("handler")
    for n in range(4, 10):
        e(stw(n, MB_R3 + 4 * (n - 3), 0))
    e(mfcr(4), stw(4, MB_CR, 0), mfspr(5, SRR0), mfspr(6, SRR1), lwz(7, MB_END, 0))
    e(cmpwi(3, 0xC00))
    a.bne("h_exc")
    e(cmpw(5, 7))
    a.bne("h_exc")
    e(stw(6, MB_SC_SRR1, 0))                      # the appended sc: the sequence is over
    a.b("h_dump")
    a.label("h_exc")
    e(lwz(8, MB_COUNT, 0), cmplwi(8, S_EXC_LIMIT))
    a.bge("h_abandon")
    e(mulli(9, 8, SO_EXC_SIZE), addi(9, 9, MB_EXC))
    e(stw(3, 0, 9), stw(5, 4, 9), stw(6, 8, 9))
    e(mfspr(4, DAR), stw(4, 12, 9), mfspr(4, DSISR), stw(4, 16, 9), mfmsr(4), stw(4, 20, 9))
    e(addi(8, 8, 1), stw(8, MB_COUNT, 0), cmplwi(8, S_EXC_LIMIT))
    a.bge("h_abandon")
    e(srwi(4, 3, 8), li(9, 1), slw(9, 9, 4), andi_(4, 9, LEAVE_MASK))
    a.bne("h_abandon")
    a.li32(4, STEP_MASK); e(and_(4, 9, 4, rc=1))
    a.beq("h_ret")
    e(addi(5, 5, 4))
    a.label("h_ret")
    e(mtspr(SRR0, 5))
    flush_mailbox()
    e(lwz(4, MB_CR, 0), mtcrf(0xFF, 4))
    for n in range(4, 10):
        e(lwz(n, MB_R3 + 4 * (n - 3), 0))
    e(lwz(3, MB_R3, 0), rfi())
    a.label("h_abandon")
    e(lwz(4, MB_FLAGS, 0), ori(4, 4, SS_RECOVERED), stw(4, MB_FLAGS, 0), stw(6, MB_SC_SRR1, 0))
    a.label("h_dump")
    e(stw(0, MB_R0, 0), stw(10, MB_R3 + 28, 0), stw(11, MB_R3 + 32, 0), stw(12, MB_R3 + 36, 0))
    e(mfxer(4), stw(4, MB_XER, 0), mfctr(4), stw(4, MB_CTR, 0), mflr(4), stw(4, MB_LR, 0))
    flush_mailbox()
    e(lwz(4, MB_RECOVER, 0), mtspr(SRR0, 4), li(4, MSR_REAL), mtspr(SRR1, 4), rfi())

    # ---- the exception vectors: ours while a chunk runs -------------------------
    a.label("low_prepare")
    e(mflr(14), li(9, LOW_SAVE_START))
    flush_lines(9, LOW_LINES)                     # Open Firmware's dirty lines, if any
    e(li(9, LOW_SAVE_START), addi(10, 20, S_LOWSAVE), li(11, (LOW_SAVE_END - LOW_SAVE_START) // 4))
    e(mtctr(11))
    a.label("lp_save")
    e(lwz(0, 0, 9), stw(0, 0, 10), addi(9, 9, 4), addi(10, 10, 4))
    a.bdnz("lp_save")
    # stub: stw r3, MB_R3(0); li r3, vector; ba handler
    a.la(11, "handler"); e(rlwinm(11, 11, 0, 6, 29), oris(11, 11, 0x4800), ori(11, 11, 2))
    a.li32(12, stw(3, MB_R3, 0))
    e(li(9, VECTORS[0]), li(10, len(VECTORS)), mtctr(10))
    a.label("lp_stub")
    e(stw(12, 0, 9), addis(0, 9, 0x3860), stw(0, 4, 9), stw(11, 8, 9), addi(9, 9, 0x100))
    a.bdnz("lp_stub")
    e(li(9, LOW_SAVE_START))
    flush_lines(9, LOW_LINES, icbi_too=True)
    e(isync(), mtlr(14), blr())

    a.label("low_restore")
    e(mflr(14), li(9, LOW_SAVE_START))
    flush_lines(9, LOW_LINES)                     # the handler's lines, if any are left
    e(li(9, LOW_SAVE_START), addi(10, 20, S_LOWSAVE), li(11, (LOW_SAVE_END - LOW_SAVE_START) // 4))
    e(mtctr(11))
    a.label("lr_copy")
    e(lwz(0, 0, 10), stw(0, 0, 9), addi(9, 9, 4), addi(10, 10, 4))
    a.bdnz("lr_copy")
    e(li(9, LOW_SAVE_START))
    flush_lines(9, LOW_LINES, icbi_too=True)
    e(isync(), mtlr(14), blr())

    # ---- errors, exit, helpers (as in the boot program, base r20) ----------------
    a.label("e_read"); a.la(3, "s_eread"); a.bl("puts")
    a.label("exit")
    a.la(3, "s_nl"); a.bl("puts")
    a.la(3, "s_exit"); e(li(4, 0), li(5, 0)); a.bl("ofcall")
    a.label("hang")
    a.b("hang")

    # ofcall(r3 = service name, r4 = nargs, r5 = nrets, r6..r9 = args) -> r3
    a.label("ofcall")
    e(mflr(16), addi(10, 20, S_ARGS))
    e(stw(3, 0, 10), stw(4, 4, 10), stw(5, 8, 10))
    e(stw(6, 12, 10), stw(7, 16, 10), stw(8, 20, 10), stw(9, 24, 10))
    e(slwi(4, 4, 2), add(15, 10, 4), li(0, -1), stw(0, 12, 15))
    e(mr(3, 10), mtctr(26), bctrl())
    e(lwz(3, 12, 15), mtlr(16), blr())

    # disk_read / disk_write(r3 = block, r4 = buffer, r5 = bytes) -> bytes done
    a.label("disk_read")
    a.la(7, "s_read")
    a.b("disk_io")
    a.label("disk_write")
    a.la(7, "s_write")
    a.label("disk_io")
    e(mflr(14), stw(7, S_OPNAME, 20), stw(4, S_IOBUF, 20), stw(5, S_IOLEN, 20))
    e(srwi(7, 3, 23), slwi(8, 3, 9), mr(6, 24))
    a.la(3, "s_seek"); e(li(4, 3), li(5, 1))
    a.bl("ofcall")
    e(lwz(3, S_OPNAME, 20), li(4, 3), li(5, 1), mr(6, 24))
    e(lwz(7, S_IOBUF, 20), lwz(8, S_IOLEN, 20))
    a.bl("ofcall")
    e(mtlr(14), blr())

    a.label("puts")
    e(mflr(14), mr(7, 3), li(8, 0))
    a.label("pl")
    e(lbzx(0, 7, 8), cmpwi(0, 0))
    a.beq("pw2")
    e(addi(8, 8, 1))
    a.b("pl")
    a.label("pw2")
    a.la(3, "s_write"); e(li(4, 3), li(5, 1), mr(6, 25))
    a.bl("ofcall")
    e(mtlr(14), blr())

    a.label("puthex")
    e(mflr(14), addi(7, 20, S_HEX), mr(9, 7), li(8, 8), mtctr(8))
    a.label("ph1")
    e(rotlwi(3, 3, 4), andi_(10, 3, 15), cmpwi(10, 10))
    a.blt("ph2")
    e(addi(10, 10, 7))
    a.label("ph2")
    e(addi(10, 10, 48), stb(10, 0, 9), addi(9, 9, 1))
    a.bdnz("ph1")
    a.la(3, "s_write"); e(li(4, 3), li(5, 1), mr(6, 25), li(8, 8))
    a.bl("ofcall")
    e(mtlr(14), blr())

    # ---- data ---------------------------------------------------------------
    while a.pos % 32:
        e(nop())
    a.label("drain_rec")                          # an input record: see the drain above
    drain = [mfmsr(3), ori(4, 3, 0x8000), mtmsr(4), isync(), nop(), nop(), nop(), nop(),
             mtmsr(3), isync()]
    rec = [0] * (SREC // 4)
    rec[SI_MSR // 4], rec[SI_NCODE // 4] = MSR_SAFE, len(drain)
    rec[SI_CODE // 4:SI_CODE // 4 + len(drain)] = drain
    e(*rec)
    for name, text in [
        ("s_seek", "seek"), ("s_read", "read"), ("s_write", "write"), ("s_exit", "exit"),
        ("s_banner", CRLF + "stage2 v4d"), ("s_nl", CRLF), ("s_dot", "."),
        ("s_skip", " skipped: not a 604 or 750"), ("s_rom", " rom="), ("s_rompresent", " rom=present"),
        ("s_seq", " seq"), ("s_n", CRLF + "s2 n="), ("s_sum", " sum="), ("s_exc", " exc="),
        ("s_wok", " write=ok"), ("s_wfail", " write=FAILED"), ("s_eread", CRLF + "ERR read"),
    ]:
        a.asciz(name, text)

    blob = a.assemble()
    if len(blob) > CODE_MAX:
        raise ValueError("second stage is %d bytes, limit %d" % (len(blob), CODE_MAX))
    return blob


if __name__ == "__main__":
    print("second stage: %d bytes" % len(build()))
