# Resume prompt: after milestone S: sound (A), persistence (P), the other Mac OS versions, the backlog

(Rewritten 2026-10-08, at the end of the session that filled in the stubs
Mac OS's start-up met and finished milestone S on the board. It replaces
the earlier `RESUME_disk.md`. Written for a regular session, Opus or any
model: everything it needs is here or in the files it names.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7300/7600 machine. The CPU is done (`docs/DSPPC604_plan.md`). The machine has its own plan, `docs/PPCMac_plan.md`, with the milestones C, I, T, E, V, K, S (all done), A (sound), P (persistence and the clock), X (PCI, later), and since 2026-10-08 a backlog of the Quadra 800 core's features. Mac OS 7.6.1 boots from an SD-card image to the Finder with every extension, Open Transport included, on the board.

**Work independently.** Make every decision the documents leave open yourself, the way their rules point, and record it in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. I am often around and may answer, but do not wait for me. Two things stay as they were: the CPU rule below (a CPU change stops the session), and never pushing (this repository or `..\Main_MiSTer`). At the end of each milestone, and before your context runs short, rewrite this prompt for the session after you and commit it.

**Test on the board, not in Verilator.** The whole machine simulates at about 400,000 instructions a second without lockstep (Mac OS 7.6.1 reaches the Finder well past a billion instructions: hours). Prove features on the MiSTer; use unit benches where they take seconds (`run_scsi.py`, `run_cuda.py`), and whole-machine runs only to explain what the board shows. The ways that found this session's faults are in the README ("For a fault inside Mac OS", "For a hang").

**Control the board through the MiSTer Remote (mrext, port 8182)**: `python syn\mister.py load | menu | shot OUT.png | keys TEXT | mouse DX DY | click | ws STEP ...` (`ws` steps' `sleep:` in seconds; `kbdRaw:N` a Linux key code, `kbdRawDown:N`/`kbdRawUp:N` to hold one). SSH only copies files (`put-core`, `put-rom`, `put-nvram`, `rm-nvram`, `put-disk`, `mount 0|1|2`, `umount`, `make-nvr`, `cfg`) and reads the UART (`uart`, `type`). Don't invent other control channels.

**Never reload the core while Mac OS has its disk mounted** (the user, 2026-10-08: it corrupts the image and the next boot is slower). Shut Mac OS down first: the PC keyboard's Menu key is ADB's power key, so `ws kbdRaw:127 sleep:3 kbdRaw:28` brings up Mac OS's shut-down dialog and presses Shut Down (the screen goes black; the CPU keeps running, since nothing switches the power off). Reload without a shutdown only from a hang before the Finder, and say so. **Leave the board as I would find it**: options default (`cfg` with no arguments), Mac OS shut down, and say in the commit which images are mounted. I load the core from the menu myself.

**MacsBug and the NMI.** Command-Menu (Alt and the Menu key: `ws kbdRawDown:56 sleep:0.3 kbdRaw:127 sleep:0.5 kbdRawUp:56`) is the NMI: MacsBug when the image has it (`games/PPCMac/os761mb.hda`), else the ROM's debugger. Type into MacsBug a character at a time with pauses (a helper is easy: `kbdRaw` codes from `tools\misterdeploy\ws_send.py`'s table, 0.3 s apart, Shift held with `kbdRawDown:42` for symbols); `sc` (the calling chain, with Open Transport's and the CFM fragments' names) and `wh ADDR` found this session's Open Transport hang; Return repeats the last command.

Read these first. They are the source of truth and override anything remembered:

- `README.md`: the decisions that are locked in, how to run everything, the build's size and speed (the table's last rows).
- `docs/PPCMac_plan.md`: the milestones, the machine's rules, the S section's findings of 2026-10-08, the A and P sections, the backlog (the Quadra 800 core's features), the decisions table (the 2026-10-08 rows).
- `docs/PPCMac_stubs.md`: everything the machine still stubs or simplifies. Every entry is a suspect for the next hang.
- `docs/DSPPC604_plan.md`: the CPU's rules.
- `releases/README.md`: the first test release (build 5, `PPCMac_20261008.rbf`) and the Main binary it ran with; the user shares it.
- dingusppc (`C:\Temp\mistercore\dingusppc`, the reference: `devices/` for every chip) and MAME (`C:\Temp\mistercore\mame\src\mame\apple`: `cuda.cpp`, `awacs_macrisc.cpp`, `dbdma.cpp`, `heathrow.cpp`).

## Where things stand (2026-10-08)

- **The CPU** (`rtl/DSPPC604/`) is unchanged since 0869a0f. Do not change it: if the machine finds a CPU bug or needs a CPU feature, stop, write `RESUME_cpu.md` for a CPU session, commit it, and stop.
- **Milestone S is done** (commits deab094, 0efe945): on the board build 5 boots `os761ot.hda` (the untouched 7.6.1 image) to the Finder with every extension, the mouse and keyboard work, Shut Down works from the power key. What stopped it, in order: the SWIM3 stub (the bus error at the welcome screen, the session before); the monitor sense lines (the Control driver's DDC probe drove a line low and read it back high: the lines are now wires, `PPCMac_control`); Open Transport's AppleTalk waiting for LocalTalk's line (the ESCC's synchronous mode's sync/hunt, `PPCMac_escc`). The details are in the plan's S section.
- **Filled in this session** (the user asked for every stub Mac OS meets): AWACS and DMA channels 8 and 9 (`PPCMac_awacs.sv`: the startup chime bit-exact in simulation, heard on the board by the user); MACE with its cable unplugged and DMA channels 2 and 3 (`PPCMac_mace.sv`); the ESCC's interrupts and synchronous mode, Grand Central's LocalTalk registers; Cuda's NMI on Grand Central's source 14 and the power key; Cuda's clock from the MiSTer's RTC; the keyboard's one-event Talk and its rescan of held modifiers after a reset; the NVRAM kept on block slot 2 (`PPCMac_nvsave.sv`); the Scale option (`video_freak`); one DMA arbiter in Grand Central.
- **Build 6** (the board's core): a restart (Cuda's PC3) resets the board's devices with the CPU, as a real restart does; Restart from the power key's dialog boots Mac OS back to the Finder on the board.
- **Open, from the user**: (1) with the NVRAM image mounted, a core reload played the chime twice ("once during shut down and once during startup") and the ROM was reloaded (the reload is normal); not reproduced: the Main mounts slot 2 before it sends boot.rom, so the NVRAM load finishes before the first start; after Shut Down the CPU keeps running Mac OS's code (no power-off is modelled: how Cuda switches a 7300's supply off is unknown, `PPCMac_stubs.md`, Cuda, Power). Ask the user for the exact sequence if they have not said. (2) Mac OS showed the time an hour behind with the untouched image (5:33 for 6:33), right with the user's copy: the image's daylight-saving setting or the TIMESTAMP's zone. (3) The user finds the scaling of the Mac cores "kind of weird / bad": the Scale option is in; ask what they see, with the Normal and V-Integer settings and the scaler filter.
- **Other images**: Mac OS 8.6 (`os86.hda`) still stops at a grey screen (tested on build 5); 9.1 likewise before; 7.5.3 untested since the fixes. The user's `os761mb.hda` has MacsBug and Open Transport's extensions moved out.
- **The board's state**: build 6 as `_Unstable/PPCMac.rbf`, Mac OS shut down; on the card `boot.rom` (the 7300's ROM), `os761ot.hda` (mounted as SCSI disk 0), `os761mb.hda`, `os761.hda`, `os753.hda`, `os86.hda`, `os91.hda`, `PPCMac.nvr` (mounted on the NVRAM slot, `config/PPCMac.s2`). Locally the images are in `Scratch\disks\` (git-ignored).

## The next steps

1. Milestone A: Mac OS's own sound on the board (the Sound control panel's alert sounds through channel 8; the user listens), the codec's volume and mute if Mac OS uses them (MAME applies register 2's attenuation and a mute bit; dingusppc ignores them; Linux's `awacs.h` names the bits), sound input (channel 9, silence) if anything records. Then the plan's A section and the decisions table.
2. Milestone P's proof: an Open Firmware setting and a Mac OS control panel setting kept across a core reload (the NVRAM image), the date shown right; the power-off and the power key's wake if a source tells how Cuda switches the supply (a 7300 or 7500 developer note, Darwin's Cuda driver, or a measurement on the user's 7300).
3. The grey screens of Mac OS 8.6 and 9.1: the debug readout (`cfg --uart debug`, `uart 4 --baud 115200`: row 0 the pc), the NMI (the ROM's debugger even without MacsBug), then a simulation with `--dev-log-from` near the stop.
4. The backlog in the plan's order of value: the CD-ROM (an AppleCD target on MESH at ID 3, slot 4, CD audio into AWACS), Ethernet through Main's bridge, ADB game controllers, MT32-pi and serial MIDI, the printer port.

## Tools and files

- `verilator\run_machine.py`: `--disk0/--disk1`, `--dev-log FILE` with `--dev-log-from N`, `--exc-log FILE`, `--dump-at N --dump-bin FILE`, `--trace-from N --trace-count M`, `--frame-at/--frame-every/--frame-out`, `--wav FILE` (the sound), `--clock SECS` (Cuda's clock), `--no-lockstep`. Without lockstep the RAM dump lacks what the caches hold (code is fine).
- Native code from a RAM dump: find its physical page with `verilator\ramdump.py DUMP find HEX` (the instruction words from the trace), cut the bytes out, `objcopy -I binary -O elf32-powerpc`, `llvm-objdump-18 -d --triple=powerpc` in WSL. The 64-bit arithmetic of `UpTime` conversions (16-bit limb multiplies) is a sign of a timed wait.
- `verilator\excan.py`, `verilator\devstat.py`, `verilator\ramdump.py` as before; Cuda's firmware listing: `python verilator\hc05dis.py rtl\machine\cuda\341s0060.bin`.
- `syn\mister.py` (above). An image goes onto the card fastest compressed: `gzip -1 -c FILE | ssh -i ~/.ssh/mister_only root@HOST "gunzip -c | dd of=/media/fat/games/PPCMac/NAME bs=1M conv=sparse"` then `truncate -s SIZE` (6 GB: 12 minutes). `rb-cli` (`C:\Temp\mistercore\rusty-backup\target\release\rb-cli.exe`) reads the HFS images (`ls`, `get-binhex` for a file's resource fork).

## Rules

- SystemVerilog, limited to what Verilator 5.020 and Quartus 17.0 both accept; Verilator `-Wall` clean (`make -s lint` in `verilator\`; it takes the machine's file list from `rtl/machine/PPCMac_machine.qip`, so a new file goes there, and a module outside `PPCMac_system` gets its own lint line in the Makefile). Quartus 17 refuses: a second read expression on a memory, two write statements on one RAM (mux the address and data into one), byte-enabled writes to a wide array, a variable part-select or bit-select of a two-dimensional array, `genvar` inside the `for`, a generate loop without `generate`, RAM style attributes, a three-input add or subtract as one expression, a RAM written from registers with a combinational read. Declare before use.
- Machine modules are `PPCMac_*` under `rtl/machine/`. `sys/` is never edited.
- Real hardware outranks every emulator; of the emulators dingusppc is trusted most; where it is high-level or missing, MAME, Linux's drivers and the chips' manuals; Apple's firmware is evidence too.
- Edit files with the editor tools (Edit, Write), not scripts, `sed` or heredocs. Generated files and copies are the exception.
- Commit at verified points with explicit paths (never `git add -A`), messages through a file (`git commit -F`), ending with the co-author line the harness gives. Never push or add a remote. Do not modify anything under `ppctest\` (another session's) or the dingusppc tree. Quartus rewrites a line of `PPCMac.qsf`; leave it out of commits. `Scratch\` is git-ignored. A release goes in `releases\` with its md5 in `releases\README.md`, never with a ROM.
- Update `docs/PPCMac_stubs.md` in the same commit as any change to a stub.

## Environment

- Windows 11. Verilator 5.020, g++, make, llvm-objdump-18 in WSL (Ubuntu 24.04); `sudo` needs my password, so nothing can be installed. Run WSL commands from PowerShell as `wsl --cd <windows dir> -- <command>`, and anything with `$`, quotes or pipes from a script file: `wsl -- bash /mnt/c/.../script.sh`. One Verilator build at a time per build directory (`PPCMAC_BUILD=~/.cache/ppcmac/verilator2` or `3` for a second); big logs in `~/.cache/ppcmac/`.
- Quartus Lite 17.0: `C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe --flow compile PPCMac` in the repository, about 20 minutes, in the background. Python 3.9 on Windows with `websockets` and PIL.
- The MiSTer: 192.168.99.143 (`syn\mister_host`), the Remote on port 8182, key-based SSH (`~/.ssh/mister_only`). Disk images: `\\daninas.local\Software\BlueSCSI Images\PowerPC Images`; Mac software under `\\daninas.local\Software\Old Mac Stuff`.
