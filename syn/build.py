"""A Quartus build of the core in a Scratch copy, for one CPU speed mode.

    python syn\\build.py dual|100|70 NAME [--seed N]

    dual   the OSD's "CPU speed (on reset)", 70 or 100 MHz (the PLL rewritten under
           reset); timed at 70
    100    100 MHz only: the PLL built for it, never rewritten, no OSD option; timed at 100
    70     70 MHz only: as dual without the option and the rewrite

Copies the project into Scratch\\NAME (the mode as the copy's VERILOG_MACRO
MACPPC_SPEED_100 or MACPPC_SPEED_70, the fitter's seed), compiles it (about 25
minutes; run it in the background, two at a time are fine) and leaves
output_files\\MacPPC7300.rbf there, copied as Scratch\\NAME\\MacPPC7300_<mode>.rbf."""

import os
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
QUARTUS = r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe"
FILES = ["MacPPC7300.qpf", "MacPPC7300.qsf", "MacPPC7300.sdc", "MacPPC7300.srf",
         "MacPPC7300.sv", "files.qip"]
DIRS = ["rtl", "sys"]
MACRO = {"dual": None, "100": "MACPPC_SPEED_100", "70": "MACPPC_SPEED_70"}


def main():
    a = sys.argv[1:]
    if len(a) < 2 or a[0] not in MACRO:
        print(__doc__)
        return 2
    mode, name = a[0], a[1]
    seed = int(a[a.index("--seed") + 1]) if "--seed" in a else 1
    out = os.path.join(REPO, "Scratch", name)
    if os.path.exists(out):
        print("%s exists" % out)
        return 1
    os.makedirs(out)
    for f in FILES:
        shutil.copy2(os.path.join(REPO, f), out)
    for d in DIRS:
        shutil.copytree(os.path.join(REPO, d), os.path.join(out, d))
    qsf = os.path.join(out, "MacPPC7300.qsf")
    text = open(qsf).read().replace("set_global_assignment -name SEED 1\n",
                                    "set_global_assignment -name SEED %d\n" % seed)
    if MACRO[mode]:
        text += '\nset_global_assignment -name VERILOG_MACRO "%s=1"\n' % MACRO[mode]
    open(qsf, "w").write(text)
    print("Scratch\\%s: mode %s, seed %d" % (name, mode, seed), flush=True)
    log = open(os.path.join(out, "quartus.log"), "w")
    r = subprocess.run([QUARTUS, "--flow", "compile", "MacPPC7300"], cwd=out, stdout=log,
                       stderr=subprocess.STDOUT)
    rbf = os.path.join(out, "output_files", "MacPPC7300.rbf")
    if r.returncode != 0 or not os.path.exists(rbf):
        print("FAIL: see Scratch\\%s\\quartus.log" % name)
        return 1
    shutil.copy2(rbf, os.path.join(out, "MacPPC7300_%s.rbf" % mode))
    summ = os.path.join(out, "output_files", "MacPPC7300.sta.summary")
    if os.path.exists(summ):
        lines = open(summ).read().split("\n")
        for i, l in enumerate(lines):
            if l.startswith("Type  : Setup") and "pll|pll_inst" in l:
                print(l.split("'")[1].split("|")[-2], lines[i + 1].strip())
    print("done: Scratch\\%s\\MacPPC7300_%s.rbf" % (name, mode))
    return 0


if __name__ == "__main__":
    sys.exit(main())
