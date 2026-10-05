"""Wrap the test program in a Linux/PowerPC ELF for `qemu-ppc-static`.

A small shim stands in for Open Firmware's client interface, mapping the few
services the test program uses onto Linux system calls. The disk is the file
`sim.hda` in the current directory. This checks the test program's logic on an
independent PowerPC implementation; it says nothing about how Apple's Open
Firmware behaves.
"""

import struct

import harness
from ppcasm import *
from layout import SIM_MAGIC, M_STACK

BASE = 0x10000000
SHIM_OFF = 0x100
HARNESS_OFF = 0x10000
SO = 3


def _word(text):
    return int.from_bytes(text.encode("ascii"), "big")


def _shim():
    s = Asm(base_reg=11)
    e = s.emit
    count = [0]

    def rebase():                       # r11 = shim start; clobbers LR
        count[0] += 1
        name = "rb%d" % count[0]
        s.bl(name)
        s.label(name)
        e(mflr(11), addi(11, 11, -s.labels[name]))

    def service(tag, nxt):
        s.li32(7, _word(tag))
        e(cmpw(5, 7))
        s.bne(nxt)

    # entry: hand the test program its "client interface" and the sim marker
    rebase()
    s.la(5, "cif")
    s.li32(3, SIM_MAGIC)
    e(li(4, 0))
    s.li32(9, HARNESS_OFF - SHIM_OFF)
    e(add(9, 9, 11), mtctr(9), 0x4E800420)          # bctr

    s.label("cif")
    e(mflr(0))
    rebase()
    s.la(12, "v_lr")
    e(stw(0, 0, 12))
    e(lwz(4, 0, 3), lwz(5, 0, 4))                    # first four letters of the service
    e(lwz(6, 4, 3), slwi(6, 6, 2), add(6, 6, 3), addi(6, 6, 12), stw(6, 4, 12))
    e(mr(10, 3))

    service("find", "n1")
    e(li(3, 1))
    s.b("ret")
    s.label("n1")
    service("getp", "n2")
    e(lwz(4, 16, 10), lwz(5, 0, 4), lwz(8, 20, 10))
    service("stdo", "g1")
    e(li(0, 1), stw(0, 0, 8), li(3, 4))
    s.b("ret")
    s.label("g1")
    service("boot", "g2")
    s.la(9, "s_bootpath")
    e(lwz(0, 0, 9), stw(0, 0, 8), lwz(0, 4, 9), stw(0, 4, 8), li(3, 7))
    s.b("ret")
    s.label("g2")
    e(li(3, -1))
    s.b("ret")
    s.label("n2")
    service("open", "n3")
    s.la(3, "s_img")
    e(li(4, 2), li(5, 0), li(0, 5), sc())            # open(path, O_RDWR)
    s.bc(BO_FALSE, SO, "ret_sys")
    e(li(3, 0))
    s.b("ret_sys")
    s.label("n3")
    service("seek", "n4")
    e(lwz(3, 12, 10), lwz(4, 20, 10), li(5, 0), li(0, 19), sc(), li(3, 0))   # lseek
    s.b("ret_sys")
    s.label("n4")
    service("read", "n5")
    e(li(0, 3))
    s.b("rw")
    s.label("n5")
    service("writ", "n6")
    e(li(0, 4))
    s.label("rw")
    e(lwz(3, 12, 10), lwz(4, 16, 10), lwz(5, 20, 10), sc())
    s.bc(BO_FALSE, SO, "ret_sys")
    e(li(3, -1))
    s.b("ret_sys")
    s.label("n6")
    service("exit", "n7")
    e(li(3, 0), li(0, 1), sc())
    s.label("n7")
    e(li(3, -1))
    s.b("ret")

    s.label("ret_sys")
    rebase()
    s.label("ret")
    s.la(12, "v_lr")
    e(lwz(6, 4, 12), stw(3, 0, 6), lwz(0, 0, 12), mtlr(0), li(3, 0), blr())

    s.label("v_lr")
    e(0, 0)                                          # saved LR, return-cell pointer
    s.label("s_bootpath")
    s.data(b"disk:0\0\0")
    s.asciz("s_img", "sim.hda")
    return s.assemble()


def build(code=None):
    shim = _shim()
    if code is None:
        code = harness.build()
    assert SHIM_OFF + len(shim) <= HARNESS_OFF
    body = bytearray(HARNESS_OFF + len(code))
    body[SHIM_OFF:SHIM_OFF + len(shim)] = shim
    body[HARNESS_OFF:] = code
    memsz = HARNESS_OFF + M_STACK + 0x100
    ehdr = b"\x7fELF" + bytes([1, 2, 1, 0]) + bytes(8)
    ehdr += struct.pack(">HHIIIIIHHHHHH", 2, 20, 1, BASE + SHIM_OFF, 52, 0, 0, 52, 32, 1, 40, 0, 0)
    phdr = struct.pack(">IIIIIIII", 1, 0, BASE, BASE, len(body), memsz, 7, 0x10000)
    body[0:len(ehdr) + len(phdr)] = ehdr + phdr
    return bytes(body)
