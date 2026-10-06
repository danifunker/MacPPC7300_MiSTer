#!/usr/bin/env python3
"""Build and run the DSPPC604 pipeline tests.

    python verilator\\run_core.py              everything below
    python verilator\\run_core.py --seeds 100  more random programs
    python verilator\\run_core.py --quick      a short run

1. The real-604 integer vectors, assembled into one program and executed by
   the pipeline, without and with random bus wait states.
2. The real-604 floating-point vectors, the same way.
3. Random floating-point programs (arithmetic, loads, stores, FPSCR
   instructions) with the state fpmodel.py expects after every instruction.
4. Each exception once, with what its handler must find in SRR0, SRR1, DAR
   and DSISR; address translation with every cause of DSI and ISI; and a
   computation that thousands of external and decrementer interrupts must
   leave undisturbed.
5. Random programs in lockstep with dingusppc's interpreter, including
   supervisor instructions, mode switches and exceptions: after every
   instruction the registers and MSR must match, and at the end the memory.
   Then the same with address translation on.
6. The memory port carried across a clock boundary, at several clock
   ratios, with random requests checked against a software memory.
7. The SDRAM controller behind the crossing, against a model of the 128 MB
   board that checks every command and timing (sdram_main.cpp).

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
    # the compilers' temporary files go in a directory of this build's own:
    # other WSL sessions working at the same time have deleted files in /tmp
    # under a running g++
    tmp = build.rstrip("/") + "-tmp"
    os.makedirs(tmp, exist_ok=True)
    os.environ["TMPDIR"] = tmp
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

    # 2. the floating-point vectors the same way
    goldenfp = os.path.join(progs, "goldenfp.prog")
    r = run([sys.executable, os.path.join(HERE, "progs.py"), "goldenfp", goldenfp])
    if r.returncode:
        print(r.stdout)
        return 1
    print("real-604 floating-point vectors through the pipeline (25,598 checks each):")
    for stall, seed in ((0, 1),) if args.quick else ((0, 1), (30, 2)):
        r = run([tb, "--prog", goldenfp, "--stall", str(stall), "--seed", str(seed)])
        report("  wait states %d%%" % stall, r)

    # ... and the 7300 run's version-4 set: the same vectors plus non-IEEE
    # mode, the enabled exceptions, XER, the FPSCR instructions, and integer
    # and floating-point loads and stores through a buffer
    v4 = os.path.join(HERE, "..", "ppctest", "runs", "results_604_7300_of_run1.csv")
    if os.path.exists(v4):
        print("the 7300 run's vectors through the pipeline (12,053 integer, 67,571 floating-point checks):")
        for kind, stall in (("golden", 20), ("goldenfp", 20)):
            prog = os.path.join(progs, kind + "_7300.prog")
            r = run([sys.executable, os.path.join(HERE, "progs.py"), kind, prog, v4])
            if r.returncode:
                print(r.stdout)
                return 1
            r = run([tb, "--prog", prog, "--stall", str(stall), "--seed", "4"])
            report("  %s, wait states %d%%" % ("integer" if kind == "golden" else "floating point", stall), r)

    # 3. random floating-point programs, every instruction checked against fpmodel.py
    print("random floating-point programs against the software model:")
    for seed in range(args.first_seed, args.first_seed + max(2, args.seeds // 4)):
        prog = os.path.join(progs, "fprandom.prog")
        r = run([sys.executable, os.path.join(HERE, "progs.py"), "fprandom", prog, str(args.count), str(seed)])
        if r.returncode:
            print(r.stdout)
            return 1
        stall = (0, 20, 50)[seed % 3]
        r = run([tb, "--prog", prog, "--stall", str(stall), "--seed", str(seed)])
        report("  seed %d, wait states %d%%" % (seed, stall), r)

    # 4. exceptions and interrupts, with known outcomes
    print("exceptions and interrupts:")
    for name, gen, tb_args in (
        ("each exception once", ["exctest"], ["--stall", "10"]),
        ("floating-point enabled exceptions", ["fpexctest"], []),
        ("address translation, DSI, ISI", ["mmutest"], ["--stall", "20", "--seed", "5"]),
        ("lwarx/stwcx., dcbz, cache ops", ["resvtest"], ["--stall", "25"]),
        ("caches, cache ops, HID0, DMA", ["cachetest"], ["--stall", "30", "--seed", "7"]),
        ("external interrupts", ["irqtest", "3000"], ["--irq-every", "97", "--stall", "10"]),
        ("decrementer interrupts", ["irqtest", "3000"], ["--tb-run"]),
        ("both, with wait states", ["irqtest", "3000"], ["--irq-every", "61", "--tb-run", "--stall", "30"]),
    ):
        prog = os.path.join(progs, "exc.prog")
        r = run([sys.executable, os.path.join(HERE, "progs.py"), gen[0], prog] + gen[1:])
        if r.returncode:
            print(r.stdout)
            return 1
        r = run([tb, "--prog", prog] + tb_args)
        report("  " + name, r)

    # 5. random programs in lockstep, exceptions and supervisor instructions
    #    included; then the same with address translation on (page faults,
    #    protection faults, tlbie, and the page table's R and C bits compared
    #    at the end)
    total = 0
    for xlate in (False, True):
        print("random programs in lockstep with dingusppc%s:" % (", translation on" if xlate else ""))
        seeds = range(args.first_seed, args.first_seed + (max(2, args.seeds // 2) if xlate else args.seeds))
        for seed in seeds:
            prog = os.path.join(progs, "random.prog")
            r = run([sys.executable, os.path.join(HERE, "progs.py"), "random", prog, str(args.count), str(seed)]
                    + (["xlate"] if xlate else []))
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

    # 6. the memory port across two clocks
    r = run(["make", "-s", "-C", HERE, "cdc", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building the clock-crossing bench failed")
        return 1
    print("the memory port across a clock boundary (CPU against memory clock):")
    for pa, pb, label in ((15152, 10000, "66 against 100 MHz"), (15152, 7692, "66 against 130 MHz"),
                          (15152, 15152, "66 against 66 MHz"), (10000, 15152, "100 against 66 MHz")):
        r = run([os.path.join(build, "cdc", "cdc_tb"), "--count", "5000", "--pa", str(pa), "--pb", str(pb),
                 "--stall", "30", "--seed", "3"])
        report("  " + label, r)

    # 7. the SDRAM controller against a model of the board, through the crossing
    r = run(["make", "-s", "-C", HERE, "sdram", "BUILD=" + build])
    if r.returncode:
        print(r.stdout)
        print("building the SDRAM bench failed")
        return 1
    print("the SDRAM controller against a model of the 128 MB board (100 MHz):")
    for seed, pa, label in ((1, 15385, "CPU at 65 MHz"), (2, 20000, "CPU at 50 MHz"), (3, 10000, "CPU at 100 MHz")):
        r = run([os.path.join(build, "sdram", "sdram_tb"), "--count", "20000", "--seed", str(seed), "--pa", str(pa)])
        report("  " + label, r)

    print("\nRESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d runs)" % failures))
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
