# Resume prompt: milestone S, the disks: from "Welcome to Mac OS" to the Finder, then on through the machine's plan, independently

(Written 2026-10-07, at the end of the session that built milestone S's
machinery and fixed the pointer's trails. It replaces the earlier
`RESUME_disk.md`.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (`docs/DSPPC604_plan.md`). The machine has its own plan, `docs/PPCMac_plan.md`, with the milestones C (Cuda), I (interrupts through Grand Central), T (serial console), E (the empty SCSI buses), V (video), K (ADB), S (SCSI boot), A (sound), P (persistence and the clock), X (the PCI bus, later). C, I (for the VIA), T, E, V and K are done, on the board. S is under way: Mac OS 7.6.1 boots from the SD card's image on the board to "Welcome to Mac OS" and stops with a bus error. This session finishes S.

**Work independently.** I am not available to answer questions. Make every decision the documents leave open yourself, the way their rules point, and record it in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. When S is done on the board, go straight on to the next milestone in the plan's order (A, then P) without waiting for me. At the end of each milestone, and before your context runs short, rewrite this prompt for the session after you (the state, the next step, the decisions you took) and commit it. Two things stay as they were: the CPU rule below (a CPU change stops the session), and never pushing (this repository or `..\Main_MiSTer`).

**Test on the board, not in Verilator.** The whole machine simulates at about 400,000 instructions a second in lockstep (Mac OS's disk boot reaches its first block at 318 million instructions, 13 minutes; the happy Mac at 452 million). Prove features on the MiSTer; use unit benches where they take seconds (`run_scsi.py`, `run_cuda.py`), and whole-machine runs to explain what the board shows going wrong. The whole-machine lockstep run is worth it for S's remaining fault, below: it compares the CPU with dingusppc's after every instruction and mirrors DMA writes into the reference's RAM, so a coherence slip in the DMA path stops it at the instruction.

**Control the board through the MiSTer Remote (mrext, port 8182)**, as my other cores do (`tools\misterdeploy\`; `..\lbmactwo_MiSTer\docs\full_control_MiSTer_through_remote_http.md` documents the API): `python syn\mister.py load | menu | shot OUT.png | keys TEXT | mouse DX DY | click | ws STEP ...`. SSH only copies files (`put-core`, `put-rom`, `put-nvram`, `rm-nvram`, `put-disk`, `mount`, `umount`, `cfg`) and reads the UART (`uart`, `type`). The `ws` steps' `sleep:` is in seconds. Don't invent other control channels.

**Leave the board as I would find it.** I load the core from the menu myself. After a test: `rm-nvram` if an NVRAM image was put there, restore options (`cfg` with no arguments is the default: 16 MB, ROM, UART modem port, picture Mac, 16-inch), and load the menu. A disk image mounted as SCSI disk 0 (`config/PPCMac.s0`) may stay: say in the commit which one.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, how to run everything (the SCSI bench and the new machine bench options are described there), the build's size and speed.
- `docs/PPCMac_plan.md`: the milestones and their proofs, the machine's rules, the S section ("What Mac OS asks of the disk", "Built"), the V section's note on the pointer's trails, the decisions table (the S row).
- `docs/PPCMac_stubs.md`: everything the machine stubs, simplifies or leaves out (MESH, the disks, DBDMA, the DMA port's remaining window, the physical mouse).
- `docs/DSPPC604_plan.md`: the CPU's rules.
- dingusppc (`C:\Temp\mistercore\dingusppc`, the reference): `devices/common/dbdma.cpp`, `devices/common/scsi/mesh.cpp`, `scsibusctrl.cpp`, `scsihd.cpp`; Linux's `drivers/scsi/mesh.c` (fetched from GitHub when needed) for how MESH is really driven.

## Where things stand (2026-10-07, commits 2414696, 6407e7d)

- **The CPU** (`rtl/DSPPC604/`) is unchanged since 0869a0f. Do not change it: if the machine finds a CPU bug or needs a CPU feature, stop, write `RESUME_cpu.md` for a CPU session, commit it, and stop. One candidate is noted in the stubs list (the DMA window: caches that held off fills while a snoop is pending would close it); do not act on it.
- **The pointer's trails (fixed, 2414696).** Mac OS maps the frame buffer cacheable and write-through and draws the pointer itself; the CPU's cache asks for a line with the missing word's address and `PPCMac_video` started the DDR3 burst there. Now from the line's start; the lockstep run with `--vram-check` and mouse moves reads back every byte as written.
- **S, built and verified as far as it goes:**
  - `PPCMac_dbdma.sv` (MESH's DBDMA channel A in `PPCMac_gc`), the DMA port in `PPCMac_machine` (snoop, memory before any new CPU access, a second snoop after a write: holding CPU reads during the snoop deadlocked the board), `PPCMac_mesh.sv` (bus at the signal level, FIFO, information phases, DMA in and out; ACK held after a message byte and after a status byte), `PPCMac_scsidisk.sv` (IDs 0 and 1, hps_io slots 0 and 1, a 10 us phase-change delay), `PPCMac.sv` (hps_io `VDNUM` 6, OSD `SC0`/`SC1`, the disk light).
  - `python verilator\run_scsi.py`: the ROM's and Mac OS's register sequences (PIO and DMA reads, DMA writes, INQUIRY, READ CAPACITY, an absent ID): passes.
  - Lockstep whole machine with the 7.6.1 image (before the ACK-after-status change): the ROM reads blocks 0-3 and the driver (64-82) by PIO at 317.6 million instructions, the driver's DMA reads follow, Mac OS writes block 98 at 431 million (where dingusppc hangs: it has no MESH DMA out), the happy Mac at 452 million, all in lockstep; then the SIM hung waiting for REQ to drop after a status byte (460 million), which the ACK-after-status change (6407e7d) addresses.
  - On the board (the build before 6407e7d): Mac OS 7.6.1 boots from `games/PPCMac/os761.hda` to "Welcome to Mac OS" and stops with "Sorry, a system error occurred. bus error", with the 7300's and with the 7600's ROM alike, and with Shift held (no "Extensions Off": it comes before extensions load). You have seen this error sometimes on the physical 7600. Mac OS 9.1 (`games/PPCMac/os91.hda`, whose driver partition is newer, 36 blocks at block 59) stays on the grey screen with the CPU in the SCSI Manager and Mac OS's idle loops: never reaches its welcome screen.
- **Left running at the end of the session** (gone with it; redo them): a Quartus build of 6407e7d (`output_files\PPCMac.rbf` if it finished) and the lockstep disk boot on 6407e7d to 2 billion instructions.
- **The board's state**: `_Unstable/PPCMac.rbf` is the build before 6407e7d; `games/PPCMac/boot.rom` the 7300's ROM (md5 edcf3422...); `os761.hda` and `os91.hda` on the card; `config/PPCMac.s0` names whichever image the session left mounted (see its last commit).
- **Physical mouse**: you reported that your physical USB mouse on the MiSTer did not move the pointer while the Remote's did. Both reach the core through the same hps_io packet and small moves through the Remote work, so the physical mouse's events seem not to reach the core (the Main drops mouse input while the OSD is open). Not solved; check in another core first.
- **The board build**: about 29,000 ALMs (69 %), 168 RAM blocks; the CPU's clock closes at 64-64.2 MHz slow 100 C (slack -0.8 to -1.0 ns), run at 65. Quartus: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac` in the repository, about 15 minutes in the background.

## The next steps

1. Put a build of 6407e7d on the board (`put-core`, `mount 0 games/PPCMac/os761.hda`, `load`, wait 40 s, `shot`). Does 7.6.1 now get past "Welcome to Mac OS"? If not, the debug readout over the UART (`cfg --uart debug`, reload, `uart 3 --baud 115200`: row 0 the pc, 4 the MSR, 6 status with bit 28 "stuck", 12 device writes) shows where the CPU is.
2. Run the lockstep disk boot to the bus error and find its cause:
   `python verilator\run_machine.py --monitor 16 --disk0 Scratch\disks\os761.hda --disk-log --max-instr 2000000000 --progress 10000000 --frame-at 300000000 --frame-every 50000000 --frame-out f%llu.png`
   (from WSL with Linux paths if you run it by script; PowerShell's `Start-Process -ArgumentList` splits arguments with spaces, so use a script). A lockstep MISMATCH points at the instruction; otherwise the frames show when the dialog appears, and a second run with `--trace-from N --trace-count M` (and `--dev-log`, which slows the run six times, only near it) shows the access that faults: in the 68k emulator a bus error is a DSI (or machine check) the NanoKernel hands to the 68k code; find its DAR and what Mac OS expected there.
3. Mac OS 9.1's driver: what it does with MESH and the target that the 7.6.1 driver does not (a unit-bench sequence in `scsi_main.cpp` for it, as dingusppc's log or the board's readout shows it).
4. S is done when Mac OS reaches the Finder on the board, with the mouse and keyboard; write the plan's S section and the README status, commit, rewrite this prompt, go on to A (the startup chime: AWACS and DBDMA channel 8, the same `PPCMac_dbdma` on the same DMA port; its descriptors and samples are in the ROM). Later in S: Linux (the Debian 7 image), a CD-ROM target.

## Tools and files added by the S session

- `verilator\run_scsi.py` (`scsi_tb_top.sv`, `scsi_main.cpp`): MESH, DBDMA A and the disks, seconds.
- The machine bench: `--disk0/--disk1 FILE` (hps_io's block side; writes kept in memory), `--disk-log`, `--disk-latency N`, `--mouse N:DX:DY`, `--vram-check` (every CPU write to the VRAM kept, every read and every picture-side answer checked), `--vram-log FILE`, `--frame-out` with `%llu`; DMA writes mirrored into the reference's RAM; the progress line prints the disks' state.
- `syn\mister.py put-disk FILE [NAME]`, `mount 0|1 PATH` (writes `config/PPCMac.sN`, which the stock Main reads at core start), `umount 0|1`.
- `verilator\machref` with a disk: `--set hdd_img2=FILE` (dingusppc's 7300 boots it to the happy Mac and hangs at the first DMA write); use a copy (`Scratch\disks\os761_ref.hda`), dingusppc writes it.
- Disk images (git-ignored, `Scratch\disks\`): `os761.hda` (Mac OS 7.6.1, from `\\daninas.local\Software\BlueSCSI Images\PowerPC Images`), `os761_ref.hda` (dingusppc's copy), `os91.hda` (9.1).

## Rules

- SystemVerilog, limited to what Verilator 5.020 and Quartus 17.0 both accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`; it takes the machine's file list from `rtl/machine/PPCMac_machine.qip`, so a new file goes there; the SCSI bench's top is linted too). Quartus 17 refuses, silently or not: a second read expression on a memory, byte-enabled writes to a wide array, a variable part-select or bit-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, every RAM style attribute, a three-input add or subtract as one expression, a RAM written from registers with a combinational read. Watch for signed constants that overflow. In Verilator a size cast of a signed expression inside a function call's argument did not sign-extend as written: write sign extensions out.
- Machine modules are `PPCMac_*` under `rtl/machine/`. `sys/` is never edited.
- Real hardware outranks every emulator; of the emulators dingusppc is trusted most; where dingusppc is high-level or missing (MESH's DMA out), Linux's driver and the chips' manuals; Apple's own firmware is evidence too (the ROM's SIM settled two MESH behaviours this session: read it in `rom7300/resources/2B27E0_nitt_43_Native_4.3.lst`).
- Edit files with the editor tools (Edit, Write), not scripts, `sed` or heredocs. Generated files and files copied whole from my other repositories are the exception.
- Commit at verified points with explicit paths (never `git add -A`), messages through a file (`git commit -F`), ending with the co-author line the harness gives. Never push or add a remote. Do not modify anything under `ppctest\` (another session's; running its tools is fine) or the dingusppc tree. Quartus rewrites a line of `PPCMac.qsf`; leave it out of commits.

## Environment

- Windows 11. Verilator 5.020, g++, make in WSL (Ubuntu 24.04); `sudo` needs my password, so nothing can be installed. Run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>`; anything non-trivial in a script file run with `wsl -- bash /mnt/c/.../script.sh`. Build one Verilator bench at a time in a build directory; a second build directory (`PPCMAC_BUILD`) for a second run. A Verilated model held in a global must be released before its context (`scsi_main.cpp` hung on exit until it did).
- Quartus Lite 17.0 at `C:\intelFPGA_lite\17.0`. Python 3.9 on Windows with `websockets` and PIL.
- The MiSTer: 192.168.99.143 (`syn\mister_host`, git-ignored), the Remote on port 8182, key-based SSH (`~/.ssh/mister_only`).
