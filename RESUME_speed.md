# Resume prompt: speed: close timing at 70 MHz, then finish the FPU's pipeline

(Rewritten 2026-10-15 at the end of the machine session that made the
seventh release, for a CPU session. It is the only resume prompt:
everything it needs is here or in the files it names. The prompt it
replaces, for the cycle-accounting work of 2026-10-10, is in git's history;
that work went on through 2026-10-14 on `fpu-pipe`, since merged.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with my own PowerPC CPU, `DSPPC604` (`rtl/DSPPC604/`), inside a Power Macintosh 7300/7600 machine (`rtl/machine/`). It works: Mac OS 7.6.1 to 9.1 and Debian 7.11 boot on the board. The seventh release is `releases/MacPPC7300_20261015.rbf` (master 7941709): the CPU runs at 70 MHz, or 100 MHz as an overclock (OSD "CPU speed (on reset)"), with a 128 KB L2. Two things are left of the speed work, in this order:

1. **Close setup timing on the CPU clock at 70 MHz** in Quartus 17.0's slow 1100 mV 100 C model (the only model this project times). The release misses by **2.47 ns** (Fmax 59.7 MHz; 8,794 failing launch/latch pairs, 6,389 of them within 0.5 ns, only 15 worse than 2 ns). Every build since 70 MHz has carried about this much (-1.8 to -2.9 ns) and run fine on the board at room temperature; I want it closed for real. The memory and video clocks already close.
2. **Finish the FPU's pipeline.** `docs/fpu_pipe_plan.md` step 1 (the unit's latencies: fadd and fmul 5 cycles, fmadd 6, fdiv 18, the dividers) is done; **step 2, the overlap, was never built**: EX still holds every FP instruction until the FPU answers, so independent FP operations never overlap as on a real 604 (three cycles, pipelined). Build the overlap there described, in its order: (1) a second, independent FP operation accepted behind the first and committed in order through the completion queue; then (2) cacheable loads behind a pending FP operation; (3) branches behind it.

