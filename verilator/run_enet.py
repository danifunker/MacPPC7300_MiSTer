#!/usr/bin/env python3
"""Build the Ethernet bridge's bench (MacPPC7300_enet alone) under Verilator and run it.

    python verilator\\run_enet.py [--seed S] [--restarts N]

The bench (enet_main.cpp) runs the bridge's DDR3 port against a model of
the rings' window, the Main's side as support/mac/mac_eth.cpp's ring_poll
does it, and MACE's side as MacPPC7300_mace keeps it (toggles across
resets): frames both ways; a Shut Down with a frame offered and the power
key after it; restarts at random moments. Every frame is checked.

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
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_enet.py"] + sys.argv[1:])

    cache = os.path.join(os.path.expanduser("~"), ".cache", "macppc7300")
    build = os.environ.get("MACPPC7300_BUILD") or os.path.join(cache, "verilator")
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp

    r = run(["make", "-s", "-C", HERE, "enet", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building the Ethernet bridge's bench failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    return subprocess.call([os.path.join(build, "enet", "enet_tb")] + sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
