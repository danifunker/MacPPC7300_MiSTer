#!/usr/bin/env python3
"""Build and run the DSPPC604 pipeline tests.

    python verilator\\run_core.py              everything below
    python verilator\\run_core.py --seeds 100  more random programs
    python verilator\\run_core.py --quick      a short run

1. The real-604 integer vectors, assembled into one program and executed by
   the pipeline, without and with random bus wait states.
2. Random programs in lockstep with dingusppc's interpreter: after every
   instruction the registers must match, and at the end the memory.

Runs from Windows (through WSL) or directly under Linux.
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)


def main():
    if os.name == "nt":
        return subprocess.call(["wsl", "--cd", HERE, "--", "python3", "run_core.py"] + sys.argv[1:])

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=20, help="random programs to run (default 20)")
    ap.add_argument("--count", type=int, default=20000, help="instructions per random program")
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--quick", action="store_true", help="4 random programs, one golden pass")
    args = ap.parse_args()
    if args.quick:
        args.seeds = 4

    cache = os.path.join(os.path.expanduser("~"), ".cache", "ppcmac")
    build = os.environ.get("PPCMAC_BUILD") or os.path.join(cache, "verilator")
    refdir = os.path.join(cache, "dingusref")
    progs = os.path.join(build, "progs")
    os.makedirs(progs, exist_ok=True)

    # the reference model, then the test bench linked with it
    r = run(["make", "-s", "-C", os.path.join(HERE, "ref"), "BUILD=" + refdir])
    if r.returncode:
        print(r.stdout)
        print("building the dingusppc reference failed")
        return 1
    lib = os.path.join(refdir, "libdingusref.a")
    r = run(["make", "-s", "-C", HERE, "core", "BUILD=" + build, "REF_LIB=" + lib])
    if r.returncode:
        print(r.stdout)
        print("building the test bench failed")
        return 1
    tb = os.path.join(build, "core_ref", "core_tb")

    failures = 0

    def report(label, r):
        nonlocal failures
        lines = r.stdout.strip().splitlines()
        ok = r.returncode == 0
        stats = next((l for l in lines if "cycles per instruction" in l), "")
        print("%-34s %s  %s" % (label, "pass" if ok else "FAIL", stats))
        if not ok:
            failures += 1
            for l in lines[-14:]:
                print("    " + l)

    # 1. golden vectors as a program
    golden = os.path.join(progs, "golden.prog")
    r = run([sys.executable, os.path.join(HERE, "progs.py"), "golden", golden])
    if r.returncode:
        print(r.stdout)
        return 1
    print("real-604 integer vectors through the pipeline (11,576 checks each):")
    for stall, seed in ((0, 1),) if args.quick else ((0, 1), (25, 2), (60, 3)):
        r = run([tb, "--prog", golden, "--stall", str(stall), "--seed", str(seed)])
        report("  wait states %d%%" % stall, r)

    # 2. random programs in lockstep
    print("random programs in lockstep with dingusppc:")
    total = 0
    for seed in range(args.first_seed, args.first_seed + args.seeds):
        prog = os.path.join(progs, "random.prog")
        r = run([sys.executable, os.path.join(HERE, "progs.py"), "random", prog, str(args.count), str(seed)])
        if r.returncode:
            print(r.stdout)
            return 1
        stall = (0, 15, 40, 70)[seed % 4]
        r = run([tb, "--prog", prog, "--lockstep", "--stall", str(stall), "--seed", str(seed)])
        report("  seed %d, wait states %d%%" % (seed, stall), r)
        for l in r.stdout.splitlines():
            if l.endswith("per instruction)"):
                total += int(l.split()[0])
    print("%d random instructions compared" % total)

    print("\nRESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d runs)" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
