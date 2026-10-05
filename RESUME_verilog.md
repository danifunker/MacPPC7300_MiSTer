# Resume prompt: DSPPC604 pipeline (milestone M3)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: the execute units are finished and verified, and the pipeline is next.

Read these two files first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, the pipeline shape, and what is still needed from real hardware.

## Where things stand (2026-10-05)

- **M0 done.** Git repository initialised (branch `main`, nothing committed yet). The MiSTer template is imported as `PPCMac`; the bitstream is still the template's test pattern.
- **M1 done.** `python verilator\run.py` replays the 37,174 real-604 vectors. All 11,576 integer vectors pass, including the 132 undefined divides, which match the chip.
- **M2 done.** All 25,598 floating-point vectors pass. `verilator\fpmodel.py` is a bit-exact software model of the 604's FPU; the RTL also agrees with it on 1.8 million random vectors.
- **Quartus checks** (`python syn\check.py int|fpu`): integer decode + execute with the forwarding loop is about 900 ALMs and 92 MHz; see the README for the FPU's numbers.

## What I want from this session

Milestone M3 from the plan: the pipeline for user-mode integer code.

1. Before writing RTL, propose the pipeline's stage registers, the hazard/forwarding block and the sequencer for multi-operation instructions, checked against the six rules in the plan, and get my agreement.
2. Decide with me what the lockstep reference is. The plan proposes dingusppc's CPU built as a library under WSL.
3. Build it until the golden vectors pass through the pipeline as programs, with random stalls, and random instruction streams run in lockstep with the reference.
4. Run the Quartus check on the whole pipeline; the target is 66 MHz or better, 75 if it can be had.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Don't push, and don't commit unless I ask. Keep `Scratch/` and machine-specific files under `ppctest/` out of git.
- Don't modify `ppctest\TO_CARD`, `ppctest\FROM_CARD` or `ppctest\runs`; the hardware testing continues separately (`RESUME_hardware.md`).
- `sys/` is the MiSTer framework and is never edited.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`).
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.
