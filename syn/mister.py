#!/usr/bin/env python3
"""Drive the MiSTer: put the core and the ROM on it, set the core's options,
load it, take a screenshot, use its keyboard and mouse, read the core's UART.

The board is controlled through the MiSTer Remote (mrext, port 8182), as the
other cores' tooling does (tools/misterdeploy): loading a core, screenshots,
keys and the mouse. SSH does what the Remote has no call for: copying files
to the card and the core's UART.

    python syn\\mister.py put-core [RBF]          output_files\\PPCMac.rbf -> _Unstable/PPCMac.rbf
    python syn\\mister.py put-rom FILE            -> games/PPCMac/boot.rom (loaded at core start)
    python syn\\mister.py put-nvram [FILE]        -> games/PPCMac/boot1.rom, the NVRAM image loaded at
                                                 core start (default syn\\nvram_of_prompt.bin)
    python syn\\mister.py rm-nvram                removes boot1.rom (the NVRAM starts blank)
    python syn\\mister.py put-disk FILE [NAME]    a disk image -> games/PPCMac/NAME
    python syn\\mister.py mount 0|1 PATH          the image (PATH from /media/fat) mounted as SCSI
                                                 disk 0 or 1 at the core's next start
                                                 (config/PPCMac.s0 or .s1, as the OSD writes it)
    python syn\\mister.py umount 0|1|2            ... no longer
    python syn\\mister.py make-nvr [PATH]         an empty 8 KB NVRAM image (default
                                                 games/PPCMac/PPCMac.nvr) if there is none, mounted
                                                 on block slot 2 (config/PPCMac.s2): the core loads
                                                 it at its start and keeps the NVRAM in it
    python syn\\mister.py cfg [--ram MB] [--boot rom|memtest] [--uart modem|debug]
                              [--picture mac|debug] [--monitor 16|13|12]
                              [--joy none|mousestick|firebird|gamepad|sidewinder] [--ptr]
                                                 writes config/PPCMac.CFG
    python syn\\mister.py load                    loads _Unstable/PPCMac.rbf (Remote: /api/launch)
    python syn\\mister.py menu                    loads the menu core again (/api/launch/menu)
    python syn\\mister.py shot [OUT.png]          a screenshot of the core's output, fetched
                                                 (/api/screenshots)
    python syn\\mister.py keys TEXT               typed on the Remote's keyboard (\\n Return),
                                                 to the core's ADB keyboard
    python syn\\mister.py mouse DX DY [STEPS]     the Remote's mouse moved, right and down
    python syn\\mister.py click [left|right]      its button
    python syn\\mister.py ws STEP ...             any tools\\misterdeploy\\ws_send.py steps
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
ignores), MISTER_HTTP_PORT (the Remote's, default 8182) and MISTER_KEY
(default ~/.ssh/mister_only). Only key-based SSH is used; nothing asks for a
password (BatchMode). The websocket needs Python's websockets package.
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

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


# ---- the MiSTer Remote (mrext) on port 8182: how the board is controlled ----

def remote():
    return "http://%s:%s" % (host(), os.environ.get("MISTER_HTTP_PORT", "8182"))


def api(method, path, body=None, timeout=20):
    """A Remote API call: the response body (bytes)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(remote() + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def ws(steps):
    """Steps for the Remote's websocket (tools/misterdeploy/ws_send.py):
    kbd:, kbdRaw:, kbdRawDown:, kbdRawUp:, text:, mouseMove:, mouseBtn:, sleep:."""
    sys.path.insert(0, os.path.join(ROOT, "tools", "misterdeploy"))
    import asyncio
    import ws_send
    asyncio.run(ws_send.run(host(), int(os.environ.get("MISTER_HTTP_PORT", "8182")), steps))
    return 0


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
    if cmd == "put-disk":
        ssh("mkdir -p /media/fat/games/PPCMac")
        name = a[2] if len(a) > 2 else os.path.basename(a[1])
        return scp(a[1], "root@%s:/media/fat/games/PPCMac/%s" % (host(), name))
    if cmd == "mount":
        # what the Main writes when an SC slot's image is picked in the OSD
        # (menu.cpp, store_name): the path from /media/fat, read back and
        # mounted at the core's next start (user_io.cpp)
        slot, path = int(a[1]), a[2]
        if slot not in (0, 1, 2) or "'" in path:
            sys.exit("mount 0|1|2 PATH (from /media/fat, e.g. games/PPCMac/os761.hda; 2: the NVRAM image)")
        return ssh("test -f '/media/fat/%s' && printf '%%s\\0' '%s' > /media/fat/config/PPCMac.s%d && "
                   "xxd /media/fat/config/PPCMac.s%d" % (path, path, slot, slot))
    if cmd == "make-nvr":
        # an empty (all-zero) 8 KB NVRAM image, if there is none, mounted on
        # block slot 2: the core loads it at its start and saves the NVRAM
        # into it (PPCMac_nvsave)
        path = a[1] if len(a) > 1 else "games/PPCMac/PPCMac.nvr"
        if "'" in path:
            sys.exit("make-nvr [PATH]")
        return ssh("test -f '/media/fat/%s' || dd if=/dev/zero of='/media/fat/%s' bs=8192 count=1 2>/dev/null; "
                   "printf '%%s\\0' '%s' > /media/fat/config/PPCMac.s2 && ls -l '/media/fat/%s'"
                   % (path, path, path, path))
    if cmd == "umount":
        return ssh("rm -f /media/fat/config/PPCMac.s%d" % int(a[1]))
    if cmd == "cfg":
        ram, boot, uart, picture, monitor = 16, "rom", "modem", "mac", 16
        joys = ["none", "mousestick", "firebird", "gamepad", "sidewinder"]   # PPCMac.sv: O[13:11]
        joy = a[a.index("--joy") + 1] if "--joy" in a else "none"
        if joy not in joys:
            sys.exit("--joy one of %s" % ", ".join(joys))
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
                or picture not in ("mac", "debug") or monitor not in (16, 13, 12)):
            sys.exit("--ram one of %s, --boot rom or memtest, --uart modem or debug, --picture mac or debug, "
                     "--monitor 16, 13 or 12" % sorted(RAM_OPTION))
        status = ((RAM_OPTION[ram] << 1) | ((boot == "memtest") << 4) | ((uart == "debug") << 6)
                  | ((picture == "debug") << 7) | (joys.index(joy) << 11)
                  | (("--ptr" in a) << 14) | ({16: 0, 13: 1, 12: 2}[monitor] << 15))
        data = "".join("\\x%02x" % ((status >> (8 * i)) & 0xFF) for i in range(4)) + "\\x00" * 12
        return ssh("printf '%s' > /media/fat/config/PPCMac.CFG && xxd /media/fat/config/PPCMac.CFG" % data)
    if cmd == "load":
        api("POST", "/api/launch", {"path": CORE[len("/media/fat/"):]})
        return 0
    if cmd == "menu":
        api("POST", "/api/launch/menu")
        return 0
    if cmd == "shot":
        out = a[1] if len(a) > 1 else "PPCMac_screen.png"
        def ours():
            return sorted((s for s in json.loads(api("GET", "/api/screenshots")) if s.get("core") == "PPCMac"),
                          key=lambda s: s["modified"])
        before = {s["path"] for s in ours()}
        api("POST", "/api/screenshots")
        for _ in range(20):
            time.sleep(0.5)
            new = [s for s in ours() if s["path"] not in before]
            if new:
                break
        else:
            sys.exit("no new screenshot appeared")
        time.sleep(0.5)                       # the file is complete
        with open(out, "wb") as f:
            f.write(api("GET", "/api/screenshots/" + urllib.request.quote(new[-1]["path"]), timeout=60))
        print(out)
        return 0
    if cmd == "ws":
        return ws(a[1:])
    if cmd == "keys":
        return ws(["text:" + " ".join(a[1:])])
    if cmd == "mouse":
        dx, dy = int(a[1]), int(a[2])
        n = int(a[3]) if len(a) > 3 else max(1, (max(abs(dx), abs(dy)) + 19) // 20)
        steps = []
        for i in range(n):
            steps += ["mouseMove:%d,%d" % (dx * (i + 1) // n - dx * i // n, dy * (i + 1) // n - dy * i // n)]
        return ws(steps)
    if cmd == "click":
        return ws(["mouseBtn:" + (a[1] if len(a) > 1 else "left")])
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
