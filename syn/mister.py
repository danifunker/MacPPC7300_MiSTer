#!/usr/bin/env python3
"""Drive the MiSTer: put the core and the ROM on it, set the core's options,
load it, take a screenshot, use its keyboard and mouse, read the core's UART.

The board is controlled through the MiSTer Remote (mrext, port 8182), as the
other cores' tooling does (tools/misterdeploy): loading a core, screenshots,
keys and the mouse. SSH does what the Remote has no call for: copying files
to the card and the core's UART.

    python syn\\mister.py put-core [RBF]          output_files\\MacPPC7300.rbf -> _Unstable/MacPPC7300.rbf
    python syn\\mister.py put-rom FILE            -> games/MacPPC7300/boot.rom (loaded at core start)
    python syn\\mister.py put-nvram [FILE]        -> games/MacPPC7300/boot1.rom, the NVRAM image loaded at
                                                 core start (default syn\\nvram_of_prompt.bin)
    python syn\\mister.py rm-nvram                removes boot1.rom (the NVRAM starts blank)
    python syn\\mister.py put-disk FILE [NAME]    a disk image -> games/MacPPC7300/NAME
    python syn\\mister.py mount 0|1|4 PATH        the image (PATH from /media/fat) mounted as SCSI
                                                 disk 0 or 1, or the CD-ROM (4), at the core's
                                                 next start (config/MacPPC7300.sN, as the OSD writes it)
    python syn\\mister.py umount 0|1|2|4          ... no longer
    python syn\\mister.py make-nvr [PATH]         an empty 8 KB NVRAM image (default
                                                 games/MacPPC7300/MacPPC7300.nvr) if there is none, mounted
                                                 on block slot 2 (config/MacPPC7300.s2): the core loads
                                                 it at its start and keeps the NVRAM in it
    python syn\\mister.py cfg [--ram MB] [--monitor 16|13|12]
                              [--joy none|mousestick|firebird|gamepad|sidewinder] [--ptr]
                              [--eth] [--net eth0|eth1|wlan0|tap0] [--trace-mesh] [--l2 on|off]
                                                 writes config/MacPPC7300.CFG (--eth or --net: Ethernet
                                                 on, eth0 unless --net; --trace-mesh: the trace
                                                 also takes MESH's accesses and interrupt;
                                                 no OSD entry; --l2: the L2 cache, on unless off)
    python syn\\mister.py load                    loads _Unstable/MacPPC7300.rbf (Remote: /api/launch)
    python syn\\mister.py menu                    loads the menu core again (/api/launch/menu)
    python syn\\mister.py shot [OUT.png]          a screenshot of the core's output, fetched
                                                 (/api/screenshots)
    python syn\\mister.py keys TEXT               typed on the Remote's keyboard (\\n Return),
                                                 to the core's ADB keyboard
    python syn\\mister.py osd-mount N NAME ...     the OSD opened, down N items, Enter, then each
                                                 NAME typed in the file browser and Enter (e.g.
                                                 osd-mount 4 floppy arkanoid: the floppy's item,
                                                 games/MacPPC7300/floppy/arkanoid.img); blind
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
    python syn\\mister.py trace [--last N] [--from K]
                                                 the SCSI targets' trace (MacPPC7300_trace, DDR3
                                                 0x30500000): every command with its status,
                                                 sense, bytes moved and the Toolbox's answer;
                                                 bus resets; CD mounts (the last 40 unless asked)
    python syn\\mister.py trace-capture [SECONDS]  copies every new record on the MiSTer
                                                 (syn\\trstream.py, in the background) for longer
                                                 than the ring holds
    python syn\\mister.py trace-fetch OUT          ... brings the capture back; then
    python syn\\mister.py trace --file OUT         decodes it

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
CORE = "/media/fat/_Unstable/MacPPC7300.rbf"
RAM_OPTION = {16: 0, 24: 1, 48: 2, 64: 3, 96: 4, 6: 5, 120: 6}      # MacPPC7300.sv: O[3:1]

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
        rbf = a[1] if len(a) > 1 else os.path.join(ROOT, "output_files", "MacPPC7300.rbf")
        return scp(rbf, "root@%s:%s" % (host(), CORE))
    if cmd == "put-rom":
        ssh("mkdir -p /media/fat/games/MacPPC7300")
        return scp(a[1], "root@%s:/media/fat/games/MacPPC7300/boot.rom" % host())
    if cmd == "put-nvram":
        img = a[1] if len(a) > 1 else os.path.join(HERE, "nvram_of_prompt.bin")
        if os.path.getsize(img) != 8192:
            sys.exit("%s is not an 8 KB NVRAM image" % img)
        ssh("mkdir -p /media/fat/games/MacPPC7300")
        return scp(img, "root@%s:/media/fat/games/MacPPC7300/boot1.rom" % host())
    if cmd == "rm-nvram":
        return ssh("rm -f /media/fat/games/MacPPC7300/boot1.rom")
    if cmd == "put-disk":
        ssh("mkdir -p /media/fat/games/MacPPC7300")
        name = a[2] if len(a) > 2 else os.path.basename(a[1])
        return scp(a[1], "root@%s:/media/fat/games/MacPPC7300/%s" % (host(), name))
    if cmd == "mount":
        # what the Main writes when an SC slot's image is picked in the OSD
        # (menu.cpp, store_name): the path from /media/fat, read back and
        # mounted at the core's next start (user_io.cpp)
        slot, path = int(a[1]), a[2]
        if slot not in (0, 1, 2, 4) or "'" in path:
            sys.exit("mount 0|1|2|4 PATH (from /media/fat, e.g. games/MacPPC7300/os761.hda; 2: the NVRAM image; "
                     "4: a CD image, which needs the Main branch)")
        return ssh("test -f '/media/fat/%s' && printf '%%s\\0' '%s' > /media/fat/config/MacPPC7300.s%d && "
                   "xxd /media/fat/config/MacPPC7300.s%d" % (path, path, slot, slot))
    if cmd == "make-nvr":
        # an empty (all-zero) 8 KB NVRAM image, if there is none, mounted on
        # block slot 2: the core loads it at its start and saves the NVRAM
        # into it (MacPPC7300_nvsave)
        path = a[1] if len(a) > 1 else "games/MacPPC7300/MacPPC7300.nvr"
        if "'" in path:
            sys.exit("make-nvr [PATH]")
        return ssh("test -f '/media/fat/%s' || dd if=/dev/zero of='/media/fat/%s' bs=8192 count=1 2>/dev/null; "
                   "printf '%%s\\0' '%s' > /media/fat/config/MacPPC7300.s2 && ls -l '/media/fat/%s'"
                   % (path, path, path, path))
    if cmd == "umount":
        return ssh("rm -f /media/fat/config/MacPPC7300.s%d" % int(a[1]))
    if cmd == "cfg":
        ram, monitor = 16, 16
        joys = ["none", "mousestick", "firebird", "gamepad", "sidewinder"]   # MacPPC7300.sv: O[13:11]
        joy = a[a.index("--joy") + 1] if "--joy" in a else "none"
        if joy not in joys:
            sys.exit("--joy one of %s" % ", ".join(joys))
        for i in range(1, len(a) - 1):
            if a[i] == "--ram":
                ram = int(a[i + 1])
            if a[i] == "--monitor":
                monitor = int(a[i + 1])
        if ram not in RAM_OPTION or monitor not in (16, 13, 12):
            sys.exit("--ram one of %s, --monitor 16, 13 or 12 (the memory-test boot and the debug "
                     "readout are gone)" % sorted(RAM_OPTION))
        nets = ["eth0", "eth1", "wlan0", "tap0"]                                # MacPPC7300.sv: O[19:17], 0 off
        net = a[a.index("--net") + 1] if "--net" in a else "eth0"
        if net not in nets:
            sys.exit("--net one of %s" % ", ".join(nets))
        eth = (nets.index(net) + 1) if ("--eth" in a or "--net" in a) else 0
        l2 = a[a.index("--l2") + 1] if "--l2" in a else "on"                   # MacPPC7300.sv: O[4], 1 off
        if l2 not in ("on", "off"):
            sys.exit("--l2 on or off")
        status = ((RAM_OPTION[ram] << 1) | ((l2 == "off") << 4) | (joys.index(joy) << 11)
                  | (("--ptr" in a) << 14) | ({16: 0, 13: 1, 12: 2}[monitor] << 15)
                  | (eth << 17) | (("--trace-mesh" in a) << 29))
        data = "".join("\\x%02x" % ((status >> (8 * i)) & 0xFF) for i in range(4)) + "\\x00" * 12
        return ssh("printf '%s' > /media/fat/config/MacPPC7300.CFG && xxd /media/fat/config/MacPPC7300.CFG" % data)
    if cmd == "load":
        api("POST", "/api/launch", {"path": CORE[len("/media/fat/"):]})
        return 0
    if cmd == "menu":
        api("POST", "/api/launch/menu")
        return 0
    if cmd == "shot":
        out = a[1] if len(a) > 1 else "MacPPC7300_screen.png"
        def ours():
            return sorted((s for s in json.loads(api("GET", "/api/screenshots")) if s.get("core") == "MacPPC7300"),
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
        # a key's down and up as two steps, as a hand types (kbdRaw sends both at once)
        sys.path.insert(0, os.path.join(ROOT, "tools", "misterdeploy"))
        import ws_send
        steps = []
        for s in ws_send.expand_text(" ".join(a[1:])):
            if s.startswith("kbdRaw:"):
                steps += ["kbdRawDown:" + s[7:], "kbdRawUp:" + s[7:]]
            else:
                steps.append(s)
        return ws(steps)
    if cmd == "osd-mount":
        # blind, as the screenshots leave the OSD out: F12, down to the menu item, Enter; in
        # the file browser each name typed jumps to it (the Main's filter), Enter
        sys.path.insert(0, os.path.join(ROOT, "tools", "misterdeploy"))
        import ws_send
        steps = ["kbdRaw:88", "sleep:1"] + ["kbdRaw:108", "sleep:0.2"] * int(a[1]) + ["kbdRaw:28", "sleep:1.5"]
        for name in a[2:]:
            steps += ws_send.expand_text(name)
            steps += ["sleep:0.5", "kbdRaw:28", "sleep:1.5"]
        return ws(steps)
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
    if cmd == "trace-capture":
        # trstream.py on the MiSTer for SECONDS, in the background; `trace-fetch OUT` brings it back
        secs = int(a[1]) if len(a) > 1 else 60
        if scp(os.path.join(HERE, "trstream.py"), "root@%s:/tmp/trstream.py" % host()):
            return 1
        return ssh("nohup python3 /tmp/trstream.py %d /tmp/trace.bin > /tmp/trstream.log 2>&1 &" % secs)
    if cmd == "trace-fetch":
        out = a[1] if len(a) > 1 else "trace.bin"
        ssh("cat /tmp/trstream.log")
        return scp("root@%s:/tmp/trace.bin" % host(), out)
    if cmd == "trace":
        last = int(a[a.index("--last") + 1]) if "--last" in a else 40
        first = int(a[a.index("--from") + 1]) if "--from" in a else None
        fname = a[a.index("--file") + 1] if "--file" in a else None
        return trace(last, first, fname)
    print(__doc__)
    return 2


TRACE_BASE, TRACE_RECS = 0x30500000, 2048
SCSI_OPS = {0x00: "TEST UNIT READY", 0x03: "REQUEST SENSE", 0x08: "READ(6)", 0x0A: "WRITE(6)",
            0x12: "INQUIRY", 0x15: "MODE SELECT", 0x1A: "MODE SENSE", 0x1B: "START STOP",
            0x1E: "PREVENT", 0x25: "READ CAPACITY", 0x28: "READ(10)", 0x2A: "WRITE(10)",
            0x42: "READ SUB-CHANNEL", 0x43: "READ TOC", 0xC0: "EJECT", 0xC1: "READ TOC (Apple)",
            0xC2: "READ Q SUBCODE", 0xCC: "AUDIO STATUS", 0xD0: "TB LIST", 0xD1: "TB GET",
            0xD2: "TB COUNT", 0xD3: "TB SEND PREP", 0xD4: "TB SEND DATA", 0xD5: "TB SEND END",
            0xD6: "TB DEBUG", 0xD7: "TB LIST CDS", 0xD8: "TB SET NEXT CD", 0xD9: "TB DEVICES",
            0xDA: "TB COUNT CDS"}
MESH_REGS = ["count lo", "count hi", "FIFO", "sequence", "bus st 0", "bus st 1", "FIFO count", "exception",
             "error", "int mask", "interrupt", "source ID", "dest ID", "sync", "MESH ID", "sel timeout"]
MACE_REGS = {0: "RCVFIFO", 1: "XMTFIFO", 2: "XMTFC", 3: "XMTFS", 4: "XMTRC", 5: "RCVFC", 6: "RCVFS",
             7: "FIFOFC", 8: "IR", 9: "IMR", 10: "PR", 11: "BIUCC", 12: "FIFOCC", 13: "MACCC", 14: "PLSCC",
             15: "PHYCC", 16: "CHIPID lo", 17: "CHIPID hi", 18: "IAC", 20: "LADRF", 21: "PADR", 24: "MPC",
             26: "RNTPC", 27: "RCVCC", 29: "UTR", 30: "RTR1", 31: "RTR2"}
DMA_REGS = {0x00: "control", 0x04: "status", 0x08: "cmdptr hi", 0x0C: "cmdptr", 0x10: "int sel",
            0x14: "branch sel", 0x18: "wait sel"}
AWACS_REGS = {0: "control", 1: "codec ctl", 2: "codec st", 3: "clip", 4: "byte swap", 5: "frames"}


def trace(last, first, fname=None):
    if fname:
        # a capture of tools' trstream.py: records each after its 4-byte index
        raw = open(fname, "rb").read()
        recs = [(int.from_bytes(raw[k:k + 4], "little"), raw[k + 4:k + 36]) for k in range(0, len(raw) - 35, 36)]
        n, drops = (recs[-1][0] + 1 if recs else 0), 0
    else:
        # the region read on the MiSTer through /dev/mem (read() refuses addresses
        # above the kernel's memory; mmap does not)
        size = 64 + TRACE_RECS * 32
        script = ("import mmap,os,base64,sys;f=os.open('/dev/mem',os.O_RDONLY|os.O_SYNC);"
                  "m=mmap.mmap(f,%d,mmap.MAP_SHARED,mmap.PROT_READ,offset=%d);"
                  "sys.stdout.write(base64.b64encode(m[:%d]).decode())" % (size, TRACE_BASE, size))
        args = ["ssh"] + ssh_args() + ["root@" + host(), "python3 -c \"%s\"" % script]
        raw = base64.b64decode(subprocess.check_output(args, timeout=60))
        w = lambda off: int.from_bytes(raw[off:off + 8], "little")
        head = w(0)
        if head >> 32 != 0x54524345:
            print("no trace (header %016x): a core without MacPPC7300_trace, or nothing written yet" % head)
            return 1
        n, drops = head & 0xFFFFFFFF, w(8)
        lo = max(0, n - TRACE_RECS) if first is None else max(first, n - TRACE_RECS)
        if first is None:
            lo = max(lo, n - last)
        recs = [(i, raw[64 + (i % TRACE_RECS) * 32:][:32]) for i in range(lo, n)]
    for i, r in recs:
        kind, tid, st, key = r[0], r[1], r[2], r[3] & 15
        us = int.from_bytes(r[4:8], "little")
        flags = r[19]
        t = "%5d %9.3f" % (i, us / 1e6)
        fl = "flags %02x" % flags
        if kind == 1:
            cdb = r[8:18][:max(6, r[30])]
            op = cdb[0]
            nbytes = int.from_bytes(r[20:24], "little")
            line = "%s ID%d %-16s %s st %02x" % (t, tid, SCSI_OPS.get(op, "op %02x" % op),
                                                 " ".join("%02x" % b for b in cdb), st)
            if st:
                line += " sense %x/%02x" % (key, r[18])
            line += " bytes %d" % nbytes
            if 0xD0 <= op <= 0xDA and op not in (0xD6, 0xD9):
                line += " main %s slot %d" % (r[24:29].hex(), r[29] & 7)
            print(line + "  " + fl)
        elif kind == 7:
            cdb = r[8:18]
            print("%s ID%d start %-15s %s" % (t, tid, SCSI_OPS.get(cdb[0], "op %02x" % cdb[0]),
                                              " ".join("%02x" % b for b in cdb)))
        elif kind == 2:
            print("%s bus reset  %s" % (t, fl))
        elif kind == 3:
            print("%s CD mount  %s" % (t, fl))
        elif kind == 4:
            be, we = r[1] & 15, (r[1] >> 4) & 1
            addr = int.from_bytes(r[8:12], "little")
            data = int.from_bytes(r[12:16], "little")
            blk = (addr >> 8) & 0x1FF
            if blk in (0x180, 0x110, 0x111):
                reg = ("MESH " + MESH_REGS[(addr >> 4) & 15] if blk == 0x180 else
                       "MACE " + MACE_REGS.get((addr >> 4) & 31, "%d" % ((addr >> 4) & 31)))
                if be == 8:
                    data >>= 24
            elif blk == 0:
                reg = "GC int " + {0x20: "events", 0x24: "mask", 0x28: "clear", 0x2C: "levels"}.get(addr & 0xFC, "?")
            elif blk == 0x140:
                reg = "AWACS %s+%d" % (AWACS_REGS.get((addr >> 4) & 15, "%d" % ((addr >> 4) & 15)), addr & 3)
            else:
                reg = "DMA-%X " % (blk & 15) + DMA_REGS.get(addr & 0xFF, "%02x" % (addr & 0xFF))
            print("%s %-14s %s %0*x  (be %x)" % (t, reg, "w" if we else "r", 2 if be == 8 else 8, data, be))
        elif kind == 6:
            info = int.from_bytes(r[8:12], "little")
            sub = info >> 24
            if sub == 1:
                print("%s ADB key %02x %s%s" % (t, info & 0x7F, "up" if (info >> 8) & 1 else "down",
                                                "  DROPPED (queue full)" if (info >> 16) & 1 else ""))
            else:
                c = (info >> 16) & 0xFF
                kindc = {0: "reset/flush", 2: "listen", 3: "talk"}.get((c >> 2) & 3, "?")
                print("%s ADB cmd %02x (addr %d %s r%d) answer %02x queue %d" % (
                    t, c, c >> 4, kindc, c & 3, (info >> 8) & 0xFF, info & 7))
        elif kind == 10:
            s = r[1]
            print("%s IRQ cpu %d 68k %d | MESH mask %d event %d line %d | DMA-A mask %d event %d level %d"
                  % (t, s >> 7, (s >> 6) & 1, (s >> 5) & 1, (s >> 4) & 1, (s >> 3) & 1,
                     (s >> 2) & 1, (s >> 1) & 1, s & 1))
        elif kind == 11:
            s = r[1]
            print("%s IRQ cpu %d 68k %d | DMA-8 mask %d event %d level %d active %d"
                  % (t, s >> 7, (s >> 6) & 1, (s >> 5) & 1, (s >> 4) & 1, (s >> 3) & 1, (s >> 2) & 1))
        elif kind in (5, 8, 9):
            # MacPPC7300_dbdma fin_info: {cmd_ptr, cmd key bits reqCount, ..., ...}
            w1, w2 = int.from_bytes(r[8:16], "little"), int.from_bytes(r[16:24], "little")
            fi = w1 | (w2 << 64)
            ptr, cmdw, x, y = fi >> 96, (fi >> 64) & 0xFFFFFFFF, (fi >> 32) & 0xFFFFFFFF, fi & 0xFFFFFFFF
            cmd, key, bits, req = cmdw >> 28, (cmdw >> 24) & 7, (cmdw >> 16) & 0xFF, cmdw & 0xFFFF
            c = "@%08x cmd %d key %d i%d b%d w%d req %d" % (ptr, cmd, key, (bits >> 4) & 3, (bits >> 2) & 3,
                                                           bits & 3, req)
            if kind == 5 and cmd in (4, 5):
                print("%s DMA-%d done %s res %d status %04x value %08x"
                      % (t, r[1], c, x >> 16, x & 0xFFFF, y))
            elif kind == 5:
                print("%s DMA-%d done %s res %d status %04x intsel %04x irq %d"
                      % (t, r[1], c, x >> 16, x & 0xFFFF, y >> 16, y & 1))
            elif kind == 8:
                print("%s DMA-%d fetch %s addr %08x dep %08x" % (t, r[1], c, x, y))
            else:
                print("%s DMA-%d STOPPED in state %d %s res %d status %04x conds w%d b%d i%d"
                      % (t, r[1], y >> 28, c, x >> 16, x & 0xFFFF, (y >> 2) & 1, (y >> 1) & 1, y & 1))
        elif kind == 12:
            # the CPU's performance counters (syn/perf.py accounts them): part 0 starts with the cycles
            words = [int.from_bytes(r[8 + 4 * k:12 + 4 * k], "little") for k in range(6)]
            print("%5d perf part %d cycles %u: %s" % (i, r[1], us, " ".join("%u" % w for w in words)))
        else:
            print("%s kind %d %s" % (t, kind, r.hex()))
    print("%d records, %d dropped (flags: cd_ok ejected prevent cd_valid tb cdc disks hk)" % (n, drops))
    return 0


if __name__ == "__main__":
    sys.exit(main())
