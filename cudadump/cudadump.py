#!/usr/bin/env python3
"""Read Cuda's firmware out of a Power Macintosh through the VIA.

  cudadump.py build  [--out TO_CARD/HD50_512_cudadump_v1.hda]
  cudadump.py decode IMAGE [--save DIR] [--mame cuda.zip]
  cudadump.py qemu   IMAGE [--machine g3beige|mac99]

`build` makes a bootable disk image for a BlueSCSI (SCSI ID 5 in the file
name; rename for another ID). Booted from Open Firmware with
`boot scsi-int/sd@5:0`, the program on it sends Cuda read-only commands
(READ_MCU_MEM of RAM 0090-01FF and ROM 0B00-1FFF in 256-byte pieces,
GET_REAL_TIME, READ_PRAM) and writes every reply back to the image; `decode`
then names the firmware. `qemu` boots the same image under QEMU's OpenBIOS
(Windows), which proves the boot path, the VIA search and the handshake
against a second Cuda model: QEMU's Cuda knows no READ_MCU_MEM and OpenBIOS
cannot write a disk, so there the console line is the whole result.

Nothing on the Mac is changed: the program only reads from Cuda and only
writes to its own disk.
"""

import argparse
import datetime
import os
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "ppctest"))

import image                                  # noqa: E402  (ppctest's disk envelope)
from cudalayout import *                      # noqa: E402
import program                                # noqa: E402

LOCAL_FW = os.path.join(HERE, "..", "rtl", "machine", "cuda", "341s0060.bin")
MAME_ZIP = os.path.join(HERE, "..", "..", "retrobios", "bios", "Arcade", "MAME", "cuda.zip")

# MAME's dumps (src/mame/apple/cuda.cpp): file, what, where it sits, CRC32
MAME_ROMS = [
    ("341s0417", "Cuda 2.35 (68HC05E1)", 0x0F00, 0x1100, 0x571F24C9),
    ("341s0788", "Cuda 2.37 (68HC05E1)", 0x0F00, 0x1100, 0xDF6E1B43),
    ("341s0789", "Cuda 2.38 (68HC05E1)", 0x0F00, 0x1100, 0x682D2ACE),
    ("341s0060", "Cuda 2.40 (68HC05E1)", 0x0F00, 0x1100, 0x0F5E7B4A),
    ("341s0262", "Cuda 3.02 (68HC05E5)", 0x0B00, 0x1500, 0xF43A803D),
    ("341s0285", "Cuda Lite (68HC05E5)", 0x0C00, 0x1400, 0xBA2707DA),
]
MCU_SIZE = 0x2000
# OpenBIOS: partition map entry 2 is ours, %BOOT asks for its raw boot code
QEMU_BOOT = "boot hd:2,%BOOT"
PVR_NAMES = {1: "601", 3: "603", 4: "604", 6: "603e", 7: "603ev", 8: "750", 9: "604e", 10: "604ev",
             12: "7400", 0x8000: "7450", 0x8001: "7455"}


class Job:
    """A packet to send and how many reply bytes to take."""

    def __init__(self, name, pkt, max_reply, tag=0):
        if not 1 <= len(pkt) <= J_PKT_MAX:
            raise ValueError("packet length")
        if max_reply > R_DATA_MAX:
            raise ValueError("reply longer than a result block holds")
        self.name, self.pkt, self.max_reply, self.tag = name, bytes(pkt), max_reply, tag

    def pack(self):
        raw = bytearray(J_SIZE)
        raw[J_LEN] = len(self.pkt)
        raw[J_PKT:J_PKT + len(self.pkt)] = self.pkt
        struct.pack_into(">HI", raw, J_MAX, self.max_reply, self.tag)
        return bytes(raw)

    @classmethod
    def unpack(cls, raw):
        n = raw[J_LEN]
        mx, tag = struct.unpack_from(">HI", raw, J_MAX)
        pkt = bytes(raw[J_PKT:J_PKT + n])
        return cls(describe_packet(pkt), pkt, mx, tag)

    @property
    def mcu_addr(self):
        """The address a READ_MCU_MEM job reads, else None."""
        if len(self.pkt) == 4 and self.pkt[0] == 1 and self.pkt[1] == 2:
            return self.pkt[2] << 8 | self.pkt[3]
        return None


