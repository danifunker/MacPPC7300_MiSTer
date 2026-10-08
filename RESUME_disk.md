# Resume prompt: after the session that tested the parity work: Mac OS 8.5-9.1 further, then milestone A

(Rewritten 2026-10-08, at the end of the session that installed the Main
branch on the board, got the CD-ROM, the Toolbox and Ethernet working, and
Mac OS 8.5, 8.6 and 9.1 to the Finder.
It replaces the earlier `RESUME_disk.md`. Written for a regular session,
Opus or any model: everything it needs is here or in the files it names.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (`docs/DSPPC604_plan.md`). The machine has its own plan, `docs/PPCMac_plan.md`: milestones C, I, T, E, V, K, S done, A (sound), P (persistence), X (PCI, later), and the backlog of the Quadra 800 core's features (its table says what is built and what works). Mac OS 7.6.1, 8.5, 8.6 and 9.1 boot from SD-card images to the Finder on the board; the CD-ROM, the BlueSCSI Toolbox's file sharing and Ethernet (DHCP, web, ping, FTP) work there.

**Work independently.** Make every decision the documents leave open yourself, the way their rules point, and record it in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. I am often around and may answer, but do not wait for me. Things that stay: the CPU rule below (a CPU change stops the session), never pushing (this repository or `..\Main_MiSTer`), and **never changing anything under `sys/`** (not even another core's fix there: describe it and let me decide). At the end of each milestone, and before your context runs short, rewrite this prompt for the session after you and commit it.

**Test on the board, not in Verilator.** The whole machine simulates at about 400,000 instructions a second (Mac OS reaches the Finder well past a billion: hours). Prove features on the MiSTer; use the unit benches (`run_cuda.py`, `run_scsi.py`, `run_escc.py`: seconds) and whole-machine runs only to explain what the board shows. The ways that found earlier faults are in the README ("For a fault inside Mac OS", "For a hang", and the trace).

**The trace on the board** (`PPCMac_trace.sv`, README): `python syn\mister.py trace [--last N]` reads a ring of 2,048 records the core keeps in DDR3: each SCSI command's start and status (with the Toolbox's answer from the Main), bus resets, CD mounts; the CPU's accesses to MACE and DMA channels 2 and 3 (MESH at F3018000 and channel A too with `cfg --trace-mesh`); DMA channels 2 and 3's commands (fetched, finished, stopped); the ADB keyboard (keys queued, Cuda's commands to it). For longer than the ring holds: `trace-capture SECONDS` (runs `syn\trstream.py` on the MiSTer; start it after the core has loaded), `trace-fetch OUT`, `trace --file OUT`. This found the keyboard's lost keys and Mac OS's Ethernet DMA programs in minutes.

**Control the board through the MiSTer Remote (mrext, port 8182)**: `python syn\mister.py load | menu | shot OUT.png | keys TEXT | mouse DX DY [STEPS] | click | ws STEP ...` (`ws` steps: `sleep:` seconds, `kbdRaw:N` a Linux key code, `kbdRawDown:N`/`kbdRawUp:N`, `mouseMove:dx,dy`, `mouseBtn:left`, and `mouseBtn:left_down` / `mouseBtn:left_up` to hold the button: System 7's menus can be dragged). From Git Bash set `MSYS_NO_PATHCONV=1` before passing text with `/` (it turns "/" into a Windows path). Typing into an old app's dialog: Tab into a field selects all of it, then type (Cmd-A does not work there). SSH only copies files (`put-core`, `put-rom`, `put-nvram`, `rm-nvram`, `put-disk`, `mount 0|1|2|4`, `umount`, `make-nvr`, `cfg`) and reads the UART (`uart`, `type`). `cfg` takes `--ram --boot --uart --picture --monitor 16|13|12 --joy none|mousestick|firebird|gamepad|sidewinder --ptr --eth --net eth0|eth1|wlan0|tap0 --trace-mesh`; with no arguments, the defaults. The pointer moves about 0.85 pixel per count in slow steps: move, screenshot, correct.

**Never reload the core while Mac OS has its disk mounted** (it corrupts the image). Shut Mac OS down first: `ws kbdRaw:127 sleep:3 kbdRaw:28` (the Menu key is ADB's power key; Return presses Shut Down), then check the screenshot is black; a modal message eats the first Return, and an app's own dialog can stop the shut-down (dismiss it). Reload without a shutdown only from a hang before the Finder, and say so. **Leave the board as I would find it**: options default (`cfg`), Mac OS shut down, the menu core loaded (`menu`), and say in the commit which images are mounted. I load the core from the menu myself. **Ask me before installing a different Main binary.**

**MacsBug and the NMI.** Command-Menu (`ws kbdRawDown:56 sleep:0.3 kbdRaw:127 sleep:0.5 kbdRawUp:56`) is the NMI: MacsBug with `games/PPCMac/os761mb.hda`, else the ROM's debugger.

Read these first. They are the source of truth:

- `README.md`: the locked decisions, how to run everything (the trace), the build table (its last rows: builds 11-17).
- `docs/PPCMac_plan.md`: the backlog table (Quadra parity: what is built and works), the decisions table (the "after parity" rows of 2026-10-08: the user's answers, the trace, `ALLOW_POWER_UP_DONT_CARE OFF`, the memory test, Ethernet's DMA).
- `docs/PPCMac_stubs.md`: everything still stubbed or untried (the DBDMA, MACE, ADB and disks/CD rows were rewritten 2026-10-08).
- `docs/DSPPC604_plan.md`: the CPU's rules.
- `releases/README.md`: the test release (build 5) the user shares on Discord; `releases/boot0.rom` is the 7300's ROM, in git on purpose (the user: that is how the core is distributed for now).
- References: dingusppc (`C:\Temp\mistercore\dingusppc`), MAME (`..\mame\src\mame\apple`), the Quadra 800 core (`..\MacQuadra800_MiSTer`, read only: no edits, commits, pushes or fetches), the Mac LC core (`..\MacLC_MiSTer`, its BlueSCSI contracts in `docs/BLUESCSI_*`), Linux's `drivers/net/ethernet/apple/mace.c`, NetBSD's `sys/arch/macppc/dev/if_mc.c` (both online).

## Where things stand (2026-10-08, end of the session)

- **The CPU** (`rtl/DSPPC604/`) unchanged since 0869a0f. A CPU bug or feature: stop, write `RESUME_cpu.md`, commit, stop.
- **The Main**: the branch `Mac-ppc-enhancements` in `..\Main_MiSTer` (aad7960, 7b3a601) is installed on the board as `/media/fat/MiSTer` (md5 a2546ea7d3d5a3a1338187f41d327044, built in WSL by the `mainbuild.sh` pattern: rsync to `~/.cache/ppcmac/main_ppcenh`, `make`); the official one is kept as `/media/fat/MiSTer.official` (eb1799eb). The CD and Ethernet need the branch; keep it unless I say otherwise.
- **Works on the board** (this session, commits 714627c, 162c9b0, 7dcfbf0):
  - Mac OS 8.5, 8.6 and 9.1 to the Finder from their own images (build 20; next steps 1).
  - CD-ROM at ID 3: ISO and CUE/BIN (data and audio; the AppleCD Audio Player numbers only audio tracks). BlueSCSI Toolbox file sharing (`games/PPCMac/shared`): download and upload (an upload is padded to whole 512-byte blocks: the protocol's block-encoded SEND carries no byte count; the Mac LC core does the same). The CD changer app finds no changer: **parked** (the user).
  - Ethernet (OSD "Ethernet (on reset)" On): DHCP, Cyberdog, ping, Fetch to FTP. It took MACE's internal loopback (the driver's self-test), a real FCS, and Grand Central's DMA status bits (s5 = MACE's XMTSV on channel 2; on channel 3 the frame's end ends an INPUT_MORE and sets s6). Build 18: the driver's LOAD_QUADs of MACE's XMTRC, XMTFS and IR through the system space (key 6) reach MACE (channels 2 and 3 only) and their values are written back into the commands; 60 pings of 1,400 bytes, none lost.
  - The keyboard: keys lost or changed were the ADB keyboard's clock crossing of hps_io's key code (the toggle now a stage after the code): 186 characters through the Remote, none lost.
- **The disk images on the card** (`games/PPCMac/`): `os761ot.hda` (SCSI disk 0), `toolbox.hda` (disk 1: a 20 MB volume "Toolbox" with BlueSCSI SD Transfer, SCSICDChanger, Fetch 2.1.2), `PPCMac.nvr` (NVRAM), `CD3/` (Open Transport 1.3.1.iso, DOOM II.iso; the CD slot mounts the OT ISO), `shared/`, also `os761mb.hda`, `os761.hda`, `os753.hda`, `os85.hda` (new), `os86.hda`, `os91.hda`. Local copies in `Scratch\disks\` (`os86.hda` unzipped), `Scratch\toolbox\` (the Toolbox disk's sources); bitstreams in `Scratch\build1\PPCMac_bN.rbf`.
- **Size**: build 20 (on the board, `Scratch\build1\PPCMac_b20.rbf`) 35,089 of 41,910 ALMs (84%), 192 RAM blocks, slack -1.200 ns; the trace costs about 900 ALMs and 9 RAM blocks (it can be dropped from a release build if the room is needed).
- **The scaler fault** (the Discord tester's picture in four strips, probably): fixed outside `sys/` with `ALLOW_POWER_UP_DONT_CARE OFF` in `PPCMac.qsf` (the decisions table says why). Not proven: a screen of many clean-boot loads (the Quadra core's `docs/perf/fix_hw_20261001/scaler_fault/vscreen.sh` and `vbuf_probe.py`: reboot, load, check the scaler's header at DDR3 0x20000000) would show it, and needs my OK because it reboots the MiSTer many times.
- **No memory test to patch**: the 7300's ROM tests no RAM at start-up that grows with its size (measured; the plan's decisions table).

## Open with the user

1. A floppy drive (SWIM3 with a real drive and disk images): the user asked whether there is one; there is not. About 6,200 ALMs are free. Ask whether to build it.
2. A new test release for Discord (build 17 or later, with the branch Main since the CD and Ethernet need it): ask.
3. The double chime at a core reload with the NVRAM mounted: the user will look again.
4. To try with the user or Discord: the controllers, the MT32-pi, serial MIDI in and out, PPP, printing.

## Next steps

1. **Mac OS 8.5-9.1 on the board**: they start to the Finder since build 20 (the grey screen was their disk driver's SDTR; "The 8.6 hang" below). Try them further: the Finder, Open Transport and Ethernet, the CD, the Toolbox apps, sound; a longer session for stability. 8.5 and 9.1 warn that the clock is not set: Mac OS's own year-2019 limit (the time shown is right; mactcp.net's 2020Patch lifts it), not the core's. The 8.6 image (`os86.hda`) ends in BeOS R4.5's loader: its `_OS_Chooser` in Startup Items (no BeOS partition on it, so the loader offers only "Rescan"); a BeOS image for PowerPC would be a fine test of the hardware without Apple's drivers. The 9.1 pointer did not show in the Remote's screenshots once the Finder ran (it did on 7.6.1): look whether it is the hardware cursor (RaDACal) or the screenshot.
2. Milestone A (Mac OS's own sounds, the codec's volume and mute: I must listen) and P's proof (a setting kept across a reload).
3. The CD changer when I un-park it: the app reads page 0x31 and the CD's INQUIRY on ID 3 (both as the Mac LC core's) and still finds nothing; trace what it sends next on the LC core for comparison.

## The 8.6 hang

The images carry Apple's driver 8.1.2 (8.5, 8.6) and 8.1.3 (9.1), Drive Setup 1.7's (18 KB, status 37F; 7.6.1's images have a 9 KB one). With 7.6.1's driver put into `os86.hda`'s driver partition (`Scratch\disks\os86_head_olddrv.bin`, the image's first 96 blocks; `os86_head_orig.bin` the original, also in `games/PPCMac/` on the card; the card's image is the original again) 8.6 started on build 17. Found with build 18's MESH trace (`cfg --trace-mesh`, `trace --last 2048`): the new driver's first command through SCSI Manager 4.3 selects with ATN and sends IDENTIFY + SDTR; our disk answered MESSAGE REJECT (07); the SIM then wrote MESH's synchronous parameters 02 (asynchronous), bus status 0 = 08 (ATN), and issued bus free (09), then polled MESH's interrupt register (00) for ever. Our MESH, like dingusppc's, kept ACK during a bus free with ATN up (dingusppc then moves its target on by hand); on a bus of signals the target waits for ACK to drop, so nothing moved. Fixed in build 20 (8.5, 8.6 and 9.1 to the Finder on the board): the disks answer SDTR with offset 0 (asynchronous) and WDTR with 8 bits as a real drive negotiates, MESH's bus free lets ACK go, and a target answers ATN at the end of a message in with MESSAGE OUT (`run_scsi.py` test 12). The trace's queue drops records while the CPU polls a register in a loop (the drop count says so); the lead-up survives in the ring if it is read soon after the stall.

## Tools and files

- `verilator\run_machine.py` (`--disk0/--disk1`, `--disk-log`, `--ram`, `--no-lockstep`, `--dev-log`, `--dev-log-from`, `--exc-log`, `--dump-at`, `--trace-from`, `--frame-*`, `--wav`, `--clock`), `excan.py`, `devstat.py`, `ramdump.py`, `hc05dis.py`.
- Unit benches: `run_cuda.py` (Cuda and the ADB devices), `run_scsi.py [--stock]` (MESH, the disks, the CD, the Toolbox), `run_escc.py`.
- Quartus builds: copy `PPCMac.qpf/.qsf/.sdc/.srf`, `PPCMac.sv`, `build_id.v`, `files.qip`, `rtl\`, `sys\` into `Scratch\qbuild` (or `Scratch\qbuild2` for a second at the same time) and compile there in the background (about 25 minutes); keep each bitstream as `Scratch\build1\PPCMac_bN.rbf`. Commit `PPCMac.qsf` only through a patch of your own lines (`git apply --cached`): Quartus rewrites its version line.
- `syn\mister.py` (above). Images to the card: `gzip -1 -c FILE | ssh -i ~/.ssh/mister_only root@HOST "gunzip -c | dd of=/media/fat/games/PPCMac/NAME bs=1M conv=sparse"` then `truncate -s SIZE` (6 GB: about 10 minutes). `rb-cli` (`C:\Temp\mistercore\rusty-backup\target\release\rb-cli.exe`, run with `MSYS_NO_PATHCONV=1`) reads and writes HFS images: `ls`, `cp IMG PATH IMG PATH` between images, `optical new mac-hfs`, `mac-scsi-bless --driver-from DONOR` (how `toolbox.hda` was made).
- A LAN test page: `python -m http.server 8000` in a scratch folder on this PC (192.168.99.82); `Scratch`-side sniffer `sniff.py` (a Python AF_PACKET reader on the MiSTer's eth0, filtered to the guest's MAC 08:00:07:2d:d0:a3) is in the previous session's scratchpad; copy it if needed.

## Rules

- SystemVerilog both Verilator 5.020 and Quartus 17.0 accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`; the file list comes from `rtl/machine/PPCMac_machine.qip`, so a new file goes there). Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM, byte-enabled writes to a wide array, a variable part-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, RAM style attributes, a three-input add or subtract as one expression, a RAM written from registers with a combinational read; an implicit `.name` port connection needs the same type (signed too). Declare before use. A type name and a variable may not share a name.
- Machine modules are `PPCMac_*` under `rtl/machine/`. **`sys/` is never edited.**
- Real hardware outranks every emulator; dingusppc first among them; then MAME, Linux's and NetBSD's drivers, the chips' manuals; Apple's firmware and Mac OS's own drivers (read off the board with the trace) are evidence too.
- Edit files with the editor tools (Edit, Write), not scripts, `sed` or heredocs. Generated files and copies are the exception.
- Commit at verified points with explicit paths (never `git add -A`), messages through a file (`git commit -F`), ending with the co-author line the harness gives. Never push or add a remote. Do not modify anything under `ppctest\` or the dingusppc tree. `Scratch\` is git-ignored.
- Update `docs/PPCMac_stubs.md` in the same commit as any change to a stub. New code: comments short (the user's wish, for the Main above all).
- Never type passwords or other credentials into anything on the board (the user types them).

## Environment

- Windows 11. Verilator 5.020, g++, make, llvm-objdump-18 in WSL (Ubuntu 24.04); `sudo` needs my password. Run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>`, anything with `$`, quotes or pipes from a script file. One Verilator build at a time per build directory.
- Quartus Lite 17.0: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac`. Python 3.9 on Windows with `websockets` and PIL.
- The MiSTer: 192.168.99.143 (`syn\mister_host`), the Remote on 8182, key-based SSH (`~/.ssh/mister_only`), `python3` on it (no `pkill`: use `ps | grep` and `kill`). Disk images: `\\daninas.local\Software\BlueSCSI Images\PowerPC Images`; Mac software under `\\daninas.local\Software\Old Mac Stuff`. An FTP server on the LAN at 192.168.99.5 (the user's; it refuses anonymous logins).
