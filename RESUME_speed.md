# Resume prompt: the sound first (the chime low and crackly; Mac OS's sounds wrong after 40 ms); the speed work paused with its account in the plan

(Rewritten 2026-10-10 at the end of the cycle-accounting session (builds
47, 48) for a Claude Fable session. It is the only resume prompt:
everything it needs is here or in the files it names; the board's tools,
the Main, the rules and the environment are at the end.)

**The user's decision, 2026-10-10: the sound issues come first; the speed
work stops after build 48.** So the next session is a **machine session**
(the usual rule: it never changes the CPU) on the sound:

1. **The startup chime on the board is far too low and crackly** (the user,
   by ear, on build 47; never listened to before: milestone A's proof was
   the chime bit-exact in simulation, "on the board, to be heard"). First
   have the user compare build 38 (`releases/`) by ear: if 38 is clean, the
   suspect is build 43's area cut, which made DMA channel 8 fetch a word per
   memory access instead of a 32-byte line (`MacPPC7300_dbdma`'s `LINE` 0
   for channel 8; AWACS's FIFO lasts about three frames, 68 µs): put channel
   8 back on lines. The level is a separate fault: AWACS's attenuation
   fields or the scaling into the 16-bit output; measure it in the bench
   (`run_scsi.py` test 14 drives the chime's path) against the ROM's sample
   values and the MiSTer's audio output in `MacPPC7300.sv`.
2. **Sound in games** (open since 2026-10-09): after its first 40 ms a
   sound's content is wrong; the Sound Manager refills its buffers far ahead
   of the hardware and polls channel 8's status until ACTIVE clears. The
   plan's decisions table, "sound", has the analysis; build 42 (`TRACE = 1`)
   records channel 8's commands and interrupt. A diagnostic build needs
   `TRACE = 1` in `MacPPC7300.sv` (and `PERF = 1` only for the counters).

The speed work resumes later from `docs/MacPPC7300_plan.md`, "Where the
cycles go" (the account and the ranked cuts; the first needs the user's
go-ahead under rule 2 of `docs/DSPPC604_plan.md`), with the paragraphs
below as its state. The user's real 7300/120 reference row is in the Speed
table.

---

## The speed work's state (paused 2026-10-10)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with my own PowerPC CPU, `DSPPC604` (`rtl/DSPPC604/`), inside a Power Macintosh 7300/7600 machine (`rtl/machine/`). It works: Mac OS 7.6.1 to 9.1 and Debian 7.11 boot on the board. The core is MacPPC7300; the fifth release is build 38 (`releases/MacPPC7300_20261009.rbf`, the Main c641b24f). The CPU runs at 70 MHz with a 128 KB L2 (OSD "L2 cache (on reset)", default on). I want it **faster, measured**, and I have found where the speed is:

**On a real 7600 with a 120 MHz 604 (40 MHz bus, 3x) this core is about a quarter as fast on Speedometer's CPU tests. The clock explains 0.58x; the rest, about 2.3x, is cycles per instruction** (the integer golden programs run at 1.85 cycles an instruction on this core; a 604 is four-issue, out of order, with single-cycle L1 hits and a 512-entry branch history table). That is the work item of this session:

1. **Read the 604 User's Manual's chapter 6 first** (`Scratch\PPC\PowerPC_604_Users_Manual_Nov94.pdf`; `604um.txt` is its text for grepping): "Instruction Timing": the fetch, the 64-entry BTAC and 512-entry BHT, dispatch, the branch-correction examples (6.4.4-6.4.6) and the per-unit latency tables (6.5.1-6.5.5: every integer op 1 cycle, loads 2 + bus, `fadd`/`fmul`/`fmadd`/`fcmp` 3 pipelined, `fdiv` 32). Put the 604's numbers in the plan as the comparison row for ours (1.85 integer cycles an instruction on the golden programs; the FPU 7-8, 33, one at a time). **Then cycle accounting.** Put counters in the core (a few 32-bit counters read through the debug path or the trace, or a Verilator-side account if the board route is long): instructions retired; cycles; fetch bubbles after taken branches and mispredictions; load-use stalls; D-cache misses and their cycles; I-cache misses and theirs; cycles waiting for a multi-cycle integer op (mul, div); cycles waiting for the FPU; L2 misses. Read them on the board under Speedometer's CPU tests (Dhrystones, Towers, Quick Sort, Puzzle; the script runs them all) and under the random lockstep programs. **Then attack the biggest bucket.** My guesses, to be checked, not followed: branches (every taken branch's redirect bubbles and the BTB's reach), load-use stalls (a load's data is not there until it reaches WB: `ex_stall` in `DSPPC604.sv`), then the one-instruction-at-a-time issue.
2. **The pipeline rules hold** (`docs/DSPPC604_plan.md`, "Rules that keep the pipeline from growing special cases"). A cut that changes how a hazard is handled or how state is committed (a second issue slot, a load's data forwarded a stage earlier, a branch resolved earlier) needs my go-ahead before it is built: stop and ask, with the rule-free alternative's cost. Cuts inside a unit, or a better predictor that leaves the handshakes alone, do not.
3. **Every step measured on the board** with Speedometer 4.02 under the fixed conditions (`syn\speedo_run.py`, below) and the time to the Finder; the whole Speed table is in `docs/MacPPC7300_plan.md`. Also run Speedometer on my real 7600/120 for the reference row if I haven't yet (ask me; the Graf test question too: whether a real machine offers 1-bit at 832 x 624).
4. **A release** of a proven faster build (`releases/`, its README, the Main it was tested with): ask me first.

**This is a CPU session.** My usual rule is that a machine session never changes the CPU; this one may change `rtl/DSPPC604/`, behind the gates below and rule 2 above.

**Work independently otherwise.** Decide what the documents leave open, record each decision in `docs/MacPPC7300_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. I am often around and may answer, but don't wait for me. Before your context runs short, rewrite this prompt for the next session and commit it.

## Read first (the source of truth; it overrides anything remembered)

- `docs/MacPPC7300_plan.md`: the **Speed** section (every build's timing, area, boot time and Speedometer numbers, builds 28 to 46, and how a run is made), the decisions table (the last rows: "speed" 2026-10-10, the FPU cuts).
- `docs/DSPPC604_plan.md`: the rules, "Pipeline shape", M3/M4 (the pipeline), M5 (the caches, the MMU), M2's last paragraphs (the FPU as it now stands and what was tried), "Cost and speed".
- `README.md`: the build table (through build 46), "How fast will it be".
- The last sections here: the board's tools, the Main, the rules and the environment (mister.py, the Remote, Quartus, WSL). They all apply.

## Where things stand (2026-10-10)

- **Committed, a1ae377 and after (builds 47, 48): the cycle accounting.**
  `DSPPC604_perf` behind `PERF` (28 counters: every cycle classed, the
  events counted), into the DDR3 trace every 2^23 cycles with `TRACE = 1`
  (kind 12, five records), `syn\perf.py` for the account per 120 ms
  interval (`--file` a capture of `mister.py trace-capture`/`trace-fetch`,
  `--csv`, `--sum A B`), `speedo_run.py --shots` for which test is on; the
  benches print it (`core_main.cpp`, `print_perf`). Measured on the board:
  the plan's "Where the cycles go" (the table per phase, the ranked cuts).
  The user's real 7300/120 ran the same Speedometer: 3.0-4.5x on the CPU and
  FPU tests, the clock 1.71x of ours. A release build keeps `PERF = 0`.
  The whole run's capture: `Scratch\speedo_b48\` (`perf.csv`, the
  screenshots); the first 48 s of a capture are the previous run's ring.
- **The bitstreams:** b47 (`Scratch\qbuild10`), b48 (`qbuild11`) in
  `Scratch\build1\`; the board was left with build 46 in `_Unstable`,
  Debian on slot 0, the machine off.
- **Committed, 3514027 (builds 44, 45):** the FPU's results that need no arithmetic are found a cycle after the request, from its operand registers, and the operands' classes (`fp_cls_t`, `cls_a/b/c`) come from the core beside the operands (`fp_classify`, `fp_classify_single` for an lfs result still a single). Build 42's 400 worst paths were that one path; build 45 is -1.350 ns at 70 MHz asked (from -2.404), 35,725 ALMs, no FPU path among the 400 worst; the limit is now the fetch address into the I-cache's way RAMs and PLRU, and the D-cache's tag RAM into the I-cache. Speedometer as build 38.
- **Committed, e69c10e (build 46):** S_LZC skipped when the leading-zero count is known: `fmul` 6 cycles, `fdiv` 33, `fdivs`/`fres` 19, `frsp`/`fctiw` 7, a sum with a pinned addend or a dominant product 7, an addend-dominant sum still 8. Build 46: 35,238 ALMs, -2.249 ns with seed 1 and -3.356 with seed 2 (both fits: the fetch address into the I-cache's RAMs, no FPU path among the 400 worst; three fits of a near-identical CPU at -1.35, -2.25 and -3.36 ns say that family's placement swings 2 ns). Speedometer: Math 108.111 (106.797), FPU 3.600 (3.566), the rest unchanged.
- **Tried and reverted:** the addend-dominant sum's count taken as nominal and corrected in S_NORM (every vector passed; S_NORM then did not fit the cycle: the unit alone 65.8 MHz). Two designs that could still take that cycle are in `docs/DSPPC604_plan.md` (M2's last paragraph). The rest of the FPU latency list (the add path's alignment in the request cycle, a radix-8 divider, S_SHIFT into S_NORM, FP overlap) is worth a few per cent on three FPU tests: **deferred behind the cycles-per-instruction work.**
- **Bitstreams:** `Scratch\build1\MacPPC7300_bN.rbf`, b28 (the third release) to b46 (b33, b33a, b34 carry build 33's cache bug; b35 never built; b37 abandoned). Quartus scratch copies: `Scratch\qbuild6` (44), `qbuild7` (45), `qbuild8` (46, seed 1), `qbuild9` (46, seed 2), `qbuild5` (42/43). TimeQuest: `worstNN.tcl` in each (400 worst paths by family through `syn\sta_families.py worst_bNN.txt`, the six slowest cell by cell in `worst_bNN_paths.txt`). `syn\check.py fpu` synthesises the FPU alone (3,443 ALMs, 74.6 MHz at build 46); it uses physical synthesis with register retiming, so a stage that no longer fits shows up as retimed registers (`_NEW_REG`, `_RTM`) dragging its neighbours down: read the cell-by-cell path.
- **The bug of build 33, worth remembering:** every simulation gate was green and the board bombed within minutes (Mac OS 7.6.1 "error type 10" in the Finder, 9.1 stuck at the grey screen): the D-cache's S_IDLE took a request it had not granted when a snoop to the pending write's set and a CPU request to another set met in one cycle. The lockstep's disk-less boot has almost no DMA; the board's disk DMA finds such a race at once. The snoop storm in `run_core.py` fails on that cache within a few thousand instructions on every seed. **Any change to a cache's or the machine's arbitration must run `run_core.py` (the storm is in it) and then the board with a disk.**
- **The board, as left on 2026-10-10:** build 46 in `_Unstable/MacPPC7300.rbf` (the release is still build 38), the Main c641b24f (`MiSTer.9e88154e`, `MiSTer.a2546ea7`, `MiSTer.official` kept on the card); `games/MacPPC7300/`, `config/MacPPC7300.*`, `screenshots/MacPPC7300/`; the machine off, slot 0 Debian (`linux_debian711.hda`), slot 4 the Open Transport CD, slot 1 empty, 120 MB, eth0, the L2 on. For a Speedometer run put `os761ot.hda` on slot 0 first (`mister.py mount 0 games/MacPPC7300/os761ot.hda`: a config file read at the core's next start, so it can be set while another core runs) and Debian back after (`mount 0 games/MacPPC7300/linux_debian711.hda`). The user shares the board: ask before taking it if they may be using it.
- **Open from build 38's test:** the first time 7.6.1's Finder opened `os753.hda` on ID 1 it stopped with a bus error; not seen again. If it comes back, suspect a race in the disks' DMA first and give `run_scsi.py` a disk on ID 1.
- **Sound in games (open):** after its first 40 ms a sound's content is wrong (the Sound Manager refills its buffers far ahead of the hardware; it polls channel 8's status until ACTIVE clears). The plan's decisions table, "sound", has the analysis; build 42 (`TRACE = 1`) records channel 8's commands and interrupt. A new diagnostic build needs `TRACE = 1` in `MacPPC7300.sv`.
- **The user's request for later:** an OSD "Power" button that presses the ADB power key.
- **The SCSI disks' writes go through the Main's Mac-family write cache** (`support/mac/mac_disk.cpp` in `..\Main_MiSTer`): the Disk numbers are with it.
- **The disk image:** Speedometer 4.02 is at the root of `os761ot.hda`; `games/MacPPC7300/os761ot_backup.zip` (67 MB, zip64) is its backup: unzip it over the image on a PC if a CPU change ever corrupts the volume.

## Speedometer runs

`python syn\speedo_run.py OUTDIR RBF [--l2 off]` (with `syn\pointer.json`; `syn\boottime.py` photographs a boot alone) does a whole run from an **off** machine in 7 minutes: refuses to load unless the screen is dark, `put-core`, `cfg --ram 120 --eth`, `load`, times the Finder's menu bar (85 s), closes the Finder's windows, "Mac" Command-O, "Spee" Command-O, clicks the splash, clicks "Not Yet", Command-A, Command-D "Mac" Return, Return at the Graf notice, 100 s, photographs the results (`results.png`), Command-Q, clicks "No", the power key. Clicks find the arrow pointer in a screenshot and correct; never trust an open-loop move for a button.

Read the numbers off `results.png` and type them into the Speed table: CPU, Graphics, Disk, Math, PR; the Benchmark Mix (KWhetstones/s, Dhrystones/s, Towers, Quick Sort, Bubble Sort, Queens, Puzzle, Permutations, Int. Matrix, Sieve, average); Color (8-bit, 16-bit, average); FPU (KWhetstones/s, Matrix Mult., Fast Fourier, average). KWhetstones/s swings 15 % between runs (a timed test); the rest repeat within 1-2 %. The Graf Test is skipped ("this machine does not support monochrome graphics"), so PR is never given.

**Never reload the core while an OS has its volume mounted** (it corrupts the image). Shut Mac OS down with the power key (Menu) then Return; the screen goes dark (a screenshot fails: `no new screenshot appeared`); only then load. Debian at its login prompt: Ctrl+Option+Delete reboots it cleanly; the screen does not go dark on a reset, so load the core when the ROM's grey screen shows, before Mac OS mounts anything.

## What the timing says now (builds 45 and 46, slow 100 C, 70 MHz asked: 14.29 ns)

Build 45: -1.350 ns; 210 of the 400 worst paths from the D-cache's tag RAM into the I-cache's PLRU address, then CPU paths into RAMs (-1.07). Build 46 (the same except inside the FPU): -2.249 ns; all 400 the fetch address: the MMU's `i_page_q` and the SPRG bypass into the I-cache's way RAMs and PLRU address. The fitter swings families by up to 1.7 ns between fits at 85 % utilisation; the board at room temperature has run -2.56 at 70 MHz through everything. A clock beyond 70 wants that fetch-address family cut first; it is the same logic the cycles-per-instruction work will touch (the fetch), so take the two together.

## The gates for every change

- `make -s lint` in `verilator\`.
- The CPU suites: `python verilator\run_core.py` (15 minutes; record the golden programs' cycle counts: 1.85/1.89/2.04 integer, 3.46/3.53 FP, 1.87 and 3.70 on the 7300's) and `python verilator\run.py` (and `run.py --csv ppctest\runs\results_604_7300_of_run1.csv`, the 7300's vectors).
- `python verilator\run_cuda.py`, `python verilator\run_scsi.py` for machine changes.
- `python verilator\run_machine.py --max-instr 300000000 --progress 50000000` (12 minutes): the 7300's ROM in lockstep with dingusppc into Mac OS. **Open Firmware waits about 150 M instructions for the chime's DMA (pc FF808768: not stuck); Mac OS starts near 200 M.** With memory-path changes also `--no-lockstep --ram 120 --max-instr 3000000 --dev-log FILE`: the writes to F80001C0-F80004F0 must put the banks at 0, 64, 96 and 112 MB.
- **One WSL job at a time**: two benches at once in WSL hung `run_core.py` for 25 minutes twice. From PowerShell, never end a bench's pipeline with `Select-Object -First N`: it stops the bench once it has its lines.
- A Quartus build (25 minutes, a `Scratch\qbuild*` copy; keep bitstreams as `Scratch\build1\MacPPC7300_bN.rbf`, numbering on from 46) and its timing report (`quartus_sta.exe -t worstNN.tcl` in the build directory, then `syn\sta_families.py`).
- The board: Mac OS 7.6.1 to the Finder and Speedometer under the fixed conditions (`os761ot.hda`, RAM 120 MB, the 16-inch monitor, 256 colours, Ethernet eth0, nothing else mounted); Mac OS 9.1, a floppy and the CD now and then.
- Commit at each verified step (explicit paths, the message from a file, `MacPPC7300.qsf` only through a patch of your own lines). When a faster build is proven, it is a candidate for `releases/` (ask me first).

## Other open work (the machine; not this session's unless it is quick)

The scaler fault fix (`ALLOW_POWER_UP_DONT_CARE OFF`) unproven; the CD changer parked; the double chime with the NVRAM; milestone A (Mac OS's sounds) and P's proof; 16-bit DirectColor; the 9.1 pointer missing from screenshots; floppy writing; on the board still unseen: the OSD itself (screenshots leave it out), Mac OS 8.6, millions of colours, 720K floppies, RAM 96/48/24/6 MB in "About This Computer". The plan's milestones and decisions table hold the details.

## The board's tools

`python syn\mister.py ...` (usage at the top of the file): `put-core RBF`, `load`, `menu`, `cfg [--ram MB] [--monitor 16|13|12] [--joy ...] [--ptr] [--eth] [--net eth0|eth1|wlan0|tap0] [--l2 on|off]`, `mount 0|1|2|4 PATH`, `umount N`, `shot OUT.png`, `keys TEXT`, `mouse DX DY [STEPS]`, `click`, `ws STEP ...` (`kbdRaw:N`, `kbdRawDown/Up:N`, `mouseMove:dx,dy`, `mouseBtn:left|left_down|left_up`, `sleep:S`, `text:...`), `osd-mount N NAME ...` (blind: N items down from the first menu item; a name it does not find leaves the OSD open holding the keyboard and mouse: Escape twice), `uart [S] [--baud N]`, `type LINE`, `trace [--last N]`, `trace-capture S`, `trace-fetch OUT`, `trace --file OUT`, `run CMD`. From Git Bash set `MSYS_NO_PATHCONV=1` before text with `/`. Mac OS: the Menu key is the power key (`ws kbdRaw:127 sleep:3 kbdRaw:28` shuts down), Alt is Command. A floppy is not remembered across loads. `cat /tmp/CORENAME` on the MiSTer says which core runs.

## The Main

The branch `Mac-ppc-enhancements` in `..\Main_MiSTer` (squashed by the user into e9eb5fe): the core in the Mac SCSI family, Ethernet, the rename. Installed on the board as `/media/fat/MiSTer`: md5 c641b24fec57a34de4b1b10b800a1639, the same as `releases/MiSTer` (built in WSL with `/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin` on PATH: rsync the branch to `~/.cache/macppc7300/main_ppcenh`, `rm -rf bin`, `make -j8`; Ubuntu's `arm-linux-gnueabihf-gcc` makes a binary that does not link). Kept on the card: `MiSTer.9e88154e`, `MiSTer.a2546ea7`, `MiSTer.official` (eb1799eb). Ask me before installing any other Main binary.

## Rules

- **Never push** (this repository or `..\Main_MiSTer`) or add a remote. **Never change anything under `sys/`** (not even another core's fix: describe it and let me decide). Don't modify `ppctest\`, the dingusppc or MAME trees, or the Quadra repository (`..\MacQuadra800_MiSTer`, read only).
- SystemVerilog both Verilator 5.020 and Quartus 17.0 accept; Verilator `-Wall` clean. Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM, byte-enabled writes to a wide array, a variable part-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, RAM style attributes, a three-input add or subtract as one expression, a RAM written from registers with a combinational read; an implicit `.name` port connection needs the same type. Declare before use. CPU modules are `DSPPC604_*`; machine modules are `MacPPC7300_*` under `rtl/machine/`.
- Edit files with the editor tools, not scripts, `sed` or heredocs (generated files and copies are the exception). New code gets short comments. Update `docs/MacPPC7300_stubs.md` in the same commit as any stub change.
- Commit with explicit paths (never `git add -A`), the message from a file (`git commit -F`), ending with the co-author line the harness gives. `Scratch\` is git-ignored.
- Never type passwords or other credentials into anything on the board (I type them). Real hardware outranks every emulator; dingusppc first among them, then MAME, Linux's and NetBSD's drivers, the chips' manuals. rb-cli (`C:\Users\spam\AppData\Local\Programs\Rusty Backup\bin\rb-cli.exe`) handles Mac archives and HFS images (`archive extract`, `expand --to-hfv`, `ls`, `put`): use it before anything else.

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04); run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>` (Git Bash mangles the paths), anything with `$`, quotes or pipes from a script file. One Verilator build at a time. Python 3.9 on Windows (`websockets`, PIL, `capstone`).
- Quartus Lite 17.0: copy `MacPPC7300.qpf/.qsf/.sdc/.srf`, `MacPPC7300.sv`, `build_id.v`, `files.qip`, `rtl\`, `sys\` into a `Scratch\qbuild*` copy and run `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile MacPPC7300` there in the background (about 25 minutes; `rm -rf` the copy's `rtl` from Git Bash, PowerShell's Remove-Item is refused there). Two compiles side by side are fine (40 minutes each).
- The MiSTer: 192.168.99.143 (`syn\mister_host`), the Remote on 8182, key-based SSH as root (`~/.ssh/mister_only`). Images: `\\daninas.local\Software\BlueSCSI Images\PowerPC Images`, Mac software under `\\daninas.local\Software\Old Mac Stuff`.
- References: dingusppc (`C:\Temp\mistercore\dingusppc`), MAME (`..\mame\src\mame\apple`), the Quadra 800 core (`..\MacQuadra800_MiSTer`, read only), the Mac LC core (`..\MacLC_MiSTer`).