def describe_packet(pkt):
    if len(pkt) >= 2 and pkt[0] == 1:
        names = {0x02: "READ_MCU_MEM", 0x03: "GET_REAL_TIME", 0x07: "READ_PRAM"}
        name = names.get(pkt[1], "pseudo %02X" % pkt[1])
        if len(pkt) == 4:
            name += " %02X%02X" % (pkt[2], pkt[3])
        return name
    return "packet " + " ".join("%02X" % b for b in pkt)


def default_jobs():
    """Only reads: the clock, RAM 0090-01FF (PRAM is 0100-01FF), ROM 0B00-1FFF
    (a 68HC05E1's ROM is 0F00-1FFF, a 68HC05E5's 0B00-1FFF), PRAM through
    READ_PRAM as a cross-check, the clock again. Never 0000-008F: on an E5
    some registers there change when read."""
    jobs = [Job("GET_REAL_TIME", [1, 3], 8)]

    def mem(addr, n):
        jobs.append(Job("READ_MCU_MEM %04X" % addr, [1, 2, addr >> 8, addr & 0xFF], 3 + n, addr))

    mem(0x0090, 0x100)
    mem(0x0190, 0x070)
    for addr in range(0x0B00, 0x2000, 0x100):
        mem(addr, 0x100)
    jobs.append(Job("READ_PRAM 0000", [1, 7, 0, 0], 3 + 0x100, 0x10000))
    jobs.append(Job("GET_REAL_TIME", [1, 3], 8))
    return jobs


