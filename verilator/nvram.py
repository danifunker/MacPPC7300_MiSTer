#!/usr/bin/env python3
"""The 7300/7600's 8 KB NVRAM (Grand Central's) as an image file: rebuilt
from a device log, its Open Firmware partition shown and changed.

    python verilator\\nvram.py fromlog LOG OUT [--until N]
        replay the NVRAM writes of a device log (run_machine.py --dev-log)
        from a blank NVRAM, up to instruction N, into an 8 KB image
    python verilator\\nvram.py show IMG
        Open Firmware's variables, if its partition is valid
    python verilator\\nvram.py set IMG OUT NAME=VALUE ...
        change variables (flags true/false, numbers, strings) and the
        partition's checksum, e.g. auto-boot?=false
    python verilator\\nvram.py dingus IMG OUT
        the image as dingusppc's nvram.bin (its signature and size first),
        for verilator\\machref run in the file's directory

The NVRAM is reached through Grand Central (MacPPC7300_gc.sv; dingusppc's
macio.h): the address's high bits written to F301D000, then byte
(address & 1F) at F301F000 + 16 * (address & 1F).

Open Firmware 1.0.5's partition (the "Old World" one) is NVRAM 1800-1FFF,
as dingusppc's devices/common/ofnvram.cpp reads and writes it: a header
(signature 1275, version 5, 8 pages, checksum, here, top), the flags word
at +0C, numbers and string descriptors (NVRAM offset, length) from +10, the
strings in a heap growing down from 2000. The 16-bit words of the partition
sum, with the carry added back, to FFFF.
"""

import struct
import sys

NV_SIZE = 0x2000
OF_OFF = 0x1800
OF_SIZE = 0x800

FLAGS = ["little-endian?", "real-mode?", "auto-boot?", "diag-switch?", "fcode-debug?",
         "oem-banner?", "oem-logo?", "use-nvramrc?", "f-segment?"]

# name: (kind, offset in the partition)
VARS = {
    "real-base": ("int", 0x10), "real-size": ("int", 0x14), "virt-base": ("int", 0x18),
    "virt-size": ("int", 0x1C), "load-base": ("int", 0x20), "pci-probe-list": ("int", 0x24),
    "screen-#columns": ("int", 0x28), "screen-#rows": ("int", 0x2C), "selftest-#megs": ("int", 0x30),
    "boot-device": ("str", 0x34), "boot-file": ("str", 0x38), "diag-device": ("str", 0x3C),
    "diag-file": ("str", 0x40), "input-device": ("str", 0x44), "output-device": ("str", 0x48),
    "oem-banner": ("str", 0x4C), "oem-logo": ("str", 0x50), "nvramrc": ("str", 0x54),
    "boot-command": ("str", 0x58),
}


def from_log(path, until=None):
    """Replay a device log's NVRAM writes; returns the image and the count."""
    nv = bytearray(NV_SIZE)
    hi = 0
    n = 0
    with open(path) as fh:
        for line in fh:
            p = line.split()
            if len(p) < 7 or p[0] != "A" or p[3] != "W":
                continue
            if len(p) > 7 and p[7] == "cached":
                continue
            icount = int(p[1])
            if until is not None and icount > until:
                break
            size, addr, value = int(p[4]), int(p[5], 16), int(p[6], 16)
            if addr & ~3 == 0xF301D000:
                # the bytes as they lie on the bus, the lowest address first
                lanes = [None] * 4
                for k in range(size):
                    lanes[(addr & 3) + k] = (value >> (8 * (size - 1 - k))) & 0xFF
                if size == 1:
                    hi = lanes[addr & 3]
                elif lanes[0] is not None:
                    hi = (lanes[1] << 8) | lanes[0]          # MacPPC7300_gc: {wdata[23:16], wdata[31:24]}
                else:
                    hi = (lanes[3] << 8) | lanes[2]          # {wdata[7:0], wdata[15:8]}
            elif 0xF301F000 <= addr < 0xF301F200 and size == 1:
                nv[((hi << 5) + ((addr >> 4) & 0x1F)) & (NV_SIZE - 1)] = value
                n += 1
    return nv, n


def checksum(part):
    acc = 0
    for i in range(0, OF_SIZE, 2):
        acc += (part[i] << 8) | part[i + 1]
    return (acc + (acc >> 16)) & 0xFFFF


