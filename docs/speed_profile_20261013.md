# A profile of Speedometer, and the frame buffer's path (2026-10-13, `fpu-pipe`)

## The branch today

`fpu-pipe` took the timing cuts of `addr-stage` that cost nothing per
clock (becef81..f90f09f: WB's payload every cycle, the DSI from the MMU's
register, stfs converted per source, a rotator each way, MEM's forwarding
selects without `mem_leave`, the ITT's commit a cycle late and its index
pre-folded, the FPU's sticky bits beside `n_fix`, the memory unit's
two-word bit and its free descriptor written every cycle) and the
optional L2 (`L2_KB = 0`). At 100 MHz the fit closed at −5.60 ns (87 %),
a nanosecond better than before, and the board scores were unchanged:
CPU 5.388, Mix 16.90, Dhrystones 5.66, FPU 6.98, Color 1.920 (`W100`).

## The profile

A build with the DDR3 trace and the CPU's counters (`TRACE = 1, PERF =
1`, 90 MHz, −5.73 ns) ran Speedometer while `syn/mister.py
trace-capture` read the ring (the reader now copies it in bulk: with the
CPU's samples it is about 1,800 records a second, and reading a record
at a time lost most of them; no screenshots while the tests run either).
`syn/perf.py --csv` gives one line per 2^23 cycles (93 ms at 90 MHz);
one-second bins over the run:

| Phase | seconds | CPI | where the cycles go |
|---|---:|---:|---|
| CPU test (68k) | 4 | 1.2 | fetch 8–10 %, mispredicts 3.5 % of branches: a tight, well-predicted loop |
| Math | 2 | 2.0–2.4 | FPU 19–26 %, divides 15–21 % |
| Disk | 2 | 3.4–4.1 | data cache busy 45–62 %, doubles 10–15 per 100 instructions |
| Benchmark Mix | 18 | 1.2–1.5 | mispredicts 10–27 % in the sorts and puzzles, load-use 4–10 % |
| FPU | 5 | 1.5–1.7 | FPU 9–20 % |
| **Color (8 and 16 bit)** | **15** | **4.5–9.3** | **data cache busy 60–74 %**, doubles up to 45 per 100 instructions, a memory transaction every other instruction |
| then the idle event loop (Finder, toolbox: 68k) | — | 2.88 | fetch 28 % (26 I-cache misses per 1,000 instructions), data misses 19 % (21 per 1,000), mispredicts 27.6 % |

So the Color tests are not drawing-bound: they are bound by the frame
buffer's path. Every word or byte a program stores to the screen was a
whole round trip through the clock crossing (about fifteen cycles at
100 MHz) before the next could go, and QuickDraw moves doubles, two words
each. And the code that gives the machine its feel — the Finder and the
toolbox, 68k code under the emulator — runs at CPI 2.88 with a quarter of
its cycles waiting for instruction fetch.

**The L2 cache.** The same profile with the L2 on (the OSD's option; the
hangs it was blamed for were the VIA timer bug, fixed 2026-10-11): the
idle loop's CPI 2.88 → 2.17 (fetch 20 %, data misses 12 %), and the
scores at 90 MHz: CPU 4.846 → 4.890, Mix 15.51 → 15.89, FPU 6.31 → 6.49,
Color 1.861 → 2.010 (+8 %). It costs nothing now; it should be on.

## The frame buffer's write combiner (345e52c, 9ba6338)

`MacPPC7300_vramwc`, between the machine's VRAM port and its crossing. A
store is taken into a register stage and answered the next cycle, then
goes into one of eight 32-byte line entries (a store to a line held
merges into it); the entries are a FIFO drained whenever the crossing is
free, as line writes with a byte mask (the crossing's byte enables are a
parameter, 32 for the VRAM's; the video's DDR3 beats take the mask), so a
run of stores reaches the DDR3 at up to eight words a transaction and a
lone store a few cycles after it was made. A load waits for the entries
to drain, brings its whole line and keeps it: the loads that follow of
the same line are answered from it until a store touches that line, so a
copy from the screen costs one transaction in eight. A load sees every
earlier store.

Checks: its own bench (`make vramwc`: random word, byte and line stores
and loads against a model, the memory compared at the end), and the
machine bench's `--vram-check`, which now also compares the DDR3's frame
buffer byte by byte with what the CPU wrote at the end, with the picture
of the boot identical to the baseline's. (The bench's DDR3 model used to
fold the trace's ring, at 0x30500000, into the VRAM by taking addresses
modulo its size; the differences that showed were that.) The ROM boot,
whose screen fill is 614k word stores 99.8 % sequential, 317.25M →
315.18M cycles.

The first build on the board showed a black screen: the fit's worst path
ran from the CPU port's I/D choice through the machine's decode into the
combiner's tag compares and entry registers, and a store's acceptance
decided unevenly there leaves the entry count wrong and the first screen
store waiting forever. Hence the register stage in front of the
compares; the combiner's paths then leave the worst list.

**On the board (90 MHz, −4.89 ns, the L2 off):** Color average 1.861 →
2.415 (+30 %): the 8-bit test 5.34 → 4.41 s, the 16-bit 7.81 → 5.60 s;
CPU 4.843, Mix 15.45, FPU 6.33, unchanged; a clean run and shutdown.

## 100 MHz is a lottery

Three fits of the same design at 100 MHz: −5.60 (boots, runs
Speedometer), −6.28 and −6.34 (one shows a picture or nothing, the other
nothing, their worst paths the usual families). As T100 against Q100 and
C2 against c1_adj before: at 100 MHz this design is at its cliff, and
which fit boots is decided by a few tenths of a nanosecond of placement
noise. A build for the board at 100 MHz should be fitted with several
seeds and the best taken (`SEED` in the qsf; three in parallel take an
hour on misterubuntu). Lasting margin needs the design itself to move,
which is the work `addr-stage` found too expensive for 110 MHz; at 100
MHz a smaller step would do.

## Next

- The combiner's effect on the Color tests and on the Finder, on the
  board, from a fit that boots (90 MHz, and the best 100 MHz seed).
- A 64 KB instruction cache (`IC_IDXW = 9`: 56 M10Ks more, the index
  already from a translated bit) for the 68k code's fetch misses: the
  ROM boot's fetch waits 3.6 → 2.6 %; the idle loop is the real measure.
- The data cache's misses on 68k code (19 %): the L2 on covers much of
  it; a larger data cache needs eight ways (its index must stay within
  the page).
