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
| M5 | MMU and caches | translation and cache tests; lockstep with translation on | done 2026-10-06 (timing pass stopped at 64-65 MHz) |
| M6 | Real ROM in simulation, first MiSTer build | the 7600 ROM runs from reset until it needs hardware; timing met at 66 MHz or better | done 2026-10-06, apart from timing: the ROM runs in simulation and on the board, identically, to Open Firmware's wait for Cuda; the CPU's clock closes at 64.6 MHz (65 asked) |

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

What the first hardware data did not cover (the enabled overflow, underflow
and inexact exceptions, FPSCR arriving with exception bits set, 24 of the 32
`frsqrte` entries, non-IEEE mode) the 7300 run of 2026-10-06 did, with 39,025
vectors the model had predicted (`ppctest/v4gen.py`,
`runs/results_604_7300_of_run1.csv`). The model and the unit were corrected
where the 604 disagreed, and now match every one of them:

- **Non-IEEE mode (FPSCR[NI])**, 1,366 of 4,000 vectors differed: a result
  that would be denormalised is delivered as a signed zero, with UX, XX and
  FI set whether or not the denormal would have been exact, FR clear and
  FPRF saying zero. Denormal *operands* are computed with exactly as in IEEE
  mode, whatever Table 2-7 of the 604 manual says ("zero A, B, C").
  `fctiw`, `frsqrte`, `fres` and the compares are not affected.
- **Enabled underflow and overflow in single precision** whose adjusted
  exponent is still outside the double range, 456 vectors the model had
  called undefined: the 604 delivers the scaled value with the exponent
  field formed from its wider internal biased exponent as bits 9-0 as they
  are and bit 10 as bit 11 XOR bit 10 (the identity for every exponent in
  range), and classes a scaled result as a normal number whatever its
  exponent (FPRF C bit clear). Nothing the model computes is undefined any
  more.
- The 251-entry `frsqrte` table sweep and the 1,664-vector `frsqrte`/`fres`
  sweep matched: all 32 table entries are now measured.
- The 8,228 vectors with the other enables and with sticky bits preloaded
  matched the model as it was.

Still to do on the unit itself, when the pipeline shows what matters: shorten
the 8-cycle arithmetic path (a separate add path that skips the multiplier,
leading-zero anticipation, merging stages that have slack), and let it accept
a new request every cycle.

The speed session (2026-10-09, the user's request that the FPU be faster
too): `fmul` skips the add cycle (no addend: S_MUL2 hands the product to the
back end, 7 cycles), and the operand register is off again
(`FPU_OPERAND_REG = 0`: the cuts since 2026-10-06 took the forwarding paths
it was switched on for off the top of the list). Measured: the FP golden
program 3.53 to 3.45 cycles per instruction, the 7300's 3.81 to 3.73, the
random FP programs 4.74-5.33 to 4.27-4.83; every vector and the suite as
before. The add path's alignment cannot fold into one cycle at 70 MHz (the
exponent difference, the clamp and a 161-bit shift with sticky in series),
so adds keep their 8; what would shorten them is deciding the alignment
distance in the request cycle from the operands' exponents. Whether
independent FP operations may overlap (EX waits for each response, rule 3;
a scoreboard would join the one hazard mechanism, rule 2) is left to the
measurements: Speedometer's Matrix Mult. and Fast Fourier are dependent
chains, where latency, not throughput, is the cost.

The timing cuts of 2026-10-10 (the machine plan's decisions table, "speed"):
the results that need no arithmetic are found in the cycle after the
request, from the operand registers, while the first stage has begun (a
special result abandons it for S_DONE: a cycle more for those operands only;
the golden programs 3.45 to 3.49 cycles an instruction), and the operands'
classes (`fp_cls_t`, `cls_a/b/c`) come from the requester beside the
operands, found with `fp_classify` or, for an lfs result still a single,
`fp_classify_single`, so no conversion sits in front of them. The unit alone:
3,294 ALMs, 75.5 MHz worst case; the whole CPU's worst path moved off the FPU
(builds 44 and 45 in the Speed table: -2.40 to -1.35 ns at 70 MHz).

The latency cuts of 2026-10-10, first step: S_LZC is skipped when the
leading-zero count is known without counting. A product of normalised
operands has its top at bit 105 or 104 (`fmul` 7 to 6 cycles), a quotient
in (1/2, 2) at bit 161 or 160 (`fdiv` 34 to 33, `fdivs` and `fres` 20 to
19), and a sum whose two parts are two or more places apart has its top
within a place of the larger: five bits at a fixed place give the count when
the addend is pinned at the top (`frsp`, `fctiw`, an addend 2**56 or more
times the product: 8 to 7) or the product is four or more times the addend
(8 to 7). An addend larger than the product by up to 2**55 (its place
variable: a 54:1 window mux after the 163-bit adder cost 3 ns too many, the
unit alone fell to 59 MHz) and the four distances where cancellation can
reach far still count in S_LZC (8). The unit alone: 3,443 ALMs, 74.6 MHz.
Tried and reverted the same day, for the addend-dominant sum (a dot
product's running sum against each product: Matrix Mult.'s case, which
build 46 therefore hardly moved): the count taken as nominal (sr) in S_ADD
and corrected by 0, 1 or 2 in S_NORM from three bits of the registered sum
(the product lies wholly below those bits, so the top is at the addend's
place, one above after a carry or one below after a borrow). Every vector
passed, but S_NORM grew by the window mux and a fourth adder into `l_q`,
the fitter retimed registers across S_NORM/S_SHIFT and the unit alone fell
to 65.8 MHz. Two designs that could still take that cycle, for a later FPU
session: shift the partial products left by sr in S_MUL1 (the DSP outputs
and the distance are both ready at about 5 ns there), so the addend stays
pinned at the top and the window is fixed, at the price of a 159-bit adder
in S_MUL2; or take the one carry bit into the addend's lowest window place
from the adder's output in S_ADD (a single 54:1 mux of `add_sum` or
`add_zp`, selected early by `eff_sub`, rather than the 5-bit window of the
first attempt). Then the add path's alignment distance decided in the
request cycle (adds skip S_MUL1), a radix-8 divider, S_SHIFT folded into
S_NORM where the shift amounts allow. All of it is worth a few per cent on
three Speedometer FPU tests; the core's distance from a real 604 (about a
quarter of a 7600/120's Speedometer CPU index at 70 against 120 MHz: 0.58 of
the clock, the rest cycles per instruction) is a pipeline matter, scoped in
`RESUME_speed.md`.

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
- Measured on the 7300 (2026-10-06): the FPSCR instructions, every bit of
  every one (2,989 vectors), are as built; `mffs` puts FFF80000 in the upper
  word, as `fctiw` does; FPSCR bit 20 is never set. `lfs` of every class
  (SNaNs and denormals included) was as built. `stfs` of a double below the
  single denormal range was not: the 604 denormalises for every exponent of
  896 or less, shifting the 24-bit significand right by 897 minus the
  exponent, so from exponent 873 down (double denormals included) it stores
  a signed zero (92 vectors). The conversion in `DSPPC604_pkg` and the model
  do that now. The 152 integer load and store vectors (every form,
  byte-reversed and string ones included) were as built.

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

Added after the review of everything flagged during M0-M4 (2026-10-05):
`dcbt` and `dcbtst` are accepted and do nothing (they are hints, so that is
allowed); the alignment exception for a string operation that is not
word-aligned and crosses a 4 KB boundary, or is word-aligned and crosses a
256 MB boundary (604 manual 2.3.4.3), with directed tests for both and for
the cases that must execute; three deliberate bugs in the exception logic
(SRR0 of `sc`, MSR[EE] left on at entry, the decrementer's pending flag not
cleared) were each caught by the directed tests.

Left for later, with the milestone that needs them:

- DSI and ISI, `lwarx`/`stwcx.`, the remaining cache instructions: M5
  (done in its steps 1 and 2).
- Machine check, trace, the 604's breakpoint and performance-monitor
  interrupts, soft reset, power saving, little-endian mode: no milestone;
  what each would take is under "Known behaviour and open items" below.
- From real hardware, when a supervisor-level test is possible: the reset
  values of MSR and HID0, and the SRR1 and DSISR a 604 really delivers.
  (Done 2026-10-06, next paragraph; the reset values are still open, the
  test runs after the ROM.)

**Corrected from the 7300 run's second stage (2026-10-06)**, 10,772
supervisor-mode sequences (`ppctest/runs/sresults_604_7300_of_run1.csv`;
the groups are described in `ppctest/README.md`). Where the 604 disagreed
with the core, the core and its directed tests now follow the 604:

- `mtxer` keeps `0xE000FF7F`, bits 16-23 included (the core kept
  `0xE000007F`); `mcrxr` is as built.
- `mtmsr` keeps `0x0005FF77`: bit 29, PM, is implemented on the 604 (the
  core had `0x0005FF73`); `rfi` copies the same low 16 bits, `0xFF77`.
- An SPR the 604 does not have is an illegal instruction in user mode as in
  supervisor mode (the core, following manual 4.5.7, called it privileged in
  user mode). The SPRs that exist: 1, 8, 9, 18, 19, 22, 25, 26, 27, 268, 269,
  272-275, 282, 284, 285, 287, 528-543, 952-955, 959, 1008, 1010, 1013, 1023,
  of which 1, 8, 9, 268 and 269 are readable in user mode. So `mfspr` 268/269
  reads the time base like `mftb`, in user mode too, and PIR (1023, four bits)
  exists; both added. 1009 (HID1), 956-958, 1019-1022 (the 604e's and 750's)
  do not exist.
- `stwcx` without the record bit is illegal (the core executed it). Every
  other instruction without a record form ignores bit 31 (`lwarx` with it set
  writes CR0, which the core does not reproduce: undefined).
- The second and later exceptions for a pending enabled floating-point
  exception (FEX still set when a later instruction, floating-point or not,
  completes) set SRR1[15]: SRR0 is not the instruction that caused it. The
  first, raised by the instruction itself, has it clear, in every FE0/FE1
  mode. The core sets it for the pending case now.
- The alignment exception's DSISR: the opcode fields are the architecture's,
  but where it says rD and rA the 604 puts rD and rD - 1, and 8 and 7 for
  `dcbz`. Measured for `lmw`, `stmw`, `lfd`, `stfd`, `lwarx`, `stwcx.` and
  `dcbz`; the update forms were not tested. The core and the tests do the
  same; a handler on a 604 cannot take rA from DSISR.
