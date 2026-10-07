#!/usr/bin/env python3
"""Boot a cudadump disk image under QEMU's PowerPC Mac emulation (OpenBIOS).

    python qemuemu.py IMAGE [--machine g3beige|mac99] [--cpu CPU] [--boot "boot hd:2,%BOOT"]

Runs on Windows with the QEMU in C:\\Program Files\\qemu (or --qemu, or
qemu-system-ppc on the PATH). The image goes on the first IDE disk, the
console on a TCP serial port OpenBIOS uses because the machine has no
display; the command is typed at the `0 >` prompt and what comes back is
printed.

OpenBIOS boots the same image as the Mac: `hd:2` is the second entry of the
Apple partition map (ours) and `%BOOT` asks its mac-parts package for the
raw boot code at pmBootLoad with the entry at pmBootEntry, the Apple way
(packages/mac-parts.c, libopenbios/bootcode_load.c). Two limits: QEMU's
Cuda (hw/misc/macio/cuda.c) knows GET_TIME and GET_PRAM and answers every
other command with an error packet, and OpenBIOS's IDE driver has no write
method (disk-label's `write` returns -1), so the program's disk writes fail
and nothing lands in the image. What this proves is the boot path, the VIA
search through the device tree (mac-io at 81080000 on g3beige, 80000000 on
mac99, not the 7600's F3000000), the sync and the handshake against a
second Cuda model, and the error-packet path; the console line is the result.
"""

import argparse
import os
import re
import shutil
import socket
import subprocess
import sys
import time

QEMU_DEFAULT = r"C:\Program Files\qemu\qemu-system-ppc.exe"
PROMPT = re.compile(rb"\d+ > (\x1b\[[0-9;]*[A-Za-z])*$")


def find_qemu(given=None):
    for cand in ([given] if given else []) + [QEMU_DEFAULT, shutil.which("qemu-system-ppc")]:
        if cand and os.path.exists(cand):
            return cand
    raise RuntimeError("no qemu-system-ppc found; give --qemu")


class Console:
    def __init__(self, sock, echo=True):
        self.sock, self.echo, self.buf = sock, echo, b""
        self.sock.settimeout(0.2)

    def read_until(self, pattern, timeout, quiet=1.0):
        """Collect output until `pattern` matches the tail and the line has been
        quiet for a moment, or until the timeout: (text, matched)."""
        start = len(self.buf)
        deadline = time.time() + timeout
        last = time.time()
        while time.time() < deadline:
            try:
                data = self.sock.recv(65536)
                if not data:
                    return self.buf[start:].decode("latin-1"), None
                self.buf += data
                last = time.time()
                if self.echo:
                    sys.stdout.write(data.decode("latin-1").replace("\r", ""))
                    sys.stdout.flush()
            except socket.timeout:
                if pattern.search(self.buf[start:]) and time.time() - last > quiet:
                    return self.buf[start:].decode("latin-1"), True
        return self.buf[start:].decode("latin-1"), False

    def send(self, line):
        for ch in line.encode("ascii") + b"\r":
            self.sock.send(bytes([ch]))
            time.sleep(0.01)


def run(image, commands, machine="g3beige", cpu=None, ram=128, qemu=None, port=4555,
        timeout=120, boot_timeout=90, log_path=None, echo=True, extra=()):
    """Start QEMU on the image, type the commands, stop it. Returns the console
    text. Raises RuntimeError when QEMU dies or no prompt appears."""
    cmd = [find_qemu(qemu), "-M", machine, "-m", str(ram), "-nographic", "-monitor", "none",
           "-serial", "tcp:127.0.0.1:%d,server,nowait" % port,
           "-prom-env", "auto-boot?=false",
           "-drive", "file=%s,format=raw,if=ide,index=0" % image] + list(extra)
    if cpu:
        cmd += ["-cpu", cpu]
    log = open(log_path or os.devnull, "wb")
    emu = subprocess.Popen(cmd, stdout=log, stderr=log)
    con = None
    try:
        for _ in range(100):
            if emu.poll() is not None:
                raise RuntimeError("QEMU exited at once (code %d); see the log" % emu.returncode)
            sock = socket.socket()
            try:
                sock.connect(("127.0.0.1", port))
                break
            except OSError:
                sock.close()
                time.sleep(0.2)
        else:
            raise RuntimeError("QEMU opened no serial port")
        con = Console(sock, echo)
        text, ok = con.read_until(PROMPT, boot_timeout)
        if not ok:
            con.send("")
            text, ok = con.read_until(PROMPT, 10)
        if not ok:
            raise RuntimeError("no OpenBIOS prompt within %d s" % boot_timeout)
        for line in commands:
            con.send(line)
            text, ok = con.read_until(PROMPT, timeout)
            if ok is None:
                print("\n[the machine reset or QEMU closed the console]")
                break
            if not ok:
                print("\n[no prompt after %r within %d s]" % (line, timeout))
                break
        print()
        return con.buf.decode("latin-1")
    finally:
        emu.terminate()
        try:
            emu.wait(10)
        except subprocess.TimeoutExpired:
            emu.kill()
        log.close()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("image")
    p.add_argument("--machine", default="g3beige", help="g3beige (mac-io at 81080000) or mac99")
    p.add_argument("--cpu")
    p.add_argument("--ram", type=int, default=128)
    p.add_argument("--qemu")
    p.add_argument("--port", type=int, default=4555)
    p.add_argument("--timeout", type=float, default=120)
    p.add_argument("--log", help="QEMU's own output goes here")
    p.add_argument("--boot", default="boot hd:2,%BOOT", help="what to type at the prompt")
    a = p.parse_args()
    run(a.image, [a.boot], a.machine, a.cpu, a.ram, a.qemu, a.port, a.timeout, log_path=a.log)


if __name__ == "__main__":
    main()