# --- build ---------------------------------------------------------------------------------
def build(jobs=None):
    """The image as bytes, its build id, the two stages' sizes."""
    jobs = jobs or default_jobs()
    if len(jobs) > JOB_MAX:
        raise ValueError("at most %d jobs" % JOB_MAX)
    s1, s2 = program.build_stage1(), program.build_stage2()
    s2 = s2.ljust(-(-len(s2) // 4096) * 4096, b"\0")          # read in 4 KB pieces
    if len(s2) > S2_MAX_BLKS * BLOCK:
        raise ValueError("second stage too long")
    table = b"".join(j.pack() for j in jobs)
    build_id = zlib.crc32(s1 + s2 + table)
    img = image._disk(END_BLK, s1, 1)                         # ppctest's envelope, 1 MB
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    struct.pack_into(">9I", hdr, H_VERSION, VERSION, build_id, len(jobs), S2_BLK, len(s2),
                     JOB_BLK, RES_BLK, LOG_BLK, LOG_BLKS)
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    img[S2_BLK * BLOCK:S2_BLK * BLOCK + len(s2)] = s2
    img[JOB_BLK * BLOCK:JOB_BLK * BLOCK + len(table)] = table
    return bytes(img), build_id, len(s1), len(s2)


def cmd_build(args):
    data, build_id, n1, n2 = build()
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as fh:
        fh.write(data)
    print("wrote %s: %d KB, build %08X, boot block %d bytes, second stage %d bytes, %d jobs"
          % (args.out, len(data) >> 10, build_id, n1, n2, len(default_jobs())))
    print("Open Firmware:  boot scsi-int/sd@5:0   (rename HD50_... for another SCSI ID)")
    print("QEMU:           python cudadump.py qemu %s" % args.out)


# --- decode ----------------------------------------------------------------------------------
class Dump:
    """A cudadump image, before or after it has run."""

    def __init__(self, data):
        self.data = data
        hdr = data[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK]
        if hdr[0:8] != MAGIC:
            raise ValueError("not a cudadump image (bad magic in block %d)" % HDR_BLK)
        w = lambda off: struct.unpack_from(">I", hdr, off)[0]
        self.version, self.build_id, self.njob = w(H_VERSION), w(H_BUILD), w(H_NJOB)
        self.job_blk, self.res_blk, self.log_blk, self.log_blks = w(H_JOBBLK), w(H_RESBLK), w(H_LOGBLK), w(H_LOGBLKS)
        self.state = w(H_DONE)
        self.done = self.state == DONE
        self.started = self.state == STARTED
        self.pvr, self.msr, self.via, self.how = w(H_PVR), w(H_MSR), w(H_VIA), w(H_HOW)
        self.nok, self.nfail, self.ndisc, self.nbytes = w(H_NOK), w(H_NFAIL), w(H_NDISC), w(H_NBYTES)
        self.sync, self.wrfail, self.blkoff = w(H_SYNC), w(H_WRFAIL), w(H_BLKOFF)
        self.dbat2 = (w(H_DBAT2U), w(H_DBAT2L))
        self.path = hdr[H_PATH:H_PATH + H_PATH_LEN].split(b"\0")[0].decode("ascii", "replace")
        self.jobs = [Job.unpack(data[self.job_blk * BLOCK + i * J_SIZE:self.job_blk * BLOCK + (i + 1) * J_SIZE])
                     for i in range(self.njob)]
        self.results = [self._result(i) for i in range(self.njob)]
        self.log = self._log()

    def _result(self, i):
        raw = self.data[(self.res_blk + i) * BLOCK:(self.res_blk + i + 1) * BLOCK]
        status, n, disc, waits = struct.unpack_from(">4I", raw, 0)
        return dict(status=status, len=n, disc=disc, waits=waits,
                    reply=bytes(raw[R_DATA:R_DATA + min(n, R_DATA_MAX)]))

    def _log(self):
        out = []
        base = self.log_blk * BLOCK
        for i in range(min(self.ndisc, self.log_blks * BLOCK // LOG_ENTRY)):
            raw = self.data[base + i * LOG_ENTRY:base + (i + 1) * LOG_ENTRY]
            n = raw[0]
            out.append((n & 0x7F, bool(n & 0x80), bytes(raw[1:1 + min(n & 0x7F, LOG_DATA_MAX)])))
        return out

    def memory(self):
        """(bytes, read) over the 68HC05's 8 KB: what READ_MCU_MEM returned,
        and which addresses were read."""
        mem, read = bytearray(MCU_SIZE), bytearray(MCU_SIZE)
        for job, res in zip(self.jobs, self.results):
            addr = job.mcu_addr
            r = res["reply"]
            if addr is None or len(r) < 3 or r[0] != 1 or r[2] != 2:
                continue
            for i, b in enumerate(r[3:]):
                if addr + i < MCU_SIZE:
                    mem[addr + i] = b
                    read[addr + i] = 1
        return bytes(mem), bytes(read)

    def replies(self, cmd):
        """Replies to pseudo command `cmd`, as (job, reply) pairs."""
        return [(j, r["reply"]) for j, r in zip(self.jobs, self.results)
                if len(j.pkt) >= 2 and j.pkt[0] == 1 and j.pkt[1] == cmd]


def hexdump(data, base=0, width=16):
    lines = []
    for off in range(0, len(data), width):
        chunk = data[off:off + width]
        text = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        lines.append("  %04X  %-*s  %s" % (base + off, width * 3 - 1, " ".join("%02X" % b for b in chunk), text))
    return "\n".join(lines)


def hexs(data):
    return " ".join("%02X" % b for b in data)


def mac_time(seconds):
    return datetime.datetime(1904, 1, 1) + datetime.timedelta(seconds=seconds)


def describe_reply(job, r):
    if not r:
        return "(nothing)"
    if r[0] == 2:
        codes = {1: "bad packet type", 2: "unknown command", 3: "bad size", 4: "bad parameter", 5: "I2C"}
        return "ERROR packet %s (%s)" % (hexs(r), codes.get(r[1], "code %d" % r[1]) if len(r) > 1 else "")
    if r[0] == 1 and len(r) >= 3:
        head = "%s" % hexs(r[:3])
        body = r[3:]
        if job.pkt[1] == 3 and len(body) >= 4:
            secs = struct.unpack(">I", body[:4])[0]
            return "%s %s -> clock %08X = %s" % (head, hexs(body[:4]), secs, mac_time(secs))
        return "%s + %d bytes" % (head, len(body))
    return hexs(r)


def ranges(read):
    out, start = [], None
    for i, v in enumerate(list(read) + [0]):
        if v and start is None:
            start = i
        elif not v and start is not None:
            out.append((start, i))
            start = None
    return out


def identify(mem, read, mame_zip=None):
    """Lines naming the firmware from the ROM part of the memory image."""
    lines = []
    rom_lo = 0x0B00
    if not all(read[rom_lo:MCU_SIZE]):
        missing = [(a, b) for a, b in ranges(bytes(1 - x for x in read[rom_lo:])) if True]
        lines.append("ROM 0B00-1FFF not completely read: missing %s"
                     % ", ".join("%04X-%04X" % (rom_lo + a, rom_lo + b - 1) for a, b in missing))
    # the copyright and the version words after its NUL (341S0060: ...1FF NUL at 0F35,
    # then 00 10 00 02 00 28)
    rom = mem[rom_lo:]
    at = rom.find(b"(c) 19")
    if at < 0:
        at = rom.find(b"Apple")
    if at >= 0:
        end = rom.find(b"\0", at)
        text = rom[at:end].decode("latin-1")
        lines.append("copyright at %04X: %r" % (rom_lo + at, text))
        if end > 0 and end + 6 <= len(rom):
            w0, major, minor = struct.unpack(">3H", rom[end + 1:end + 7])
            lines.append("version words at %04X: %04X %04X %04X -> version %04X.%04X (%d.%02d)"
                         % (rom_lo + end + 1, w0, major, minor, major, minor, major, minor))
            if (w0, major, minor) == (0x0019, 0x0002, 0x0029):
                lines.append("  (that is dingusppc's emulated Cuda, 2.41 with an empty copyright)")
    elif mem[0x0F00:0x0F07] == bytes([0, 0, 0x19, 0, 2, 0, 0x29]) and all(read[0x0F00:0x0F07]):
        lines.append("no copyright string; 0F00 holds 00 0019 0002 0029: dingusppc's emulated Cuda "
                     "(viacuda.cpp fakes an empty copyright and version 2.41 for a ROM read)")
    else:
        lines.append("no copyright string in 0B00-1FFF")
    # the stretch below a 68HC05E1's ROM
    low = mem[0x0B00:0x0F00]
    if all(read[0x0B00:0x0F00]):
        if len(set(low)) == 1:
            lines.append("0B00-0EFF reads as %02X throughout: not ROM (a 68HC05E1's bus with nothing there)" % low[0])
        else:
            lines.append("0B00-0EFF has %d distinct byte values: code there means a 68HC05E5 (Cuda 3.x)" % len(set(low)))
    # CRCs against MAME's dumps
    matched = None
    for name, what, start, size, crc in MAME_ROMS:
        if not all(read[start:start + size]):
            continue
        got = zlib.crc32(mem[start:start + size])
        hit = got == crc
        lines.append("%04X-%04X CRC32 %08X %s %s (%s, %08X)"
                     % (start, start + size - 1, got, "=" if hit else "!=", name, what, crc))
        if hit:
            matched = (name, what)
    if matched:
        lines.append("=> this is MAME's %s: %s" % matched)
    else:
        lines.append("=> none of MAME's dumps")
    # the firmware built into the core
    if os.path.exists(LOCAL_FW) and all(read[0x0F00:0x2000]):
        local = open(LOCAL_FW, "rb").read()
        part = mem[0x0F00:0x0F00 + len(local)]
        diff = sum(1 for x, y in zip(part, local))
        ndiff = sum(1 for x, y in zip(part, local) if x != y)
        lines.append("against the core's %s: %s" % (os.path.relpath(LOCAL_FW, HERE),
                     "identical" if ndiff == 0 else "%d of %d bytes differ" % (ndiff, diff)))
    # the MAME files themselves, when the archive is there
    zpath = mame_zip or (MAME_ZIP if os.path.exists(MAME_ZIP) else None)
    if zpath and os.path.exists(zpath):
        try:
            with zipfile.ZipFile(zpath) as z:
                for name, what, start, size, crc in MAME_ROMS:
                    fn = name + ".bin"
                    if fn in z.namelist() and all(read[start:start + size]):
                        ref = z.read(fn)
                        ndiff = sum(1 for x, y in zip(mem[start:start + size], ref) if x != y)
                        lines.append("against %s in %s: %s" % (fn, os.path.basename(zpath),
                                     "identical" if ndiff == 0 and len(ref) == size
                                     else "%d bytes differ" % ndiff))
        except (OSError, zipfile.BadZipFile) as ex:
            lines.append("could not read %s: %s" % (zpath, ex))
    return lines


def cmd_decode(args):
    data = open(args.image, "rb").read()
    d = Dump(data)
    cpu = PVR_NAMES.get(d.pvr >> 16, "PVR %08X" % d.pvr)
    print("cudadump image, build %08X, %d jobs" % (d.build_id, d.njob))
    if not (d.done or d.started):
        print("the program has not run on this image")
        return 1
    print("run: %s on a %s (PVR %08X), entry MSR %08X, boot path %r"
          % ("finished" if d.done else "STARTED BUT NOT FINISHED", cpu, d.pvr, d.msr, d.path))
    print("VIA at %08X (%s), DBAT2 was %08X/%08X, block offset %d"
          % (d.via, {HOW_TREE: "device tree: via-cuda reg + parent's assigned-addresses",
                     HOW_AAPL: "AAPL,address", HOW_DEFAULT: "DEFAULT, nothing found"}.get(d.how, "?"),
             d.dbat2[0], d.dbat2[1], d.blkoff))
    if d.done:
        print("sync %s; %d jobs ok, %d failed; %d unsolicited packets discarded; %d reply bytes; write %s"
              % (SYNC_NAMES.get(d.sync, d.sync), d.nok, d.nfail, d.ndisc, d.nbytes,
                 "FAILED somewhere" if d.wrfail else "ok"))
    print()
    print(" job  packet         status                    reply")
    for i, (job, res) in enumerate(zip(d.jobs, d.results)):
        if not d.done and not res["len"] and not res["status"]:
            continue
        print(" %3d  %-13s  %-24s  %s" % (i, hexs(job.pkt), ST_NAMES.get(res["status"], res["status"]),
                                          describe_reply(job, res["reply"])))
    if d.log:
        print()
        print("unsolicited packets read and discarded:")
        for n, bad, body in d.log:
            print("  %d bytes%s: %s" % (n, " (timed out)" if bad else "", hexs(body)))
    mem, read = d.memory()
    print()
    print("Cuda memory read: " + ", ".join("%04X-%04X" % (a, b - 1) for a, b in ranges(read)))
    for job, r in d.replies(3):
        pass
    clocks = [struct.unpack(">I", r[3:7])[0] for j, r in d.replies(3) if len(r) >= 7 and r[0] == 1]
    if len(clocks) >= 2:
        print("clock: %s at the start, %s at the end (%d s for the dump)"
              % (mac_time(clocks[0]), mac_time(clocks[-1]), clocks[-1] - clocks[0]))
    if all(read[0x00AB:0x00AF]):
        secs = struct.unpack(">I", mem[0x00AB:0x00AF])[0]
        print("clock in RAM 00AB-00AE: %08X = %s" % (secs, mac_time(secs)))
    if all(read[0x0100:0x0200]):
        print("PRAM (MCU RAM 0100-01FF):")
        print(hexdump(mem[0x0100:0x0200], 0x0100))
        for job, r in d.replies(7):
            if len(r) >= 3 + 0x100 and r[0] == 1:
                same = r[3:3 + 0x100] == mem[0x0100:0x0200]
                print("READ_PRAM 0000 %s MCU memory 0100-01FF" % ("agrees with" if same else "DIFFERS from"))
    print()
    for line in identify(mem, read, args.mame):
        print(line)
    if args.save:
        os.makedirs(args.save, exist_ok=True)
        tag = "%08X" % d.build_id
        saved = []
        for name, start, end in (("cuda_mem_0000-1FFF", 0, MCU_SIZE), ("cuda_rom_0F00", 0x0F00, 0x2000),
                                 ("cuda_rom_0B00", 0x0B00, 0x2000), ("cuda_ram_0090", 0x0090, 0x0200)):
            if all(read[start:end]) or name.startswith("cuda_mem"):
                path = os.path.join(args.save, "%s_%s.bin" % (name, tag))
                with open(path, "wb") as fh:
                    fh.write(mem[start:end])
                saved.append(path)
        path = os.path.join(args.save, "cuda_read_map_%s.bin" % tag)
        with open(path, "wb") as fh:
            fh.write(read)
        saved.append(path)
        print()
        print("saved: " + ", ".join(saved))
        print("(cuda_mem is the whole 8 KB with unread bytes as 00; cuda_read_map marks the bytes read)")
    return 0


def cmd_qemu(args):
    import qemuemu
    qemuemu.run(args.image, [args.boot], args.machine, args.cpu, qemu=args.qemu, timeout=args.timeout,
                log_path=args.log)
    print("(OpenBIOS has no disk write, so nothing lands in the image: the console line above is "
          "the result. QEMU's Cuda answers READ_MCU_MEM and READ_PRAM with error packets, 'E'.)")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--out", default=os.path.join(HERE, "TO_CARD", "HD50_512_cudadump_v%d.hda" % VERSION))
    b.set_defaults(func=cmd_build)
    d = sub.add_parser("decode")
    d.add_argument("image")
    d.add_argument("--save", help="directory for the memory image files")
    d.add_argument("--mame", help="MAME's cuda.zip, to compare byte for byte")
    d.set_defaults(func=cmd_decode)
    q = sub.add_parser("qemu")
    q.add_argument("image")
    q.add_argument("--machine", default="g3beige")
    q.add_argument("--cpu")
    q.add_argument("--qemu")
    q.add_argument("--timeout", type=float, default=120)
    q.add_argument("--log", help="QEMU's own output goes here")
    q.add_argument("--boot", default=QEMU_BOOT, help="what to type at OpenBIOS's prompt")
    q.set_defaults(func=cmd_qemu)
    args = p.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
