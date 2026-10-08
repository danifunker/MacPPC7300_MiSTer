# Resume prompt: after the Quadra 800 parity session: test what was built, then Mac OS 8.6 and 9.1

(Rewritten 2026-10-08, at the end of the session that added the Quadra 800
core's features. It replaces the earlier `RESUME_disk.md`. Written for a
regular session, Opus or any model: everything it needs is here or in the
files it names.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (`docs/DSPPC604_plan.md`). The machine has its own plan, `docs/PPCMac_plan.md`: milestones C, I, T, E, V, K, S done, A (sound), P (persistence), X (PCI, later), and the backlog of the Quadra 800 core's features (its table says what is built and what is tried). Mac OS 7.6.1 boots from an SD-card image to the Finder with every extension on the board.

**Work independently.** Make every decision the documents leave open yourself, the way their rules point, and record it in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. I am often around and may answer, but do not wait for me. Two things stay: the CPU rule below (a CPU change stops the session), and never pushing (this repository or `..\Main_MiSTer`). At the end of each milestone, and before your context runs short, rewrite this prompt for the session after you and commit it.

**Test on the board, not in Verilator.** The whole machine simulates at about 400,000 instructions a second (Mac OS reaches the Finder well past a billion: hours). Prove features on the MiSTer; use the unit benches (`run_cuda.py`, `run_scsi.py`, `run_escc.py`: seconds) and whole-machine runs only to explain what the board shows. The ways that found earlier faults are in the README ("For a fault inside Mac OS", "For a hang").

**Control the board through the MiSTer Remote (mrext, port 8182)**: `python syn\mister.py load | menu | shot OUT.png | keys TEXT | mouse DX DY [STEPS] | click | ws STEP ...` (`ws` steps: `sleep:` seconds, `kbdRaw:N` a Linux key code, `kbdRawDown:N`/`kbdRawUp:N`, `mouseMove:dx,dy`, `mouseBtn:left`; the Remote cannot hold a mouse button, so menus in System 7 cannot be dragged: open things by double-clicking in the Finder, type-select a name, and use lists that take clicks). SSH only copies files (`put-core`, `put-rom`, `put-nvram`, `rm-nvram`, `put-disk`, `mount 0|1|2`, `umount`, `make-nvr`, `cfg`) and reads the UART (`uart`, `type`). `cfg` takes `--ram --boot --uart --picture --monitor 16|13|12 --joy none|mousestick|firebird|gamepad|sidewinder --ptr`; with no arguments, the defaults. The pointer moves about 0.85 pixel per count in slow steps (Mac OS accelerates fast ones): move, screenshot, correct.

**Never reload the core while Mac OS has its disk mounted** (the user: it corrupts the image). Shut Mac OS down first: `ws kbdRaw:127 sleep:3 kbdRaw:28` (the Menu key is ADB's power key; Return presses Shut Down), then check the screenshot is black; a modal message on screen eats the first Return. Reload without a shutdown only from a hang before the Finder, and say so. **Leave the board as I would find it**: options default (`cfg`), Mac OS shut down, and say in the commit which images are mounted. I load the core from the menu myself. **Never install a Main binary on the board without asking me first.**

**MacsBug and the NMI.** Command-Menu (`ws kbdRawDown:56 sleep:0.3 kbdRaw:127 sleep:0.5 kbdRawUp:56`) is the NMI: MacsBug with `games/PPCMac/os761mb.hda`, else the ROM's debugger. Type into MacsBug a character at a time, 0.3 s apart.

Read these first. They are the source of truth:

- `README.md`: the locked decisions, how to run everything, the build table (its last rows: builds 7-10).
- `docs/PPCMac_plan.md`: the backlog table (Quadra parity: what is built, tried, waiting), the decisions table (the 2026-10-08 "parity" rows: the user's answers, the controllers, the serial port, the CD and Toolbox contract, Ethernet).
- `docs/PPCMac_stubs.md`: everything still stubbed or untried (the ADB, ESCC, disks/CD and MACE rows were rewritten 2026-10-08).
- `docs/DSPPC604_plan.md`: the CPU's rules.
- `releases/README.md`: the test release (build 5) the user shares on Discord.
- References: dingusppc (`C:\Temp\mistercore\dingusppc`), MAME (`..\mame\src\mame\apple`), the Quadra 800 core (`..\MacQuadra800_MiSTer`, read only: no edits, commits, pushes or fetches), the Mac LC core (`..\MacLC_MiSTer`, its BlueSCSI contracts in `docs/BLUESCSI_*`), Linux's `drivers/net/ethernet/apple/mace.c`.

## Where things stand (2026-10-08, end of the parity session)

- **The CPU** (`rtl/DSPPC604/`) unchanged since 0869a0f. A CPU bug or feature: stop, write `RESUME_cpu.md`, commit, stop.
- **Built this session** (commits 1baefca, 06d6561 and the Ethernet commit after them):
  - ADB game controllers (`PPCMac_adb`, the Quadra's MouseStick II, Firebird, GamePad, SideWinder; Talk 3 collisions; "Stick moves pointer" also for the GamePad and None). Board: keyboard and mouse still work beside a GamePad and a MouseStick. The user's findings for the Quadra core's own controllers: `docs/quadra800_adb_joystick_prompt.md`.
  - Serial (`PPCMac_escc`, `PPCMac.sv`): TRxC as a MIDI interface's 1 MHz, the UART's MIDI mode, the MT32-pi on the user port, CTS/RTS/DTR for PPP and the Main's printer daemon. `run_escc.py` passes.
  - CD-ROM at ID 3 (`PPCMac_scsidisk`, `PPCMac_cdaudio`) over the Quadra's optimized contract with the Main's Mac CD layer; BlueSCSI Toolbox (file sharing on ID 0, CD changer on ID 3) as the Mac LC's. `run_scsi.py` passes, and `--stock` (the official Main: no drive, nothing written to slot 4).
  - The 12-inch 512 x 384 monitor (Monitor is O[16:15] now): works on the board.
  - Ethernet (`PPCMac_mace` receive, `PPCMac_enet`, `PPCMac_ddrarb`, the DBDMA's `di_last`): frames through two DDR3 rings at 0x30400000; written, linted, built (build 10), **not tested at all**: no bench, not on the board.
  - Already on: ALSA audio and Y/C video (the framework's defaults).
- **The Main**: branch `Mac-ppc-enhancements` in `..\Main_MiSTer` (the user's branch for this work): aad7960 (ppcmac in the Mac SCSI family and the optimized CD contract), 7b3a601 (ppcmac Ethernet). Local only, the user reviews it before upstreaming; keep new comments few. Build: WSL, `/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin` on PATH, rsync the tree to `~/.cache/ppcmac/main_ppcenh`, `make` (a script like `mainbuild.sh`: copy, make, md5 `bin/MiSTer`). In the Mac family the Main also gives our disks its write buffer and sends local time (daylight saving included) as the TIMESTAMP.
- **Size**: build 10 (everything above) 34,115 of 41,910 ALMs (81%), 182 RAM blocks, 48 DSP, the CPU at -0.852 ns slow-model slack (runs at 65 MHz). The user asked for the size once the SCSI features were in, and may want a floppy drive if it fits (about 7,800 ALMs free).
- **The board**: build 10 as `_Unstable/PPCMac.rbf` (md5 7ad786f1d7aebfbb690976ab035d26bd), Mac OS shut down, options default; `os761ot.hda` on SCSI disk 0, `PPCMac.nvr` on the NVRAM slot; also on the card `boot.rom` (7300), `os761mb.hda`, `os761.hda`, `os753.hda`, `os86.hda`, `os91.hda`. Local images in `Scratch\disks\` (git-ignored); bitstreams kept in `Scratch\build1\PPCMac_bN.rbf`.

## Open with the user

1. **Installing the branch's Main on the board** (needed for the CD, the Toolbox, the changer and Ethernet): ask before doing it, and keep the official binary to put back.
2. **A Discord tester's start-up screen** (French Mac OS 8.5-9, "Démarrage en cours…"): the picture cut into four strips by black bars, each a different horizontal slice. Not reproduced: on the board 7.6.1 shows 256, thousands and millions right at 832 x 624, and a late DDR3 line would show stale lines, not black. Asked the user for: the OS version and image (it reaches its welcome screen; ours of 8.6 and 9.1 stop at a grey screen before), the build, the OSD's Monitor and RAM, their MiSTer.ini video lines, whether the Finder is the same, and to try the 13-inch option and 256 colours.
3. The double chime at a core reload with the NVRAM mounted: the user will look again.
4. The user's commit c6d759a put `releases/boot0.rom` (Apple's 4 MB ROM) into git; the releases rule says no ROM. Mention it; do not undo it.
5. To try with the user or Discord: the controllers (the MouseStick's axes under the Gravis control panel; "Stick moves pointer"), the MT32-pi, serial MIDI in and out, PPP, printing to an ImageWriter through the Main's printer daemon.

## Next steps

1. **With the Main installed** (after asking): the CD (an ISO, then a CUE/BIN with audio: the AppleCD Audio Player plays, the sound in the mix), the Toolbox (the BlueSCSI app or MacAtrium: a shared folder `games/PPCMac/shared` or the ini's `shared_folder=`), the changer (`games/PPCMac/CD3`), then Ethernet (OSD Ethernet On: Mac OS's TCP/IP by DHCP, a ping or a web page). Put the official Main back afterwards unless the user says otherwise.
2. **An Ethernet bench** if the board shows trouble (or before, if cheap): MACE + DMA channels 2 and 3 + `PPCMac_enet` with a DDR3 model and the C++ as the Main; `run_scsi.py`'s Grand Central already includes MACE.
3. **A floppy drive** if the user wants it (SWIM3 with a real drive and disk images; check the area first).
4. **Mac OS 8.6's grey screen**, then **9.1's**: the debug readout (`cfg --uart debug`, `uart 4 --baud 115200`: row 0 the pc), the NMI, then a simulation with `--dev-log-from` near the stop. The Discord tester's image gets past it: ask for it.
5. Milestone A (Mac OS's own sounds, the codec's volume and mute) and P's proof (a setting kept across a reload).

## Tools and files

- `verilator\run_machine.py` (`--disk0/--disk1`, `--dev-log`, `--exc-log`, `--dump-at`, `--trace-from`, `--frame-*`, `--wav`, `--clock`, `--no-lockstep`), `excan.py`, `devstat.py`, `ramdump.py`, `hc05dis.py`.
- Unit benches: `run_cuda.py` (Cuda and the ADB devices, controllers included), `run_scsi.py [--stock]` (MESH, the disks, the CD, the Toolbox), `run_escc.py` (the serial rates, MIDI, CTS/RTS).
- Quartus builds: copy `PPCMac.qpf/.qsf/.sdc/.srf`, `PPCMac.sv`, `build_id.v`, `files.qip`, `rtl\`, `sys\` into `Scratch\qbuild` and compile there in the background (about 20 minutes), so the tree can change meanwhile; keep each bitstream as `Scratch\build1\PPCMac_bN.rbf`.
- `syn\mister.py` (above). Images to the card: `gzip -1 -c FILE | ssh -i ~/.ssh/mister_only root@HOST "gunzip -c | dd of=/media/fat/games/PPCMac/NAME bs=1M conv=sparse"` then `truncate -s SIZE`. `rb-cli` (`C:\Temp\mistercore\rusty-backup\target\release\rb-cli.exe`) reads HFS images.

## Rules

- SystemVerilog both Verilator 5.020 and Quartus 17.0 accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`; the file list comes from `rtl/machine/PPCMac_machine.qip`, so a new file goes there). Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM, byte-enabled writes to a wide array, a variable part-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, RAM style attributes, a three-input add or subtract as one expression, a RAM written from registers with a combinational read; an implicit `.name` port connection needs the same type (signed too). Declare before use. A type name and a variable may not share a name.
- Machine modules are `PPCMac_*` under `rtl/machine/`. `sys/` is never edited.
- Real hardware outranks every emulator; dingusppc first among them; then MAME, Linux's drivers, the chips' manuals; Apple's firmware is evidence too.
- Edit files with the editor tools (Edit, Write), not scripts, `sed` or heredocs. Generated files and copies are the exception.
- Commit at verified points with explicit paths (never `git add -A`), messages through a file (`git commit -F`), ending with the co-author line the harness gives. Never push or add a remote. Do not modify anything under `ppctest\` or the dingusppc tree. Leave `PPCMac.qsf` out of commits (Quartus rewrites a line). `Scratch\` is git-ignored. A release goes in `releases\` with its md5, never with a ROM.
- Update `docs/PPCMac_stubs.md` in the same commit as any change to a stub. New code: comments short (the user's wish, for the Main above all).

## Environment

- Windows 11. Verilator 5.020, g++, make, llvm-objdump-18 in WSL (Ubuntu 24.04); `sudo` needs my password. Run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>`, anything with `$`, quotes or pipes from a script file. One Verilator build at a time per build directory (a known flake: "destroy locked Thread Pool" at archive time; run it again).
- Quartus Lite 17.0: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac`. Python 3.9 on Windows with `websockets` and PIL.
- The MiSTer: 192.168.99.143 (`syn\mister_host`), the Remote on 8182, key-based SSH (`~/.ssh/mister_only`). Disk images: `\\daninas.local\Software\BlueSCSI Images\PowerPC Images`; Mac software under `\\daninas.local\Software\Old Mac Stuff`.