- The bits the supervisor registers keep: SRR0 bits 0-29; SDR1 `0xFFFF01FF`;
  EAR `0x8000003F`; PIR 4 bits; BAT upper `0xFFFE1FFF`, lower `0xFFFE007B`
  (the IBATs keep W and G too); SPRG0-3, SRR1, DAR, DSISR, DEC, IABR, DABR,
  MMCR0, PMC1, PMC2, SIA, SDA and the segment registers all 32 bits. The
  core masked none of them before.
- As built, and now measured: SRR1 holds only the MSR bits for `sc`, FP
  unavailable, alignment and DSI (dingusppc's extra bits on `sc` and FP
  unavailable are its own); `0x00040000` privileged, `0x00080000` illegal,
  `0x00020000` trap, `0x00100000` FP enabled; DSISR `0x40000000` no page,
  `0x08000000` protection, `0x02000000` store, `0x00100000` `eciwx`
  (`0x02100000` `ecowx`); ISI SRR1 `0x40000000` no page, `0x08000000`
  protection; exception entry keeps ME and clears the rest (IP, ILE and LE
  were never set); `sc` saves the next address; `dcbz` on a cache-inhibited
  page or in user mode is alignment with DAR the line; `lwarx`/`stwcx.` on a
  cache-inhibited page take no DSI and the store succeeds; `eciwx`/`ecowx`
  take a DSI; `mftb` with a TBR number other than 268/269 is illegal;
  `tlbia`, `tlbld`, `tlbli`, opcodes 0-2, 4-6, 9, 22, 30, 56-58, 60-62 and an
  opcode-17 word without bit 30 are illegal; `FFFFFFFF` is a valid `fnmadd.`;
  `lswx`/`stswx` with XER = 0 touch nothing; `lmw` with rA in the range loads
  it like the others; the decrementer interrupt comes when bit 0 is written
  set, or on the next instruction after `mtmsr` enables EE with one pending.

### M5: MMU and caches

Steps, each verified before the next:

1. Address translation: BATs, segment registers, hashed page table walk in
   hardware with reference and change bit updates, ITLB and DTLB, `tlbie`;
   DSI and ISI with DAR and DSISR. Proof: lockstep with dingusppc with
   translation on (its MMU is its own code; where it cannot be the reference
   goes into `verilator/ref/README.md`), plus directed page-fault tests.
2. `lwarx`/`stwcx.` and the cache instructions, `dcbz` first.
3. Instruction and data caches in block RAM, 32-byte lines; the HID0
   cache-control bits. The memory side becomes a line-fill bus to the SDRAM
   controller, which runs on its own clock, so the clock crossing is part of
   this step. Writes to memory by anything other than the CPU (disk DMA, the
   HPS loading a ROM) must go through or invalidate the data cache; the bus
   is defined with that in mind.
4. Timing and area: register files and SPRs in RAM, the FPU's input path,
   66 MHz with margin and 75 if it can be had. MEM may split in two if
   translation plus cache lookup does not fit one cycle; decided here with
   timing data.

How the rules apply, decided before step 1 and followed in it:

- A data access that faults in MEM is the one thing the pipeline had not had
  to do: the instruction in MEM is dropped, the one in EX behind it is
  cancelled before it commits (EX can only leave in the cycle MEM's access
  completes, so the fault gates that same `ex_leave`), and the fetch is
  redirected through the one flush. SRR0 is MEM's address. Earlier
  operations of the same instruction stay done, as for interrupts: `lmw`,
  `stmw` and the strings are restartable, and an update form has not written
  rA yet. Rule 1's invariant holds because the faulting operation wrote no
  status register.
- ISI is a marker carried with the instruction from fetch to EX, where it is
  taken like an illegal instruction: the instruction never executes.
- `stwcx.` is the one instruction that accesses memory and writes a status
  register (CR0). To keep the invariant it is two operations: the
  conditional store, then CR0 from the reservation's outcome, the shape an
  update form already has.
- 604 facts the RTL must follow: `dcbz` to a cache-inhibited or write-through
  page, or with the data cache disabled or locked, takes an *alignment*
  exception (604 manual 4.5.6); `lwarx` and `stwcx.` at a non-word-aligned
  address take alignment; `eciwx` and `ecowx` take DSI, since this machine
  has no external control facility (EAR[E] = 0).

**Step 1, address translation: done 2026-10-05.**

- `DSPPC604_mmu` sits between the pipeline and the two buses. Block address
  translation (four IBAT and four DBAT pairs, lowest match wins), then the
  segment register and a translation lookaside buffer per side, filled by a
  hardware walk of the hashed page table (both hash groups; one walker for
  both sides, data first). The walker sets the referenced bit when it loads
  an entry and the changed bit for a store, with byte writes to the PTE as
  the 604 does; a store that hits an entry whose C bit is clear walks again
  to set it. Neither is set when the access fails the protection check,
  which the architecture allows and dingusppc does too.
- Each TLB is direct-mapped, 64 entries, indexed by EA bits 14-19: the
  604's congruence class, so `tlbie` invalidates exactly what the 604 does,
  one entry in each. An entry holds the PTE fields and the segment's VSID;
  the segment register's keys and no-execute bit are looked up on every
  access, so `mtsr` needs no invalidation.
- A fetch or an access that hits is translated in the cycle it is requested:
  the TLBs are read a cycle ahead, with the address the fetch will present
  next (`pc_next`) and with the effective address as an access leaves EX. A
  data access to a page other than the one read ahead (the second word of
  an access crossing a page boundary) costs one extra cycle. With
  translation off nothing costs anything: the suite's cycle counts are
  unchanged.
- Exceptions as the manual lists them: DSI for no page, protection, a
  direct-store segment (nothing here serves one), `eciwx`/`ecowx`
  (DSISR[11]); ISI for no page, protection, no-execute segment, guarded
  memory, direct-store segment. DAR is the address of the word that failed,
  which for an access crossing into a bad page is the page boundary.
  `mtsr`, `mtspr` to SDR1 or a BAT, and `tlbie` refetch, like `mtmsr`.
- Verified (`python verilator\run_core.py`): a directed program with BATs,
  page tables in both hash groups, every cause of DSI and ISI with the exact
  DAR, DSISR and SRR1, accesses that cross into an unmapped page (the first
  word's bytes are stored, then the fault), `lmw` across a page, a stale
  entry used until `tlbie`, the keys in user mode, and the page table's R
  and C bits checked at the end (34 checks, 14 memory words); and random
  programs in lockstep with dingusppc with translation on, their data pages
  mapped 4 MB away from their addresses with read-only pages and holes that
  draw hundreds of DSIs per program, the DAR and DSISR copied by the
  handler into compared registers, and the page tables compared with
  dingusppc's at the end, R and C bits included. Five deliberate bugs
  (secondary hash, a key rule, C never set, EX committing behind a fault,
  TLB aliasing) each caught; the last only by lockstep, the first two only
  by the directed test.
- Where dingusppc cannot be the reference here: direct-store segments
  (it aborts), guarded memory (no ISI), `eciwx` (no DSISR); and its `tlbie`
  flushes every page translation, which only differs for software that
  forgets one. The random programs keep the code under a BAT, so no
  speculative fetch walks the table.
- Quartus, whole CPU: 12,049 ALMs (29%), 7 RAM blocks (the two TLBs, the
  branch target buffer, SPRG0-3), 61-65 MHz worst case over three runs.
  (Measured before step 2, which adds little.)
  The MMU itself is about 1,200 ALMs. The slowest paths are the operand
  forwarding network into the ALU and FPU, as before; the MMU adds to its
  fanout (the DTLB's read-ahead address comes off the effective-address
  adder) and a term to `ex_leave`. Two things learnt: the DTLB only became
  a RAM once its two read expressions were merged into one with a muxed
  address (as flip-flops it cost 3,900 ALMs and 8 MHz); and reading the
  ITLB ahead with the *redirect* address put branch resolution in front of
  the RAM, so it reads ahead with the predicted address and re-reads after
  a redirect into another page. For step 4.

**Step 2, the reservation and cache instructions: done 2026-10-05.**

- `lwarx` is a load that sets the reservation when it completes; `stwcx.`
  is two operations from the sequencer: the store, made only if the
  reservation is set and clearing it when it completes, then CR0 from the
  outcome (EQ for stored, SO from XER). So no memory operation writes a
  status register, and a `stwcx.` that takes a DSI leaves both CR0 and the
  reservation alone. There is no address compare and an exception does
  not clear the reservation, as on the 604 and in dingusppc. Both
  instructions take the alignment exception at a non-word-aligned address.
- `dcbz` is eight word stores of zero from the sequencer. It takes the
  alignment exception with the data cache disabled or locked (HID0[DCE],
  HID0[DLOCK]; DAR is the address as computed), decided in EX, and on a
  write-through or cache-inhibited page (DAR is the line), decided in MEM
  by the translation, through the same path as a DSI; the walker does not
  set C for a `dcbz` it then refuses. A DSI on `dcbz` names the line.
- `dcbf`, `dcbst`, `dcbi` and `icbi` translate their address like a load
  (`dcbi` like a store, and it is privileged), so they take the DSIs and
  set the R and C bits the architecture gives them, and otherwise do
  nothing until there is a cache. `dcbt` and `dcbtst` stay no-ops.
- Verified: a directed program (23 checks, 23 memory words: CR0 and memory
  after `stwcx.` with and without a reservation, across `sc` into user mode
  and back, with XER[SO]; `dcbz` zeroing a line and leaving its neighbours;
  all three alignment cases; the cache instructions on read-only, missing
  and cache-inhibited pages with the R and C bits), and the random lockstep
  programs, which now include `lwarx`/`stwcx.` pairs, `dcbz` (hundreds of
  DSIs on it with translation on) and, without translation, the other
  cache instructions. Three deliberate bugs each caught.
- Where dingusppc cannot be the reference: it sets its reservation before
  `lwarx`'s load and clears CR0 before `stwcx.`'s store, so the random
  programs keep the pair on a fixed, always mapped and word-aligned address
  (it has no alignment check either), and the test bench restores CR0
  after a `stwcx.` that faulted; its `dcbf`, `dcbst`, `dcbi` and `icbi` do
  nothing at all (no translation, no R bit), so the translated programs
  leave them out; it never takes `dcbz`'s alignment exceptions.

**Step 3, caches and the memory bus: design, decided before building.**

- Each cache is the 604's shape: 16 KB, four ways of 128 sets of 32-byte
  lines, indexed by address bits 11-5. Those bits are inside the page
  offset, so the index is the same virtual and physical and nothing can
  alias; the tag is the physical page number. The data cache is write-back
  with a dirty bit per line and write-allocate; the instruction cache is
  read-only. Replacement is a pseudo-LRU tree (three bits per set).
- The caches are drop-in replacements for the two buses the pipeline has
  today: a request with the physical address from the MMU (which
  translates in the request cycle), the line read with the index at that
  edge, the tag compared in the next cycle, and the answer one cycle after
  the request on a hit, exactly the test bench bus's timing. So the
  pipeline's fetch and MEM stages do not change and neither does the
  cycle count of a hit. The memory unit never issues two requests in
  consecutive cycles, so a store's write to the data RAM is never read in
  the same cycle; no bypass is needed.
- The page table walker reads and writes through the data cache, as the
  604's table search does: a page table entry software just wrote is in
  the cache, not in memory.
- The request kinds the data cache serves, from the memory unit through
  the MMU: word read and write with byte enables; line zero (`dcbz`, one
  operation again, allocating without a fill); flush (`dcbf`: write back
  and invalidate), store (`dcbst`: write back), invalidate (`dcbi`, and
  `icbi` which is passed to the instruction cache); and uncached word
  accesses for pages with I = 1, HID0 off, or a locked cache's misses.
  With translation off the attributes are the architecture's default,
  cacheable (W = 0, I = 0); device registers are reached through BATs
  with I = 1, as the ROM sets them up.
- HID0: ICE and DCE enable, ILOCK and DLOCK treat misses as
  cache-inhibited, ICFI and DCFI invalidate everything without write-back
  and clear themselves the cycle after (manual 2.1.2).
- One memory port leaves the CPU, data before instructions: a request
  (level, until acknowledged) for one 32-byte line or one word with byte
  enables, read or write, with the whole line of write data presented in
  parallel and the whole line of read data returned with the acknowledge.
  One request outstanding. That is the shape the clock crossing to the
  SDRAM controller wants: the request and its data stand still while a
  toggle crosses, the answer and its data stand still while another
  toggles back. Critical-word-first and a second outstanding request are
  later refinements, if the measured speed asks for them.
- Coherence with the rest of the machine: a snoop port. Anything that
  reads or writes memory behind the CPU's back (disk DMA, the HPS loading
  a ROM, video) presents the line address first; the data cache writes the
  line back if it is dirty, invalidates it for a write, and acknowledges;
  the instruction cache invalidates for a write. The external access goes
  ahead after the acknowledge. Nothing else keeps the caches coherent,
  there being one processor.