**Rule 2 of `docs/DSPPC604_plan.md` (a change to how a hazard is handled or how state is committed needs my go-ahead, with the rule-free alternative's cost):** my asking for (2) is the go-ahead for overlap (1), FP behind FP inside the completion queue. Overlap (2) and (3) change the memory unit's and the branch's hazards: put each to me with its design and what (1) measured first. For the timing: cuts that leave the pipeline's behaviour alone (logic restructured inside a stage, duplicates, a carry-free sum-and-compare, a register where the cycle has room) need no go-ahead; a cut that moves a decision a cycle later (a redirect, a CR update, the effective address before translation) does: list them with their cost in cycles per instruction, measured, and ask. I'm often around.

**The FPU work must not undo the timing work:** after (1) closes 70 MHz, every FPU step keeps it closed (or the step's cost is put to me).

**This is a CPU session:** it may change `rtl/DSPPC604/`, and for the timing also the machine's paths into the CPU's clock (Grand Central's read mux, the L2: see below). Work independently otherwise: decide what the documents leave open, record each decision in `docs/MacPPC7300_plan.md`'s decisions table ("decided by the session, DATE", with the reason), the CPU's in `docs/DSPPC604_plan.md` and `docs/fpu_pipe_plan.md`, and in the commit message. Commit each verified step. A release: ask me first. Before your context runs short, rewrite this prompt for the next session and commit it.

## Read first (the source of truth; it overrides anything remembered)

- `docs/DSPPC604_plan.md`: the rules ("Rules that keep the pipeline from growing special cases"), "Pipeline shape", M2 (the FPU), M3/M4 (the pipeline, the completion queue), M5 (caches, MMU), the timing passes.
- `docs/fpu_pipe_plan.md`: step 1's account, step 2's design (the three overlaps, why Speedometer gains little from them), the timing notes (the effective-address family and the two ways to cut it).
- `docs/speed_results_20261010.md` to `..._20261012.md`, `docs/speed_profile_20261013.md`: what the speed work built and measured (MEM's second slot, the BTB/ITT, branch folding, the 64 KB I-cache, the 100 MHz fits); `docs/speed_AT_log.md` (the completion queue).
- `docs/MacPPC7300_plan.md`: the Speed section and the decisions table's last rows ("CPU speed": how the switchable PLL works and was measured; "linux", "network", "keyboard", "scsi": the 100 MHz staging done in the machine).
- `README.md`: "CPU clock", the build table.

## Where things stand (2026-10-15)

- **The PLL is reconfigurable** (`rtl/pll/pll_0002.v`, Quartus's own generation: a 700 MHz VCO, the CPU's counter C1 dividing by 10, the memory clock's C2 by 7). `MacPPC7300.sv` keeps `CPU_MHZ = 70`: **the build is timed at 70**, and the OSD's 100 MHz rewrites C1 to 7 through `sys/pll_cfg` under reset. Never set `CPU_MHZ = 100`: Quartus then merges C1 with C2 (both by 7) and the rewrite would move the memory clock too. To see a placement at 100 MHz: `quartus_sta.exe -t <repo>\syn\sta_at100.tcl` in the build's directory (the release: -6.76 ns at 100; builds fitted at 100 had about -5.9).
- **The CPU clock's name** in a timing report: `emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk` (older builds: `general[1].gpll~PLL_OUTPUT_COUNTER`). `syn\sta_cpupaths.tcl` writes every failing pair (slack, from, to, logic levels) to `cpupaths.txt` in the build's directory (3 minutes); group them by endpoint and source module in Python.
- **The release's failing paths at 70 MHz, by endpoint (worst slack, pairs, source):**
  - The D-cache's `state.S_IDLE` and the memory unit's `state`/`S_RSP0` from `mem_result` (12 levels, -2.47, -1.75): MEM's result forwarded into the effective address, then the cache's and memory unit's decision in the same cycle. `fpu_pipe_plan.md`'s timing notes: this family needs the effective address registered before translation (a cycle on every load: rule 2) or a carry-free sum-and-compare for the page match (rule-free).
  - `pc_f`, the return stack (`ras_scount`, `ras_spec_write`), the ITT (`itt_spec_h`), `if2_valid`, the MMU's `i_info_q`, `dsisr` from `wb_result` (8-9 levels, -2.31 to -1.58): write-back's forwarding into branch resolution and the redirect.
  - `cr[*]` from `fa_mem` (11-12 levels, -2.15 to -1.66): a forwarded operand through the ALU into CR0/CR fields.
  - The D-cache's `wr_data_wd` from its tag RAM (-1.69), the I-cache's `r_addr` into the fetch stage's RAM (-1.57).
  - In another fit of the same design (the morning's 70 MHz build, `Scratch\q70mon\cpupaths.txt`), the worst were the flush/kill cone instead: `if2_kill`, `if2_itt_idx[9]`, `pc_f`, `pred_hold` from `msr`, `fpscr`, `mem_valid`, `wb_valid`, `resv_valid`, `ex_dec.sys/spr`, the FPU's `fin_set` (9-11 levels, -2.85); `ex_dec.spr/sys` into `mem_result` (-2.2); the I-cache's tag into the fetch RAM (-2.4); then the MMU, the memory unit, the D-cache, the BTB/ITT RAMs at -1.9 to -1.1. **The fitter swings these families by 0.5-1 ns between fits: cut all of them, not the one a fit happens to put first,** and judge a cut over two seeds.
  - **Machine paths in the CPU clock:** Grand Central's read mux into the machine's line buffer (1,014 pairs, -1.13: device reads want one more clock, which costs nothing measurable), the L2's word RAMs (-0.87). Yours to cut too.
- **On the board at 70 MHz (the release, Mac OS 7.6.1, RAM 28 MB, the 16-inch monitor, L2 on, eth0):** Speedometer 4.02: CPU 3.816, Disk 1.691, Math 257.2, the Benchmark Mix 14.71, Color 2.160 (8-bit 2.201, 16-bit 2.120), FPU 5.404 (KWhetstones 31,022, Matrix Mult. 0.119 s, Fast Fourier 0.067 s). At 100 MHz: CPU 5.480, Math 369.5, Mix 21.26, Color 2.810, FPU 7.802. The real 7300/120: CPU 7.800, Mix 28.058, FPU 14.329 (`docs/real_7300_speedometer.png`); its MacBench 4: `docs/real_7300_macbench4.png`, `docs/MacBench4_Real_hardware_reference.mar`.
- **Speedometer's FP tests are 68k code under Mac OS's emulator** (SANE): one FP operation between loads and stores, so overlap gains little there (`fpu_pipe_plan.md`, "Whether it pays"). **Measure the FPU's pipeline on native code:** the core bench's microbenchmarks (`fpbench.py` and `divbench.py` were scratch files of the FPU session: rebuild them as `progs.py` programs: dependent and independent fadd/fmul/fmadd chains, lfd-lfd-fmadd loops), and MacBench 4's floating-point test on the board (`games/MacPPC7300/CD3/MacBench 4 CD.toast`, "Mount CD-ROM"; MacBench 5 is there too).
- **Open on the CPU (smaller):** Linux's `isync` on every exception return steps the fold epoch, so the BTB is swept every sixteen exceptions (a speed cost under Linux; the plan's "linux" decision row). Take it if it is quick.
- **The bug of build 33, worth remembering:** every simulation gate was green and the board bombed within minutes: the D-cache took a request it had not granted when a snoop and a request met. **Any change to a cache's or the machine's arbitration runs `run_core.py` (its snoop storm) and then the board with a disk.**

## The gates for every change

- `make -s lint` in `verilator\` (Verilator `-Wall` clean).
- The CPU suites: `python verilator\run_core.py` (15 minutes; record the golden programs' cycle counts: the CPI is the cost of any added stage) and `python verilator\run.py` (the 604's vectors; also `--csv ppctest\runs\results_604_7300_of_run1.csv`).
- `python verilator\run_machine.py --max-instr 300000000 --progress 50000000` (12 minutes): the 7300's ROM in lockstep with dingusppc into Mac OS (Open Firmware waits about 150 M instructions for the chime's DMA: not stuck).
- `python verilator\run_cuda.py`, `run_scsi.py`, `run_enet.py` for machine changes.
- **One WSL job at a time** (two Verilator builds race on /tmp). From PowerShell, never end a bench's pipeline with `Select-Object -First N`.
- A Quartus build (25 minutes) in a `Scratch\` copy: `MacPPC7300.qpf/.qsf/.sdc/.srf`, `MacPPC7300.sv`, `files.qip`, `rtl\`, `sys\`; `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile MacPPC7300` in the background; delete a killed build's `db` and `incremental_db` before the next. Two compiles side by side are fine: never leave Quartus idle. Then `syn\sta_cpupaths.tcl` (and `syn\sta_at100.tcl`).
- The board: Mac OS 7.6.1 and Speedometer's whole run at 70 and at 100 MHz; 9.1 to the Finder now and then; Debian (below) for anything near exceptions, the MMU or interrupts; MacBench 4 for the FPU.

## The board (the user's, shared: ask before taking it)

- **misterkvms-cli** (`C:\Temp\mistercore\misterkvms\target\release\misterkvms-cli.exe`, run from that folder) is how to see and drive it: `screenshot OUT.png` (the capture card; `--native` gives the framework's own picture at the core's size), `key COMBO`, `type TEXT`, `mouse move|click|down|up`, `wait-for-change [--until-still 2s] [--timeout 60s]`, `record 30s OUT.wav|.mp4`. **Chain steps into one command; wait on the screen rather than sleeping; look at a screenshot only where a decision depends on it.**
- `python syn\kvms.py`: `load RBF` (copies to `_Unstable/MacPPC7300_test.rbf` and loads it through the OSD), `click|dclick|move X Y` (finds the Mac's arrow and corrects), `finder`, `off`, `keys`, `shot`. **Cores load through the OSD only** (never `/api/launch`, `mister.py load` or misterkvms's `load-core`).
- `python syn\speedo_kvms.py OUTDIR LABEL`: a whole Speedometer run from a starting Mac (power key or load first), results in `OUTDIR\results.png`, the machine left off. Disk `os761ot.hda` on SCSI 0 (Speedometer at its root).
- **Never reload the core while an OS has a volume mounted.** Mac OS: the power key (PC Menu key, `key app`) then Return; it is off when the capture shows no signal (`kvms.py off`). Debian: switch to tty1 (`key ctrl+win+f1 --hold 300`), `key ctrl+win+delete --hold 300`, wait for "Restarting system" on the serial console, then the OSD's "Reset and close OSD" (two Ups from the top) or load a core. Debian needs RAM 124 MB (28 MB stops 0.5 s into the kernel).
- **OSD options live in the Main's memory until "Save settings"** (System page): loading another build reads `config/MacPPC7300.CFG` again. Change settings only in the OSD (never edit or copy .CFG files). "On reset" options (RAM, CPU speed, monitor) take effect at the OSD's Reset or the power key after a Shut Down.
- SSH (`~/.ssh/mister_only`, root@192.168.99.143) only for files, the serial console and devmem: `syn\uartts.py` (on the board: the console with wall-clock times; one reader at a time), `python syn\mister.py net 10` (the Ethernet rings: frames sent and taken), `mister.py trace` with a `TRACE = 1` build.
- **As left on 2026-10-15:** the release build running as `_Unstable/MacPPC7300_test.rbf` with Debian at its login screen at 70 MHz; slot 0 `linux_debian711.hda`, slot 1 `toolbox.hda`, slot 4 the Mac OS 9.1 CD; RAM 124 MB set for that session only (the saved setting is 28 MB). The disk images are backed up in `games/MacPPC7300/backup_20261015/`.

## Rules

- **Never push** or add a remote (this repository or `..\Main_MiSTer`). **Never change anything under `sys/`.** Don't modify `ppctest\`, the dingusppc or MAME trees, or `..\MacQuadra800_MiSTer` (read only). Never name the earlier speed work's contributor anywhere.
- SystemVerilog that both Verilator 5.020 and Quartus 17.0 accept (`rtl/pll*.v` are plain Verilog: no `int` or `bit`). Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM, byte-enabled writes to a wide array, a variable part-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, RAM style attributes, a three-input add or subtract as one expression, a RAM written from registers with a combinational read. Declare before use. CPU modules are `DSPPC604_*`, machine modules `MacPPC7300_*`.
- Edit files with the editor tools, not scripts, `sed` or heredocs (generated files and copies are the exception). New code: comments short, a line where something is not obvious.
- Commit with explicit paths (never `git add -A`), ending with the co-author line the harness gives. `Scratch\` is git-ignored.
- Never type passwords or other credentials on the board (I type them). Real hardware outranks every emulator; dingusppc first among them.

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04): run WSL from PowerShell (`wsl bash <script in /mnt/c/...>`; Git Bash mangles paths), with `TMPDIR` set to `~/.cache/macppc7300/verilator-tmp`. Python 3.9 on Windows (PIL, numpy). `llvm-objdump-18 --triple=powerpc` in WSL disassembles PowerPC (wrap raw code with `llvm-objcopy-18 -I binary -O elf32-powerpc`).
- Quartus Lite 17.0 (`C:\intelFPGA_lite\17.0\quartus\bin64\`): `quartus_sh`, `quartus_sta`, `qmegawiz` (regenerates IP from a `pll.v`'s wizard settings).
- rb-cli (`C:\Users\spam\AppData\Local\Programs\Rusty Backup\bin\rb-cli.exe`): HFS images (`ls`, `get`, `put`, `locate`; `MSYS_NO_PATHCONV=1` in Git Bash, Windows paths for images). Local copies of some images in `Scratch\disks\`.
- References: dingusppc (`C:\Temp\mistercore\dingusppc`), MAME (`..\mame`), the Quadra 800 core (`..\MacQuadra800_MiSTer`, read only).
