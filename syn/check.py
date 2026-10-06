#!/usr/bin/env python3
"""Area and timing check of one DSPPC604 block on the DE10-Nano's FPGA.

    python syn\\check.py int            integer decode + execute path
    python syn\\check.py fpu            floating-point unit
    python syn\\check.py core           the pipeline (no FPU, caches or MMU yet)
    python syn\\check.py int --mhz 66   constrain to a different clock
    python syn\\check.py core --paths 40 --detail 2
                                       ... and the 40 slowest distinct paths
                                       (one line per family of register pairs,
                                       with its count), then the two slowest
                                       cell by cell
    python syn\\check.py core --report-only --paths 40
                                       the same from the last compile
    python syn\\check.py core --report-only --to "*wb_result*" --to "*pc_f*"
                                       the slowest path into the registers
                                       matching each pattern, cell by cell

Builds a throw-away Quartus project in syn/build/<target>, with every port
except the clock as a virtual pin, compiles it (synthesis, fit, timing) and
prints the resource use and Fmax. Needs Quartus 17.0 (Lite is enough).

The Fmax figure swings by 2-3 MHz between fits of near-identical designs;
judge a change by the named paths' slack, and by what the cell-by-cell
report says each path spends its time on.
"""

import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.normpath(os.path.join(HERE, "..", "rtl", "DSPPC604"))
QUARTUS_BIN = os.environ.get("QUARTUS_BIN", r"C:\intelFPGA_lite\17.0\quartus\bin64")
DEVICE = "5CSEBA6U23I7"   # DE10-Nano

def cpu_sources():
    """The CPU's file list, from its .qip (shared with Quartus and Verilator)."""
    with open(os.path.join(RTL, "DSPPC604.qip")) as fh:
        return re.findall(r"qip_path\)\s+(\S+?)\]", fh.read())


# top-level wrapper per target; unused CPU modules are simply dropped
TARGETS = {
    "int": "DSPPC604_check_int",
    "fpu": "DSPPC604_check_fpu",
    "core": "DSPPC604_check_core",
}


def q(path):
    return path.replace("\\", "/")


def write_project(top, mhz, build):
    files = [os.path.join(RTL, f) for f in cpu_sources()] + [os.path.join(HERE, top + ".sv")]
    for f in files:
        if not os.path.exists(f):
            sys.exit("missing source: " + f)
    lines = [
        'set_global_assignment -name FAMILY "Cyclone V"',
        "set_global_assignment -name DEVICE " + DEVICE,
        "set_global_assignment -name TOP_LEVEL_ENTITY " + top,
        "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files",
        "set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL",
        # the settings a MiSTer core is built with (see <core>.qsf)
        'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"',
        "set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED",
        "set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON",
        "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON",
        "set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON",
        "set_global_assignment -name ALLOW_POWER_UP_DONT_CARE ON",
        "set_global_assignment -name SEED 1",
        'set_global_assignment -name MIN_CORE_JUNCTION_TEMP "-40"',
        "set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100",
        "set_global_assignment -name SDC_FILE check.sdc",
        'set_instance_assignment -name VIRTUAL_PIN ON -to "i_*"',
        'set_instance_assignment -name VIRTUAL_PIN ON -to "o_*"',
    ]
    lines += ["set_global_assignment -name SYSTEMVERILOG_FILE " + q(f) for f in files]
    with open(os.path.join(build, top + ".qsf"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(build, top + ".qpf"), "w") as fh:
        fh.write('QUARTUS_VERSION = "17.0"\nPROJECT_REVISION = "%s"\n' % top)
    with open(os.path.join(build, "check.sdc"), "w") as fh:
        fh.write("create_clock -name clk -period %.3f [get_ports clk]\n" % (1000.0 / mhz))
        fh.write("derive_clock_uncertainty\n")


def report(top, build, mhz):
    out = os.path.join(build, "output_files")
    print()
    try:
        with open(os.path.join(out, top + ".fit.summary")) as fh:
            for line in fh:
                if re.match(r"\s*(Logic utilization|Total registers|Total block memory bits|"
                            r"Total RAM Blocks|Total DSP Blocks)", line):
                    print(line.rstrip())
    except OSError:
        print("no fitter summary (the fit did not finish)")
    try:
        with open(os.path.join(out, top + ".sta.rpt")) as fh:
            sta = fh.read()
    except OSError:
        print("no timing report")
        return 1
    worst = None
    for model, body in re.findall(r"; (Slow [^;]*? Model) Fmax Summary\s*;\n(.*?)\n\n", sta, re.S):
        m = re.search(r";\s*([\d.]+) MHz\s*;\s*([\d.]+) MHz\s*;\s*clk\s*;", body)
        if m:
            f = float(m.group(1))
            print("Fmax %-22s %7.2f MHz" % (model, f))
            worst = f if worst is None else min(worst, f)
    if worst is None:
        print("no Fmax found in the timing report")
        return 1
    print("constraint %.2f MHz: %s (worst-case Fmax %.2f MHz)"
          % (mhz, "MET" if worst >= mhz else "NOT MET", worst))
    return 0


def sta(top, build, lines, log):
    """Run quartus_sta on the last compile with the given Tcl lines."""
    tcl = os.path.join(build, log + ".tcl")
    with open(tcl, "w") as fh:
        fh.write("project_open %s\ncreate_timing_netlist\nread_sdc\nupdate_timing_netlist\n" % top)
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(build, log + ".log"), "w") as fh:
        return subprocess.call([os.path.join(QUARTUS_BIN, "quartus_sta"), "-t", log + ".tcl"],
                               cwd=build, stdout=fh, stderr=subprocess.STDOUT)


