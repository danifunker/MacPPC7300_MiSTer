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
- Quartus (`python syn\check.py core`): 14,340 ALMs (34%), 77 RAM blocks, 58.2 MHz worst case after the first two timing cuts (step 4 has started; the plan's step 4 section says what they were). Above the 50 MHz floor, below the 66 MHz target. The slowest paths: the data cache's tag compare, way select and the memory unit's byte formatting, all in the cache's answer cycle on the way into `wb_result` (the plan's "MEM may split in two"); then the operand forwarding network through the effective-address adder into the MMU and the cache's request; then the forwarded operands into the FPU's first stage.
- A second session works on real-hardware tests from `RESUME_hardware.md`, inside `ppctest\` only. Its changes there are uncommitted and are not yours to commit.

## What I want from this session

1. **M5 step 4, the timing and area pass, in progress.** Target 66 MHz with margin, 75 if it can be had; 50 is the floor; now 58.2 MHz. The plan's step 4 section has what was tried and measured: two cuts that cost nothing got 55.2 to 58.2 MHz; a registered data-cache answer (`LATE_ANSWER`, a parameter of `DSPPC604_cache`, left at 0) cost 9-14% of the cycles and gained nothing, because the next three paths are all within 0.3 ns of each other: the operand forwarding muxes into the ALU and everything EX decides from its result; the data cache's answer cycle into `wb_result`; the forwarded operands into the FPU's first stage. Candidates, in that order: deciding the forwarding selects at the ID/EX edge instead of comparing register numbers in EX (this touches rule 2, the one hazard mechanism, so say so first); the trap condition from the ALU's compare flags; a register on the FPU's operands inside the unit; then the registered cache answer again. The register files in RAM are area, not time. Measure each change with `python syn\check.py core --paths 10` (about 20 minutes; the fitter swings by a few MHz between runs, so judge by the named paths' slack), and keep every change checked by the whole suite and its cycle counts.
2. Then **M6**: run the 7600's ROM (version `077D.28F2`) from the reset vector in Verilator against a stub machine, in lockstep with dingusppc, until it needs hardware that is not there; then the CPU in the MiSTer project with memory and the ROM, a first bitstream that executes ROM code and reports over the UART. The SDRAM controller behind `DSPPC604_memcdc` is part of this. Note for it: with translation off the 604 treats memory as cacheable, so device registers must be reached through BATs with I = 1, which is what the ROM sets up; if early ROM code touches a device with translation off, that will show up in lockstep.

Before changing how state is committed or how hazards are handled, check the change against the rules in the plan and tell me.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`. What Quartus 17 has refused so far: a second read expression on a memory (it becomes flip-flops), byte-enabled writes to a two-dimensional unpacked array (flip-flops again; a one-dimensional array of packed bytes in a module of its own, `DSPPC604_cache_ram`, is the shape it infers), a variable part-select of a two-dimensional array (flatten first), `genvar` declared inside the `for`, and a generate loop without `generate`/`endgenerate`. Verilator accepts all of these, so lint does not catch them; only a Quartus run does.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Commit your work locally at verified points. Never push. Stage explicit paths (`rtl`, `verilator`, `syn`, `docs`, `README.md`, `RESUME_verilog.md`), never `git add -A`.
- Don't modify anything under `ppctest\`. `sys/` is the MiSTer framework and is never edited. Don't modify the dingusppc tree.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed; test programs are generated as instruction words by `verilator\progs.py`).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file; a background process started that way dies with the wsl.exe that launched it, so long runs go through a script run in the tool's own background mode. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`). In a Bash heredoc `\\` arrives as `\`; write scripts and patches to a file instead. `within`, `dist` and `cross` are SystemVerilog keywords.
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash; `604um.txt` is the extracted 604 manual), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.
