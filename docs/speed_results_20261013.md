# Why 110 MHz black-screens, and the clock sweep tool (2026-10-13, branch `addr-stage`)

Branch `addr-stage` (from `fpu-pipe` ef00783) holds the day's timing cuts,
the diagnosis of the 110 MHz black screen, and a run-time CPU clock.

## The diagnosis

Every build at 110 MHz (and one at 105 MHz with memory at 105) showed a
black screen from power-up, where 100 MHz runs Mac OS and Speedometer.
Inferring from the slow-corner slack (−7.0 ns at 110 against −6.6 at a
working 100) said only "too slow"; a build with the DDR3 trace and the
CPU sampler (`TRACE = 1, PERF = 1`; `syn/mister.py trace-capture`,
`syn/cpusample.py`) says what the CPU does:

- **At 110 MHz the CPU neither crashes nor takes an exception.** EX holds
  one instruction for the whole capture: the third of eight back-to-back
  `lfdx f1,0,r3` at FFF04214, the ROM's loop that touches each 64 MB
  memory bank (FFF04200–FFF0422C, the cache on, addresses such as
  0x5C000000 beyond installed RAM). The first two complete; the third,
  a hit on the line just filled, never does. 146,864 samples, 100 %.
- **The mechanism.** In a hit's answer cycle the memory unit offers its
  next access (`first_slot` takes `resp_valid`), the cache grants it
  (`can_take` takes `word_hit`), and the memory unit's state, the MMU's
  `d_outstanding` and the cache's state plus its ~70 payload registers
  each record the grant — all behind the tag compare of the current
  lookup. Decided unevenly from the late hit, the memory unit waits for
  an answer the cache never looks up. The first run of back-to-back hits
  after power-up is this loop, so it hangs there every time.
- **A control.** The same trace build at 100 MHz is slower than the
  release-style build (the trace logic fills the chip to 93 %, −7.44 ns)
  and fails differently: it passes the bank loop, then falls into a storm
  of 10 million DSIs at FF816C18 (the MMU's translate path). Too-slow
  builds fail there, not in the bank loop.
- **Not the clock crossing.** An audit of every crossing between the CPU
  and memory clocks found nothing that depends on which clock is faster;
  `make cdc` and `make sdram` pass at 110 against 100; and CPU 70 MHz with
  memory at 105 MHz boots on the board. Memory speed is not a lever
  either: relative to the CPU, this memory is already faster than the real
  7300's 50 MHz bus (a line in about 25–30 CPU cycles).

## A switch, and what it showed

`dc_pipe` (OSD "D-cache pipelining (on reset)", 985dc40) keeps the hit
out of the grant: a hit's answer cycle takes no request, so the cache's
grant and payload enables come from registers and the memory unit offers
the next access a cycle later. ROM boot 321.72M → 327.27M cycles (+1.7 %).
On the board (build `C2`, the run-time clock below):

| CPU clock | pipelining on | pipelining off |
|---|---|---|
| 92 MHz | — | desktop |
| 100 MHz | desktop (build `c1_adj`, −7.29 ns at 109); the flashing "?" disk (build `C2`, −7.43: its fit fails at 100 even here) | system error "illegal instruction" at Welcome to Mac OS |
| 109 MHz | black: the lfdx hang | black: 388,620 program checks at FFC031BC (a jump into the 68k ROM's data: a load or store went wrong), then the ROM's wait loop |
| 120 MHz | black | black |

Two fits of the same design a tenth of a nanosecond apart, one booting
at 100 MHz and the other not, say how close to the edge 100 MHz already
is (as T100 against Q100 did on 2026-10-13). So the grant hang is the
first symptom only. Behind it, at 109 MHz, loads
and stores corrupt (the broad band of paths at −6 to −7 ns at the slow
corner: the 1000th-worst path is within a nanosecond of the worst), and
the un-pipelined mode exercises a path of its own that fails at 100 MHz.
There is no single path to cut: 110 MHz needs the deeper pipeline (a
two-cycle cache answer and a real address stage, about 8–10 % of cycles),
which only pays at 120 MHz and beyond, where the same band would have to
move by another nanosecond. 100 MHz with pipelining on is the practical
optimum of this microarchitecture on this FPGA.

## The run-time CPU clock (22d9333)

The PLL is reconfigurable (`rtl/pll/pll_0002.v`: one 1200 MHz VCO, M 24,
the counters explicit; the CPU's counter 11 as built, 109.09 MHz, so the
fitter keeps it apart from memory's 12). `MacPPC7300_clkadj` applies the
OSD's choice — "CPU clock (on reset)": 100, 109, 120, 133, 92, 86, 80, 75
MHz — to that counter through `altera_pll_reconfig_top` while the machine
is held in reset, as the framework adjusts its HDMI PLL; only that
counter changes, so memory and video keep their clocks and the PLL its
lock. The machine's time bases take the rate chosen (`cpu_hz`, taken
under reset like the RAM size; each is an accumulator that ticks in a
cycle it starts not negative, one add with no compare). Verified: the
built-in 109 MHz never boots; with the OSD at 100 the same core reaches
the desktop. A build can now be tried at every clock in minutes.
`syn/mister.py` reads the trace from the board; a saved config's clock
bits are status 33–31 (byte 3 bit 7, byte 4 bits 1–0), pipelining off is
status 34.

## The timing cuts of the branch

5bb1f43 WB's payload every cycle, the DSI from the MMU's fault register;
593d592 stfs converted per forwarding source, a rotator each way;
2104bad MEM's forwarding selects without `mem_leave`, the ITT commit a
cycle late, the FPU's sticky bits beside `n_fix`; 480b083 the memory
unit's two-word flag as a descriptor bit; 09d89e5 MEM_MHZ; fd8651f the
address from EX's registers (+1.4 % cycles: the forwarded operand through
the adder, the MMU's compare and the grant was the one family in every
110 MHz fit); 7789361 a load's data shaped per way (+1,300 ALMs);
ead884f the ITT index pre-folded; 37cabfb the free descriptor written
every cycle; dd0ab99 `L2_KB = 0` builds no L2. None moved the worst
slack at 110 MHz out of its band (−7.0 to −7.9, fit noise ±0.4). The
ones that cost nothing per clock could be carried to `fpu-pipe` for
margin at 100 MHz; fd8651f and 7789361 only pay above 100.
