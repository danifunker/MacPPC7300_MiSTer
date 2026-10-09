"""Load the core on the board and photograph its screen every few seconds: the
time from the core's load to the Finder.

    python boottime.py OUTDIR [--mount0 PATH] [--reboot-linux] [--every S] [--for S]

--reboot-linux sends Ctrl+Option+Delete to a Debian at its login prompt and
waits until the screen goes dark (the machine's reset) before loading."""

import os
import subprocess
import sys
import time

MISTER = [sys.executable, r"C:\Temp\mistercore\PPC_Mac\syn\mister.py"]


def mister(*args):
    return subprocess.run(MISTER + list(args), capture_output=True, text=True)


def main():
    a = sys.argv[1:]
    out = a[0]
    every = float(a[a.index("--every") + 1]) if "--every" in a else 5.0
    total = float(a[a.index("--for") + 1]) if "--for" in a else 150.0
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "log.txt"), "a")

    def say(s):
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    if "--mount0" in a:
        r = mister("mount", "0", a[a.index("--mount0") + 1])
        say("mount 0: rc %d %s" % (r.returncode, (r.stdout + r.stderr).strip()[-200:]))
    if "--shutdown-mac" in a:
        # the power key (Menu), then Return in its dialog: the machine goes off (no video)
        r = mister("ws", "kbdRaw:127", "sleep:3", "kbdRaw:28")
        say("shut down: rc %d" % r.returncode)
        t = time.time()
        while time.time() - t < 120:
            r = mister("shot", os.path.join(out, "shutdown.png"))
            if r.returncode != 0:
                say("screen dark after %.1f s: the machine is off" % (time.time() - t))
                break
            time.sleep(1.0)
        else:
            say("the screen never went dark: NOT loading (a reload with a volume mounted corrupts it)")
            sys.exit(2)
    if "--reboot-linux" in a:
        r = mister("ws", "kbdRawDown:29", "sleep:0.2", "kbdRawDown:125", "sleep:0.2", "kbdRaw:111",
                   "sleep:0.3", "kbdRawUp:125", "kbdRawUp:29")
        say("ctrl+option+delete: rc %d" % r.returncode)
        # Linux's console is dark; the ROM's screen after the reset is grey
        from PIL import Image, ImageStat
        t = time.time()
        while time.time() - t < 120:
            p = os.path.join(out, "reboot.png")
            r = mister("shot", p)
            mean = ImageStat.Stat(Image.open(p).convert("L")).mean[0] if r.returncode == 0 else -1
            say("  %.1f s: shot rc %d mean %.0f" % (time.time() - t, r.returncode, mean))
            if mean > 100:
                say("the ROM's grey screen after %.1f s: loading now" % (time.time() - t))
                break
            time.sleep(0.5)
        else:
            say("no grey screen seen: NOT loading")
            sys.exit(2)
    t0 = time.time()
    r = mister("load")
    say("load: rc %d at %s" % (r.returncode, time.strftime("%H:%M:%S")))
    while time.time() - t0 < total:
        el = time.time() - t0
        r = mister("shot", os.path.join(out, "t%03d.png" % int(el)))
        say("t+%5.1f s: shot rc %d" % (el, r.returncode))
        time.sleep(every)
    say("done")


if __name__ == "__main__":
    main()
