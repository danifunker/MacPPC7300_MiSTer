#!/usr/bin/env python3
"""Drive the MiSTer over SSH: put the core and the ROM on it, set the core's
options, load it, take a screenshot, read the core's UART.

    python syn\\mister.py put-core [RBF]          output_files\\PPCMac.rbf -> _Unstable/PPCMac.rbf
    python syn\\mister.py put-rom FILE            -> games/PPCMac/boot.rom (loaded at core start)
    python syn\\mister.py cfg [--ram MB] [--boot rom|memtest]   writes config/PPCMac.CFG
    python syn\\mister.py load                    loads _Unstable/PPCMac.rbf
    python syn\\mister.py menu                    loads the menu core again
    python syn\\mister.py shot [OUT.png]          a screenshot of the core's output, fetched
    python syn\\mister.py uart [SECONDS]          what the core sends on its UART (/dev/ttyS1)
    python syn\\mister.py run CMD                 any shell command on the MiSTer

The board: MISTER_HOST (or the first line of syn\\mister_host, which git
ignores) and MISTER_KEY (default ~/.ssh/mister_only). Only key-based SSH is
used; nothing asks for a password (BatchMode).
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE = "/media/fat/_Unstable/PPCMac.rbf"
RAM_OPTION = {16: 0, 24: 1, 48: 2, 64: 3, 96: 4, 6: 5}       # PPCMac.sv: O[3:1]


def host():
    h = os.environ.get("MISTER_HOST")
    if not h:
        p = os.path.join(HERE, "mister_host")
        if os.path.exists(p):
            h = open(p).read().split()[0]
    if not h:
        sys.exit("set MISTER_HOST or put the MiSTer's address in syn\\mister_host")
    return h


def ssh_args():
    key = os.environ.get("MISTER_KEY") or os.path.join(os.path.expanduser("~"), ".ssh", "mister_only")
    return ["-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"]


def ssh(cmd, capture=False, timeout=None):
    args = ["ssh"] + ssh_args() + ["root@" + host(), cmd]
    if capture:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout).stdout
    return subprocess.call(args, timeout=timeout)


def scp(src, dst):
    return subprocess.call(["scp"] + ssh_args() + [src, dst])


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    cmd = a[0]
    if cmd == "put-core":
        rbf = a[1] if len(a) > 1 else os.path.join(ROOT, "output_files", "PPCMac.rbf")
        return scp(rbf, "root@%s:%s" % (host(), CORE))
    if cmd == "put-rom":
        ssh("mkdir -p /media/fat/games/PPCMac")
        return scp(a[1], "root@%s:/media/fat/games/PPCMac/boot.rom" % host())
    if cmd == "cfg":
        ram, boot = 16, "rom"
        for i in range(1, len(a) - 1):
            if a[i] == "--ram":
                ram = int(a[i + 1])
            if a[i] == "--boot":
                boot = a[i + 1]
        if ram not in RAM_OPTION or boot not in ("rom", "memtest"):
            sys.exit("--ram one of %s, --boot rom or memtest" % sorted(RAM_OPTION))
        status = (RAM_OPTION[ram] << 1) | ((boot == "memtest") << 4)
        data = "\\x%02x" % status + "\\x00" * 15
        return ssh("printf '%s' > /media/fat/config/PPCMac.CFG && xxd /media/fat/config/PPCMac.CFG" % data)
    if cmd == "load":
        return ssh("echo 'load_core %s' > /dev/MiSTer_cmd" % CORE)
    if cmd == "menu":
        return ssh("echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd")
    if cmd == "shot":
        out = a[1] if len(a) > 1 else "PPCMac_screen.png"
        ssh("echo screenshot > /dev/MiSTer_cmd")
        time.sleep(3)
        name = ssh("ls -t /media/fat/screenshots/PPCMac/*.png 2>/dev/null | head -1", capture=True).strip()
        if not name.endswith(".png"):
            sys.exit("no screenshot found (%s)" % name)
        return scp("root@%s:%s" % (host(), name), out)
    if cmd == "uart":
        secs = int(a[1]) if len(a) > 1 else 3
        return ssh("stty -F /dev/ttyS1 115200 raw -echo && timeout %d cat /dev/ttyS1" % secs, timeout=secs + 30)
    if cmd == "run":
        return ssh(" ".join(a[1:]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
