# Speed work on `fpu-pipe`, 2026-10-12: cutting the clock's paths

Goal: raise the clock the core closes at (and the overclock it survives)
without giving back cycles. Every change below passes the FP and integer
vectors, run_core and the 300M-instruction ROM lockstep; the ROM boot's
cycle count is the cost measure (393.84M before, 394.43M after).

## Changes

| Commit | What | Path family it cut |
|---|---|---|
| ca69767 | MEM gets a second slot: room in MEM comes from registers; an access that has had its last grant (cannot fault any more) is passed by the next instruction; the memory unit keeps a second descriptor | D-cache hit -> answer -> MEM room -> EX leave -> ID -> fetch slots, BTB and fetch RAM addresses (the 60 and 65 MHz limiter, ~290 of the 1000 worst at 65) |
| df6fa7e | MMU compares a held address's page from the memory unit's registers | EX adder -> bus mux -> page compare (never used, but timed) |
| 191bbb8 | D-cache and I-cache data in even/odd word RAMs (altsyncram, 128-bit write with word enables, 32-bit read): a read gives the word asked for and the next, no 8:1 select of the line | cache address/forwarded line -> word select -> way select -> load bytes -> WB |
| e849cf0 | Memory crossing takes its ~290 request registers whenever idle | L2 answer -> port arbiter -> memory map -> L2 -> capture enable (~630 of the worst at 65) |
| 774a905 | EX's twelve forwarding selects are registers decided a cycle ahead (checked against the compares in simulation every cycle) | 7-bit compare in front of every operand mux |
| fa43a01 | External interrupt registered; "answered wide" from the cache's registers; mispredict compares both candidates beside the branch decision; uncached answers from a register (S_UANS) | interrupt sources -> EX exception -> unit starts (~400 at 65); CR -> 32-bit compare -> fetch; memory crossing data -> WB |
| 22b99be | MACE software reset a clock after its write | device write data -> GC decode -> sync clear of ~120 regs (~450 at 70) |
| 49020ca | Cache set compares in the answer's cycle; FPU exponent and tiny test made beside the normalising shift | EX adder -> set compare; FPU shift -> n_fix -> exponent -> state |
| 840c8b2 | tw/twi and string instructions take a second EX cycle, deciding their exception from registers | operand -> add -> string crossing -> ex_abort -> every commit and the redirect (~200 at 70) |
| 9b65cef | The cache takes a store's data in its lookup cycle, from the memory unit's descriptor (stfs conversion and byte placement there) | forwarding -> stfs conversion -> byte shift -> cache registers |

Tried and set aside: tags in MLABs (Quartus kept M10K); a per-page cache of
I-side translations (0.6 % more cycles; its path no longer limits).

## Timing (slow 100C, retiming on, seed 1)

| Tree | 65 MHz | 70 MHz |
|---|---:|---:|
| 8cc417d (start) | -1.22 | (-2.7 release-style) |
| + MEM slot | -1.75 | -2.29 |
| + crossing, banks, MMU | -1.28 | -2.65 |
| + selects, interrupt, wide, mispredict, uncached, MACE, sets | -1.93 | -2.60 |

Fit-to-fit noise is about 0.6 ns; each cut removed its family from the
worst 1000, and the next families are all within a few tenths of each other.

Also 0ac208c (the port's I/D owner select from registers) and 3e124ef
(BTB 1024 entries: ROM boot 385.99M cycles, -2.1 %).

Build 9b65cef at the clocks below (slow 100C, retiming on, seed 1):
65 MHz -1.21, 70 -2.29, 80 -3.32, 90 -5.23 ns.

## Board (mister14, Speedometer 4.02, L2 off), build 9b65cef

| | 70 MHz (older 632f644-era) | 80 MHz | 90 MHz |
|---|---:|---:|---:|
| CPU | 3.142 | 3.599 | 4.069 |
| Benchmark Mix | 12.120 | 13.667 | 15.294 |
| KWhetstones (mix) | | 26,759 | 29,821 |
| Dhrystones | | 73,667 | 83,151 |
| FPU average | 5.044 | 5.720 | 6.406 |
| Color average | 1.535 | 1.647 | 1.796 |

Both overclocks boot Mac OS and finish every test; 90 MHz showed no
"clock not set" alert this time (it did with the build of 2026-10-11).
Real 7300 reference (realspeedometer.png): CPU 7.800, Mix 28.058, FPU 14.329,
Color 3.135.

### 100 MHz (build 3e124ef: + I/D port select, BTB 1024)

Slow 100C: 70 MHz -2.22, 90 -5.15, 100 -6.38 ns. On the board at 100 MHz
(L2 off) Mac OS boots and Speedometer finishes every test (the 2026-10-11
build gave a black screen at 100):

| | 100 MHz |
|---|---:|
| CPU | 4.533 |
| Benchmark Mix | 16.606 |
| KWhetstones (mix) | 31,945 |
| Dhrystones | 93,084 |
| FPU average | 7.097 |
| Color average | 1.875 |

### MacBench 4 (6100/60 = 100), L2 on

| | 70 MHz (2026-10-11) | 90 MHz (9b65cef) | real 7300 |
|---|---:|---:|---:|
| Processor | | 148 | 271 |
| Floating Point | 98 | 126 | 214 |
| Graphics | 100 | 126 (about 16 min, completes) | 221 |
| Disk | | | 365 |
| CD-ROM | | | 693 |

At 90 MHz the core scores 55-59 % of the real 7300 (macbenchresults copy.png).
