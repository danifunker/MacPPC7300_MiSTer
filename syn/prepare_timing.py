#!/usr/bin/env python3
"""Copy the verified CPU into an isolated full-machine Quartus project.

    python syn/prepare_timing.py --out Scratch/cpu70_seed1 --seed 1 --no-retiming
    cd Scratch/cpu70_seed1
    quartus_sh --flow compile MacPPC7300

Run again into a different directory for seed 2. This prepares sources only;
it neither runs Quartus nor deploys a bitstream. The main project's settings
are untouched; multicorner analysis is enabled in the copy.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


ROOT = Path(__file__).resolve().parent.parent
PROJECT_FILES = ("MacPPC7300.qpf", "MacPPC7300.qsf", "MacPPC7300.sdc",
                 "MacPPC7300.srf", "MacPPC7300.sv", "files.qip")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, type=Path, help="new project directory")
    ap.add_argument("--seed", type=int, default=1, help="positive fitter seed")
    ap.add_argument("--verification", type=Path, default=ROOT / "Scratch/perf/gpr_ram/source-metadata.json",
                    help="archived verification metadata for this CPU revision")
    ap.add_argument("--no-retiming", action="store_true", help="disable physical register retiming for an area/timing comparison")
    args = ap.parse_args()
    out = args.out.resolve()
    if args.seed < 1:
        ap.error("--seed must be positive")
    if out.exists():
        ap.error("--out must be a new directory; existing projects are never overwritten")
    # Avoid copying a source tree into itself or writing into a protected
    # source directory. Scratch and external build locations are allowed.
    if out == ROOT or any(p == out or p in out.parents for p in (ROOT / "rtl", ROOT / "sys", ROOT / ".git")):
        ap.error("--out cannot replace the checkout or be inside rtl, sys or .git")
    top = (ROOT / "MacPPC7300.sv").read_text()
    if not re.search(r"localparam\s+int\s+CPU_MHZ\s*=\s*70\s*;", top):
        ap.error("this fixed-clock comparison requires CPU_MHZ = 70")
    if not re.search(r'CPU_MHZ\s*==\s*70\s*\?\s*"70\.000000 MHz"', top):
        ap.error("verify the PLL selection explicitly maps CPU_MHZ = 70 to 70 MHz before preparing this comparison")
    metadata_path = args.verification.resolve()
    if not metadata_path.is_file():
        ap.error("missing verification source-metadata.json; run and archive CPU verification first")
    verified = json.loads(metadata_path.read_text())
    cpu_sources = sorted((ROOT / "rtl/DSPPC604").glob("*.sv"))
    verified_cpu = {p for p in verified["sha256"] if p.startswith("rtl/DSPPC604/") and p.endswith(".sv")}
    if verified_cpu != {p.relative_to(ROOT).as_posix() for p in cpu_sources}:
        ap.error("CPU source list differs from archived verification")
    mismatches = [str(p.relative_to(ROOT)) for p in cpu_sources
                  if verified["sha256"].get(p.relative_to(ROOT).as_posix()) != digest(p)]
    if mismatches:
        ap.error("CPU differs from archived verification: " + ", ".join(mismatches))
    for name in PROJECT_FILES:
        if not (ROOT / name).is_file():
            ap.error("missing project input: " + name)
    out.mkdir(parents=True)
    for name in PROJECT_FILES:
        shutil.copy2(ROOT / name, out / name)
    for name in ("rtl", "sys"):
        shutil.copytree(ROOT / name, out / name, ignore=shutil.ignore_patterns(".git", "db", "incremental_db", "output_files"))
    # sys/build_id.tcl is the pre-flow script and creates build_id.v. Copy a
    # preexisting one if present, for tools opening the project before flow.
    if (ROOT / "build_id.v").is_file():
        shutil.copy2(ROOT / "build_id.v", out / "build_id.v")
    qsf = out / "MacPPC7300.qsf"
    qsf.write_text(qsf.read_text().rstrip() +
                   "\n\n# Isolated CPU performance validation settings\n" +
                   "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS ON\n" +
                   "set_global_assignment -name SEED %d\n" % args.seed +
                   ("set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF\n" if args.no_retiming else ""))
    manifest = {"baseline_commit": verified["baseline_commit"], "cpu_mhz": 70,
                "seed": args.seed, "multicorner_analysis": True,
                "register_retiming": not args.no_retiming,
                "cpu_matches_archived_verification": True,
                "timing_verified": False, "board_performance_verified": False,
                "sha256": {p.relative_to(out).as_posix(): digest(p)
                           for p in sorted(out.rglob("*")) if p.is_file()}}
    (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(metadata_path, out / "verification-source-metadata.json")
    print("Prepared full-machine project:", out)
    print("CPU: 70 MHz; fitter seed: %d; multicorner timing enabled" % args.seed)
    print("Run in that directory: quartus_sh --flow compile MacPPC7300")
    print("Then inspect output_files/MacPPC7300.{fit,sta}.rpt, including hold and unconstrained paths.")
    print("This snapshot has not been synthesized or timed.")


if __name__ == "__main__":
    main()