- For the tests: the test bench's memory model serves the line port with
  random wait states, and the lockstep programs end by flushing the data
  region with `dcbf` so that the final memory comparison with dingusppc,
  which has no cache, sees the written-back data. A directed test covers
  hits, misses, evictions and write-back, every cache instruction, the
  snoop port and the HID0 bits.

**Step 3, the caches and the clock crossing: done 2026-10-05.**

- `DSPPC604_cache`, twice, as designed above: 16 KB, four ways of 128 sets
  of 32-byte lines, pseudo-LRU, write-back and write-allocate on the data
  side, read-only on the instruction side; `dcbz` allocates a zero line
  without a fill (one operation again, not eight); `dcbf`, `dcbst`, `dcbi`
  do what they say; `icbi` reaches the instruction cache through the data
  cache; uncached words for cache-inhibited pages, a disabled cache or a
  locked cache's misses; write-through stores update a line if present
  and go to memory, allocating nothing. HID0[ICE], [DCE], [ILOCK], [DLOCK],
  [ICFI], [DCFI] as the manual says, the two invalidate bits acting once
  and clearing themselves (a 128-cycle sweep, also after reset). The page
  table walker goes through the data cache.
- A read hit takes the next request behind it, so fetches flow one per
  cycle; a store's RAM write happens in its answer cycle, which nothing
  else reads (the memory unit and the walker leave a cycle between
  accesses).
- `isync` now refetches, like `mtmsr`: a `blrl` whose target the branch
  target buffer knows is fetched before an `icbi` ahead of it completes,
  and the architecture's `isync` is what discards that. `mtspr` to HID0
  refetches too.
- The snoop port: both caches answer in their own time (a dirty line is
  written back first), the core combines the answers, and the instruction
  cache serves an `icbi` as soon as its own part of an external snoop is
  done so that neither can hold up the other.
- The test bench's memory model serves the line port with random wait
  states; the lines the data cache may hold dirty are collected from a new
  trace port (every data access as it reaches the cache) and written back
  through the snoop port when the program ends, as a DMA engine would, so
  that the memory comparisons see them. The same trace port carries the
  interrupt tests' acknowledge store, which the cache would otherwise
  absorb. The bench also has a DMA engine on the snoop port.
- Verified: everything that ran before runs through the caches (48 runs);
  a directed program (30 checks, 34 memory words) with nine lines in one
  set (evictions and write-back), what memory holds after `dcbf`, `dcbst`,
  `dcbi` and DCFI, with the cache locked or off, and on a write-through
  page, all seen through a cache-inhibited alias of the same physical page;
  self-modifying code with `dcbst`/`icbi`/`isync` and with ICFI; DMA in and
  out through the snoop port, with the CPU holding the lines clean and then
  dirty. Three deliberate bugs (dirty bit not set, write-back to the wrong
  address, snoop without write-back) each caught, two of them by the
  lockstep programs as well.
- The random lockstep programs lose `dcbi`, which with a real cache throws
  away stores that dingusppc, having no cache, keeps; the directed tests
  have it. The end-of-run write-back made the `dcbf` epilogue planned above
  unnecessary.
- Cost in cycles: the 131,770-instruction straight-line golden program,
  every line of which is a compulsory miss, goes from 1.36 to 1.85 cycles
  per instruction with an ideal line port, and from 4.29 to 2.04 with 60%
  wait states; the random lockstep programs stay at about 2.6, the caches
  absorbing their memory traffic entirely.
- Synthesis lessons: Quartus 17 inferred the instruction cache's data as
  RAM but built the data cache's from flip-flops (141,000 registers, three
  times the device), because a byte-enabled write into a two-dimensional
  unpacked array is not a shape it recognises; each way's data now lives
  in `DSPPC604_cache_ram`, a one-dimensional array of packed bytes in a
  module of its own, the handbook's template. It also refuses a variable
  part-select of a two-dimensional array, `genvar` inside the `for`, and a
  generate loop without `generate`. Verilator accepts all of these, so
  only a Quartus run finds them.
- Quartus, whole CPU with the caches: 14,234 ALMs (34%), 10,796
  registers, 77 RAM blocks (14%; the two caches' data and tags, the TLBs,
  the branch target buffer, SPRG0-3), 7 DSP blocks, 55.2 MHz worst case.
  Above the 50 MHz floor, below the 66 MHz target. The slowest paths run
  from the data cache's tag RAM through the four-way compare, the way and
  word select, the memory unit's byte shifting and the single-to-double
  conversion into `wb_result`: the cache's answer cycle and the memory
  unit's formatting in one cycle, which is where the plan said MEM might
  have to split. For step 4, together with the forwarding network.

**Step 4, timing and area: in progress.**

- Two cuts with no cost in cycles, each measured on its own: the cache
  picks the word within each way before the tags are compared, so only a
  four-way choice follows the compare (55.2 to 57.0 MHz); the MMU reads
  the segment register a cycle ahead with the TLB entry, so its 16:1
  choice leaves the lookup's cycle (57.0 to 58.2 MHz; `mtsr` marks the
  copy stale, and a directed case switches VSIDs with translation on).
  14,340 ALMs, 77 RAM blocks.
- The "MEM may split in two" question, measured: with the data cache
  answering from a register a cycle later (`LATE_ANSWER`, kept as a
  parameter), the cache's path leaves the top of the list but the clock
  only goes from 58.2 to 58.5 MHz, because the next path is 0.1 ns
  shorter: the operand forwarding muxes into the ALU's adder and shifter.
  The cost was 9% more cycles on the plain lockstep programs, 12-14% on
  the translated ones, and 4.34 instead of 3.46 cycles per instruction on
  the floating-point golden program. So not until EX is faster; the
  answer stays at one cycle.
- What remains, in order of the slack, all within about 0.3 ns of each
  other at 75 MHz (3.6 to 3.9 ns short): the forwarding network into the
  ALU (the 7-bit compares and the three-way operand muxes, then the adder
  or rotator, then everything EX decides from the result: the effective
  address into the MMU's lookup and the cache's request, the alignment
  checks, the trap compares, the redirect); the data cache's answer cycle
  into `wb_result`; the forwarded operands into the FPU's first stage.
  Candidates, none tried: deciding the forwarding selects a cycle earlier
  at the ID/EX edge (this touches the one hazard mechanism, rule 2, so it
  is to be agreed first); taking the trap condition from the ALU's
  compare flags instead of separate comparators; registering the FPU's
  operands inside the unit (a 9th cycle on an 8-cycle operation); and
  then the registered cache answer again once EX allows it. The register
  files in RAM save area, not time, and wait.
- `DSPPC604_memcdc` carries the memory port into the memory controller's
  clock and the answer back: the request and its write data are captured
  once and stand still while a toggle crosses through two flip-flops, the
  read data likewise on the way back. About two cycles of each clock each
  way. Verified by a two-clock Verilator bench (`cdc_main.cpp`) with random
  line and word requests against a software memory at 66 against 100, 130,
  66 and 50 MHz, 100 against 66, and two clocks a hundredth apart. The
  SDRAM controller on the far side of it belongs to the machine (M6).
- 2026-10-06, after the 7300 corrections: the same RTL fitted again came
  out at 56.0 MHz worst case (14,254 ALMs, 11,900 registers, 77 RAM
  blocks), 2 MHz under the earlier run of nearly the same design: the
  fitter's swing. Of the 400 slowest paths, 394 ran from the data cache's
  tag RAM to `wb_result` (4.4 ns short at 75 MHz), 5 from the forwarding
  select `fa_wb` to the data cache's RAM address (4.0 ns), 1 from the tag
  RAM to a forwarded operand (3.9 ns); the FPU's operand path was not among
  them this time.
- The trap condition from the ALU's compare flags, built: `tw` and `twi`
  are decoded as a compare in the ALU (b - a, as `cmp` now is too) and the
  TO field tests the adder's carry, sign and overflow; the three
  comparators on the forwarded operands are gone, and `cmp` no longer has
  comparators of its own either. No cycles cost; the whole suite and
  `run.py` on both vector files pass. Fmax: see below.
