#!/usr/bin/env python3
"""Boot ppctest disk images under Apple's Open Firmware in dingusppc.

Runs inside WSL/Linux. It starts the emulator with a real Old World ROM, the
console on the emulated modem port, and Open Firmware stopped at its prompt
(the emulator's own NVRAM file only); then types the given commands at the
`0 >` prompt, as one would on a serial terminal, and prints what comes back.

    python3 ofemu.py --rom runs/my7600.rom --nvram NVRAM.bin \\
        --ext TEST.hda[:ROMDUMP.hda] [--cpu 604] "boot scsi/sd@0:0" ...

Disks get SCSI IDs 0, 1, 2, 4, ... in the order given, on the external bus
(--ext, `scsi`) or the internal one (--int, `scsi-int`). The images are worked
on in a scratch directory and copied back afterwards; the emulated Mac's PRAM
and NVRAM persist between runs. This checks our code against the real
firmware and a second CPU model; what the emulated CPU returns for a test
vector is the emulator's opinion only.
"""

import argparse
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import time

DINGUS = os.path.expanduser("~/.cache/ppcmac/dingusppc-build/bin/dingusppc")
WORK = os.path.expanduser("~/.cache/ppcmac/dingus-run")
STATE = os.path.expanduser("~/.cache/ppcmac/dingus-state")     # the emulated Mac's PRAM and NVRAM
PROMPT = re.compile(rb"\d+ > \r?(\x1b\[[0-9;]*[A-Za-z])*$")   # "0 > " plus cursor codes


class Console:
    def __init__(self, sock, echo=True):
        self.sock, self.echo, self.buf = sock, echo, b""

    def read_until(self, pattern, timeout, quiet=3.0):
        """Collect output until `pattern` matches the tail and the line has
        been quiet for a moment, or until the timeout. Returns (text, matched);
        matched is None when the emulated machine reset (the socket closed)."""
        start = len(self.buf)
        deadline = time.time() + timeout
        last = time.time()
        while time.time() < deadline:
            r, _, _ = select.select([self.sock], [], [], 0.2)
            if r:
                data = self.sock.recv(65536)
                if not data:
                    return self.buf[start:].decode("latin-1"), None
                self.buf += data
                last = time.time()
                if self.echo:
                    sys.stdout.write(data.decode("latin-1").replace("\r", ""))
                    sys.stdout.flush()
            elif pattern.search(self.buf[start:]) and time.time() - last > quiet:
                return self.buf[start:].decode("latin-1"), True
        return self.buf[start:].decode("latin-1"), False

    def send(self, line):
        for ch in line.encode("ascii") + b"\r":       # no flow control: go gently
            self.sock.send(bytes([ch]))
            time.sleep(0.01)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rom", required=True)
    p.add_argument("--int", dest="internal", default="", help="images for the internal SCSI bus, colon-separated")
    p.add_argument("--ext", default="", help="images for the external SCSI bus, colon-separated")
    p.add_argument("--cpu", default="604")
    p.add_argument("--machine", default="pm7600")
    p.add_argument("--ram", default="16")
    p.add_argument("--nvram", help="8192-byte NVRAM image for the emulated Mac, used when it has "
                                   "none yet; it should have auto-boot? false and the console on ttya")
    p.add_argument("--fresh", action="store_true", help="forget the emulated Mac's PRAM and NVRAM")
    p.add_argument("--timeout", type=float, default=900, help="seconds allowed per command")
    p.add_argument("--boot-timeout", type=float, default=240)
    p.add_argument("--no-copy-back", action="store_true")
    p.add_argument("--verbosity", default="0", help="emulator log verbosity (emulator.log in the work dir)")
    p.add_argument("commands", nargs="*")
    a = p.parse_args()

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    if a.fresh:
        shutil.rmtree(STATE, ignore_errors=True)
    os.makedirs(STATE, exist_ok=True)
    shutil.copy(a.rom, os.path.join(WORK, "rom.bin"))
    for name in ("pram.bin", "nvram.bin"):
        if os.path.exists(os.path.join(STATE, name)):
            shutil.copy(os.path.join(STATE, name), os.path.join(WORK, name))
    if a.nvram and not os.path.exists(os.path.join(WORK, "nvram.bin")):
        with open(a.nvram, "rb") as fh:
            data = fh.read()
        with open(os.path.join(WORK, "nvram.bin"), "wb") as fh:      # dingusppc's file format
            fh.write(b"DINGUSPPCNVRAM" + bytes(1) + len(data).to_bytes(2, "little") + data)

    images, local = [], []
    cmd = [DINGUS, "-r", "-m", a.machine, "-b", "rom.bin", "--cpu", a.cpu,
           "--rambank1_size", a.ram, "--serial_backend=socket",
           "--log-to-stderr", "--log-verbosity", a.verbosity]
    for opt, text, prefix in (("--hdd_img2", a.internal, "int"), ("--hdd_img", a.ext, "ext")):
        paths = [x for x in text.split(":") if x]
        names = []
        for i, path in enumerate(paths):
            name = "%s%d.hda" % (prefix, i)
            shutil.copy(path, os.path.join(WORK, name))
            images.append(path)
            local.append(name)
            names.append(name)
        if names:
            cmd += [opt, ":".join(names)]
    env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    log = open(os.path.join(WORK, "emulator.log"), "wb")
    emu = subprocess.Popen(cmd, cwd=WORK, env=env, stdin=subprocess.PIPE, stdout=log, stderr=log)
    status = 1
    path = os.path.join(WORK, "dingussocket")

    def connect():
        """Attach to the console (again, after the machine reset itself) and
        wait for the prompt."""
        for _ in range(300):
            if emu.poll() is not None:
                raise RuntimeError("the emulator exited; see %s/emulator.log" % WORK)
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.connect(path)
                break
            except OSError:
                sock.close()
                time.sleep(0.2)
        else:
            raise RuntimeError("no console socket; see %s/emulator.log" % WORK)
        con = Console(sock)
        # output printed before the emulator accepted us is lost, so ask for a
        # fresh prompt rather than waiting for the banner
        text, ok = con.read_until(PROMPT, 5)
        if not ok:
            con.send("")
            text, ok = con.read_until(PROMPT, a.boot_timeout)
        if not ok:
            raise RuntimeError("no Open Firmware prompt within %d s (tail: %r)"
                               % (a.boot_timeout, con.buf[-48:]))
        return con

    try:
        con = connect()
        for line in a.commands:
            for attempt in range(2):
                con.send(line)
                text, ok = con.read_until(PROMPT, a.timeout)
                if ok is None:
                    print("\n[the machine reset itself; reconnecting and repeating %r]" % line)
                    time.sleep(1)
                    con = connect()
                    continue
                break
            if not ok:
                print("\n[no prompt after %r within %d s]" % (line, a.timeout))
                break
        else:
            status = 0
        print()
    finally:
        emu.terminate()
        try:
            emu.wait(10)
        except subprocess.TimeoutExpired:
            emu.kill()
        log.close()
        if not a.no_copy_back:
            for path, name in zip(images, local):
                shutil.copy(os.path.join(WORK, name), path)
        for name in ("pram.bin", "nvram.bin"):
            if os.path.exists(os.path.join(WORK, name)):
                shutil.copy(os.path.join(WORK, name), os.path.join(STATE, name))
    sys.exit(status)


if __name__ == "__main__":
    main()
