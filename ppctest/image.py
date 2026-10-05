"""Build the bootable test disk image and read results back out of it."""

import json
import struct
import zlib

import harness
import simelf
from layout import *
from vectors import unpack_output, expected_as_output, OUT_FIELDS

H_METABLK, H_METALEN = 0x20, 0x24       # host-only: compressed vector names
H_ELFBLK, H_ELFLEN = 0x34, 0x38         # host-only: the same program as a Linux executable


def _chunks(nrec):
    return -(-nrec // CHUNK_RECS) * CHUNK_BLOCKS


def _pstr(text, size):
    return text.encode("ascii").ljust(size, b"\0")


def _partition_entry(start, count, name, ptype, status, boot_size=0, load=0, processor=""):
    # Apple partition map entry (Inside Macintosh: Devices), 512 bytes
    e = struct.pack(">2sHIII", b"PM", 0, 2, start, count)
    e += _pstr(name, 32) + _pstr(ptype, 32)
    e += struct.pack(">IIIIIIIIII", 0, count, status,
                     0, boot_size, load, 0, load, 0, 0)    # boot block at logical 0
    e += _pstr(processor, 16)
    return e.ljust(BLOCK, b"\0")


def _disk(blocks_needed, code, min_mb):
    """Blank bootable disk: partition map plus the given boot code."""
    total = max(blocks_needed, min_mb * 1024 * 1024 // BLOCK)
    total = -(-total // 2048) * 2048                      # whole megabytes
    img = bytearray(total * BLOCK)

    # block 0: driver descriptor record; blocks 1-2: partition map.
    # The names, types, status values and the 0x4000 load address are the
    # ones NetBSD/macppc's installboot writes for its "partition zero"
    # bootstrap, which Open Firmware 1.0.5 is known to boot.
    img[0:BLOCK] = struct.pack(">2sHI", b"ER", BLOCK, total).ljust(BLOCK, b"\0")
    img[BLOCK:2 * BLOCK] = _partition_entry(1, 2, "Apple", "Apple_partition_map", 0x37)
    img[2 * BLOCK:3 * BLOCK] = _partition_entry(
        PART_START, total - PART_START, "NetBSD", "NetBSD/macppc", 0x3B,
        boot_size=BOOT_MAX, load=0x4000, processor="PowerPC")
    img[BOOT_BLK * BLOCK:BOOT_BLK * BLOCK + len(code)] = code
    return img


def build_romdump(addr=0xFFC00000, size=0x400000, min_mb=8):
    """Disk that copies `size` bytes of physical memory at `addr` onto itself."""
    if size % 4096:
        raise ValueError("size must be a multiple of 4096")
    code = harness.build_romdump()
    img = _disk(VEC_BLK + size // BLOCK, code, min_mb)
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    struct.pack_into(">2I", hdr, H_VERSION, VERSION, zlib.crc32(code))
    struct.pack_into(">3I", hdr, H_ROMBLK, VEC_BLK, addr, size)
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    return bytes(img)


class RomDump:
    """A ROM-dump disk, before or after it has run."""

    def __init__(self, data):
        hdr = data[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK]
        w = lambda off: struct.unpack_from(">I", hdr, off)[0]
        if hdr[0:8] != MAGIC or not w(H_ROMLEN):
            raise ValueError("not a ppctest ROM-dump image")
        self.addr, self.size = w(H_ROMADDR), w(H_ROMLEN)
        self.done = w(H_DONE) == DONE
        self.sum, self.wrfail, self.pvr, self.sim = w(H_SUM), w(H_WRFAIL), w(H_PVR), w(H_SIM)
        self.path = hdr[H_PATH:H_PATH + H_PATH_LEN].split(b"\0")[0].decode("ascii", "replace")
        start = w(H_ROMBLK) * BLOCK
        self.rom = data[start:start + self.size]

    def checksum(self):
        return harness.checksum(struct.unpack(">%dI" % (self.size // 4), self.rom))


def old_world_rom_info(rom):
    """(stored checksum, computed checksum, version) for a 4 MB Old World ROM,
    using the rule dingusppc's machinefactory.cpp applies."""
    stored = struct.unpack_from(">I", rom, 0)[0]
    n = min(len(rom) - 4, 0x2FFFFC)
    computed = sum(struct.unpack_from(">%dH" % (n // 2), rom, 4)) & 0xFFFFFFFF
    version = (struct.unpack_from(">H", rom, 8)[0] << 16) | struct.unpack_from(">H", rom, 0x12)[0]
    return stored, computed, version


def build(vectors, min_mb=8):
    """Return the image as bytes."""
    n = len(vectors)
    area = _chunks(n)
    vec_blk, exp_blk, res_blk = VEC_BLK, VEC_BLK + area, VEC_BLK + 2 * area
    meta_blk = VEC_BLK + 3 * area

    names = sorted({v.name for v in vectors})
    srcs = sorted({v.src for v in vectors})
    ni, si = {x: i for i, x in enumerate(names)}, {x: i for i, x in enumerate(srcs)}
    meta = zlib.compress(json.dumps({
        "names": names, "srcs": srcs,
        "name": [ni[v.name] for v in vectors], "src": [si[v.src] for v in vectors],
    }, separators=(",", ":")).encode())

    code = harness.build()
    runner = simelf.build(code)
    elf_blk = meta_blk + -(-len(meta) // BLOCK)
    img = _disk(elf_blk + -(-len(runner) // BLOCK), code, min_mb)

    inputs = b"".join(v.pack_input() for v in vectors)
    expect = b"".join(v.pack_expected() for v in vectors)
    build_id = zlib.crc32(code + inputs + expect)
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    struct.pack_into(">7I", hdr, H_VERSION, VERSION, build_id, n, vec_blk, res_blk, exp_blk,
                     meta_blk)
    struct.pack_into(">I", hdr, H_METALEN, len(meta))
    struct.pack_into(">2I", hdr, H_ELFBLK, elf_blk, len(runner))
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    img[vec_blk * BLOCK:vec_blk * BLOCK + len(inputs)] = inputs
    img[exp_blk * BLOCK:exp_blk * BLOCK + len(expect)] = expect
    img[meta_blk * BLOCK:meta_blk * BLOCK + len(meta)] = meta
    img[elf_blk * BLOCK:elf_blk * BLOCK + len(runner)] = runner
    return bytes(img)


class Image:
    """A built (and possibly executed) test disk."""

    def __init__(self, data):
        self.data = data
        hdr = data[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK]
        if hdr[0:8] != MAGIC:
            raise ValueError("not a ppctest image (bad magic in block %d)" % HDR_BLK)
        w = lambda off: struct.unpack_from(">I", hdr, off)[0]
        if w(H_ROMLEN):
            raise ValueError("this is a ROM-dump image; use `ppctest.py rom-extract`")
        self.build_id, self.nvec = w(H_BUILD), w(H_NVEC)
        self.vec_blk, self.res_blk, self.exp_blk = w(H_VECBLK), w(H_RESBLK), w(H_EXPBLK)
        self.done = w(H_DONE) == DONE
        self.sum, self.nmiss, self.wrfail = w(H_SUM), w(H_NMISS), w(H_WRFAIL)
        self.pvr, self.msr, self.hid0 = w(H_PVR), w(H_MSR), w(H_HID0)
        self.sim, self.nrun = w(H_SIM), w(H_NRUN)
        self.path = hdr[H_PATH:H_PATH + H_PATH_LEN].split(b"\0")[0].decode("ascii", "replace")
        self.miss = list(struct.unpack_from(">%dI" % H_MISS_MAX, hdr, H_MISS))
        raw = data[w(H_METABLK) * BLOCK:w(H_METABLK) * BLOCK + w(H_METALEN)]
        meta = json.loads(zlib.decompress(raw))
        self.names = [meta["names"][i] for i in meta["name"]]
        self.srcs = [meta["srcs"][i] for i in meta["src"]]
        self.elf_blk, self.elf_len = w(H_ELFBLK), w(H_ELFLEN)

    def linux_runner(self):
        return self.data[self.elf_blk * BLOCK:self.elf_blk * BLOCK + self.elf_len]

    def _rec(self, blk, i):
        off = blk * BLOCK + i * REC
        return self.data[off:off + REC]

    def input(self, i):
        v = struct.unpack(">2I4I4I3Q", self._rec(self.vec_blk, i))
        keys = ("insn", "flags", "r3", "r4", "r5", "r6", "cr", "xer", "ctr", "fpscr",
                "f4", "f5", "f6")
        return dict(zip(keys, v))

    def expected(self, i):
        if not self.input(i)["flags"] & F_HAS_EXPECTED:
            return None
        return unpack_output(self._rec(self.exp_blk, i))

    def result(self, i):
        return unpack_output(self._rec(self.res_blk, i))

    def result_checksum(self):
        words = struct.unpack_from(">%dI" % (self.nvec * REC // 4), self.data,
                                   self.res_blk * BLOCK)
        return harness.checksum(words)

    def expected_checksum(self):
        """Checksum the target would print if every vector with an expectation
        matched it; None when some vectors have no expectation."""
        words = []
        for i in range(self.nvec):
            if not self.input(i)["flags"] & F_HAS_EXPECTED:
                return None
            words += struct.unpack(">16I", self._rec(self.exp_blk, i))
        return harness.checksum(words)


def fmt(field, value):
    return ("%016X" if field.startswith("f") and field != "fpscr" else "%08X") % value
