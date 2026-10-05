#!/usr/bin/env python3
"""PowerPC CPU test disk: build it, and decode what a real machine wrote back.

  ppctest.py build   [--cpu 604e] [--out HD40_512_ppctest.hda]
  ppctest.py results IMAGE [--csv FILE]
  ppctest.py vector  IMAGE INDEX [INDEX ...]     (indexes are hex, as printed on screen)
  ppctest.py selftest [--cpu 604e] [--qemu-cpu 604]

  ppctest.py rom-build   [--out HD40_512_romdump.hda]   (boot disk that dumps the Mac's ROM)
  ppctest.py rom-extract IMAGE [--out dumped.rom]
  ppctest.py rom-check   FILE                           (verify any 4 MB Old World ROM file)
  ppctest.py rom-selftest
"""

import argparse
import csv
import os
import subprocess
import sys

import image
import simelf
import vectors
from vectors import OUT_FIELDS

HERE = os.path.dirname(os.path.abspath(__file__))
PVR_NAMES = {1: "601", 3: "603", 4: "604", 6: "603e", 7: "603ev", 8: "750 (G3)",
             9: "604e", 10: "604ev"}
IN_FIELDS = ("r3", "r4", "r5", "r6", "cr", "xer", "ctr", "fpscr", "f4", "f5", "f6")


