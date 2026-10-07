# Resume prompt: a CPU bug the machine found (update-form load with rD = rB)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7600 machine. The machine session that built Cuda (the 7600's ADB/power microcontroller, as the real chip running its real firmware) took the 7600's ROM past the point where it used to stop, and at 24,440,545 instructions the lockstep with dingusppc caught the CPU getting an instruction wrong. My rule: CPU bugs are fixed in a CPU session, not a machine session. This is that session.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, what the real 604 does, how to run everything.
- `docs\DSPPC604_plan.md`: the milestones, **the rules that keep the pipeline free of special cases** (read them before touching anything), the M6 section.
- `verilator\ref\README.md`: the dingusppc lockstep library.
- `docs\PPCMac_stubs.md`, its last section: where the machine's lockstep bench takes the core's word for something (one accommodation is new: SPRs the real 604 lacks).

## The bug

`python verilator\run_machine.py --max-instr 24440600` (the 7600's ROM, 16 MB, lockstep; about two minutes, the first 5.4 million cycles being Cuda's cold start) stops with:

```
MISMATCH after 24440545 instructions at FFF122B4 insn=7F9AE06E
  r26   reference 00FEA000  core 00FEA021
  the core reported writing: r28=00000021 r26=00FEA021
  before it: rD/rS field r28=00000000, rA field r26=00FEA000, rB field r28=00000000
```

`7F9AE06E` is `lwzux r28, r26, r28`, in the NanoKernel's page-table code (`rom7600\ppc\ppc_nanokernel_FFF10000.lst`, FFF122AC: `slwi r28,r30,2`; `extlwi r26,r31,30,22`; `lwzux r28,r26,r28`). The effective address is r26 + r28 = 00FEA000; the word loaded is 00000021, which goes to r28. r26 must become the effective address, 00FEA000 (the architecture; dingusppc agrees; and both operands are multiples of 4 here, so 00FEA021 cannot be an address the program formed). The core writes r26 = 00FEA021: the address plus the loaded value, as if the update of rA were formed from rB after rB (= rD) had taken the load's result.

rD = rB is a valid form of the indexed update loads (only rA = 0 and rA = rD are invalid). What is not known yet:

- which forms do it: `lbzux`, `lhzux`, `lhaux`, `lwzux` are the candidates (rD = rB); the D-form update loads have no rB; the FP update loads write an FPR; `lmw` and the string loads write many registers;
- whether it depends on timing (a cache hit or miss, a stall in the cycle the update is formed: the ROM runs here with caches on, from SDRAM through the clock crossing);
- why the random lockstep programs (`run_core.py` step 5) never met it: check whether the generator (`verilator\progs.py`) ever gives an update-form indexed load rD = rB.

## What I want from this session

1. A directed test that reproduces it outside the ROM (every update-form indexed load with rD = rB, hit and miss, with and without wait states), in the suite (`run_core.py`), failing first. Make the random generator able to produce the case.
2. Find the cause and fix it. **If the fix changes how a hazard is handled or how state is committed (the plan's rules), stop and ask me before building it**; tell me what the rule-free alternative costs if there is one.
3. Then the whole suite (`python verilator\run_core.py`, `python verilator\run.py`, `python verilator\run_cuda.py`), cycle counts held where they should be (1.85/3.53 and 1.87/3.81 on the golden programs), and `python verilator\run_machine.py --max-instr 60000000 --progress 4000000 --dev-log FILE`: it must pass 24,440,545 and go on in lockstep. Note where it stops next and why (the ROM is into the NanoKernel and the Mac OS ROM by then; the next stop is likely a device: `docs\PPCMac_stubs.md`; or `verilator\machref\devdiff.py FILE MACHREF_LOG --hunks 10 --no-values` against dingusppc's whole 7600 shows where the device traffic parts).
4. Record it in the plan (a short section: the bug, its cause, the test, the fix and its cost), commit, and say in `RESUME_machine.md` that the machine session can continue.

## Where things stand (2026-10-06, late)

- **The CPU** (`rtl\DSPPC604\`) is unchanged since M5 apart from this bug: 150 million instructions of the ROM in lockstep before Cuda existed, all the suites green.
- **The machine** now has Cuda (`rtl\machine\PPCMac_cuda.sv`, `PPCMac_hc05.sv`, `PPCMac_cudarom.sv`, the firmware in `rtl\machine\cuda\341s0060.bin`), Grand Central's VIA with a real shift register and port B, and VIA accesses paced to the VIA's clock as MAME's Grand Central does. Cuda holds the CPU in reset until its firmware powers the machine up (5.4 million cycles in the bench with `CUDA_FAST_BOOT`; 1.28 s on the board). The ROM's first Cuda exchange and Open Firmware's Cuda traffic now go through; the device traffic matches dingusppc's whole 7600 (`devdiff.py --no-values`) up to the NanoKernel, apart from Cuda's timing.
- **Not yet done for Cuda**: the board (a full Quartus compile and `syn\mister.py`); that is the machine session's, after this fix.
- **One bench accommodation is new** (`verilator\core_main.cpp`, machine mode): `mtspr`/`mfspr` of an SPR the real 604 does not have (the README's list) takes the program exception in the core, as on the chip; dingusppc accepts the 604e's MMCR1, PMC3, PMC4 (the NanoKernel probes them at FFF131B0), so the bench makes the reference take the exception with the core's SRR0, SRR1 and MSR. The MISMATCH report now also prints the registers the core reported writing and the instruction's operands before it.

## Rules

- SystemVerilog, limited to what Verilator 5.020 and Quartus 17.0 both accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`). The README and the plan list what Quartus 17 refuses.
- Module and file names carry the CPU model: `DSPPC604_*`.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most.
- Edit files with the editor tools, not scripts or heredocs.
- Commit at verified points, never push; stage explicit paths, never `git add -A`. Do not modify anything under `ppctest\` (another session's), `sys\`, or the dingusppc and MAME trees.
- One Verilator build in WSL at a time; launch WSL from PowerShell with Windows paths (`wsl --cd <windows dir> -- <command>`).
