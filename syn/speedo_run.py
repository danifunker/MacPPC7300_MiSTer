"""One Speedometer run on the board, from an OFF machine: put the given
bitstream on the card, load it, boot Mac OS 7.6.1 (os761ot.hda, Speedometer
4.02 at the root of the disk), run all tests, photograph the results, quit,
shut down. Everything by keyboard except Speedometer's "save?" alert.

    python speedo_run.py OUTDIR RBF [--l2 off]

Screenshots and log in OUTDIR. Leaves the machine off (dark)."""

import os
import subprocess
import sys
import time

import json
from PIL import Image, ImageStat

MISTER = [sys.executable, r"C:\Temp\mistercore\PPC_Mac\syn\mister.py"]
CMD = 56        # the PC's Alt is the Mac's Command
HERE = os.path.dirname(os.path.abspath(__file__))
POINTER = json.load(open(os.path.join(HERE, "pointer.json")))   # the arrow's black and white pixels from its tip


def mister(*args):
    return subprocess.run(MISTER + list(args), capture_output=True, text=True)


def find_pointer(path):
    """The arrow pointer's tip in a screenshot, or None."""
    im = Image.open(path).convert("L")
    px = im.load()
    w, h = im.size
    best, where = 0, None
    for y in range(0, h - 20):
        for x in range(2, w - 14):
            if px[x, y] >= 50 or px[x, y + 1] >= 50 or px[x + 1, y + 1] >= 50:
                continue
            score = sum(1 for dx, dy in POINTER["black"] if px[x + dx, y + dy] < 50)
            score += sum(1 for dx, dy in POINTER["white"] if px[x + dx, y + dy] > 200)
            if score > best:
                best, where = score, (x, y)
    return where if best >= 80 else None


def main():
    a = sys.argv[1:]
    out, rbf = a[0], a[1]
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "log.txt"), "a")

    def say(s):
        s = time.strftime("%H:%M:%S ") + s
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    def shot(name):
        r = mister("shot", os.path.join(out, name + ".png"))
        say("shot %s: rc %d" % (name, r.returncode))
        return r.returncode == 0

    def ws(*steps):
        return mister("ws", *steps)

    def cmd_key(code):
        ws("kbdRawDown:%d" % CMD, "sleep:0.1", "kbdRaw:%d" % code, "sleep:0.1", "kbdRawUp:%d" % CMD)

    def move_to(x, y, tries=5):
        """Move the pointer to (x, y) by screenshot and correction."""
        for i in range(tries):
            p = os.path.join(out, "ptr.png")
            if mister("shot", p).returncode != 0:
                return False
            at = find_pointer(p)
            if at is None:
                say("  pointer not found: pinning it top left")
                mister("mouse", "-3000", "-3000", "30")
                mister("mouse", "40", "40", "10")
                continue
            dx, dy = x - at[0], y - at[1]
            say("  pointer at %s, want (%d, %d)" % (at, x, y))
            if abs(dx) <= 2 and abs(dy) <= 2:
                return True
            steps = max(1, max(abs(dx), abs(dy)) // 3)
            mister("mouse", str(int(dx / 0.76)), str(int(dy / 0.76)), str(steps))
            ws("sleep:0.4")
        return False

    def click_at(x, y):
        ok = move_to(x, y)
        ws("sleep:0.3", "mouseBtn:left_down", "sleep:0.3", "mouseBtn:left_up")
        return ok

    def wait_dark(limit):
        t = time.time()
        while time.time() - t < limit:
            if mister("shot", os.path.join(out, "probe.png")).returncode != 0:
                return True
            time.sleep(1)
        return False

    if shot("before"):
        say("the screen is not dark: the machine is not off; refusing to load")
        sys.exit(2)
    say("put-core %s: rc %d" % (rbf, mister("put-core", rbf).returncode))
    cfg = ["cfg", "--ram", "120", "--eth"]
    if "--l2" in a:
        cfg += ["--l2", a[a.index("--l2") + 1]]
    say("%s: rc %d" % (" ".join(cfg), mister(*cfg).returncode))
    t0 = time.time()
    say("load: rc %d" % mister("load").returncode)
    # the boot: the Finder's menu bar about 100 s in (its white row across the top),
    # the desktop a few seconds later; the dialogs (clock, Energy Saver) closed with Return
    time.sleep(70)
    menubar = None
    while time.time() - t0 < 160:
        el = time.time() - t0
        p = os.path.join(out, "boot%03d.png" % int(el))
        if mister("shot", p).returncode == 0:
            im = Image.open(p).convert("L")
            top = ImageStat.Stat(im.crop((20, 1, 700, 5))).mean[0]
            if top > 230:
                menubar = el
                say("the menu bar at %.0f s" % el)
                break
        time.sleep(4)
    if menubar is None:
        say("no menu bar seen by 160 s")
    time.sleep(12)
    ws("kbdRaw:28", "sleep:2", "kbdRaw:28", "sleep:2", "kbdRaw:28", "sleep:2")
    shot("desktop")
    # the hard disk: type its name, open it; Speedometer: type its name, open it
    # (the Finder reopens the windows left open: close them first, so the
    # typing selects on the desktop)
    for _ in range(3):
        cmd_key(17)                               # Command-W
        ws("sleep:1")
    mister("keys", "Mac")
    ws("sleep:0.5")
    cmd_key(24)                                   # Command-O
    ws("sleep:3")
    mister("keys", "Spee")
    ws("sleep:0.5")
    cmd_key(24)
    say("Speedometer opening")
    time.sleep(25)                                # the splash
    shot("splash")
    # the splash and the registration nag: a click on the picture, then "Not Yet"
    # (Return would Register)
    mister("mouse", "-3000", "-3000", "30")
    mister("mouse", "480", "270", "160")          # about (360, 200)
    ws("mouseBtn:left", "sleep:3")
    shot("nag")
    say("Not Yet clicked: %s" % click_at(417, 295))
    ws("sleep:3")
    shot("main")
    cmd_key(30)                                   # Command-A: Run All Tests...
    ws("sleep:2")
    cmd_key(32)                                   # Command-D: Desktop
    ws("sleep:1.5")
    mister("keys", "Mac")
    ws("sleep:1", "kbdRaw:28", "sleep:10")        # OK; the Graf Test notice follows
    shot("graf")
    ws("kbdRaw:28")
    say("tests running")
    time.sleep(100)
    shot("done")
    ws("kbdRaw:28", "sleep:2")                    # The tests are done!
    shot("results")
    cmd_key(16)                                   # Command-Q
    ws("sleep:2")
    # "Save before quitting?": No at about (305, 220)
    say("No clicked: %s" % click_at(305, 220))
    ws("sleep:3")
    shot("quit")
    ws("kbdRaw:127", "sleep:3", "kbdRaw:28", "sleep:3")   # the power key, Shut Down
    say("shut down: dark %s" % wait_dark(60))
    say("done in %.0f s" % (time.time() - t0))


if __name__ == "__main__":
    main()
