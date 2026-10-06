# Resume prompt: DSPPC604, milestone M5 step 4 (timing and area)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: it is functionally complete for the software we target (the 604 instruction set, exceptions, supervisor state, address translation, caches, a line port to memory with its clock crossing). What is left of M5 is the timing and area pass; after that comes M6, the real ROM in simulation and the first MiSTer build.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests, current size and speed.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, what was built in each milestone, and the section "Known behaviour and open items", which holds everything flagged so far (it replaced the caveat list that used to live in this prompt).
- `verilator\ref\README.md`: the dingusppc lockstep library and where dingusppc is wrong or differs from a real 604, with translation on included.

## Where things stand (2026-10-05, end of day)

- **M0-M4 done, M5 steps 1-3 done**, all committed on `main`, nothing pushed. `rtl\DSPPC604\DSPPC604.sv` is a six-stage pipeline with the integer units, the FPU, exceptions, interrupts, MSR and the SPRs, the reservation and the cache instructions; `DSPPC604_mmu.sv` (BATs, segment registers, a 64-entry TLB per side, a hardware page-table walk with R and C bits, DSI and ISI, `tlbie`) sits between the pipeline and two `DSPPC604_cache` instances (16 KB, four-way, 32-byte lines, write-back, pseudo-LRU; `dcbz`/`dcbf`/`dcbst`/`dcbi`/`icbi`; HID0's enable, lock and invalidate bits); one memory port leaves the CPU (a line or a word, request held until acknowledged, data whole) with a snoop port for DMA, and `DSPPC604_memcdc.sv` carries that port into another clock.
- `python verilator\run.py`: 37,174 single-instruction vectors recorded on a real 604, all pass.
- `python verilator\run_core.py`: the vectors as programs, random FP programs against `fpmodel.py`, directed exception, interrupt, translation, reservation and cache tests (the last with a DMA engine on the snoop port), random programs in lockstep with dingusppc with and without translation, and the clock crossing at four ratios (52 runs, about 540,000 lockstep instructions). The test bench writes back the lines the data cache may hold dirty through the snoop port when a program ends, so memory comparisons see them.
- Quartus (`python syn\check.py core`): see the plan's M5 step 3 for the numbers with the caches; before them 12,049 ALMs (29%) and 61-65 MHz worst case. The slowest paths are the operand forwarding network into the ALU and FPU.
- A second session works on real-hardware tests from `RESUME_hardware.md`, inside `ppctest\` only. Its changes there are uncommitted and are not yours to commit.

## What I want from this session

1. **M5 step 4, the timing and area pass.** Target 66 MHz with margin, 75 if it can be had; 50 is the floor. Known gains, none tried yet: the register files and SPRs are flip-flops (MLAB/M10K would save most of the area beyond the units); the forwarded operands run straight into the ALU and the FPU's first stage, which sets the clock; the DTLB's read-ahead address hangs off the effective-address adder; `ex_leave` gained terms (`mem_fault`) with every milestone; the caches' tag compare and way select sit in the answer cycle after the MMU's translation. Measure before and after each change with `python syn\check.py core --paths 10`; the fitter's results swing by several MHz between runs, so judge by the slack of the named paths, not by Fmax alone. Keep every change checked by the whole suite.
2. Then **M6**: run the 7600's ROM (version `077D.28F2`) from the reset vector in Verilator against a stub machine, in lockstep with dingusppc, until it needs hardware that is not there; then the CPU in the MiSTer project with memory and the ROM, a first bitstream that executes ROM code and reports over the UART. The SDRAM controller behind `DSPPC604_memcdc` is part of this. Note for it: with translation off the 604 treats memory as cacheable, so device registers must be reached through BATs with I = 1, which is what the ROM sets up; if early ROM code touches a device with translation off, that will show up in lockstep.

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
