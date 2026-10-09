"""Build the bootable test disk image and read results back out of it."""

import json
import re
import struct
import zlib

import harness
import simelf
import stage2
import svectors
from layout import *
from vectors import unpack_output, expected_as_output, OUT_FIELDS


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


def _put_runner(img, hdr, code, build_id, raw=False):
    runner = simelf.build(code, build_id, raw)
    struct.pack_into(">2I", hdr, H_ELFBLK, ELF_BLK, len(runner))
    img[ELF_BLK * BLOCK:ELF_BLK * BLOCK + len(runner)] = runner


def linux_commands(program):
    """What to type on the Mac, as root, to run a disk's program under Linux."""
    return ["dd if=/dev/sdX of=%s bs=512 skip=%d count=%d" % (program, ELF_BLK, ELF_MAX_BLKS),
            "chmod +x %s" % program,
            "./%s" % program]


def build_romdump(addr=0xFFC00000, size=0x400000, min_mb=8):
    """Disk that copies `size` bytes of physical memory at `addr` onto itself."""
    if size % 4096:
        raise ValueError("size must be a multiple of 4096")
    code = harness.build_romdump()
    img = _disk(VEC_BLK + size // BLOCK, code, min_mb)
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    build_id = zlib.crc32(code + struct.pack(">2I", addr, size))
    struct.pack_into(">2I", hdr, H_VERSION, VERSION, build_id)
    struct.pack_into(">3I", hdr, H_ROMBLK, VEC_BLK, addr, size)
    _put_runner(img, hdr, code, build_id)
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    return bytes(img)


def parse_status(raw):
    """The Linux wrapper's run status (see layout.py), or None."""
    if len(raw) < LNX_BLKS * BLOCK or struct.unpack_from(">I", raw, L_MAGIC)[0] != LNX_MAGIC:
        return None
    w = lambda off: struct.unpack_from(">I", raw, off)[0]
    n = min(w(L_CPULEN), L_CPUINFO_MAX)
    st = {
        "fpexc_before": w(L_FPEXC0), "fpexc_after": w(L_FPEXC1),
        "set_ret": w(L_SETRET), "set_failed": bool(w(L_SETCR) & 0x10000000),
        "ntrap": w(L_NTRAP), "slot": w(L_SLOT),
        "fatal_sig": w(L_FATALSIG), "fatal_nip": w(L_FATALNIP), "fatal_vec": w(L_FATALVEC),
        "cpuinfo": raw[L_CPUINFO:L_CPUINFO + n].decode("latin-1"),
        "log": [],
    }
    for i in range(min(st["ntrap"], L_LOG_MAX)):
        vec, x = struct.unpack_from(">2I", raw, L_LOG + 8 * i)
        st["log"].append((vec, x >> 16, x & 0xFFFF))
    m = re.search(r"\(pvr\s+([0-9a-fA-F]{4})\s+([0-9a-fA-F]{4})\)", st["cpuinfo"])
    st["pvr"] = int(m.group(1) + m.group(2), 16) if m else 0
    return st


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
        self.status = parse_status(data[(HDR_BLK + 1) * BLOCK:(HDR_BLK + 1 + LNX_BLKS) * BLOCK])

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


def build(vectors, min_mb=8, nslot=NSLOT_MAX, own_slots_always=False, seqs=None, rom=True):
    """Return the image as bytes. nslot: how many runs it has room for.
    own_slots_always: self-test variant, see harness.build. seqs: the
    second stage's sequences (svectors.SVector); rom: give the second stage
    room for a ROM dump."""
    n = len(vectors)
    area = _chunks(n)
    trap_blks = -(-n // (8 * BLOCK))                      # one bit per vector
    if trap_blks * BLOCK > TRAPMAP_MAX:
        raise ValueError("too many vectors for the Linux wrapper's trap bitmap")
    if not 1 <= nslot <= NSLOT_MAX:
        raise ValueError("nslot must be 1..%d" % NSLOT_MAX)
    stride = area + trap_blks
    vec_blk, exp_blk, res_blk = VEC_BLK, VEC_BLK + area, VEC_BLK + 2 * area
    meta_blk = res_blk + (1 + nslot) * stride

    names = sorted({v.name for v in vectors})
    srcs = sorted({v.src for v in vectors})
    ni, si = {x: i for i, x in enumerate(names)}, {x: i for i, x in enumerate(srcs)}
    meta = zlib.compress(json.dumps({
        "names": names, "srcs": srcs,
        "name": [ni[v.name] for v in vectors], "src": [si[v.src] for v in vectors],
    }, separators=(",", ":")).encode())
    end = meta_blk + -(-len(meta) // BLOCK)

    # the second stage: its code (read in 4096-byte chunks), its sequences,
    # one result area per slot, then the ROM dump and its marker block
    s2code = sinputs = b""
    s2_blk = sv_blk = sr_blk = sarea = rom2_blk = 0
    if seqs:
        s2code = stage2.build()
        sinputs = b"".join(v.pack() for v in seqs)
        s2_blk = -(-end // CHUNK_BLOCKS) * CHUNK_BLOCKS
        sv_blk = s2_blk + -(-len(s2code) // 4096) * CHUNK_BLOCKS
        sarea = -(-len(seqs) // SCHUNK_RECS) * CHUNK_BLOCKS
        sr_blk = sv_blk + sarea
        end = sr_blk + nslot * sarea
        if rom:
            rom2_blk = end
            end = rom2_blk + ROM2_BLKS + 1

    code = harness.build(own_slots_always)
    img = _disk(end, code, min_mb)

    inputs = b"".join(v.pack_input() for v in vectors)
    expect = b"".join(v.pack_expected() for v in vectors)
    build_id = zlib.crc32(code + inputs + expect + s2code + sinputs)
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    struct.pack_into(">7I", hdr, H_VERSION, VERSION, build_id, n, vec_blk, res_blk, exp_blk,
                     meta_blk)
    struct.pack_into(">I", hdr, H_METALEN, len(meta))
    struct.pack_into(">5I", hdr, H_AREA, area, stride, trap_blks, nslot, SLOT_BLK)
    if seqs:
        struct.pack_into(">7I", hdr, H_S2BLK, s2_blk, len(s2code), sv_blk, len(seqs), sr_blk, sarea,
                         rom2_blk)
        img[s2_blk * BLOCK:s2_blk * BLOCK + len(s2code)] = s2code
        img[sv_blk * BLOCK:sv_blk * BLOCK + len(sinputs)] = sinputs
    _put_runner(img, hdr, code, build_id, own_slots_always)
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    img[vec_blk * BLOCK:vec_blk * BLOCK + len(inputs)] = inputs
    img[exp_blk * BLOCK:exp_blk * BLOCK + len(expect)] = expect
    img[meta_blk * BLOCK:meta_blk * BLOCK + len(meta)] = meta
    return bytes(img)


class Run:
    """One execution recorded on a test disk. Runs sit in slots 1..; `sim`
    says whether it ran under Linux (with `status`) or from Open Firmware.
    Slot 0 is the single run of a version-1 disk."""

    def __init__(self, img, slot, hdr, status=None, trapmap=b""):
        self.img, self.slot, self.status, self.trapmap = img, slot, status, trapmap
        w = lambda off: struct.unpack_from(">I", hdr, off)[0]
        self.done = w(H_DONE) == DONE
        self.sum, self.nmiss, self.wrfail = w(H_SUM), w(H_NMISS), w(H_WRFAIL)
        self.pvr, self.msr, self.hid0 = w(H_PVR), w(H_MSR), w(H_HID0)
        self.sim, self.nrun = w(H_SIM), w(H_NRUN)
        self.path = hdr[H_PATH:H_PATH + H_PATH_LEN].split(b"\0")[0].decode("ascii", "replace")
        self.miss = list(struct.unpack_from(">%dI" % H_MISS_MAX, hdr, H_MISS))
        self.res_blk = img.res_blk + slot * img.stride
        if not self.pvr and status:
            self.pvr = status["pvr"]                      # from /proc/cpuinfo
        # the second stage (Open Firmware runs only)
        self.s2_done = w(H_S2DONE) == DONE
        self.s2_nrun, self.s2_sum = w(H_S2NRUN), w(H_S2SUM)
        self.s2_flags, self.s2_romsum = w(H_S2FLAGS), w(H_S2ROMSUM)
        self.sres_blk = img.sr_blk + (slot - 1) * img.sstride if img.nsv and slot else 0

    def result(self, i):
        return unpack_output(self.img._rec(self.res_blk, i))

    def result_checksum(self):
        words = struct.unpack_from(">%dI" % (self.img.nvec * REC // 4), self.img.data,
                                   self.res_blk * BLOCK)
        return harness.checksum(words)

    def s2_result(self, i):
        off = self.sres_blk * BLOCK + i * SREC
        return svectors.unpack_output(self.img.data[off:off + SREC])

    def s2_checksum(self):
        words = struct.unpack_from(">%dI" % (self.img.nsv * SREC // 4), self.img.data,
                                   self.sres_blk * BLOCK)
        return harness.checksum(words)

    def trapped(self, i):
        return i // 8 < len(self.trapmap) and bool(self.trapmap[i // 8] & (0x80 >> (i % 8)))


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
        self.version = w(H_VERSION)
        self.build_id, self.nvec = w(H_BUILD), w(H_NVEC)
        self.vec_blk, self.res_blk, self.exp_blk = w(H_VECBLK), w(H_RESBLK), w(H_EXPBLK)
        raw = data[w(H_METABLK) * BLOCK:w(H_METABLK) * BLOCK + w(H_METALEN)]
        meta = json.loads(zlib.decompress(raw))
        self.names = [meta["names"][i] for i in meta["name"]]
        self.srcs = [meta["srcs"][i] for i in meta["src"]]
        self.elf_blk, self.elf_len = w(H_ELFBLK), w(H_ELFLEN)
        if self.version >= 2:
            self.area, self.stride, self.trap_blks = w(H_AREA), w(H_STRIDE), w(H_TRAPBLKS)
            self.nslot, self.slot_blk = w(H_NSLOT), w(H_SLOTBLK)
        else:
            self.area, self.stride, self.trap_blks = _chunks(self.nvec), 0, 0
            self.nslot, self.slot_blk = 0, 0
        self.s2_blk, self.s2_len = w(H_S2BLK), w(H_S2LEN)
        self.sv_blk, self.nsv, self.sr_blk, self.sstride = w(H_SVBLK), w(H_NSV), w(H_SRBLK), w(H_SSTRIDE)
        self.rom2_blk = w(H_ROM2BLK)

        # Slot 0 is described by the main header; only version-1 disks use it.
        self.main = Run(self, 0, hdr)
        self.runs = [self.main] if self.main.done else []
        self.unfinished = []
        for s in range(1, self.nslot + 1):
            at = (self.slot_blk + (s - 1) * SLOT_BLKS) * BLOCK
            shdr = data[at:at + BLOCK]
            if not any(shdr[0:4]):
                continue
            status = parse_status(data[at + BLOCK:at + (1 + LNX_BLKS) * BLOCK])
            tm = (self.res_blk + s * self.stride + self.area) * BLOCK
            run = Run(self, s, shdr, status, data[tm:tm + self.trap_blks * BLOCK])
            (self.runs if run.done else self.unfinished).append(run)

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

    def sinput(self, i):
        off = self.sv_blk * BLOCK + i * SREC
        return svectors.unpack_input(self.data[off:off + SREC])

    def rom2(self):
        """The second stage's ROM dump: a dict with the marker block's fields,
        the 4 MB and their checksum, or None when no run has made one."""
        if not self.rom2_blk:
            return None
        at = (self.rom2_blk + ROM2_BLKS) * BLOCK
        magic, pvr, total, slot, wrfail = struct.unpack_from(">5I", self.data, at)
        if magic != ROM2_MAGIC:
            return None
        rom = self.data[self.rom2_blk * BLOCK:self.rom2_blk * BLOCK + ROM2_BLKS * BLOCK]
        computed = harness.checksum(struct.unpack(">%dI" % (len(rom) // 4), rom))
        return dict(pvr=pvr, sum=total, slot=slot, wrfail=wrfail, rom=rom, computed=computed)

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
