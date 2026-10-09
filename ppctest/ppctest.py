#!/usr/bin/env python3
"""PowerPC CPU test disk: build it, and decode what a real machine wrote back.

  ppctest.py build   [--set v4] [--out HD40_512_ppctest.hda]
  ppctest.py results IMAGE [--name WHAT] [--golden FILE.csv]
  ppctest.py vector  IMAGE INDEX [INDEX ...]     (indexes are hex, as printed on screen)
  ppctest.py diff    A.csv B.csv                 (two results files, vector by vector)
  ppctest.py selftest [--set v4] [--qemu-cpu 604]

  ppctest.py rom-build   [--out HD50_512_romdump.hda]   (disk that dumps the Mac's ROM)
  ppctest.py rom-extract IMAGE [--out dumped.rom]
  ppctest.py rom-check   FILE [FILE2]                   (verify a 4 MB Old World ROM file)
  ppctest.py rom-selftest
"""

import argparse
import csv
import io
import os
import re
import subprocess
import sys

import image
import simelf
import svectors
import vectors
from layout import S2F_ROM_DUMPED, S2F_ROM_PRESENT, S2F_WRFAIL, S2F_SKIPPED, SS_RAN, SS_RECOVERED, SS_SKIPPED
from vectors import OUT_FIELDS, CSV_IN as IN_FIELDS, CSV_COLUMNS

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "runs")
PVR_NAMES = {1: "601", 3: "603", 4: "604", 6: "603e", 7: "603ev", 8: "750 (G3)",
             9: "604e", 10: "604ev"}
PVR_TAGS = {1: "601", 3: "603", 4: "604", 6: "603e", 7: "603ev", 8: "g3", 9: "604e", 10: "604ev"}
FPEXC_MODES = {0: "disabled", 1: "asynchronous, non-recoverable", 2: "asynchronous",
               3: "precise", 0xFFFFFFFF: "not reported"}
SIGNALS = {4: "SIGILL", 5: "SIGTRAP", 7: "SIGBUS", 8: "SIGFPE", 11: "SIGSEGV"}


def load_set(args):
    if args.set == "v3":
        vs = vectors.build_set(args.cpu, args.dingus, not args.no_extras)
    else:
        vs = vectors.build_v4(args.cpu)
    if getattr(args, "no_fp_enables", False):
        vs = [v for v in vs if not v.fpscr & 0xF8]
    return vs


def cmd_build(args):
    vs = load_set(args)
    seqs = None if args.no_stage2 else svectors.build_set()
    data = image.build(vs, nslot=args.slots, seqs=seqs)
    with open(args.out, "wb") as fh:
        fh.write(data)
    img = image.Image(data)
    with_exp = sum(1 for v in vs if v.exp is not None)
    print("wrote %s: %d MB, %d vectors (%d with expected values), build %08X, "
          "room for %d runs" % (args.out, len(data) >> 20, len(vs), with_exp,
                                img.build_id, img.nslot))
    if seqs:
        groups = {}
        for v in seqs:
            groups[v.group] = groups.get(v.group, 0) + 1
        print("second stage (Open Firmware runs only): %d sequences (%s), ROM dump area"
              % (len(seqs), ", ".join("%s %d" % kv for kv in groups.items())))
    if with_exp == len(vs):
        print("checksum if every vector matches: %08X" % img.expected_checksum())
    print("Open Firmware:  boot scsi-int/sd@N:0")
    print("Linux (as root; sdX = this disk):")
    for line in image.linux_commands("p"):
        print("  " + line)


def describe(img, i):
    inp = img.input(i)
    line = "#%05X %-9s insn=%08X" % (i, img.names[i], inp["insn"])
    used = [f for f in IN_FIELDS if inp[f]]
    return line + "".join(" %s=%s" % (f, image.fmt(f, inp[f])) for f in used)


def cpu_text(run):
    if not run.pvr:
        return "CPU not recorded"
    name = PVR_NAMES.get(run.pvr >> 16, "unknown CPU")
    return "%s, PVR %08X%s" % (name, run.pvr, " (from /proc/cpuinfo)" if run.sim else "")


def run_title(run):
    kind = "Linux run" if run.sim else "Open Firmware run"
    return "%s in slot %d" % (kind, run.slot) if run.slot else kind


