"""The on-target test program.

A position-independent raw binary of at most 2048 bytes, started by Open
Firmware's "partition zero" boot (`boot scsi-int/sd@N:0`) the same way
NetBSD/macppc's first-stage `bootxx` is: r5 holds the client-interface entry.
The start-up sequence (cache flush, BAT3 mapping the low 256 MB, MSR = 0x3030)
deliberately mirrors bootxx, which is known to run under Open Firmware 1.0.5.

For every 64-byte input record it patches the instruction into `slot`, loads
r3-r6, CR, XER, CTR, FPSCR and f3-f6, executes it, and stores the same state.
Results are written back to the boot disk; a checksum, a mismatch count and the
first mismatching vector numbers are also printed on the console.

Register use: r27 load address, r26 client interface, r25 stdout, r24 disk,
r23 simulator flag, r22 vectors left, r21 chunk block offset, r19 checksum,
r18 write-failed flag, r17 vectors in this chunk, r13 mismatches, r29 vector
number, r31/r30 input/output record, r28 address of `slot`, r7 the memory
buffer of an F_MEM vector (0 otherwise). r14-r16 belong to
the call helpers.
"""

from ppcasm import *
from layout import *


CRLF = chr(13) + chr(10)


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


def _prologue(a):
    """Entry, console, boot device and header check, shared by every program.
    Leaves r24 = disk, r25 = stdout, the header block in M_HDR."""
    e = a.emit

    # ---- entry -----------------------------------------------------------
    a.bl("here")
    a.label("here")
    e(mflr(27), addi(27, 27, -4))
    e(mr(26, 5), mr(23, 3))
    # Open Firmware does not flush the instruction cache after loading us
    e(mr(8, 27), li(9, BOOT_MAX // 32), mtctr(9))
    a.label("flush")
    e(dcbf(0, 8), icbi(0, 8), addi(8, 8, 32))
    a.bdnz("flush")
    e(sync(), isync())

    a.li32(9, SIM_MAGIC)
    e(cmpw(23, 9), li(23, 0))
    a.bne("real")
    e(li(23, 1), li(13, 0))
    a.b("common")

    a.label("real")
    e(mfmsr(13))
    e(mfspr(8, PVR), srwi(8, 8, 16), cmpwi(8, 1))
    a.beq("msr")                      # 601: different BAT format, leave OF's mapping
    e(li(0, 0), mtspr(DBAT3U, 0), mtspr(IBAT3U, 0), isync())
    # low 256 MB one-to-one, supervisor read/write, cache-inhibited so the
    # patched instruction is always fetched from memory
    e(li(8, 0x1FFE), li(9, 0x22))
    e(mtspr(DBAT3L, 9), mtspr(DBAT3U, 8), mtspr(IBAT3L, 9), mtspr(IBAT3U, 8), isync())
    a.label("msr")
    e(li(8, 0x3030), mtmsr(8), isync())   # FP | ME | IR | DR; EE, FE0, FE1 off

    a.label("common")
    e(addi(1, 27, M_STACK), li(0, 0), stw(0, 0, 1))
    e(stw(13, M_MSR, 27))

    # ---- console and boot device -------------------------------------------
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
    # "…/sd@4:0" -> "…/sd@4": open the whole disk, as bootxx does
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

    # ---- header: refuse to touch a disk that is not ours --------------------
    e(li(3, HDR_BLK), addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_read")
    e(cmpwi(3, BLOCK))
    a.bne("e_read")
    e(lwz(8, M_HDR + H_MAGIC, 27)); a.li32(9, _word("PPCT")); e(cmpw(8, 9))
    a.bne("e_magic")
    e(lwz(8, M_HDR + H_MAGIC + 4, 27)); a.li32(9, _word("EST1")); e(cmpw(8, 9))
    a.bne("e_magic")


def _status(a, slots=False):
    """Label `done`: fill in the completion record and write the header back,
    to the block in M_HDRBLK when the program uses result slots.
    Uses r19 checksum, r18 write-failed, r13 mismatches, r29 count."""
    e = a.emit
    a.label("done")
    e(li(8, 0), li(9, 0), cmpwi(23, 0))
    a.bne("nopriv")
    e(mfspr(8, PVR), mfspr(9, HID0))
    a.label("nopriv")
    a.li32(0, DONE)
    e(stw(0, M_HDR + H_DONE, 27), stw(19, M_HDR + H_SUM, 27))
    e(stw(13, M_HDR + H_NMISS, 27), stw(18, M_HDR + H_WRFAIL, 27))
    e(stw(8, M_HDR + H_PVR, 27), stw(9, M_HDR + H_HID0, 27))
    e(stw(23, M_HDR + H_SIM, 27), stw(29, M_HDR + H_NRUN, 27))
    e(lwz(0, M_MSR, 27), stw(0, M_HDR + H_MSR, 27))
    e(addi(8, 27, M_PATH), addi(10, 27, M_HDR + H_PATH), li(9, 0))
    a.label("cp")
    e(lwzx(0, 8, 9), stwx(0, 10, 9), addi(9, 9, 4), cmpwi(9, H_PATH_LEN))
    a.blt("cp")
    e(lwz(3, M_HDRBLK, 27) if slots else li(3, HDR_BLK))
    e(addi(4, 27, M_HDR), li(5, BLOCK)); a.bl("disk_write")
    e(cmpwi(3, BLOCK))
    a.beq("h_ok")
    e(li(18, 1))
    a.label("h_ok")
    # Open Firmware 1.0.5 keeps the last write in its block buffer until the
    # next disk operation (seen on a real 7600: every result chunk landed but
    # this header did not). Read another block to push it out: the same
    # seek-then-read that followed every result chunk in that run. A build
    # that also closed the disk and restored the entry MSR before exiting
    # reset the 7600; which of the two did it is not known, so neither is here.
    e(li(3, 0), addi(4, 27, M_IN), li(5, BLOCK)); a.bl("disk_read")


def build_romdump():
    """Copy H_ROMLEN bytes of physical memory at H_ROMADDR to the boot disk,
    4096 bytes at a time, with the same checksum the test program uses."""
    a = Asm(base_reg=27)
    e = a.emit
    _prologue(a)
    e(lwz(22, M_HDR + H_ROMLEN, 27), lwz(21, M_HDR + H_ROMBLK, 27))
    e(lwz(20, M_HDR + H_ROMADDR, 27))
    # Under Linux the wrapper maps physical memory at the same address with
    # the top bit clear (a user program cannot have an address that high).
    e(cmpwi(23, 0))
    a.beq("addr_ok")
    e(rlwinm(20, 20, 0, 1, 31))
    a.label("addr_ok")
    e(li(19, 0), li(18, 0), li(13, 0), li(29, 0))

    a.label("chunk")
    e(cmpwi(22, 0))
    a.ble("done")
    e(cmpwi(23, 0))
    a.bne("copy")
    # the ROM is read by physical address: data translation off while copying
    e(mfmsr(7), rlwinm(8, 7, 0, 28, 26), mtmsr(8), isync())
    a.label("copy")
    e(addi(10, 27, M_OUT), li(9, 0))
    a.label("cpy")
    e(lwzx(0, 20, 9), stwx(0, 10, 9), rotlwi(19, 19, 1), add(19, 19, 0))
    e(addi(9, 9, 4), cmpwi(9, 4096))
    a.blt("cpy")
    # These stores went through the data cache (real mode), but Open
    # Firmware's SCSI write takes the bytes straight from RAM. Without this
    # flush a real 7600 wrote a mix of this chunk and older ones.
    e(li(9, 4096 // 32), mtctr(9))
    a.label("fl")
    e(dcbf(0, 10), addi(10, 10, 32))
    a.bdnz("fl")
    e(sync())
    e(cmpwi(23, 0))
    a.bne("wr")
    e(mtmsr(7), isync())
    a.label("wr")
    e(mr(3, 21), addi(4, 27, M_OUT), li(5, 4096)); a.bl("disk_write")
    e(cmpwi(3, 4096))
    a.beq("w_ok")
    e(li(18, 1))
    a.label("w_ok")
    e(addi(20, 20, 4096), addi(21, 21, CHUNK_BLOCKS), addi(22, 22, -4096), addi(29, 29, 1))
    e(andi_(0, 22, 0xFFFF))
    a.bne("chunk")
    a.la(3, "s_dot"); a.bl("puts")              # one dot per 64 KB
    a.b("chunk")

    _status(a)
    a.la(3, "s_sum"); a.bl("puts"); e(mr(3, 19)); a.bl("puthex")
    e(cmpwi(18, 0))
    a.la(3, "s_wok")
    a.beq("pw")
    a.la(3, "s_wfail")
    a.label("pw")
    a.bl("puts")
    a.b("exit")

    _epilogue(a, [
        ("s_banner", CRLF + "romdump v4b "), ("s_nl", CRLF), ("s_dot", "."),
        ("s_sum", CRLF + "rom sum="), ("s_wok", " write=ok"), ("s_wfail", " write=FAILED"),
    ])
    return _finish(a)


def build(own_slots_always=False):
    """own_slots_always: test-only variant that picks its result slot itself
    even under the Linux wrapper, so the self-test can exercise that code."""
    a = Asm(base_reg=27)
    e = a.emit
    _prologue(a)

    # ---- result slot: the first one whose header block is still blank ---------
    # Each run gets its own, so runs with different CPU cards sit side by side
    # on one disk. Under Linux the wrapper chooses the slot and redirects the
    # writes, so this is skipped there.
    e(li(8, HDR_BLK), stw(8, M_HDRBLK, 27))
    if not own_slots_always:
        e(cmpwi(23, 0))
        a.bne("slots_done")
    e(lwz(21, M_HDR + H_NSLOT, 27), lwz(22, M_HDR + H_SLOTBLK, 27), li(20, 1))
    a.label("slot_try")
    e(cmpw(20, 21))
    a.bgt("e_full")
    e(mr(3, 22), addi(4, 27, M_IN), li(5, BLOCK)); a.bl("disk_read")
    e(cmpwi(3, BLOCK))
    a.bne("e_read")
    e(lwz(8, M_IN, 27), cmpwi(8, 0))
    a.beq("slot_ok")
    e(addi(20, 20, 1), addi(22, 22, SLOT_BLKS))
    a.b("slot_try")
    a.label("slot_ok")
    e(stw(22, M_HDRBLK, 27), stw(20, M_HDR + H_SLOT, 27))
    e(lwz(8, M_HDR + H_STRIDE, 27), mullw(8, 8, 20), lwz(9, M_HDR + H_RESBLK, 27))
    e(add(9, 9, 8), stw(9, M_HDR + H_RESBLK, 27))        # results go to this slot's area
    a.label("slots_done")

    e(lwz(22, M_HDR + H_NVEC, 27))
    e(li(21, 0), li(19, 0), li(18, 0), li(13, 0), li(29, 0))
    a.la(28, "slot")

    # ---- per-chunk loop -----------------------------------------------------
    a.label("chunk")
    e(cmpwi(22, 0))
    a.ble("done")
    e(lwz(3, M_HDR + H_VECBLK, 27), add(3, 3, 21), addi(4, 27, M_IN), li(5, 4096))
    a.bl("disk_read")
    e(cmpwi(3, 4096))
    a.bne("e_read")
    e(lwz(3, M_HDR + H_EXPBLK, 27), add(3, 3, 21), addi(4, 27, M_EXP), li(5, 4096))
    a.bl("disk_read")
    e(cmpwi(3, 4096))
    a.bne("e_read")
    e(li(17, CHUNK_RECS), cmpw(22, 17))
    a.bge("n_ok")
    e(mr(17, 22))
    a.label("n_ok")
    e(addi(31, 27, M_IN), addi(30, 27, M_OUT), mr(11, 17))

    # ---- one vector ---------------------------------------------------------
    a.label("vec")
    e(lwz(0, I_INSN, 31), stw(0, 0, 28))
    e(dcbf(0, 28), sync(), icbi(0, 28), sync(), isync())
    e(lfd(0, I_CTR, 31), mtfsf(0xFF, 0))          # low word of the pair = FPSCR
    a.la(8, "zero"); e(lfd(3, 0, 8))
    e(lfd(4, I_F4, 31), lfd(5, I_F4 + 8, 31), lfd(6, I_F4 + 16, 31))
    # the memory buffer starts as the f6 pattern; r7 = its address for an
    # F_MEM vector, 0 otherwise
    e(stfd(6, M_SCRATCH, 27))
    e(lwz(0, I_FLAGS, 31), andi_(7, 0, F_MEM))
    a.beq("nomem")
    e(addi(7, 27, M_SCRATCH))
    a.label("nomem")
    e(lwz(0, I_CR, 31), mtcrf(0xFF, 0))
    e(lwz(0, I_XER, 31), mtxer(0))
    e(lwz(0, I_CTR, 31), mtctr(0))
    e(lwz(3, I_R3, 31), lwz(4, I_R3 + 4, 31), lwz(5, I_R3 + 8, 31), lwz(6, I_R3 + 12, 31))
    e(add(6, 6, 7))
    a.label("slot")
    e(nop())
    e(stw(3, O_R3, 30), stw(4, O_R3 + 4, 30), stw(5, O_R3 + 8, 30))
    e(subf(0, 7, 6), stw(0, O_R3 + 12, 30))       # r6 less the buffer address
    e(mfcr(0), stw(0, O_CR, 30), mfxer(0), stw(0, O_XER, 30))
    e(stfd(3, O_F3, 30), stfd(4, O_F3 + 8, 30), stfd(5, O_F3 + 16, 30), stfd(6, O_F3 + 24, 30))
    e(mffs(0), stfd(0, O_CTR, 30))                # FPSCR lands in O_FPSCR
    e(mfctr(0), stw(0, O_CTR, 30))
    e(cmpwi(7, 0))
    a.beq("nobuf")
    e(lfd(0, M_SCRATCH, 27), stfd(0, O_F3 + 24, 30))   # the buffer, in place of f6
    a.label("nobuf")

    # checksum: sum = rotl(sum, 1) + word, over the 16 output words
    e(li(9, REC // 4), mr(8, 30))
    a.label("ck")
    e(lwz(0, 0, 8), rotlwi(19, 19, 1), add(19, 19, 0))
    e(addi(8, 8, 4), addi(9, 9, -1), cmpwi(9, 0))
    a.bne("ck")

    e(lwz(0, I_FLAGS, 31), andi_(0, 0, F_HAS_EXPECTED))
    a.beq("nocmp")
    e(addi(10, 30, M_EXP - M_OUT), mr(8, 30), li(9, REC // 4))
    a.label("cm")
    e(lwz(0, 0, 8), lwz(7, 0, 10), cmpw(0, 7))
    a.bne("miss")
    e(addi(8, 8, 4), addi(10, 10, 4), addi(9, 9, -1), cmpwi(9, 0))
    a.bne("cm")
    a.b("nocmp")
    a.label("miss")
    e(cmpwi(13, H_MISS_MAX))
    a.bge("miss2")
    e(slwi(8, 13, 2), add(8, 8, 27), stw(29, M_HDR + H_MISS, 8))
    a.label("miss2")
    e(addi(13, 13, 1))
    a.label("nocmp")
    e(addi(29, 29, 1), addi(31, 31, REC), addi(30, 30, REC))
    e(addi(11, 11, -1), cmpwi(11, 0))
    a.bne("vec")

    e(lwz(3, M_HDR + H_RESBLK, 27), add(3, 3, 21), addi(4, 27, M_OUT), li(5, 4096))
    a.bl("disk_write")
    e(cmpwi(3, 4096))
    a.beq("w_ok")
    e(li(18, 1))
    a.label("w_ok")
    e(addi(21, 21, CHUNK_BLOCKS), subf(22, 17, 22))
    a.la(3, "s_dot"); a.bl("puts")
    a.b("chunk")

    # ---- finish -------------------------------------------------------------
    _status(a, slots=True)

    a.la(3, "s_n"); a.bl("puts"); e(mr(3, 29)); a.bl("puthex")
    a.la(3, "s_sum"); a.bl("puts"); e(mr(3, 19)); a.bl("puthex")
    a.la(3, "s_miss"); a.bl("puts"); e(mr(3, 13)); a.bl("puthex")
    e(cmpwi(18, 0))
    a.la(3, "s_wok")
    a.beq("pw")
    a.la(3, "s_wfail")
    a.label("pw")
    a.bl("puts")

    # ---- second stage: the tests that do not fit in a boot block ---------------
    # Loaded 64 KB above this program and entered with the same registers
    # (r27 base, r26 client interface, r25 console, r24 disk, r20 its own
    # base) and the slot header in M_HDR. Not under Linux.
    e(cmpwi(23, 0))
    a.bne("exit")
    e(lwz(22, M_HDR + H_S2LEN, 27), cmpwi(22, 0))
    a.beq("exit")
    e(lwz(21, M_HDR + H_S2BLK, 27), addis(20, 27, 1))
    a.label("s2")
    e(mr(3, 21), mr(4, 20), li(5, 4096)); a.bl("disk_read")
    e(cmpwi(3, 4096))
    a.bne("e_read")
    e(addi(21, 21, CHUNK_BLOCKS), addi(20, 20, 4096), addi(22, 22, -4096), cmpwi(22, 0))
    a.bgt("s2")
    e(addis(20, 27, 1), mtctr(20), bctr())

    _epilogue(a, [
        ("s_banner", CRLF + "ppctest v4d "), ("s_nl", CRLF), ("s_dot", "."),
        ("s_n", CRLF + "n="), ("s_sum", " sum="), ("s_miss", " miss="),
        ("s_wok", " write=ok"), ("s_wfail", " write=FAILED"),
    ])
    return _finish(a)


_OF_STRINGS = [
    ("s_finddevice", "finddevice"), ("s_getprop", "getprop"), ("s_open", "open"),
    ("s_seek", "seek"), ("s_read", "read"), ("s_write", "write"), ("s_exit", "exit"),
    ("s_chosen", "/chosen"), ("s_stdout", "stdout"), ("s_bootpath", "bootpath"),
]
_ERR_STRINGS = [
    ("s_epath", CRLF + "ERR no bootpath"), ("s_eopen", CRLF + "ERR open"),
    ("s_eread", CRLF + "ERR read"), ("s_emagic", CRLF + "ERR not a ppctest disk"),
    ("s_efull", CRLF + "ERR full"),
]


def _epilogue(a, strings):
    """Error exits, call helpers and string data, shared by every program."""
    e = a.emit
    a.label("e_path"); a.la(3, "s_epath"); a.b("fail")
    a.label("e_open"); a.la(3, "s_eopen"); a.b("fail")
    a.label("e_read"); a.la(3, "s_eread"); a.b("fail")
    a.label("e_full"); a.la(3, "s_efull"); a.b("fail")      # every result slot is used
    a.label("e_magic"); a.la(3, "s_emagic")
    a.label("fail")
    a.bl("puts")
    a.label("exit")
    a.la(3, "s_nl"); a.bl("puts")
    a.la(3, "s_exit"); e(li(4, 0), li(5, 0)); a.bl("ofcall")
    a.label("hang")
    a.b("hang")

    # ---- helpers ------------------------------------------------------------
    # ofcall(r3 = service name, r4 = nargs, r5 = nrets, r6..r9 = args) -> r3
    a.label("ofcall")
    e(mflr(16), addi(10, 27, M_ARGS))
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
    e(mflr(15), stw(7, M_OPNAME, 27), stw(4, M_IOBUF, 27), stw(5, M_IOLEN, 27))
    e(srwi(7, 3, 23), slwi(8, 3, 9), mr(6, 24))
    a.la(3, "s_seek"); e(li(4, 3), li(5, 1))
    a.bl("ofcall")
    e(lwz(3, M_OPNAME, 27), li(4, 3), li(5, 1), mr(6, 24))
    e(lwz(7, M_IOBUF, 27), lwz(8, M_IOLEN, 27))
    a.bl("ofcall")
    e(mtlr(15), blr())

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

    a.label("puthex")
    e(mflr(15), addi(7, 27, M_HEX), mr(9, 7), li(8, 8), mtctr(8))
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

    # ---- data ---------------------------------------------------------------
    a.label("zero")
    e(0, 0)
    for name, text in _OF_STRINGS + strings + _ERR_STRINGS:
        a.asciz(name, text)


def _finish(a, limit=BOOT_MAX):
    blob = a.assemble()
    if len(blob) > limit:
        raise ValueError("program is %d bytes, limit %d" % (len(blob), limit))
    return blob


def checksum(words):
    s = 0
    for w in words:
        s = (((s << 1) | (s >> 31)) + w) & 0xFFFFFFFF
    return s


if __name__ == "__main__":
    print("test program: %d bytes" % len(build()))
