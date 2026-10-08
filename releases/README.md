# PPCMac releases

Test builds of the Power Macintosh 7300/7600 core for the MiSTer
(DE10-Nano), each with the Main binary it was tested with.

| File | Date | md5 | What it is |
|---|---|---|---|
| `PPCMac_20261008.rbf` | 2026-10-08 | `d8b9fa6c4e7193ef4845054d352eb9ee` | The first test build: Mac OS 7.6.1 boots from a SCSI disk image to the Finder with every extension (Open Transport included), the startup chime plays, Shut Down works, the NVRAM is kept on the SD card. Commit `0efe945`. |
| `MiSTer` | 2026-10-07 | `4704874bf6105223b315fbf55844f2fc` | The official MiSTer-devel Main, master of 2026-10-07 (the same binary as MiSTer-devel/MacQuadra800_MiSTer's `releases/MiSTer`). The core was tested on a Main of 2026-10-06; it needs nothing beyond the stock Main. |

## Installing

1. Copy `PPCMac_20261008.rbf` to `/media/fat/_Unstable/` (or `_Computer/`)
   on the SD card, as `PPCMac.rbf` or under its own name.
2. Optional: replace `/media/fat/MiSTer` with `MiSTer` from here (keep a
   copy of yours), then reboot the MiSTer. Any recent official Main works.
3. The ROM: the core needs a Power Macintosh 7300 or 7600 ROM image (4 MB:
   `077D.34F2` from a 7300, or `077D.28F2` from a 7600) as
   `/media/fat/games/PPCMac/boot.rom`. `boot0.rom` here is the 7300's
   (`077D.34F2`, md5 `edcf3422d712f61f83c07efc2401cbb8`); copy it into
   `/media/fat/games/PPCMac/` (the Main loads `boot0.rom` and `boot.rom`
   alike).
4. A disk: a SCSI hard disk image (`.hda` or `.vhd`, 512-byte blocks, an
   Apple partition map; the BlueSCSI-style images of Mac OS 7.5.3 to 9.1
   work as images) in `/media/fat/games/PPCMac/`, mounted from the OSD:
   "Mount SCSI disk 0". The Main remembers it.
5. Optional, the NVRAM (Open Firmware's settings, Mac OS's PRAM): an 8 KB
   file of zeros, for example `/media/fat/games/PPCMac/PPCMac.nvr`, mounted
   from the OSD: "Mount NVRAM". The core loads it at its start and writes
   the NVRAM back into it two seconds after any change.

## What works, what does not

- Mac OS 7.6.1 boots to the Finder: the video (832 x 624 or 640 x 480,
  the OSD's Monitor), the keyboard and mouse (ADB), the SCSI disks, the
  startup chime, the clock (set from the MiSTer's), the serial port (the
  modem port on the MiSTer's UART). Mac OS's own sounds are not tested yet.
- Mac OS 8.6 and 9.1 stop at a grey screen before the welcome screen.
- No CD-ROM, no floppy disks, no network (Ethernet is there with its cable
  unplugged), no PCI cards.
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
  chime may play twice.
