"""One Speedometer run on the board through misterkvms (the user's capture and
input tool; syn/speedo_run.py is the older mrext version): the core already
loaded through the OSD with os761ot.hda (Speedometer 4.02 at the root of the
disk) as SCSI disk 0, the Mac starting or about to. Waits for the Finder,
runs all tests, photographs the results, quits, shuts down. Loads nothing
and changes no setting.

    python speedo_kvms.py OUTDIR [LABEL]

Screenshots and log in OUTDIR. Leaves the machine off (dark)."""

import json
import os
import subprocess
import sys
import time

from PIL import Image, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
KVMS_DIR = os.path.join(HERE, "..", "..", "misterkvms")
KVMS = os.path.join(KVMS_DIR, "target", "release", "misterkvms-cli.exe")
POINTER = json.load(open(os.path.join(HERE, "pointer.json")))   # the arrow's black and white pixels from its tip


def kvms(*args):
    return subprocess.run([KVMS] + list(args), capture_output=True, text=True, cwd=KVMS_DIR)


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
    out = os.path.abspath(sys.argv[1])
    label = sys.argv[2] if len(sys.argv) > 2 else ""
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, "log.txt"), "a")

    def say(s):
        s = time.strftime("%H:%M:%S ") + s
        print(s, flush=True)
        log.write(s + "\n")
        log.flush()

    def shot(name):
        p = os.path.join(out, name + ".png")
        r = kvms("screenshot", p)
        return p if r.returncode == 0 else None

    def dark(p):
        return p is None or ImageStat.Stat(Image.open(p).convert("L")).mean[0] < 3

    def key(combo, pause=0.6):
        kvms("key", combo)
        time.sleep(pause)

    def move_by(dx, dy):
        # in small steps: the Mac's acceleration stays low
        n = max(1, int(max(abs(dx), abs(dy)) // 8))
        for i in range(n):
            kvms("mouse", "move", str(round(dx * (i + 1) / n) - round(dx * i / n)),
                 str(round(dy * (i + 1) / n) - round(dy * i / n)))

    def move_to(x, y, tries=6):
        """Move the pointer to (x, y) by screenshot and correction."""
        for _ in range(tries):
            p = shot("ptr")
            at = find_pointer(p) if p else None
            if at is None:
                say("  pointer not found: to the top left")
                move_by(-900, -700)
                continue
            dx, dy = x - at[0], y - at[1]
            say("  pointer at %s, want (%d, %d)" % (at, x, y))
            if abs(dx) <= 2 and abs(dy) <= 2:
                return True
            move_by(dx, dy)
            time.sleep(0.4)
        return False

    def click_at(x, y):
        ok = move_to(x, y)
        kvms("mouse", "click", "left")
        return ok

    say("run %s" % label)
    t0 = time.time()
    # the Finder: its menu bar (a white row across the top), the desktop a few seconds later
    menubar = None
    while time.time() - t0 < 240:
        p = shot("boot")
        if p and not dark(p):
            im = Image.open(p).convert("L")
            if im.size[0] >= 700 and ImageStat.Stat(im.crop((20, 1, 700, 5))).mean[0] > 230:
                menubar = time.time() - t0
                say("the menu bar at %.0f s" % menubar)
                break
        time.sleep(4)
    if menubar is None:
        say("no menu bar seen by 240 s")
        sys.exit(1)
    time.sleep(12)
    for _ in range(3):
        key("enter", 2)                            # the clock's and Energy Saver's dialogs
    shot("desktop")
    # the hard disk: type its name, open it; Speedometer: type its name, open it
    # (the Finder reopens the windows left open: close them first)
    # (the disk is "MacOS7-6-1": "Mac" alone picks the MacBench CD when it is mounted)
    for _ in range(3):
        key("alt+w", 1)
    kvms("type", "MacOS")
    time.sleep(0.5)
    key("alt+o", 3)
    kvms("type", "Spee")
    time.sleep(0.5)
    key("alt+o", 0)
    say("Speedometer opening")
    time.sleep(25)                                 # the splash
    shot("splash")
    # the splash and the registration nag: a click on the picture, then "Not Yet"
    say("splash clicked: %s" % click_at(360, 200))
    time.sleep(3)
    shot("nag")
    say("Not Yet clicked: %s" % click_at(417, 295))
    time.sleep(3)
    shot("main")
    key("alt+a", 2)                                # Run All Tests...
    key("alt+d", 1.5)                              # Desktop
    kvms("type", "MacOS")
    time.sleep(1)
    key("enter", 10)                               # OK; the Graf Test notice follows
    shot("graf")
    key("enter", 0)
    say("tests running")
    t1 = time.time()
    time.sleep(100)
    shot("done")
    key("enter", 2)                                # The tests are done!
    shot("results")
    say("tests took about %.0f s" % (time.time() - t1))
    key("alt+q", 2)
    # "Save before quitting?": No at about (305, 220)
    say("No clicked: %s" % click_at(305, 220))
    time.sleep(3)
    shot("quit")
    key("app", 3)                                  # the power key (the PC's Menu key): Shut Down
    key("enter", 3)
    t2 = time.time()
    off = False
    while time.time() - t2 < 60:
        if dark(shot("probe")):
            off = True
            break
        time.sleep(2)
    say("shut down: dark %s" % off)
    say("done in %.0f s" % (time.time() - t0))


if __name__ == "__main__":
    main()
