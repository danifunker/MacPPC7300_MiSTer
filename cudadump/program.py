"""The on-target program that reads Cuda's firmware out through the VIA.

Two stages, both position-independent raw binaries assembled with ppctest's
ppcasm (imported, never changed):

- the **boot block** (`build_stage1`, at most 2048 bytes): started by Open
  Firmware's "partition zero" boot the way ppctest's harness.py is, whose
  start-up it copies instruction for instruction (bootxx's cache flush, BAT3
  over the low 256 MB, MSR 0x3030: translation on, external interrupts off).
  It finds the console and the boot disk through the client interface, reads
  the header block, loads the second stage 64 KB above itself and jumps to
  it. On a firmware that opened the boot partition rather than the whole
  disk (OpenBIOS), the header is found 4 blocks early and every block number
  is corrected by that offset.

- the **second stage** (`build_stage2`): finds the `via-cuda` node by walking
  the device tree (peer / child / parent / getprop), takes its `reg` offset
  and its parent's `assigned-addresses` base (F3000000 + 16000 on a 7600 or
  7300), maps that megabyte with DBAT2 (cache-inhibited, guarded; the 7300's
  firmware leaves BAT0-2 clear), then talks to Cuda exactly as the 7600's ROM
  and verilator/cuda_main.cpp's host do: sync, then each job's packet out
  (shift register set to output, TIP asserted, BYTEACK toggled per byte),
  the idle acknowledge and the attention byte in, the reply read with TIP
  asserted and BYTEACK toggled until Cuda negates TREQ or enough bytes are
  in, TIP negated and the idle acknowledge read. After every shift-register
  flag ten more VIA reads before touching SR or ACR (Cuda samples the last
  bit 3.8 us after the flag). Timeouts are counted in VIA reads. Anything
  Cuda offers before a job (TREQ asserted on its own) is read, logged and
  discarded. Every job's reply goes to its result block on the disk at once;
  the log and the header follow at the end. MSR[EE] is 0 throughout.

Register use in the second stage: r31 VIA base, r30 reply pointer, r29 reply
count, r28 current job entry, r27 the boot block's base (its RAM holds the
header and the block offset), r26 client interface, r25 stdout, r24 disk,
r23 log pointer, r22 packets discarded, r21 job index, r20 this stage's
base, r19 bytes received, r18 write-failed flag, r17 jobs failed, r13 jobs
ok; r14/r15/r16 hold return addresses for the three call levels (level 1:
wait_flag, wait_treq; 2: read_bytes; 3: cuda_init, drain, send_packet,
read_reply, and the client-interface helpers, which never nest with them).
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "ppctest"))

from ppcasm import *                      # noqa: E402
from layout import BOOT_MAX, PART_START   # noqa: E402  (ppctest's disk envelope)
from cudalayout import *                  # noqa: E402

CRLF = chr(13) + chr(10)
DBAT2U, DBAT2L = 540, 541

# the VIA's registers, offsets from its base (0x200 apart on Grand Central)
VIA_B, VIA_DIRB, VIA_SR, VIA_ACR, VIA_IFR = 0x0000, 0x0400, 0x1400, 0x1600, 0x1A00
TREQ, TACK, TIP = 0x08, 0x10, 0x20       # port B: PB3 in, PB4 out, PB5 out; low asserts
SR_INT = 0x04                            # IFR bit 2: the shift register's flag
ACR_SR_OUT = 0x10                        # ACR bit 4: shift out (with bits 3,2 = 11: external clock)

# the boot block's RAM, offsets from its load address (r27)
M_ARGS = 0x0800
M_STDOUT = 0x0840
M_OPNAME, M_IOBUF, M_IOLEN, M_MSR, M_BLKOFF = 0x0844, 0x0848, 0x084C, 0x0850, 0x0854
M_HEX = 0x0860
M_PATH = 0x0880              # 128 bytes
M_HDR = 0x0A00               # the header block
M_STACK = 0x7FF0
S2_LOAD = 0x10000            # the second stage goes here (r20)

# the second stage's RAM, offsets from its base (r20)
S_CODE_MAX = 0x2000
S_ARGS = 0x2000
S_OPNAME, S_IOBUF, S_IOLEN, S_LR4 = 0x2040, 0x2044, 0x2048, 0x204C
S_HEX = 0x2050
S_NAME = 0x2080              # a node's name (32 bytes)
S_PROP = 0x2100              # reg / assigned-addresses (256 bytes)
S_RES = 0x2200               # the result block being built (512 bytes)
S_JOBS = 0x2400              # the job table (512 bytes)
S_LOG = 0x2800               # the discard log (LOG_BLKS blocks)
S_LOG_END = S_LOG + LOG_BLKS * BLOCK
S_SIZE = S_LOG_END

MSR_RUN = 0x3030             # FP | ME | IR | DR; EE, FE0, FE1 off (harness.py)


# --- encoders ppcasm does not have ---------------------------------------------
def xori(ra, rs, ui):   return d_form(26, rs, ra, ui & 0xFFFF)
def lhz(rt, d, ra):     return d_form(40, rt, ra, d & 0xFFFF)
def eieio():            return x_form(31, 0, 0, 0, 854)


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


# --- shared helpers -----------------------------------------------------------
def _helpers(a, br, args, opname, iobuf, iolen, hexbuf):
    """ofcall, disk_read/disk_write, puts, puthex, fail/exit. br is the stage's
    base register; the offsets are its scratch words. Block numbers are
    corrected by the offset the boot block found (M_BLKOFF, always via r27)."""
    e = a.emit

    a.label("fail")
    a.bl("puts")
    a.label("exit")
    a.la(3, "s_nl"); a.bl("puts")
    a.la(3, "s_exit"); e(li(4, 0), li(5, 0)); a.bl("ofcall")
    a.label("hang")
    a.b("hang")

    # ofcall(r3 = service name, r4 = nargs, r5 = nrets, r6..r9 = args) -> r3.
    # Clobbers r0, r3-r10, r14, CTR.
    a.label("ofcall")
    e(mflr(16), addi(10, br, args))
    e(stw(3, 0, 10), stw(4, 4, 10), stw(5, 8, 10))
    e(stw(6, 12, 10), stw(7, 16, 10), stw(8, 20, 10), stw(9, 24, 10))
    e(slwi(4, 4, 2), add(14, 10, 4), li(0, -1), stw(0, 12, 14))
    e(mr(3, 10), mtctr(26), bctrl())
    e(lwz(3, 12, 14), mtlr(16), blr())

    # disk_read / disk_write(r3 = block, r4 = buffer, r5 = bytes) -> bytes done
    a.label("disk_read")
    a.la(7, "s_read")
    a.b("disk_io")
    a.label("disk_write")
    a.la(7, "s_write")
    a.label("disk_io")
    e(mflr(15), stw(7, opname, br), stw(4, iobuf, br), stw(5, iolen, br))
    e(lwz(0, M_BLKOFF, 27), subf(3, 0, 3))
    e(srwi(7, 3, 23), slwi(8, 3, 9), mr(6, 24))
    a.la(3, "s_seek"); e(li(4, 3), li(5, 1))
    a.bl("ofcall")
    e(lwz(3, opname, br), li(4, 3), li(5, 1), mr(6, 24))
    e(lwz(7, iobuf, br), lwz(8, iolen, br))
    a.bl("ofcall")
    e(mtlr(15), blr())

    # puts(r3 = NUL-terminated string)
    a.label("puts")
    e(mflr(15), mr(7, 3), li(8, 0))
    a.label("pl")
    e(lbzx(0, 7, 8), cmpwi(0, 0))
    a.beq("pw2")
    e(addi(8, 8, 1))
    a.b("pl")
    a.label("pw2")
    a.la(3, "s_write"); e(li(4, 3), li(5, 1), mr(6, 25))
    a.bl("ofcall")
    e(mtlr(15), blr())

    # puthex(r3): eight hex digits
    a.label("puthex")
    e(mflr(15), addi(7, br, hexbuf), mr(9, 7), li(8, 8), mtctr(8))
    a.label("ph1")
    e(rotlwi(3, 3, 4), andi_(10, 3, 15), cmpwi(10, 10))
    a.blt("ph2")
    e(addi(10, 10, 7))
    a.label("ph2")
    e(addi(10, 10, 48), stb(10, 0, 9), addi(9, 9, 1))
    a.bdnz("ph1")
    a.la(3, "s_write"); e(li(4, 3), li(5, 1), mr(6, 25), li(8, 8))
    a.bl("ofcall")
    e(mtlr(15), blr())


_OF_STRINGS = [
    ("s_seek", "seek"), ("s_read", "read"), ("s_write", "write"), ("s_exit", "exit"),
    ("s_nl", CRLF),
]


def _strings(a, strings):
    for name, text in strings:
        a.asciz(name, text)


def _finish(a, limit):
    blob = a.assemble()
    if len(blob) > limit:
        raise ValueError("program is %d bytes, limit %d" % (len(blob), limit))
    return blob


# --- stage 1: the boot block -----------------------------------------------------
def build_stage1():
    a = Asm(base_reg=27)
    e = a.emit

    # ---- entry: as harness.py (bootxx) -----------------------------------------
    a.bl("here")
    a.label("here")
    e(mflr(27), addi(27, 27, -4))
    e(mr(26, 5))
    # Open Firmware does not flush the instruction cache after loading us
    e(mr(8, 27), li(9, BOOT_MAX // 32), mtctr(9))
    a.label("flush")
    e(dcbf(0, 8), icbi(0, 8), addi(8, 8, 32))
    a.bdnz("flush")
    e(sync(), isync())

    e(mfmsr(13))
    e(mfspr(8, PVR), srwi(8, 8, 16), cmpwi(8, 1))
    a.beq("msr")                      # 601: different BAT format, leave OF's mapping
    e(li(0, 0), mtspr(DBAT3U, 0), mtspr(IBAT3U, 0), isync())
    # low 256 MB one-to-one, supervisor read/write, cache-inhibited
    e(li(8, 0x1FFE), li(9, 0x22))
    e(mtspr(DBAT3L, 9), mtspr(DBAT3U, 8), mtspr(IBAT3L, 9), mtspr(IBAT3U, 8), isync())
    a.label("msr")
    e(li(8, MSR_RUN), mtmsr(8), isync())

    e(addi(1, 27, M_STACK), li(0, 0), stw(0, 0, 1))
    e(stw(13, M_MSR, 27), stw(0, M_BLKOFF, 27))

    # ---- console and boot device ---------------------------------------------
    a.la(3, "s_finddevice"); e(li(4, 1), li(5, 1)); a.la(6, "s_chosen")
    a.bl("ofcall")
    e(mr(24, 3))
    a.la(3, "s_getprop"); e(li(4, 4), li(5, 1), mr(6, 24)); a.la(7, "s_stdout")
    e(addi(8, 27, M_STDOUT), li(9, 4))
    a.bl("ofcall")
    e(lwz(25, M_STDOUT, 27))
    a.la(3, "s_banner"); a.bl("puts")

    a.la(3, "s_getprop"); e(li(4, 4), li(5, 1), mr(6, 24)); a.la(7, "s_bootpath")
    e(addi(8, 27, M_PATH), li(9, 127))
    a.bl("ofcall")
    e(cmpwi(3, 1))
    a.ble("e_path")
    e(cmpwi(3, 127))
    a.ble("len_ok")
    e(li(3, 127))
    a.label("len_ok")
    e(addi(8, 27, M_PATH), add(9, 8, 3), li(0, 0), stb(0, 0, 9))
    # ".../sd@5:0" -> ".../sd@5": open the whole disk, as bootxx does
    a.label("scan")
    e(lbz(0, 0, 8), cmpwi(0, 0))
    a.beq("scan_done")
    e(cmpwi(0, ord(":")))
    a.beq("scan_cut")
    e(addi(8, 8, 1))
    a.b("scan")
    a.label("scan_cut")
    e(li(0, 0), stb(0, 0, 8))
    a.label("scan_done")
    e(addi(3, 27, M_PATH)); a.bl("puts")

    a.la(3, "s_open"); e(li(4, 1), li(5, 1), addi(6, 27, M_PATH))
    a.bl("ofcall")
    e(mr(24, 3), cmpwi(3, 0))
    a.beq("e_open")
    e(cmpwi(3, -1))
    a.beq("e_open")

    # ---- the header: ours, on the whole disk or on the partition ----------------
    a.label("hdr_try")
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_read")
    e(cmpwi(3, BLOCK))
    a.bne("e_read")
    e(lwz(8, M_HDR + H_MAGIC, 27)); a.li32(9, _word(MAGIC[:4].decode())); e(cmpw(8, 9))
    a.bne("hdr_shift")
    e(lwz(8, M_HDR + H_MAGIC + 4, 27)); a.li32(9, _word(MAGIC[4:].decode())); e(cmpw(8, 9))
    a.beq("hdr_ok")
    a.label("hdr_shift")
    # not at block 8: if the firmware opened the boot partition itself, the
    # disk's block 8 is the partition's block 4. One retry with that offset.
    e(lwz(0, M_BLKOFF, 27), cmpwi(0, 0))
    a.bne("e_magic")
    e(li(0, PART_START), stw(0, M_BLKOFF, 27))
    a.b("hdr_try")
    a.label("hdr_ok")

    # ---- load the second stage 64 KB above us and jump ---------------------------
    e(lwz(22, M_HDR + H_S2LEN, 27), cmpwi(22, 0))
    a.beq("e_magic")
    e(lwz(21, M_HDR + H_S2BLK, 27), addis(20, 27, 1))
    a.label("s2")
    e(mr(3, 21), mr(4, 20), li(5, 4096)); a.bl("disk_read")
    e(cmpwi(3, 4096))
    a.bne("e_read")
    e(addi(21, 21, 4096 // BLOCK), addi(20, 20, 4096), addi(22, 22, -4096), cmpwi(22, 0))
    a.bgt("s2")
    e(addis(20, 27, 1), mr(8, 20), li(9, S2_MAX_BLKS * BLOCK // 32), mtctr(9))
    a.label("flush2")
    e(dcbf(0, 8), icbi(0, 8), addi(8, 8, 32))
    a.bdnz("flush2")
    e(sync(), isync())
    e(mtctr(20), bctr())

    # ---- errors, helpers, data ------------------------------------------------------
    a.label("e_path"); a.la(3, "s_epath"); a.b("fail")
    a.label("e_open"); a.la(3, "s_eopen"); a.b("fail")
    a.label("e_read"); a.la(3, "s_eread"); a.b("fail")
    a.label("e_magic"); a.la(3, "s_emagic"); a.b("fail")
    _helpers(a, 27, M_ARGS, M_OPNAME, M_IOBUF, M_IOLEN, M_HEX)
    _strings(a, _OF_STRINGS + [
        ("s_finddevice", "finddevice"), ("s_getprop", "getprop"), ("s_open", "open"),
        ("s_chosen", "/chosen"), ("s_stdout", "stdout"), ("s_bootpath", "bootpath"),
        ("s_banner", CRLF + "cudadump v%d " % VERSION),
        ("s_epath", CRLF + "ERR no bootpath"), ("s_eopen", CRLF + "ERR open"),
        ("s_eread", CRLF + "ERR read"), ("s_emagic", CRLF + "ERR not a cudadump disk"),
    ])
    return _finish(a, BOOT_MAX)


# --- stage 2: the Cuda code ------------------------------------------------------------
def build_stage2():
    a = Asm(base_reg=20)
    e = a.emit

    def via_rmw(reg, op, value):
        """read-modify-write of a VIA register through r0, with eieio."""
        e(lbz(0, reg, 31), op(0, 0, value), stb(0, reg, 31), eieio())

    def ofcall(name, nargs, args):
        """args: a list of (register, source) where source is an int to li,
        or ('reg', n) to copy from register n, or ('la', label), or ('addr', off)."""
        for reg, src in args:
            if isinstance(src, int):
                e(li(reg, src))
            elif src[0] == "reg":
                e(mr(reg, src[1]))
            elif src[0] == "la":
                a.la(reg, src[1])
            elif src[0] == "addr":
                e(addi(reg, 20, src[1]))
        a.la(3, name); e(li(4, nargs), li(5, 1))
        a.bl("ofcall")

    a.bl("here")
    a.label("here")
    e(mflr(20), addi(20, 20, -4))

    # ---- 1. find the VIA: the via-cuda node, depth first --------------------------
    ofcall("s_peer", 1, [(6, 0)])
    e(mr(21, 3))
    a.label("walk")
    e(cmpwi(21, 0))
    a.beq("notfound")
    e(li(0, 0), stw(0, S_NAME, 20), stw(0, S_NAME + 4, 20), stw(0, S_NAME + 8, 20))
    ofcall("s_getprop", 4, [(6, ("reg", 21)), (7, ("la", "s_name")), (8, ("addr", S_NAME)), (9, 31)])
    e(lwz(8, S_NAME, 20)); a.li32(9, _word("via-")); e(cmpw(8, 9))
    a.bne("down")
    e(lwz(8, S_NAME + 4, 20)); a.li32(9, _word("cuda")); e(cmpw(8, 9))
    a.bne("down")
    e(lbz(8, S_NAME + 8, 20), cmpwi(8, 0))
    a.beq("found")
    a.label("down")
    ofcall("s_child", 1, [(6, ("reg", 21))])
    e(cmpwi(3, 0))
    a.beq("up")
    e(mr(21, 3))
    a.b("walk")
    a.label("up")
    ofcall("s_peer", 1, [(6, ("reg", 21))])
    e(cmpwi(3, 0))
    a.bne("sideways")
    ofcall("s_parent", 1, [(6, ("reg", 21))])
    e(mr(21, 3), cmpwi(3, 0))
    a.beq("notfound")
    a.b("up")
    a.label("sideways")
    e(mr(21, 3))
    a.b("walk")

    a.label("found")
    # its reg: the offset within the parent; the parent's assigned-addresses:
    # the base (third cell of the first entry, a PCI address)
    ofcall("s_getprop", 4, [(6, ("reg", 21)), (7, ("la", "s_reg")), (8, ("addr", S_PROP)), (9, 256)])
    e(cmpwi(3, 4))
    a.blt("try_aapl")
    e(lwz(31, S_PROP, 20))
    ofcall("s_parent", 1, [(6, ("reg", 21))])
    e(cmpwi(3, 0))
    a.beq("try_aapl")
    ofcall("s_getprop", 4, [(6, ("reg", 3)), (7, ("la", "s_aa")), (8, ("addr", S_PROP)), (9, 256)])
    e(cmpwi(3, 12))
    a.blt("try_aapl")
    e(lwz(8, S_PROP + 8, 20), add(31, 31, 8), li(22, HOW_TREE))
    a.b("have_via")
    a.label("try_aapl")
    # a firmware that publishes where it mapped the registers (New World style)
    ofcall("s_getprop", 4, [(6, ("reg", 21)), (7, ("la", "s_aapl")), (8, ("addr", S_PROP)), (9, 256)])
    e(cmpwi(3, 4))
    a.blt("notfound")
    e(lwz(31, S_PROP, 20), li(22, HOW_AAPL))
    a.b("have_via")
    a.label("notfound")
    a.li32(31, DEFAULT_VIA); e(li(22, HOW_DEFAULT))
    a.label("have_via")
    e(stw(31, M_HDR + H_VIA, 27), stw(22, M_HDR + H_HOW, 27))
    a.la(3, "s_via"); a.bl("puts"); e(mr(3, 31)); a.bl("puthex")
    # one letter for how: t (tree), a (AAPL,address), d (the default)
    a.la(8, "s_how"); e(add(8, 8, 22), lbz(0, -1, 8), stb(0, S_HEX, 20), li(0, 0), stb(0, S_HEX + 1, 20))
    e(addi(3, 20, S_HEX)); a.bl("puts")

    # ---- 2. map its megabyte with DBAT2: cache-inhibited, guarded (not on a 601) ----
    e(mfspr(8, PVR), srwi(8, 8, 16), cmpwi(8, 1))
    a.beq("nobat")
    e(mfspr(8, DBAT2U), mfspr(9, DBAT2L))
    e(stw(8, M_HDR + H_DBAT2U, 27), stw(9, M_HDR + H_DBAT2L, 27))
    e(rlwinm(8, 31, 0, 0, 11))                    # the megabyte
    e(ori(9, 8, 0x2A), ori(8, 8, 0x1E))           # WIMG 0101, RW; BL 1 MB, Vs
    e(li(0, 0), mtspr(DBAT2U, 0), isync(), mtspr(DBAT2L, 9), mtspr(DBAT2U, 8), isync())
    a.label("nobat")

    # ---- 3. the header says we started -----------------------------------------------
    a.li32(0, STARTED)
    e(stw(0, M_HDR + H_DONE, 27), mfspr(8, PVR), stw(8, M_HDR + H_PVR, 27))
    e(lwz(0, M_MSR, 27), stw(0, M_HDR + H_MSR, 27))
    e(lwz(0, M_BLKOFF, 27), stw(0, M_HDR + H_BLKOFF, 27))
    e(addi(8, 27, M_PATH), addi(10, 27, M_HDR + H_PATH), li(9, 0))
    a.label("cp")
    e(lwzx(0, 8, 9), stwx(0, 10, 9), addi(9, 9, 4), cmpwi(9, H_PATH_LEN))
    a.blt("cp")
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")

    # ---- 4. the job table ----------------------------------------------------------------
    e(lwz(3, M_HDR + H_JOBBLK, 27), addi(4, 20, S_JOBS), li(5, BLOCK)); a.bl("disk_read")
    e(cmpwi(3, BLOCK))
    a.bne("e_read")
    e(li(13, 0), li(17, 0), li(18, 0), li(19, 0), li(22, 0), addi(23, 20, S_LOG))

    # ---- 5. sync with Cuda ----------------------------------------------------------------
    a.bl("cuda_init")
    e(stw(3, M_HDR + H_SYNC, 27), cmpwi(3, 0))
    a.la(3, "s_sync_ok")
    a.beq("ps")
    a.la(3, "s_sync_bad")
    a.label("ps")
    a.bl("puts")
    a.la(3, "s_nl"); a.bl("puts")

    # ---- 6. the jobs -----------------------------------------------------------------------
    e(li(21, 0))
    a.label("job")
    e(lwz(0, M_HDR + H_NJOB, 27), cmpw(21, 0))
    a.bge("jobs_done")
    e(slwi(28, 21, 4), addi(28, 28, S_JOBS), add(28, 28, 20))
    e(addi(8, 20, S_RES), li(9, BLOCK // 4), mtctr(9), li(0, 0))
    a.label("clr")
    e(stw(0, 0, 8), addi(8, 8, 4))
    a.bdnz("clr")
    a.bl("do_job")
    e(lwz(3, M_HDR + H_RESBLK, 27), add(3, 3, 21), addi(4, 20, S_RES), li(5, BLOCK))
    a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("w_ok")
    e(li(18, 1))
    a.label("w_ok")
    e(lwz(0, S_RES + R_STATUS, 20), cmpwi(0, 0))
    a.la(3, "s_t")
    a.bne("pc")
    e(lbz(0, S_RES + R_DATA, 20), cmpwi(0, 2))     # Cuda's error packet
    a.la(3, "s_e")
    a.beq("pc")
    a.la(3, "s_dot")
    a.label("pc")
    a.bl("puts")
    e(addi(21, 21, 1))
    a.b("job")

    # ---- 7. the log, the header, a read to push Open Firmware's write buffer out ------
    a.label("jobs_done")
    e(lwz(3, M_HDR + H_LOGBLK, 27), addi(4, 20, S_LOG), li(5, LOG_BLKS * BLOCK)); a.bl("disk_write")
    e(cmpwi(3, LOG_BLKS * BLOCK))
    a.beq("l_ok")
    e(li(18, 1))
    a.label("l_ok")
    a.li32(0, DONE)
    e(stw(0, M_HDR + H_DONE, 27), stw(13, M_HDR + H_NOK, 27), stw(17, M_HDR + H_NFAIL, 27))
    e(stw(22, M_HDR + H_NDISC, 27), stw(19, M_HDR + H_NBYTES, 27), stw(18, M_HDR + H_WRFAIL, 27))
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("h_ok")
    e(li(18, 1))
    a.label("h_ok")
    # Open Firmware 1.0.5 keeps the last write in its block buffer until the
    # next disk operation (harness.py saw it on the 7600): read block 0 as it
    # does, then read the header back and say whether it has the completion
    e(lwz(3, M_BLKOFF, 27), addi(4, 20, S_RES), li(5, BLOCK)); a.bl("disk_read")
    e(li(3, HDR_BLK), addi(4, 20, S_JOBS), li(5, BLOCK)); a.bl("disk_read")
    e(lwz(8, S_JOBS + H_DONE, 20)); a.li32(9, DONE); e(cmpw(8, 9))
    a.la(3, "s_hdr_ok")
    a.beq("ph")
    a.la(3, "s_hdr_stale")
    a.label("ph")
    a.bl("puts")

    # ---- 8. DBAT2 back as it was, the summary, exit --------------------------------------
    e(mfspr(8, PVR), srwi(8, 8, 16), cmpwi(8, 1))
    a.beq("nobat2")
    e(lwz(8, M_HDR + H_DBAT2U, 27), lwz(9, M_HDR + H_DBAT2L, 27))
    e(li(0, 0), mtspr(DBAT2U, 0), isync(), mtspr(DBAT2L, 9), mtspr(DBAT2U, 8), isync())
    a.label("nobat2")
    a.la(3, "s_jobs"); a.bl("puts"); e(mr(3, 21)); a.bl("puthex")
    a.la(3, "s_ok"); a.bl("puts"); e(mr(3, 13)); a.bl("puthex")
    a.la(3, "s_fail"); a.bl("puts"); e(mr(3, 17)); a.bl("puthex")
    a.la(3, "s_disc"); a.bl("puts"); e(mr(3, 22)); a.bl("puthex")
    a.la(3, "s_bytes"); a.bl("puts"); e(mr(3, 19)); a.bl("puthex")
    e(cmpwi(18, 0))
    a.la(3, "s_wok")
    a.beq("pw")
    a.la(3, "s_wfail")
    a.label("pw")
    a.bl("puts")
    a.b("exit")

    a.label("e_read"); a.la(3, "s_eread"); a.b("fail")

    # ---- one job (r28 = its entry): send, read, record ---------------------------------
    a.label("do_job")
    e(mflr(0), stw(0, S_LR4, 20))
    e(stw(22, S_RES + R_DISC, 20), li(29, 0), li(12, RETRIES))
    a.label("retry")
    a.bl("drain")                                 # whatever Cuda has to say first
    a.bl("send_packet")
    e(cmpwi(3, 0))
    a.beq("sent")
    e(cmpwi(3, 2))
    a.bne("send_bad")
    e(addi(12, 12, -1), cmpwi(12, 0))             # a collision: let Cuda talk, then again
    a.bne("retry")
    e(li(3, ST_COLLISIONS))
    a.b("job_fail")
    a.label("send_bad")
    e(li(3, ST_SEND_TIMEOUT))
    a.b("job_fail")
    a.label("sent")
    a.bl("read_reply")
    e(cmpwi(3, 0))
    a.bne("job_fail")
    e(addi(13, 13, 1))
    a.b("job_end")
    a.label("job_fail")
    e(addi(17, 17, 1))
    a.label("job_end")
    e(stw(3, S_RES + R_STATUS, 20), stw(29, S_RES + R_LEN, 20), add(19, 19, 29))
    e(lwz(0, S_LR4, 20), mtlr(0), blr())

    # ---- cuda_init: the VIA's lines and the sync, as cuda_main.cpp's host -----------------
    # -> r3 = 0, or 1-4 for the step that timed out
    a.label("cuda_init")
    e(mflr(16))
    e(lbz(0, VIA_DIRB, 31), ori(0, 0, TIP | TACK), andi_(0, 0, 0xFF & ~TREQ), stb(0, VIA_DIRB, 31), eieio())
    via_rmw(VIA_B, ori, TIP | TACK)
    e(lbz(0, VIA_ACR, 31), andi_(0, 0, 0xFF & ~0x1C), ori(0, 0, 0x0C), stb(0, VIA_ACR, 31), eieio())
    e(lbz(0, VIA_SR, 31))
    e(li(0, 0xD05), mtctr(0))                     # about 4 ms of VIA reads, as the ROM
    a.label("ci_delay")
    e(lbz(0, VIA_B, 31))
    a.bdnz("ci_delay")
    e(lbz(0, VIA_SR, 31), li(0, SR_INT), stb(0, VIA_IFR, 31), eieio())
    via_rmw(VIA_B, andi_, 0xFF & ~TACK)           # sync: TACK asserted without TIP
    e(li(4, 0)); a.bl("wait_treq")                # Cuda asserts TREQ
    e(li(11, 1), cmpwi(3, 0))
    a.bne("ci_fail")
    a.bl("wait_flag")
    e(li(11, 2), cmpwi(3, 0))
    a.bne("ci_fail")
    e(lbz(0, VIA_SR, 31))
    via_rmw(VIA_B, ori, TACK)
    e(li(4, TREQ)); a.bl("wait_treq")             # Cuda negates TREQ
    e(li(11, 3), cmpwi(3, 0))
    a.bne("ci_fail")
    a.bl("wait_flag")
    e(li(11, 4), cmpwi(3, 0))
    a.bne("ci_fail")
    e(lbz(0, VIA_SR, 31))
    via_rmw(VIA_B, ori, TIP)
    e(li(3, 0))
    a.b("ci_ret")
    a.label("ci_fail")
    via_rmw(VIA_B, ori, TIP | TACK)
    e(mr(3, 11))
    a.label("ci_ret")
    e(mtlr(16), blr())

    # ---- drain: read and log every packet Cuda offers (TREQ asserted) -----------------------
    a.label("drain")
    e(mflr(16), li(11, 8))
    a.label("dr_loop")
    e(lbz(0, VIA_B, 31), andi_(0, 0, TREQ))
    a.bne("dr_ret")                               # TREQ negated: nothing pending
    a.bl("wait_flag")                             # the attention byte
    e(cmpwi(3, 0))
    a.bne("dr_timeout")
    e(lbz(0, VIA_SR, 31))
    via_rmw(VIA_B, andi_, 0xFF & ~TIP)            # TIP: send it
    e(addi(30, 23, 1), li(29, 0), li(7, LOG_DATA_MAX), li(8, 64))
    a.bl("read_bytes")
    e(cmpwi(29, 0x7F))
    a.ble("dr_len")
    e(li(29, 0x7F))
    a.label("dr_len")
    e(cmpwi(3, 0))
    a.beq("dr_store")
    e(ori(29, 29, 0x80))
    a.label("dr_store")
    e(stb(29, 0, 23))
    e(addi(0, 20, S_LOG_END - LOG_ENTRY), cmplw(23, 0))
    a.bge("dr_full")
    e(addi(23, 23, LOG_ENTRY))
    a.label("dr_full")
    e(addi(22, 22, 1), addi(11, 11, -1), cmpwi(11, 0))
    a.bne("dr_loop")
    a.b("dr_ret")
    a.label("dr_timeout")
    e(lwz(0, S_RES + R_WAITS, 20), addi(0, 0, 1), stw(0, S_RES + R_WAITS, 20))
    via_rmw(VIA_B, ori, TIP | TACK)
    a.label("dr_ret")
    e(mtlr(16), blr())

    # ---- send_packet (r28 = the job): -> r3 = 0 sent, 1 timeout, 2 collision ---------------
    a.label("send_packet")
    e(mflr(16), lbz(9, J_LEN, 28), addi(10, 28, J_PKT))
    via_rmw(VIA_ACR, ori, ACR_SR_OUT)             # shift out
    e(lbz(4, 0, 10), stb(4, VIA_SR, 31), eieio())
    via_rmw(VIA_B, andi_, 0xFF & ~TIP)            # TIP: the first byte goes
    a.bl("wait_flag")
    e(cmpwi(3, 0))
    a.bne("sp_timeout")
    e(lbz(0, VIA_SR, 31))
    e(lbz(0, VIA_B, 31), andi_(0, 0, TREQ))
    a.beq("sp_collision")                         # Cuda wanted to talk: not ours
    a.label("sp_next")
    e(addi(10, 10, 1), addi(9, 9, -1), cmpwi(9, 0))
    a.beq("sp_done")
    e(lbz(4, 0, 10), stb(4, VIA_SR, 31), eieio())
    via_rmw(VIA_B, xori, TACK)
    a.bl("wait_flag")
    e(cmpwi(3, 0))
    a.bne("sp_timeout")
    e(lbz(0, VIA_SR, 31))
    a.b("sp_next")
    a.label("sp_done")
    e(li(3, 0))
    a.b("sp_finish")
    a.label("sp_collision")
    e(li(3, 2))
    a.b("sp_finish")
    a.label("sp_timeout")
    e(li(3, 1))
    a.label("sp_finish")
    via_rmw(VIA_ACR, andi_, 0xFF & ~ACR_SR_OUT)   # shift in again
    e(lbz(0, VIA_SR, 31))
    via_rmw(VIA_B, ori, TIP | TACK)
    e(mtlr(16), blr())

    # ---- read_reply (r28 = the job): the idle acknowledge, the attention byte, the bytes ---
    # -> r3 = 0, ST_NO_REPLY, ST_READ_TIMEOUT or ST_ACK_TIMEOUT; r29 bytes in S_RES
    a.label("read_reply")
    e(mflr(16), li(11, 8))
    a.label("rr_wait")
    a.bl("wait_flag")
    e(cmpwi(3, 0))
    a.bne("rr_none")
    e(lbz(0, VIA_SR, 31))
    e(lbz(0, VIA_B, 31), andi_(0, 0, TREQ))
    a.beq("rr_treq")                              # TREQ asserted: the reply follows
    e(addi(11, 11, -1), cmpwi(11, 0))             # else the idle acknowledge: wait on
    a.bne("rr_wait")
    a.label("rr_none")
    e(li(3, ST_NO_REPLY))
    a.b("rr_ret")
    a.label("rr_treq")
    via_rmw(VIA_B, andi_, 0xFF & ~TIP)
    e(addi(30, 20, S_RES + R_DATA), li(29, 0), li(7, R_DATA_MAX), lhz(8, J_MAX, 28))
    a.bl("read_bytes")
    a.label("rr_ret")
    e(mtlr(16), blr())

    # ---- read_bytes: TIP is asserted; r30 buffer, r7 its room, r8 bytes to take -------------
    # -> r3 = 0, ST_READ_TIMEOUT or ST_ACK_TIMEOUT; r29 = bytes received
    a.label("read_bytes")
    e(mflr(15))
    a.label("rb_loop")
    a.bl("wait_flag")
    e(cmpwi(3, 0))
    a.bne("rb_timeout")
    e(lbz(4, VIA_SR, 31), cmplw(29, 7))
    a.bge("rb_full")
    e(stbx(4, 30, 29))
    a.label("rb_full")
    e(addi(29, 29, 1))
    e(lbz(0, VIA_B, 31), andi_(0, 0, TREQ))
    a.bne("rb_last")                              # TREQ negated: that was the last byte
    e(cmplw(29, 8))
    a.bge("rb_last")                              # enough of an open-ended reply
    via_rmw(VIA_B, xori, TACK)
    a.b("rb_loop")
    a.label("rb_last")
    via_rmw(VIA_B, ori, TIP | TACK)
    a.bl("wait_flag")                             # the idle acknowledge
    e(cmpwi(3, 0))
    a.bne("rb_noack")
    e(lbz(0, VIA_SR, 31), li(3, 0))
    a.b("rb_ret")
    a.label("rb_noack")
    e(li(3, ST_ACK_TIMEOUT))
    a.b("rb_ret")
    a.label("rb_timeout")
    via_rmw(VIA_B, ori, TIP | TACK)
    e(li(3, ST_READ_TIMEOUT))
    a.label("rb_ret")
    e(mtlr(15), blr())

    # ---- wait_flag: the shift register's flag, then ten more VIA reads -> r3 = 0, 1 timeout --
    a.label("wait_flag")
    e(mflr(14))
    a.li32(0, TIMEOUT_READS); e(mtctr(0))
    a.label("wf_loop")
    e(lbz(3, VIA_IFR, 31), andi_(3, 3, SR_INT))
    a.bne("wf_got")
    a.bdnz("wf_loop")
    e(li(3, 1))
    a.b("wf_ret")
    a.label("wf_got")
    e(li(0, 10), mtctr(0))
    a.label("wf_ten")
    e(lbz(0, VIA_B, 31))
    a.bdnz("wf_ten")
    e(li(3, 0))
    a.label("wf_ret")
    e(mtlr(14), blr())

    # ---- wait_treq: r4 = 0 for asserted, TREQ for negated -> r3 = 0, 1 timeout --------------
    a.label("wait_treq")
    e(mflr(14))
    a.li32(0, TIMEOUT_READS); e(mtctr(0))
    a.label("wt_loop")
    e(lbz(3, VIA_B, 31), andi_(3, 3, TREQ), cmpw(3, 4))
    a.beq("wt_ok")
    a.bdnz("wt_loop")
    e(li(3, 1))
    a.b("wt_ret")
    a.label("wt_ok")
    e(li(3, 0))
    a.label("wt_ret")
    e(mtlr(14), blr())

    _helpers(a, 20, S_ARGS, S_OPNAME, S_IOBUF, S_IOLEN, S_HEX)
    _strings(a, _OF_STRINGS + [
        ("s_getprop", "getprop"), ("s_peer", "peer"), ("s_child", "child"), ("s_parent", "parent"),
        ("s_name", "name"), ("s_reg", "reg"), ("s_aa", "assigned-addresses"), ("s_aapl", "AAPL,address"),
        ("s_via", " via="), ("s_how", "tad"),
        ("s_sync_ok", " sync=ok"), ("s_sync_bad", " sync=FAILED"),
        ("s_dot", "."), ("s_t", "T"), ("s_e", "E"),
        ("s_jobs", CRLF + "jobs="), ("s_ok", " ok="), ("s_fail", " fail="), ("s_disc", " disc="),
        ("s_bytes", " bytes="), ("s_wok", " write=ok"), ("s_wfail", " write=FAILED"),
        ("s_hdr_ok", " hdr=ok"), ("s_hdr_stale", " hdr=STALE"),
        ("s_eread", CRLF + "ERR read"),
    ])
    return _finish(a, S_CODE_MAX)


if __name__ == "__main__":
    s1, s2 = build_stage1(), build_stage2()
    print("boot block %d bytes (limit %d), second stage %d bytes (limit %d)"
          % (len(s1), BOOT_MAX, len(s2), S_CODE_MAX))