def cmd_build(args):
    vs = vectors.build_set(args.cpu, args.dingus, not args.no_extras)
    if args.no_fp_enables:
        vs = [v for v in vs if not v.fpscr & 0xF8]
    data = image.build(vs)
    with open(args.out, "wb") as fh:
        fh.write(data)
    img = image.Image(data)
    with_exp = sum(1 for v in vs if v.exp is not None)
    print("wrote %s: %d MB, %d vectors for a %s (%d with expected values), build %08X"
          % (args.out, len(data) >> 20, len(vs), args.cpu, with_exp, img.build_id))
    if with_exp == len(vs):
        print("checksum if every vector matches: %08X" % img.expected_checksum())
    blocks = -(-img.elf_len // 512)
    print("Open Firmware:  boot scsi-int/sd@N:0")
    print("Linux (as root, sdX = this disk):")
    print("  dd if=/dev/sdX of=ppctest bs=512 skip=%d count=%d && chmod +x ppctest"
          % (img.elf_blk, blocks))
    print("  ln -sf /dev/sdX sim.hda && ./ppctest")


def describe(img, i):
    inp = img.input(i)
    line = "#%05X %-9s insn=%08X" % (i, img.names[i], inp["insn"])
    used = [f for f in IN_FIELDS if inp[f]]
    return line + "".join(" %s=%s" % (f, image.fmt(f, inp[f])) for f in used)


def report(img, csv_path=None, limit=12, force=False):
    print("build %08X, %d vectors" % (img.build_id, img.nvec))
    if not img.done:
        print("The test program has not written its completion record to this image.")
        print("Either it has not run, it did not finish, or writing to the disk failed.")
        if not force:
            return 2
        print("--force: decoding whatever is in the results area anyway "
              "(checksum of it: %08X)." % img.result_checksum())
        return compare(img, csv_path, limit, 0)
    cpu = "user-mode run (Linux program or simulator), CPU not recorded" if img.sim else "%s, PVR %08X" % (PVR_NAMES.get(img.pvr >> 16, "unknown CPU"),
                                                       img.pvr)
    print("ran on: %s   entry MSR %08X   HID0 %08X   boot device %r"
          % (cpu, img.msr, img.hid0, img.path))
    print("vectors run: %d   checksum printed by target: %08X   target-side mismatches: %d"
          % (img.nrun, img.sum, img.nmiss))
    status = 0
    if img.wrfail:
        print("WARNING: the target reported at least one failed disk write.")
        status = 1
    if img.result_checksum() != img.sum:
        print("WARNING: results on disk do not match the target's checksum (%08X on disk); "
              "the write-back is incomplete or corrupt." % img.result_checksum())
        status = 1

    return compare(img, csv_path, limit, status)


def compare(img, csv_path, limit, status):
    by_name, shown, matched, unknown = {}, 0, 0, 0
    rows = []
    for i in range(img.nvec):
        got, exp = img.result(i), img.expected(i)
        if exp is None:
            unknown += 1
            verdict = "recorded"
        elif got == exp:
            matched += 1
            verdict = "match"
        else:
            verdict = "MISMATCH"
            by_name[img.names[i]] = by_name.get(img.names[i], 0) + 1
            if shown < limit:
                shown += 1
                print("  " + describe(img, i))
                for f in OUT_FIELDS:
                    if got[f] != exp[f]:
                        print("      %-5s expected %s  got %s"
                              % (f, image.fmt(f, exp[f]), image.fmt(f, got[f])))
        if csv_path:
            inp = img.input(i)
            rows.append([i, img.names[i], img.srcs[i], "%08X" % inp["insn"]]
                        + [image.fmt(f, inp[f]) for f in IN_FIELDS]
                        + [image.fmt(f, got[f]) for f in OUT_FIELDS] + [verdict])
    total_bad = sum(by_name.values())
    print("against dingusppc's expected values: %d match, %d differ; %d more recorded "
          "with no expectation" % (matched, total_bad, unknown))
    if total_bad:
        if total_bad > shown:
            print("  (first %d shown above)" % shown)
        print("  differing vectors by instruction: "
              + ", ".join("%s %d" % kv for kv in sorted(by_name.items(), key=lambda kv: -kv[1])))
    if csv_path:
        with open(csv_path, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["index", "name", "source", "insn"] + ["in_" + f for f in IN_FIELDS]
                       + ["out_" + f for f in OUT_FIELDS] + ["verdict"])
            w.writerows(rows)
        print("all results written to %s" % csv_path)
    return status


def cmd_results(args):
    with open(args.image, "rb") as fh:
        img = image.Image(fh.read())
    csv_path = args.csv
    if csv_path is None and img.done:
        csv_path = "results_%s.csv" % ("sim" if img.sim else "%08X" % img.pvr)
    if csv_path is None and args.force:
        csv_path = "results_forced.csv"
    sys.exit(report(img, csv_path, force=args.force))


def cmd_vector(args):
    with open(args.image, "rb") as fh:
        img = image.Image(fh.read())
    for text in args.index:
        i = int(text, 16)
        if i >= img.nvec:
            print("#%X: no such vector (image has %X)" % (i, img.nvec))
            continue
        print(describe(img, i))
        exp = img.expected(i)
        if exp is None:
            print("      no expected values for this vector")
        else:
            print("      expected " + " ".join("%s=%s" % (f, image.fmt(f, exp[f])) for f in OUT_FIELDS))


def rom_report(rom):
    stored, computed, version = image.old_world_rom_info(rom)
    ok = stored == computed and len(rom) == 0x400000
    print("%d bytes; ROM checksum stored %08X, computed %08X; version %04x.%04x"
          % (len(rom), stored, computed, version >> 16, version & 0xFFFF))
    print("This is a self-consistent 4 MB Old World ROM." if ok else
          "This does NOT look like an intact 4 MB Old World ROM.")
    return ok


def cmd_rom_build(args):
    data = image.build_romdump(int(args.addr, 16), int(args.size, 16))
    with open(args.out, "wb") as fh:
        fh.write(data)
    print("wrote %s: %d MB; dumps %s bytes from physical address %s"
          % (args.out, len(data) >> 20, args.size, args.addr))


def cmd_rom_extract(args):
    with open(args.image, "rb") as fh:
        dump = image.RomDump(fh.read())
    if not dump.done:
        print("The dump program has not written its completion record to this image.")
        sys.exit(2)
    print("dumped on PVR %08X from boot device %r" % (dump.pvr, dump.path))
    if dump.wrfail or dump.checksum() != dump.sum:
        print("WARNING: write failure reported or checksum mismatch (target %08X, disk %08X); "
              "the dump is not trustworthy." % (dump.sum, dump.checksum()))
        sys.exit(1)
    print("transfer checksum matches (%08X)" % dump.sum)
    with open(args.out, "wb") as fh:
        fh.write(dump.rom)
    print("wrote %s" % args.out)
    sys.exit(0 if rom_report(dump.rom) else 1)


def cmd_rom_check(args):
    with open(args.file, "rb") as fh:
        sys.exit(0 if rom_report(fh.read()) else 1)


def run_sim(work):
    qemu = ["qemu-ppc-static", "-cpu", "604", "./sim.elf"]
    if os.name == "nt":
        cmd = ["wsl", "--cd", work, "--"] + qemu
    else:
        os.chmod(os.path.join(work, "sim.elf"), 0o755)
        cmd = qemu
    run = subprocess.run(cmd, cwd=work, capture_output=True, timeout=600)
    print("--- console output (exit code %d) ---" % run.returncode)
    print(run.stdout.decode("ascii", "replace").strip())


def cmd_rom_selftest(args):
    import harness
    work = os.path.join(HERE, "_sim")
    os.makedirs(work, exist_ok=True)
    code = harness.build_romdump()
    size = 0x8000                                   # the program's own memory
    with open(os.path.join(work, "sim.hda"), "wb") as fh:
        fh.write(image.build_romdump(simelf.BASE + simelf.HARNESS_OFF, size))
    with open(os.path.join(work, "sim.elf"), "wb") as fh:
        fh.write(simelf.build(code))
    run_sim(work)
    with open(os.path.join(work, "sim.hda"), "rb") as fh:
        dump = image.RomDump(fh.read())
    good = (dump.done and not dump.wrfail and dump.checksum() == dump.sum
            and dump.rom[:1024] == code[:1024])
    print("done=%s write_failed=%d checksum target %08X / disk %08X, first 1024 bytes %s"
          % (dump.done, dump.wrfail, dump.sum, dump.checksum(),
             "match the program" if dump.rom[:1024] == code[:1024] else "DIFFER"))
    sys.exit(0 if good else 1)


def cmd_selftest(args):
    work = os.path.join(HERE, "_sim")
    os.makedirs(work, exist_ok=True)
    vs = vectors.build_set(args.cpu, args.dingus, not args.no_extras)
    # QEMU's user-mode emulation always traps enabled FP exceptions (it has no
    # MSR[FE0/FE1] to turn them off), so those vectors cannot run here.
    kept = [v for v in vs if not v.fpscr & 0xF8]
    print("simulating %d vectors (%d with FP exceptions enabled left out)"
          % (len(kept), len(vs) - len(kept)))
    vs = kept
    hda, elf = os.path.join(work, "sim.hda"), os.path.join(work, "sim.elf")
    data = image.build(vs)
    with open(hda, "wb") as fh:
        fh.write(data)
    with open(elf, "wb") as fh:
        fh.write(image.Image(data).linux_runner())      # as `dd` would extract it
    qemu = ["qemu-ppc-static", "-cpu", args.qemu_cpu, "./sim.elf"]
    if os.name == "nt":
        cmd = ["wsl", "--cd", work, "--"] + qemu
    else:
        os.chmod(elf, 0o755)
        cmd = qemu
    print("running: " + " ".join(cmd))
    run = subprocess.run(cmd, cwd=work, capture_output=True, timeout=600)
    out = run.stdout.decode("ascii", "replace")
    print("--- console output of the test program (exit code %d) ---" % run.returncode)
    print(out.strip())
    err = "\n".join(l for l in run.stderr.decode("utf-8", "replace").replace("\0", "").splitlines()
                    if l.strip() and "Failed to mount" not in l)
    if err:
        print("--- stderr ---\n" + err)
    print("--- decoded from the disk image ---")
    with open(hda, "rb") as fh:
        img = image.Image(fh.read())
    sys.exit(report(img, os.path.join(work, "results_sim.csv")))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--cpu", default="604e", choices=vectors.CPUS,
                        help="CPU the disk will run on (decides which instructions are safe)")
        sp.add_argument("--dingus", default=vectors.DINGUS_DEFAULT,
                        help="directory holding dingusppc's ppcinttests.csv / ppcfloattests.csv")
        sp.add_argument("--no-extras", action="store_true",
                        help="only dingusppc's vectors, all of which have expected values")

    b = sub.add_parser("build"); common(b)
    b.add_argument("--out", default="HD40_512_ppctest.hda")
    b.add_argument("--no-fp-enables", action="store_true",
                   help="leave out vectors that set FPSCR exception-enable bits")
    b.set_defaults(fn=cmd_build)
    r = sub.add_parser("results")
    r.add_argument("image"); r.add_argument("--csv")
    r.add_argument("--force", action="store_true",
                   help="decode the results area even without a completion record")
    r.set_defaults(fn=cmd_results)
    v = sub.add_parser("vector")
    v.add_argument("image"); v.add_argument("index", nargs="+")
    v.set_defaults(fn=cmd_vector)
    s = sub.add_parser("selftest"); common(s)
    s.add_argument("--qemu-cpu", default="604")
    s.set_defaults(fn=cmd_selftest)
    rb = sub.add_parser("rom-build")
    rb.add_argument("--out", default="HD40_512_romdump.hda")
    rb.add_argument("--addr", default="FFC00000", help="physical address, hex")
    rb.add_argument("--size", default="400000", help="bytes, hex, multiple of 0x1000")
    rb.set_defaults(fn=cmd_rom_build)
    rx = sub.add_parser("rom-extract")
    rx.add_argument("image"); rx.add_argument("--out", default="dumped.rom")
    rx.set_defaults(fn=cmd_rom_extract)
    rc = sub.add_parser("rom-check")
    rc.add_argument("file")
    rc.set_defaults(fn=cmd_rom_check)
    rs = sub.add_parser("rom-selftest")
    rs.set_defaults(fn=cmd_rom_selftest)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
