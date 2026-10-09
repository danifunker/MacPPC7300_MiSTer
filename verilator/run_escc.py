#!/usr/bin/env python3
"""Build the ESCC bench (MacPPC7300_escc alone) under Verilator and run it.

    python verilator\\run_escc.py

The bench (escc_main.cpp) programs the modem port as Open Firmware (38,400),
a MIDI driver (x32 from TRxC: 31,250) and PPP (57,600, 115,200) do and
measures the bits sent; receives a byte at MIDI's rate (RTS up while it
waits); and checks CTS in RR0 and its external/status interrupt. A second.

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
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_escc.py"] + sys.argv[1:])

    cache = os.path.join(os.path.expanduser("~"), ".cache", "macppc7300")
    build = os.environ.get("MACPPC7300_BUILD") or os.path.join(cache, "verilator")
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp

    r = run(["make", "-s", "-C", HERE, "escc", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building the ESCC bench failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    return subprocess.call([os.path.join(build, "escc", "escc_tb")] + sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
