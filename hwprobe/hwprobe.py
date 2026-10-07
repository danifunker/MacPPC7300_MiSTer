#!/usr/bin/env python3
"""Measure on the real 7300 what the emulators can only guess.

  hwprobe.py build  [--out TO_CARD/HD50_512_hwprobe_v1.hda] [--target-id 6]
                    [--no-mesh] [--no-curio]
  hwprobe.py list   [--target-id 6]
  hwprobe.py decode IMAGE

`build` makes a bootable disk image for a BlueSCSI (SCSI ID 5 in the file
name, as cudadump's; rename for another ID). Booted from Open Firmware with
`boot scsi-int/sd@5:0`, the program on it runs a table of register
operations on Grand Central's devices, timed with the time base, prints the
results on the console and writes them back to the image; `decode` names
and interprets them. `list` shows the operation table.

What it measures (the machine's plan, milestone E, and docs/PPCMac_stubs.md):

- how long an access to the VIA, MESH, Curio and Grand Central's own
  registers takes (1000 reads each);
- the time base's rate against the VIA's timer 2 (783,360 Hz);
- MESH's registers as Open Firmware leaves them, its ID, what bus status 0
  and 1 show after an arbitration and during a selection, whether
  reselection off (0D) sets command done and whether the next command
  clears it, and the selection timeout of an empty ID with the register at
  0x19 and at 0x05 (10 ms units?);
- Curio's registers as left, its part ID (the transfer count's high byte
  after a chip reset, with ENF, and after a DMA no-operation), and the
  selection timeout of an empty ID with the ROM's set-up (clock factor 5,
  timeout A7) and with timeout 10: the chip's clock;
- Grand Central's interrupt events, mask and levels before and after.

The selections go to an ID nobody should answer (--target-id, 6 unless told
otherwise; the BlueSCSI is 5, a 7300's own disk 0 and CD-ROM 3). If a
target does answer, the program resets that bus (RST for 25 us, then a
second's rest) and says so in the results. Nothing else on the Mac is
changed: MESH's interrupt mask, destination ID and synchronous parameters
are put back as they were, Curio is left set up as Mac OS's ROM sets it up,
and the program writes only its own blocks.
"""

import argparse
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "ppctest"))

import image                                  # noqa: E402  (ppctest's disk envelope)
from hwlayout import *                        # noqa: E402
import program                                # noqa: E402

PVR_NAMES = {1: "601", 3: "603", 4: "604", 6: "603e", 7: "603ev", 8: "750", 9: "604e", 10: "604ev",
             12: "7400", 0x8000: "7450", 0x8001: "7455"}

# Grand Central's devices, offsets from its base
MESH, CURIO, VIA = 0x18000, 0x10000, 0x16000
GC_EVENTS, GC_MASK, GC_LEVELS, GC_DMA0_STATUS = 0x20, 0x24, 0x2C, 0x8004
TB_NOMINAL = 12_500_000          # the 7300's bus at 50 MHz, the time base at a quarter


def MR(n):
    return MESH + 0x10 * n


def CR(n):
    return CURIO + 0x10 * n


def VR(n):
    return VIA + 0x200 * n


class Program:
    """The operation table, and a name for every result it makes."""

    def __init__(self):
        self.ops = []         # (op, off, val, arg)
        self.names = []       # one per result
        self.index = {}       # name -> result number

    def _op(self, op, off=0, val=0, arg=0, name=None):
        self.ops.append((op, off & 0xFFFFFFFF, val & 0xFFFFFFFF, arg & 0xFFFFFFFF))
        if name is not None:
            if name in self.index:
                raise ValueError("duplicate result name " + name)
            self.index[name] = len(self.names)
            self.names.append(name)

    def w8(self, off, val):            self._op(OP_W8, off, val)
    def r8(self, off, name):           self._op(OP_R8, off, name=name)
    def w32(self, off, val):           self._op(OP_W32, off, val)
    def r32(self, off, name):          self._op(OP_R32, off, name=name)
    def tb0(self):                     self._op(OP_TB0)
    def tbd(self, name):               self._op(OP_TBD, name=name)
    def poll8(self, off, mask, ticks, name): self._op(OP_POLL8, off, mask, ticks, name)
    def rep8(self, off, n, name):      self._op(OP_REP8, off, 0, n, name)
    def rep32(self, off, n, name):     self._op(OP_REP32, off, 0, n, name)
    def wait(self, ticks):             self._op(OP_WAIT, 0, 0, ticks)
    def w8r(self, off, name):          self._op(OP_W8R, off, self.index[name])

    def skip_unless_timeout(self, body):
        """Run the operations body() makes only if the last result has 0x100
        set (a poll ran out of time)."""
        at = len(self.ops)
        self._op(OP_SKIPEQ, 0, 0x100, 0)
        n0 = len(self.ops)
        body()
        op, _, val, arg = self.ops[at]
        self.ops[at] = (op, len(self.ops) - n0, val, arg)

    def pack(self):
        if len(self.ops) + 1 > OPS_MAX:
            raise ValueError("%d operations, at most %d" % (len(self.ops) + 1, OPS_MAX))
        if len(self.names) > RES_MAX:
            raise ValueError("%d results, at most %d" % (len(self.names), RES_MAX))
        raw = b"".join(struct.pack(">B3xIII", *o) for o in self.ops + [(OP_END, 0, 0, 0)])
        return raw.ljust(OPS_BLKS * BLOCK, b"\0")


