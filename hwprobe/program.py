"""The on-target program of the hardware probe disk.

Two stages, both position-independent raw binaries assembled with ppctest's
ppcasm (imported, never changed), built as cudadump's are:

- the **boot block** (`build_stage1`, at most 2048 bytes): cudadump's, with
  this disk's header: started by Open Firmware's "partition zero" boot, it
  copies harness.py's start-up (the cache flush, BAT3 over the low 256 MB,
  MSR 0x3030: translation on, external interrupts off), finds the console
  and the boot disk through the client interface, reads the header block,
  loads the second stage 64 KB above itself and jumps to it.

- the **second stage** (`build_stage2`): finds Grand Central as cudadump
  finds the VIA (the `via-cuda` node's parent's `assigned-addresses`),
  maps its megabyte with DBAT2 (cache-inhibited, guarded), reads the
  operation table and runs it (hwlayout's OP_*: register reads and writes,
  polls and loops timed with the time base), prints every result on the
  console in hex, eight to a line, then writes them and the header to the
  disk, puts DBAT2 back and exits to Open Firmware. MSR[EE] is 0 throughout.

Register use in the second stage: r31 Grand Central's base, r30 the next
operation, r29 the next result's address, r28 the time base at TB0, r27 the
boot block's base (its RAM holds the header and the block offset), r26 the
client interface, r25 stdout, r24 the disk, r23 the results' base, r22 how
Grand Central was found, r21 the device-tree walk's node, r20 this stage's
base, r19 the result being printed, r18 the write-failed flag, r17 ofcall's
argument block; r14 and r15 hold return addresses (ofcall; disk_io, puts,
puthex).
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "ppctest"))

from ppcasm import *                      # noqa: E402
from layout import BOOT_MAX, PART_START   # noqa: E402  (ppctest's disk envelope)
from hwlayout import *                    # noqa: E402

CRLF = chr(13) + chr(10)
DBAT2U, DBAT2L = 540, 541
TBL = 268

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
S_OPNAME, S_IOBUF, S_IOLEN = 0x2040, 0x2044, 0x2048
S_HEX = 0x2050
S_NAME = 0x2080              # a node's name (32 bytes)
S_PROP = 0x2100              # assigned-addresses (256 bytes)
S_OPS = 0x2400               # the operation table
S_RES = S_OPS + OPS_BLKS * BLOCK
S_SCRATCH = S_RES + RES_BLKS * BLOCK

MSR_RUN = 0x3030             # FP | ME | IR | DR; EE, FE0, FE1 off (harness.py)


# --- encoders ppcasm does not have ---------------------------------------------
def lhz(rt, d, ra):     return d_form(40, rt, ra, d & 0xFFFF)
def eieio():            return x_form(31, 0, 0, 0, 854)
def and_dot(ra, rs, rb): return x_form(31, rs, ra, rb, 28, 1)
def and_(ra, rs, rb):   return x_form(31, rs, ra, rb, 28)
def mftb(rt):           return (31 << 26) | (rt << 21) | ((TBL & 0x1F) << 16) | ((TBL >> 5) << 11) | (371 << 1)


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


# --- shared helpers (cudadump's) ----------------------------------------------------
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
    # Clobbers r0, r3-r12, r14, r17, CTR (r14 and r17 survive the client
    # interface, which keeps r13-r31).
    a.label("ofcall")
    e(mflr(14), addi(10, br, args))
    e(stw(3, 0, 10), stw(4, 4, 10), stw(5, 8, 10))
    e(stw(6, 12, 10), stw(7, 16, 10), stw(8, 20, 10), stw(9, 24, 10))
    e(slwi(4, 4, 2), add(17, 10, 4), li(0, -1), stw(0, 12, 17))
    e(mr(3, 10), mtctr(26), bctrl())
    e(lwz(3, 12, 17), mtlr(14), blr())

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


# --- stage 1: the boot block (cudadump's, this disk's header) -------------------------
def build_stage1():
    a = Asm(base_reg=27)
    e = a.emit

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
        ("s_banner", CRLF + "hwprobe v%d " % VERSION),
        ("s_epath", CRLF + "ERR no bootpath"), ("s_eopen", CRLF + "ERR open"),
        ("s_eread", CRLF + "ERR read"), ("s_emagic", CRLF + "ERR not a hwprobe disk"),
    ])
    return _finish(a, BOOT_MAX)


# --- stage 2: the interpreter ---------------------------------------------------------
def build_stage2():
    a = Asm(base_reg=20)
    e = a.emit

    def ofcall(name, nargs, args):
        """args: (register, source): an int to li, ('reg', n), ('la', label) or
        ('addr', offset from r20)."""
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

    # ---- 1. Grand Central: the via-cuda node's parent, depth first --------------------
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
    # the parent's assigned-addresses: the base (third cell of the first entry)
    ofcall("s_parent", 1, [(6, ("reg", 21))])
    e(cmpwi(3, 0))
    a.beq("try_aapl")
    ofcall("s_getprop", 4, [(6, ("reg", 3)), (7, ("la", "s_aa")), (8, ("addr", S_PROP)), (9, 256)])
    e(cmpwi(3, 12))
    a.blt("try_aapl")
    e(lwz(31, S_PROP + 8, 20), li(22, HOW_TREE))
    a.b("have_gc")
    a.label("try_aapl")
    # a firmware that publishes where it mapped the VIA (New World style):
    # Grand Central's base is that address less the VIA's offset
    ofcall("s_getprop", 4, [(6, ("reg", 21)), (7, ("la", "s_aapl")), (8, ("addr", S_PROP)), (9, 256)])
    e(cmpwi(3, 4))
    a.blt("notfound")
    e(lwz(31, S_PROP, 20), addis(31, 31, -1), addi(31, 31, -0x6000), li(22, HOW_AAPL))
    a.b("have_gc")
    a.label("notfound")
    a.li32(31, DEFAULT_GC); e(li(22, HOW_DEFAULT))
    a.label("have_gc")
    e(stw(31, M_HDR + H_GC, 27), stw(22, M_HDR + H_HOW, 27))
    a.la(3, "s_gc"); a.bl("puts"); e(mr(3, 31)); a.bl("puthex")
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

    # ---- 3. the header says we started; the operation table -----------------------------
    a.li32(0, STARTED)
    e(stw(0, M_HDR + H_DONE, 27), mfspr(8, PVR), stw(8, M_HDR + H_PVR, 27))
    e(lwz(0, M_MSR, 27), stw(0, M_HDR + H_MSR, 27))
    e(lwz(0, M_BLKOFF, 27), stw(0, M_HDR + H_BLKOFF, 27))
    e(addi(8, 27, M_PATH), addi(10, 27, M_HDR + H_PATH), li(9, 0))
    a.label("cp")
    e(lwzx(0, 8, 9), stwx(0, 10, 9), addi(9, 9, 4), cmpwi(9, H_PATH_LEN))
    a.blt("cp")
    e(li(18, 0))
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")
    e(lwz(3, M_HDR + H_OPSBLK, 27), addi(4, 20, S_OPS), li(5, OPS_BLKS * BLOCK)); a.bl("disk_read")
    e(cmpwi(3, OPS_BLKS * BLOCK))
    a.bne("e_read")
    # the results start zeroed
    e(addi(23, 20, S_RES), mr(8, 23), li(9, RES_MAX), mtctr(9), li(0, 0))
    a.label("clr")
    e(stw(0, 0, 8), addi(8, 8, 4))
    a.bdnz("clr")
    a.la(3, "s_run"); a.bl("puts")

    # ---- 4. the operations --------------------------------------------------------------
    e(addi(30, 20, S_OPS), mr(29, 23), mftb(28))
    a.label("op")
    e(lbz(3, O_OP, 30), lwz(4, O_OFF, 30), lwz(5, O_VAL, 30), lwz(6, O_ARG, 30))
    e(add(7, 31, 4), addi(30, 30, 16))
    for code, label in ((OP_END, "ops_done"), (OP_W8, "o_w8"), (OP_R8, "o_r8"), (OP_W32, "o_w32"),
                        (OP_R32, "o_r32"), (OP_TB0, "o_tb0"), (OP_TBD, "o_tbd"), (OP_POLL8, "o_poll8"),
                        (OP_REP8, "o_rep8"), (OP_REP32, "o_rep32"), (OP_WAIT, "o_wait"),
                        (OP_SKIPEQ, "o_skipeq"), (OP_W8R, "o_w8r")):
        e(cmpwi(3, code))
        a.beq(label)
    a.b("ops_done")                               # an unknown operation ends the run

    a.label("o_w8")
    e(stb(5, 0, 7), eieio())
    a.b("op")
    a.label("o_w32")
    e(stw(5, 0, 7), eieio())
    a.b("op")
    a.label("o_r8")
    e(lbz(8, 0, 7))
    a.b("store")
    a.label("o_r32")
    e(lwz(8, 0, 7))
    a.b("store")
    a.label("o_tb0")
    e(mftb(28))
    a.b("op")
    a.label("o_tbd")
    e(mftb(8), subf(8, 28, 8))
    a.b("store")
    a.label("o_poll8")
    e(mftb(9))
    a.label("po_loop")
    e(lbz(8, 0, 7), and_dot(10, 8, 5))
    a.bne("store")
    e(mftb(10), subf(10, 9, 10), cmplw(10, 6))
    a.blt("po_loop")
    e(ori(8, 8, 0x100))
    a.b("store")
    a.label("o_rep8")
    e(mtctr(6), mftb(9))
    a.label("r8_loop")
    e(lbz(8, 0, 7))
    a.bdnz("r8_loop")
    e(mftb(8), subf(8, 9, 8))
    a.b("store")
    a.label("o_rep32")
    e(mtctr(6), mftb(9))
    a.label("r32_loop")
    e(lwz(8, 0, 7))
    a.bdnz("r32_loop")
    e(mftb(8), subf(8, 9, 8))
    a.b("store")
    a.label("o_wait")
    e(mftb(9))
    a.label("w_loop")
    e(mftb(10), subf(10, 9, 10), cmplw(10, 6))
    a.blt("w_loop")
    a.b("op")
    a.label("o_skipeq")
    e(lwz(8, -4, 29), and_(8, 8, 5), cmpw(8, 6))
    a.bne("op")
    e(slwi(4, 4, 4), add(30, 30, 4))
    a.b("op")
    a.label("o_w8r")
    e(slwi(5, 5, 2), lwzx(8, 23, 5))
    # the address is Grand Central's base plus off, as for the others
    e(stb(8, 0, 7), eieio())
    a.b("op")
    a.label("store")
    e(stw(8, 0, 29), addi(29, 29, 4))
    e(addi(0, 23, RES_MAX * 4), cmplw(29, 0))
    a.blt("op")
    a.label("ops_done")

    # ---- 5. DBAT2 back as it was ---------------------------------------------------------
    e(mfspr(8, PVR), srwi(8, 8, 16), cmpwi(8, 1))
    a.beq("nobat2")
    e(lwz(8, M_HDR + H_DBAT2U, 27), lwz(9, M_HDR + H_DBAT2L, 27))
    e(li(0, 0), mtspr(DBAT2U, 0), isync(), mtspr(DBAT2L, 9), mtspr(DBAT2U, 8), isync())
    a.label("nobat2")

    # ---- 6. the results on the console, eight to a line ------------------------------------
    e(subf(21, 23, 29), srwi(21, 21, 2), stw(21, M_HDR + H_NRES, 27))
    a.la(3, "s_nres"); a.bl("puts"); e(mr(3, 21)); a.bl("puthex")
    e(li(19, 0))
    a.label("pr")
    e(cmpw(19, 21))
    a.bge("pr_done")
    e(andi_(0, 19, 7))
    a.bne("pr_sp")
    a.la(3, "s_nl"); a.bl("puts")
    e(mr(3, 19)); a.bl("puthex")
    a.la(3, "s_colon"); a.bl("puts")
    a.label("pr_sp")
    a.la(3, "s_sp"); a.bl("puts")
    e(slwi(8, 19, 2), lwzx(3, 23, 8)); a.bl("puthex")
    e(addi(19, 19, 1))
    a.b("pr")
    a.label("pr_done")

    # ---- 7. the results and the header on the disk; read back as cudadump does -------------
    e(lwz(3, M_HDR + H_RESBLK, 27), mr(4, 23), li(5, RES_BLKS * BLOCK)); a.bl("disk_write")
    e(cmpwi(3, RES_BLKS * BLOCK))
    a.beq("r_ok")
    e(li(18, 1))
    a.label("r_ok")
    a.li32(0, DONE)
    e(stw(0, M_HDR + H_DONE, 27), stw(18, M_HDR + H_WRFAIL, 27))
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("h_ok")
    e(li(18, 1))
    a.label("h_ok")
    # Open Firmware 1.0.5 keeps the last write in its block buffer until the
    # next disk operation: read block 0, then the header back
    e(lwz(3, M_BLKOFF, 27), addi(4, 20, S_SCRATCH), li(5, BLOCK)); a.bl("disk_read")
    e(li(3, HDR_BLK), addi(4, 20, S_SCRATCH), li(5, BLOCK)); a.bl("disk_read")
    e(lwz(8, S_SCRATCH + H_DONE, 20)); a.li32(9, DONE); e(cmpw(8, 9))
    a.la(3, "s_hdr_ok")
    a.beq("ph")
    a.la(3, "s_hdr_stale")
    a.label("ph")
    a.bl("puts")
    e(cmpwi(18, 0))
    a.la(3, "s_wok")
    a.beq("pw")
    a.la(3, "s_wfail")
    a.label("pw")
    a.bl("puts")
    a.b("exit")

    a.label("e_read"); a.la(3, "s_eread"); a.b("fail")

    _helpers(a, 20, S_ARGS, S_OPNAME, S_IOBUF, S_IOLEN, S_HEX)
    _strings(a, _OF_STRINGS + [
        ("s_getprop", "getprop"), ("s_peer", "peer"), ("s_child", "child"), ("s_parent", "parent"),
        ("s_name", "name"), ("s_aa", "assigned-addresses"), ("s_aapl", "AAPL,address"),
        ("s_gc", " gc="), ("s_how", "tad"), ("s_run", " running"),
        ("s_nres", CRLF + "results="), ("s_colon", ":"), ("s_sp", " "),
        ("s_hdr_ok", CRLF + "hdr=ok"), ("s_hdr_stale", CRLF + "hdr=STALE"),
        ("s_wok", " write=ok"), ("s_wfail", " write=FAILED"),
        ("s_eread", CRLF + "ERR read"),
    ])
    return _finish(a, S_CODE_MAX)


if __name__ == "__main__":
    s1, s2 = build_stage1(), build_stage2()
    print("boot block %d bytes (limit %d), second stage %d bytes (limit %d)"
          % (len(s1), BOOT_MAX, len(s2), S_CODE_MAX))
