# Resume prompt: speed: the FPU's overlap (1) built and committed; its board run, the fit's cost, the rule-2 cuts

(Rewritten 2026-10-16 12:40 at the end of the FPU overlap session on
`fpu-pipe2`. It is the only resume prompt: everything it needs is here or
in the files it names. The prompt it replaces, of 2026-10-16 10:15, is in
git's history at 2fff1c6.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

## FIRST: what the overlap session left (2026-10-16)

Overlap (1) of `docs/fpu_pipe_plan.md` is built, verified and committed on
`fpu-pipe2`: 4435e46 (the FPU in two halves) and 5c1fc34 (the pipeline's
admission of a second FP operation into the completion queue). The account
is `docs/fpu_pipe_plan.md` "Overlap 1 as built" (the design, the two bugs
the random programs found, the microbenchmarks' table, the fits) and the
decisions row "FPU overlap" in `docs/MacPPC7300_plan.md`. Measured:
independent fadd/fmul/fmadd streams 5.25/5.25/6.25 → 3.27 cycles an
operation, the random FP programs -4.5 to -4.9 % cycles, everything else
cycle-identical to the branch before it; `run_core.py` whole, the 25,598
FP vectors, lint and the 300 M lockstep (identical, 312.13 M) pass. The
microbenchmarks: `python verilator\progs.py fpbench Scratch\fpbench\KIND.prog KIND`
(dep, indep, mul, madd, mulchain, lfdmadd), run with the built core bench
(`~/.cache/macppc7300/verilator/core_ref/core_tb --prog ... --stall 0`).

**Left for you, in this order:**

1. **The board, done in part.** The overlap build (`Scratch\q70f3`, the
   committed source; `Scratch\q70f2` the same logic before a timing
   restructuring) boots Mac OS 7.6.1 to the Finder on the board at the
   user's saved 100 MHz / 124 MB (46-50 s to the menu bar; `q70c7` 56 s:
   startup is not slower, the user asked). MacBench 4 (on `os761.hda`'s
   root, run with the "Run Test Suite" button and Return twice, the CD
   tests skipped; the Disk test writes to the disk: cancel it with its
   button): Processor 167, Floating Point 142, against 166 and 143 for
   the core's 2026-10-14 run at 100 MHz (the user's files on that disk's
   root; the real 7300: 271 and 214): MacBench's FP test does not move
   with overlap (1). Speedometer on `os761ot.hda` at 100 MHz
   (`Scratch\speedo_f3`): CPU 5.485, Disk 1.725, Math 369.5, Mix 21.68,
   Color 2.864, FPU 7.871 (KWhetstones 8.890, Matrix Mult 8.534, FFT
   6.187) against the release's 100 MHz run 5.480, 1.737, 369.5, 21.26,
   2.810, 7.802: nothing broke, Mix, Color and FPU up 1-2 %. **The board
   check, done 2026-10-16 afternoon** (`Scratch\board_f3`: screenshots,
   serial logs `deb_uart*.txt`, the SCSI trace `hang85_scsitrace.txt`):
   Debian 7.11 at 100 MHz / 124 MB to the greeter and tty1's login
   prompt, about 25 minutes of serial console over three boots, no oops,
   panic or trap (no login: a password); Ctrl+Option+Delete works only
   from a text console (`ctrl+win+f1` first: Option is the Win key, X
   swallows it); the greeter's power menu, Shutdown, powers the machine
   off ("Power down."). Speedometer at 70 MHz (`Scratch\speedo_f3_70`,
   RAM 124 MB) clean: CPU 3.817, Disk 3.138, Math 256.8, Mix 15.29,
   Color 2.132, FPU 5.510 against the release's 3.816, 1.691, 257.2,
   14.71, 2.160, 5.404 (the Disk figure doubled: unexplained).
   **But startup fails now and then at 100 MHz:** the first boot after
   a core load (the Debian disk's Mac OS 8.5) hung at the Welcome screen
   under an empty white alert box (OSD Reset cured it), and the next
   cold start, Mac OS 9.1, bombed at its Welcome screen with "address
   error" (its Restart then reached the Finder). With the first
   session's grey-desktop hang, three failures in about ten 100 MHz
   boots of `q70f3`; the user also heard a startup chime an octave off
   on one boot and reset it. The 2026-10-12 100 MHz failures looked the
   same (`docs/speed_results_20261012.md`, "Stability at 100 MHz": a
   timing path, cured by a cut). **Next:** count boots at 70 MHz
   against 100 MHz with `q70f3`, and at 100 MHz with `q70c7` (the
   branch without the overlap), before anything else builds on the
   overlap; `syn\sta_at100.tcl` on `q70f3` for the overlap's paths at
   100 MHz.
2. **The fit's cost.** The overlap costs about 960 ALMs (89 %); the CPU
   clock -2.65 ns in `q70f3` against `q70c7`'s -2.58 (the fitter's
   swing), 13,672 failing pairs against 10,399; the first fit (`q70f2`,
   the admission's late enable on the 200-flop issue register) had
   -3.21 and 19,175, cut by loading the register every free cycle. The
   overlap's remaining family: MEM's room through `fpu_resp_ready` into
   the FPU's `back_free` and the handoff's registers (120 pairs, -2.4).
   If the area must come back: the queue at 4 entries (the code
   hardcodes 8: pointers [2:0], counts 4'd8, loops to 8), or a one-entry
   FP slot in place of the queue (the FP admission only ever has one
   entry in flight behind EX's operation, the issue register being
   single); the user's call.
3. **Overlaps (2) and (3), built on the user's go-ahead the same
   afternoon** (`docs/fpu_pipe_plan.md`, "Overlaps 2 and 3 as built";
   the decisions row "FPU overlaps 2 and 3"): an FP operation that
   writes a register leaves EX into a queue entry when the unit takes it
   (`completion_push_ex`), the instructions behind it run in EX, the
   order gate holds their leave, commit, redirect and memory request
   until its pop; the head entry's answer pops it live (`cq_live`), so
   dependent chains keep 5.25 cycles an operation. Measured: the random
   FP programs -2.4 to -2.8 % over overlap (1), nothing else moved;
   `progs.py fpqtest` (branches, a store, an fcmpu, a system call and
   interrupts behind queued FP operations, in lockstep with dingusppc)
   is in `run_core.py`. The early request of loads (overlap 2 proper)
   was built, measured at no gain (the lfd-lfd-fmadd loop stays at 3.27
   cycles an instruction: the load holds EX until the pop) and removed;
   what would pay is loads leaving EX into queue entries of their own
   (64-bit data and the update address per entry, an answer FIFO for
   the memory unit's two descriptors, a fault at the pop refetching):
   written up in full as `docs/enhancement_loads_as_queue_entries.md`
   (the user set it aside on 2026-10-16 evening: "we can bring it up if
   we need to"; the 100 MHz startup failures too, for now). Committed as
   8d794c9; then overlap (1)'s admission from ID (the issue register
   `fq_*`, the younger-writers' bitmap) was removed, since EX's push
   left it only compares and traps-on operations to work behind and the
   fit of 8d794c9 (`Scratch\q70f4`, 37,662 ALMs, -2.73 ns) had it as
   its worst families; without it (`Scratch\q70f5`) 36,952 ALMs
   (88 %), -2.70 ns, 10,847 pairs: `q70c7`'s level, +618 ALMs for the
   whole FPU work; the random FP programs +0.6 %, nothing else moved.
   The fit's memory clock missed by 0.48 ns on the SDRAM controller's
   data-out register (routing; it passed in the other fits): watch it.
   **Not yet on the board** (the
   build of the committed state: `Scratch\q70f5\output_files\MacPPC7300.rbf`):
   Mac OS 7.6.1, the startup-failure count at 100 MHz (and at 70) over
   ten boots against `q70c7`'s, MacBench and Speedometer; an Opus session
   drives the board (the user's wish, 2026-10-16).

## The branch's eleven timing cuts (committed, a08ed6d to f5cd1dd) and what remains

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with my own PowerPC CPU, `DSPPC604` (`rtl/DSPPC604/`), inside a Power Macintosh 7300/7600 machine (`rtl/machine/`). It works: Mac OS 7.6.1 to 9.1 and Debian 7.11 boot on the board. The seventh release is `releases/MacPPC7300_20261015.rbf` (master 7941709): the CPU runs at 70 MHz, or 100 MHz as an overclock (OSD "CPU speed (on reset)"), with a 128 KB L2. The work goes on on the branch **`fpu-pipe2`** (off master 57eba8b; the machine session's commits may land on it too, I sort the branches later). **First the items of the section above (the overlap's board run and its fit's cost).** Then three things are left of the speed work, in this order (3 is the overlap's continuation):

1. **Close setup timing on the CPU clock at 70 MHz** in Quartus 17.0's slow 1100 mV 100 C model (the only model this project times). The 2026-10-15 CPU session made eleven cuts (commits a08ed6d to f5cd1dd, one each, every one a restructuring inside a cycle, none moving a decision later: the account is `docs/MacPPC7300_plan.md`'s decisions table, row "timing", and `docs/DSPPC604_plan.md` "Cost and speed"). The release's fit had 8,794 failing pairs, -2.47 ns; the branch's fits 7,256 pairs at -2.03 (`Scratch\q70c5`, eight cuts) and 5,506 at -2.71 (`Scratch\q70c6`, nine cuts: one family, a shift by a register's amount with the record bit, forwarded rB through the rotator and the zero into CR0). **The fitter swings a family 0.5-1 ns between fits of the same source** (-2.74, -2.77, -2.13, -2.07, -2.03, -2.71, -2.58 on seven fits of this branch): judge a cut over two fits and by its family's count, never by one fit's worst pair. **What remains needs a cycle (rule 2: my go-ahead, with the cost measured):**
   - the data cache's answer (its address register through the pending store's merge, the word and way choices, the memory unit's byte lanes into wb_result and its readers: -1.4 to -2.2, 900 pairs): a cycle on the answer, `LATE_ANSWER` for the data cache (a parameter: `DSPPC604_cache #(.LATE_ANSWER (0))` in `DSPPC604.sv`), measured 2026-10-06 at 9-14 % of the cycles;
   - the effective address into the MMU's page compares and the data cache's set compare, deciding the caches' and the memory unit's states in the same cycle (-1.2 to -2.2): the address registered before translation, a cycle on every access;
   - CR0 from a forwarded operand through the ALU (compare and record forms; the rotator's is the deepest: -2.0 to -2.7): CR0 written a cycle after the operation leaves EX, a dependent branch waiting a cycle (`cmp; bc` is everywhere: measure before deciding);
   - the machine's paths in the CPU's clock, the machine session's: the data cache's write-back into the L2's write register (seven levels inside `MacPPC7300_l2`, -2.77 in one fit, -1.1 in another, up to 1,700 pairs), Grand Central's read mux (-1.5).
   Measure each candidate's cost in the benches first (the golden programs' cycle counts, the 300 M lockstep's count; `Scratch\run_core_base.log` is the release's `run_core.py` run for the comparison: diff the "pass ... instructions in N cycles" rows by section and name), then put it to me with the numbers.
2. **The board's Speedometer for the branch.** Measured at 100 MHz on 2026-10-16 with the overlap (FIRST, item 1: as the release's 100 MHz numbers, Mix, Color and FPU 1-2 % up); not yet at 70 MHz. The run of 2026-10-15 23:29 (`Scratch\speedo_c6`) found `os761.hda` on SCSI 0, not `os761ot.hda`, and the script's blind clicks duplicated every item of that disk's root (16 "... copy" items, 167 MB) before it was stopped; the disk was cleaned (below). **Before any Speedometer run: mount `os761ot.hda` on SCSI disk 0 through the OSD, with the Mac off, and read the entry back** (the OSD's file browser, driven with `misterkvms-cli key` and watched with screenshots) and only then `python syn\speedo_kvms.py OUTDIR LABEL`. The release's numbers at 70 MHz (Mac OS 7.6.1, RAM 28 MB, the 16-inch monitor, L2 on): CPU 3.816, Disk 1.691, Math 257.2, Mix 14.71, Color 2.160, FPU 5.404; the branch's cuts change no cycle (the ROM lockstep 312.13 M cycles against the release's 312.15 M), so the same numbers are expected: the run is the proof that the cuts broke nothing.
3. **Finish the FPU's pipeline.** `docs/fpu_pipe_plan.md` step 1 is done; **step 2, the overlap, was never built**: EX still holds every FP instruction until the FPU answers. Build the overlap there described, in its order: (1) a second, independent FP operation accepted behind the first and committed in order through the completion queue; then (2) cacheable loads behind a pending FP operation; (3) branches behind it. My asking for this is the go-ahead for overlap (1) (FP behind FP inside the completion queue); (2) and (3) change the memory unit's and the branch's hazards: put each to me with its design and what (1) measured first. **Every FPU step keeps the timing the cuts reached** (or its cost is put to me). Measure the FPU's pipeline on native code: the core bench's microbenchmarks (rebuild `fpbench.py` and `divbench.py` as `progs.py` programs: dependent and independent fadd/fmul/fmadd chains, lfd-lfd-fmadd loops) and MacBench 4's floating-point test on the board (`games/MacPPC7300/CD3/MacBench 4 CD.toast`).

**Rule 2 of `docs/DSPPC604_plan.md`:** a change to how a hazard is handled or how state is committed needs my go-ahead, with the rule-free alternative's cost. Cuts that leave the pipeline's behaviour alone need none (the eleven are of that kind). **This is a CPU session:** it may change `rtl/DSPPC604/` and the docs; the machine (`rtl/machine/`, `MacPPC7300.sv`) is another session's, in this same checkout: touch only your own files, `git add` only them. Work independently otherwise: decide what the documents leave open, record each decision in `docs/MacPPC7300_plan.md`'s decisions table ("decided by the session, DATE", with the reason), the CPU's in `docs/DSPPC604_plan.md` and `docs/fpu_pipe_plan.md`, and in the commit message. Commit each verified step. A release: ask me first. Before your context runs short, rewrite this prompt for the next session and commit it.

## Read first (the source of truth; it overrides anything remembered)

- `docs/DSPPC604_plan.md`: the rules ("Rules that keep the pipeline from growing special cases"), "Pipeline shape", M2 (the FPU), M3/M4 (the pipeline, the completion queue), M5 (caches, MMU), "Cost and speed" (the timing pass's method and patterns).
- `docs/MacPPC7300_plan.md`: the decisions table's last rows ("timing": the eleven cuts and what remains; "CPU speed": the switchable PLL).
- `docs/fpu_pipe_plan.md`: step 2's design (the three overlaps, why Speedometer gains little from them).
- `docs/speed_results_20261010.md` to `..._20261012.md`, `docs/speed_profile_20261013.md`: the speed work before (MEM's second slot, the BTB/ITT, branch folding, the 64 KB I-cache); `docs/speed_AT_log.md` (the completion queue).
- `README.md`: "CPU clock", the build table.

## Where things stand (2026-10-16, after the overlap session; the overlap's fits and board runs are in FIRST)

- **The branch's fits:** `Scratch\q70c5` (commits through bc7b481: 7,256 pairs, -2.03 ns), `Scratch\q70c6` (through 38f7631: 5,506 pairs, -2.71 ns, 36,524 ALMs, 87 %; its `output_files\MacPPC7300.rbf` ran Mac OS 7.6.1 to the Finder on the board), `Scratch\q70c7` (all eleven: 10,399 pairs, -2.58 ns, 36,334 ALMs; the forwarded address into the memory unit's state first, then CR0, the data cache's word, Grand Central's read mux with 2,199 pairs at -1.96). The release's: `Scratch\qsw2` (8,794 pairs, -2.47). Each has `cpupaths.txt`; `syn\cpupaths_families.py FILE N` groups the pairs by source and endpoint family, `syn\sta_pathsum.py detail.txt` prints a `report_timing -detail full_path` report's cells and arrival times (see `Scratch\q70c6\detail6.tcl` for the form: `report_timing -setup -to_clock $clk -to [get_keepers {*DSPPC604:cpu|cr[*}] -npaths 2 -detail full_path -pairs_only -file detail.txt`).
- **The PLL is reconfigurable** (`rtl/pll/pll_0002.v`: a 700 MHz VCO, the CPU's counter C1 dividing by 10, the memory clock's C2 by 7). `MacPPC7300.sv` keeps `CPU_MHZ = 70`: **the build is timed at 70**, and the OSD's 100 MHz rewrites C1 to 7 through `sys/pll_cfg` under reset. Never set `CPU_MHZ = 100`. The CPU clock's name in a timing report: `emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk` (builds before the reconfigurable PLL: `general[1].gpll~PLL_OUTPUT_COUNTER|divclk`); `syn\sta_cpupaths.tcl` writes every failing pair to `cpupaths.txt` in a build's directory (`quartus_sta.exe -t <repo>\syn\sta_cpupaths.tcl`, 3 minutes); `syn\sta_at100.tcl` sees the placement at 100 MHz.
- **The disk cleanup, done:** `os761.hda` (6 GB, the user's Mac OS 7.6.1 disk with MacBench) was copied from the board (`Scratch\disks\os761_board.hda`), the 16 duplicates removed (`rb-cli rm -r IMAGE "/* copy"` from Git Bash with `MSYS_NO_PATHCONV=1`), `rb-cli fsck` clean (679 files, 74 directories), copied back as `os761.hda.new` (md5 c879cc26...), swapped in, the core reloaded, and the Finder shows the root as it was. The duplicated version stays as `os761.hda.dup` until the user deletes it.
- **Open on the CPU (smaller):** Linux's `isync` on every exception return steps the fold epoch, so the BTB is swept every sixteen exceptions (a speed cost under Linux; the plan's "linux" decision row). Take it if it is quick.
- **The bug of build 33, worth remembering:** every simulation gate was green and the board bombed within minutes: the D-cache took a request it had not granted when a snoop and a request met. **Any change to a cache's or the machine's arbitration runs `run_core.py` (its snoop storm) and then the board with a disk.**

## The gates for every change

- `make -s lint` in `verilator\` (Verilator `-Wall` clean). From Windows run WSL through a script file (`wsl bash /mnt/c/.../lint.sh` with `TMPDIR=$HOME/.cache/macppc7300/verilator-tmp` exported inside it): a `bash -c` string from PowerShell loses its `$` variables.
- The CPU suites: `python verilator\run_core.py` (15 minutes; `--quick` 4 minutes for a first look; record the golden programs' cycle counts: the CPI is the cost of any added stage) and `python verilator\run.py` (the 604's vectors; also `--csv ppctest\runs\results_604_7300_of_run1.csv`).
- `python verilator\run_machine.py --max-instr 300000000 --progress 50000000` (12 minutes): the 7300's ROM in lockstep with dingusppc into Mac OS (identical; 312.13 M cycles on the branch).
- `python verilator\run_cuda.py`, `run_scsi.py`, `run_enet.py` for machine changes.
- **One WSL job at a time** (two Verilator builds race on /tmp; Verilator 5.020 also dies now and then with "attempted to destroy locked Thread Pool": run it again). From PowerShell, never end a bench's pipeline with `Select-Object -First N`.
- A Quartus build (25 minutes) in a `Scratch\` copy: `MacPPC7300.qpf/.qsf/.sdc/.srf`, `MacPPC7300.sv`, `files.qip`, `rtl\`, `sys\`, `build_id.v`; `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile MacPPC7300` in the background; the `.rbf` lands in `output_files\`. Two compiles side by side are fine: never leave Quartus idle. Then `syn\sta_cpupaths.tcl`.
- The board: Mac OS 7.6.1 and Speedometer's whole run at 70 and at 100 MHz; 9.1 to the Finder now and then; Debian for anything near exceptions, the MMU or interrupts; MacBench 4 for the FPU.

## The board (the user's: it said on 2026-10-15 that this work may take it whenever it wants)

- **misterkvms-cli** (`C:\Temp\mistercore\misterkvms\target\release\misterkvms-cli.exe`, run from that folder) sees and drives it: `screenshot OUT.png` (the capture card; `--native` the framework's own picture at the core's size), `key COMBO` (`app` is the Mac's power key: the shutdown dialog, then `enter`), `type TEXT`, `mouse move|click|down|up` (in the capture's frame, not the Mac's: use `syn\kvms.py move|click X Y`, which finds the Mac's arrow and corrects), `wait-for-change`, `record`. **Mac OS 7's menus drop only while the button is held**: `kvms.py move` onto the title, `misterkvms-cli mouse down left`, a screenshot, `kvms.py move` onto the item, `mouse up left`.
- `python syn\kvms.py`: `load RBF` (copies to `_Unstable/MacPPC7300_test.rbf` and loads it through the OSD), `click|dclick|move X Y`, `finder`, `off [SECONDS]` (waits for no signal), `keys`, `shot OUT.png`. **Cores load through the OSD only.**
- `python syn\speedo_kvms.py OUTDIR LABEL`: a whole Speedometer run from a starting Mac, **only with `os761ot.hda` on SCSI 0** (see above). It types and clicks blindly: with another disk it does damage.
- **Never reload the core while an OS has a volume mounted.** Mac OS: the power key, then Return; it is off when `kvms.py off` says so. Debian: `key ctrl+win+f1 --hold 300`, `key ctrl+win+delete --hold 300`, "Restarting system" on the serial console, then the OSD. Debian needs RAM 124 MB.
- **OSD options live in the Main's memory until "Save settings"**; change settings only in the OSD (never edit or copy .CFG files). "On reset" options take effect at the OSD's Reset or the power key after a Shut Down.
- SSH (`~/.ssh/mister_only`, root@192.168.99.143) only for files, the serial console and devmem.
- **As left on 2026-10-16 (the overlap session):** `Scratch\q70f3`'s build loaded as `_Unstable/MacPPC7300_test.rbf`, SCSI 0 `os761ot.hda` (Speedometer's disk; the user's `os761.hda`, cleaned on 2026-10-16 00:34 with the duplicated version kept beside it as `os761.hda.dup`, 6 GB, for the user to delete, was on SCSI 0 before and is what the user boots), the user's saved settings 100 MHz and RAM 124 MB (changed by the user from 70 MHz / 28 MB since 2026-10-15). After Speedometer the Mac was shut down by the script and `os761.hda` put back on SCSI 0 through the OSD, the machine left off.
- **`kvms.py load` has no guard:** on 2026-10-16 `kvms.py off` timed out ("FAIL: no off", the Mac still at a grey screen after the Finder had quit) and the load that followed in the same command went ahead over it. Chain `off` and `load` only with the exit code checked (`&&` in Bash, `if ($LASTEXITCODE -eq 0)` in PowerShell), or run them apart. The disk booted and showed no damage afterwards.

## Rules

- **Never push** or add a remote. **Never change anything under `sys/`.** Don't modify `ppctest\`, the dingusppc or MAME trees, or `..\MacQuadra800_MiSTer` (read only). Never name the earlier speed work's contributor anywhere.
- SystemVerilog that both Verilator 5.020 and Quartus 17.0 accept (`rtl/pll*.v` plain Verilog). Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM, byte-enabled writes to a wide array, a variable part-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, a three-input add or subtract as one expression, a RAM written from registers with a combinational read. `(* ramstyle = "logic" *)` and `"no_rw_check"` are accepted. Declare before use. CPU modules are `DSPPC604_*`, machine modules `MacPPC7300_*`.
- Edit files with the editor tools, not scripts, `sed` or heredocs (generated files and copies are the exception). New code: comments short, a line where something is not obvious.
- Commit with explicit paths (never `git add -A`), ending with the co-author line the harness gives. `Scratch\` is git-ignored.
- Never type passwords or other credentials on the board. Real hardware outranks every emulator; dingusppc first among them.

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04). Python 3.9 on Windows (PIL, numpy). `llvm-objdump-18 --triple=powerpc` in WSL disassembles PowerPC.
- Quartus Lite 17.0 (`C:\intelFPGA_lite\17.0\quartus\bin64\`): `quartus_sh`, `quartus_sta`, `qmegawiz`.
- rb-cli (`C:\Users\spam\AppData\Local\Programs\Rusty Backup\bin\rb-cli.exe`): HFS images (`ls`, `get`, `put`, `rm`, `fsck`, `locate`; `MSYS_NO_PATHCONV=1` in Git Bash, Windows paths for images). Local copies of some images in `Scratch\disks\`.
- References: dingusppc (`C:\Temp\mistercore\dingusppc`), MAME (`..\mame`), the Quadra 800 core (`..\MacQuadra800_MiSTer`, read only).