def default_program(target_id=6, mesh=True, curio=True):
    p = Program()
    ms = lambda ms_: int(TB_NOMINAL * ms_ / 1000)          # noqa: E731

    # ---- Grand Central's interrupt registers as found -----------------------------------
    p.r32(GC_EVENTS, "gc_events_before")
    p.r32(GC_MASK, "gc_mask_before")
    p.r32(GC_LEVELS, "gc_levels_before")

    # ---- access times: 1000 reads each -----------------------------------------------------
    p.rep8(VR(0), 1000, "via_portb_x1000")
    p.rep8(VR(13), 1000, "via_ifr_x1000")
    p.rep8(MR(14), 1000, "mesh_id_x1000")
    p.rep8(CR(12), 1000, "curio_config3_x1000")
    p.rep32(GC_LEVELS, 1000, "gc_levels_x1000")
    p.rep32(GC_DMA0_STATUS, 1000, "gc_dma0_status_x1000")

    # ---- the time base against the VIA's timer 2 (783,360 Hz): 10 ms --------------------------
    p.w8(VR(8), 0xFF)
    p.tb0()
    p.w8(VR(9), 0xFF)                                       # loads FFFF and starts it
    p.wait(ms(10))
    p.r8(VR(9), "t2_high_a")
    p.r8(VR(8), "t2_low")
    p.r8(VR(9), "t2_high_b")
    p.tbd("t2_window_tb")

    if mesh:
        # ---- MESH as Open Firmware left it (not the FIFO: a read takes a byte) ---------
        for n in range(16):
            if n != 2:
                p.r8(MR(n), "mesh_r%X" % n)

        # ---- arbitration, reselection off, a selection of an empty ID ----------------------
        for rnd, sel_to in ((1, 0x19), (2, 0x05)):
            r = "mesh%d_" % rnd
            p.w8(MR(9), 0x00)                               # no interrupt out of MESH
            p.w8(MR(10), 0x07)                              # clear them all
            p.r8(MR(10), r + "int_cleared")
            p.tb0()
            p.w8(MR(3), 0x01)                               # arbitrate
            p.poll8(MR(10), 0x07, ms(1), r + "arb_int")
            p.tbd(r + "arb_tb")
            for n, what in ((7, "exception"), (8, "error"), (3, "sequence"), (4, "bus0"), (5, "bus1")):
                p.r8(MR(n), r + "arb_" + what)
            p.w8(MR(10), 0x07)
            p.w8(MR(12), target_id)
            p.w8(MR(15), sel_to)
            p.w8(MR(3), 0x0D)                               # reselection off
            p.r8(MR(10), r + "int_after_0D")
            p.r8(MR(3), r + "seq_after_0D")
            p.w8(MR(3), 0x0F)                               # flush FIFO
            p.r8(MR(10), r + "int_after_0F")
            p.tb0()
            p.w8(MR(3), 0x02)                               # select
            p.r8(MR(10), r + "int_right_after_select")
            p.r8(MR(4), r + "sel_bus0")
            p.r8(MR(5), r + "sel_bus1")
            p.poll8(MR(10), 0x06, ms(2000), r + "sel_int")  # an exception or an error

            def reset_mesh_bus():
                p.w8(MR(5), 0x80)                           # RST
                p.wait(ms(0.025))
                p.w8(MR(5), 0x00)
                p.wait(ms(1000))
            p.skip_unless_timeout(reset_mesh_bus)
            p.tbd(r + "sel_tb")
            for n, what in ((10, "int"), (7, "exception"), (8, "error"), (3, "sequence"),
                            (4, "bus0"), (5, "bus1"), (6, "fifo_count")):
                p.r8(MR(n), r + "end_" + what)
            p.w8(MR(10), 0x07)

        # ---- put back what Open Firmware had --------------------------------------------
        p.w8r(MR(12), "mesh_rC")
        p.w8r(MR(13), "mesh_rD")
        p.w8(MR(15), 0x19)
        p.w8(MR(10), 0x07)
        p.w8r(MR(9), "mesh_r9")

    if curio:
        # ---- Curio as left (not the FIFO or the interrupt status: reading them changes them) --
        for n in (0, 1, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15):
            p.r8(CR(n), "curio_r%X" % n)

        # ---- the part ID: the transfer count's high byte -----------------------------------
        p.w8(CR(3), 0x02)                                   # reset chip
        p.w8(CR(3), 0x00)                                   # no operation: takes commands again
        p.w8(CR(11), 0x40)                                  # configuration 2: ENF
        p.r8(CR(14), "curio_id_after_reset")
        p.r8(CR(0), "curio_count_lo_after_reset")
        p.r8(CR(1), "curio_count_mid_after_reset")
        p.w8(CR(3), 0x80)                                   # DMA no-operation
        p.r8(CR(14), "curio_id_after_dma_nop")
        p.r8(CR(0), "curio_count_lo_after_dma_nop")
        p.r8(CR(1), "curio_count_mid_after_dma_nop")
        p.w8(CR(11), 0x80)                                  # as the ROM: then reads the high byte
        p.r8(CR(14), "curio_id_cfg2_80")

        # ---- the ROM's set-up (34F2, FFEB5ED0-FFEB6080), without its bus reset ---------------
        for cmd in (0x02, 0x00, 0x01):
            p.w8(CR(3), cmd)
        for n, v in ((8, 0x47), (11, 0x08), (12, 0x04), (9, 0x05), (5, 0xA7), (7, 0x00)):
            p.w8(CR(n), v)
        p.r8(CR(4), "curio_setup_status")
        p.r8(CR(5), "curio_setup_int_status")

        # ---- a selection with ATN of an empty ID, as the ROM's: identify, READ(6) ---------------
        for rnd, sel_to in ((1, 0xA7), (2, 0x10)):
            r = "curio%d_" % rnd
            p.w8(CR(5), sel_to)
            p.w8(CR(3), 0x01)                               # clear FIFO
            p.w8(CR(4), target_id)
            for b in (0x80, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00):
                p.w8(CR(2), b)
            p.r8(CR(7), r + "fifo_flags_before")
            p.tb0()
            p.w8(CR(3), 0x42)                               # select with ATN
            p.r8(CR(4), r + "status_right_after")
            p.poll8(CR(4), 0x80, ms(2000), r + "status_at_int")

            def reset_curio_bus():
                p.w8(CR(3), 0x03)                           # reset the bus (no interrupt: DISR)
                p.wait(ms(1000))
                p.w8(CR(3), 0x02)
                p.w8(CR(3), 0x00)
            p.skip_unless_timeout(reset_curio_bus)
            p.tbd(r + "sel_tb")
            for n, what in ((6, "seq_step"), (3, "command"), (4, "status"), (7, "fifo_flags"),
                            (5, "int_status")):
                p.r8(CR(n), r + "end_" + what)
        p.w8(CR(3), 0x01)
        p.w8(CR(3), 0x44)                                   # as the ROM ends: enable selection

    # ---- Grand Central's interrupt registers after ------------------------------------------
    p.r32(GC_EVENTS, "gc_events_after")
    p.r32(GC_MASK, "gc_mask_after")
    p.r32(GC_LEVELS, "gc_levels_after")
    return p