- A register on the FPU's operands, built behind `OPERAND_REG` (a
  parameter of `DSPPC604_fpu`, `FPU_OPERAND_REG` on the core): the
  operands, control and FPSCR are taken into registers in the request
  cycle and the unit works from those a cycle later, so the forwarding
  network ends at a register. Cost: one cycle on every floating-point
  instruction (the moves, `fsel` and the compares one instead of none):
  3.46 to 3.53 cycles per instruction on the floating-point golden program,
  3.74 to 3.81 on the 7300's, 4.3-4.8 to 4.7-5.3 on the random
  floating-point programs (dense with floating point), integer code
  untouched. Whole suite green either way. Fmax: see below.
- Fmax with the trap change (FPU register off): 57.4 MHz worst case,
  14,002 ALMs (252 fewer: the comparators), 11,839 registers; with the FPU
  register on as well: 54.8 MHz, 13,888 ALMs, 11,590 registers, and no FPU
  path among the 1,600 slowest (it had been 2.6 ns short with the register
  off). The Fmax figures swing with the fitter by 2-3 MHz between runs of
  near-identical designs; the slowest paths are the same every time and are
  what to judge by.
- The slowest paths cell by cell (`quartus_sta` with `report_timing -detail
  full_path`, on the trap-change fit, 75 MHz constraint):
  - Tag RAM to `wb_result`, 3.9 ns short: the tag RAM's output register
    (the M10K's own, 2.5 ns clock-to-out where a flip-flop takes 0.6) is
    6.5 ns after the clock edge; the four-way compare and the way select
    take it to 12.1; the memory unit's byte shift to 14.4; then **6.5 ns of
    `lfs`'s single-to-double conversion** (the leading-zero count, the
    exponent subtract and the final mux, with 3.6 ns of routing) to 20.9.
    The conversion sat in series on every load.
  - A forwarding select to the MEM registers' enables, 3.3 ns short: the
    operand mux (1.4 ns of routing), the rotator and the ALU's result mux
    (5.5 ns), the string operation's 4 KB-boundary adder and compare
    (1.9 ns), `ex_abort` with its fan-out of 295, and 2 ns of routing to
    each enable. The rotator is on the path because the result mux waits
    for its slowest input, whatever the instruction; the effective address
    and both alignment checks took the result mux's output.
  - `ex_dec.frc` to the FPU's `fin_result`, 2.6 ns short (register off):
    the seven-bit forwarding compare in two levels, 4.1 ns with routing; the
    operand mux, 1.7; the FPU's operand classes, special results and result
    mux, 8.5.
  - Forwarding selects and `wb_result` to the caches' RAM address ports and
    the data cache's LRU array, 3.8 to 4.3 ns short: the handshake chain.
    `ex_stall` (the forwarding compares) and the units' responses decide
    `ex_leave`, which decides `id_take`, `if2_leave` and `if_req` in the
    same cycle, and the caches take a request combinationally, so the
    instruction cache's read index waits on EX's hazard decision.
- Two more cuts without a cycle's cost, built on that: the conversion of a
  single loaded by `lfs` is made in WB from the registered word (`wb_value`,
  which the FPR write and the forwarding from WB use; a GPR never needs it),
  and the effective address, both alignment checks and DAR take the adder's
  sum straight from the ALU (`sum`, a new output) instead of the result
  mux. Whole suite and both vector replays green, cycle counts unchanged.
  Fmax with both, the trap change and the FPU register on: 58.5 MHz worst
  case (60.4 MHz at the hot corner), 15,579 ALMs, 13,691 registers (the
  fitter's retiming and duplication grew: the cache path is no longer the
  one it works on). The cache path went from 4.4 to 3.1 ns short and from
  the top of the list to sixth. What is on top now, 3.2 ns short, in one
  family: from a forwarding select (one the fitter had already retimed into
  a register of its own) through the operand mux (2.0 ns), the ALU's adder
  (2.3), the string operation's 4 KB adder and compare (1.7), `x_align`
  and `ex_abort` with a fan-out of 600 (1.1 plus 1.7 of routing), the commit
  enable `ex_leave & ~ex_abort` with a fan-out of 157 (1.4), into the CTR's
  next-value mux and a register the fitter retimed into the middle of
  `ctr - 1`. Then the branch condition into the branch target buffer's
  write (3.1), the cache's answer into `wb_result` (3.1), and the cache's
  hit decision into the data RAM's write data (2.5).
- The configuration committed (the three cuts, the FPU register off):
  59.5 MHz worst case (59.6 at the hot corner), 14,212 ALMs, 11,103
  registers, 77 RAM blocks, 7 DSP blocks. Its slowest paths, 3.2 to
  3.5 ns short at 75 MHz, are the same family as above from the other
  end: a forwarded operand through the adder and the alignment checks into
  SRR0, DAR and `pc_f` (the exception and redirect decisions), the
  forwarding compare of operand C into a register the fitter retimed into
  the decoder's output, the fetch address into the MMU's segment-register
  read-ahead, and ID's decode and register read into `ex_a`. The first of
  these, cell by cell (`check.py --detail`): `ex_dec.rc` to the compare
  `fc_mem`, 3.2 ns of which 1.9 is routing; `ex_stall`, `ex_done` (2.0 of
  routing), `id_take` with a fan-out of 354, ID's load enable with 114,
  `id_insn`, the decoder, 16.1 ns in all. So in this fit the forwarding
  compare does head the handshake chain, not retimed; the rule-2 proposal
  below is what would take it off, and the enables' fan-out is the
  rule-free part of the same chain.
- What that says about the remaining candidates. The seven-bit forwarding
  compares are already registers in the fitter's hands (physical synthesis
  retimes them, their inputs all being registers), so the proposal below
  would buy less than the 4 ns the compare shows in a path where the fitter
  did not retime it; the string check, the commit enable's fan-out and the
  cache's same-cycle hit decision (which `mem_ready`, hence `ex_leave` and
  the whole fetch handshake, wait for) are what remain. 66 MHz needs 1.8 ns
  from this list, 75 MHz 3.2.
- **Proposed, decided 2026-10-06: not now.** The cuts that touch no rule
  come first; this is to be revisited with the measured gap in hand if
  they fall short of 66 MHz. The proposal, kept for then: deciding the
  forwarding selects at the ID/EX edge. Today EX compares, every cycle, the
  seven-bit names of the registers it reads with the destinations of the
  operations in MEM and WB, and the three-way operand muxes follow those
  compares; the compare sits in front of the ALU, the FPU and everything EX
  decides. The proposal keeps the one set of comparisons and the one stall
  condition that rule 2 asks for, but makes them at the ID/EX edge, against
  the operation that is moving from EX to MEM and the one moving from MEM to
  WB, and carries the outcome into EX as a two-bit source per operand (own
  value, MEM, WB). While an operation is held in EX the sources age by rule:
  MEM becomes WB when MEM's operation leaves, and WB becomes the captured
  value a cycle later (what the "held here" code does today), and nothing
  new can enter MEM in the meantime. The stall condition (the source is a
  load in MEM) reads the same two bits. What changes is when the comparison
  is made, not how many there are or who declares the registers; the
  decoder's declarations stay the one source. Cost: a few flip-flops; no
  cycles. Expected gain: the seven-bit compares and their fan-out leave the
  EX cycle for good, where today the fitter's retiming does it for some
  paths and not others (the FPU's operand path showed the compare at 4.1 ns
  with the FPU register off); the stall decision `ex_stall` becomes a
  register's output, which shortens the fetch handshake chain that waits
  on it. Measured value unknown until built; the fitter's own retiming
  makes it smaller than first thought.
- Also open, no rule touched, in the order of likely gain: the string
  operation's 4 KB check from the operands in parallel with the adder (a
  three-input 13-bit add; about 1.7 ns off the commit-enable chain);
  registering the data cache's hit for the *handshake only* while the
  data still answers in the same cycle is not possible, so the cache's
  same-cycle hit stays unless the answer moves (`LATE_ANSWER`, 9-14 % of
  the cycles); the tag RAM in MLABs instead of M10Ks (about 1 ns of its
  2.5 ns clock-to-out, for 18 MLABs).
- The string operation's 4 KB check from the operands, built (2026-10-06,
  the sixth cut): the first access crosses when its last byte is in
  another page than its first, which `a[11:0] + b[11:0] + (count - 1)`
  and the carry out of `a[11:0] + b[11:0]` decide without the ALU (the
  bit above the page offset of the first differs from the carry of the
  second); the 256 MB check and the word-alignment bits take the adder's
  sum as before. Written as one three-input expression, Quartus built two
  adders in series, 4.2 ns from the operand mux to `x_align`: 60.8 MHz,
  and the top path (3.0 ns short) ran from the forwarding compare through
  that check and `x_align` into the redirect and the branch target
  buffer's read address. Written as a 3:2 compression into one adder,
  beside the 12-bit adder for the carry: 61.7 MHz worst case (61.9 at the
  hot corner), 14,290 ALMs, 11,308 registers, 77 RAM blocks. Whole suite
  and both replays green, every cycle count unchanged. The EX decision
  family is off the top of the list. What leads now, at 75 MHz: the data
  cache's answer into `wb_result` (2.8 ns short: the tag RAM's 2.5 ns
  clock-to-out, the valid and tag compare, the way select with a fan-out
  of 173 and 1.9 ns of routing, the memory unit's byte shift), a
  forwarded operand through the ALU into CR (2.6), ID's decode and
  register read into `ex_b` (2.5), the exception redirect into the branch
  target buffer's read address (2.5), a forwarded operand into the FPU's
  first stage (2.3) and into `mem_result` (2.2). 66 MHz needs every path
  above about 1.8 ns short at this constraint.