def cpuinfo_fields(run):
    if not run.status:
        return {}
    out = {}
    for line in run.status["cpuinfo"].splitlines():
        if ":" in line:
            k, v = line.split(":", 1)
            out.setdefault(k.strip(), v.strip())
    return out


def auto_name(run, machine=None):
    cpu = PVR_TAGS.get(run.pvr >> 16, "pvr%04X" % (run.pvr >> 16)) if run.pvr else "unknown"
    if not machine:
        m = re.search(r"AAPL,(\w+)", run.status["cpuinfo"]) if run.status else None
        machine = m.group(1) if m else None
    return cpu + ("_" + machine if machine else "") + ("" if run.sim else "_of")


def load_golden(path):
    """key (name, insn, inputs) -> recorded outputs, from a results CSV."""
    gold = {}
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            key = (r["name"], r["insn"]) + tuple(r["in_" + f] for f in IN_FIELDS)
            gold.setdefault(key, tuple(r["out_" + f] for f in OUT_FIELDS))
    return gold


def report_run(img, run, golden=None, golden_name="", limit=4):
    """Print everything about one run. Returns (status, CSV rows, notes)."""
    notes = ["%s: %s" % (run_title(run), cpu_text(run)),
             "disk %r, image build %08X, %d vectors" % (run.path, img.build_id, img.nvec)]
    print("--- " + notes[0])
    print("    disk %r   entry MSR %08X   HID0 %08X" % (run.path, run.msr, run.hid0))
    status = 0
    if not run.done:
        print("    NOT FINISHED: this run started and never wrote its completion record.")
        status = 1
    else:
        print("    vectors run: %d   checksum %08X   mismatches counted on the Mac: %d (%08X)"
              % (run.nrun, run.sum, run.nmiss, run.nmiss))
        if run.wrfail:
            print("    WARNING: the target reported at least one failed disk write.")
            status = 1
        if run.result_checksum() != run.sum:
            print("    WARNING: results on disk do not match the target's checksum (%08X on "
                  "disk); the write-back is incomplete or corrupt." % run.result_checksum())
            status = 1
    st = run.status
    if st:
        ci = cpuinfo_fields(run)
        shown = [k for k in ("cpu", "revision", "clock", "machine", "motherboard", "detected as")
                 if k in ci]
        if shown:
            line = "    cpuinfo: " + " | ".join("%s: %s" % (k, ci[k]) for k in shown)
            print(line)
            notes.append(line.strip())
        mode = lambda v: "%s" % FPEXC_MODES.get(v, "%08X" % v)
        line = ("    floating-point traps: mode was %s, asked for disabled (%s), now %s"
                % (mode(st["fpexc_before"]),
                   "refused, error %d" % st["set_ret"] if st["set_failed"] else "accepted",
                   mode(st["fpexc_after"])))
        print(line)
        notes.append(line.strip())
        if st["fatal_sig"]:
            line = ("    FATAL: %s at %08X while on vector #%X, outside the instruction under test"
                    % (SIGNALS.get(st["fatal_sig"], "signal %d" % st["fatal_sig"]),
                       st["fatal_nip"], st["fatal_vec"]))
            print(line)
            notes.append(line.strip())
            status = 1
        if st["ntrap"]:
            kinds = {}
            for vec, sig, code in st["log"]:
                kinds[sig] = kinds.get(sig, 0) + 1
            line = ("    %d vectors trapped and were stepped over (of the first %d: %s)"
                    % (st["ntrap"], len(st["log"]),
                       ", ".join("%d %s" % (n, SIGNALS.get(s, "signal %d" % s))
                                 for s, n in sorted(kinds.items()))))
            print(line)
            notes.append(line.strip())
            for vec, sig, code in st["log"][:limit]:
                print("      " + describe(img, vec) + "  [%s code %d]"
                      % (SIGNALS.get(sig, sig), code))

    per, by_name, shown, rows = {}, {}, {}, []
    gold = dict(same=0, differ=0, by_name={}, first=[]) if golden else None
    for i in range(img.nvec):
        got, exp = run.result(i), img.expected(i)
        src, name = img.srcs[i], img.names[i]
        st4 = per.setdefault(src, [0, 0, 0, 0])            # match, differ, recorded, trapped
        if run.trapped(i):
            verdict = "TRAP"
            st4[3] += 1
        elif exp is None:
            verdict = "recorded"
            st4[2] += 1
        elif got == exp:
            verdict = "match"
            st4[0] += 1
        else:
            verdict = "MISMATCH"
            st4[1] += 1
            by_name[(src, name)] = by_name.get((src, name), 0) + 1
            if shown.get(src, 0) < limit:
                shown[src] = shown.get(src, 0) + 1
                print("  " + describe(img, i) + "  [%s]" % src)
                for f in OUT_FIELDS:
                    if got[f] != exp[f]:
                        print("      %-5s expected %s  got %s"
                              % (f, image.fmt(f, exp[f]), image.fmt(f, got[f])))
        inp = img.input(i)
        row = (["%d" % i, name, src, "%08X" % inp["insn"]]
               + [image.fmt(f, inp[f]) for f in IN_FIELDS]
               + [image.fmt(f, got[f]) for f in OUT_FIELDS] + [verdict])
        rows.append(row)
        if gold is not None:
            g = golden.get((name, row[3]) + tuple(row[4:4 + len(IN_FIELDS)]))
            if g is not None:
                if g == tuple(row[4 + len(IN_FIELDS):-1]):
                    gold["same"] += 1
                else:
                    gold["differ"] += 1
                    gold["by_name"][name] = gold["by_name"].get(name, 0) + 1
                    if len(gold["first"]) < limit:
                        gold["first"].append((i, g, row[4 + len(IN_FIELDS):-1]))

    print("    %-14s %7s %7s %7s %7s" % ("source", "match", "DIFFER", "no exp.", "trapped"))
    for src, (m, d, r, t) in per.items():
        line = "    %-14s %7d %7d %7d %7d" % (src, m, d, r, t)
        print(line)
        notes.append(line.strip())
    total_bad = sum(v[1] for v in per.values())
    if total_bad:
        print("    differing vectors by instruction: "
              + ", ".join("%s %d" % (k[1], n)
                          for k, n in sorted(by_name.items(), key=lambda kv: -kv[1])[:24]))
    if gold is not None:
        line = ("    against %s: %d vectors in common, %d identical, %d differ"
                % (golden_name, gold["same"] + gold["differ"], gold["same"], gold["differ"]))
        print(line)
        notes.append(line.strip())
        if gold["differ"]:
            print("      by instruction: " + ", ".join(
                "%s %d" % kv for kv in sorted(gold["by_name"].items(), key=lambda kv: -kv[1])[:24]))
            for i, g, mine in gold["first"]:
                print("      " + describe(img, i))
                for f, a, b in zip(OUT_FIELDS, g, mine):
                    if a != b:
                        print("          %-5s there %s  here %s" % (f, a, b))
    s2status, s2rows = report_stage2(img, run, notes, limit)
    return status | s2status, rows, notes, s2rows