# --- build -----------------------------------------------------------------------------------
def build(prog):
    s1, s2 = program.build_stage1(), program.build_stage2()
    s2 = s2.ljust(-(-len(s2) // 4096) * 4096, b"\0")          # read in 4 KB pieces
    if len(s2) > S2_MAX_BLKS * BLOCK:
        raise ValueError("second stage too long")
    table = prog.pack()
    build_id = zlib.crc32(s1 + s2 + table)
    img = image._disk(END_BLK, s1, 1)                         # ppctest's envelope, 1 MB
    hdr = bytearray(BLOCK)
    hdr[0:8] = MAGIC
    struct.pack_into(">7I", hdr, H_VERSION, VERSION, build_id, len(prog.ops) + 1, S2_BLK, len(s2),
                     OPS_BLK, RES_BLK)
    img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK] = hdr
    img[S2_BLK * BLOCK:S2_BLK * BLOCK + len(s2)] = s2
    img[OPS_BLK * BLOCK:OPS_BLK * BLOCK + len(table)] = table
    return bytes(img), build_id, len(s1), len(s2)


def options_from(args):
    return dict(target_id=args.target_id, mesh=not args.no_mesh, curio=not args.no_curio)


def cmd_build(args):
    prog = default_program(**options_from(args))
    img, build_id, n1, n2 = build(prog)
    out = args.out or os.path.join(HERE, "TO_CARD", "HD50_512_hwprobe_v%d.hda" % VERSION)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "wb") as f:
        f.write(img)
    print("%s: %d bytes, build %08X; boot block %d bytes, second stage %d bytes; "
          "%d operations, %d results; selections of ID %d"
          % (out, len(img), build_id, n1, n2, len(prog.ops) + 1, len(prog.names), args.target_id))
    return 0


