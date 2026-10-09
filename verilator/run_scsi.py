#!/usr/bin/env python3
"""Build the SCSI bench (scsi_tb_top: Grand Central with MESH and its DBDMA
channel, and the disks on the internal bus) under Verilator and run it.

    python verilator\\run_scsi.py [scsi_tb options]

The bench (scsi_main.cpp) drives Grand Central's registers as the 7300's ROM
and Mac OS 7.6.1's disk driver drive them (dingusppc's device log of a boot
from the 7.6.1 image): programmed-I/O reads, DMA reads into memory with a
descriptor longer than MESH's count, multi-block DMA, DMA writes, INQUIRY,
READ CAPACITY, a selection of an absent ID; then the CD-ROM at ID 3 and the
BlueSCSI Toolbox against a model of the Main's Mac layer (--stock: the
official Main, no CD drive); the messages Mac OS 8.5's driver sends (SDTR,
WDTR, a MESSAGE REJECT answered under ATN); last the floppy: SWIM3 reading
DiskCopy and raw images (1440K, 800K) into memory by DMA channel 1. A memory answers the DMA port, and hps_io's
block side serves a made-up image (or --disk FILE). Every byte is checked.
--verbose prints every block the card moves. A few seconds.

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
        conv = [to_wsl(a) if i > 0 and args[i - 1] == "--disk" else a for i, a in enumerate(args)]
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_scsi.py"] + conv)

    cache = os.path.join(os.path.expanduser("~"), ".cache", "macppc7300")
    build = os.environ.get("MACPPC7300_BUILD") or os.path.join(cache, "verilator")
    # the compilers' temporary files go in a directory of this build's own
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp

    r = run(["make", "-s", "-C", HERE, "scsi", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building the SCSI bench failed")
        return 1
    if r.stdout.strip():
        print(r.stdout.strip())
    return subprocess.call([os.path.join(build, "scsi", "scsi_tb")] + args)


if __name__ == "__main__":
    sys.exit(main())
