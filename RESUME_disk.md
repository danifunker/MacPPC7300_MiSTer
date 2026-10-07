# Resume prompt: milestone S, the first disk, then on through the machine's plan, independently

(Written 2026-10-07 at the end of the session that built milestones V, video, and K, the ADB keyboard and mouse, in simulation and on the board. It replaces `RESUME_video.md`.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (`docs/DSPPC604_plan.md`). The machine has its own plan, `docs/PPCMac_plan.md`, with the milestones C (Cuda), I (interrupts through Grand Central), T (serial console), E (the empty SCSI buses), V (video), K (ADB), S (SCSI boot), A (sound), P (persistence and the clock), X (the PCI bus, later). C, I (for the VIA), T, E, V and K are done, on the board. This session starts milestone S.

**Work independently.** I am not available to answer questions. Make every decision the documents leave open yourself, the way their rules point, and record it in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. When S is done on the board, go straight on to the next milestone in the plan's order (A, then P) without waiting for me. At the end of each milestone, and before your context runs short, rewrite this prompt for the session after you (the state, the next step, the decisions you took) and commit it. Two things stay as they were: the CPU rule below (a CPU change stops the session), and never pushing (this repository or `..\Main_MiSTer`).

**Test on the board, not in Verilator.** The whole machine simulates at 0.6 MHz (0.9% of real time; Mac OS's screen comes eight minutes in), so I asked (2026-10-07) to keep Verilator to a minimum: prove features on the MiSTer, use unit benches only where they take seconds (`run_cuda.py`, a small bench of a new block), and run the whole machine in Verilator only to explain something the board shows going wrong, briefly.

**Control the board through the MiSTer Remote (mrext, port 8182)**, as my other cores do (`tools\misterdeploy\`, from them; `..\lbmactwo_MiSTer\docs\full_control_MiSTer_through_remote_http.md` documents the API): `python syn\mister.py load | menu | shot OUT.png | keys TEXT | mouse DX DY | click | ws STEP ...` go through it (`/api/launch`, `/api/screenshots`, the websocket's `kbdRaw:`, `text:`, `mouseMove:`, `mouseBtn:`, `kbd:osd` ...). SSH is only for copying files to the card (`put-core`, `put-rom`, `put-nvram`, `rm-nvram`, `cfg`) and the UART (`uart`, `type`). Don't invent other control channels.

**Leave the board as I would find it.** I load the core from the menu myself between sessions. A test NVRAM image left as `games/PPCMac/boot1.rom` stops Mac OS from starting (that happened: I saw no picture). After a test: `rm-nvram`, restore any option changed (`cfg`), and reload the core or the menu.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, how to run everything, the build's size and speed.
- `docs/PPCMac_plan.md`: the milestones with their proofs, the machine's rules (one device port; one way into memory, through the CPU's snoop port; one way into the CPU, through Grand Central; machine-specific things in machine modules; two checks before the board; time by phase accumulation; stubs written down), what the ROM asks for in order, the results so far, the S section (how disks reach the core), the decisions table.
- `docs/PPCMac_stubs.md`: everything the machine stubs, simplifies or leaves out. An entry changes in the same commit as the stub, and leaves only when the real thing is built and tested.
- `docs/DSPPC604_plan.md`: the CPU's rules.
- dingusppc (`C:\Temp\mistercore\dingusppc`, the reference): `devices/common/dbdma.cpp`, `devices/common/scsi/mesh.cpp`, `scsibus.cpp`, `scsihd.cpp`, `scsicommoncmds.cpp`; `devices/ioctrl/grandcentral.cpp` for the DMA channels.
- `..\MacQuadra800_MiSTer` (my Mac Quadra 800 core): how a Mac core takes its disks from Main_MiSTer's Mac SCSI family support, its mount replay and caching.

## Where things stand (2026-10-07)

- The reference ROM is the 7300's (`ppctest\runs\my7300.rom`, 077D.34F2, on the card as `games/PPCMac/boot.rom`); the 7600's (077D.28F2) must keep working.
- **The CPU** (`rtl/DSPPC604/`) is unchanged since 0869a0f. Do not change it: if the machine finds a CPU bug or needs a CPU feature, stop, write a hand-off prompt for a CPU session (`RESUME_cpu.md`), commit it, and stop the session. That is my rule for this project.
- **V, done**: Control, RaDACal, Athens, the 4 MB VRAM in the DDR3 at byte 0x30000000, the scan-out in the 100 MHz memory clock; the OSD's Monitor option (16-inch 832 x 624 by default, 13-inch 640 x 480) and Picture option (Mac or debug readout). Mac OS's grey screen, its pointer and the flashing question-mark disk on the board.
- **K, done**: `rtl/machine/PPCMac_adb.sv`, the keyboard (address 2, handler 2) and mouse (address 3, handler 1) on Cuda's ADB line, timed in Cuda's 4,194,304 Hz ticks, from `hps_io`'s PS/2 keyboard and mouse. `run_cuda.py` has Cuda's firmware talk to them (`verilator/cuda_tb_top.sv`), twenty packets checked, in lockstep with MAME's 6805. On the way: Cuda's PA6 is the ADB line's level (it had been inverted). On the board the pointer follows the Remote's mouse, and Open Firmware takes lines from the Remote's keyboard with `syn\nvram_of_kbd.bin` (`input-device` kbd, output on the modem port).
- **The board**: the committed tree is 26,869 ALMs (64%), 166 RAM blocks, 46 DSP blocks; the CPU's clock closes at 64.81 MHz slow 100 C, run at 65 MHz. Quartus: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac` in the repository, about 15 minutes; run it in the background and wait for the process to end ("Full Compilation was successful").
- **The serial console**: `syn\nvram_of_prompt.bin` as `boot1.rom` stops Open Firmware at its prompt on the modem port; `python syn\mister.py type LINE ...` and `uart S`. Remove it after (see above).
- **Watching a simulation**: `python verilator\run_gui.py` is the same ImGui/SDL window my other cores' Verilator setups have (frames, fps, speed, debug log, the picture). Use it when I should see a simulation, sparingly.
- **`hwprobe/`**: a disk for the real 7300 that I will run; when its results come (`FROM_CARD\`), decode them (`hwprobe.py decode`) and act on them as its README says.

## Milestone S: what to build

The plan's S section has it; in short:

- **DBDMA** (`dbdma.cpp`) as the first bus master, through the CPU's snoop port (rule 2): channel programs from memory (INPUT/OUTPUT MORE and LAST, STORE and LOAD QUAD, NOP, STOP; interrupt, branch and wait conditions; status), MESH's channel and interrupt first.
- **MESH's data phases** on top of E's selection: a hard-disk target (`scsihd.cpp`, the common commands), MESH's DMA commands.
- **The disks through Main_MiSTer's Mac SCSI family support** (decided 2026-10-07 at my request): branch `ppcmac-scsi-family` of `..\Main_MiSTer` (commit 5797d42, worktree `..\Main_MiSTer_ppcmac`; the main checkout stays on my `sun-family` branch, do not switch it) adds `ppcmac` to `is_mac_scsi_family()`. The slot layout (hard disks 0 and 1, the NVRAM's slot 2 for P, the BlueSCSI Toolbox 3, CD-ROM 4, changer 5; `VDNUM` 6), what to take from the Quadra core and the cautions (DDR3 0x1FF00000-0x1FF21000 is Main's Ethernet mailbox; no flush on core reload) are in the plan's S section. Main builds in WSL with `/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin` on PATH. Do not install a new MiSTer binary on the board without my say; until I do, the core must work with the board's present Main (the standard `hps_io` block interface).
- **The proof**: Open Firmware boots one of the repository's Apple partition-map disks from SCSI first (`ppctest`, `cudadump`, `hwprobe` images), then Mac OS from my images (`\\daninas.local\Software\BlueSCSI Images\PowerPC Images`, zipped 512-byte-sector `.hda`; 7.6.1 is the 7300's own system; copy one in, and put it on the card yourself) to the Finder, with the mouse and keyboard. Later Linux (the Debian 7 image there, `HD00_512 LINUX 8500MB.hda.zip`, which starts Mac OS and then BootX), and a CD-ROM target after the hard disk.

## Rules

- SystemVerilog, limited to what Verilator 5.020 and Quartus 17.0 both accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`; it takes the machine's file list from `rtl/machine/PPCMac_machine.qip`, so a new file goes there). Quartus 17 refuses, silently or not: a second read expression on a memory, byte-enabled writes to a wide array, a variable part-select or bit-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, every RAM style attribute, a three-input add or subtract as one expression, a RAM written from registers with a combinational read. Watch for signed constants that overflow (`-7'sd64`): Quartus warns "constant value overflow". In Verilator a size cast of a signed expression inside a function call's argument did not sign-extend as written: write sign extensions out (`{{3{x[6]}}, x}`).
- Machine modules are `PPCMac_*` under `rtl/machine/`. `sys/` is never edited.
- Real hardware outranks every emulator; of the emulators dingusppc is trusted most; where dingusppc is high-level, MAME, then the chips' manuals. Apple's own firmware is evidence too: Cuda's firmware settled PA6 (trace it with `run_cuda.py --trace-from N --trace-count M`, read its bytes at file offset address - 0x0F00 of `rtl/machine/cuda/341s0060.bin`).
- Edit files with the editor tools (Edit, Write), not scripts, `sed` or heredocs. Generated files and files copied whole from my other repositories are the exception.
- Commit at verified points with explicit paths (never `git add -A`), messages through a file (`git commit -F`), ending with the co-author line the harness gives. Never push or add a remote. Do not modify anything under `ppctest\` (another session's; running its tools is fine) or the dingusppc tree. Quartus rewrites a line of `PPCMac.qsf`; leave it out of commits (`git checkout -- PPCMac.qsf`).

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04); `sudo` needs my password, so nothing can be installed. Run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>`; put anything non-trivial in a script file in the scratchpad and run it with `wsl -- bash /mnt/c/.../script.sh`. Build one Verilator bench at a time.
- Quartus Lite 17.0 at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows with `websockets` (for the Remote).
- The MiSTer: 192.168.99.143 (`syn\mister_host`, git-ignored), the Remote on port 8182, key-based SSH (`~/.ssh/mister_only`).