def report_stage2(img, run, notes, limit=4):
    """The second stage's part of a run: summary lines and the sresults rows."""
    if not img.nsv or run.sim or not run.slot:
        return 0, []
    if not run.s2_done:
        line = "    stage 2: no completion record (it did not run, or did not finish)"
        print(line)
        notes.append(line.strip())
        return 1, []
    fl = run.s2_flags
    if fl & S2F_SKIPPED:
        line = "    stage 2: skipped, not a 604/604e/604ev/750"
        print(line)
        notes.append(line.strip())
        return 0, []
    status = 0
    rom = ("dumped the ROM (checksum %08X)" % run.s2_romsum if fl & S2F_ROM_DUMPED else
           "ROM already on the disk" if fl & S2F_ROM_PRESENT else "no ROM area")
    line = "    stage 2: %d sequences run, checksum %08X, %s" % (run.s2_nrun, run.s2_sum, rom)
    print(line)
    notes.append(line.strip())
    if fl & S2F_WRFAIL:
        print("    WARNING: stage 2 reported at least one failed disk write.")
        status = 1
    if run.s2_nrun != img.nsv or run.s2_checksum() != run.s2_sum:
        print("    WARNING: stage 2 results on disk (%d sequences, checksum %08X) do not match its "
              "completion record." % (img.nsv, run.s2_checksum()))
        status = 1
    seqs = svectors.build_set()
    if len(seqs) != img.nsv:
        print("    WARNING: this svectors.py makes %d sequences, the disk holds %d; names may be off."
              % (len(seqs), img.nsv))
    rows, per, by_vec, shown = [], {}, {}, 0
    for i in range(img.nsv):
        inp, out = img.sinput(i), run.s2_result(i)
        sv = seqs[i] if i < len(seqs) else svectors.SVector("#%d" % i, "?", inp["code"])
        rows.append(svectors.csv_row(i, sv, inp, out))
        st = per.setdefault(sv.group, [0, 0, 0, 0])      # ran, with exceptions, abandoned, skipped
        if out["status"] & SS_SKIPPED:
            st[3] += 1
            continue
        st[0] += 1
        if out["nexc"]:
            st[1] += 1
        if out["status"] & SS_RECOVERED:
            st[2] += 1
            if shown < limit and sv.group not in ("sweep", "sprsweep"):
                shown += 1
                print("      abandoned: %s %s" % (sv.group, sv.name))
        for x in out["exc"]:
            by_vec[x["vec"]] = by_vec.get(x["vec"], 0) + 1
    print("    %-10s %7s %7s %9s %7s" % ("group", "ran", "w/exc", "abandoned", "skipped"))
    for g, (n, x, ab, sk) in per.items():
        line = "    %-10s %7d %7d %9d %7d" % (g, n, x, ab, sk)
        print(line)
        notes.append(line.strip())
    line = "    exceptions by vector: " + ", ".join(
        "%04X %d" % kv for kv in sorted(by_vec.items()))
    print(line)
    notes.append(line.strip())
    return status, rows


