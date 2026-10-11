# FPU pipelining (branch `fpu-pipe`)

Started 2026-10-10 from `speed-at` (2b899b5) with the user's go-ahead for
hazard changes in the FPU's path. On the board the FP tests run at about
45 % of a real 604's work per clock (Matrix Mult., Fast Fourier), against
63-75 % for the integer tests (`docs/speed_results_20261010.md`).

## Step 1, done: latency inside the unit (and the dividers)

No handshake changed; the FPU still holds EX until it answers.

| Dependent chain, cycles per operation (core bench) | before | now |
|---|---:|---:|
| fadd / fsub | 8 | 5 |
| fadd, terms of similar size; a - b, b larger | 9 | 5 |
| near-equal subtraction (cancellation possible) | 9 | 6 |
| fmul | 7 | 5 |
| fmadd | 8 | 6 |
| fdiv (double) | 34 | 18 |
| lfd, lfd, fmadd on the sum (a loop) | 12 | 9 |
| divw, worst case (a real 604: 20) | 20 | 12 |
| divw, typical (1000000/1000, 123456789/98765) | 14-18 | 7 |

- c688655: S_SHIFT only for integers and denormals; the result answered
  from S_ROUND, a cycle before S_DONE. 9aa91ed corrects its claim that
  nothing new reached the redirect: EX traps at the instruction that sets
  FEX when MSR[FE0,FE1] allow it, so the early answer is used only while
  traps are off (Mac OS's normal state), and FEX for the trap comes from
  S_DONE's registers.
- 39c8b4c, d3ae710: effective additions, and subtractions of terms two or
  more places apart, skip S_LZC (count for the larger term's top, correct
  by one place in S_NORM).
- 76dab1c, 02ae566: fadd/fsub skip the multiplier (S_ALGN: distance and
  aligned addend in one cycle, the sticky bit from the addend's trailing
  zeros).
- 0726953: the FPU divider takes two radix-4 steps a cycle.
- 7fe2361, 171c278: the integer divider skips the quotient digits the
  divisor's size makes zero, and takes two radix-4 steps a clock (the
  board's Whetstone-like phase waited 31.6 % of its cycles on it).

Each passes the 25,598 FP and 11,444 integer real-604 vectors, run_core and
the 300M ROM lockstep. The microbenchmarks are `fpbench.py` and
`divbench.py` (scratch; plain `progs.py` programs).

What is left in the unit: fadd start -> ALGN -> ADD -> NORM -> ROUND;
fmul start -> MUL1 -> MUL2 -> NORM -> ROUND; fmadd with ADD as well. The
604 does 3 cycles, pipelined.

On the board at 70 MHz (release-style builds, same image and settings as
docs/speed_results_20261010.md):

| | build 52 | speed-at 9def284 | fpu-pipe 2ae6056 | fpu-pipe 02ae566 |
|---|---:|---:|---:|---:|
| CPU | 2.459 | 3.137 | 3.143 | 3.140 |
| FPU KWhetstones/s | 17,064 | 21,274 | 24,222 | 26,689 |
| Matrix Mult. (s) | .175 | .138 | .127 | .125 |
| Fast Fourier (s) | .089 | .077 | .069 | .067 |
| FPU average | 3.515 | 4.325 | 4.787 | **5.033** |
| Mix KWhetstones/s | 15,666 | 19,526 | 21,626 | 23,948 |
| Mix average | 8.384 | 10.607 | 11.322 | **12.131** |

## Step 2, the overlap: what it takes

Today EX holds an FP instruction until the FPU answers, and commit is in
order: the trace (one architectural snapshot per completed instruction,
followed by dingusppc in lockstep) depends on it. The AT completion queue
lets simple ALU instructions run ahead of a long operation into eight
speculative entries that drain after it commits; FP instructions, loads,
stores and branches cannot, so in an FP loop (lfd, lfd, fmadd, bdnz) nothing
overlaps the fmadd.

Ways to overlap, cheapest first:

1. **A second FP operation behind the first, in the completion queue's
   manner.** The FPU accepts an independent FP operation while the first
   is in ADD or later (a two-deep pipeline: the multiplier free after
   MUL2). The younger one's result waits in a queue entry until the older
   commits, then commits in order. Needs: a 64-bit value and FPSCR/CR1
   effects per entry, the FPSCR's sticky bits merged in order, FPR
   dependency checks against the entries. No trace change.
2. **Loads behind a long operation.** A cacheable load executed
   speculatively into a queue entry (its fault, if any, carried and taken
   at commit). Cache-inhibited loads (device registers) must not run
   ahead. Needs the memory unit to accept a request whose commit is
   deferred, and ordering against older stores.
3. **Branches behind it**, resolved speculatively with the redirect held
   until commit.

1 alone helps Whetstone's and the FFT's independent operations; matrix
multiply also needs 2. Each is a hazard change with its own interlocks;
each lands with the vectors, the FP random programs, run_core and the ROM
lockstep, and a board run.

### Whether it pays for Speedometer

Speedometer's FP tests are 68k code; every FP operation is emulated
(SANE): operands loaded, one FP operation, its result stored soon after.
A store of a pending result waits either way, so overlap gains little
there, while each operation's latency counts in full. The board's
Whetstone-like phase also waits on the integer divider for a third of its
cycles (SANE's extended arithmetic, most likely). Hence step 1 went to the
latencies and the dividers first. Overlap stays the plan for native FP
code (option 1 above), after measuring how much of it the board runs.

## Timing notes

At 70 MHz no FPU path is among the 1000 worst after step 1. The fits of
2026-10-10 (release-style, seed 1, 84-85 % ALMs) swing by about 0.7 ns
between near-identical sources: -2.43, -3.31, -3.09, -3.13 ns. Each time
the worst family is the effective address (forwarding -> adder -> the
MMU's four page compares) deciding something in the same cycle: first the
D-cache's write data enable (cut in 24964a7), then the walker's start and
the cache's address (9def284), then the fault's DSISR/DAR registers (cut
on this branch), now the MMU's and the memory unit's own state bits.
Those cannot take the payload trick: closing 70 MHz needs the effective
address registered before translation (a cycle on every load, or a
carry-free sum-and-compare for the page match), or EX's other families
(forwarding -> ALU -> CR0, branch -> pc_f) cut too.

## Integer notes (same branch)

- 89ab4ba, bcctr predicted to CTR when no CTR write is in flight: the ROM
  boot's mispredictions -2.2 % (its worst sites are Open Firmware's Forth
  NEXT, mtctr three instructions before bctr, still in flight). On the
  board (55 MHz with the counters) Speedometer's misprediction rates are
  unchanged in every phase (timed loops 30 % of branches, big-code phases
  24-32 %), CPU 2.445 against 2.446: Mac OS's mispredicted branches are not
  bcctrs with an early CTR. Kept (small, prediction only), worth nothing
  measurable there.
- The big-code phases wait 20-27 % of their cycles for instruction fetch
  with L2 off (about 22 cycles a line fill at 55 MHz); the 32 KB I-cache
  cut their line fills from about 45 to 25 per 1000 instructions. Next
  candidates: next-line instruction prefetch, or the L2 (on by default;
  the test settings keep it off).

