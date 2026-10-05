#!/usr/bin/env python
"""Read and edit Open Firmware variables in an Old World Power Mac NVRAM image.

  ofnvram.py show  NVRAM_FILE
  ofnvram.py set   NVRAM_FILE OUT_FILE name=value [name=value ...]

Works on a file (a copy of /dev/nvram, 8192 bytes); it never touches the
device itself. Layout follows dingusppc's devices/common/ofnvram.cpp: the
Open Firmware partition is 0x800 bytes at offset 0x1800, strings are packed
downward from its end. Runs under Python 2.7 and 3.
"""

from __future__ import print_function

import struct
import sys

OFF, SIZE, SIG = 0x1800, 0x800, 0x1275
FLAGS = ["little-endian?", "real-mode?", "auto-boot?", "diag-switch?", "fcode-debug?",
         "oem-banner?", "oem-logo?", "use-nvramrc?"]
INTS = [("real-base", 0x10), ("real-size", 0x14), ("virt-base", 0x18), ("virt-size", 0x1C),
        ("load-base", 0x20), ("pci-probe-list", 0x24), ("screen-#columns", 0x28),
        ("screen-#rows", 0x2C), ("selftest-#megs", 0x30)]
STRS = [("boot-device", 0x34), ("boot-file", 0x38), ("diag-device", 0x3C), ("diag-file", 0x40),
        ("input-device", 0x44), ("output-device", 0x48), ("oem-banner", 0x4C), ("oem-logo", 0x50),
        ("nvramrc", 0x54), ("boot-command", 0x58)]
HERE = 0x185C                      # first byte after the variable table


def checksum(part):
    acc = sum(struct.unpack(">%dH" % (len(part) // 2), bytes(part)))
    return (acc + (acc >> 16)) & 0xFFFF


class OfNvram(object):
    def __init__(self, data):
        if len(data) < OFF + SIZE:
            raise ValueError("file too short for an Old World NVRAM image")
        self.data = bytearray(data)
        p = self.data[OFF:OFF + SIZE]
        sig, version, pages, _, here, top = struct.unpack(">HBBHHH", bytes(p[:10]))
        if sig != SIG or version != 5 or pages * 256 != SIZE:
            raise ValueError("no Open Firmware partition at 0x1800 (sig %04X, version %d, pages %d)"
                             % (sig, version, pages))
        if checksum(p) != 0xFFFF:
            raise ValueError("Open Firmware partition checksum is wrong")
        self.here, self.top = here, top
        flags = struct.unpack(">I", bytes(p[12:16]))[0]
        self.flags = dict((n, bool(flags & (0x80000000 >> i))) for i, n in enumerate(FLAGS))
        self.other_flags = flags & 0x00FFFFFF
        self.ints = dict((n, struct.unpack(">I", bytes(p[o:o + 4]))[0]) for n, o in INTS)
        self.strs = {}
        for name, o in STRS:
            addr, length = struct.unpack(">HH", bytes(p[o:o + 4]))
            if length and not (OFF <= addr and addr + length <= OFF + SIZE):
                raise ValueError("%s points outside the partition" % name)
            self.strs[name] = bytes(p[addr - OFF:addr - OFF + length]) if length else b""

    def show(self):
        for n in FLAGS:
            print("%-16s %s" % (n, "true" if self.flags[n] else "false"))
        for n, _ in INTS:
            print("%-16s %X" % (n, self.ints[n]))
        for n, _ in STRS:
            text = self.strs[n].decode("latin-1")
            if "\r" in text or "\n" in text:
                print("%-16s (%d bytes)" % (n, len(text)))
                for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
                    print("    | " + line)
            else:
                print("%-16s %s" % (n, text))
        print("free space for strings: %d bytes" % (self.top - self.here))

    def set(self, name, value):
        if name in self.flags:
            if value not in ("true", "false"):
                raise ValueError("%s takes true or false" % name)
            self.flags[name] = value == "true"
        elif name in self.ints:
            self.ints[name] = int(value, 16) & 0xFFFFFFFF
        elif name in self.strs:
            self.strs[name] = value.encode("latin-1")
        else:
            raise ValueError("unknown variable " + name)

    def pack(self):
        p = bytearray(self.data[OFF:OFF + SIZE])
        flags = self.other_flags
        for i, n in enumerate(FLAGS):
            if self.flags[n]:
                flags |= 0x80000000 >> i
        p[12:16] = struct.pack(">I", flags)
        for n, o in INTS:
            p[o:o + 4] = struct.pack(">I", self.ints[n])
        if self.here != HERE:
            raise ValueError("unexpected variable-table size (here = %04X)" % self.here)
        for i in range(HERE - OFF, SIZE):
            p[i] = 0
        top = OFF + SIZE
        for n, o in STRS:
            s = self.strs[n]
            top -= len(s)
            if top < HERE:
                raise ValueError("strings do not fit in the partition")
            p[top - OFF:top - OFF + len(s)] = s
            p[o:o + 4] = struct.pack(">HH", top, len(s))
        p[6:10] = struct.pack(">HH", self.here, top)
        p[4:6] = b"\0\0"
        p[4:6] = struct.pack(">H", ~checksum(p) & 0xFFFF)
        out = bytearray(self.data)
        out[OFF:OFF + SIZE] = p
        return bytes(out)


def main(argv):
    if len(argv) >= 3 and argv[1] == "show":
        OfNvram(open(argv[2], "rb").read()).show()
    elif len(argv) >= 5 and argv[1] == "set":
        nv = OfNvram(open(argv[2], "rb").read())
        for item in argv[4:]:
            name, value = item.split("=", 1)
            nv.set(name, value)
        new = nv.pack()
        OfNvram(new).show()                 # re-parse what we are about to hand back
        open(argv[3], "wb").write(new)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