- The commit enable's fan-out, built (2026-10-06, the seventh cut): only
  `mem_valid` waits for the abort decision; MEM's data registers load on
  `ex_leave` alone, a dropped operation's values included, since everything
  that reads them (the memory unit's request, the forwarding compares, the
  fault, WB) is qualified by `mem_valid`. Nothing a handler can see changes
  on an aborted operation (rule 1); the hazard mechanism is untouched. Whole
  suite and both replays green, cycle counts identical. 62.3 MHz worst
  case (63.1 at the cold corner), 14,366 ALMs, 11,161 registers.
  `ex_abort` is now on none of the reported paths; the commit enable
  appears once, fed by the data cache's hit decision through `mem_ready`
  (fan-out 43) and the enable (21) into XER at about zero slack. The 2,000
  slowest paths are now one family, 2.3 to 2.7 ns short: a single loaded by
  `lfs`, converted in WB (the leading-zero count and shift, 3 ns) and
  forwarded into an FPU operation that finishes in its request cycle, the
  NaN class into FPSCR, the enabled-exception decision `x_fpen`, the
  redirect into `pc_f` and the branch target buffer's read address; the
  same head runs into the FPU's first stage (2.3), its compare into CR
  (1.7) and `fsel` and the moves into `mem_result` (1.1). Two ways to
  take it off, both to be measured: the FPU operand register
  (`FPU_OPERAND_REG`, a cycle per floating-point instruction), or one more
  term in the one stall condition, an FP operation whose operand is an
  `lfs` single still in WB waiting a cycle as it waits for a load in MEM
  (the "held here" capture then has a whole cycle for the conversion),
  which costs a cycle only within two instructions of the `lfs` but
  changes how a hazard is handled, so it is for the owner to decide.
