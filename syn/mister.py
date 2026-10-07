#!/usr/bin/env python3
"""Drive the MiSTer over SSH: put the core and the ROM on it, set the core's
options, load it, take a screenshot, read the core's UART.

    python syn\\mister.py put-core [RBF]          output_files\\PPCMac.rbf -> _Unstable/PPCMac.rbf
    python syn\\mister.py put-rom FILE            -> games/PPCMac/boot.rom (loaded at core start)
    python syn\\mister.py put-nvram [FILE]        -> games/PPCMac/boot1.rom, the NVRAM image loaded at
                                                 core start (default syn\\nvram_of_prompt.bin)
    python syn\\mister.py rm-nvram                removes boot1.rom (the NVRAM starts blank)
    python syn\\mister.py cfg [--ram MB] [--boot rom|memtest] [--uart modem|debug]
                              [--picture mac|debug] [--monitor 16|13]
                                                 writes config/PPCMac.CFG
    python syn\\mister.py load                    loads _Unstable/PPCMac.rbf
    python syn\\mister.py menu                    loads the menu core again
    python syn\\mister.py shot [OUT.png]          a screenshot of the core's output, fetched
    python syn\\mister.py uart [SECONDS] [--baud N] [--raw]
                                                 what the core sends on its UART (/dev/ttyS1);
                                                 38400 (the modem port) unless --baud
    python syn\\mister.py type [--wait S] [--baud N] [--raw] LINE ...
                                                 types each LINE and a return at the modem port,
                                                 a character every 15 ms, printing what comes
                                                 back (S seconds after each line)
    (Both leave Open Firmware's escape sequences and carriage returns out
    unless --raw.)
    python syn\\mister.py run CMD                 any shell command on the MiSTer

For a terminal of your own on the modem port, from a shell on the MiSTer:
stty -F /dev/ttyS1 38400 raw -echo, then cat /dev/ttyS1 and write to it.

The board: MISTER_HOST (or the first line of syn\\mister_host, which git
ignores) and MISTER_KEY (default ~/.ssh/mister_only). Only key-based SSH is
used; nothing asks for a password (BatchMode).
"""

import base64
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CORE = "/media/fat/_Unstable/PPCMac.rbf"
RAM_OPTION = {16: 0, 24: 1, 48: 2, 64: 3, 96: 4, 6: 5}       # PPCMac.sv: O[3:1]

# a reader of the UART left from an earlier command would take part of what
# comes in: stop any before starting another
STOP_READERS = r'''for p in /proc/[0-9]*; do [ "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" = "cat /dev/ttyS1 " ] && kill ${p#/proc/}; done'''


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


def ssh_clean(cmd, timeout):
    """Run cmd on the MiSTer and print what it prints with Open Firmware's
    line editing left out: its ANSI escape sequences and carriage returns
    (it redraws the line after each key), as the bench's terminal does."""
    args = ["ssh"] + ssh_args() + ["root@" + host(), cmd]
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    esc = False
    try:
        while True:
            b = p.stdout.read(1)
            if not b:
                break
            c = b[0]
            if esc:
                esc = not (0x41 <= c <= 0x5A or 0x61 <= c <= 0x7A or c == 0x40)
            elif c == 0x1B:
                esc = True
            elif c == 0x0A or 0x20 <= c < 0x7F:
                sys.stdout.write(chr(c))
                sys.stdout.flush()
        return p.wait(timeout=timeout)
    except KeyboardInterrupt:
        p.kill()
        return 1


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
    if cmd == "put-nvram":
        img = a[1] if len(a) > 1 else os.path.join(HERE, "nvram_of_prompt.bin")
        if os.path.getsize(img) != 8192:
            sys.exit("%s is not an 8 KB NVRAM image" % img)
        ssh("mkdir -p /media/fat/games/PPCMac")
        return scp(img, "root@%s:/media/fat/games/PPCMac/boot1.rom" % host())
    if cmd == "rm-nvram":
        return ssh("rm -f /media/fat/games/PPCMac/boot1.rom")
    if cmd == "cfg":
        ram, boot, uart, picture, monitor = 16, "rom", "modem", "mac", 16
        for i in range(1, len(a) - 1):
            if a[i] == "--ram":
                ram = int(a[i + 1])
            if a[i] == "--boot":
                boot = a[i + 1]
            if a[i] == "--uart":
                uart = a[i + 1]
            if a[i] == "--picture":
                picture = a[i + 1]
            if a[i] == "--monitor":
                monitor = int(a[i + 1])
        if (ram not in RAM_OPTION or boot not in ("rom", "memtest") or uart not in ("modem", "debug")
                or picture not in ("mac", "debug") or monitor not in (16, 13)):
            sys.exit("--ram one of %s, --boot rom or memtest, --uart modem or debug, --picture mac or debug, "
                     "--monitor 16 or 13" % sorted(RAM_OPTION))
        status = ((RAM_OPTION[ram] << 1) | ((boot == "memtest") << 4) | ((uart == "debug") << 6)
                  | ((picture == "debug") << 7) | ((monitor == 13) << 8))
        data = "\\x%02x\\x%02x" % (status & 0xFF, status >> 8) + "\\x00" * 14
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
        raw = "--raw" in a
        baud = int(a[a.index("--baud") + 1]) if "--baud" in a else 38400
        rest = [x for i, x in enumerate(a[1:], 1) if x not in ("--baud", "--raw") and a[i - 1] != "--baud"]
        secs = int(rest[0]) if rest else 3
        remote = "%s; stty -F /dev/ttyS1 %d raw -echo && timeout %d cat /dev/ttyS1" % (STOP_READERS, baud, secs)
        return ssh(remote, timeout=secs + 30) if raw else ssh_clean(remote, secs + 30)
    if cmd == "type":
        baud, wait, lines, raw, i = 38400, 2.0, [], False, 1
        while i < len(a):
            if a[i] == "--baud":
                baud = int(a[i + 1]); i += 2
            elif a[i] == "--wait":
                wait = float(a[i + 1]); i += 2
            elif a[i] == "--raw":
                raw = True; i += 1
            else:
                lines.append(a[i]); i += 1
        # The lines travel base64-encoded, so that no shell quoting touches
        # them, and go out a character every 15 ms, as typed: Open Firmware
        # echoes each with a few bytes of escape sequences, and the ESCC's
        # receive FIFO holds three characters, so a line sent at full speed
        # loses characters (on a real Mac too).
        total = sum(wait + 0.02 * (len(ln) + 1) for ln in lines) + 2
        script = [STOP_READERS, "stty -F /dev/ttyS1 %d raw -echo" % baud,
                  "(timeout %d cat /dev/ttyS1 &)" % int(total + 1), "sleep 0.3"]
        for ln in lines:
            b64 = base64.b64encode((ln + "\r").encode("latin-1")).decode()
            script.append(r'''echo %s | base64 -d | od -An -v -to1 | tr -s ' ' '\n' | while read o; do [ -n "$o" ] && printf "\\$o" > /dev/ttyS1; usleep 15000; done''' % b64)
            script.append("sleep %g" % wait)
        script.append("sleep 1")
        remote = "; ".join(script)
        return ssh(remote, timeout=int(total) + 40) if raw else ssh_clean(remote, int(total) + 40)
    if cmd == "run":
        return ssh(" ".join(a[1:]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
