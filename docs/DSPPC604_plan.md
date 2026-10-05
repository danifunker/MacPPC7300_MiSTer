# DSPPC604: plan to a fully pipelined CPU

The goal of this plan is a pipelined PowerPC 604-class CPU that runs real ROM
code in simulation and meets timing on the DE10-Nano, built in steps that are
each verified before the next begins. The decisions it rests on are in the
[README](../README.md).

Dates are the day a milestone was closed. Open milestones carry an estimate in
working sessions, not calendar promises.

| # | Milestone | Proof it is done | State |
|---|---|---|---|
| M0 | Repository, MiSTer skeleton | project opens in Quartus | done 2026-10-05 |
| M1 | Vector test bench, integer execute unit | 11,576 real-604 integer vectors pass | done 2026-10-05 |
| M2 | Floating-point unit | 25,598 real-604 FP vectors pass | done 2026-10-05 |
| M3 | Pipeline, user-mode integer | golden vectors pass *through the pipeline*; lockstep against a reference on random code | done 2026-10-05 |
| M4 | Supervisor state, exceptions, FP in the pipeline | exception and SPR tests; lockstep with exceptions; interrupt tests | done 2026-10-05 |
| M5 | MMU and caches | translation and cache tests; lockstep with translation on | next |
| M6 | Real ROM in simulation, first MiSTer build | the 7600 ROM runs from reset until it needs hardware; timing met at 66 MHz or better | week 4-5 |

## Rules that keep the pipeline from growing special cases

A CPU that is pipelined late ends up with one-off stall and fix-up paths per
instruction. These rules exist to prevent that, and every milestone is
reviewed against them.

1. **Commit in order, at two fixed points.** An instruction commits its status
   registers (CR, XER, LR, CTR; later FPSCR, MSR and the SPRs) when it leaves
   EX, and its general register and memory write in MEM/WB. Leaving EX is
   only possible once nothing older can still fault, and from then on the
   instruction itself cannot be cancelled, so both points are final and
   exceptions stay precise. The invariant that makes this safe: an operation
   that accesses memory, the only kind that can fault after EX, writes no
   status register. (As first written this rule said "one commit point at the
   end of the pipeline". Building M3 showed the two-point form needs no
   forwarding network for the status registers at all; EX simply reads them.)
2. **One hazard mechanism.** The decoder declares which registers each
   operation reads and writes (up to three GPRs in, one out; later the same
   for FPRs). One set of forwarding comparisons and one stall condition (the
   value is a load that has not arrived) work from those declarations. No
   instruction gets its own stall logic.
3. **One way to take more than a cycle.** Multiply, divide and floating point
   sit behind the request/response handshake the units already have; the
   execute stage waits for `resp_valid`. Instructions that are several
   operations in one (`lmw`, `stmw`, the string instructions, update forms
   that write two registers) are expanded by a small sequencer in decode into
   simple operations, so the stages after it never see them.
4. **One flush.** A mispredicted branch, an exception, `rfi`, `isync` and
   writes to state that changes how later instructions are fetched or
   translated all use the same flush-and-refetch.
5. **Stateless units.** The execute units stay as they are now: operands in,
   results out. The test wrapper and the pipeline instantiate the very same
   modules, so the golden vectors keep guarding them.
