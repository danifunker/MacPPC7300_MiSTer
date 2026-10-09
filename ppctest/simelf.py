"""Wrap the test program in a static Linux/PowerPC executable.

A small wrapper stands in for Open Firmware's client interface, mapping the few
services the test program uses onto Linux system calls. The same executable is
what runs on a real Power Mac under Linux and under `qemu-ppc-static` for the
self-test. Before it starts the test program it

  * turns floating-point exception traps off for the process
    (prctl PR_SET_FPEXC, PR_FP_EXC_DISABLED), as the Open Firmware build does
    with MSR[FE0,FE1], and records what the kernel answered;
  * catches SIGILL, SIGTRAP, SIGBUS, SIGFPE and SIGSEGV: one raised by the
    instruction under test is logged and stepped over, anything else ends the
    run with its status saved;
  * finds its disk: the path given as the first argument, else `sim.hda` in
    the current directory, else the first of /dev/sda../dev/sdp carrying this
    program's own build number. Nothing is written anywhere else;
  * on a disk with result slots, claims the first free one, so that several
    runs (one per CPU card, say) sit side by side on one image. Started from
    Open Firmware the test program does this itself;
  * copies /proc/cpuinfo into the run's status blocks;
  * on a ROM-dump disk, maps the physical range through /dev/mem (or the
    device given as the second argument).

Disk writes are confined to the claimed slot: its header block, its result
area, its status blocks and its trap bitmap.

The wrapper is linked at a fixed address, so it uses absolute addresses. A
system call destroys r0 and r3-r12; everything that must survive one lives in
memory (services, which may not touch the test program's r13-r31) or in
r13-r31 (start-up code, which runs before the test program).
"""

import struct

import harness
from ppcasm import *
from layout import *

BASE = 0x10000000
SHIM_OFF = 0x100
HARNESS_OFF = 0x1000
# zero-initialised memory after the test program's own (which ends below
# HARNESS_OFF + M_STACK + 0x100)
S_HDR = 0xA000               # the disk's header block, as found
S_LNX = 0xA200               # run status, LNX_BLKS blocks
S_PATH = 0xAA00              # path of the disk, 128 bytes
S_TRAPMAP = 0xB000
MEMSZ = S_TRAPMAP + TRAPMAP_MAX

# Linux system calls (32-bit PowerPC)
SYS_EXIT, SYS_READ, SYS_WRITE, SYS_OPEN, SYS_CLOSE, SYS_LSEEK = 1, 3, 4, 5, 6, 19
SYS_FSYNC, SYS_PRCTL, SYS_RT_SIGACTION, SYS_MMAP2 = 118, 171, 173, 192
PR_GET_FPEXC, PR_SET_FPEXC, PR_FP_EXC_DISABLED = 11, 12, 0
SA_SIGINFO = 4
SIGNALS = (4, 5, 7, 8, 11)   # ILL, TRAP, BUS, FPE, SEGV
UC_REGS = 48                 # struct ucontext: pointer to the saved registers
GREG_NIP = 32 * 4
SI_CODE = 8

# wrapper variables, offsets from the label `vars`
(V_LR, V_RETP, V_ARGS, V_FD, V_POS, V_SLOT, V_HDROFF, V_RESLO, V_RESHI, V_DELTA,
 V_STATOFF, V_MAPOFF, V_MAPLEN, V_ARGC, V_ARGV1, V_ARGV2, V_BUILD, V_TMP, V_EXIT) = range(0, 76, 4)
NVARS = 20


SAVED = "saved as run # of # on this disk\n"


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


