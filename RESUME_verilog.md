# Resume prompt: DSPPC604, milestone M5 from step 3

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: it runs the whole 604 instruction set that software uses, with exceptions, supervisor state and address translation, on a simple word bus with no caches. Next are the caches and the line-fill bus to the SDRAM, then timing.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests, current size and speed.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, what was built in each milestone, and the section "Known behaviour and open items", which holds everything flagged so far (it replaced the caveat list that used to live in this prompt).
- `verilator\ref\README.md`: the dingusppc lockstep library and where dingusppc is wrong or differs from a real 604, with translation on included.

## Where things stand (2026-10-05, end of day)

- **M0-M4 done, M5 steps 1 and 2 done**, all committed on `main`, nothing pushed. `rtl\DSPPC604\DSPPC604.sv` is a six-stage pipeline with the integer units, the FPU, exceptions, interrupts, MSR and the SPRs, the reservation, `dcbz` and the cache instructions (which translate their address and do nothing else yet); `DSPPC604_mmu.sv` sits between it and the buses: BATs, segment registers, a 64-entry direct-mapped TLB per side, a hardware page-table walk with R and C bits, DSI and ISI, `tlbie`.
- `python verilator\run.py`: 37,174 single-instruction vectors recorded on a real 604, all pass.
- `python verilator\run_core.py`: the vectors as programs, random FP programs against `fpmodel.py`, directed exception, interrupt, translation and reservation tests, and random programs in lockstep with dingusppc, with and without translation (47 runs, about 540,000 lockstep instructions; 300 programs without translation passed as well, before step 2).
- Quartus (`python syn\check.py core`): 12,049 ALMs (29%), 61-65 MHz worst case depending on the run, measured before step 2. The slowest paths are the operand forwarding network into the ALU and FPU; the timing pass is step 4.
- A second session works on real-hardware tests from `RESUME_hardware.md`, inside `ppctest\` only. Its changes there are uncommitted and are not yours to commit.

## What I want from this session

Milestone M5 from the plan, in this order, each step verified before the next:

3. Instruction and data caches in block RAM with 32-byte lines, and the memory side as a line-fill bus. Decided: main memory is the MiSTer SDRAM module (64 or 128 MB fitted), and the machine's installed RAM is a core option of 6, 16, 24, 32, 64 or 128 MB. The bus therefore targets the SDRAM controller on its own clock; the clock crossing is part of this step. Things already in place for it: the TLBs are read a cycle ahead (what a virtually indexed, physically tagged cache needs); the memory unit's "touch" requests are where `dcbf`, `dcbst`, `dcbi` and `icbi` will become cache operations; `dcbz` is eight word stores today and should become a line allocate; the page attributes (WIMG) come out of the MMU with every translation; HID0[ICE], [DCE], [ILOCK], [DLOCK] and the invalidate bits are stored but only DCE and DLOCK are looked at (by `dcbz`). Writes to memory by anything other than the CPU (disk DMA, the HPS loading a ROM) must go through or invalidate the data cache. The lockstep test bench models the bus as one word per request with random wait states; it will need a line-fill model.
4. The timing and area pass: register files in RAM, the FPU's input path, the forwarding network's fanout (the DTLB's read-ahead address comes off the effective-address adder), 66 MHz with margin and 75 if it can be had.

Before changing how state is committed or how hazards are handled, check the change against the rules in the plan and tell me.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`. Quartus infers a RAM only from a single read expression per memory; a second read expression turns the memory into flip-flops.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Commit your work locally at verified points. Never push. Stage explicit paths (`rtl`, `verilator`, `syn`, `docs`, `README.md`, `RESUME_verilog.md`), never `git add -A`.
- Don't modify anything under `ppctest\`. `sys/` is the MiSTer framework and is never edited. Don't modify the dingusppc tree.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed; test programs are generated as instruction words by `verilator\progs.py`).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file; a background process started that way dies with the wsl.exe that launched it, so long runs go through a script run in the tool's own background mode. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`). In a Bash heredoc `\\` arrives as `\`; write scripts and patches to a file instead. `within`, `dist` and `cross` are SystemVerilog keywords.
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash; `604um.txt` is the extracted 604 manual), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.