def csv_text(rows, columns=CSV_COLUMNS):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(columns)
    w.writerows(rows)
    return buf.getvalue()


def save_results(out_dir, name, explicit, rows, notes, s2rows=()):
    """Write results_<name>.csv and a .txt beside it, and sresults_<name>.csv
    when the run has second-stage results. Never overwrites a different file:
    an automatic name gets the next free run number."""
    text = csv_text(rows)
    os.makedirs(out_dir, exist_ok=True)
    n = 1
    while True:
        base = "results_%s" % name if explicit else "results_%s_run%d" % (name, n)
        path = os.path.join(out_dir, base + ".csv")
        if not os.path.exists(path):
            break
        with open(path, newline="") as fh:
            if fh.read() == text:
                print("    results are already saved as %s" % path)
                break
        if explicit:
            print("    %s exists and is different; not overwritten. Choose another --name." % path)
            return None
        n += 1
    if not os.path.exists(path):
        with open(path, "w", newline="") as fh:
            fh.write(text)
        print("    all results written to %s" % path)
    with open(os.path.join(out_dir, base + ".txt"), "w", newline="\n") as fh:
        fh.write("\n".join(notes) + "\n")
    if s2rows:
        spath = os.path.join(out_dir, "s" + base + ".csv")
        stext = csv_text(s2rows, svectors.CSV_COLUMNS)
        if os.path.exists(spath) and open(spath, newline="").read() != stext:
            print("    %s exists and is different; not overwritten." % spath)
        else:
            with open(spath, "w", newline="") as fh:
                fh.write(stext)
            print("    stage 2 results written to %s" % spath)
    return path


def report(img, out_dir=RUNS, name=None, golden_path=None, force=False, slot=None, save=True,
           machine=None):
    print("build %08X, %d vectors, disk format %d" % (img.build_id, img.nvec, img.version))
    runs = list(img.runs)
    if force:
        runs += img.unfinished
        if not img.main.done and not img.nslot:
            runs.append(img.main)
    if slot is not None:
        runs = [r for r in runs if r.slot == slot]
    if not runs:
        print("No finished run is recorded on this image.")
        print("Either the test program has not run, it did not finish, or writing to the "
              "disk failed.")
    for r in img.unfinished:
        print("Slot %d holds a run that started and did not finish%s."
              % (r.slot, "" if force else " (--force decodes what it wrote)"))
    if not runs:
        return 2
    golden = load_golden(golden_path) if golden_path else None
    status = 0
    for run in runs:
        st, rows, notes, s2rows = report_run(img, run, golden,
                                             os.path.basename(golden_path) if golden_path else "")
        status |= st
        if save:
            this = name if name and len(runs) == 1 else (
                "%s_slot%d" % (name, run.slot) if name else auto_name(run, machine))
            save_results(out_dir, this, bool(name), rows, notes, s2rows)
    rom = img.rom2()
    if rom:
        ok = rom["sum"] == rom["computed"] and not rom["wrfail"]
        print("ROM dump on this disk: made by the run in slot %d on PVR %08X, checksum %08X (%s)"
              % (rom["slot"], rom["pvr"], rom["sum"],
                 "matches the data" if ok else "DOES NOT MATCH THE DATA, or a write failed"))
        print("  extract it with: python ppctest.py rom-extract IMAGE --out runs/NAME.rom")
    return status


