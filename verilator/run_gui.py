#!/usr/bin/env python3
"""The whole machine in a window, to watch it run.

    python verilator\\run_gui.py [--rom FILE | --rom7600] [--nvram FILE] [--ram MB]
                                 [--monitor 16|13] [--pause]

Builds ppcmac_gui (gui_main.cpp, `make gui`) and starts it: the Control
window (run, reset, the frame counter with the machine's frames a second,
the speed in simulated MHz and instructions a second), the Machine window
(pc, MSR, counts), the Video window (the Control video's picture, zoom), the
Debug log (with what the machine sends on the modem port) and a line to
type at the modem port. Defaults: the 7300's ROM, 16 MB, the 16-inch
monitor. Mac OS turns the video on at about 128 million instructions.

From Windows it runs in WSL and the window comes up through WSLg.
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
        conv = []
        for i, a in enumerate(args):
            if i > 0 and args[i - 1] in ("--rom", "--nvram") and (":" in a or os.path.exists(a)):
                a = to_wsl(a)
            conv.append(a)
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_gui.py"] + conv)

    cache = os.path.join(os.path.expanduser("~"), ".cache", "ppcmac")
    build = os.environ.get("PPCMAC_BUILD") or os.path.join(cache, "verilator")
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp

    rom = "my7600.rom" if "--rom7600" in args else "my7300.rom"
    args = [a for a in args if a != "--rom7600"]
    if "--rom" not in args:
        args = ["--rom", os.path.join(HERE, "..", "ppctest", "runs", rom)] + args

    print("building ppcmac_gui (a few minutes after an RTL change)...", flush=True)
    r = run(["make", "-s", "-C", HERE, "gui", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building ppcmac_gui failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    return subprocess.call([os.path.join(build, "gui", "ppcmac_gui")] + args)


if __name__ == "__main__":
    sys.exit(main())