def _shim(build_id, raw=False):
    s = Asm(origin=BASE + SHIM_OFF)
    e = s.emit
    count = [0]

    def local(prefix):
        count[0] += 1
        return "%s%d" % (prefix, count[0])

    def sys(nr):
        e(li(0, nr), sc())

    def say(text, fd=2):
        """write a fixed message; the text is kept after the code"""
        name = local("msg")
        messages.append((name, text))
        s.li_addr(4, name)
        e(li(3, fd), li(5, len(text)))
        sys(SYS_WRITE)

    def die(text, code):
        say(text)
        e(li(3, code))
        sys(SYS_EXIT)

    messages = []

    # ---- entry: r1 -> argc, argv[0], argv[1], argv[2] ---------------------------
    s.li_addr(31, "vars")
    e(lwz(3, 0, 1), lwz(4, 8, 1), lwz(5, 12, 1))
    e(stw(3, V_ARGC, 31), stw(4, V_ARGV1, 31), stw(5, V_ARGV2, 31))
    s.li32(30, BASE + S_LNX)
    s.li32(0, LNX_MAGIC)
    e(stw(0, L_MAGIC, 30), li(0, 1), stw(0, L_VERSION, 30))
    e(li(0, -1), stw(0, L_FPEXC0, 30), stw(0, L_FPEXC1, 30))

    # floating-point exception traps off, with the kernel's answers on record
    e(li(3, PR_GET_FPEXC), addi(4, 30, L_FPEXC0)); sys(SYS_PRCTL)
    e(li(3, PR_SET_FPEXC), li(4, PR_FP_EXC_DISABLED)); sys(SYS_PRCTL)
    e(stw(3, L_SETRET, 30), mfcr(0), stw(0, L_SETCR, 30))
    s.bns("fp_ok")
    say("WARNING: the kernel refused to turn floating-point traps off\n")
    s.label("fp_ok")
    e(li(3, PR_GET_FPEXC), addi(4, 30, L_FPEXC1)); sys(SYS_PRCTL)

    for sig in SIGNALS:
        e(li(3, sig)); s.li_addr(4, "sigact"); e(li(5, 0), li(6, 8)); sys(SYS_RT_SIGACTION)

    # ---- find the disk ----------------------------------------------------------
    e(lwz(3, V_ARGC, 31), cmpwi(3, 2))
    s.blt("no_arg")
    e(lwz(20, V_ARGV1, 31))
    s.bl("probe")
    e(cmpwi(3, 0))
    s.beq("found")
    die("ERR: the disk named on the command line is not this program's test disk\n", 2)
    s.label("no_arg")
    s.li_addr(20, "s_img")
    s.bl("probe")
    e(cmpwi(3, 0))
    s.beq("found")
    e(li(22, ord("a")))
    s.label("scan")
    s.li_addr(20, "s_dev")
    e(stb(22, 7, 20))
    s.bl("probe")
    e(cmpwi(3, 0))
    s.beq("found")
    e(addi(22, 22, 1), cmpwi(22, ord("p")))
    s.ble("scan")
    die("ERR: no test disk for this program found (sim.hda, /dev/sda../dev/sdp)\n", 2)

    # probe(r20 = path) -> r3 = 0 when it is our disk, with its header in S_HDR
    s.label("probe")
    e(mr(3, 20), li(4, 0), li(5, 0)); sys(SYS_OPEN)
    s.bso("p_fail")
    e(mr(23, 3), li(4, HDR_BLK * BLOCK), li(5, 0)); sys(SYS_LSEEK)
    e(mr(3, 23)); s.li32(4, BASE + S_HDR); e(li(5, BLOCK)); sys(SYS_READ)
    e(mr(24, 3), mfcr(25))
    e(mr(3, 23)); sys(SYS_CLOSE)
    e(andis_(0, 25, 0x1000))                        # CR0[SO]: the read failed
    s.bne("p_fail")
    e(cmpwi(24, BLOCK))
    s.bne("p_fail")
    s.li32(4, BASE + S_HDR)
    e(lwz(0, H_MAGIC, 4)); s.li32(5, _word("PPCT")); e(cmpw(0, 5))
    s.bne("p_fail")
    e(lwz(0, H_MAGIC + 4, 4)); s.li32(5, _word("EST1")); e(cmpw(0, 5))
    s.bne("p_fail")
    e(lwz(0, H_BUILD, 4), lwz(5, V_BUILD, 31), cmpw(0, 5))
    s.bne("p_fail")
    e(li(3, 0), blr())
    s.label("p_fail")
    e(li(3, 1), blr())

    s.label("found")
    # remember the path, for the banner and the header
    s.li32(4, BASE + S_PATH)
    e(li(5, 0))
    s.label("cp_path")
    e(lbzx(0, 20, 5), stbx(0, 4, 5), cmpwi(0, 0))
    s.beq("cp_done")
    e(addi(5, 5, 1), cmpwi(5, 120))
    s.blt("cp_path")
    e(li(0, 0), stbx(0, 4, 5))
    s.label("cp_done")
    e(mr(3, 20), li(4, 2), li(5, 0)); sys(SYS_OPEN)             # O_RDWR
    s.bns("open_ok")
    die("ERR: cannot open the test disk for writing (are you root?)\n", 2)
    s.label("open_ok")
    e(mr(25, 3), stw(3, V_FD, 31))

    # ---- claim a result slot ----------------------------------------------------
    s.li32(26, BASE + S_HDR)
    # raw: leave the slots to the test program (self-test of its own slot code)
    e(li(27, 0) if raw else lwz(27, H_NSLOT, 26), cmpwi(27, 0))
    s.beq("no_slots")
    e(li(28, 1))
    s.label("slot_loop")
    e(lwz(4, H_SLOTBLK, 26), addi(5, 28, -1), mulli(5, 5, SLOT_BLKS), add(4, 4, 5), slwi(29, 4, 9))
    e(mr(3, 25), mr(4, 29), li(5, 0)); sys(SYS_LSEEK)
    e(li(0, -1), stw(0, V_TMP, 31))                 # a failed read must not look free
    e(mr(3, 25), addi(4, 31, V_TMP), li(5, 4)); sys(SYS_READ)
    e(lwz(0, V_TMP, 31), cmpwi(0, 0))
    s.beq("claim")
    e(addi(28, 28, 1), cmpw(28, 27))
    s.ble("slot_loop")
    die("ERR: every result slot on this disk is used; copy it to the PC first\n", 3)
    s.label("claim")
    s.li32(0, STARTED)
    e(stw(0, H_DONE, 26), stw(28, H_SLOT, 26))
    e(mr(3, 25), mr(4, 29), li(5, 0)); sys(SYS_LSEEK)
    e(mr(3, 25), mr(4, 26), li(5, BLOCK)); sys(SYS_WRITE)
    s.bso("claim_bad")
    e(cmpwi(3, BLOCK))
    s.beq("claimed")
    s.label("claim_bad")
    die("ERR: cannot write to the test disk\n", 2)
    s.label("claimed")
    e(stw(28, V_SLOT, 31), stw(29, V_HDROFF, 31), addi(0, 29, BLOCK), stw(0, V_STATOFF, 31))
    e(lwz(4, H_RESBLK, 26), slwi(4, 4, 9), stw(4, V_RESLO, 31))
    e(lwz(5, H_AREA, 26), slwi(5, 5, 9), add(6, 4, 5), stw(6, V_RESHI, 31))
    e(lwz(7, H_STRIDE, 26), mullw(7, 7, 28), slwi(7, 7, 9), stw(7, V_DELTA, 31))
    e(add(8, 6, 7), stw(8, V_MAPOFF, 31))
    e(lwz(9, H_TRAPBLKS, 26), slwi(9, 9, 9), stw(9, V_MAPLEN, 31))
    s.b("slots_done")
    s.label("no_slots")
    e(li(0, 0), stw(0, V_SLOT, 31), stw(0, V_MAPLEN, 31))
    e(li(0, HDR_BLK * BLOCK), stw(0, V_HDROFF, 31))
    e(li(0, (HDR_BLK + 1) * BLOCK), stw(0, V_STATOFF, 31))
    s.label("slots_done")
    e(lwz(0, V_SLOT, 31), stw(0, L_SLOT, 30))

    # ---- which CPU is this ------------------------------------------------------
    s.li_addr(3, "s_cpuinfo")
    e(li(4, 0), li(5, 0)); sys(SYS_OPEN)
    s.bso("no_cpuinfo")
    e(mr(23, 3), addi(4, 30, L_CPUINFO), li(5, L_CPUINFO_MAX)); sys(SYS_READ)
    s.bso("ci_close")
    e(stw(3, L_CPULEN, 30))
    s.label("ci_close")
    e(mr(3, 23)); sys(SYS_CLOSE)
    s.label("no_cpuinfo")

    # ---- ROM-dump disk: map the physical range, top address bit cleared ---------
    e(lwz(21, H_ROMLEN, 26), cmpwi(21, 0))
    s.beq("no_map")
    e(lwz(22, H_ROMADDR, 26), cmpwi(22, 0))
    s.bge("no_map")                                 # ordinary memory (the self-test)
    s.li_addr(3, "s_mem")
    e(lwz(0, V_ARGC, 31), cmpwi(0, 3))
    s.blt("mem_open")
    e(lwz(3, V_ARGV2, 31))
    s.label("mem_open")
    e(li(4, 0), li(5, 0)); sys(SYS_OPEN)
    s.bso("mem_bad")
    e(mr(7, 3), rlwinm(3, 22, 0, 1, 31), mr(4, 21), li(5, 1), li(6, 0x11), srwi(8, 22, 12))
    sys(SYS_MMAP2)                                  # PROT_READ, MAP_SHARED | MAP_FIXED
    s.bns("no_map")
    s.label("mem_bad")
    die("ERR: cannot map the memory device (/dev/mem; are you root?)\n", 4)
    s.label("no_map")

    # ---- start the test program -------------------------------------------------
    s.li_addr(5, "cif")
    s.li32(3, SIM_MAGIC)
    e(li(4, 0))
    s.li32(9, BASE + HARNESS_OFF)
    e(mtctr(9), bctr())

    # ---- the "client interface": r3 -> service name, nargs, nrets, args... ------
    def ret(value=None):
        if value is not None:
            e(li(3, value))
        s.b("ret")

    def service(tag, nxt):
        s.li32(7, _word(tag))
        e(cmpw(5, 7))
        s.bne(nxt)

    s.label("cif")
    e(mflr(0)); s.li_addr(12, "vars")
    e(stw(0, V_LR, 12), stw(3, V_ARGS, 12), mr(10, 3))
    e(lwz(4, 0, 10), lwz(5, 0, 4))                  # first four letters of the service
    e(lwz(6, 4, 10), slwi(6, 6, 2), add(6, 6, 10), addi(6, 6, 12), stw(6, V_RETP, 12))

    service("find", "n1")
    ret(1)
    s.label("n1")
    service("getp", "n2")
    e(lwz(4, 16, 10), lwz(5, 0, 4), lwz(8, 20, 10))
    service("stdo", "g1")
    e(li(0, 1), stw(0, 0, 8))
    ret(4)
    s.label("g1")
    service("boot", "g2")
    s.li32(9, BASE + S_PATH)
    e(li(3, 0))
    s.label("bp")
    e(lbzx(0, 9, 3), cmpwi(0, 0))
    s.beq("ret")
    e(stbx(0, 8, 3), addi(3, 3, 1))
    s.b("bp")
    s.label("g2")
    ret(-1)

    s.label("n2")
    service("open", "n3")
    e(lwz(3, V_FD, 12))
    ret()
    s.label("n3")
    service("seek", "n4")
    e(lwz(0, 20, 10), stw(0, V_POS, 12))            # low word of the position
    ret(0)

    s.label("n4")
    service("read", "n5")
    e(lwz(4, V_POS, 12), cmpwi(4, HDR_BLK * BLOCK))
    s.bne("rd")
    e(lwz(4, V_HDROFF, 12))                         # the header is this run's own copy
    s.label("rd")
    e(lwz(3, V_FD, 12), li(5, 0)); sys(SYS_LSEEK)
    s.li_addr(12, "vars")
    e(lwz(10, V_ARGS, 12), lwz(3, V_FD, 12), lwz(4, 16, 10), lwz(5, 20, 10)); sys(SYS_READ)
    s.bns("ret")
    ret(-1)

    s.label("n5")
    service("writ", "n6")
    e(lwz(3, 12, 10), cmpwi(3, 1))
    s.bne("wr_disk")
    e(lwz(4, 16, 10), lwz(5, 20, 10)); sys(SYS_WRITE)            # the console
    s.bns("ret")
    ret(-1)
    s.label("wr_disk")
    e(lwz(4, V_POS, 12), lwz(0, V_SLOT, 12), cmpwi(0, 0))
    s.beq("wr")                                     # a disk without slots: as asked
    e(cmpwi(4, HDR_BLK * BLOCK))
    s.bne("wr_res")
    e(lwz(4, V_HDROFF, 12))
    s.b("wr")
    s.label("wr_res")                               # else only this run's result area
    e(lwz(0, V_RESLO, 12), cmplw(4, 0))
    s.blt("wr_refuse")
    e(lwz(0, V_RESHI, 12), cmplw(4, 0))
    s.bge("wr_refuse")
    e(lwz(0, V_DELTA, 12), add(4, 4, 0))
    s.label("wr")
    e(lwz(3, V_FD, 12), li(5, 0)); sys(SYS_LSEEK)
    s.li_addr(12, "vars")
    e(lwz(10, V_ARGS, 12), lwz(3, V_FD, 12), lwz(4, 16, 10), lwz(5, 20, 10)); sys(SYS_WRITE)
    s.bns("ret")
    s.label("wr_refuse")
    ret(-1)

    s.label("n6")
    service("exit", "n7")
    e(li(0, 0), stw(0, V_EXIT, 12))
    s.b("finish")
    s.label("n7")
    e(li(3, -1))

    s.label("ret")                                  # r3 = the service's result
    s.li_addr(12, "vars")
    e(lwz(6, V_RETP, 12), stw(3, 0, 6), lwz(0, V_LR, 12), mtlr(0), li(3, 0), blr())

    # ---- finish: save the run status and trap bitmap, then exit(V_EXIT) ----------
    s.label("finish")
    s.li_addr(31, "vars")
    e(lwz(3, V_FD, 31), cmpwi(3, 0))
    s.beq("leave")                                  # no disk was opened
    e(lwz(4, V_STATOFF, 31), li(5, 0)); sys(SYS_LSEEK)
    e(lwz(3, V_FD, 31)); s.li32(4, BASE + S_LNX); e(li(5, LNX_BLKS * BLOCK)); sys(SYS_WRITE)
    e(lwz(5, V_MAPLEN, 31), cmpwi(5, 0))
    s.beq("synced")
    e(lwz(3, V_FD, 31), lwz(4, V_MAPOFF, 31), li(5, 0)); sys(SYS_LSEEK)
    e(lwz(3, V_FD, 31)); s.li32(4, BASE + S_TRAPMAP); e(lwz(5, V_MAPLEN, 31)); sys(SYS_WRITE)
    s.label("synced")
    e(lwz(3, V_FD, 31)); sys(SYS_FSYNC)
    s.bso("leave")
    e(lwz(5, V_SLOT, 31), lwz(0, V_EXIT, 31), or_(0, 0, 5), cmpw(0, 5))
    s.bne("leave")                                  # only after a clean exit
    e(cmpwi(5, 0))
    s.beq("leave")
    s.li_addr(4, "s_saved")                         # "saved as run N of M on this disk"
    s.li32(6, BASE + S_HDR)
    e(addi(5, 5, 48), stb(5, SAVED.index("#"), 4))
    e(lwz(6, H_NSLOT, 6), addi(6, 6, 48), stb(6, SAVED.rindex("#"), 4))
    e(li(3, 1), li(5, len(SAVED))); sys(SYS_WRITE)
    s.label("leave")
    e(lwz(3, V_EXIT, 31)); sys(SYS_EXIT)

    # ---- signal handler: r3 = signal, r4 -> siginfo, r5 -> ucontext --------------
    s.label("handler")
    e(lwz(6, UC_REGS, 5), lwz(7, GREG_NIP, 6), lwz(8, 28 * 4, 6), lwz(9, 29 * 4, 6))
    s.li32(10, BASE + S_LNX)
    e(cmpw(7, 8))                                   # the test program keeps r28 = `slot`
    s.bne("fatal")
    e(addi(7, 7, 4), stw(7, GREG_NIP, 6))           # step over the instruction
    s.li32(0, TRAPMAP_MAX * 8)
    e(cmplw(9, 0))
    s.bge("h_log")
    s.li32(11, BASE + S_TRAPMAP)
    e(srwi(12, 9, 3), lbzx(0, 11, 12), andi_(8, 9, 7), li(7, 0x80), srw(7, 7, 8), or_(0, 0, 7))
    e(stbx(0, 11, 12))
    s.label("h_log")
    e(lwz(8, L_NTRAP, 10), addi(0, 8, 1), stw(0, L_NTRAP, 10), cmplwi(8, L_LOG_MAX))
    s.bge("h_out")
    e(slwi(8, 8, 3), add(8, 8, 10), stw(9, L_LOG, 8))
    e(lwz(0, SI_CODE, 4), andi_(0, 0, 0xFFFF), slwi(3, 3, 16), or_(0, 0, 3), stw(0, L_LOG + 4, 8))
    s.label("h_out")
    e(blr())
    s.label("fatal")                                # not the instruction under test
    e(stw(3, L_FATALSIG, 10), stw(7, L_FATALNIP, 10), stw(9, L_FATALVEC, 10))
    s.li_addr(12, "vars")
    e(addi(3, 3, 100), stw(3, V_EXIT, 12))
    say("\nERR: fatal signal outside a test vector; run status saved\n")
    s.b("finish")

    # ---- data -------------------------------------------------------------------
    s.label("sigact")                               # kernel struct sigaction
    s.addr_word("handler")
    e(SA_SIGINFO, 0, 0, 0)
    s.label("vars")
    for i in range(NVARS):
        e(build_id if i * 4 == V_BUILD else 0)
    s.asciz("s_img", "sim.hda")
    s.asciz("s_dev", "/dev/sda")
    s.asciz("s_cpuinfo", "/proc/cpuinfo")
    s.asciz("s_mem", "/dev/mem")
    s.asciz("s_saved", SAVED)
    for name, text in messages:
        s.asciz(name, text)
    return s.assemble()


def build(code=None, build_id=0, raw=False):
    """The Linux executable for a test program; build_id ties it to its disk."""
    if code is None:
        code = harness.build()
    shim = _shim(build_id, raw)
    assert SHIM_OFF + len(shim) <= HARNESS_OFF, "wrapper is %d bytes" % len(shim)
    assert HARNESS_OFF + M_STACK + 0x100 <= S_HDR
    body = bytearray(HARNESS_OFF + len(code))
    body[SHIM_OFF:SHIM_OFF + len(shim)] = shim
    body[HARNESS_OFF:] = code
    ehdr = b"\x7fELF" + bytes([1, 2, 1, 0]) + bytes(8)
    ehdr += struct.pack(">HHIIIIIHHHHHH", 2, 20, 1, BASE + SHIM_OFF, 52, 0, 0, 52, 32, 1, 40, 0, 0)
    phdr = struct.pack(">IIIIIIII", 1, 0, BASE, BASE, len(body), MEMSZ, 7, 0x10000)
    body[0:len(ehdr) + len(phdr)] = ehdr + phdr
    assert len(body) <= ELF_MAX_BLKS * BLOCK
    return bytes(body)
