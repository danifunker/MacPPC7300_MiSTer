# MacPPC7300 for MiSTer

A Power Macintosh 7300 for the [MiSTer](https://github.com/MiSTer-devel)
FPGA platform (DE10-Nano). It runs Apple's own ROM, Mac OS 7.5.3 through
9.1, and PowerPC Linux.

The CPU is the core's own PowerPC 604-compatible processor (`DSPPC604`),
checked instruction by instruction against a real 604. Around it is the
7300's logic board: Hammerhead, Bandit, Grand Central, the Control video,
MESH SCSI, the MACE Ethernet, AWACS sound, the SWIM3 floppy controller, and
Cuda, a 68HC05 running Apple's original firmware.

## Which file

The bitstreams are in [`releases/`](releases/):

| File | CPU clock |
|---|---|
| `MacPPC7300_OC_20261022.rbf` | 100 MHz, about 40 % faster. Works on the DE10-Nano, MiSTer Pi and SuperStation. |
| `MacPPC7300_20261022.rbf` | 70 MHz, the speed the design is timed for. Use it on other hardware, or if the 100 MHz file gives a black screen, a grey screen or a crash at "Welcome to Mac OS". |

Both are the same machine and share the same `games/MacPPC7300/` folder and
OSD settings.

## Installing

1. Copy the `.rbf` to `/media/fat/_Computer/` (or `_Unstable/`) on the SD
   card.
2. Copy a Power Macintosh 7300 ROM image (4 MB, version `077D.34F2`) to
   `/media/fat/games/MacPPC7300/boot0.rom`. `releases/boot0.rom` is that
   ROM. A 7600 ROM (`077D.28F2`) works too.
3. Put a hard disk image (`.hda` or `.vhd` with an Apple partition map, as
   BlueSCSI uses) in `/media/fat/games/MacPPC7300/` and mount it from the
   OSD as "Pri. disk (ID 0)". A second disk can go on ID 1.
4. Optional: create an empty 8 KB file, for example
   `games/MacPPC7300/MacPPC7300.nvr`, and mount it under Advanced >
   "NVRAM image". Open Firmware's settings and Mac OS's startup disk are
   then kept between sessions.

The CD-ROM drive, Ethernet and file sharing need a MiSTer Main with
MacPPC7300 support (merged into the official Main as MiSTer-devel/Main_MiSTer
#1350); update your MiSTer if they are missing. With an older Main the core
still runs, without those three.

## What works

- **Mac OS 7.5.3, 7.6.1, 8.5, 8.6 and 9.1** boot to the Finder and shut down.
- **Debian 7.11 PowerPC** boots through BootX to its console and graphical
  login. It needs 124 MB of RAM, so a 128 MB SDRAM board. In BootX's
  options, turn "Force SCSI ON" off.
- **Video**: Apple's 16-inch (832 x 624, the default), 13-inch (640 x 480)
  and 12-inch (512 x 384) monitors. A 17-inch Multiscan (up to 1024 x 768),
  the 21-inch (1152 x 870) and a 20-inch Multiscan (up to 1152 x 870) are
  also offered. 256 colours, thousands and millions. Pick the monitor on the
  OSD's Video page; a Multiscan's resolutions are switched in Mac OS's
  Monitors control panel.
- **Sound**: the startup chime and Mac OS's sounds, through AWACS.
- **Hard disks**: two SCSI disks (IDs 0 and 1), read and write.
- **CD-ROM** (SCSI ID 3): ISO, Toast, CUE/BIN and CHD images. Data discs
  mount on the desktop and audio tracks play.
- **Floppy disks**: 400K, 800K, 720K and 1440K images, raw or DiskCopy 4.2.
  Read only.
- **Ethernet**: the Mac gets its own address on your network by DHCP.
  Choose the interface under "Network interface" (eth0 for the cable),
  then "Apply and reset".
- **File sharing with the MiSTer**: files in `games/MacPPC7300/shared/`
  can be copied in and out with the BlueSCSI Toolbox's "SD Transfer" app.
- **Serial port**: the modem port is the MiSTer's UART. Use it for PPP to
  the MiSTer (Mac OS Remote Access with "Null Modem 115200", the OSD's
  UART set to PPP at 115,200), for Open Firmware's console, or for MIDI to
  an MT32-pi (the OSD's UART set to MIDI).
- **Keyboard and mouse** as ADB devices, and the ADB game controllers Gravis
  MouseStick II, Firebird, Gravis GamePad and SideWinder 3D Pro from a
  MiSTer joystick (OSD Input page).
- **Clock**: Mac OS's clock is set from the MiSTer's at every start.
- **Power**: Shut Down turns the machine off (black screen). The keyboard's
  power key, or "Apply and reset", starts it again.
- **Memory**: 28 MB (any SDRAM board), 60 MB (64 MB board or larger) or
  124 MB (128 MB board); also 6 and 16 MB.
- **Cache**: a 128 KB L2 cache, on by default (OSD Machine page).

## What does not work (yet)

- Writing to floppy disks. They show as locked.
- Sound input. Recording gives silence.
- The printer port has no line, so there's no LocalTalk network or printer
  on it.
- No external SCSI bus and no PCI cards.
- The BlueSCSI Toolbox's CD changer app does not find the changer.
- Mac OS lists 1280 x 960 and 1280 x 1024 for the 20-inch Multiscan but
  stays in its current mode.
- Apple System Profiler does not show the L2 cache. It is there and works.
- The 100 MHz build may not run on boards other than the DE10-Nano, MiSTer
  Pi and SuperStation; use the 70 MHz build there.

## Keyboard

| PC key | Mac key |
|---|---|
| Alt | Command |
| Windows | Option |
| Menu | Power: opens Mac OS's shut-down dialog, or starts a machine that is off |
| Alt + Menu | NMI: MacsBug, if installed |
| Ctrl + Alt + Menu | Restart |

Alt and Windows can be swapped on the OSD's Input page. Hold Shift during
startup to start Mac OS with extensions off.

## Good to know

- **Shut Down from the Finder** before loading another core or switching
  the MiSTer off, as on a real Mac. Disk writes reach the image file about
  half a second after Mac OS makes them, and a disk that was not shut down
  is checked at the next start.
- Settings marked "Changes pending" (Memory, the Machine and Video pages,
  the controller, the network) take effect at "Apply and reset", or at the
  power key after a Shut Down. Use "Save settings" on the System page to
  keep them.
- The floppy image is not remembered between core loads; the hard disks,
  the CD and the NVRAM image are.
- For the 13-inch monitor on a 1080-line display, Scale "V-Integer" gives
  even lines. For the 16-inch, "Normal" with a sharp scaler filter looks
  best.

## Speed

An in-order core at 70 MHz is slower per clock than a real 604, which
issues several instructions per clock. Speedometer 4.02 on Mac OS 7.6.1:

| | 70 MHz | 100 MHz (OC) | Real 7300/120 |
|---|---|---|---|
| CPU (Quadra 605 = 1) | 3.82 | 5.48 | 7.80 |
| Math | 257 | 370 | 320 |
| FPU (Quadra 650 = 1) | 5.40 | 7.80 | 14.33 |

On integer work that is about half a real 7300 at 70 MHz. Mac OS's timing (sound, serial, the clock) stays correct at either
speed.

## Building

Quartus Prime 17.0 (Lite). The project is `MacPPC7300.qpf`. To build both
release files:

```
python syn\build.py 70 build70 --seed 3
python syn\build.py 100 build100 --seed 4
```

Each copies the project to `Scratch\NAME`, compiles it (about 25 minutes)
and prints the clocks' timing slack. `--seed N` picks the fitter seed;
`dual` builds a development bitstream with a CPU speed option in the OSD.

## Tests

The simulation benches use Verilator (run under WSL on Windows). The
reference models are built from [dingusppc](https://github.com/dingusppc/dingusppc)
and [MAME](https://github.com/mamedev/mame) checkouts next to this
repository.

| Command | What it checks |
|---|---|
| `python verilator\run.py` | the CPU's integer and floating-point units against the vectors recorded on a real 604 |
| `python verilator\run_core.py` | the CPU pipeline, caches, MMU and exceptions: golden programs, directed tests, random programs in lockstep with dingusppc, the SDRAM controller |
| `python verilator\run_machine.py` | the whole machine running the ROM in lockstep with dingusppc |
| `python verilator\run_gui.py` | the whole machine in a window, to watch it start |
| `python verilator\run_cuda.py` | Cuda's 68HC05 and firmware, instruction by instruction against MAME's 6805 |
| `python verilator\run_scsi.py` | MESH, its DMA, the disks, the CD-ROM and the floppy |
| `python verilator\run_escc.py`, `run_enet.py` | the serial port and Ethernet |
| `python syn\check.py core` | synthesises the CPU alone and reports its size and clock |

## Repository layout

| Path | Contents |
|---|---|
| `MacPPC7300.sv`, `.qsf`, `.sdc`, `files.qip` | the core's top level and Quartus project |
| `rtl/DSPPC604/` | the CPU |
| `rtl/machine/` | the 7300's logic board, devices and SDRAM controller |
| `rtl/machine/cuda/` | Cuda's firmware, Apple's 341S0060 |
| `sys/` | the MiSTer framework, unmodified |
| `releases/` | the bitstreams and the 7300 ROM |
| `syn/` | `build.py`, `check.py`, and `mister.py` for working with a MiSTer over the network |
| `verilator/` | the simulation benches and reference models |
| `ppctest/` | builds a test disk for a real PowerPC Mac and decodes its results; `ppctest/runs/` holds the golden 604 results |
| `hwprobe/` | a test disk that measures device behaviour on a real 7300 |
| `tools/misterdeploy/` | helpers for the MiSTer Remote |
| `docs/` | design notes: the CPU and machine plans, the sound path, and everything the machine leaves out (`MacPPC7300_stubs.md`) |

## Thanks

[dingusppc](https://github.com/dingusppc/dingusppc), the reference this
machine was checked against; MAME, for Cuda's firmware dump and its 6805
core; the MiSTer Macintosh Quadra 800 and Mac LC cores, whose CD-ROM, ADB
controller, MIDI and BlueSCSI Toolbox designs this core shares; Sorgelig's
SDRAM controller; and the MiSTer framework.

## License

GPL-2.0-or-later, as the MiSTer framework. `rtl/machine/cuda/341s0060.bin`
(and the ROM module generated from it) is Apple's Cuda firmware as MAME's
romset has it, and `releases/boot0.rom` is Apple's ROM; neither is covered
by that license.