6. **Model differences are data or whole modules.** A value that differs
   between CPU models (PVR, an estimate table, TLB size) is a parameter. A
   behaviour that differs (the 603's software TLB reload) is its own module in
   that model's version. No `if (model == ...)` inside shared logic.

## Pipeline shape

```
IF1 -> IF2 -> ID -> EX -> MEM -> WB
```

| Stage | Work |
|---|---|
| IF1 | next PC, branch prediction, instruction cache and ITLB address |
| IF2 | instruction cache data, hit check |
| ID | decode, register read, sequencer for multi-operation instructions |
| EX | ALU, effective address, branch resolution, multiply/divide/FPU request |
| MEM | data cache and DTLB access, load alignment |
| WB | commit, exception entry |

Expected costs: 3 cycles for a mispredicted branch, 1 for a load followed by a
use, 3 for a multiply, 35 for a divide (the same as today's units), floating
point to be measured in M2. MEM may split in two if translation plus cache
lookup does not fit one 13 ns cycle; that is decided with timing data in M5,
not before.

## Milestones in detail

### M2: floating-point unit (done)

- `DSPPC604_fpu` with the agreed interface: `a`, `b`, `c`, `fpscr_in` in;
  `result`, `result_we`, `fpscr_out`, `cr_out`, `fex` out.
- One datapath for everything: `x * y + z` with a single rounding (add is
  `a * 1 + b`, multiply has no addend, `frsp` and `fctiw` have no product),
  and a two-bits-per-cycle divider for `fdiv` and `fres`, both feeding one
  normalise, shift, round and pack back end. Every stage is registered.
- Written against `verilator/fpmodel.py`, a bit-exact software model that was
  first made to match all 25,598 hardware vectors. The RTL then matched the
  hardware vectors and 1.8 million random vectors from the model.
- Cycles from request to response: moves, `fsel` and compares 0; add,
  subtract, multiply, multiply-add, `frsp`, `fctiw` 8; `fdiv` 34; `fdivs`
  and `fres` 20; `frsqrte` 2. Add 6 when an operand is denormal. A result
  that needs no arithmetic (NaN, infinity, zero operands) takes 1.
- Stand-alone on the DE10-Nano's FPGA: 3,303 ALMs, 4 DSP blocks, 73.5 MHz
  worst case (75.2 MHz at the hot corner). The slowest path is the rounding
  stage; the stage boundaries have not been tuned yet.

What the hardware data does not cover, and the RTL therefore takes from the
architecture manual alone:

- enabled overflow, underflow and inexact exceptions (only the
  invalid-operation enable was set in any vector);
- FPSCR arriving with exception bits already set (how FX behaves);
- 24 of the 32 `frsqrte` table entries;
- `FPSCR[NI]`, non-IEEE mode, which is not implemented at all yet.

**Needs from the hardware side** (one new vector set covers all four): the
same instructions with the other enables set and with sticky bits preloaded,
an `frsqrte` sweep of 32 operands per exponent parity, and a few operations
with NI set.

Still to do on the unit itself, when the pipeline shows what matters: shorten
the 8-cycle arithmetic path (a separate add path that skips the multiplier,
leading-zero anticipation, merging stages that have slack), and let it accept
a new request every cycle.

### M3: pipeline, user-mode integer (done)

What was built (`rtl/DSPPC604/DSPPC604.sv` and the modules it instantiates):

- The six stages, with req/gnt/rvalid buses for instructions and data.
- All user-mode integer instructions: loads and stores in every form (update,
  indexed, byte-reversed, multiple, string), branches, CR logic,
  `mfcr`/`mtcrf`/`mcrf`/`mcrxr`, moves to and from LR, CTR and XER.
- `DSPPC604_seq`: the sequencer. Update forms become the access plus an add;
  `lmw`/`stmw` and the string instructions become one access per register.
  A scratch register (number 32) holds the base address of `lswx`/`stswx`.
- `DSPPC604_mem_unit`: any 1 to 4 byte access at any alignment as one or two
  word-aligned bus accesses, with the byte-reverse, sign-extend and string
  conversions.
- A 128-entry branch target buffer with two-bit counters. Every instruction
  carries the address the fetch continued with, and EX redirects when that is
  not where the instruction really goes, so a wrong prediction costs three
  cycles and nothing else.
- An instruction the core does not implement stops it (`halted`), until
  exceptions exist.

How it was verified (`python verilator\run_core.py`):

1. The 11,576 real-604 integer vectors assembled into one 131,765-instruction
   program, each instruction's inputs produced by the instructions just
   before it, run with 0%, 25% and 60% random bus wait states. All pass.
2. Random programs in lockstep with dingusppc's interpreter
   (`verilator/ref`): registers compared after every instruction, memory at
   the end. Deliberately broken RTL (four different bugs) is caught.
3. Quartus: 3,208 ALMs, 78.6 MHz worst case.

Measured cost, with the test bench's bus (a data access takes two cycles;
there are no caches yet): 1.36 cycles per instruction on the straight-line
golden program.

Carried into M4, because they need exceptions:

- `sc`, `tw`, `twi`.
- The alignment exceptions the 604 manual lists: `lmw`/`stmw` at an address
  that is not word-aligned, and an unaligned string operation crossing a 4 KB
  boundary. Today these simply execute.

Where dingusppc is not a usable reference (found while building the lockstep
library; details in `verilator/ref/README.md`): divide results the
architecture leaves undefined, its `tw` compares the operands the wrong way
round, it raises the alignment exception for `stmw` but not `lmw`, it keeps
reserved XER bits, and its floating point never reports inexact. The random
programs avoid these or, for the undefined divides, take the real-604 value.

### M4: supervisor state, exceptions, floating point in the pipeline

**Step 1, floating point in the pipeline: done 2026-10-05.**

- Floating-point registers are written in WB and forwarded like general
  registers; a register is named by seven bits, so the one hazard mechanism
  serves both files. FPSCR commits when an instruction leaves EX, like CR.
- FP loads and stores in every form. A double is two word accesses at a
  word-aligned address. The single/double conversions of `lfs` and `stfs`
  are the bit rearrangements the architecture defines.
- `DSPPC604_fpscr`: `mtfsf`, `mtfsfi`, `mtfsb0`, `mtfsb1`, `mcrfs`; `mffs`.
- Verified: the 25,598 real-604 FP vectors as one 281,579-instruction program
  (constants loaded with `lfd`, FPSCR set with `mtfsf`), with and without bus
  wait states; random FP programs checked after every instruction against
  `fpmodel.py`; five deliberate bugs each caught.
- With the FPU the pipeline is 9,391 ALMs and 66.5 MHz. The register files
  are still flip-flops, and the forwarded FP operands feed the FPU's first
  stage directly; both are to be fixed in a timing and area pass.
- Follows the manual only, no hardware data: the FPSCR instructions, the
  upper word `mffs` delivers (FFF80000 here), and what `stfs` stores for a
  double below the single denormal range. All three are in the vector set
  asked for in `RESUME_hardware.md`.

**Step 2, exceptions and supervisor state: done 2026-10-05.**

- MSR, SRR0, SRR1, SPRG0-3, DAR, DSISR, the decrementer and time base (they
  advance on a `tb_tick` input), PVR, and as plain storage for now HID0, EAR,
  IABR, DABR, the performance-monitor registers, SDR1, the BATs and the
  segment registers. An SPR number the 604 does not have is an illegal
  instruction, as the 604 manual says.
- `mfmsr`, `mtmsr`, `rfi`, `sc`, `tw`, `twi`, `mftb`, `mfsr`/`mtsr` and their
  indirect forms. `tlbie` and `tlbsync` are accepted and do nothing yet.
- Exceptions: program (illegal, privileged, trap, enabled floating-point),
  floating-point unavailable, system call, alignment (`lmw`/`stmw` and
  floating-point loads and stores at an address that is not word-aligned,
  with DAR and DSISR), external interrupt, decrementer.
- How it works: everything that can stop an instruction is known by the time
  it would leave EX. It is dropped there, SRR0/SRR1/MSR are written and the
  fetch redirected at that one edge. Because the status registers commit in
  EX, an interrupt or a pending floating-point exception is just a condition
  on whichever instruction is in EX; nothing is sampled or carried along. A
  floating-point instruction that raises an enabled exception itself
  completes and traps at the same edge. `mtmsr` and `rfi` always refetch.
- Verified three ways (`python verilator\run_core.py`):
  1. Lockstep with dingusppc now includes supervisor instructions, switches
     between user and supervisor mode, system calls, traps, illegal and
     privileged instructions and floating-point unavailable; MSR is compared
     after every instruction, and the handlers copy SRR0 and SRR1 into
     registers that are compared too.
  2. Each exception raised once, with the exact SRR0, SRR1, DAR and DSISR the
     handler must find, including both ways an enabled floating-point
     exception arrives.
  3. A loop with known results under thousands of external and decrementer
     interrupts, with and without bus wait states: the results are intact and
     every interrupt raised is counted exactly once by its handler.
- Where dingusppc could not be the reference: it sets an SRR1 bit on `sc` and
  on floating-point unavailable that the architecture does not (the test
  bench clears them), its `tw` swaps the operands (the random programs use
  only conditions where that does not matter), and it never takes an enabled
  floating-point exception or an interrupt (covered by 2 and 3).

- Quartus, whole CPU so far: 10,781 ALMs (26%), 69.5 MHz worst case.

Left for later, with the milestone that needs them:

- DSI and ISI, `lwarx`/`stwcx.`, the cache instructions: M5.
- Machine check, trace (MSR[SE], MSR[BE]), the 604's instruction-address
  breakpoint and performance-monitor interrupts, soft reset, power saving,
  little-endian mode: not started, no milestone yet.
- The alignment exception for an unaligned string operation that crosses a
  4 KB boundary (604 manual, section 2.3.4.3): not implemented.
- From real hardware, when a supervisor-level test is possible: the reset
  values of MSR and HID0, and the SRR1 and DSISR a 604 really delivers.

- MSR, SRR0/SRR1, every exception with its priority and vector, `rfi`,
  privileged-instruction and illegal-instruction checks, alignment.
- SPRs: PVR, SPRG0-3, DAR, DSISR, DEC, time base, HID0, the 604's performance
  monitor and breakpoint registers as far as software looks at them.
- External interrupt and decrementer.
- Floating point joins the pipeline: FPRs, FP loads and stores (with the
  single/double conversion), the FPSCR instructions (`mffs`, `mtfsf`,
  `mtfsfi`, `mtfsb0`, `mtfsb1`, `mcrfs`), FP-unavailable, and precise enabled
  FP exceptions under MSR[FE0,FE1].
- **Needs from the hardware side:** a second vector set for what the first
  one does not cover: loads, stores, branches, CR logic and the FPSCR
  instructions. Programs started from Open Firmware run in supervisor mode, so
  SPR reads can be recorded too.

### M5: MMU and caches

- Block address translation, segment registers, hashed page table walk in
  hardware with reference and change bit updates, ITLB and DTLB, `tlbie`.
- Instruction and data caches in block RAM, 32-byte lines; `dcbz`, `dcbf`,
  `dcbst`, `dcbi`, `dcbt`, `dcbtst`, `icbi`; the HID0 cache-control bits.
- The memory side becomes a line-fill bus. Writes to memory by anything other
  than the CPU (disk DMA, the HPS loading a ROM) must go through or
  invalidate the data cache; the bus is defined with that in mind.

### M6: real ROM, first MiSTer build

- Run the 7600's own ROM from the reset vector in Verilator against a stub
  machine, in lockstep with dingusppc, until it needs hardware that is not
  there.
- Put the CPU in the MiSTer project with memory and the ROM; get a first
  bitstream that executes ROM code and reports over the UART.
- Timing closure at 66 MHz, then try 75.

After M6 the work is the machine, which gets its own plan.

## Decisions needed along the way

| When | Question |
|---|---|
| now | When the 7300 is running tests: build the extra floating-point vector set listed under M2? |
| M3 | Is dingusppc built as a library acceptable as the lockstep reference, given it is the reference trusted most? |
| M5 | Main memory on the SDRAM module or on the HPS DDR3? It sets the line-fill latency and how much RAM the machine can have. |
| M6 | With measured speed in hand: stay with the 7600, or model a slower machine first? |
