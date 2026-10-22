# MacPPC7300 release notes

The bitstreams are in `releases/`. Installing (the ROM, disks, the Main
binary for the CD-ROM and Ethernet) is as in `releases/README.md`.

## 2026-10-21

Two bitstreams of the same source (branch `ibm-learnings-osd-ppp`), each at
one fixed speed (no CPU speed option any more):

| File | md5 | CPU speed |
|---|---|---|
| `MacPPC7300_20261021.rbf` | `7b0735e6c4cef48fb1ae462116c14402` | 70 MHz, the speed the design is timed at (fitter seed 3) |
| `MacPPC7300_OC_20261021.rbf` | `1e2b06b558a10b71b42f442e615a6d2c` | **100 MHz, an overclock** (fitter seed 4): faster, but whether a fit runs at 100 depends on the fit; if it misbehaves on your board, use the other file and say so on Discord |

Both identify as MacPPC7300 (the same `games/MacPPC7300/` folder and
settings). **Your OSD settings start over once** (the menu changed): set
the Memory and the disks again.

New since 2026-10-16:

- **PPP and serial on Mac OS work.** Mac OS's serial driver moves its bytes
  through Grand Central's DMA channels 4-7, which were missing: Mac OS 9.1
  froze the moment Remote Access opened the modem port. They are DMA
  engines now, and their receive side does what the user's real 7300 was
  measured doing when software stops the channel (`hwprobe --dbdma`). With
  the OSD's UART set to PPP at 115,200 and Remote Access on "Null Modem
  115200": connected in a second, pings from the MiSTer, a 92 KB web page
  from a server on the MiSTer complete in Internet Explorer.
- **The OSD follows the MiSTer computer cores' standard menu**: the disks,
  Load ROM, Memory and Network interface on the top page; Machine, Video,
  Input (new: Swap Alt/Win keys), Audio (the MT32-pi) and Advanced (the
  NVRAM image) pages; settings that need a restart show "Changes pending"
  until "Apply and reset".
- **SDRAM byte writes** (found by the IBM RS/6000 core, which shares this
  controller): the MiSTer SDRAM boards take a write's byte masks on two
  address lines the controller left at 0, so a single-byte or halfword
  store to uncached memory wrote the whole word. Fixed.
- The CPU carries the RS/6000 core's little-endian mode, switched off here.
- Known: Mac OS 9.1 and 7.6.1 say "Your clock is not set to the correct
  time" at every start but a restart right after setting the time, and
  close the alert by themselves. The clock is right and the year is not the
  cause: the core writes the MiSTer's time into Cuda's clock bytes but not
  the "time set" flag (Cuda RAM A1 bit 4) that Cuda's SET_REAL_TIME sets
  with them, and Mac OS asks Cuda for that flag. Fixed after this release.
- Seen once, not reproduced: a Restart from Mac OS 9.1 right after a PPP
  session stopped at the Finder (Apply and reset recovered it).

Tested on the board (DE10-Nano, 128 MB SDRAM, RAM 124 MB):

- OC build: Mac OS 7.6.1 cold starts 5 of 5 (61-62 s to the Finder), Mac
  OS 9.1, the chime, the OSD.
- 70 MHz build: Mac OS 7.6.1 cold starts 3 of 3 (70 s), Mac OS 9.1,
  Ethernet (DHCP), PPP (connected in 5 s, a 92 KB page complete, pings 20
  of 20 and 10 of 10 at 1,000 bytes), the chime, the OSD ("Changes
  pending", Apply and reset).

## 2026-10-16

Two bitstreams of the same source (branch `fpu-pipe2`, 3f2dab7 plus the
build modes below):

| File | md5 | CPU speed |
|---|---|---|
| `MacPPC7300_20261016.rbf` | `ea88aa498918ecabd12113c0f3e14c00` | **Dual speed**: OSD "CPU speed (on reset)", 70 MHz (the default) or 100 MHz, taken at the next Reset or power-on, as in the 2026-10-15 release. Built and timed at 70 (fitter seed 2). |
| `MacPPC7300_20261016_100MHz.rbf` | `395ffb2c6a1ddd6d70a707da8bb92038` | **100 MHz only**: the PLL is built for 100 MHz and never reconfigured; the OSD has no speed option. For boards where the dual build's 100 MHz misbehaves (reported on Discord for QMTech and other third-party boards): if the PLL's reconfiguration is the trouble there, this build avoids it. |

New since 2026-10-15:

- **The FPU overlaps its work.** The FPU is split in two halves, so a second
  operation computes while the first is rounded, and an FP operation that
  writes a register leaves the pipeline's execute stage for the completion
  queue as soon as the unit takes it: independent instructions behind it,
  FP or not (integer work, branches, compares), go on while it computes,
  committed in order. Independent fadd/fmul/fmadd streams went from 5.25
  (fmadd 6.25) to 3.27 cycles an operation; dependent chains are unchanged.
- **The eleven timing cuts** of the 2026-10-15 CPU session (no cycle changes).
- Speedometer 4.02 on Mac OS 7.6.1 at 70 MHz (this source, the build before
  the reseed): CPU 3.817, Math 257.2, the Benchmark Mix 15.26 (14.71 in the
  2026-10-15 release), Color 2.141, FPU 5.528 (5.404). MacBench 4's FP test
  does not move: its code is loads and stores around each operation.

Tested on the board (DE10-Nano, 128 MB SDRAM, RAM 124 MB):

- Dual build at 100 MHz: Mac OS 7.6.1 to the Finder 3 of 3 (45-61 s);
  Debian 7.11 to sshd's start in 181 s, no kernel errors, a clean restart.
- 100 MHz-only build: Mac OS 7.6.1 3 of 3 (45-61 s); Debian to sshd in
  197 s, no kernel errors, a clean restart.
- The same source at 70 MHz (an earlier fit): 10 of 10 cold starts.

**100 MHz is an overclock and depends on the fit.** The design is timed at
70 MHz; at 100 a fit either starts or not. Of four fits of this source,
two start at 100 MHz on our board and two do not (one never shows a
picture, one stops at the ROM's grey screen now and then); these are the
two that do. If 100 MHz misbehaves on your board (a black screen, a grey
screen, a bomb at "Welcome to Mac OS"), use 70 MHz and say so on Discord,
naming the board and which of the two files.

## Building

`python syn\build.py MODE NAME [--seed N]` copies the project to
`Scratch\NAME` and compiles it (about 25 minutes; two side by side are
fine), leaving `Scratch\NAME\MacPPC7300_MODE.rbf`:

- `dual`: the OSD's 70 / 100 MHz choice (the default source, timed at 70);
- `100`: 100 MHz only (the `MACPPC_SPEED_100` macro; the CPU and memory
  clocks become one counter of the PLL);
- `70`: 70 MHz only (`MACPPC_SPEED_70`).

It prints the CPU and memory clocks' setup slack. Try a new fit at 100 MHz
on the board before releasing it: a fit that misses the memory clock (two
of two so far) has been one that fails at 100.

**Every release from 2026-10-21 on is two fixed-speed bitstreams** (the
user's decision: the OSD's speed toggle does not work well enough), of the
same source: `MacPPC7300_YYYYMMDD.rbf` (`build.py 70`, the design's speed)
and `MacPPC7300_OC_YYYYMMDD.rbf` (`build.py 100`, the overclock: OC in the
name, the user's naming). Both keep the core name MacPPC7300 (the same
`games/MacPPC7300/` folder and settings). No dual build is released; `dual`
stays for development only.
