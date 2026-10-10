#!/usr/bin/env python3
"""Run checked, repeatable CPU performance cases at a fixed clock.

python verilator/perf.py --tb PATH --out Scratch/perf/baseline --lockstep
These isolate bottlenecks; Speedometer on the board remains the 2x acceptance test.
"""

import argparse
import json
import os
import re
import subprocess

from progs import B_SELF, CODE_BASE, CTR, D, HID0_DCE, HID0_ICE, MSR_FP, Program, X, caches_on, li32, mtspr, set_msr


def cases(loops):
    data, result = 0x00800000, 0x00900000

    def program(body, expected, fp=False, initial=(0, 0, 0, 0), fp_counter=0):
        p = Program()
        p.words = caches_on(value=HID0_ICE | HID0_DCE) + set_msr(MSR_FP if fp else 0)
        p.words += li32(1, data) + li32(2, result)
        for r, value in zip(range(3, 7), initial):
            p.words += li32(r, value)
        p.data[data] = 42
        p.data[data + 4], p.data[data + 8] = 43, 44
        p.data[data + 12] = 45
        if fp:
            # f4 = 1, f5 = 2: keep arithmetic finite across every iteration.
            p.data[data + 32], p.data[data + 36] = 0x3FF00000, 0
            p.data[data + 40], p.data[data + 44] = 0x40000000, 0
            p.words += [D(50, 4, 1, 32), D(50, 5, 1, 40)]
        p.words += li32(7, loops) + [mtspr(CTR, 7)]
        p.words += body
        p.words += [(16 << 26) | (16 << 21) | ((-4 * len(body)) & 0xFFFC)]
        if fp:
            p.words += [D(54, 3, 2, 0), D(36, 6, 2, 8)]
            p.expect[result], p.expect[result + 4] = 0x40000000, 0
            p.expect[result + 8] = fp_counter
        else:
            p.words += [D(36, r, 2, 4 * (r - 3)) for r in range(3, 7)]
            p.expect.update({result + 4 * i: v for i, v in enumerate(expected)})
        p.words += [B_SELF]
        return p

    yield "alu_independent", program([D(14, r, r, 1) for _ in range(4) for r in range(3, 7)], [4 * loops] * 4)
    yield "alu_chain", program([D(14, 3, 3, 1)] * 16, [16 * loops, 0, 0, 0])
    yield "load_independent", program([D(32, r, 1, 4 * (r - 3)) for _ in range(4) for r in range(3, 7)], [42, 43, 44, 45])
    yield "load_use", program([D(32, 3, 1, 0), D(14, 3, 3, 1)] * 8, [43, 0, 0, 0])
    value = 0x01234567
    p = program([D(36, 3, 1, 64 + 4 * i) for i in range(16)], [value, 0, 0, 0], initial=(value, 0, 0, 0))
    p.expect.update({data + 64 + 4 * i: value for i in range(16)})
    yield "store_hits", p
    p = program([D(36, 3, 1, 64), D(32, 4, 1, 64)] * 8, [value, value, 0, 0], initial=(value, 0, 0, 0))
    p.expect[data + 64] = value
    yield "store_load", p
    yield "multiply_mix", program([X(3, 4, 5, 235), D(14, 6, 6, 1)] * 8, [21, 3, 7, 8 * loops], initial=(0, 3, 7, 0))
    fmul = (63 << 26) | (3 << 21) | (4 << 16) | (5 << 6) | (25 << 1)
    yield "fp_multiply", program([fmul] * 8, [], fp=True)
    yield "fp_integer_mix", program([fmul, D(14, 6, 6, 1)] * 8, [], fp=True, fp_counter=8 * loops)
    yield "fp_integer_overlap", program(([fmul] + [D(14, 6, 6, 1)] * 4) * 8, [], fp=True, fp_counter=32 * loops)
    yield "divide_integer_mix", program(([X(3, 4, 5, 459)] + [D(14, 6, 6, 1)] * 4) * 4,
                                          [33333, 100000, 3, 16 * loops], initial=(0, 100000, 3, 0))
    yield "divide_waw_chain", program(([X(3, 4, 5, 459), D(14, 3, 0, 42), D(14, 3, 3, 1),
                                        D(14, 6, 6, 1), D(14, 6, 6, 1)]) * 4,
                                       [43, 100000, 3, 8 * loops], initial=(0, 100000, 3, 0))
    yield "divide_operand_chain", program(([X(3, 4, 5, 459)] + [D(14, 4, 4, 1)] * 4) * 2,
                                           [(100000 + 8 * loops - 4) // 3, 100000 + 8 * loops, 3, 0],
                                           initial=(0, 100000, 3, 0))
    yield "fp_load_independent", program([D(50, r, 1, 40) for _ in range(4) for r in (3, 6, 7, 8)], [], fp=True)
    p = program([D(54, 5, 1, 64 + 8 * i) for i in range(16)] + [fmul], [], fp=True)
    for i in range(16):
        p.expect[data + 64 + 8 * i], p.expect[data + 68 + 8 * i] = 0x40000000, 0
    yield "fp_store_hits", p

    p = program([], [16 * loops, 0, 0, 0])
    # Two functions 512 bytes apart contend for the baseline BTB's entries.
    # Repeated calls also exercise return targets at different call sites.
    loop = next(i for i, w in enumerate(p.words) if w == mtspr(CTR, 7)) + 1
    body = []
    for _ in range(8):
        for target in (0x12000, 0x12200):
            pc = CODE_BASE + 4 * (loop + len(body))
            body.append((18 << 26) | ((target - pc) & 0x03FFFFFC) | 1)
            p.data[target], p.data[target + 4] = D(14, 3, 3, 1), 0x4E800020
    p.words[loop:loop + 1] = body + [(16 << 26) | (16 << 21) | ((-4 * len(body)) & 0xFFFC)]
    yield "branch_calls", p


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tb", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--loops", type=int, default=10000)
    ap.add_argument("--lockstep", action="store_true")
    ap.add_argument("--require-overlap", action="store_true", help="verify simultaneous queue append/retirement was exercised")
    args = ap.parse_args()
    if not 1 <= args.loops <= 1000000:
        ap.error("--loops must be between 1 and 1000000")
    os.makedirs(args.out, exist_ok=True)
    results = {}
    for name, p in cases(args.loops):
        path = os.path.join(args.out, name + ".prog")
        p.write(path)
        command = [args.tb, "--prog", path, "--profile"] + (["--lockstep"] if args.lockstep else [])
        run = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with open(os.path.join(args.out, name + ".log"), "w") as fh:
            fh.write(run.stdout)
        match = re.search(r"(\d+) instructions in (\d+) cycles \(", run.stdout)
        if run.returncode or not match or "RESULT: PASS" not in run.stdout:
            raise RuntimeError(name + " failed:\n" + run.stdout)
        instructions, cycles = map(int, match.groups())
        results[name] = {"instructions": instructions, "cycles": cycles, "cpi": cycles / instructions,
                         "events": {k: int(v) for k, v in re.findall(r"event\s+(\w+)\s+(\d+)", run.stdout)},
                         "buckets": {k: int(v) for k, v in re.findall(r"bucket\s+(\w+)\s+(\d+)", run.stdout)}}
        print("%-20s %9d cycles, %.3f CPI" % (name, cycles, cycles / instructions), flush=True)
    if args.require_overlap:
        for name in ("fp_integer_mix", "fp_integer_overlap", "divide_integer_mix", "divide_waw_chain"):
            if not results[name]["events"].get("overlap_parallel", 0):
                raise RuntimeError(name + ": no simultaneous completion append and retirement")
    with open(os.path.join(args.out, "results.json"), "w") as fh:
        json.dump({"loops": args.loops, "lockstep": args.lockstep, "cases": results}, fh, indent=2)


if __name__ == "__main__":
    main()
