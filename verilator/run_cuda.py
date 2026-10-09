#!/usr/bin/env python3
"""Build Cuda (MacPPC7300_cuda: the 68HC05 and its firmware) under Verilator and
test it alone, in lockstep with MAME's 6805 core.

    python verilator\\run_cuda.py [cuda_tb options]

The bench (cuda_main.cpp) is a VIA and a host around Cuda: a cold start
until Cuda releases the CPU's reset, the host's sync, then a script of
packets whose replies are checked. Every instruction is compared with MAME's
6805 core (verilator/hc05ref). Options are passed to cuda_tb, e.g.
--seconds 6, --trace-from 0 --trace-count 50, --no-lockstep.

Runs from Windows (through WSL) or directly under Linux.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def main():
    if os.name == "nt":
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_cuda.py"] + sys.argv[1:])

    cache = os.path.join(os.path.expanduser("~"), ".cache", "macppc7300")
    build = os.environ.get("MACPPC7300_BUILD") or os.path.join(cache, "verilator")
    # the compilers' temporary files go in a directory of this build's own
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp
    refdir = os.path.join(cache, "hc05ref")

    args = sys.argv[1:]
    lockstep = "--no-lockstep" not in args
    args = [a for a in args if a != "--no-lockstep"]
    if lockstep:
        args = ["--lockstep", "--rom", os.path.join(HERE, "..", "rtl", "machine", "cuda", "341s0060.bin")] + args

    r = run(["make", "-s", "-C", os.path.join(HERE, "hc05ref"), "BUILD=" + refdir])
    if r.returncode:
        print(r.stdout)
        print("building MAME's 6805 reference failed")
        return 1
    lib = os.path.join(refdir, "libhc05ref.a")
    r = run(["make", "-s", "-C", HERE, "cuda", "BUILD=" + build, "HC05_LIB=" + lib])
    if r.returncode:
        print(r.stdout)
        print("building the Cuda bench failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    return subprocess.call([os.path.join(build, "cuda_ref", "cuda_tb")] + args)


if __name__ == "__main__":
    sys.exit(main())
