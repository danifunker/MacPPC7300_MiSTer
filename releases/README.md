# MacPPC7300 releases

Test builds of the Power Macintosh 7300/7600 core for the MiSTer
(DE10-Nano), each with the Main binary it was tested with.

| File | Date | md5 | What it is |
|---|---|---|---|
| `MacPPC7300_20261021.rbf` | 2026-10-21 | `7b0735e6c4cef48fb1ae462116c14402` | **70 MHz** (the speed the design is timed at). From now on each release is two files at fixed speeds, no CPU speed option. New: **PPP and serial on Mac OS work** (Grand Central's serial DMA channels, which Mac OS's serial driver needs, built from measurements on a real 7300); **the OSD is the MiSTer computer cores' standard menu** (top page: disks, Load ROM, Memory, Network interface; pages Machine, Video, Input with "Swap Alt/Win keys", Audio, Advanced; "Changes pending" and "Apply and reset"): **set your Memory and disks again**; byte stores to uncached SDRAM memory fixed. Notes in `../release.md`. |
| `MacPPC7300_OC_20261021.rbf` | 2026-10-21 | `1e2b06b558a10b71b42f442e615a6d2c` | **100 MHz, an overclock** (OC): the same source; 5 of 5 cold starts on our board, but whether a fit runs at 100 MHz depends on the fit; if it misbehaves, use the 70 MHz file and say so on Discord. |
| `MacPPC7300_20261016.rbf`, `_20261016_100MHz.rbf` (in git's history) | 2026-10-16 | | The dual-speed and 100 MHz-only builds of the FPU overlap work (`../release.md`). |
| `MacPPC7300_20261015.rbf` (in git's history) | 2026-10-15 | `dbf4e4059b61c2828c9fdbbe82f5fe23` | The seventh test build. **The CPU speed is an OSD option**: "CPU speed (on reset)", 70 MHz (the default) or 100 MHz, taken at the next Reset or power-on, with the speed work's CPU (the pipelined FPU, branch folding, the larger BTB and instruction cache, the frame buffer's write combiner). Speedometer 4.02 on Mac OS 7.6.1: at 70 MHz CPU 3.82, Math 257, the Benchmark Mix 14.7, Color 2.16, the FPU 5.40 (build 54: 2.50, 108, 8.5, 1.35, 3.61); at 100 MHz CPU 5.48, Math 370, the Mix 21.3, Color 2.81, the FPU 7.80. **100 MHz is an overclock**: the design does not close timing there (70 MHz is as every build since 70 MHz); if it misbehaves for you, use 70 and say so on Discord. Also new: **32 and 64 MB SDRAM boards should work** (the ROM goes to the top of the board you have; not tried on a real 32 or 64 MB board yet); the RAM list is 28 MB (the default), 6, 16, and 60 and 124 MB on boards that hold them, and the setting moved: **set your RAM again and use Save settings** (Debian needs more than 28 MB). **Mac OS 9.1's Ethernet works** (the Ethernet chip's ID and address ROM as Apple's driver checks them). Ethernet comes back after Shut Down and the power key. Six monitors: Apple's 16-inch, 13-inch and 12-inch, a 17-inch Multiscan (640 x 480 to 1024 x 768) and a 20-inch Multiscan (to 1152 x 870), whose resolutions Mac OS's Monitors & Sound switches without a reset, and the 21-inch (1152 x 870). The MT32-pi no longer plays Linux's console as MIDI. Tested on the board with this build: Speedometer's whole run at 70 and at 100 MHz, the chime at both, Debian at 100 MHz and switched back to 70 (its console, its clock, Ethernet); on the day's builds with the same machine: Mac OS 7.6.1 and 9.1 with Ethernet (DHCP, pings), the monitors on 7.6.1, the 128 MB board's RAM list. |
| `MacPPC7300_20261014_100MHz.rbf` (in git's history) | 2026-10-14 | `3179dcc81cb5fee8f8b9d8babdffada0` | **A test build of the speed work at 100 MHz** (branch `fpu-pipe`, d3028e7; the same Main as below). The CPU runs at 100 MHz instead of 70 (the memory and video at their usual clocks) with the pipelined FPU, a second memory slot, branch folding and a 2,048-entry BTB, a 64 KB instruction cache, and a write combiner in front of the frame buffer. Speedometer 4.02 on Mac OS 7.6.1 against build 54: CPU 2.50 to **5.44**, Dhrystones 2.70 to 5.71, the Benchmark Mix 8.5 to 17.4, Color 1.35 to 2.56, the FPU 3.61 to 7.10 (the L2 off; it adds a few per cent more). **It is an overclock: 100 MHz does not close timing, and this bitstream is one fit of five that boots at that clock** (`docs/speed_profile_20261013.md`); it booted and ran Speedometer three times here, shut down cleanly each time. If it misbehaves for you (a black screen, a bus error at "Welcome to Mac OS", a hang), that is the clock, not your card: please say so on Discord with what you saw, and use build 54. Tested: Mac OS 7.6.1 to the Finder and Speedometer's whole run, RAM 120 MB, the 16-inch monitor; Mac OS 9.1, the CD-ROM, Ethernet and the floppy are not tested on this build. |
| `MacPPC7300_20261011.rbf` (in git's history) | 2026-10-11 | `82e2175df868b9343c66f63ad308ef21` | The sixth test build (build 54). The picture is there from power-up (a black 640 x 480 at 60 Hz while the Mac's video is off, as the other cores give the framework a signal), and the FPU's special cases and `fmul` are a few cycles shorter than the fifth build's (builds 44-46). The sound path is the fifth build's, which is right (a `MacPPC7300_20261010.rbf`, build 52, went out for a few hours on 2026-10-10 with the codec's rate code 2 at 44,100 Hz, every sound an octave high; it is withdrawn and in git's history only). Tested on the board with the Main from here: the chime and the system sounds by ear, Mac OS 7.6.1 and 9.1 to the Finder and shut down, Speedometer's whole run (CPU 2.503, Math 107.975, FPU 3.610 on the measuring build 48; the fifth build's numbers otherwise). Known: Altair's startup sound buzzes for a second (the app's startup racing the Sound Manager; the same on the Quadra core; its other sounds are fine). The fifth build (`MacPPC7300_20261009.rbf`, build 38, md5 `d87539bba6158e288bf0985fb7111799`) is in git's history. |
| `MacPPC7300_20261009.rbf` (in git's history) | 2026-10-09 | `d87539bba6158e288bf0985fb7111799` | The fifth test build (build 38): the fourth renamed. The core is now **MacPPC7300** (it was PPCMac): its files go in `games/MacPPC7300/`, and the disks identify as "MiSTer VIRTUAL DISK" as the Mac LC core's do. Upgrading from PPCMac: rename `games/PPCMac` to `games/MacPPC7300`, and `config/PPCMac.CFG` to `config/MacPPC7300.CFG` to keep the OSD's settings; mount the disks again (the old `config/PPCMac.s*` can go), and delete the old `PPCMac` core file. Tested on the board with the Main from here: Speedometer's whole run on Mac OS 7.6.1 (the fourth build's numbers), Mac OS 9.1 to the Finder, the CD-ROM, and a second hard disk ("Mount SCSI disk 1": a Mac OS 7.5.3 disk beside 7.6.1, 70 MB copied on it and between the two). Once, opening the second disk for the first time, the Finder stopped with a bus error; it did not happen again. The fourth build (build 36, commit `2e755e4`) was everything in the third, faster. The CPU runs at 70 MHz instead of 65, a 128 KB L2 cache sits in front of the memory, and the FPU's multiply is shorter. Speedometer 4.02 on Mac OS 7.6.1 against the third build: CPU 2.28 to 2.50, Disk 1.39 to 1.56, Math 95.0 to 106.8, FPU 3.12 to 3.57; the start to the Finder's menu bar from about 101 s to 86 s. Tested on the board: Speedometer's whole run on 7.6.1, Mac OS 9.1 to the Finder. The earlier builds, under the old name (`PPCMac_20261008.rbf`, 7.6.1 only; `PPCMac_20261008b.rbf`, build 20; `PPCMac_20261008c.rbf`, build 28: the floppy drive, Debian, 120 MB, the power-off; `PPCMac_20261009.rbf`, build 36), are in git's history. |
| `MiSTer` | 2026-10-09 | `c641b24fec57a34de4b1b10b800a1639` | The Main for this build: the official MiSTer-devel Main with four commits for this core (branch `Mac-ppc-enhancements`, `24832a2`; the fourth follows the new name: a Main from before it does not know MacPPC7300): the core joins the Mac SCSI family (the CD-ROM through the Mac CD layer, the BlueSCSI Toolbox, local time with daylight saving), its Ethernet frames go through the Main, and its Ethernet option is one setting (Off or the interface). The CD-ROM and Ethernet need it; with an official Main the core runs without them. The other cores are untouched. |

## Installing

1. Copy `MacPPC7300_20261021.rbf` (or the overclock, `MacPPC7300_OC_20261021.rbf`) to `/media/fat/_Unstable/` (or
   `_Computer/`) on the SD card, as `MacPPC7300.rbf` or under its own name.
2. For the CD-ROM and Ethernet: keep a copy of your `/media/fat/MiSTer`
   (for example as `MiSTer.official`), copy `MiSTer` from here in its
   place, then reboot the MiSTer. Your other cores keep working: it is the
   official Main with this core's additions. To go back, copy yours back.
3. The ROM: the core needs a Power Macintosh 7300 or 7600 ROM image (4 MB:
   `077D.34F2` from a 7300, or `077D.28F2` from a 7600) as
   `/media/fat/games/MacPPC7300/boot.rom`. `boot0.rom` here is the 7300's
   (`077D.34F2`, md5 `edcf3422d712f61f83c07efc2401cbb8`); copy it into
   `/media/fat/games/MacPPC7300/` (the Main loads `boot0.rom` and `boot.rom`
   alike).
4. A disk: a SCSI hard disk image (`.hda` or `.vhd`, 512-byte blocks, an
   Apple partition map; the BlueSCSI-style images of Mac OS 7.5.3 to 9.1
   work as they are) in `/media/fat/games/MacPPC7300/`, mounted from the OSD:
   "Pri. disk (ID 0)" (and "Disk (ID 1)" for a second one). The
   Main remembers them.
5. Optional, the NVRAM (Open Firmware's settings): an 8 KB
   file of zeros, for example `/media/fat/games/MacPPC7300/MacPPC7300.nvr`, mounted
   from the OSD: Advanced, "NVRAM image". The core loads it at its start and writes
   the NVRAM back into it two seconds after any change.
6. Optional, a CD (needs the Main from here): an `.iso`, `.toast`,
   `.cue`/`.bin` or `.chd` image, mounted from the OSD: "CD-ROM (ID 3)". It
   is SCSI ID 3; Apple's CD-ROM driver (in Mac OS's Extensions) shows it
   on the desktop, the AppleCD Audio Player plays its audio tracks.
7. Optional, file sharing with the MiSTer (needs the Main from here): put
   files in `/media/fat/games/MacPPC7300/shared/` and use the BlueSCSI
   Toolbox's Mac app ("BlueSCSI SD Transfer") to copy them in and out.
8. Optional, Ethernet (needs the Main from here): OSD "Network
   interface": the MiSTer's interface (eth0 for the cable), then "Apply and
   reset". The Mac gets its own address on your network (Open Transport's
   TCP/IP, "Using DHCP Server").
9. Optional, a floppy disk: OSD "Floppy disk", a `.dsk`, `.img` or
   `.ima` image (400K, 800K or 1440K, tried; 720K should work too; raw or
   DiskCopy 4.2). Disks are read-only (shown locked); eject from the
   Finder (Put Away). The OSD does not remember a floppy across loads.
10. Optional, Linux: a Debian 7.11 PowerPC disk image with its own Mac OS
    and BootX (the BlueSCSI-style "HD00_512 LINUX" image works) needs RAM
    124 MB (a 128 MB SDRAM board; at 28 MB it stops half a second into the
    kernel) and, in BootX's options, "Force SCSI ON" off.

## What works, what does not

- Mac OS 7.6.1, 8.5, 8.6 and 9.1 boot to the Finder: the video (the OSD's
  Monitor: 832 x 624, 640 x 480, 512 x 384, a 17-inch Multiscan to 1024 x
  768, the 21-inch's 1152 x 870, a 20-inch Multiscan to 1152 x 870; its
  1280-wide modes are listed but not taken), the keyboard and mouse (ADB),
  the SCSI disks, the CD-ROM, Ethernet, the startup chime, the clock (set
  from the MiSTer's, local time), the serial port (the modem port on the
  MiSTer's UART, or MIDI). Mac OS's own sounds are not tested yet.
- Mac OS 9.1 and 7.6.1 say "Your clock is not set to the correct time" as
  they start, and close it by themselves. The time is right: the core puts
  the MiSTer's time into Cuda's clock without the "time set" flag Cuda
  keeps beside it, so Mac OS takes the clock as never set. Fixed after the
  2026-10-21 release (the core sets the flag with the time).
- Memory (OSD top page): 28 MB (the default, any board), then 60 (a 64 MB
  SDRAM board or larger) and 124 MB (a 128 MB board), then 6 and 16 MB;
  Mac OS sees all of it. Settings that need a restart (Memory, the
  Machine and Video pages, the controller, Network interface) show
  "Changes pending" until "Apply and reset" (or the power key after a
  Shut Down); "Save settings" on the System page keeps them.
- Shut Down (Mac OS, or Linux's `poweroff`/`shutdown -h now`) switches the
  machine off: the screen goes dark. The OSD's "Apply and reset" or the keyboard's
  power key (the PC keyboard's Menu key) starts it again.
- Floppy disks: read only. No PCI cards.
- Debian 7.11 Linux boots to its login prompt (the console in colour, the
  disks, Ethernet), at 70 and 100 MHz, its graphical login (lightdm) too;
  sound under Linux is not tested. If the image
  starts its graphical login (lightdm) and the screen stays dark,
  Ctrl+Option+F1 (Ctrl, the Windows key, F1) shows the text console.
- ADB game controllers (OSD, takes effect at the core's Reset): Gravis
  MouseStick II, Firebird, GamePad, SideWinder 3D Pro; "Stick moves
  pointer" drives the mouse from the stick. MIDI: the OSD's UART "MIDI",
  with an MT32-pi on the MiSTer's I/O board, for Mac apps that send MIDI
  through the modem port.
- The PC keyboard: Alt is Command, the Windows keys are Option, the Menu
  key is the power key (alone: Mac OS's shut-down dialog; with Alt: the
  debugger, MacsBug if it is installed; with Control and Alt: restart).
  Hold Shift through the start-up to start without extensions.
- Shut Down from the Finder before loading another core or switching the
  MiSTer off: like a real Mac, a disk that is not shut down is checked at
  the next start.
- The CPU is the core's own 604-compatible design at 70 MHz, or 100 MHz
  in the OC file (an overclock), with a 128 KB L2 cache (OSD Machine page,
  "L2 cache", on by default). Speedometer 4.02 on Mac OS
  7.6.1 gives CPU 3.82 (5.48 at 100 MHz) and Math 257 (370) against a
  Quadra 605, the FPU 5.40 (7.80) against a Quadra 650. The Mac's clock,
  sounds and serial port keep their rates at either speed.
- With the Main from here, the disks' writes are gathered in the MiSTer's
  memory and reach the image file within half a second: Shut Down before
  switching the MiSTer off.
- Scale (OSD): V-Integer gives even lines for the 13-inch 640 x 480 on a
  1080-line display; for the 16-inch 832 x 624 Normal with a sharp scaler
  filter looks best.
- Known: when the core is loaded with an NVRAM image mounted, the startup
  chime may play twice. If the picture starts in four strips, please say
  so on Discord: this build has a fix for that we could not test.
- The OSD's UART stays for the serial port (Open Firmware's console, MIDI,
  PPP); the debug readouts of earlier builds are gone.
