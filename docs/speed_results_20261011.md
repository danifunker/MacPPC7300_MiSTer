# Speed work on `fpu-pipe`, 2026-10-11

## MacBench's hangs: the VIA's timer flag (2c1bea4)

MacBench 4's Floating Point test hung at 60 and 70 MHz (and on release 54),
and the user saw its Graphics test hang too. CPU samples taken during a hang
(trace kind 14, `syn/cpusample.py`) and MacBench's code from its CD showed
where:

- The FP test's driver (06F03434 in that run) calls `Microseconds`, the
  kernel through a function pointer, `Microseconds` again, and adds the
  difference until the sum passes 10,000,000 µs. The kernel (a 16 x 16
  matrix inversion) returned every time; the sum never got there.
- Its 64-bit subtract (06F033F0) stores nothing when the high words differ
  and the low word did not wrap, so one bad `Microseconds` reading can put
  a huge value into the sum.
- `Microseconds` is InterfaceLib's glue (ROM FFD636A0) to the 68k trap
  A193, which reads VIA T2's high byte and then the interrupt flags.

The VIA (copied from dingusppc) set T2's flag two VIA clocks after its
counter wrapped, so FFFF and FFFE could be read with the flag still clear,
and Mac OS then counted a whole timer period wrongly. A 6522 sets the flag
as the counter goes from 0 to FFFF; MAME's 6522 holds the counter at 0
until the flag sets, with the comment that Mac OS reads T2CH and then IFR.
The core now does as a 6522 (T1 too: flag at the wrap, a free-running
reload a clock later).

On the board, 70 MHz with L2 on, which had hung four times out of four:

| MacBench 4 (6100/60 = 100) | before | now |
|---|---:|---:|
| Floating Point | hang | **98** (about 73 s) |
| Graphics | hang (the user's run) | **100** (about 20 min) |

And at 60 MHz with L2 on (HEAD ca741e4, which also hung before): Floating
Point **83**, in about 55 s.

## Speedometer 4.02: L2 on vs off, 60 MHz (timing-closed build, 41f4965)

| | L2 off | L2 on |
|---|---:|---:|
| CPU | 2.680 | 2.701 |
| Benchmark Mix | 10.525 | 10.711 |
| FPU average | 4.321 | 4.415 |
| Color average | 1.274 | 1.346 |

L2 is worth 1-5 %; the clock and the CPU's work per clock matter more.

## Speedometer 4.02 at 70 MHz, L2 off

| | speed-at 9def284 | fpu-pipe 02ae566 | fpu-pipe 632f644-era build (VIA, posted stores, FPSCR cut) |
|---|---:|---:|---:|
| CPU | 3.137 | 3.140 | 3.142 |
| Benchmark Mix | 10.607 | 12.131 | 12.120 |
| FPU average | 4.325 | 5.033 | 5.044 |
| Color average | 1.446 | — | **1.535** (8-bit 6.616 s, 16-bit 9.249 s) |

## Speedometer 4.02 at 60 MHz, L2 off: HEAD (ca741e4) against 41f4965

| | 41f4965 | ca741e4 |
|---|---:|---:|
| CPU | 2.680 | 2.679 |
| Benchmark Mix | 10.525 | 10.535 |
| FPU average | 4.321 | 4.326 |
| Color average | 1.274 | **1.366** (+7 %) |
| Eight bit (s) | 7.994 | 7.478 |
| Sixteen bit (s) | 11.105 | 10.329 |

## Changes

- 2c1bea4 VIA timers as a 6522's (above).
- a0da146 The data cache posts a word store that memory must get
  (cache-inhibited: device registers and the frame buffer; write-through;
  the cache off) from a one-entry buffer and goes on; anything that next
  wants the memory port waits for it, and `sync` waits in EX. ROM boot
  397.66M -> 393.43M cycles. Same commit: with FP traps on (MSR FE0/FE1),
  mtfsf and the other FPSCR instructions take a second cycle so the trap
  decision comes from a register (a 65 MHz worst-path family).
- 0af0965 The sequencer's last operation from the opcode bits, not the
  decoder (ID's handshake off the decoder; checked against the decoder in
  simulation with `$fatal`).
- b61b8a0 Video: scan-out bursts of 32 words instead of 128, taking turns
  with the CPU's frame buffer accesses.
- 632f644 A device's word answer from a register (the 60 MHz fit's worst
  path, -0.247 ns), one cycle more per device access.

All pass the FP and integer vectors, run_core and the 300M ROM lockstep
(the machine changes also with `--vram-check`).

## Timing

| Build | Clock | Slow 100C worst | Notes |
|---|---:|---:|---|
| 41f4965, retiming on, seed 1 | 60 | +0.039 | closed |
| 2c1bea4+a0da146, seed 1 | 60 | -0.247 | 9 paths: device read mux (cut in 632f644), mem_valid -> MMU |
| same | 65 | -2.11 | |
| same, release-style | 70 | -2.74 | |
| ca741e4, retiming on, seed 1 | 60 | -0.223 | 8 paths, all the D-cache hit -> MEM-stage family below |

The family that now sets the clock is a D-cache hit deciding, in the same
cycle, whether the pipeline advances: tag RAM -> hit -> the answer ->
the memory unit's `req_ready` -> `id_to_ex` -> EX's registers (about 230
of the 1000 worst paths at 65 MHz). Registering the cache's answer
(`LATE_ANSWER`) costs 8.4 % of the ROM boot's cycles (393.4M -> 426.6M),
more than the clock it would buy. The alternative is a second request
slot in the memory unit, so that EX can hand over the next access
whatever this cycle's hit says. That changes the pipeline's hazards and
waits for the user's go-ahead.
