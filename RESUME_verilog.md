# Resume prompt: DSPPC604, milestone M5

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: it runs integer and floating-point code with exceptions and supervisor state, in real mode on a simple bus. The next milestone gives it an MMU and caches.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests, current size and speed.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, what was built in each milestone and what was left out of it.
- `verilator\ref\README.md`: the dingusppc lockstep library and where dingusppc is wrong or differs from a real 604.

## Where things stand (2026-10-05)

- **M0-M4 done and committed.** `rtl\DSPPC604\DSPPC604.sv` is a six-stage pipeline with the integer units, the FPU, exceptions, interrupts, MSR and the SPRs.
- `python verilator\run.py`: 37,174 single-instruction vectors recorded on a real 604, all pass.
- `python verilator\run_core.py`: the same vectors as programs through the pipeline, random floating-point programs against `fpmodel.py`, directed exception and interrupt tests, and random programs in lockstep with dingusppc (supervisor instructions and exceptions included).
- Not there yet: MMU (so no DSI or ISI), caches, `lwarx`/`stwcx.`, the cache instructions (`dcbz` above all), machine check, trace. BATs, SDR1 and the segment registers exist as storage only.
- Size and speed are in the README. The register files are still flip-flops and the 75 MHz target is not met with the FPU connected; a timing and area pass is owed.

## What I want from this session

Milestone M5 from the plan. Suggested order, each step verified before the next:

1. Address translation: BATs, segment registers, hashed page table walk in hardware with reference and change bits, ITLB and DTLB, `tlbie`; DSI and ISI with DAR and DSISR. Proof: lockstep with dingusppc with translation on (its MMU is its own code, so say where it cannot be the reference), plus directed page-fault tests.
2. `lwarx`/`stwcx.` and the cache instructions, `dcbz` first.
3. Instruction and data caches in block RAM with 32-byte lines, and the memory side as a line-fill bus. Decide with me first whether main memory will be the SDRAM module or the HPS DDR3, because it sets the bus.
4. The timing and area pass: register files in RAM, the FPU's input path, 66 MHz with margin and 75 if it can be had.

Before changing how state is committed or how hazards are handled, check the change against the rules in the plan and tell me. A memory access that can fault in MEM is the one case the current design has not had to handle yet: an instruction in MEM being cancelled, and EX being flushed behind it.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Commit your work locally at verified points. Never push. Stage explicit paths (`rtl`, `verilator`, `syn`, `docs`, `README.md`, `RESUME_verilog.md`), never `git add -A`: a second session may be working in `ppctest\` at the same time (`RESUME_hardware.md`), and its files are not yours to commit.
- Don't modify anything under `ppctest\`. `sys/` is the MiSTer framework and is never edited. Don't modify the dingusppc tree.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed; test programs are generated as instruction words by `verilator\progs.py`).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`). In a Bash heredoc `\\` arrives as `\`; write scripts and patches to a file instead.
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.