def valid(nv):
    part = nv[OF_OFF:OF_OFF + OF_SIZE]
    sig, ver, pages = struct.unpack(">HBB", part[0:4])
    return sig == 0x1275 and ver == 5 and pages * 256 == OF_SIZE and checksum(part) == 0xFFFF


def get_vars(nv):
    part = nv[OF_OFF:OF_OFF + OF_SIZE]
    flags = struct.unpack(">I", part[12:16])[0]
    out = []
    for i, name in enumerate(FLAGS):
        out.append((name, "true" if flags & (0x80000000 >> i) else "false"))
    for name, (kind, off) in VARS.items():
        if kind == "int":
            out.append((name, "%08x" % struct.unpack(">I", part[off:off + 4])[0]))
        else:
            soff, slen = struct.unpack(">HH", part[off:off + 4])
            o = soff - OF_OFF
            out.append((name, part[o:o + slen].decode("latin-1") if 0 <= o and o + slen <= OF_SIZE else "?"))
    return out


def set_var(nv, name, value):
    part = bytearray(nv[OF_OFF:OF_OFF + OF_SIZE])
    if name in FLAGS:
        bit = 0x80000000 >> FLAGS.index(name)
        flags = struct.unpack(">I", part[12:16])[0]
        flags = flags | bit if value == "true" else flags & ~bit if value == "false" else None
        if flags is None:
            sys.exit("%s takes true or false" % name)
        part[12:16] = struct.pack(">I", flags)
    elif name in VARS and VARS[name][0] == "int":
        off = VARS[name][1]
        part[off:off + 4] = struct.pack(">I", int(value, 0))
    elif name in VARS:
        # as ofnvram.cpp: take the old string out of the heap, put the new one at its bottom
        off = VARS[name][1]
        soff, slen = struct.unpack(">HH", part[off:off + 4])
        here, top = struct.unpack(">HH", part[6:10])
        new_top = top + slen - len(value)
        if new_top < here:
            sys.exit("no room in the heap for %s" % name)
        part[top + slen - OF_OFF:soff + slen - OF_OFF] = part[top - OF_OFF:soff - OF_OFF]
        for k, o in VARS.values():
            if k == "str":
                ko = struct.unpack(">H", part[o:o + 2])[0]
                if ko < soff:
                    part[o:o + 2] = struct.pack(">H", ko + slen)
        top = new_top
        part[top - OF_OFF:top - OF_OFF + len(value)] = value.replace("\n", "\r").encode("latin-1")
        part[off:off + 4] = struct.pack(">HH", top, len(value))
        part[8:10] = struct.pack(">H", top)
    else:
        sys.exit("unknown variable %s" % name)
    part[4:6] = b"\0\0"
    part[4:6] = struct.pack(">H", ~checksum(part) & 0xFFFF)
    nv[OF_OFF:OF_OFF + OF_SIZE] = part


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    if a[0] == "fromlog" and len(a) >= 3:
        until = int(a[a.index("--until") + 1]) if "--until" in a else None
        nv, n = from_log(a[1], until)
        open(a[2], "wb").write(nv)
        print("%d NVRAM writes replayed; Open Firmware's partition %s" % (n, "valid" if valid(nv) else "NOT valid"))
        return 0
    if a[0] == "show" and len(a) == 2:
        nv = bytearray(open(a[1], "rb").read())
        if len(nv) != NV_SIZE or not valid(nv):
            print("no valid Open Firmware partition")
            return 1
        for name, v in get_vars(nv):
            print("%-16s %s" % (name, v.replace("\r", "\\r")))
        return 0
    if a[0] == "set" and len(a) >= 4:
        nv = bytearray(open(a[1], "rb").read())
        if len(nv) != NV_SIZE or not valid(nv):
            sys.exit("no valid Open Firmware partition in %s" % a[1])
        for kv in a[3:]:
            name, _, value = kv.partition("=")
            set_var(nv, name, value)
        if not valid(nv):
            sys.exit("the partition came out invalid")
        open(a[2], "wb").write(nv)
        return 0
    if a[0] == "dingus" and len(a) == 3:
        nv = open(a[1], "rb").read()
        if len(nv) != NV_SIZE:
            sys.exit("%s is not an 8 KB image" % a[1])
        # devices/common/nvram.cpp: "DINGUSPPCNVRAM" with its NUL, the size (a
        # little-endian 16-bit word on the machines dingusppc runs on), the data
        open(a[2], "wb").write(b"DINGUSPPCNVRAM\0" + struct.pack("<H", NV_SIZE) + nv)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
