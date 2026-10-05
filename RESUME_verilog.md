# Resume prompt: DSPPC604, milestone M5, and the caveats to sort through

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`. The first machine to target is the Power Macintosh 7600; the eventual goal is the Apple Pippin. This session continues the CPU: it runs integer and floating-point code with exceptions and supervisor state, in real mode on a simple bus. The next milestone gives it an MMU and caches. Before that, go through the caveat list at the end with me.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 turned out to do, how to run the tests, current size and speed.
- `docs\DSPPC604_plan.md`: the milestones, the rules that keep the pipeline free of special cases, what was built in each milestone and what was left out of it.
- `verilator\ref\README.md`: the dingusppc lockstep library and where dingusppc is wrong or differs from a real 604.

## Where things stand (2026-10-05, end of day)

- **M0-M4 done and committed** (five commits on `main`, nothing pushed). `rtl\DSPPC604\DSPPC604.sv` is a six-stage pipeline with the integer units, the FPU, exceptions, interrupts, MSR and the SPRs.
- `python verilator\run.py`: 37,174 single-instruction vectors recorded on a real 604, all pass.
- `python verilator\run_core.py`: the same vectors as programs through the pipeline, random floating-point programs against `fpmodel.py`, directed exception and interrupt tests, and random programs in lockstep with dingusppc (supervisor instructions and exceptions included).
- Quartus (`python syn\check.py core`): 10,781 ALMs (26%), 69.5 MHz worst case. 66 MHz met, 75 not.
- A second session works on real-hardware tests from `RESUME_hardware.md`, inside `ppctest\` only. Its changes there are uncommitted and are not yours to commit.

## What I want from this session

1. **Go through the caveat list below with me.** For each one, say whether it is already right in the code, only documented, or open, and what sorting it out would take. Fix the cheap ones as we go; put the rest into `docs\DSPPC604_plan.md` so they stop living only in prompts.
2. **Milestone M5** from the plan, in this order, each step verified before the next:
   1. Address translation: BATs, segment registers, hashed page table walk in hardware with reference and change bits, ITLB and DTLB, `tlbie`; DSI and ISI with DAR and DSISR. Proof: lockstep with dingusppc with translation on (its MMU is its own code, so say where it cannot be the reference), plus directed page-fault tests.
   2. `lwarx`/`stwcx.` and the cache instructions, `dcbz` first.
   3. Instruction and data caches in block RAM with 32-byte lines, and the memory side as a line-fill bus. Decide with me first whether main memory will be the SDRAM module or the HPS DDR3, because it sets the bus.
   4. The timing and area pass: register files in RAM, the FPU's input path, 66 MHz with margin and 75 if it can be had.

Before changing how state is committed or how hazards are handled, check the change against the rules in the plan and tell me. A memory access that can fault in MEM is the one case the current design has not had to handle: an instruction in MEM being cancelled, and EX flushed behind it.

## Rules

- SystemVerilog is fine, limited to what Verilator 5.020 and Quartus 17.0 both accept. Keep the RTL clean under Verilator `-Wall`.
- Module and file names carry the CPU model: `DSPPC604_*`. Each later CPU model gets its own version.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Commit your work locally at verified points. Never push. Stage explicit paths (`rtl`, `verilator`, `syn`, `docs`, `README.md`, `RESUME_verilog.md`), never `git add -A`.
- Don't modify anything under `ppctest\`. `sys/` is the MiSTer framework and is never edited. Don't modify the dingusppc tree.

## Environment

- Windows 11. Verilator 5.020, g++, make and `qemu-ppc-static` are in WSL (Ubuntu 24.04); `sudo` there needs my password, so ask me to install anything missing (a PowerPC cross-compiler is not installed; test programs are generated as instruction words by `verilator\progs.py`).
- Run WSL commands as `wsl --cd <windows dir> -- <command>` or from a script file. Git Bash rewrites arguments that look like Unix paths (prefix with `MSYS_NO_PATHCONV=1`). In a Bash heredoc `\\` arrives as `\`; write scripts and patches to a file instead. `within`, `dist` and `cross` are SystemVerilog keywords.
- Quartus Lite 17.0 is at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages.
- References: manuals in `Scratch\PPC` (`pdftotext` is in Git Bash), `C:\Temp\mistercore\dingusppc`, `..\qemu`, `..\mame`.

## Caveats to sort through

Everything flagged while building M0-M4, in one place. Tags: **[code]** behaves this way in the RTL on purpose; **[test]** a limitation of a test, not of the CPU; **[open]** not implemented or not decided; **[hw]** needs real-hardware data to settle; **[doc]** where it is written down.

### Things the CPU does that software could notice

- **[code][open]** Instructions the 604 has but the core does not yet take the *illegal instruction* exception: `lwarx`, `stwcx.`, `dcbz`, `dcbf`, `dcbst`, `dcbi`, `dcbt`, `dcbtst`, `icbi`, `eciwx`, `ecowx`. An OS will hit `dcbz` and `lwarx`/`stwcx.` at once. M5 step 2.
- **[code][open]** No MMU yet: MSR[IR]/[DR] are stored but ignored, no DSI or ISI, the BATs, SDR1 and segment registers are storage only. M5 step 1.
- **[open]** Not implemented and no milestone yet: machine check, trace (MSR[SE], MSR[BE]), the 604's instruction-address breakpoint (IABR) and performance-monitor interrupts, soft reset, power saving (MSR[POW]), little-endian mode (MSR[LE]/[ILE] are stored and ignored).
- **[open]** Alignment exception for an unaligned string operation that crosses a 4 KB boundary (604 manual 2.3.4.3): not implemented. The other alignment cases (`lmw`/`stmw`, FP loads and stores at non-word addresses) are. **[doc]** plan, M4 step 2.
- **[code]** Interrupts are taken only on the first operation of a multi-operation instruction; an exception in a later operation leaves the earlier ones done and restarts the instruction. That is what the architecture allows; `lmw` with rA inside the loaded range (an invalid form) would misbehave. **[doc]** core header comment.
- **[code]** `mtmsr` and `rfi` always refetch the next instruction. Fine, just a cost.
- **[code]** MSR implemented-bit mask is `0x0005FF73` (no 604e PM bit); exception entry keeps ME, IP and ILE and copies ILE to LE; SRR1 takes MSR bits `0x87C0FFFF`; `mtxer` keeps `0xE000007F`. **[hw]** which XER and MSR bits a real 604 keeps is unverified.
- **[code]** Reset state: MSR `0x40` (vectors at FFFxxxxx), DEC `0xFFFFFFFF`, time base 0, HID0 0; GPRs and FPRs are not reset. **[hw]** real reset values unknown except MSR at the Open Firmware prompt (`00003070`) and HID0 there (`8000C084`).
- **[code]** `mftb` is decoded as reading SPR 284/285; `mfspr` 284/285 also works in supervisor mode. The decrementer and time base advance on the `tb_tick` input; the system must pulse it at bus clock / 4. The decrementer exception becomes pending when DEC passes zero or when `mtdec` writes a value with bit 0 set while it was clear.
- **[code]** Exception priority, highest first: external interrupt, decrementer, pending enabled FP exception, privileged, illegal, FP unavailable, system call, trap, alignment, then an enabled FP exception the instruction raised itself. `mfspr`/`mtspr` of an unknown SPR is privileged in user mode and illegal in supervisor mode (604 manual 4.5.7).
- **[code]** `mffs` returns `FFF80000` in the upper word; `fctiw` does too (that one is measured on the real 604). **[hw]** `mffs` is not.
- **[code]** `stfs` of a double with exponent below the single denormal range (undefined by the architecture) stores the top bits as if the value were normal. **[hw]**
- **[code]** FPSCR[NI] (non-IEEE mode) is ignored by the FPU and by the model. **[hw][open]**
- **[code]** `fres` is a full divide of 1.0 by the operand rounded to single, because that is what the 604 does. A 750 will need its own estimate. `frsqrte` is a 32-entry table of which 8 entries are measured; the other 24 follow the same rule. **[hw]**
- **[code]** Divide by zero and `0x80000000 / -1` return what the real 604 returns (`(a << 4) | 0xF`, low nibble 0 for a negative signed dividend; 1 for the overflow case). **[doc]** README.
- **[code]** The sequencer's scratch register (number 32) is not architectural and never visible. Update forms take one extra cycle because they are two operations.
- **[code]** The branch target buffer has 128 entries, no return-address stack; a stale or wrong entry costs three cycles and is corrected in EX. A mispredicted branch costs three cycles.
- **[code]** Latencies: multiply 2 cycles after request, divide 34 (radix 2; radix 4 would halve it), FP add/mul/madd 8, `fdiv` 34, `fdivs`/`fres` 20, `frsqrte` 2, plus 6 if an operand is denormal. A data access takes two cycles on the test bench bus until there is a cache. **[doc]** plan, M2 and M3.

### Design decisions that differ from the plan as first written

- **[code][doc]** Rule 1 now says commit in order at two points: CR, XER, LR, CTR, FPSCR, MSR and the SPRs when an instruction leaves EX; general and floating-point registers and memory in MEM/WB. The invariant that makes it safe: an operation that accesses memory writes no status register. M5's faulting memory accesses must keep that invariant.
- **[code]** CR, XER, LR, CTR, FPSCR and MSR have no forwarding at all; EX reads the committed registers. The hazard logic covers GPRs and FPRs only (seven-bit register names).
- **[code]** The FPU holds its response until the pipeline takes it (`resp_ready`), like the integer unit.

### What the tests do not cover, or cover with a stand-in

- **[hw][test]** No hardware data for: FP exception enables other than VE, FPSCR arriving with sticky bits set, 24 of 32 `frsqrte` entries, NI mode, the FPSCR instructions, `mffs`'s upper word, `stfs` below the single range, `lfs` of SNaNs and denormals, which XER/MSR bits stick, SRR1 and DSISR as a real 604 delivers them, reset values. The user-level ones are the v4 vector set asked for in `RESUME_hardware.md`; the rest need a supervisor-level run.
- **[test]** The golden FP vectors always start with CR = 0, so an FP instruction with a non-zero CR in place is only checked by the random FP programs.
- **[test]** dingusppc cannot be the reference for: FP arithmetic (never reports inexact, clears VE on compares), `tw` (operands swapped), undefined divide results (quotient 0), unaligned `lmw` (no exception), reserved XER/MSR bits (kept), undefined SPRs (plain storage), invalid instruction forms (trap as illegal), enabled FP exceptions and interrupts (never taken), `sc` and FP-unavailable SRR1 bits (one wrong bit each; the test bench clears them). The random programs avoid all of these or correct for them; `verilator\ref\README.md` has the list with file and line numbers.
- **[test]** The random FP programs skip operations the model marks undefined (an enabled overflow or underflow whose adjusted exponent is still out of range).
- **[test]** The random integer programs keep r0, r1 and r2 as index and data bases, drift the bases slowly, keep `lmw`/`stmw` word-aligned through a copy of the base, and set XER for `lswx`/`stswx` from controlled values.
- **[test]** The lockstep test bench models 16 MB of RAM with addresses wrapping modulo 16 MB; dingusppc reads all ones outside its RAM and drops stores, and cannot fetch from MSR[IP]=1 vectors, so every program sets IP=0 first. Interrupt tests use fixed addresses: handlers count at `00FFFFE0`/`00FFFFE4` and acknowledge at `00FFFFF0`.
- **[test]** The 300-program M3 lockstep run: the last 80 programs have a full passing summary; the first 225 showed per-program pass lines and no failure, but their final summary line was cut off by an output filter. Every later run (60 programs with exceptions) has a complete summary.
- **[test]** Deliberate-bug checks were done for the integer pipeline (4 bugs) and the FP pipeline (5 bugs), not for the exception logic.
- **[test]** The trace ports on `DSPPC604` exist for the test bench; a real build leaves them unconnected.

### Cost and speed

- **[open]** Register files and SPRs are flip-flops; moving them to MLAB/M10K RAM is the main area saving. The forwarded FP operands feed the FPU's first stage directly and set the clock. Whole CPU: 10,781 ALMs, 69.5 MHz worst case. M5 step 4.
- **[open]** Speed is not yet representative: 1.36 cycles per instruction on straight-line code with an ideal bus; every data access takes two cycles until the caches exist.
- **[open]** Whether part of the CPU could run on the DE10-Nano's ARM was raised and set aside; the FPU's request/response boundary is where such a split would go.

### Repository and process

- **[doc]** The lockstep test binary links dingusppc (GPL-3), so that executable is GPL-3; nothing of dingusppc is in the repo, and the core stays GPL-2-or-later.
- **[doc]** `.gitattributes`: `sys/`, the template's `rtl/` demo files and the golden CSVs are byte-exact; our sources are LF; `clean.bat` no longer deletes `*.csv` below the root.
- **[doc]** One commit was redone the same minute after `git add -A` swept in the hardware session's unfinished `ppctest` files. Stage explicit paths.
- **[hw]** The 7600 is out of action (chimes, no picture, keyboard ignored, with its original 604 card, after three hours' rest). One unconfirmed guess: it sits at an invisible Open Firmware prompt because `auto-boot?` was set false. The 7300 runs the 604, 604e and G3 cards; the 601 card does not work in it.