def cmd_results(args):
    with open(args.image, "rb") as fh:
        img = image.Image(fh.read())
    golden = args.golden
    if golden is None and os.path.exists(vectors.GOLDEN_604):
        golden = vectors.GOLDEN_604
    sys.exit(report(img, args.out_dir, args.name, golden, args.force, args.slot,
                    machine=args.machine))


def cmd_vector(args):
    with open(args.image, "rb") as fh:
        img = image.Image(fh.read())
    for text in args.index:
        i = int(text, 16)
        if i >= img.nvec:
            print("#%X: no such vector (image has %X)" % (i, img.nvec))
            continue
        print(describe(img, i) + "  [%s]" % img.srcs[i])
        exp = img.expected(i)
        if exp is None:
            print("      no expected values for this vector")
        else:
            print("      expected " + " ".join("%s=%s" % (f, image.fmt(f, exp[f])) for f in OUT_FIELDS))


def cmd_diff(args):
    a = load_golden(args.a)
    same = differ = missing = 0
    by_name, first = {}, []
    with open(args.b, newline="") as fh:
        for r in csv.DictReader(fh):
            key = (r["name"], r["insn"]) + tuple(r["in_" + f] for f in IN_FIELDS)
            mine = tuple(r["out_" + f] for f in OUT_FIELDS)
            if key not in a:
                missing += 1
            elif a[key] == mine:
                same += 1
            else:
                differ += 1
                by_name[r["name"]] = by_name.get(r["name"], 0) + 1
                if len(first) < args.show:
                    first.append((r, a[key], mine))
    print("%d vectors in common: %d identical, %d differ; %d of %s are not in %s"
          % (same + differ, same, differ, missing, args.b, args.a))
    if differ:
        print("by instruction: " + ", ".join(
            "%s %d" % kv for kv in sorted(by_name.items(), key=lambda kv: -kv[1])))
    for r, x, y in first:
        print("#%s %-9s insn=%s [%s]" % (r["index"], r["name"], r["insn"], r["source"])
              + "".join(" %s=%s" % (f, r["in_" + f]) for f in IN_FIELDS if int(r["in_" + f], 16)))
        for f, p, q in zip(OUT_FIELDS, x, y):
            if p != q:
                print("      %-5s %s  |  %s" % (f, p, q))
    sys.exit(1 if differ else 0)


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
    print("Open Firmware:  boot scsi-int/sd@N:0")
    print("Linux (as root; sdX = this disk; reads the ROM through /dev/mem):")
    for line in image.linux_commands("r"):
        print("  " + line)


