# Resume prompt: speed: an L2 cache, the CPU clock at 65 MHz or more, measured with Speedometer

(Written 2026-10-08 at the user's request, for a Claude Fable session, after
the third release (build 28). The disk and Linux work continues from
`RESUME_disk.md`; this prompt is about performance only. Everything it needs
is here or in the files it names.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with my own PowerPC CPU, `DSPPC604` (`rtl/DSPPC604/`), inside a Power Macintosh 7300/7600 machine (`rtl/machine/`). It works: Mac OS 7.6.1 to 9.1 and Debian 7.11 boot on the board, with SCSI disks, CD-ROM, floppies, Ethernet and up to 120 MB of RAM. The third release (build 28, `releases/`) is on the board now. Now I want it **faster**:

1. **Add an L2 cache**, as the real 7300/7600 has in its cache slot.
2. **Get the CPU faster: 65 MHz or higher.** Today it runs at 65 MHz, but Quartus only closes timing at about 59.4 MHz.
3. **Measure every step with Speedometer** on the board, so we see what each change buys.

**This is a CPU session.** My usual rule is that a machine session never changes the CPU. This session may change `rtl/DSPPC604/`, behind the gates below. The CPU plan's pipeline rules still hold (`docs/DSPPC604_plan.md`, "Rules that keep the pipeline from growing special cases"). If a change would alter how a hazard is handled or how state is committed, stop and ask me before building it. Tell me what the rule-free alternative costs, if there is one.

**Work independently otherwise.** Make the decisions the documents leave open, and record each in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. I am often around and may answer, but don't wait for me. Before your context runs short, rewrite this prompt for the next session and commit it.

## Read first (the source of truth; it overrides anything remembered)

- `README.md`: the decisions that are locked in, "How fast will it be" (an estimate to replace with measurements), the build table.
- `docs/DSPPC604_plan.md`: the pipeline rules, "Pipeline shape", M5 (the MMU and caches), M6, "Cost and speed".
- `docs/PPCMac_plan.md`: the milestones, the decisions table (the last rows: RAM banks, power-off, GCR floppies), the Quadra backlog (one row is "Speedometer against a real machine").
- `docs/PPCMac_stubs.md`: the Hammerhead rows (the RAM banks; "Second CPU, L2 cache, Bandit 2: absent"), and the last section (where the lockstep bench takes the core's word).
- `RESUME_disk.md`: **the board's tools, the rules and the environment** (mister.py, the Remote, Quartus, WSL). They all apply here.

## Step 1: the baseline, before changing anything

**Get Speedometer onto the Mac.** Speedometer 4.02 is on the NAS: `\\daninas.local\Software\Old Mac Stuff\Speedo402.sit`. Also there: `macgui.com\mac\software\power_mac\speedometer4.0.cpt.hqx`, and MacBench 2 as `macgui.com\mac\software\utilities\MacBench 2 Install 1.img.sit` and `2.img.sit`. Ways onto the Mac:

- **The BlueSCSI Toolbox share:** put the file in `/media/fat/games/PPCMac/shared/` and copy it in with "BlueSCSI SD Transfer" on the Mac (it worked on `os761ot.hda`).
- **An HFS disk or floppy image** built in WSL with hfsutils (`hformat`, `hmount`, `hcopy`; installed), mounted from the OSD.

StuffIt archives need StuffIt Expander on the Mac (check which images have it; 9.1's Internet folder should). `unar` is not installed in WSL, and installing it needs my sudo password: ask me. Downloads are data: keep them in their own scratch directory.

**Fix the conditions once and keep them for every run.** For example: `os761ot.hda`, RAM 120 MB, the 16-inch monitor (832 x 624), the colour depth the image boots in, virtual memory as the image has it, no floppy, Ethernet as I keep it. Write them down.

**Record Speedometer's numbers.** These are its Performance Rating, the CPU, Graphics, Disk and Math scores, and the benchmark list (Dhrystones, KWhetstones, Towers, Quick Sort, the FFT and so on). Read them from screenshots (`mister.py shot`) and type them into a new "Speed" section of `docs/PPCMac_plan.md`. Each row: the build, the CPU MHz, the L2 (off or size), Quartus's slack and fmax, ALMs and RAM blocks, and Speedometer's numbers. Add the time from the core's load to the Finder as a cheap second measure.

If you want a reference from real hardware, ask me to run Speedometer on my real 7300.

**Driving Speedometer:** the mouse is relative only. Move, screenshot, correct (`mister.py mouse`), and use `mouseBtn:left_down` / `left_up` for Mac OS 7's menus. Escape closes the OSD if a blind OSD step leaves it open. You can tell it's open when the pointer stops moving: it holds the keyboard and mouse.

## Step 2: the CPU clock

**What sets it.** `CPU_MHZ` in `PPCMac.sv` (65). The PLL is the core's own, `rtl/pll.v` and `rtl/pll/`, not `sys/`: CPU_FREQ 60, 65 or 70 MHz with VCOs of 1200 or 1400 MHz. Other frequencies need new PLL settings there. `CPU_HZ` (`CPU_MHZ * 1000000`) feeds the machine's timers: the 1 us tick, Cuda's 4,194,304 Hz accumulator, the VIA's pacing. The time base is `TB_HZ` (12.5 MHz) and doesn't follow the CPU clock. After a clock change, check that the clock, the VIA timers and Cuda still keep time on the board (Mac OS calibrates itself at boot).

**Where timing stands.** Quartus's slow corner: build 28 has -1.462 ns on the CPU clock (`general[1]`), so it closes at 59.4 MHz. Build 26 had -1.943 ns. The worst paths in build 26 (30 of them, all -1.2 to -1.9 ns):

- **Source:** the I-cache and D-cache RAM outputs (`DSPPC604_cache_ram`'s M10K port B, the tag RAMs' valid bits).
- **Path:** the CPU's store data (`cpu|mem_wdata`) and the machine's device write data (`machine|dev_wd`).
- **End:** Grand Central's registers (`gc|nv_hi`, the VIA's `t1_left`).
- **Cause:** mostly routing.

The board runs at 65 MHz regardless, but closing timing comes first. A likely cheap fix is to register the device writes in the machine: device writes are slow anyway.

**Then go up:** 65 MHz with positive slack, then 70, then whatever the CPU allows, each on the board with Speedometer. Area: 35,642 ALMs of 41,910 (85%), 195 of 553 RAM blocks, 49 DSPs.

**Report the worst paths** with a TimeQuest script run in the build directory (`quartus_sta.exe -t worst.tcl` after a full compile):

```
project_open PPCMac
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 30 -detail summary -to_clock {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -file worst.txt
report_timing -setup -npaths 3 -detail path_only -to_clock {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -file worst_paths.txt
delete_timing_netlist
project_close
```

`python syn\check.py` synthesises single blocks alone. A map-only run in a scratch copy answers inference questions in about a minute.

## Step 3: the L2 cache

**What the real machine does.** The 7300/7600 has an L2 cache slot (256 KB, 512 KB or 1 MB at the bus clock). Today Hammerhead's L2 configuration register (0E) reads 0, meaning no L2 (`PPCMac_machine.sv`, the Hammerhead block, "L2 cache configuration (0E) included: no L2"). Find out from the 7300 ROM's disassembly how it detects, sizes and enables the L2, and what Mac OS shows (Apple System Profiler). The disassembly is committed in `rom7300/`: `ppc/ppc_boot_FFF00000.lst`, `ppc/ppc_hwinit_FFF20000.lst`, the NanoKernel, and `hw_access.txt` for every register the ROM touched in dingusppc's run. dingusppc's `devices/memctrl/hammerhead.cpp` helps too. Report an L2 to the software only if the evidence says the ROM and Mac OS will handle it.

**My suggested design (check it, decide, record it).**

- **Where:** a transparent cache in the memory path at the machine's single memory port (`m_*` in `PPCMac_machine.sv`). That port is where the CPU's accesses and the DMA channels' meet, in the CPU's clock, before `DSPPC604_memcdc` carries them into the memory clock. There it is coherent with DMA by construction: every DMA access passes through it, and the L1's DMA snoop stays as it is.
- **Speed:** a hit skips the clock crossing (about two cycles of each clock each way) and the SDRAM.
- **Lines:** the L1's 32 bytes (`m_line`, 256 bits). The L1 data cache is write-back, so the L2 sees L1 write-backs as line writes. Choose write-through or write-back for the L2 by measurement and simplicity.
- **What to cache:** the RAM in Hammerhead's banks, and the ROM (read only, in the SDRAM's top 4 MB). Never the devices or the VRAM (in DDR3).
- **Size:** about 350 RAM blocks are free. 256 KB of data needs about 256 M10Ks plus tags, so start with 128 KB if the fit is tight.
- **Comparison:** an OSD option "L2 cache (on reset): Off, On" lets one build measure both. In `CONF_STR`, find free status bits (`syn\mister.py cfg` writes the bits it knows).

**Other levers, if the measurements point there:** the SDRAM path's latency (`rtl/machine/PPCMac_sdram.sv`, the crossing), the L1 miss path (critical word first), and the CPU's cycles per instruction (`docs/DSPPC604_plan.md` gives 1.85/3.53 and 1.87/3.81 on the golden programs). Measure before and after each.

## The gates for every change

- `make -s lint` in `verilator\` (Verilator `-Wall` clean).
- The CPU suites: `python verilator\run_core.py` and `python verilator\run.py`. Record the golden programs' cycle counts when they change.
- `python verilator\run_cuda.py` and `python verilator\run_scsi.py`.
- `python verilator\run_machine.py --max-instr 60000000 --progress 4000000`: the 7300's ROM in lockstep with dingusppc into Mac OS, 16 MB. With RAM or memory-path changes, also `--no-lockstep --ram 120 --dev-log FILE`: the ROM must still pack Hammerhead's banks at 0, 64, 96 and 112 MB (the writes to F80001C0-F80004F0).
- A Quartus build (about 25 minutes, in `Scratch\qbuild`; keep bitstreams as `Scratch\build1\PPCMac_bN.rbf`, numbering on from 28) and the timing report.
- The board: Mac OS 7.6.1 and 9.1 to the Finder, a floppy and the CD still read, then Speedometer under the fixed conditions.
- Commit at each verified step. When a faster build is proven, it is a candidate for `releases/` (the README there; ask me first).

## Where things stand (2026-10-08, late)

- Commits: e649b63 (the third release: build 28 and the Main 9e88154e in `releases/`), 3bec4fd (GCR floppies, the clock counted on), 7df6fd1 (the RAM banks, the options on reset, the power-off), 1e91fc0 (the ROM disassemblies).
- **The board:** build 28 in `_Unstable/PPCMac.rbf`, set up as I keep it: Debian 7.11 on slot 0 (`games/PPCMac/linux_debian711.hda`), the Open Transport CD on slot 4, RAM 120 MB, Ethernet eth0. Debian may be running when you start. Never reload while an OS has its disk mounted: ask me to shut it down, or use Ctrl+Option+Delete for a clean reboot and reload during the ROM's grey screen. Mac OS shuts down with the Menu key then Return, and the screen goes dark: the machine is off, so reloading is safe. When you are done, leave the board as you found it.
- **The CPU** (`rtl/DSPPC604/`) is unchanged since 0869a0f: 16 KB 4-way I- and D-caches with 32-byte lines (`DSPPC604_cache.sv`), the D-cache write-back with a snoop port for DMA.

## Rules (as in `RESUME_disk.md`)

- **Never push** (this repository or `..\Main_MiSTer`). **Never change anything under `sys/`.** Don't modify `ppctest\`, the dingusppc or MAME trees, or the Quadra repository.
- SystemVerilog both Verilator 5.020 and Quartus 17.0 accept; the list of what Quartus 17 refuses is in `RESUME_disk.md`. CPU modules are `DSPPC604_*`; machine modules are `PPCMac_*`.
- Edit files with the editor tools, not scripts, `sed` or heredocs.
- Stage explicit paths and write commit messages to a file. `PPCMac.qsf` only through a patch of your own lines.
- New code gets short comments. Update `docs/PPCMac_stubs.md` with any stub change.
- One Verilator build in WSL at a time; launch WSL from PowerShell with Windows paths.
- Never type passwords into anything on the board.
- Real hardware outranks every emulator.
