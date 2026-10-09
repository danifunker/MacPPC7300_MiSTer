# MacPPC7300 releases

Test builds of the Power Macintosh 7300/7600 core for the MiSTer
(DE10-Nano), each with the Main binary it was tested with.

| File | Date | md5 | What it is |
|---|---|---|---|
| `MacPPC7300_20261009.rbf` | 2026-10-09 | `d87539bba6158e288bf0985fb7111799` | The fifth test build (build 38): the fourth renamed. The core is now **MacPPC7300** (it was PPCMac): its files go in `games/MacPPC7300/`, and the disks identify as "MiSTer VIRTUAL DISK" as the Mac LC core's do. Upgrading from PPCMac: rename `games/PPCMac` to `games/MacPPC7300`, and `config/PPCMac.CFG` to `config/MacPPC7300.CFG` to keep the OSD's settings; mount the disks again (the old `config/PPCMac.s*` can go), and delete the old `PPCMac` core file. **Not yet tested on the board.** The fourth build (build 36, commit `2e755e4`) was everything in the third, faster. The CPU runs at 70 MHz instead of 65, a 128 KB L2 cache sits in front of the memory, and the FPU's multiply is shorter. Speedometer 4.02 on Mac OS 7.6.1 against the third build: CPU 2.28 to 2.50, Disk 1.39 to 1.56, Math 95.0 to 106.8, FPU 3.12 to 3.57; the start to the Finder's menu bar from about 101 s to 86 s. Tested on the board: Speedometer's whole run on 7.6.1, Mac OS 9.1 to the Finder. The earlier builds, under the old name (`PPCMac_20261008.rbf`, 7.6.1 only; `PPCMac_20261008b.rbf`, build 20; `PPCMac_20261008c.rbf`, build 28: the floppy drive, Debian, 120 MB, the power-off; `PPCMac_20261009.rbf`, build 36), are in git's history. |
| `MiSTer` | 2026-10-09 | `c641b24fec57a34de4b1b10b800a1639` | The Main for this build: the official MiSTer-devel Main with four commits for this core (branch `Mac-ppc-enhancements`, `24832a2`; the fourth follows the new name: a Main from before it does not know MacPPC7300): the core joins the Mac SCSI family (the CD-ROM through the Mac CD layer, the BlueSCSI Toolbox, local time with daylight saving), its Ethernet frames go through the Main, and its Ethernet option is one setting (Off or the interface). The CD-ROM and Ethernet need it; with an official Main the core runs without them. The other cores are untouched. |

## Installing

1. Copy `MacPPC7300_20261009.rbf` to `/media/fat/_Unstable/` (or `_Computer/`)
   on the SD card, as `MacPPC7300.rbf` or under its own name.
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
   "Mount SCSI disk 0" (and "Mount SCSI disk 1" for a second one). The
   Main remembers them.
5. Optional, the NVRAM (Open Firmware's settings, Mac OS's PRAM): an 8 KB
   file of zeros, for example `/media/fat/games/MacPPC7300/MacPPC7300.nvr`, mounted
   from the OSD: "Mount NVRAM". The core loads it at its start and writes
   the NVRAM back into it two seconds after any change.
6. Optional, a CD (needs the Main from here): an `.iso`, `.toast`,
   `.cue`/`.bin` or `.chd` image, mounted from the OSD: "Mount CD-ROM". It
   is SCSI ID 3; Apple's CD-ROM driver (in Mac OS's Extensions) shows it
   on the desktop, the AppleCD Audio Player plays its audio tracks.
7. Optional, file sharing with the MiSTer (needs the Main from here): put
   files in `/media/fat/games/MacPPC7300/shared/` and use the BlueSCSI
   Toolbox's Mac app ("BlueSCSI SD Transfer") to copy them in and out.
8. Optional, Ethernet (needs the Main from here): OSD "Ethernet (on
   reset)": the MiSTer's interface (eth0 for the cable), then the core's
   Reset. The Mac gets its own address on your network (Open Transport's
   TCP/IP, "Using DHCP Server").
9. Optional, a floppy disk: OSD "Insert floppy disk", a `.dsk`, `.img` or
   `.ima` image (400K, 800K or 1440K, tried; 720K should work too; raw or
   DiskCopy 4.2). Disks are read-only (shown locked); eject from the
   Finder (Put Away). The OSD does not remember a floppy across loads.
10. Optional, Linux: a Debian 7.11 PowerPC disk image with its own Mac OS
    and BootX (the BlueSCSI-style "HD00_512 LINUX" image works) needs RAM
    96 MB or more and, in BootX's options, "Force SCSI ON" off.

## What works, what does not

- Mac OS 7.6.1, 8.5, 8.6 and 9.1 boot to the Finder: the video (832 x 624,
  640 x 480 or 512 x 384, the OSD's Monitor), the keyboard and mouse (ADB),
  the SCSI disks, the CD-ROM, Ethernet, the startup chime, the clock (set
  from the MiSTer's, local time), the serial port (the modem port on the
  MiSTer's UART, or MIDI). Mac OS's own sounds are not tested yet.
- Mac OS 8.5 and 9.1 say "Your clock is not set to the correct time" at
  every start: their date code takes no year after 2019 (the "Y2K20" bug of
  the classic Mac OS); the time is right. The free 2020Patch extension
  (mactcp.net) is said to quiet it (not tried here).
- RAM (OSD, "on reset": a change takes effect at the next Reset): 6, 16,
  24, 48, 64, 96 or 120 MB; Mac OS sees all of it. The Monitor and the
  game controller also wait for the next Reset.
- Shut Down (Mac OS, or Linux's `poweroff`/`shutdown -h now`) switches the
  machine off: the screen goes dark. The OSD's Reset or the keyboard's
  power key (the PC keyboard's Menu key) starts it again.
- Floppy disks: read only. No PCI cards.
- Debian 7.11 Linux boots to its login prompt (the console in colour, the
  disks, Ethernet); X and sound under Linux are not tested. If the image
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
- The CPU is the core's own 604-compatible design at 70 MHz with a 128 KB
  L2 cache ("L2 cache (on reset)" in the OSD, on by default), slower than a
  real 7300's 604e. Speedometer 4.02 on Mac OS 7.6.1 gives CPU 2.50 and
  Math 106.8 against a Quadra 605, the FPU 3.57 against a Quadra 650.
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
