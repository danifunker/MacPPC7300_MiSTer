# Resume prompt: the machine around DSPPC604, from milestone E

(Written 2026-10-07 at the end of the machine session that put Cuda on the board, made the 7300's ROM the reference, wrote the machine's plan, wired the VIA's interrupt through Grand Central and put Open Firmware's console on the modem port.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (its plan is `docs/DSPPC604_plan.md`); the machine has its own plan, `docs/PPCMac_plan.md`, whose milestones are C (Cuda), I (interrupts through Grand Central), T (a serial console), E (the empty SCSI buses), V (video), K (ADB), S (SCSI boot), A (sound), P (persistence and the clock), X (the PCI bus, later). C, I (for the VIA) and T are done, in simulation and on the board: Open Firmware's prompt comes over the MiSTer's UART, which is how I run validation tests now. Ask me where a decision is mine; otherwise follow the documents.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, how to run everything, the build's size and speed.
- `docs/PPCMac_plan.md`: the machine's milestones with their proofs, its rules (one device port, one way into memory through the CPU's snoop port, one way into the CPU, machine-specific things in machine modules, two checks before the board, time by phase accumulation, stubs written down), what the ROM asks for in order (dingusppc's 10^9-instruction run), the results so far, and the decisions waiting for me.
- `docs/PPCMac_stubs.md`: everything the machine stubs, simplifies or leaves out. Keep it current: an entry changes in the same commit as the stub.
- `docs/DSPPC604_plan.md`: the CPU's rules and its M6 section (the ROM in lockstep, the board).
- `verilator/ref/README.md`, `verilator/machref/README.md`.
- `rom7300/README.md` (git-ignored): the 7300's ROM disassembled, and where every address the docs quote moves to; `rom7600/README.md` for the method and the notes for an implementation.
- `C:\Temp\mistercore\dingusppc\devices\common\scsi\mesh.cpp`, `scsibusctrl.cpp`, `scsibus.cpp`, `sc53c94.cpp`: the reference for milestone E.

## Where things stand (2026-10-07)

- The reference ROM is the 7300's (`ppctest\runs\my7300.rom`, 077D.34F2); `run_machine.py` runs it by default, `--rom7600` the 7600's, which must keep passing. `machref` builds a `pm7300` by default.
- **The CPU** (`rtl/DSPPC604/`) is unchanged since the update-form fix (0869a0f). Do not change it in this session: if the machine finds a CPU bug or needs a CPU feature, stop, write a hand-off prompt for a CPU session, and stop the session. That is my rule for this project.
- **Interrupts (milestone I)**: `PPCMac_gc.sv` keeps Grand Central's events, mask and levels as MAME's and dingusppc's (an event at a line's rising edge, at either edge in 68k mode, which Mac OS uses), the VIA as source 12. Both ROMs run 100 million instructions in lockstep with Mac OS's timer interrupts. The device traffic matches dingusppc's whole 7300 through Mac OS's start-up, interrupt service included, apart from two explained differences (dingusppc re-signals the VIA's interrupt on every register access; the real Cuda sends packets dingusppc's model does not, and dingusppc has an ADB mouse and keyboard attached).
- **The serial console (milestone T)**: `PPCMac_escc.sv` (a Z85C30's asynchronous mode; channel A on the modem port at the rate software sets, 38,400 baud from Open Firmware) inside `PPCMac_gc`; Grand Central's NVRAM can be loaded through a port while reset is held (the bench's `--nvram`, the board's `boot1.rom`); `syn\nvram_of_prompt.bin` (Open Firmware's own defaults with `auto-boot?` false; `verilator\nvram.py` makes and changes images) stops Open Firmware at its prompt on `ttya`. The bench has a terminal on the port (`--serial-in LINE`, `--serial-stop`); on the board `python syn\mister.py put-nvram`, `uart`, `type LINE ...`. Without an image the device traffic is byte for byte what it was before.
- **Where the RTL's path leaves dingusppc's**: Mac OS's SCSI Manager reads MESH's ID register (F30180E0) at 82 million instructions (86 million in dingusppc); dingusppc answers E2, our stub 0, and Mac OS then never sets MESH up. That is milestone E.
- **The board**: Cuda releases the CPU 1,284 ms after the machine's reset (readout row 6, low half: 0504) and both ROMs run through Open Firmware into Mac OS. The build without the interrupt: 28,043 device writes, the last after 135.48 million instructions, as the simulation of the same RTL (a constant 150,000 instructions apart from before 28.7 million, the Cuda waits being real time). The build with the interrupt (25,379 ALMs): Mac OS runs on its timer, the device writes growing (38,489 after 666 million instructions with the 7300's ROM), the readout's pc alternating between the NanoKernel's interrupt code and Mac OS; the board is 150,000 instructions ahead of the simulation at 25 million and 1.08 million at 73 million (the interrupts come in real time). The build with the ESCC (26,019 ALMs, 62.31 MHz slow model): Open Firmware's prompt on the UART, commands answered. The OSD's UART option is the modem port by default, the debug readout's hex lines (115,200) the other choice. The CPU's clock closes at 61-62 MHz slow 100 C in these builds (65 asked; the failing paths are the CPU's own, decode into the branch target buffer, then the data cache through `PPCMac_machine`'s device decode into Grand Central, which a register stage on device requests would cut); the board runs at 65 MHz.
- **Tests**: `python verilator\run_core.py`, `python verilator\run_cuda.py`, `python verilator\run_machine.py --max-instr 100000000 --progress 5000000 --dev-log FILE` (and `--rom7600`), `verilator\machref` (`make`, then `machref --rom ... --log ...`), `python verilator\machref\devdiff.py RTL_LOG MACHREF_LOG --hunks N --no-values`. Leaving the NanoKernel handler's own accesses (FFF15750, FFF1575C, FFF15764) out of both logs before `devdiff` shows the rest of the traffic.
- **The board**: `python syn\mister.py put-core | put-rom FILE | cfg --ram MB --boot rom|memtest | load | shot OUT.png | uart SECONDS | menu`. Quartus: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac` (about 25 minutes). The board is shared: load the menu core again when done.

## Decisions waiting for me (from the plans; do not decide them yourself)

- Decided 2026-10-07: the plan's order (T first, then E, V, K, S, A, P); the VRAM, all 4 MB, in the DDR3, block RAM only for the line buffer and the colour table; the PCI bus as milestone X, later.
- Still open: which monitor the sense lines report, which disk image (milestones V and S), which PCI card first (X).
- The CPU's: the `lfs` stall against the FPU operand register; the memory unit's second-word address register; trace and the IABR; which machine the first release models.

## What I want from this session, in order

1. **Milestone E**: MESH and Curio as empty SCSI buses, as dingusppc's `mesh.cpp` and `sc53c94.cpp` behave with no target (the ID, the sequencer commands, arbitration and selection with its timeout from `scsibusctrl.cpp`, the interrupt and exception registers, Grand Central's sources 0D and 0C), as device modules behind the machine's one device port. Proof: the 7300's ROM in lockstep through Mac OS's probing of both buses (dingusppc selects every MESH target from 230 million instructions and every Curio target from 355 million), its device traffic with values matching dingusppc's apart from the differences already explained; the 7600's ROM still passing; then the board. Update the stubs list and the plan.
2. Then the plan's next milestone, V, in the order I have chosen.
3. Anything I ask for to run validation tests from Open Firmware over the modem port comes before both (for example a way to load the `ppctest` programs through Open Firmware's `dl` and read their results back over the port).

## Rules

- SystemVerilog, limited to what Verilator 5.020 and Quartus 17.0 both accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`). Quartus 17 refuses, silently or not: a second read expression on a memory, byte-enabled writes to a wide array, a variable part-select or bit-select of a two-dimensional array (take the word into a vector first), `genvar` inside the `for`, a generate loop without `generate`, every RAM style attribute, a three-input add as one expression, a RAM written from registers with a combinational read. A comment line starting with "Verilator" is a Verilator metacomment.
- Machine modules are `PPCMac_*` under `rtl/machine/`. `sys/` is never edited; `rtl/pll*` is the template's PLL edited by hand.
- Real hardware outranks every emulator; of the emulators I trust dingusppc most; where dingusppc is high-level or does what a real line cannot, MAME.
- Edit files with the editor tools, not scripts or heredocs.
- Commit at verified points, never push; stage explicit paths, never `git add -A`. Do not modify anything under `ppctest\` (another session's) or the dingusppc tree. Quartus rewrites a line of `PPCMac.qsf`; leave it out of commits.

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04); `sudo` needs my password. Run WSL commands as `wsl --cd <windows dir> -- <command>` from PowerShell; PowerShell mangles `$variables` and quotes in a `bash -c` string, so put anything non-trivial in a script file. The runners set a private TMPDIR (two WSL builds once raced on /tmp); a second machine bench of other RTL builds in its own directory with `PPCMAC_BUILD`.
- Quartus Lite 17.0 at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows, no extra packages. Commit messages through a file (`git commit -F`).
