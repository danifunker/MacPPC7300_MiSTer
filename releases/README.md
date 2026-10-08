# PPCMac releases

Test builds of the Power Macintosh 7300/7600 core for the MiSTer
(DE10-Nano), each with the Main binary it was tested with.

| File | Date | md5 | What it is |
|---|---|---|---|
| `PPCMac_20261008b.rbf` | 2026-10-08 | `08e29d97f36a24026b0c1782477a043f` | The second test build (build 20, commit `7dcfbf0`): Mac OS 7.6.1, 8.5, 8.6 and 9.1 boot from SCSI disk images to the Finder; the CD-ROM (ISO, CUE/BIN with CD audio), Ethernet (DHCP, web, FTP), the BlueSCSI Toolbox's file sharing, ADB game controllers, MIDI and the MT32-pi, the 12-inch monitor. The first build (`PPCMac_20261008.rbf`, 7.6.1 only) is in git's history. |
| `MiSTer` | 2026-10-08 | `a2546ea7d3d5a3a1338187f41d327044` | The Main this build was tested with: the official MiSTer-devel Main with two commits for this core (branch `Mac-ppc-enhancements`, `7b3a601`): the core joins the Mac SCSI family (the CD-ROM through the Mac CD layer, the BlueSCSI Toolbox, local time with daylight saving) and its Ethernet frames go through the Main. The CD-ROM and Ethernet need it; with an official Main the core runs without them. |

## Installing

1. Copy `PPCMac_20261008b.rbf` to `/media/fat/_Unstable/` (or `_Computer/`)
   on the SD card, as `PPCMac.rbf` or under its own name.
2. For the CD-ROM and Ethernet: keep a copy of your `/media/fat/MiSTer`
   (for example as `MiSTer.official`), copy `MiSTer` from here in its
   place, then reboot the MiSTer. Your other cores keep working: it is the
   official Main with this core's additions. To go back, copy yours back.
3. The ROM: the core needs a Power Macintosh 7300 or 7600 ROM image (4 MB:
   `077D.34F2` from a 7300, or `077D.28F2` from a 7600) as
   `/media/fat/games/PPCMac/boot.rom`. `boot0.rom` here is the 7300's
   (`077D.34F2`, md5 `edcf3422d712f61f83c07efc2401cbb8`); copy it into
   `/media/fat/games/PPCMac/` (the Main loads `boot0.rom` and `boot.rom`
   alike).
4. A disk: a SCSI hard disk image (`.hda` or `.vhd`, 512-byte blocks, an
   Apple partition map; the BlueSCSI-style images of Mac OS 7.5.3 to 9.1
   work as they are) in `/media/fat/games/PPCMac/`, mounted from the OSD:
   "Mount SCSI disk 0" (and "Mount SCSI disk 1" for a second one). The
   Main remembers them.
5. Optional, the NVRAM (Open Firmware's settings, Mac OS's PRAM): an 8 KB
   file of zeros, for example `/media/fat/games/PPCMac/PPCMac.nvr`, mounted
   from the OSD: "Mount NVRAM". The core loads it at its start and writes
   the NVRAM back into it two seconds after any change.
6. Optional, a CD (needs the Main from here): an `.iso`, `.toast`,
   `.cue`/`.bin` or `.chd` image, mounted from the OSD: "Mount CD-ROM". It
   is SCSI ID 3; Apple's CD-ROM driver (in Mac OS's Extensions) shows it
   on the desktop, the AppleCD Audio Player plays its audio tracks.
7. Optional, file sharing with the MiSTer (needs the Main from here): put
   files in `/media/fat/games/PPCMac/shared/` and use the BlueSCSI
   Toolbox's Mac app ("BlueSCSI SD Transfer") to copy them in and out.
8. Optional, Ethernet (needs the Main from here): OSD "Ethernet (on
   reset)" On, "Net interface" the MiSTer's (eth0 for the cable), then the
   core's Reset. The Mac gets its own address on your network (Open
   Transport's TCP/IP, "Using DHCP Server").

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
- No floppy disks yet (coming), no PCI cards.
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
- The CPU is the core's own 604-compatible design at 65 MHz, slower than
  a real 7300's 604e (not measured yet).
- Scale (OSD): V-Integer gives even lines for the 13-inch 640 x 480 on a
  1080-line display; for the 16-inch 832 x 624 Normal with a sharp scaler
  filter looks best.
- Known: when the core is loaded with an NVRAM image mounted, the startup
  chime may play twice. If the picture starts in four strips, please say
  so on Discord: this build has a fix for that we could not test.