def cmd_list(args):
    prog = default_program(**options_from(args))
    names = {v: k for k, v in globals().items() if k.startswith("OP_")}
    res = 0
    for i, (op, off, val, arg) in enumerate(prog.ops):
        made = op in (OP_R8, OP_R32, OP_TBD, OP_POLL8, OP_REP8, OP_REP32)
        print("%3d %-10s off %05X val %08X arg %08X%s" % (i, names[op], off, val, arg,
              ("  -> %d %s" % (res, prog.names[res])) if made else ""))
        res += made
    return 0


# --- decode ------------------------------------------------------------------------------------
def decode(img, target_id=6, mesh=True, curio=True):
    hdr = img[HDR_BLK * BLOCK:(HDR_BLK + 1) * BLOCK]
    if hdr[0:8] != MAGIC:
        print("not a hwprobe image")
        return 1
    w = lambda off: struct.unpack_from(">I", hdr, off)[0]          # noqa: E731
    version, build_id, nops = w(H_VERSION), w(H_BUILD), w(H_NOPS)
    done, pvr, msr, gc, nres = w(H_DONE), w(H_PVR), w(H_MSR), w(H_GC), w(H_NRES)
    path = hdr[H_PATH:H_PATH + H_PATH_LEN].split(b"\0")[0].decode("latin-1")
    print("build %08X, version %d, %d operations" % (build_id, version, nops))
    if done not in (DONE, STARTED):
        print("the program never ran (header unchanged)")
        return 1
    print("run: %s; PVR %08X (%s), Open Firmware's MSR %08X, boot path %s"
          % ("finished" if done == DONE else "STARTED BUT DID NOT FINISH", pvr,
             PVR_NAMES.get(pvr >> 16, "?"), msr, path))
    print("Grand Central at %08X (%s); %d results; disk write %s"
          % (gc, {HOW_TREE: "device tree", HOW_AAPL: "AAPL,address", HOW_DEFAULT: "default"}.get(w(H_HOW), "?"),
             nres, "FAILED" if w(H_WRFAIL) else "ok"))
    raw = img[RES_BLK * BLOCK:(RES_BLK + RES_BLKS) * BLOCK]
    values = list(struct.unpack(">%dI" % RES_MAX, raw))[:nres]
    prog = default_program(target_id, mesh, curio)
    r = {}
    for i, v in enumerate(values):
        name = prog.names[i] if i < len(prog.names) else "result%d" % i
        r[name] = v
        print("  %3d %-34s %08X" % (i, name, v))
    interpret(r)
    return 0