def cmd_rom_extract(args):
    with open(args.image, "rb") as fh:
        data = fh.read()
    try:
        dump = image.RomDump(data)
    except ValueError:
        dump = None
    if dump is None:                                   # a test disk: the second stage's dump
        rom = image.Image(data).rom2()
        if rom is None:
            print("No ROM dump on this image (no run's second stage has made one).")
            sys.exit(2)
        print("dumped by the run in slot %d on PVR %08X" % (rom["slot"], rom["pvr"]))
        if rom["wrfail"] or rom["sum"] != rom["computed"]:
            print("WARNING: write failure reported or checksum mismatch (target %08X, disk %08X); "
                  "the dump is not trustworthy." % (rom["sum"], rom["computed"]))
            sys.exit(1)
        print("transfer checksum matches (%08X)" % rom["sum"])
        with open(args.out, "wb") as fh:
            fh.write(rom["rom"])
        print("wrote %s" % args.out)
        sys.exit(0 if rom_report(rom["rom"]) else 1)
    if not dump.done:
        print("The dump program has not written its completion record to this image.")
        sys.exit(2)
    if dump.sim:
        print("dumped under Linux from disk %r" % dump.path)
        if dump.status:
            for line in dump.status["cpuinfo"].splitlines():
                if line.split(":")[0].strip() in ("cpu", "revision", "machine", "motherboard",
                                                  "detected as"):
                    print("    " + " ".join(line.split()))
    else:
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
        rom = fh.read()
    ok = rom_report(rom)
    if args.other:
        with open(args.other, "rb") as fh:
            other = fh.read()
        print("--- " + args.other)
        ok = rom_report(other) and ok
        if rom == other:
            print("The two files are identical.")
        else:
            n = sum(1 for x, y in zip(rom, other) if x != y) + abs(len(rom) - len(other))
            print("The two files DIFFER in %d bytes." % n)
    sys.exit(0 if ok else 1)


def qemu(work, args, qemu_cpu="604"):
    """Run sim.elf in `work` under qemu's user-mode emulator. Returns (code, stdout, stderr)."""
    cmd = ["qemu-ppc-static", "-cpu", qemu_cpu, "./sim.elf"] + list(args)
    if os.name == "nt":
        cmd = ["wsl", "--cd", work, "--"] + cmd
    else:
        os.chmod(os.path.join(work, "sim.elf"), 0o755)
    run = subprocess.run(cmd, cwd=work, capture_output=True, timeout=1800)
    err = "\n".join(l for l in run.stderr.decode("utf-8", "replace").replace("\0", "").splitlines()
                    if l.strip() and "Failed to mount" not in l)
    return run.returncode, run.stdout.decode("ascii", "replace").strip(), err


def show(code, out, err):
    print("--- console output (exit code %d) ---" % code)
    print(re.sub(r"\.{40,}", lambda m: "[%d dots]" % len(m.group(0)), out))
    if err:
        print("--- stderr ---\n" + err)


def cmd_rom_selftest(args):
    import harness
    work = os.path.join(HERE, "_sim")
    os.makedirs(work, exist_ok=True)
    # 1. the program's own memory, read directly
    code = harness.build_romdump()
    size = 0x8000
    data = image.build_romdump(simelf.BASE + simelf.HARNESS_OFF, size)
    with open(os.path.join(work, "sim.hda"), "wb") as fh:
        fh.write(data)
    with open(os.path.join(work, "sim.elf"), "wb") as fh:
        fh.write(data[simelf.ELF_BLK * 512:(simelf.ELF_BLK + simelf.ELF_MAX_BLKS) * 512])
    show(*qemu(work, []))
    with open(os.path.join(work, "sim.hda"), "rb") as fh:
        dump = image.RomDump(fh.read())
    good = (dump.done and not dump.wrfail and dump.checksum() == dump.sum
            and dump.rom[:1024] == code[:1024])
    print("done=%s write_failed=%d checksum target %08X / disk %08X, first 1024 bytes %s"
          % (dump.done, dump.wrfail, dump.sum, dump.checksum(),
             "match the program" if dump.rom[:1024] == code[:1024] else "DIFFER"))

    # 2. the real thing: 4 MB at physical FFC00000 through a memory device, here
    #    a sparse file standing in for /dev/mem
    rom_path = os.path.join(RUNS, "my7600.rom")
    if os.path.exists(rom_path):
        with open(rom_path, "rb") as fh:
            rom = fh.read()
    else:
        rom = bytes((i * 7 + (i >> 9)) & 0xFF for i in range(0x400000))
    data = image.build_romdump()
    for name, blob in (("sim.hda", data), ("rom.bin", rom),
                       ("sim.elf", data[simelf.ELF_BLK * 512:(simelf.ELF_BLK + simelf.ELF_MAX_BLKS) * 512])):
        with open(os.path.join(work, name), "wb") as fh:
            fh.write(blob)
    script = "\n".join([
        "set -e",
        'd=$(mktemp -d)',
        'cp sim.elf sim.hda "$d"/',
        'truncate -s 4G "$d/mem.bin"',
        'dd if=rom.bin of="$d/mem.bin" bs=4096 seek=$((0xFFC00)) conv=notrunc status=none',
        'cd "$d"; chmod +x sim.elf',
        'qemu-ppc-static -cpu 604 ./sim.elf sim.hda mem.bin || echo "exit code $?"',
        'cd - >/dev/null; cp "$d/sim.hda" ./sim.hda; rm -rf "$d"', ""])
    with open(os.path.join(work, "romtest.sh"), "w", newline="\n") as fh:
        fh.write(script)
    cmd = ["bash", "./romtest.sh"]
    if os.name == "nt":
        cmd = ["wsl", "--cd", work, "--"] + cmd
    run = subprocess.run(cmd, cwd=work, capture_output=True, timeout=600)
    show(run.returncode, run.stdout.decode("ascii", "replace").strip(),
         "\n".join(l for l in run.stderr.decode("utf-8", "replace").replace("\0", "").splitlines()
                   if l.strip() and "Failed to mount" not in l))
    with open(os.path.join(work, "sim.hda"), "rb") as fh:
        dump = image.RomDump(fh.read())
    good2 = dump.done and not dump.wrfail and dump.checksum() == dump.sum and dump.rom == rom
    print("memory-device dump: done=%s write_failed=%d checksum target %08X / disk %08X, "
          "4 MB %s" % (dump.done, dump.wrfail, dump.sum, dump.checksum(),
                       "identical to the source" if dump.rom == rom else "DIFFER"))
    sys.exit(0 if good and good2 else 1)


