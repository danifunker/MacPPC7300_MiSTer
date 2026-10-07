#!/usr/bin/env python3
"""Build the whole machine (PPCMac_system) under Verilator and run a ROM on it.

    python verilator\\run_machine.py [machine_tb options]

Defaults: the 7300's ROM (ppctest/runs/my7300.rom, 077D.34F2: the reference
since 2026-10-07, the 7300 being the real machine we measure), 16 MB of RAM,
in lockstep with dingusppc. Every option is passed to machine_tb (see
core_main.cpp); --no-lockstep runs the machine alone, --rom FILE another ROM,
--rom7600 the 7600's own (my7600.rom, 077D.28F2), the second ROM that must
keep passing. Examples:

    python verilator\\run_machine.py --max-instr 1000000 --progress 100000
    python verilator\\run_machine.py --rom7600 --max-instr 60000000 --progress 2000000
    python verilator\\run_machine.py --dev-log dev.log --max-instr 200000
    python verilator\\run_machine.py --trace-from 5000 --trace-count 50
    python verilator\\run_machine.py --boot memtest --memtest-passes 2      (1 MB unless --ram)
    python verilator\\run_machine.py --boot memtest --mem-fault 0x1234     (must find the fault)

The device log (--dev-log) has the format of verilator/machref's log, so the
two can be compared with verilator/machref/devdiff.py.

Runs from Windows (through WSL) or directly under Linux.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def to_wsl(path):
    p = os.path.abspath(path)
    return "/mnt/" + p[0].lower() + p[2:].replace("\\", "/")


def main():
    args = sys.argv[1:]
    if os.name == "nt":
        # file arguments are Windows paths here; hand WSL its own spelling
        conv = []
        for i, a in enumerate(args):
            if i > 0 and args[i - 1] in ("--rom", "--dev-log") and (":" in a or os.path.exists(a)):
                a = to_wsl(a)
            conv.append(a)
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_machine.py"] + conv)

    cache = os.path.join(os.path.expanduser("~"), ".cache", "ppcmac")
    build = os.environ.get("PPCMAC_BUILD") or os.path.join(cache, "verilator")
    refdir = os.path.join(cache, "dingusref")
    # the compilers' temporary files go in a directory of this build's own:
    # other WSL sessions working at the same time have deleted files in /tmp
    # under a running g++
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp

    memtest = "memtest" in args
    lockstep = "--no-lockstep" not in args and not memtest
    rom = "my7600.rom" if "--rom7600" in args else "my7300.rom"
    args = [a for a in args if a not in ("--no-lockstep", "--rom7600")]
    if memtest and "--ram" not in args:
        args += ["--ram", "1"]            # the walk is slow in simulation
    if "--rom" not in args and not memtest:
        args = ["--rom", os.path.join(HERE, "..", "ppctest", "runs", rom)] + args
    if lockstep and "--lockstep" not in args:
        args = ["--lockstep"] + args

    r = run(["make", "-s", "-C", os.path.join(HERE, "ref"), "BUILD=" + refdir])
    if r.returncode:
        print(r.stdout)
        print("building the dingusppc reference failed")
        return 1
    lib = os.path.join(refdir, "libdingusref.a")
    r = run(["make", "-s", "-C", HERE, "machine", "BUILD=" + build, "REF_LIB=" + lib])
    if r.returncode:
        print(r.stdout)
        print("building the machine bench failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    tb = os.path.join(build, "machine_ref", "machine_tb")
    return subprocess.call([tb, "--machine"] + args)


if __name__ == "__main__":
    sys.exit(main())