def interpret(r):
    print()
    tb_hz = TB_NOMINAL
    if "t2_window_tb" in r:
        hi = r["t2_high_b"] if r["t2_high_a"] != r["t2_high_b"] and r["t2_low"] > 0x80 else r["t2_high_a"]
        counts = 0xFFFF - ((hi << 8) | r["t2_low"])
        if counts > 0:
            tb_hz = 783_360 * r["t2_window_tb"] / counts
            print("time base: %d ticks against %d counts of the VIA's timer 2: %.0f Hz (%.4f MHz; nominal 12.5)"
                  % (r["t2_window_tb"], counts, tb_hz, tb_hz / 1e6))
    us = lambda ticks: ticks / tb_hz * 1e6                        # noqa: E731
    for name, what in (("via_portb_x1000", "VIA port B"), ("via_ifr_x1000", "VIA IFR"),
                       ("mesh_id_x1000", "MESH's ID"), ("curio_config3_x1000", "Curio's configuration 3"),
                       ("gc_levels_x1000", "Grand Central's levels (word)"),
                       ("gc_dma0_status_x1000", "Grand Central's DMA channel 0 status (word)")):
        if name in r:
            print("a read of %-44s %8.1f ns" % (what + ":", us(r[name])))
    for rnd in (1, 2):
        p = "mesh%d_" % rnd
        if p + "sel_tb" not in r:
            continue
        to = 0x19 if rnd == 1 else 0x05
        print("MESH round %d: arbitration %s after %.2f us (exception %02X, sequence %02X, bus 0/1 %02X %02X);"
              % (rnd, "done" if r[p + "arb_int"] & 1 else "NOT done (%03X)" % r[p + "arb_int"],
                 us(r[p + "arb_tb"]), r[p + "arb_exception"], r[p + "arb_sequence"],
                 r[p + "arb_bus0"], r[p + "arb_bus1"]))
        print("  interrupt after 0D %02X (sequence %02X), after 0F %02X, right after select %02X; during selection bus 0/1 %02X %02X"
              % (r[p + "int_after_0D"], r[p + "seq_after_0D"], r[p + "int_after_0F"],
                 r[p + "int_right_after_select"], r[p + "sel_bus0"], r[p + "sel_bus1"]))
        timed_out = r[p + "sel_int"] & 0x100
        print("  selection with the timeout register at %02X: %s after %.2f ms (interrupt %02X, exception %02X, error %02X,"
              " sequence %02X, bus %02X %02X, FIFO count %02X)%s"
              % (to, "no exception" if timed_out else "the exception", us(r[p + "sel_tb"]) / 1000,
                 r[p + "end_int"], r[p + "end_exception"], r[p + "end_error"], r[p + "end_sequence"],
                 r[p + "end_bus0"], r[p + "end_bus1"], r[p + "end_fifo_count"],
                 ": A TARGET ANSWERED, the bus was reset" if timed_out else
                 "; %.2f ms per unit" % (us(r[p + "sel_tb"]) / 1000 / to)))
    if "curio_id_after_reset" in r:
        print("Curio's transfer count high byte: %02X after a chip reset with ENF, %02X after a DMA no-operation,"
              " %02X with configuration 2 at 80 (the ROM's read)"
              % (r["curio_id_after_reset"], r["curio_id_after_dma_nop"], r["curio_id_cfg2_80"]))
    for rnd in (1, 2):
        p = "curio%d_" % rnd
        if p + "sel_tb" not in r:
            continue
        to = 0xA7 if rnd == 1 else 0x10
        ms_ = us(r[p + "sel_tb"]) / 1000
        timed_out = r[p + "status_at_int"] & 0x100
        clock = 8192 * 5 * to / (ms_ / 1000) if ms_ else 0
        print("Curio round %d: timeout register %02X, factor 5: %s after %.2f ms (FIFO flags %02X before; at the end"
              " sequence step %02X, command %02X, status %02X, FIFO flags %02X, interrupt status %02X)%s"
              % (rnd, to, "no interrupt" if timed_out else "the interrupt", ms_, r[p + "fifo_flags_before"],
                 r[p + "end_seq_step"], r[p + "end_command"], r[p + "end_status"], r[p + "end_fifo_flags"],
                 r[p + "end_int_status"],
                 ": A TARGET ANSWERED, the bus was reset" if timed_out else
                 "; as 8192 x 5 x timeout clocks: %.2f MHz" % (clock / 1e6)))
    for when in ("before", "after"):
        if "gc_mask_" + when in r:
            sw = lambda v: struct.unpack("<I", struct.pack(">I", v))[0]   # noqa: E731
            print("Grand Central %s: events %08X, mask %08X, levels %08X (as registers, byte-swapped back)"
                  % (when, sw(r["gc_events_" + when]), sw(r["gc_mask_" + when]), sw(r["gc_levels_" + when])))


def cmd_decode(args):
    with open(args.image, "rb") as f:
        img = f.read()
    return decode(img, **options_from(args))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("build", "list", "decode"):
        s = sub.add_parser(name)
        if name == "decode":
            s.add_argument("image")
        if name == "build":
            s.add_argument("--out")
        s.add_argument("--target-id", type=int, default=6)
        s.add_argument("--no-mesh", action="store_true")
        s.add_argument("--no-curio", action="store_true")
    args = p.parse_args()
    return {"build": cmd_build, "list": cmd_list, "decode": cmd_decode}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
