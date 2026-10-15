"""The board through misterkvms-cli (the user's capture and input tool), as the
sessions of 2026-10-15 drove it. Cores load through the OSD, never by API.

    python syn\\kvms.py load RBF             copy RBF to _Unstable/MacPPC7300_test.rbf and load it
                                            through the OSD's browser (which opens on the core loaded
                                            last: load MacPPC7300_test once by hand). Only with no OS
                                            running: the machine off, or Linux at "Restarting system"
    python syn\\kvms.py click X Y [X Y ...]  the Mac's arrow pointer to each point (by screenshot and
                                            correction) and a click
    python syn\\kvms.py dclick X Y           ... a double-click
    python syn\\kvms.py move X Y             ... no click (a submenu; Mac OS 8 and later keep a
                                            clicked menu open, 7.6.1 does not)
    python syn\\kvms.py finder [LIMIT]       wait for Mac OS's menu bar (7.6.1's white, 9.1's grey)
    python syn\\kvms.py off [LIMIT]          wait for the machine to be off (no signal on the capture)
    python syn\\kvms.py keys COMBO ...       keys in a row ("menu", "down*6", "enter"; *N repeats)
    python syn\\kvms.py shot OUT.png [--native]   --native: the framework's own picture, the core's size

Coordinates are the capture's (screenshot without --native). Each command leaves its last
screenshot in Scratch\\kvms_last.png. The OSD: Enter cycles an option's value, Left and Right
change pages, the menu key closes it; "Reset and close OSD" is two Ups from the top."""

import os
import subprocess
import sys
import time

from PIL import Image, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from speedo_kvms import find_pointer, KVMS, KVMS_DIR   # noqa: E402
from mister import host, ssh_args                      # noqa: E402

LAST = os.path.join(HERE, "..", "Scratch", "kvms_last.png")


def kvms(*a):
    return subprocess.run([KVMS] + list(a), capture_output=True, text=True, cwd=KVMS_DIR)


def shot(path=LAST, native=False):
    r = kvms("screenshot", *(["--native"] if native else []), os.path.abspath(path))
    return path if r.returncode == 0 else None


def keys(*combos):
    for c in combos:
        name, _, n = c.partition("*")
        for _ in range(int(n or 1)):
            kvms("key", name)
            time.sleep(0.4)


def move_by(dx, dy):
    n = max(1, int(max(abs(dx), abs(dy)) // 8))
    for i in range(n):
        kvms("mouse", "move", str(round(dx * (i + 1) / n) - round(dx * i / n)),
             str(round(dy * (i + 1) / n) - round(dy * i / n)))


def point(x, y):
    for _ in range(6):
        if not shot():
            continue
        at = find_pointer(LAST)
        if at is None:
            move_by(-20, -20)
            continue
        dx, dy = x - at[0], y - at[1]
        if abs(dx) <= 2 and abs(dy) <= 2:
            return True
        move_by(dx, dy)
        time.sleep(0.3)
    return False


def menubar(path):
    im = Image.open(path).convert("L")
    return im.size[0] >= 600 and ImageStat.Stat(im.crop((20, 1, min(700, im.size[0] - 20), 5))).mean[0] > 200


def off(path):
    im = Image.open(path).convert("L")
    return im.size[0] == 1920 and ImageStat.Stat(im).mean[0] < 1


def wait_for(test, limit):
    t0 = time.time()
    while time.time() - t0 < limit:
        if shot() and test(LAST):
            return time.time() - t0
        time.sleep(2)
    return None


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 2
    cmd = a[0]
    if cmd == "load":
        key = ssh_args()
        dst = "root@%s:/media/fat/_Unstable/MacPPC7300_test.rbf" % host()
        subprocess.run(["scp"] + key + [a[1], dst], check=True)
        keys("menu")
        time.sleep(0.6)
        keys("left", "right", "right", "enter")
        time.sleep(0.8)
        keys("enter")
        print("loaded %s" % time.strftime("%H:%M:%S"))
    elif cmd in ("click", "dclick", "move"):
        pts = [int(v) for v in a[1:]]
        for x, y in zip(pts[0::2], pts[1::2]):
            if not point(x, y):
                print("pointer not found near (%d, %d)" % (x, y))
                return 1
            if cmd != "move":
                kvms("mouse", "click", "left")
                if cmd == "dclick":
                    kvms("mouse", "click", "left")
            time.sleep(1.0)
        shot()
    elif cmd in ("finder", "off"):
        t = wait_for(menubar if cmd == "finder" else off, float(a[1]) if len(a) > 1 else 240)
        print("%s after %.0f s" % (cmd, t) if t is not None else "FAIL: no %s" % cmd)
        return 0 if t is not None else 1
    elif cmd == "keys":
        keys(*a[1:])
    elif cmd == "shot":
        print(shot(a[1], "--native" in a) or "FAIL")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
