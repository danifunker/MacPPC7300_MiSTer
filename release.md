# MacPPC7300 release notes

The bitstreams are in `releases/`. Installing (the ROM, disks, the Main
binary for the CD-ROM and Ethernet) is as in `releases/README.md`.

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