- The branch target buffer taught a cycle later, built and measured, not
  taken (2026-10-06). From registered copies of index, tag, target and
  counter, the branch condition leaves the RAM's write cycle; no cycle
  changes. But Quartus then adds pass-through logic to the three arrays to
  deliver the new entry to a fetch that reads it at the same edge (the
  mapper's warning 276020): 674 more registers, new endpoints on the fetch
  address path (`id_insn` into `btb_*_bypass`), 59.7 MHz, and `ramstyle =
  "no_rw_check"` on the arrays is ignored (a bit-identical refit). Written
  as the RAM works, the read synchronous with the next fetch address and
  the old entry on a read-during-write: no pass-through, 13,781 ALMs,
  11,318 registers, 58.9 MHz in a fit led by the `lfs` family, and every
  random lockstep program 0.13 to 0.30 % longer (a two-instruction loop
  reads its branch's entry in the cycle it is written and mispredicts
  once more), the golden, floating-point and directed programs unchanged.
  And the write path has not been among the slowest families since the
  sixth cut: the buffer's endpoints in the lists are its read address,
  reached from the exception and branch decisions through the redirect,
  which this does not touch. So it buys nothing now and costs either logic
  or cycles; if the write path ever returns to the top, the synchronous
  read is the form, at that cost. The RTL stays as after the seventh cut.
- The `lfs` stall, measured on a copy of the tree (2026-10-06): one more
  term in the stall condition, `wb_fsgl & (ffa_wb | ffb_wb | ffc_wb)`, and
  EX's floating-point operand muxes taking from WB the word as loaded
  (`wb_result`) instead of `wb_value`, so that a single's conversion is on
  no path into the FPU; the "held here" capture and ID's read keep the
  converted value. The stall alone changes nothing for timing: the path
  through the mux exists whether or not the stall makes it a don't-care.
  With both: the whole `lfs` family gone from the 4,000 slowest paths,
  62.8 MHz worst case on a fit that still carried the buffer's
  pass-through logic, 14,434 ALMs; the five random floating-point programs
  0.17 to 0.21 % longer, the 45 other runs identical. What leads then, 1.7
  to 2.5 ns short: the data cache's answer into `wb_result`, the decoder
  into the fetch handshake (through the sequencer's wait for XER), the
  register-read indexes out of the decoder's case tree, and the branch
  condition into the redirect through the compare of `next_pc` with the
  prediction. Not committed: it changes how a hazard is handled (rule 2's
  one stall condition gains a case), for the owner to decide against the
  FPU operand register's 2 to 10 %.
- The data cache's tag RAM in MLABs: not to be had from Quartus 17
  (2026-10-06). Six forms were tried with map-only runs on a copy of the
  tree, each a minute: `ramstyle = "MLAB"` alone and with `no_rw_check`
  on the struct-typed two-dimensional array (behind a `TAG_MLAB`
  parameter, in a generate branch), on a plain-vector array per way in the
  data RAMs' own shape, on a module-level plain array, as the comment
  pragma `/* synthesis ramstyle = "MLAB" */`, and a `RAMSTYLE_ATTRIBUTE
  MLAB` instance assignment with an explicit and a wildcard target. Every
  one inferred the RAM with `RAM_BLOCK_TYPE = AUTO` and the fitter put it
  in M10Ks (the one full fit was bit-identical to the seventh cut's); the
  data RAMs' `no_rw_check` shows the same, their read-during-write mode
  being `OLD_DATA` on every RAM. So this flow takes no RAM style
  attribute, and the tag RAM's 2.5 ns clock-to-out stays unless the RAM
  is instantiated as a primitive, which the CPU does not do. The RTL is
  unchanged.
- The list above exhausted at 62.3 MHz, the FPU operand register on
  (`FPU_OPERAND_REG = 1`, 2026-10-06), as the plan's fallback: the `lfs`
  family is gone from the lists. Cost measured on this base: 2.0 % on the
  floating-point golden programs (3.46 to 3.53 and 3.74 to 3.81 cycles per
  instruction), 9 to 10 % on the random floating-point programs, 0.02 to
  0.05 % on the lockstep programs, the integer golden programs unchanged.
  Fit: 60.3 MHz worst case (62.5 at the cold corner), 15,480 ALMs, 13,573
  registers (the fitter's duplication grew by 2,400). What leads now, with
  nothing of the FPU in the 4,000 slowest paths: ID's decode into the
  register-read muxes, 3.3 ns short with 1,335 paths (`id_insn` through
  the decoder's case tree to its `seq` field, the sequencer's selects for
  the read indexes with a fan-out of 163, three levels of the 33:1 mux);
  the data cache's answer into `wb_result` (2.5); the cache's hit decision
  into the fetch handshake and ID's load (2.4); the forwarding compares
  through the effective address into the data cache's request (2.4). The
  `lfs` stall (0.2 %) would replace this parameter if chosen.
- The register-read indexes off the decoder's case tree, built (2026-10-06,
  the eighth cut): which field names each operand is a small function of
  the opcode (A is rS, the rD field, for the rotates, the logical and
  shift instructions and the moves to CR, the SPRs, MSR and the segment
  registers; B is rA for `rlwimi`; C is always rS), decided at the top of
  the decoder instead of in each arm of its case, so the register file's
  33:1 read mux starts from the instruction word; the sequencer's
  overrides of the indexes (the scratch register for `lswx` and `stswx`,
  the next register of a multiple or string store) are gated by its own
  step and a direct opcode compare for `lswx`/`stswx` (an input of the
  sequencer, which also decides its wait for XER, so the decoder is out of
  the fetch handshake) instead of the decoded `seq` field; at step 0 the
  overrides are identities. The hazard compares still take the decoder's
  declarations unchanged. Whole suite and both replays green, cycle counts
  identical. 64.1 MHz worst case (65.2 at the cold corner), 15,556 ALMs,
  13,554 registers: ID's family is gone from the 4,000 slowest paths. What
  leads, 2.3 ns short: a forwarded operand A through the operand mux (3 ns
  with routing), the string operation's 4 KB adders (2.5) and `x_align`
  into `ex_abort`, then 6 ns of redirect logic and routing into the branch
  target buffer's read address; then the operand into the data cache's
  request (2.0) and the cache's answer into `wb_result` (2.0: the tag
  RAM's 2.5 ns, the compare, the way select with a fan-out of 178, 2.1 ns
  of routing into the memory unit's byte shift). 66 MHz needs 1.8.
- The string check once per source of A, built (2026-10-06, the ninth
  cut): the 4 KB test is made for the register, for MEM's result and for
  WB's, and the forwarding selects choose among the three bits, so the
  32-bit operand mux (3 ns with routing) is not in front of it; B is the
  sequencer's displacement, so `ex_b` is B. About 60 ALMs. Whole suite and
  both replays green, cycle counts identical. The family is gone from the
  list. 62.9 MHz worst case in this fit, with the cache's answer swung
  from 2.0 to 2.6 ns short on the same logic (3,567 paths; the fitter's
  variance on a path with 3.4 ns of routing in it) and ID's residual path
  2.1 ns short: the sequencer's `uop = '0` in its two nop cases zeroes the
  index fields behind the decoded `seq`, which the next cut takes out.
  The cell-by-cell report of the cache's answer, after the tag RAM's
  2.5 ns: the valid and tag compare 2.3, the encoded way select with a
  fan-out of 178 and 1.9 ns of routing, the way mux 0.9, the hit/miss
  data select 1.8, 2.0 ns of routing into the memory unit, its two-word
  window and byte mask 1.0, 1.4 ns into the WB mux. What the fitter adds
  in routing there is what would have to go.
- Two small ones, built together (2026-10-06, the tenth cut): the
  sequencer's three index assignments made unconditional after its case
  (its two nop cases zeroed the whole operation, which put the decoded
  `seq` back in front of the read indexes: `id_insn` into `ex_a` 2.1 ns
  short), and the HID0 flash-invalidate registered, so that the commit
  decision (`ex_abort`, a net of 698 inputs) no longer reaches the data
  cache's grant and RAM address through `inval_all`, which the cache takes
  combinationally (2.0 ns short, 730 paths); the invalidation starts a
  cycle later, which nothing can see, the instruction after the `mtspr`
  being refetched. Whole suite and both replays green; the cache directed
  test is 2 cycles longer out of 1,419 (one per flash invalidate), every
  other count identical. Fit: 64.8 MHz worst case (65.8 at the cold
  corner), 15,598 ALMs, 13,387 registers; the cache's answer into
  `wb_result` leads at 2.1 ns short with 1,998 paths, and every other
  family is above 1.64, that is above the 66 MHz line (1.82) for the
  first time; ID's residual path is gone.
- The one-hot way select in the cache's answer, built (2026-10-06, the
  eleventh cut): each way's hit gates its own word and the four are ORed,
  instead of an encoded two-bit select with a fan-out of 178 in front of
  a 4:1 mux; the encoded number stays for the victim and the LRU. Whole
  suite green, cycle counts identical. On the tenth cut's base: 63.7 MHz
  worst case (64.2 at the cold corner), 15,678 ALMs, 13,202 registers;
  the cache's answer into `wb_result` is 1.4 ns short and off the top of
  the list (the tag RAM's 2.5 ns, the compare 3.0 with a fan-out of 147
  on each way's hit and 2.3 ns of routing, the AND-OR 0.5, the hit/miss
  select 2.1, the memory unit's window and mask 1.7, 1.7 ns into the WB
  mux). What leads now, 2.4 ns short with 392 paths: the memory unit's
  second-word address, `addr + 4` made with a 32-bit adder in the request
  cycle for the second word of a misaligned access, through the MMU's
  translation into the data cache's RAM address (`mem_unit|state.S_REQ1`
  and `mem_ea` into `word.ram`); a register with the address plus four,
  loaded with `mem_ea`, and a mux would take the adder out. Then the
  decode of `mtspr` and the refetching instructions through the redirect
  into the ITLB's read-ahead (2.0), and the cache's hit decision into
  the redirect and `pc_f` (1.75). Between this fit and the tenth cut's,
  the same families move by up to a nanosecond: the second-word adder is
  below 1.4 ns short in the one and 2.4 in the other, the cache's answer
  2.1 and 1.4. So the design sits at the 66 MHz line, each fit putting
  one family or another just past it; what remains is as much the
  fitter's placement as the logic.
- The write decided from the tags, landed a cycle later (2026-10-08, the
  speed session's twelfth cut). In the whole machine (build 29, 65 MHz
  asked, slow 100 C), 575 of the 600 slowest paths ran from the data
  cache's tag RAM through the hit decision into its own RAMs' write ports:
  a store hit's merged word and write enables (`st_word`, `data_we`,
  `tag_we` for the dirty bit), 14 ns of which 2.4 is the M10K's clock
  skew and 8 is routing. Now a write that S_LOOK or S_SNOOP decides (a
  store hit, a line zero, a flush's, invalidate's or snoop's tag clear) is
  taken into registers (`wr_*`) and written at the next edge; nothing reads
  the RAMs in that cycle (`gnt` and the snoop wait on `wr_pend`), and no
  other write can land then (S_WB and S_FILL write on `mem_ack`, two
  cycles away at the soonest). The answer's timing is unchanged; only a
  request or a snoop arriving in the very cycle after such a write waits
  one cycle, which the memory unit's and the walker's spacing already
  rules out. The golden programs: 1.85, 1.89, 2.04 and 3.53, 3.61 cycles
  per instruction, as before. The hazard mechanism and the commit points
  are untouched (a cache-internal timing of its RAM writes). Build 31:
  -0.32 ns at 65 MHz (64.0 MHz slow corner) from build 30's -2.01 on the
  same tree. On the board Speedometer's Towers and Permutations lost
  8-10 %: their recursion stores and asks again in the very next cycle, so
  the memory unit's spacing does not rule the wait out after all. Refined
  (2026-10-09): only a request or snoop to the pending write's own set
  waits (`wr_clash`, `wr_sclash`: the eight word RAMs and the tag RAM
  conflict at one index only); another set goes ahead. Also a read-only
  cache no longer muxes its RAMs into the write-back address and data
  (`WRITABLE` guards on S_WB and `mem_wdata`): the I-cache's tag RAM into
  the machine's device register through that unused mux was build 31's
  worst path. Whole suite, `run.py` and the 300 M lockstep green, cycle
  counts identical. Timing and the board: builds 33 (65 MHz) and 34
  (70 MHz).

### M6: real ROM, first MiSTer build

- Run the 7600's own ROM from the reset vector in Verilator against a stub
  machine, in lockstep with dingusppc, until it needs hardware that is not
  there. The 7300's ROM (`ppctest/runs/my7300.rom`: `077D.34F2`, header
  checksum `960E4BE9`, CRC32 `7910CDF9`) is dumped too, and is the
  reference ROM since 2026-10-07 (below).
- Put the CPU in the MiSTer project with memory and the ROM; get a first
  bitstream that executes ROM code and reports over the UART.
- Timing closure at 66 MHz, then try 75.

What the 7300 run's `probe` group says about the state the ROM leaves the
CPU in at the Open Firmware prompt, which is where the lockstep run will
arrive (2026-10-06): HID0 `8000C084` (EMCP, both caches enabled, HID0[24],
BHT), the segment registers 0-15 holding VSID 0-15 with no keys, no BATs of
its own (the test program's own BAT3 was the only one set), SDR1
`0FFE0000` (a 64 KB page table at 0FFE0000, the top of 256 MB), the
decrementer running, the time base running, a decrementer interrupt left
pending, PMC1 counting. The firmware's own entry MSR is in the run's slot
header on the disk image (`ppctest.py results` prints it), not in the CSVs.
With translation off the 604 treats memory as cacheable, so device registers
must be reached through BATs with I = 1, which is what the ROM sets up; a
read of RAM space beyond the installed memory returns 0 with no exception.

**Step 1, the ROM in Verilator, done 2026-10-06.** The machine is
`rtl/machine/`: `MacPPC7300_system` (the CPU, `MacPPC7300_machine`, the clock
crossing), the 7600's map taken from dingusppc's `machinetnt.cpp` with file
and line for each entry, and register stubs that answer as dingusppc's
devices do from reset (`docs/MacPPC7300_stubs.md` lists every one).
`verilator/core_main.cpp` builds a second time as `machine_tb` with the whole
system as its top and a software memory in its own clock on the far side of
the crossing; `verilator/run_machine.py` runs it.

The lockstep decision: the reference stays dingusppc's CPU alone, given the
ROM (`ref_add_rom`) and a device range whose reads return what the core's
machine returned (`ref_add_mmio`); `mftb` and `mfdec` get the core's values
and the decrementer and external interrupts are taken where the core took
them (`ref_interrupt`). Linking dingusppc's whole machine into the lockstep
instead would make every polling loop and timer diverge, its devices
running on dingusppc's instruction-counted time and not the core's cycles.
The device side is checked separately against dingusppc's whole 7600
(`verilator/machref`, headless, logging every device access):
`machref/devdiff.py` compares the two logs.

What happened, with 16 MB:

- **The CPU got nothing wrong.** 150 million instructions in lockstep, the
  registers and MSR identical after every one, 4.9 million device reads
  mirrored and 33,363 device writes compared for address, size and data.
  1.7-1.9 cycles per instruction (caches on from the 29th instruction).
- **The machine needed one fix**: the ROM reads Hammerhead's CPU ID at its
  40th instruction through the data cache, before any BAT (with data
  translation off the 604 caches everything), so a line request to a device
  is now eight word accesses to it, as a burst on the real bus would be. The
  bench learned that cached stores to RAM space beyond the installed memory
  stay in the cache (the ROM's RAM sizing stores, flushes with `dcbf` and
  reads back).
- **Where it stops**: after 18,273,849 instructions Open Firmware's Cuda
  routine (FF80AAC8, FF80AB74) sets up the VIA, asserts TIP and polls the
  VIA's interrupt flags for the shift register's bit with no timeout. Cuda
  (the 68HC05 behind the VIA: power, reset, real-time clock, PRAM, ADB) is
  not built, so nothing ever answers; the run was taken to 150 million
  instructions, all in that loop (FF809C7C-FF80BB00, FF838BC0-FF838EA0).
  dingusppc's Cuda answers there after 142 polls.
- **On the way**, compared with dingusppc's whole machine: the ROM's first
  Cuda exchange (instructions 140-69,404 on dingusppc) times out here (the
  ROM's loops have counter timeouts), costing 70,000 instructions; from there
  to the endless poll the two machines make the same device accesses in the
  same order (only values differ), within 1 % of each other in instruction
  count (18.27 against 18.15 million). The values that differ are the RAM
  sizing's: the ROM writes 04 to each Hammerhead bank register and 01 to
  NVRAM where dingusppc writes 08 and 02, RAM beyond the installed size
  reading 0 here (as measured on the 7300) and all ones in dingusppc.

**Step 2, the memory-test boot program, done in the bench 2026-10-06.**
`progs.py memtest` generates `rtl/machine/MacPPC7300_bootrom.sv` (67
instructions in an 8 KB ROM mirrored over the ROM's 4 MB when the OSD's Boot
option says so). It turns the caches on, maps RAM cached and the devices
inhibited with two DBATs, then each pass writes every word of the installed
RAM with its address XORed with a per-pass seed, pushes every line out with
`dcbf`, reads it all back and counts errors, reporting through the machine's
debug registers at F9000000 (not a 7600 device; the debug readout shows
them). Passes in the bench over 1 MB (3 passes, 3.3 million instructions
each) and 6 MB with 30 % wait states and a 133 MHz memory clock; an injected
single-bit fault is found at its address.

**Step 3, the SDRAM controller, verified in its bench 2026-10-06.**
`rtl/machine/MacPPC7300_sdram.sv`, adapted from Sorgelig's MiSTer `sdram.sv` as
used unmodified in the Quadra 800 core (hardware-tested at 99 MHz, eight-beat
bursts, CAS 2) and the Sun-3 core: kept are the power-up sequence, the mode
word, the refresh pairs for the two ranks of the 128 MB board, ACTIVE to
READ/WRITE in two clocks and PRECHARGE to ACTIVE in three, the read capture
three clocks after the READ and the data bus from registers; the request side
is new, one row opened and closed per request (no open pages yet). A line is
two eight-beat READs back to back (sixteen beats without a gap, the choice
the prompt left to the controller, made because the proven controller runs
bursts of eight) or sixteen single WRITEs; a word is two halfwords with DQMH
and DQML from the byte enables. The ROM upload is a second, lower-priority
port pairing bytes into halfwords. `verilator/sdram_main.cpp` runs it behind
the clock crossing against a model of the board that holds the data and
checks every command and timing (power-up, tRCD, tRP, tRAS, tRC, tRRD, tWR,
tRFC, tMRD, refresh debt, bus turnaround, DQM on reads), with the CDC
bench's request patterns and a ROM upload alongside: 40,000 requests per run
at CPU clocks from 50 to 100 MHz against the 100 MHz controller, every read
right, no protocol error, the whole 128 MB matching at the end. Three
deliberate bugs were each caught (capture a clock early, refresh every 9 us,
the model's tRCD tightened to 25 ns); a fourth (tRCD of one clock) hung the
controller's state machine, which the model reported as missed refreshes.
Step 7 of `run_core.py`.

The MiSTer top (`MacPPC7300.sv`): one PLL with three outputs (video 20 MHz as the
template had it, the CPU at `CPU_MHZ` = 65, memory 100 MHz, from a 1300 MHz
VCO; 60 and 70 MHz also divide), `hps_io` and the SDRAM controller in the
memory clock, the CPU held in reset as the prompt specifies, the ROM upload
into the top 4 MB (index 1 from the OSD, or index 0, a `boot.rom` loaded at
core start), the OSD's RAM sizes 16, 24, 48, 64, 96 and 6 MB (16 the
default) and Boot ROM or Memory test, and `MacPPC7300_debug.sv`: twelve rows of
32 squares on the template's video timing and the same rows as hex on the
UART once a second. `MacPPC7300.sdc` makes the three clocks asynchronous (every
crossing is a two-flip-flop toggle or quasi-static). `syn/mister.py` puts
the core and ROM on the MiSTer over SSH, sets the options, loads the core,
takes a screenshot and reads the UART.

The first build (29 minutes): 24,757 ALMs (59 %; the CPU 13,883, smaller
than its stand-alone 15,678 at the 75 MHz constraint), 144 RAM blocks, 40
DSP blocks (the CPU's 7, the rest the framework's scaler and audio), the SDRAM
pins' registers packed in the I/O cells. Slow 100 C model: the CPU's clock
closes at 64.59 MHz against the 65 asked (slack -0.099 ns, the same as the
CPU's stand-alone fits), memory 107.3 MHz against 100, video 45.7 against 20.
**On the board, at 65 MHz, the memory test passes at every RAM size the OSD
offers**: 6, 16, 24, 48, 64 and 96 MB, three to twenty passes each, no
error (96 MB reaches the board's second rank); 1.87-1.91 cycles per
instruction. The UART is read over SSH from /dev/ttyS1 with the core's UART
mode left at None.

**Step 4, the ROM on the board, done 2026-10-06.** The 7600's ROM as
`games/MacPPC7300/boot.rom` (loaded at core start), 16 MB, 65 MHz. The second
build adds two readout rows (device writes, and the instructions retired at
the last of them; 25,051 ALMs, the CPU's clock closing at 64.64 MHz) to
compare the path, not only the end, with the simulation:

| | Simulation (`run_machine.py`) | Board |
|---|---|---|
| Device writes before the endless poll | 26,771 | 26,771 |
| Instructions before the last device write | 18,273,776 | 18,273,773 |
| Where it loops | FF809C7C-FF80BB00, FF838BC0-FF838EA0 | FF80BAFC, FF838BC0-FF838E98 sampled |
| What it polls, MSR | F3017A00 (the VIA's flags), 00003070 | the same |

The three instructions are the measurement: the board latches the retired
count when the write is acknowledged, with the writing instruction and the
two before it still in the pipeline, where the simulation counts the
instructions before the writing one. So the first bitstream executes the
7600's ROM exactly as the simulation does, through the hardware
initialisation, RAM sizing and 18 million instructions of Open Firmware, to
where Open Firmware waits for Cuda. `docs/MacPPC7300_board_rom_20261006.png` is
the screen at that point. M6's remaining bullet, timing closure at 66 MHz
and then 75, stays open: the CPU's clock closes at 64.6 MHz in both builds
and the board runs at 65 MHz.

After M6 the work is the machine, which gets its own plan.

**Found by the machine, 2026-10-06; fixed 2026-10-07:** with Cuda built
(`docs/MacPPC7300_stubs.md`), the ROM runs on past Open Firmware into the
NanoKernel, and at 24,440,545 instructions the lockstep stopped on
`lwzux r28, r26, r28` (FFF122B4, the NanoKernel's page-table code): r26 =
00FEA000, r28 = 0, the word loaded 00000021; the core wrote r26 = 00FEA021,
the address plus the loaded value, where the architecture (and dingusppc)
give the address, 00FEA000.

- *The cause.* An update form is two operations in the sequencer (rule 3):
  the access, then rA <- rA + rB computed again from the registers. When
  rD is rB (a valid form: only rA = 0 and rA = rD are not), the second
  operation's rB is the load's own result, which the one hazard mechanism
  (rule 2) duly forwards; so rA took the address plus the loaded value, on
  every timing (cache off, a miss, a hit, wait states: all the same).
  Exactly four instructions can do it: `lbzux`, `lhzux`, `lhaux`, `lwzux`.
  The D-form update loads have no rB, the FP update loads write an FPR, and
  the update stores write no register.
- *Why nothing found it before.* The real-604 vectors have no indexed update
  loads at all (LBZU, LWZU and the rest are the D forms), and the random
  programs built every indexed update form with rB = r0, the index register,
  which is never a destination.
- *The test.* `progs.py updtest` (in `run_core.py`, with and without wait
  states): the four loads with rD = rB, with the data cache off, missing and
  hitting, aligned and not, rB small and rB large with rA wrapped to meet
  it, each followed by an `add` and a load that use both results; then the
  same loads with rD and rB distinct, the indexed stores with rS = rB,
  `lfdux`/`stfdux`, the D-form update loads and stores and `stwu r3,-16(r3)`.
  47 checks and the buffer compared at the end; 27 failed before the fix,
  all of them the rD = rB loads. The random generator now makes half of its
  indexed update forms with rD (or rS) = rB, the register holding a small
  index first (175 such instructions in a 20,000-instruction program).
- *The fix.* Rule 3's answer, not rule 2's: when an indexed update load's
  rD is its rB (decided from the opcode bits in ID, like `lswx`, so that
  the register-read index does not wait for the decoder), the sequencer
  makes three operations: scratch <- rA + rB; rD <- [scratch]; rA <-
  scratch. The load stays the operation that can fault, so a DSI leaves rA
  unchanged and the restart is as before; interrupts are still taken on the
  first operation only. No hazard or commit logic changed
  (`DSPPC604_seq.sv`; `id_ldux_rb` in `DSPPC604.sv`).
- *The cost.* One cycle more for that form only (three operations, not two);
  the golden programs' cycle counts are unchanged (1.85/3.53, 1.87/3.81).
  Synthesised alone: 15,711 ALMs against 15,678 (33 more: the compare and
  the sequencer's arm), the same 77 RAM and 7 DSP blocks, 64.96 MHz slow
  100 C against 63.7-64.8 in the two previous fits, the slowest paths the
  same families as before.
- *After it.* The whole suite green (535,481 random instructions compared,
  the rD = rB forms among them), the vector bench and Cuda's bench too; the
  machine run passes 24,440,545 and goes on in lockstep to 60 million
  instructions (the limit asked), through the NanoKernel's start-up into
  Mac OS's 68k emulator (pc 6806xxxx in user mode from 28 million on), at
  2.20 cycles per instruction. On the way, two more places where dingusppc
  is not a 604, both now bench accommodations (`docs/MacPPC7300_stubs.md`):
  MSR[PM] is dropped by dingusppc's `rfi` and exception entry where the
  604 copies it (the NanoKernel runs Mac OS with PM set: 33,160,742), and
  `dcbst`, `dcbf`, `icbi` and `dcbi` are never translated by dingusppc, so
  the DSI the core takes at Open Firmware's flush word (FF808D14, DAR
  FF840940, no translation: 33,174,510), which the NanoKernel answers by
  installing the PTE, had to be given to the reference. No device stopped
  the run; the device traffic after Open Firmware is small (22 accesses
  between 33 and 60 million instructions).

**The 7300's ROM as the reference, 2026-10-07.** `run_machine.py` now runs
the 7300's ROM (077D.34F2) by default and the 7600's with `--rom7600`. The
two ROMs share Open Firmware, the 68k emulator and its opcode table byte
for byte and differ in the start-up code, the NanoKernel and a few drivers
(`rom7300/README.md`, beside `rom7600/`, has the disassembly and
where every address quoted here moves to: FFF047C0 is FFF0499C there, the
NanoKernel's addresses stay). The 34F2 ROM runs 60 million instructions in
lockstep with no difference, 2.20 cycles per instruction, through Open
Firmware into Mac OS's 68k emulator; the same `dcbst` DSI at 33,173,502.
Against dingusppc's whole 7300 (`machref --machine pm7300`) its device
traffic parts where the 7600's did: Cuda's timing, and the periodic VIA
interrupt dingusppc services from 28.8 million instructions on. The
machine's own plan, `docs/MacPPC7300_plan.md`, takes it from here.

## Known behaviour and open items

Everything the CPU does that software could notice and that is not simply
the architecture, and the limits of the tests, in one place. *Manual* means
the 604 User's Manual with no hardware data behind it; *measured* means
recorded on the real 604; *hardware* marks a question only a supervisor-level
run on a real 604 can settle.

### Behaviour that is deliberate

- Interrupts are taken only on the first operation of a multi-operation
  instruction; an exception in a later operation leaves the earlier ones
  done and restarts the instruction. The architecture allows this, the
  instructions being restartable; only an invalid form such as `lmw` with rA
  inside the loaded range could tell the difference.
- `mtmsr` and `rfi` always refetch the next instruction.
- MSR implements `0x0005FF77` (measured: bit 29, PM, is one of the 604's;
  POW and ILE from the manual, the test never set them). Exception entry
  keeps ME, IP and ILE and copies ILE to LE (measured for ME with IP = 0).
  SRR1 takes MSR bits `0x87C0FFFF` and `rfi` copies them back (measured for
  the low 16). `mtxer` keeps `0xE000FF7F` (measured).
- Reset: MSR `0x40`, DEC `0xFFFFFFFF`, time base 0, HID0 0 (manual, Table
  4-3). GPRs, FPRs and the other SPRs are not reset. Hardware: the test ran
  after the ROM, which had left HID0 at `8000C084` (EMCP, both caches,
  bit 24, BHT) and the decrementer running.
- `mftb` reads SPR 284/285; so does `mfspr` 268/269, in user mode too, and
  `mfspr` 284/285 in supervisor mode (measured; `mtspr` 268/269 is illegal,
  manual). The time base and decrementer advance on the `tb_tick` input,
  which the system pulses at bus clock / 4. The decrementer exception becomes
  pending when DEC passes from 0 to all ones, or when `mtdec` writes bit 0
  set while it was clear (measured).
- Exception priority, highest first: external interrupt, decrementer,
  pending enabled FP exception, privileged, illegal, FP unavailable, system
  call, trap, alignment, then an enabled FP exception the instruction raised
  itself. `mfspr`/`mtspr` of an SPR the 604 does not have is illegal in both
  modes (measured; manual 4.5.7 says privileged in user mode).
- Alignment exception: `lmw`, `stmw` and FP loads and stores not
  word-aligned; a string operation that is not word-aligned and crosses a
  4 KB boundary, or is word-aligned and crosses a 256 MB boundary (manual
  2.3.4.3), checked before its first access. DSISR carries the opcode
  fields the architecture defines and, in the register fields, rD and
  rD - 1 (8 and 7 for `dcbz`), which is what the 604 puts there (measured;
  the update forms were not tested).
- `mffs` returns `FFF80000` in the upper word, as `fctiw` does (both
  measured).
- `stfs` of a double below the single denormal range stores a signed zero:
  the 604 denormalises for every exponent of 896 or less (measured).
- FPSCR[NI]: a result that would be denormalised becomes a signed zero and
  an inexact underflow; denormal operands are computed with (measured, M2).
- `fres` is a full divide of 1.0 by the operand rounded to single, which is
  what the 604 does (measured); a 750 will need its own estimate. `frsqrte`
  is a 32-entry table, every entry measured.
- Divide by zero and `0x80000000 / -1` return the real 604's values
  (measured; README). An enabled underflow or overflow in single precision
  whose scaled exponent is still out of range delivers the 604's exponent
  field (measured, M2); the architecture calls it undefined.
- The sequencer's scratch register (32) is not architectural and never
  visible. Update forms take one extra cycle, being two operations; an
  indexed load with update whose rD is its rB takes two, being three (the
  address through the scratch register, since the load overwrites rB; see
  the bug found by the machine under M6).
- The branch target buffer has 128 entries and no return-address stack; a
  wrong or stale entry costs three cycles and is corrected in EX. A
  mispredicted branch costs three cycles.
- Latencies: multiply 2 cycles after the request, divide 34 (radix 2; radix
  4 would halve it), FP add/mul/madd 8, `fdiv` 34, `fdivs`/`fres` 20,
  `frsqrte` 2, plus 6 if an operand is denormal. A data access takes two
  cycles on the test bench bus until there is a cache.
- `dcbt` and `dcbtst` do nothing, which the architecture allows for hints.
  `dcbf`, `dcbst`, `dcbi` and `icbi` translate their address and do nothing
  else until there is a cache (M5 step 3).
- The reservation has no address: `stwcx.` succeeds after any `lwarx`, as
  on the 604 and in dingusppc, and survives exceptions. `lwarx` and
  `stwcx.` to a cache-inhibited page take no DSI and the store is made
  (measured); to a write-through page the architecture allows a DSI (manual
  Table 4-9), the core takes none, and a 604 was not tested. `stwcx`
  without the record bit is illegal (measured).
- Address translation: the TLBs are direct-mapped with 64 entries (the 604's
  are two-way with 128), so a program that alternates between two pages of
  the same index walks the table for each; software cannot tell otherwise.
  The referenced bit is set when an entry is loaded, the changed bit when a
  store is allowed; neither on a protection violation (allowed; dingusppc
  does the same). A direct-store segment (T = 1) takes a DSI with DSISR[0]
  or an ISI with SRR1[3], there being no direct-store device. `eciwx` and
  `ecowx` always take a DSI with DSISR[11]: EAR[E] is stored and ignored.
  `mtsr`, `mtspr` to SDR1 or a BAT and `tlbie` refetch the next instruction,
  which spares software the `isync`.
- CR, XER, LR, CTR, FPSCR and MSR have no forwarding at all; EX reads the
  committed registers. The hazard logic covers GPRs and FPRs only
  (seven-bit register names). The FPU holds its response until the
  pipeline takes it, like the integer unit.

### Not implemented, no milestone

- Machine check: needs a bus-error signal from the machine. The 7600 ROM
  relies on bus errors when it probes for hardware, so this comes with M6 or
  the machine's plan. MSR[ME] = 0 would checkstop. Measured on the 7300: a
  load from RAM space beyond the installed memory (240 MB) returns 0 without
  any exception, so the ROM's probing of memory sizes is not what needs the
  bus error.
- Trace (MSR[SE]) is cheap now that its SRR1 is measured: `0x40000000` and
  the MSR bits, nothing else, for the instructions tested (Table 4-10's
  load/store flags were not exercised); SRR0 is the next instruction; the
  `mtmsr` that clears SE is itself traced, the one that sets it is not, and
  an instruction completing in the same cycle as that `mtmsr` is not either
  (a 604 artefact a single-issue core would not show). About 30 lines along
  the path an enabled FP exception takes (complete, then trap). MSR[BE] was
  not settled: the only branches tested sat right after the `mtmsr`, in that
  shadow. Worth a short step when a debugger wants it; see the decisions
  table.
- The instruction-address breakpoint (IABR) is as cheap: vector `0x1300`,
  SRR0 the breakpoint address itself (the instruction has not executed),
  SRR1 the MSR bits, IABR[30] = BE enables it and IABR[31] = TE must match
  MSR[IR] (measured). The performance-monitor interrupt (`0x0F00`, SRR1 the
  MSR bits, SRR0 the next instruction, re-raised until the counter is
  cleared; measured) needs the counters themselves and is not. Soft reset,
  power saving (MSR[POW]) and little-endian mode (MSR[LE] and [ILE] are
  stored and ignored): no software we target uses them. The registers of all
  of these exist as storage, with the bits a 604 keeps.

### What the tests do not cover, or cover with a stand-in

- Hardware data now covers (7600 runs plus the 7300 run of 2026-10-06, see
  M2 and M4): every FP exception enable, FPSCR arriving with sticky bits
  set, the whole `frsqrte` table, NI mode, the FPSCR instructions, `mffs`'s
  upper word, `stfs` below the single range, `lfs` of SNaNs and denormals,
  integer loads and stores in every form, which XER and MSR bits stick, which
  SPRs exist and what they keep, which opcodes are illegal, and SRR1 and
  DSISR for every exception kind the core has. Still without hardware data:
  the reset values of MSR and HID0 (the test runs after the ROM); POW, ILE
  and LE; the ISI bit for guarded memory; `lwarx`/`stwcx.` on a write-through
  page; the alignment DSISR of the update forms; MSR[BE]; what the 604 does
  for the invalid update forms (rA = 0, rA = rD). `mtspr` to a nonexistent
  SPR was tested with one number only (164: illegal in both modes).
- The golden FP vectors all start with CR = 0, so an FP instruction with a
  non-zero CR in place is checked only by the random FP programs.
- dingusppc cannot be the reference for: FP arithmetic (never reports
  inexact, clears VE on compares), `tw` (operands swapped), undefined divide
  results (quotient 0), unaligned `lmw` (no exception), reserved MSR bits and
  the low bits of SRR0 (kept; the random programs clear SRR0's before
  writing it), MSR[PM] through `rfi` and exception entry (dropped, where
  the 604 copies it between MSR and SRR1 both ways; the bench puts it
  back, `docs/MacPPC7300_stubs.md`), undefined SPRs (plain storage), `dcbst`,
  `dcbf`, `icbi` and `dcbi` (never translated, so never a DSI: the bench
  makes the reference take the one the core takes), invalid instruction
  forms
  (trap as illegal), enabled FP exceptions and interrupts (never taken), one
  SRR1 bit each on `sc` and FP unavailable (the test bench clears them). The
  random programs avoid these or correct for them; `verilator/ref/README.md`
  has the list with file and line numbers, and which items the 604 has since
  settled.
- The random FP programs no longer need to skip anything: nothing the model
  computes is undefined since the 7300 run.
- The random integer programs keep r0, r1 and r2 as index and data bases
  (the bases drift with every update form, by r0, or by a small value put
  in rB when rB is also the rD or rS, which half of them are since
  2026-10-07), keep `lmw`/`stmw`
  word-aligned and the string operations inside a page through masked copies
  of the base (dingusppc takes neither alignment exception), and set XER for
  `lswx`/`stswx` from controlled values.
- The lockstep test bench models 16 MB of RAM with addresses wrapping modulo
  16 MB; dingusppc reads all ones outside its RAM and drops stores, and
  cannot fetch from MSR[IP] = 1 vectors, so every program sets IP = 0 first.
  Interrupt tests use fixed addresses: handlers count at
  `00FFFFE0`/`00FFFFE4` and acknowledge at `00FFFFF0`.
- Deliberate-bug checks: four bugs in the integer pipeline, five in the FP
  pipeline, three in the exception logic, five in the MMU, three in the
  reservation and `dcbz` logic; each was caught.
- With translation on, the random programs keep the code under a BAT (no
  speculative fetch reaches the page table), never touch a direct-store or
  guarded page, and only `tlbie` entries whose PTEs have not changed.
- Largest lockstep run so far: 300 programs of 20,000 instructions
  (5,375,852 instructions compared) on the RTL as of 2026-10-05, all with
  a complete passing summary.
- `run_core.py` also runs the 7300 run's 79,624 vectors as two programs
  (12,053 integer and 67,571 floating-point checks; the memory vectors get
  a buffer each, whose contents are checked at the end), and `run.py --csv`
  replays the file through the execute units alone, applying XER and FPSCR
  as the hardware harness's `mtxer` and `mtfsf` left them.
- The trace ports on `DSPPC604` exist for the test bench; a real build
  leaves them unconnected.

### Cost and speed

- Register files and SPRs are flip-flops; moving them to MLAB/M10K RAM is the
  main area saving. The forwarded FP operands feed the FPU's first stage
  directly and set the clock. M5 step 4.
- 1.36 cycles per instruction on straight-line code with an ideal bus is not
  representative: every data access takes two cycles until the caches exist.
- Whether part of the CPU could run on the DE10-Nano's ARM was raised and set
  aside; the FPU's request/response boundary is where such a split would go.

## Decisions needed along the way

| When | Question |
|---|---|
| ~~now~~ | ~~When the 7300 is running tests: build the extra floating-point vector set listed under M2?~~ Done 2026-10-06: the version-4 set ran on the 7300, with a supervisor-mode second stage; M2 and M4 have what it changed. |
| M6 or later | Trace and the IABR, cheap now that their SRR1 is measured: add them when a debugger or the ROM's own tests want them, or leave them out? |
| M3 | Is dingusppc built as a library acceptable as the lockstep reference, given it is the reference trusted most? |
| M5 | ~~Main memory on the SDRAM module or on the HPS DDR3?~~ Decided 2026-10-05: the SDRAM module, 64-128 MB fitted; the machine offers 6, 16, 24, 32, 64 or 128 MB (changed 2026-10-06 to 6, 16, 24, 48, 64 and 96 MB on the 128 MB module, the ROM taking its top 4 MB; 128 MB would need the ROM elsewhere and is left out). The line-fill bus therefore targets the SDRAM controller, which runs on its own clock, so M5 includes the clock crossing. |
| M6 | With measured speed in hand: stay with the 7600, or model a slower machine first? |