def cmd_selftest(args):
    work = os.path.join(HERE, "_sim")
    os.makedirs(work, exist_ok=True)
    vs = load_set(args)
    # QEMU's user-mode emulation has no MSR[FE0/FE1] to turn off, so it always
    # traps an enabled exception. One raised by the instruction under test is
    # caught and stepped over; a vector that starts with FEX already set would
    # trap inside the test program's own code, so those cannot run here.
    kept = [v for v in vs if not vectors.fpscr_as_held(v.fpscr) & vectors.FPSCR_FEX]
    print("simulating %d vectors (%d that start with FPSCR[FEX] set left out)"
          % (len(kept), len(vs) - len(kept)))
    hda, elf = os.path.join(work, "sim.hda"), os.path.join(work, "sim.elf")
    # the second stage is on the disk (and never runs under Linux)
    data = image.build(kept, nslot=2, seqs=svectors.build_set(), rom=False)
    with open(hda, "wb") as fh:
        fh.write(data)
    with open(elf, "wb") as fh:                         # exactly what `dd` extracts
        fh.write(data[simelf.ELF_BLK * 512:(simelf.ELF_BLK + simelf.ELF_MAX_BLKS) * 512])
    codes = []
    for attempt in ("first run", "second run", "third run: both slots are used, must refuse"):
        print("=== " + attempt)
        code, out, err = qemu(work, [], args.qemu_cpu)
        show(code, out, err)
        codes.append(code)
    print("--- decoded from the disk image ---")
    with open(hda, "rb") as fh:
        img = image.Image(fh.read())
    status = report(img, out_dir=work, name="sim", save=True)
    ok = codes == [0, 0, 3] and len(img.runs) == 2 and not img.unfinished
    if len(img.runs) == 2:
        a, b = img.runs
        same = all(a.result(i) == b.result(i) for i in range(img.nvec))
        print("the two runs' results are %s" % ("identical" if same else "DIFFERENT"))
        ok = ok and same
    print("Linux-route self-test %s (exit codes %s, %d finished runs; mismatches against "
          "expected values are QEMU's and do not count)"
          % ("PASSED" if ok and status == 0 else "FAILED", codes, len(img.runs)))

    # The test program's own slot code, which is what runs from Open Firmware.
    # Here a variant that does not leave the slots to the Linux wrapper.
    print("=== the test program choosing its own result slot (the Open Firmware path)")
    few = kept[:4096]
    data = image.build(few, nslot=2, own_slots_always=True)
    with open(hda, "wb") as fh:
        fh.write(data)
    with open(elf, "wb") as fh:
        fh.write(data[simelf.ELF_BLK * 512:(simelf.ELF_BLK + simelf.ELF_MAX_BLKS) * 512])
    outs = []
    for attempt in range(3):
        code, out, err = qemu(work, [], args.qemu_cpu)
        show(code, out, err)
        outs.append(out)
    with open(hda, "rb") as fh:
        img2 = image.Image(fh.read())
    ok2 = (len(img2.runs) == 2 and [r.slot for r in img2.runs] == [1, 2]
           and "ERR full" in outs[2] and "ERR" not in outs[0] + outs[1]
           and not img2.main.done)
    if ok2:
        ref = img.runs[0]
        ok2 = all(r.result(i) == ref.result(i) for r in img2.runs for i in range(len(few)))
        ok2 = ok2 and all(r.result_checksum() == r.sum and r.nrun == len(few) for r in img2.runs)
    print("own-slot self-test %s (%d runs in slots %s; third run %s; results %s)"
          % ("PASSED" if ok2 else "FAILED", len(img2.runs), [r.slot for r in img2.runs],
             "refused" if "ERR full" in outs[2] else "NOT refused",
             "equal to the Linux-route run's" if ok2 else "not verified"))
    sys.exit(0 if ok and ok2 and status == 0 else 1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--set", default="v4", choices=("v4", "v3"),
                        help="v4: the v3 vectors checked against the real 604's results, plus "
                             "the model-predicted and new vectors (default); v3: dingusppc's "
                             "vectors and the generated extras")
        sp.add_argument("--cpu", default="604e", choices=vectors.CPUS,
                        help="CPU the disk will run on (v3 only: decides which instructions are safe)")
        sp.add_argument("--dingus", default=vectors.DINGUS_DEFAULT,
                        help="v3: directory holding dingusppc's ppcinttests.csv / ppcfloattests.csv")
        sp.add_argument("--no-extras", action="store_true",
                        help="v3: only dingusppc's vectors, all of which have expected values")

    b = sub.add_parser("build"); common(b)
    b.add_argument("--out", default="HD40_512_ppctest.hda")
    b.add_argument("--slots", type=int, default=image.NSLOT_MAX,
                   help="how many Linux runs the disk has room for")
    b.add_argument("--no-fp-enables", action="store_true",
                   help="leave out vectors that set FPSCR exception-enable bits")
    b.add_argument("--no-stage2", action="store_true",
                   help="leave out the second stage (supervisor-mode sequences and the ROM dump)")
    b.set_defaults(fn=cmd_build)
    r = sub.add_parser("results")
    r.add_argument("image")
    r.add_argument("--name", help="write runs/results_NAME.csv (default: named after the CPU)")
    r.add_argument("--machine", help="the Mac it ran in, for the file name (Linux runs "
                                     "record it themselves), for example 7300")
    r.add_argument("--out-dir", default=RUNS)
    r.add_argument("--golden", help="results CSV to compare with (default: the 604 reference run)")
    r.add_argument("--slot", type=int, help="only this run")
    r.add_argument("--force", action="store_true",
                   help="also decode a run that has no completion record")
    r.set_defaults(fn=cmd_results)
    v = sub.add_parser("vector")
    v.add_argument("image"); v.add_argument("index", nargs="+")
    v.set_defaults(fn=cmd_vector)
    d = sub.add_parser("diff")
    d.add_argument("a"); d.add_argument("b"); d.add_argument("--show", type=int, default=8)
    d.set_defaults(fn=cmd_diff)
    s = sub.add_parser("selftest"); common(s)
    s.add_argument("--qemu-cpu", default="604")
    s.set_defaults(fn=cmd_selftest)
    rb = sub.add_parser("rom-build")
    rb.add_argument("--out", default="HD50_512_romdump.hda")
    rb.add_argument("--addr", default="FFC00000", help="physical address, hex")
    rb.add_argument("--size", default="400000", help="bytes, hex, multiple of 0x1000")
    rb.set_defaults(fn=cmd_rom_build)
    rx = sub.add_parser("rom-extract")
    rx.add_argument("image"); rx.add_argument("--out", default="dumped.rom")
    rx.set_defaults(fn=cmd_rom_extract)
    rc = sub.add_parser("rom-check")
    rc.add_argument("file"); rc.add_argument("other", nargs="?")
    rc.set_defaults(fn=cmd_rom_check)
    rs = sub.add_parser("rom-selftest")
    rs.set_defaults(fn=cmd_rom_selftest)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