def family(name):
    """A register's name without the bit, the fitter's suffixes (retimed,
    duplicated, resynthesised copies) and the RAM megafunction's innards, so
    that every bit of a path between the same two things counts as one."""
    parts = [re.sub(r"\[\d+\]", "", p) for p in name.split("|")]
    parts = [p for p in parts if not p.startswith(("altsyncram_", "auto_generated"))]
    s = "|".join(parts[-2:]) if len(parts) > 1 else parts[0]
    s = re.sub(r"~.*$", "", s)
    return re.sub(r"_OTERM\d+|_NEW\d+|_RTM\d+|_RESYN\d+|_DUPLICATE|_Duplicate|__\d+", "", s)


def worst_paths(top, build, count):
    """Print the slowest paths, one line per family of register pairs."""
    txt = os.path.join(build, "paths.txt")
    rc = sta(top, build, ["report_timing -setup -npaths %d -detail summary -file paths.txt" % (count * 50)], "paths")
    if rc or not os.path.exists(txt):
        print("could not list paths; see paths.log")
        return
    seen = {}
    with open(txt) as fh:
        for line in fh:
            cols = [c.strip() for c in line.split(";")]
            if len(cols) < 5 or not re.match(r"-?\d+\.\d+$", cols[1]):
                continue
            pair = (family(cols[2]), family(cols[3]))
            if pair not in seen:
                seen[pair] = [float(cols[1]), 0]
            seen[pair][1] += 1
    print("\nslowest paths (slack ns, paths in the family, from -> to):")
    for (src, dst), (slack, n) in list(seen.items())[:count]:
        print("  %7.3f  (%4d)  %s -> %s" % (slack, n, src, dst))


def detail_paths(top, build, count, to=None):
    """Print the slowest paths cell by cell: where each spends its time.
    With a pattern, the slowest paths into the registers it matches."""
    tag = "detail" if to is None else "detail_" + re.sub(r"[^A-Za-z0-9]+", "_", to).strip("_")
    txt = os.path.join(build, tag + ".txt")
    flt = "" if to is None else " -to [get_keepers {%s}]" % to
    rc = sta(top, build, ["report_timing -setup -npaths %d -detail full_path%s -file %s.txt" % (count, flt, tag)], tag)
    if rc or not os.path.exists(txt):
        print("could not report the paths in detail; see %s.log" % tag)
        return
    n = 0
    inpath = False
    with open(txt) as fh:
        for line in fh:
            if "Data Arrival Path" in line:
                n += 1
                inpath = True
                print("\npath %d%s, cell by cell (arrival ns, step ns, kind, fan-out, element):"
                      % (n, "" if to is None else " into " + to))
                continue
            if "Data Required Path" in line:
                inpath = False
                continue
            if not inpath:
                continue
            cols = [c.strip() for c in line.split(";")]
            if len(cols) < 9 or not re.match(r"-?\d+\.\d+$", cols[1]):
                continue
            total, incr, kind, fan, elem = cols[1], cols[2], cols[4], cols[5], cols[7]
            if kind == "IC" and float(incr) < 0.6:
                continue                              # short routing steps: noise
            elem = re.sub(r"\|altsyncram[^|]*", "", elem)
            elem = re.sub(r"^[^|]*\|DSPPC604:cpu\|", "", elem)
            print("  %7s %6s %-5s %5s  %s" % (total, incr, kind, fan, elem[-100:]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", choices=sorted(TARGETS))
    ap.add_argument("--mhz", type=float, default=75.0, help="clock constraint (default 75)")
    ap.add_argument("--report-only", action="store_true", help="re-read the reports of the last run")
    ap.add_argument("--paths", type=int, default=0, metavar="N", help="also list the N slowest distinct paths")
    ap.add_argument("--detail", type=int, default=0, metavar="N", help="also print the N slowest paths cell by cell")
    ap.add_argument("--to", action="append", metavar="PATTERN",
                    help="also print the slowest path into the registers matching PATTERN cell by cell (repeatable)")
    args = ap.parse_args()

    top = TARGETS[args.target]
    build = os.path.join(HERE, "build", args.target)
    os.makedirs(build, exist_ok=True)

    if not args.report_only:
        write_project(top, args.mhz, build)
        exe = os.path.join(QUARTUS_BIN, "quartus_sh")
        log = os.path.join(build, "compile.log")
        print("compiling %s for %s at %.2f MHz (log: %s)" % (top, DEVICE, args.mhz, log))
        with open(log, "w") as fh:
            rc = subprocess.call([exe, "--flow", "compile", top], cwd=build, stdout=fh, stderr=subprocess.STDOUT)
        if rc:
            with open(log) as fh:
                errors = [l.rstrip() for l in fh if l.startswith("Error")]
            print("\n".join(errors[:30]) or "Quartus failed; see the log")
            return rc
    rc = report(top, build, args.mhz)
    if args.paths:
        worst_paths(top, build, args.paths)
    if args.detail:
        detail_paths(top, build, args.detail)
    for pattern in args.to or []:
        detail_paths(top, build, 1, pattern)
    return rc


if __name__ == "__main__":
    sys.exit(main())
