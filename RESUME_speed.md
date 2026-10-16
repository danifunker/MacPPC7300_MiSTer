# Resume prompt: speed: the FPU's overlap (in progress, uncommitted), the rule-2 timing cuts

(Rewritten 2026-10-16 10:15 in the middle of the FPU overlap work on
`fpu-pipe2`. It is the only resume prompt: everything it needs is here or
in the files it names. The prompt it replaces, of 2026-10-15's end, is in
git's history at 012285f.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

## FIRST: the FPU overlap, half built, in the working tree (uncommitted)

The working tree of `fpu-pipe2` (HEAD 324efea plus 012285f's docs) holds
**uncommitted** changes in `rtl/DSPPC604/DSPPC604.sv`, `DSPPC604_fpu.sv`,
`DSPPC604_pkg.sv`, `verilator/vector_dut.sv`, `verilator/progs.py`,
`verilator/run_core.py`, `syn/DSPPC604_check_fpu.sv` and
`docs/fpu_pipe_plan.md` ("Overlap 1 as built", the design as written).
Do not lose them (`git stash` only if you must, and say so). What they are
and where each stands:

1. **The FPU in two halves** (`DSPPC604_fpu.sv`): `fstate` (front:
   F_IDLE, F_OPND, F_PREA/B/C, F_MUL1, F_ALGN, F_MUL2, F_DIV0, F_DIV, F_RSQ,
   F_SPEC) and `state` (back: S_ADD, S_LZC, S_NORM, S_SHIFT, S_ROUND,
   S_DONE, S_IDLE). The front's copies of the operation's control are
   `f_sgl, f_int, f_div, f_rsq, f_neg, f_rc, f_rn, f_fpscr`, `s_p_f, s_z_f`,
   `e_win_f, sr_f`; the handoff block (`hand_now = back_free & (hand_cmp |
   hand_spec | hand_data)`) copies them into the back's old names and sets
   the back's state; `back_free = idle, or answering this cycle`.
   `resp_valid` is 1 whenever the back holds an answer (no longer gated by
   the request); the requester keeps the order. New outputs: `req_simple`
   (the request presented is a move/select answered in its own cycle: keep
   presenting it, never queue it), `set_out, fr_out, fi_out, fprf_we_out,
   fprf_out` (the FPSCR effects alone, for a commit later). `fpscr_update`
   moved to the package. **Verified: all 25,598 FP vectors pass
   (`python verilator\run.py --only fp`).** The protocol change: a
   requester must withdraw its request once taken (the front is free again
   before the answer) except for `req_simple` ones.
2. **The pipeline side** (`DSPPC604.sv`): `COMPLETION_QUEUE = 1` and a new
   `COMPLETION_ALU = 0` (the ALU admission stays off: it cost 1,100 ALMs and
   5 % of the ROM boot for nothing on 2026-10-11; `run_core.py` now reads
   `COMPLETION_ALU` to decide its overlap tests). The queue entry
   (`completion_t`) has a 64-bit value, a 7-bit rd (bit 6: FPR), `fp, we,
   rc, set, fr, fi, fprf_we, fprf`; `completion_fp_pend` holds the pop
   until the unit's answer; `cq_fpr_y / cq_fpr_o` are bitmaps of the FPRs
   the entries write (younger / older than EX's operation), replacing
   eight compares in EX's stall (`completion_dependency`'s FP terms) and
   in ID's admission (`fpr_busy`); a sim check compares them with
   `completion_fmatch`. Admission `completion_push_fp` (with the FPU
   instantiation): an FPU operation writing a register, not `fp_simple_of`,
   first and last, sequential, MSR[FP], not `fp_trap_on`, EX's operation
   in the unit (`ex_fpu_taken`), `~fq_valid`, sources not `fpr_busy`. The
   issue register `fq_*` requests the unit first (`fpu_req = fq_valid |
   ex_fpu_req`), the order FIFO `fo_*` (4 deep) routes answers
   (`fpu_resp_ex`, `fpu_resp_q`; an answer with the FIFO empty is a
   move's, EX's); a slot's answer is captured into its entry at once; the
   pop commits FPSCR (`cq_fpscr_new`) and CR1 (`cq_cr_new`) in the commit
   block and MEM's trace fields. `fpu_flush = ex_flush | redir`.
   **State: the quick suite passed with the queue parameter still 0
   (`Scratch\run_core_q15.log`); with `COMPLETION_QUEUE = 1` the quick
   suite `Scratch\run_core_q17.log` finished 10:20: every golden, 7300 and
   directed program passes, but the two random FP programs (fprandom seeds
   1 and 2) hang after 28-40 instructions (2 billion cycles: the stuck
   detector did not fire, so something retires or the detector misses a
   stall), the same disease as the microbenchmarks' below, most likely.**
3. **The open bug:** `python verilator\progs.py fpbench OUT KIND` writes
   microbenchmarks (`Scratch\fpbench\{dep,indep,mul,madd,mulchain,lfdmadd}.prog`,
   2,000 operations; run one with the built bench:
   `wsl bash <scratch>/fpbench.sh KIND`, i.e.
   `/home/dani/.cache/macppc7300/verilator/core_ref/core_tb --prog /mnt/c/.../KIND.prog --stall 0`).
   Before the overlap every kind took 5.25 cycles an operation (madd 6.25,
   lfdmadd 3.27 an instruction). With the queue built: **mul 3.27 (the
   overlap works), dep and mulchain 5.25 (dependent, as they must), but
   indep (fadd f3..f6 = f1 + f2) and madd die on the sim check "more FPU
   requests outstanding than the order FIFO holds"** (`fo_count` reaching
   4). A `$display("FPO ...")` trace of takes, answers and admissions is in
   the FIFO's always block (translate_off) to find how: rebuild
   (`run_core.py --quick` rebuilds core_tb) and run indep. Suspects: fadd
   goes through F_ALGN (one front cycle) so the front frees faster than
   fmul's F_MUL1/F_MUL2, and a take may be counted that the unit did not
   make (compare `fpu_take = fpu_req & fpu_ready & ~fpu_req_simple` with
   the unit's `take`), or an answer not popped (`fpu_resp & fpu_resp_ready
   & fo_count != 0`). Remove the trace when done.
4. **Area and timing of the first fit** (`Scratch\q70f1`, the overlap with
   the queue built, before the bitmaps): 37,800 ALMs (90 %, +1,470), the
   CPU clock at -3.49 ns with 20,000+ failing pairs: the forwarding
   selects and `fq_*` through `ex_stall` into the memory unit's and data
   cache's state (the queue's compares came back into EX's stall). The
   bitmaps and `COMPLETION_ALU` gating of the GPR terms were made after
   that fit: refit, and if the queue still costs, shrink it to 4 entries
   (the code hardcodes 8: pointers [2:0], counts 4'd8, loops to 8) or give
   the FP overlap its own one-entry slot instead of the queue.
5. **Then:** `run_core.py` whole, the lockstep (300 M, identical expected:
   the ROM boot has almost no FP), a fit at 70 MHz against `q70c7`
   (10,399 pairs, -2.58, 36,334 ALMs), the microbenchmarks' table into
   `docs/fpu_pipe_plan.md`, the decisions row in `docs/MacPPC7300_plan.md`,
   and the commits: the FPU split (one), the pipeline's admission (one).
   The user approved overlap (1); overlaps (2) and (3) (loads and branches
   behind an FP operation) go to the user with (1)'s measurements first.

## The branch's eleven timing cuts (committed, a08ed6d to f5cd1dd) and what remains

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with my own PowerPC CPU, `DSPPC604` (`rtl/DSPPC604/`), inside a Power Macintosh 7300/7600 machine (`rtl/machine/`). It works: Mac OS 7.6.1 to 9.1 and Debian 7.11 boot on the board. The seventh release is `releases/MacPPC7300_20261015.rbf` (master 7941709): the CPU runs at 70 MHz, or 100 MHz as an overclock (OSD "CPU speed (on reset)"), with a 128 KB L2. The work goes on on the branch **`fpu-pipe2`** (off master 57eba8b; the machine session's commits may land on it too, I sort the branches later). **First finish the FPU overlap left in the working tree (the section above).** Then three things are left of the speed work, in this order (3 is the overlap's continuation):

1. **Close setup timing on the CPU clock at 70 MHz** in Quartus 17.0's slow 1100 mV 100 C model (the only model this project times). The 2026-10-15 CPU session made eleven cuts (commits a08ed6d to f5cd1dd, one each, every one a restructuring inside a cycle, none moving a decision later: the account is `docs/MacPPC7300_plan.md`'s decisions table, row "timing", and `docs/DSPPC604_plan.md` "Cost and speed"). The release's fit had 8,794 failing pairs, -2.47 ns; the branch's fits 7,256 pairs at -2.03 (`Scratch\q70c5`, eight cuts) and 5,506 at -2.71 (`Scratch\q70c6`, nine cuts: one family, a shift by a register's amount with the record bit, forwarded rB through the rotator and the zero into CR0). **The fitter swings a family 0.5-1 ns between fits of the same source** (-2.74, -2.77, -2.13, -2.07, -2.03, -2.71, -2.58 on seven fits of this branch): judge a cut over two fits and by its family's count, never by one fit's worst pair. **What remains needs a cycle (rule 2: my go-ahead, with the cost measured):**
   - the data cache's answer (its address register through the pending store's merge, the word and way choices, the memory unit's byte lanes into wb_result and its readers: -1.4 to -2.2, 900 pairs): a cycle on the answer, `LATE_ANSWER` for the data cache (a parameter: `DSPPC604_cache #(.LATE_ANSWER (0))` in `DSPPC604.sv`), measured 2026-10-06 at 9-14 % of the cycles;
   - the effective address into the MMU's page compares and the data cache's set compare, deciding the caches' and the memory unit's states in the same cycle (-1.2 to -2.2): the address registered before translation, a cycle on every access;
   - CR0 from a forwarded operand through the ALU (compare and record forms; the rotator's is the deepest: -2.0 to -2.7): CR0 written a cycle after the operation leaves EX, a dependent branch waiting a cycle (`cmp; bc` is everywhere: measure before deciding);
   - the machine's paths in the CPU's clock, the machine session's: the data cache's write-back into the L2's write register (seven levels inside `MacPPC7300_l2`, -2.77 in one fit, -1.1 in another, up to 1,700 pairs), Grand Central's read mux (-1.5).
   Measure each candidate's cost in the benches first (the golden programs' cycle counts, the 300 M lockstep's count; `Scratch\run_core_base.log` is the release's `run_core.py` run for the comparison: diff the "pass ... instructions in N cycles" rows by section and name), then put it to me with the numbers.
2. **The board's Speedometer for the branch.** Not yet measured: the run of 2026-10-15 23:29 (`Scratch\speedo_c6`) found `os761.hda` on SCSI 0, not `os761ot.hda`, and the script's blind clicks duplicated every item of that disk's root (16 "... copy" items, 167 MB) before it was stopped; the Mac was shut down cleanly at 23:39, and the cleanup is in progress (below). **Before any Speedometer run: mount `os761ot.hda` on SCSI disk 0 through the OSD** (the OSD's file browser, driven with `misterkvms-cli key` and watched with screenshots) and only then `python syn\speedo_kvms.py OUTDIR LABEL`. The release's numbers at 70 MHz (Mac OS 7.6.1, RAM 28 MB, the 16-inch monitor, L2 on): CPU 3.816, Disk 1.691, Math 257.2, Mix 14.71, Color 2.160, FPU 5.404; the branch's cuts change no cycle (the ROM lockstep 312.13 M cycles against the release's 312.15 M), so the same numbers are expected: the run is the proof that the cuts broke nothing.
3. **Finish the FPU's pipeline.** `docs/fpu_pipe_plan.md` step 1 is done; **step 2, the overlap, was never built**: EX still holds every FP instruction until the FPU answers. Build the overlap there described, in its order: (1) a second, independent FP operation accepted behind the first and committed in order through the completion queue; then (2) cacheable loads behind a pending FP operation; (3) branches behind it. My asking for this is the go-ahead for overlap (1) (FP behind FP inside the completion queue); (2) and (3) change the memory unit's and the branch's hazards: put each to me with its design and what (1) measured first. **Every FPU step keeps the timing the cuts reached** (or its cost is put to me). Measure the FPU's pipeline on native code: the core bench's microbenchmarks (rebuild `fpbench.py` and `divbench.py` as `progs.py` programs: dependent and independent fadd/fmul/fmadd chains, lfd-lfd-fmadd loops) and MacBench 4's floating-point test on the board (`games/MacPPC7300/CD3/MacBench 4 CD.toast`).

**Rule 2 of `docs/DSPPC604_plan.md`:** a change to how a hazard is handled or how state is committed needs my go-ahead, with the rule-free alternative's cost. Cuts that leave the pipeline's behaviour alone need none (the eleven are of that kind). **This is a CPU session:** it may change `rtl/DSPPC604/` and the docs; the machine (`rtl/machine/`, `MacPPC7300.sv`) is another session's, in this same checkout: touch only your own files, `git add` only them. Work independently otherwise: decide what the documents leave open, record each decision in `docs/MacPPC7300_plan.md`'s decisions table ("decided by the session, DATE", with the reason), the CPU's in `docs/DSPPC604_plan.md` and `docs/fpu_pipe_plan.md`, and in the commit message. Commit each verified step. A release: ask me first. Before your context runs short, rewrite this prompt for the next session and commit it.

## Read first (the source of truth; it overrides anything remembered)

- `docs/DSPPC604_plan.md`: the rules ("Rules that keep the pipeline from growing special cases"), "Pipeline shape", M2 (the FPU), M3/M4 (the pipeline, the completion queue), M5 (caches, MMU), "Cost and speed" (the timing pass's method and patterns).
- `docs/MacPPC7300_plan.md`: the decisions table's last rows ("timing": the eleven cuts and what remains; "CPU speed": the switchable PLL).
- `docs/fpu_pipe_plan.md`: step 2's design (the three overlaps, why Speedometer gains little from them).
- `docs/speed_results_20261010.md` to `..._20261012.md`, `docs/speed_profile_20261013.md`: the speed work before (MEM's second slot, the BTB/ITT, branch folding, the 64 KB I-cache); `docs/speed_AT_log.md` (the completion queue).
- `README.md`: "CPU clock", the build table.

## Where things stand (2026-10-15, end of the session)

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
- **As left on 2026-10-16 00:34:** Mac OS 7.6.1 at the Finder on `Scratch\q70c7`'s build (all eleven cuts) loaded as `_Unstable/MacPPC7300_test.rbf`; SCSI 0 `os761.hda`, cleaned (its root back to its 16 items, 299.3 MB; the duplicated version kept beside it as `os761.hda.dup`, 6 GB, for the user to delete), the saved settings (RAM 28 MB, 70 MHz).

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
