# CPU speed work on `speed-at`, 2026-10-10: results

Branch `speed-at`, on top of Dani's master at build 52 (52a3b44, merged in
5494427). All measurements are Speedometer 4.02 on the board (10.0.2.14),
Mac OS 7.6.1 from `pm761_speedo.hda` (the Fresh_PowerMac6100_761 image with
Speedometer added at the root), restored to the same bytes before every run,
CFG byte 0x1c (120 MB RAM, **L2 off**, Ethernet off), all tests selected,
single runs. KWhetstones varies about 15 % from run to run; the rest within
a few percent.

## Headline

| Build | Clock | CPU | Math | Benchmark Mix | FPU average | Color average |
|---|---:|---:|---:|---:|---:|---:|
| Release build 52 (`releases/MacPPC7300_20261010.rbf`) | 70 MHz | 2.459 | — | 8.384 | 3.515 | 1.209 |
| `speed-at` HEAD (9def284), release-style (no trace) | 70 MHz | **3.137** | — | **10.607** | **4.325** | **1.446** |
| ratio | | **1.28x** | | 1.27x | 1.23x | 1.20x |

The same CPU at 55 MHz, the step-by-step record of where the speed came
from (diagnostic builds with the trace and counters on; the original CPU
is Dani's master with the counters):

| | Original | AT (e30309d) | +BTB fix | +divider | +MMU (fcae664) | +32 KB I-cache |
|---|---:|---:|---:|---:|---:|---:|
| CPU | 1.910 | 2.301 | 2.326 | 2.326 | 2.403 | 2.433 |
| Math | 82.5 | 82.4 | 83.4 | 128.7 | 129.4 | — |
| Dhrystones/s | 35,516 | 34,160 | 38,412 | 39,262 | 47,537 | 48,311 |
| Towers (s) | .267 | .200 | .197 | .197 | .178 | .175 |
| Quick Sort (s) | .202 | .196 | .191 | .179 | .162 | .160 |
| Bubble Sort (s) | .359 | .360 | .355 | .353 | .298 | .294 |
| Queens (s) | .191 | .170 | .168 | .168 | .161 | .158 |
| Puzzle (s) | .348 | .398 | .393 | .392 | .298 | .293 |
| Permutations (s) | .330 | .270 | .247 | .247 | .229 | .226 |
| Int. Matrix (s) | .221 | .249 | .246 | .238 | .173 | .170 |
| Sieve (s) | .591 | .560 | .551 | .552 | .534 | .526 |
| Mix average | 6.638 | 7.685 | 7.382 | 7.404 | 7.997 | 8.294 |
| FP Matrix Mult. (s) | .225 | .228 | .244 | .230 | .180 | .177 |
| Fast Fourier (s) | .115 | .116 | .113 | .113 | .100 | .099 |
| FPU average | 2.750 | 2.589 | 2.791 | 2.852 | 3.301 | 3.380 |
| Color average | 0.991 | — | 1.045 | 1.047 | 1.114 | 1.169 |

(The original's AT column is the user's own run of the AT build; "Original"
is with the counters, 1.886 without.) With the L2 on, the MMU build gave CPU
2.451 against 2.403: Speedometer's timed loops fit in the caches, so the L2
and the bigger I-cache mostly help everything else (see the cycle account
below).

## What changed (commits on `speed-at` after the merge)

| Commit | Change | 300M-instruction ROM lockstep, cycles |
|---|---|---:|
| fcae664 and before | (state at the start of this session's last steps) | 465,268,986 |
| 594e606 | BTB: a redirect reads its target's set, so the first fetch after a misprediction is predicted | |
| 70d6b64 | Divider: radix 4, the dividend's leading zero pairs skipped: 4-19 clocks, was 35 (DIVW average 20 cycles, was 36) | |
| fcae664 | MMU: four cached data page translations, flushed only by translation-changing redirects (a mispredicted branch emptied the old one-entry cache: 2 cycles per page switch) | 465,268,986 |
| 05e7f0e | I-cache 32 KB (256 sets, the 604e's size; the 128-deep word RAMs were half-empty M10Ks, so no extra block RAM); BTB 512 entries (2 x 256) with the valid bits in the RAM row and a sweep after reset | 419,592,966 |
| e254c08 | Quartus 17 compatibility of the above | |
| 24964a7 | D-cache: write data and attributes taken whenever a request could be, not behind the late request (timing) | 419,592,966 |
| 9def284 | MMU: a data-side walk starts a cycle after the miss, from registers; D-cache address joins the payload (timing) | 419,825,552 |

Every commit: lint clean, `verilator/run_core.py` PASS (11,444 integer and
25,598 FP real-604 vectors among it), 300M ROM lockstep with dingusppc PASS.
The I-cache and BTB steps separately: 32 KB I-cache 453.5M (I-cache line
fills 4.28M -> 1.56M), + 256-entry BTB 432.1M, + 512-entry BTB 419.6M
(mispredictions 17.8M -> 11.3M); 9.8 % fewer cycles in all.

## Timing

Release-style builds (TRACE=0, PERF=0), seed 1, retiming off, four corners:

| Build | ALMs | 70 MHz worst setup slack (slow 100 C / -40 C) | Worst family |
|---|---:|---:|---|
| build 52 (Dani's record, builds 45-46) | ~35.7k | -1.35 to -2.25 | fetch address -> I-cache way RAMs / PLRU |
| HEAD at 05e7f0e+e254c08 | 35,622 | -3.520 / -3.608 | rb forwarding -> EA adder -> MMU's 4 page compares -> D-cache write-data enable |
| + 24964a7 | 35,522 | -2.138 / -2.333 | same EA family -> walker start, D-cache r_addr |
| + 9def284 (HEAD) | 35,286 | -2.434 / -2.549 | EX: forwarding -> ALU -> CR0 -> cr; ctr/forwarding -> branch -> pc_f |

The fast corners and every hold check pass. Like build 52, HEAD does not
close 70 MHz at the slow corners; like build 52 it runs at room
temperature on the board (Speedometer above, two full runs). At 55 MHz with
the trace on, the 32 KB I-cache build closes every corner (+0.053 ns) and
the 512-entry BTB build misses by -0.043 ns on one path at the cold corner.

The MMU/D-cache family introduced by fcae664 is gone from the 1000 worst
paths. What is left is the execute stage's own single-cycle work: a
record-form result's CR0 written in the same cycle as the ALU result
behind forwarding, and the branch decision (ctr, forwarded CR) into the
next fetch address. Cutting those means writing CR0 and resolving the
branch a cycle later, with the matching interlocks: a hazard change.

### Clocks beyond 70 MHz

100-120 MHz on the DE10-Nano's Cyclone V (speed grade C7, 84 % full) is a
different pipeline rather than a tuning pass: fetch and the data access in
two or three stages (translate, RAM read, tag compare and way select, each
about one cycle of logic today), a register-read/forwarding stage of its
own, a pipelined FPU, and the machine (MacPPC7300_system, on the CPU's
clock) on its own clock or closing at the new one. Deeper pipelines raise
the misprediction cost, which the 512-entry BTB now helps with. A realistic
target is 85-100 MHz.

## Against a real 7300

A real Power Mac 7300 (Speedometer: PPC604, 256 MB; reported as 120 MHz)
scored CPU 7.800, Mix 28.058, FPU average 14.329 (`docs/real_7300_speedometer.png`;
see also the 7300/120 reference in MacPPC7300_plan.md). Per clock against
HEAD at 70 MHz: CPU 3.137 x 120/70 = 5.38, **69 %** of the real chip's work
per clock; integer tests 63-75 %; Matrix Mult. and Fast Fourier about
**45 %**. The FPU (an unpipelined state machine of about eight cycles per
fadd/fmul/fmadd, against the 604's pipelined three) is the weakest part.

## The cycle account (board, `syn/perf.py`, segmented)

Speedometer is 68k code under the emulator. Two kinds of phase show up:

- The timed loops: CPI about 1.5, 1.6 I-cache misses per 1000
  instructions, 12 % of cycles after a redirect (mispredictions), 3-4 %
  load-use, 1.6 % multiply.
- Everything between (the emulator's dispatch through large code): CPI
  about 3, 45 I-cache misses per 1000 instructions, 35-40 % of cycles
  waiting for the fetch. With the L2 on these fall to CPI about 2.2 and
  15-24 %; the 32 KB I-cache cuts the line fills to a third in the ROM
  boot. These phases are most of what a user feels and little of the
  score.

## Next

1. **FPU pipelining** (new branch `fpu-pipe`): independent FP operations
   issued back to back, a result's dependants interlocked; fadd/fmul/fmadd
   latency down from about eight cycles. A hazard change: the user's
   go-ahead given 2026-10-10.
2. EX timing for a closed 70 MHz: CR0 of record forms a cycle later,
   branch resolution a cycle later (hazard changes, as above).
3. The remaining misprediction cycle: the fetch stage in front of the GPR
   read address (4 cycles per misprediction, 3 possible).

## Reproducing

- Board runs: restore `pm761_speedo.hda`, load the MGL, open PM6100,
  open Speedometer, dismiss the splash and "Not Yet", Cmd-A, Cmd-D, PM6100,
  Return, Return at the Graf notice, about two minutes. Always quit
  Speedometer without saving and shut Mac OS down (power key, Return)
  before loading another core.
- Lockstep: `machine_tb --machine --rom releases/boot0.rom --disk0
  QuadSquad8.hda --max-instr 300000000 --progress 50000000`.
- Screenshots of every run: `Scratch/perf/board55/pm761_speedo/` (not in git).
