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

## The combiner at 100 MHz, continued

Every fit with the combiner failed at 100 MHz (nine of them, −5.6 to −7.1
ns, black or a picture or a Finder error), while the plain core booted
from three fits of three (−5.60, −6.07, −6.13) and so did the combiner
bypassed (the crossing's byte enables and the video's masked beats kept,
−6.01). Bisecting the combiner's features (no read line, no merging, the
store answered only after its drain, single-beat DDR3 writes, the PLL's
two 100 MHz outputs kept apart by a phase shift) changed nothing: all
black. The crossings' data paths measure 3–7 ns against a budget of 20.

**What the trace showed.** A build with the DDR3 trace and the combiner's
counts (kind 15, `syn/vramstat.py`): at 90 MHz the counts run (2.6 M
stores, 1.6 M drains, 68 k loads for the boot); at 100 MHz the boot got
through the chime and the Ethernet set-up and then, right after the ADB
probe at 12.9 s, made no more device access and never a store to the
screen — a port request nobody answered. Every capture also shows a
first boot attempt stalling in the chime's third DMA chunk until the ROM
download's reset 3 s later; that one is normal.

**The port registered for the devices (5e56418).** The worst paths of the
100 MHz fits with the combiner ran from the CPU port's I/D choice and the
caches' state and address registers through the machine's decode into
the devices' take and the request's 300-odd registers (−7.1 ns, `p_k`,
`p_dev`, `dev_take`). The machine now decides the devices' and the VRAM's
requests from a registered copy of the port (`q_*`, standing for the
request still up: the port's request was not answered the cycle before);
the memory path keeps the live decode. The CPU's reset also comes from a
register. Three fits at 100 MHz: −5.58, −6.15, −6.40, the machine's
families gone from the worst lists. (Answering a store in the cycle the
combiner takes it, to give the port back the cycle the copy costs, was
tried and reverted: the acknowledge then runs combinationally from the
copy's address compare into the CPU's cache fills, a −6.5 ns family of
its own, for a gain within the Color tests' noise at 100 MHz.) The board
at 90 MHz ran Speedometer clean (CPU 4.851, Mix 15.39, FPU 6.32, Color
2.355: the port's extra cycle, before the same-cycle answer, cost the
Color tests 2.5 %). The −5.58 fit at 100 MHz got to "Welcome to Mac OS"
and a bus error.

**It is not the slow corner.** The fast-corner slacks of the fits that
fail (+0.6 to +0.9 ns at 0 °C fast silicon) are better than those of the
plain fits that boot (+0.23 to +0.38). Whatever fails is not the timed
logic as the models see it. The machine bench's DDR3 model never asserted
BUSY unless `--stall` was given, and the combiner's checks had run
without it; with `--stall 30` (bus and DDR3 wait states) the boot passes,
at 90/100 and at 100/100 MHz.

**It is the area.** Three builds told the explanations apart: the
combiner with the memory clock at 90 MHz (the equal clocks) is black; the
plain core with a thousand ALMs and two thousand registers of dummy XOR
logic kept through the LED (−6.14 ns, 91 %) is black; **the combiner with
two entries (−5.80 ns, 88 %) boots to the desktop in 35 s and runs
Speedometer**: CPU 5.391, Dhrystones 5.662, FPU 6.98–7.36, Color 2.486
and 2.555 in two runs (the 8-bit test 4.01–4.22 s, the 16-bit 5.50–5.52
s) against 1.920 without it at 100 MHz. The fits that boot at 100 MHz
use 36.4–37.3 k ALMs; the ones that fail 37.2–38.0 k; the overlap is the
fit lottery, and every few hundred ALMs shift the odds. The entries are
now two by default; the drain reads them through a mux instead of a
copy. Two entries at 90 MHz: Color 2.332 (four: 2.355; the eight of the
first build, with the port's old decode, 2.415); CPU 4.843, Mix 15.48,
FPU 6.29. Ten fits of the two-entry design at 100 MHz: six boot (−5.80
to −6.31) and four fail (−5.71 to −6.27: a bus error or a hang at
"Welcome", a Finder error); the slow-corner slack does not order them,
and the failing fits' worst families are the booting fits' (the
sequencer's result into the memory unit's state, the data cache's
address into the write-back result, the cache states into the L2's
write data). A build for the board at 100 MHz is a handful of seeds and
the board: the best so far is `seed_x100r2_s3` (−5.86, Speedometer
clean, `X100r2_S3_PM761.mgl`).

Where the ALMs go (the two-entry fit, 36,945): the framework's scaler,
audio filters, OSDs, HDMI PLL and video output about 7,000, untouchable;
the CPU 15,400 (its own forwarding and control 6,270, the FPU 4,000, the
data cache 1,300, the integer unit 1,140 of which the divider 590, the
MMU 1,070, the instruction cache 660); the L2 700; the machine 10,200:
Grand Central 4,740 (the five DMA channels 2,030, MACE 420, ESCC 390,
SWIM 300, MESH 300), the SCSI disks 2,020, the ADB devices 780, the
video 850, Cuda 540, the combiner 560, the machine's own decode and
ports 1,630.

## Shrinking (2026-10-14)

Synthesis gives the per-entity counts in twelve minutes (`quartus_map`
alone; the fitter's figure runs about 2,000 ALMs above its estimate).
From the slimming so far, all behaviour-neutral, each checked by the
machine bench's boot plain and with wait states (frames identical):

| Edit | own ALUTs | registers |
|---|---:|---:|
| Each DMA channel chose its 16-byte descriptor out of the fetched line with a 128-bit mux; Grand Central chooses once for the channel that owns the port | −350 (+64) | |
| The disk model's three 32-bit range checks became one on the command's fields | −186 | |
| The combiner's request stage, redundant since the port's copy (its bench runs 13 % faster without it) | | −300 |
| The video's copies of Control's parameter and cursor registers | | −450 |
| The port copy's memory bit registered from the live decode instead of a second RAM map | −37 | |

35,105 → 34,854 ALMs by the estimate (−597 LUTs, −671 registers).
Registers hardly move the estimate: the ALM count follows the LUTs. The
remaining machine-side LUTs are the models themselves — the disk 2,500,
Grand Central 1,500, ADB 1,000, the SCSI DMA channel 970 — and the
only large blocks left are features: Ethernet (MACE and the queue,
1,100 LUTs) and the floppy (560), which could be build options.

**The 64 KB instruction cache** (`IC_IDXW = 9`, 32 M10Ks more, no
ALMs), measured on the idle desktop 25 s after the boot, two builds
with the counters at 90 MHz: CPI 2.05 → 1.73, fetch waits 23.5 % →
7.6 %, instruction-cache misses 15.9 → 4.3 per 1,000 instructions, the
data cache's misses and the mispredictions unchanged. That is the
Finder's and the toolbox's code.

## Next

- Area: a few hundred ALMs decide the 100 MHz lottery. Candidates not
  in the framework: the DMA channels' line buffers, the SCSI disk model,
  the ADB devices; the combiner's read line (256 registers) if the
  screen is seldom read.
- More placement effort (PLACEMENT_EFFORT_MULTIPLIER 3,
  ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM) over three seeds: +0.4,
  −0.3 and +0.4 ns against the same seeds without, two of the three
  boot. Noise; not adopted.
- Lasting margin at 100 MHz needs the core's deep paths cut (the memory
  unit's state from the write-back result, the data cache's address
  into the result), the work `addr-stage` found expensive, or a few
  thousand ALMs freed.
- A 64 KB instruction cache (`IC_IDXW = 9`: 56 M10Ks more, the index
  already from a translated bit) for the 68k code's fetch misses: the
  ROM boot's fetch waits 3.6 → 2.6 %; the idle loop is the real measure.
- The data cache's misses on 68k code (19 %): the L2 on covers much of
  it; a larger data cache needs eight ways (its index must stay within
  the page).
