#!/usr/bin/env python3
"""Build the DSPPC604 Verilator model and replay the real-604 golden vectors.

    python verilator\\run.py                 everything
    python verilator\\run.py --only int      integer vectors only
    python verilator\\run.py --name FMADD    one instruction (all its variants)
    python verilator\\run.py --show 20       print more failures per instruction
    python verilator\\run.py --csv x.csv     another vector file (see fpmodel.py)

Runs from Windows (through WSL) or directly under Linux. Options are passed on
to the test bench; `--help` lists them.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Build outside the Windows drive when possible: compiling on /mnt/c is slow.
BUILD_ENV = "MACPPC7300_BUILD"


def wsl_path(path):
    """A Windows path as WSL sees it: C:\\dir\\file -> /mnt/c/dir/file."""
    path = os.path.abspath(path)
    drive, rest = os.path.splitdrive(path)
    return "/mnt/" + drive[0].lower() + rest.replace("\\", "/")


def main():
    args = sys.argv[1:]
    if os.name == "nt":
        # file arguments are given relative to where the user is standing
        args = [wsl_path(a) if os.path.isfile(a) else a for a in args]
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run.py"] + args)

    args = [os.path.abspath(a) if os.path.isfile(a) else a for a in args]
    build = os.environ.get(BUILD_ENV) or os.path.join(
        os.path.expanduser("~"), ".cache", "macppc7300", "verilator")
    os.makedirs(build, exist_ok=True)
    rc = subprocess.call(["make", "-s", "-C", HERE, "BUILD=" + build])
    if rc:
        print("build failed")
        return rc
    os.chdir(HERE)
    sys.stdout.flush()
    return subprocess.call([os.path.join(build, "vector_tb")] + args)


if __name__ == "__main__":
    sys.exit(main())
