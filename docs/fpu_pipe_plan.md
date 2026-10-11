# FPU pipelining (branch `fpu-pipe`)

Started 2026-10-10 from `speed-at` (2b899b5) with the user's go-ahead for
hazard changes in the FPU's path. On the board the FP tests run at about
45 % of a real 604's work per clock (Matrix Mult., Fast Fourier), against
63-75 % for the integer tests (`docs/speed_results_20261010.md`).

## Step 1, done: latency inside the unit

No handshake changed; the FPU still holds EX until it answers.

| Dependent chain, cycles per operation (core bench) | before | now |
|---|---:|---:|
| fadd (growing sum) | 8 | 6 |
| fadd, terms of similar size | 9 | 6 |
| fmul | 7 | 5 |
| fmadd | 8 | 6 |
| fdiv | 34 | 32 |
| lfd, lfd, fmadd on the sum (a loop) | 12 | 9 |

- c688655: S_SHIFT only for integers and denormals (a normal result's
  rounding point is fixed); the result answered from S_ROUND, a cycle
  before S_DONE.
- 39c8b4c: an effective addition skips S_LZC (no cancellation possible:
  count for the place above the larger term, correct by one in S_NORM).

25,598 FP and 11,444 integer real-604 vectors, run_core and the 300M ROM
lockstep pass after each. The microbenchmark is
`fpbench.py` (scratch; the programs are straight `progs.py` code).

What is left in the unit: start -> MUL1 -> MUL2 -> ADD -> NORM -> ROUND
(answer). fmul skips ADD. The 604 does 3 cycles, pipelined.

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
