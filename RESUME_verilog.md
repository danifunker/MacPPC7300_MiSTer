# Resume prompt: DSPPC604, milestone M4

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: the pipeline runs user-mode integer code, and the next milestone adds floating point, exceptions and supervisor state to it.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, what was built in each milestone, and what is still needed from real hardware.
- `verilator\ref\README.md`: the dingusppc lockstep library and the list of places where dingusppc is wrong or differs from a real 604.

## Where things stand (2026-10-05)

- **M0-M2 done.** MiSTer template imported as `PPCMac`; integer execute unit and FPU verified against 37,174 vectors recorded on a real 604 (`python verilator\run.py`).
- **M3 done.** `rtl\DSPPC604\DSPPC604.sv` is a six-stage pipeline for user-mode integer code, with a sequencer for multi-operation instructions, a memory access unit and a branch target buffer. `python verilator\run_core.py` runs the real-604 integer vectors through it as a program and random programs in lockstep with dingusppc.
- The FPU is **not** connected to the pipeline yet. An instruction the pipeline does not implement stops it (`halted`).
- Quartus (`python syn\check.py core|fpu|int`): pipeline 3,208 ALMs at 78.6 MHz, FPU 3,303 ALMs at 73.5 MHz.

## What I want from this session

Milestone M4 from the plan. Suggested order, each step verified before the next:

1. Floating point in the pipeline: FP registers, the FPU in the execute stage, FPSCR, FP loads and stores, the FPSCR instructions. Proof: the 25,598 real-604 FP vectors run through the pipeline as a program, the way the integer ones already do.
2. Exceptions and supervisor state: MSR, SRR0/SRR1, exception entry and `rfi`, `sc`, traps, the alignment exceptions the 604 manual lists, privileged and illegal instructions, the SPRs, decrementer and external interrupt.
3. Lockstep with exceptions and interrupts. dingusppc is weak here (see its README), so say where it cannot be the reference.

Before changing how state is committed or how hazards are handled, check the change against the rules in the plan and tell me.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Commit your work locally at verified points. Never push. Keep `Scratch/` and machine-specific files under `ppctest/` out of git.
- Don't modify `ppctest\TO_CARD`, `ppctest\FROM_CARD` or `ppctest\runs`; the hardware testing continues separately (`RESUME_hardware.md`).
- `sys/` is the MiSTer framework and is never edited. Don't modify the dingusppc tree.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed; test programs are generated as instruction words by `verilator\progs.py`).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`).
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.
