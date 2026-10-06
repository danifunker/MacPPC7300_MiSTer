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

Added after the review of everything flagged during M0-M4 (2026-10-05):
`dcbt` and `dcbtst` are accepted and do nothing (they are hints, so that is
allowed); the alignment exception for a string operation that is not
word-aligned and crosses a 4 KB boundary, or is word-aligned and crosses a
256 MB boundary (604 manual 2.3.4.3), with directed tests for both and for
the cases that must execute; three deliberate bugs in the exception logic
(SRR0 of `sc`, MSR[EE] left on at entry, the decrementer's pending flag not
cleared) were each caught by the directed tests.

Left for later, with the milestone that needs them:

- DSI and ISI, `lwarx`/`stwcx.`, the remaining cache instructions: M5.
- Machine check, trace, the 604's breakpoint and performance-monitor
  interrupts, soft reset, power saving, little-endian mode: no milestone;
  what each would take is under "Known behaviour and open items" below.
- From real hardware, when a supervisor-level test is possible: the reset
  values of MSR and HID0, and the SRR1 and DSISR a 604 really delivers.

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
  The MMU itself is about 1,200 ALMs. The slowest paths are the operand
  forwarding network into the ALU and FPU, as before; the MMU adds to its
  fanout (the DTLB's read-ahead address comes off the effective-address
  adder) and a term to `ex_leave`. Two things learnt: the DTLB only became
  a RAM once its two read expressions were merged into one with a muxed
  address (as flip-flops it cost 3,900 ALMs and 8 MHz); and reading the
  ITLB ahead with the *redirect* address put branch resolution in front of
  the RAM, so it reads ahead with the predicted address and re-reads after
  a redirect into another page. For step 4.

### M6: real ROM, first MiSTer build

- Run the 7600's own ROM from the reset vector in Verilator against a stub
  machine, in lockstep with dingusppc, until it needs hardware that is not
  there.
- Put the CPU in the MiSTer project with memory and the ROM; get a first
  bitstream that executes ROM code and reports over the UART.
- Timing closure at 66 MHz, then try 75.

After M6 the work is the machine, which gets its own plan.

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
- MSR implements `0x0005FF73` (manual; no 604e PM bit). Exception entry
  keeps ME, IP and ILE and copies ILE to LE. SRR1 takes MSR bits
  `0x87C0FFFF`. `mtxer` keeps `0xE000007F`. Hardware: which XER and MSR bits
  a real 604 keeps.
- Reset: MSR `0x40`, DEC `0xFFFFFFFF`, time base 0, HID0 0 (manual, Table
  4-3). GPRs, FPRs and the other SPRs are not reset.
- `mftb` reads SPR 284/285; `mfspr` 284/285 works in supervisor mode too.
  The time base and decrementer advance on the `tb_tick` input, which the
  system pulses at bus clock / 4. The decrementer exception becomes pending
  when DEC passes from 0 to all ones, or when `mtdec` writes bit 0 set while
  it was clear.
- Exception priority, highest first: external interrupt, decrementer,
  pending enabled FP exception, privileged, illegal, FP unavailable, system
  call, trap, alignment, then an enabled FP exception the instruction raised
  itself. `mfspr`/`mtspr` of an SPR the 604 does not have is privileged in
  user mode and illegal in supervisor mode (manual 4.5.7).
- Alignment exception: `lmw`, `stmw` and FP loads and stores not
  word-aligned; a string operation that is not word-aligned and crosses a
  4 KB boundary, or is word-aligned and crosses a 256 MB boundary (manual
  2.3.4.3), checked before its first access.
- `mffs` returns `FFF80000` in the upper word, as `fctiw` does (measured for
  `fctiw`; hardware for `mffs`).
- `stfs` of a double with an exponent below the single denormal range stores
  the top bits as if it were normal (undefined by the architecture;
  hardware).
- FPSCR[NI] is ignored by the FPU and by the model (hardware; open).
- `fres` is a full divide of 1.0 by the operand rounded to single, which is
  what the 604 does (measured); a 750 will need its own estimate. `frsqrte`
  is a 32-entry table of which 8 entries are measured; the other 24 follow
  the same rule (hardware).
- Divide by zero and `0x80000000 / -1` return the real 604's values
  (measured; README).
- The sequencer's scratch register (32) is not architectural and never
  visible. Update forms take one extra cycle, being two operations.
- The branch target buffer has 128 entries and no return-address stack; a
  wrong or stale entry costs three cycles and is corrected in EX. A
  mispredicted branch costs three cycles.
- Latencies: multiply 2 cycles after the request, divide 34 (radix 2; radix
  4 would halve it), FP add/mul/madd 8, `fdiv` 34, `fdivs`/`fres` 20,
  `frsqrte` 2, plus 6 if an operand is denormal. A data access takes two
  cycles on the test bench bus until there is a cache.
- `dcbt` and `dcbtst` do nothing, which the architecture allows for hints.
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
  the machine's plan. MSR[ME] = 0 would checkstop.
- Trace (MSR[SE], MSR[BE]): about 30 lines along the path an enabled FP
  exception already takes (complete, then trap), with the 604's own SRR1
  layout (manual Table 4-10: bits 0-2 = 010, flags for load, store, taken
  branch and `mtspr` to translation registers). Only a debugger needs it, and
  only hardware could check Table 4-10.
- The 604's instruction-address breakpoint (IABR), performance-monitor
  interrupt, soft reset, power saving (MSR[POW]) and little-endian mode
  (MSR[LE] and [ILE] are stored and ignored): no software we target uses
  them. Their registers exist as storage.

### What the tests do not cover, or cover with a stand-in

- No hardware data for: FP exception enables other than VE, FPSCR arriving
  with sticky bits set, 24 of the 32 `frsqrte` entries, NI mode, the FPSCR
  instructions, `mffs`'s upper word, `stfs` below the single range, `lfs` of
  SNaNs and denormals, which XER and MSR bits stick, SRR1 and DSISR as a
  real 604 delivers them, reset values. The user-level ones are the v4
  vector set asked for in `RESUME_hardware.md`; the rest need a
  supervisor-level run.
- The golden FP vectors all start with CR = 0, so an FP instruction with a
  non-zero CR in place is checked only by the random FP programs.
- dingusppc cannot be the reference for: FP arithmetic (never reports
  inexact, clears VE on compares), `tw` (operands swapped), undefined divide
  results (quotient 0), unaligned `lmw` (no exception), reserved XER and MSR
  bits (kept), undefined SPRs (plain storage), invalid instruction forms
  (trap as illegal), enabled FP exceptions and interrupts (never taken), one
  SRR1 bit each on `sc` and FP unavailable (the test bench clears them). The
  random programs avoid these or correct for them; `verilator/ref/README.md`
  has the list with file and line numbers.
- The random FP programs skip operations the model marks undefined (an
  enabled overflow or underflow whose adjusted exponent is still out of
  range).
- The random integer programs keep r0, r1 and r2 as index and data bases
  (the bases drift, by r0, with every update form), keep `lmw`/`stmw`
  word-aligned and the string operations inside a page through masked copies
  of the base (dingusppc takes neither alignment exception), and set XER for
  `lswx`/`stswx` from controlled values.
- The lockstep test bench models 16 MB of RAM with addresses wrapping modulo
  16 MB; dingusppc reads all ones outside its RAM and drops stores, and
  cannot fetch from MSR[IP] = 1 vectors, so every program sets IP = 0 first.
  Interrupt tests use fixed addresses: handlers count at
  `00FFFFE0`/`00FFFFE4` and acknowledge at `00FFFFF0`.
- Deliberate-bug checks: four bugs in the integer pipeline, five in the FP
  pipeline, three in the exception logic, five in the MMU; each was caught.
- With translation on, the random programs keep the code under a BAT (no
  speculative fetch reaches the page table), never touch a direct-store or
  guarded page, and only `tlbie` entries whose PTEs have not changed.
- Largest lockstep run so far: 300 programs of 20,000 instructions
  (5,375,852 instructions compared) on the RTL as of 2026-10-05, all with
  a complete passing summary.
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
| now | When the 7300 is running tests: build the extra floating-point vector set listed under M2? |
| M3 | Is dingusppc built as a library acceptable as the lockstep reference, given it is the reference trusted most? |
| M5 | ~~Main memory on the SDRAM module or on the HPS DDR3?~~ Decided 2026-10-05: the SDRAM module, 64-128 MB fitted; the machine offers 6, 16, 24, 32, 64 or 128 MB. The line-fill bus therefore targets the SDRAM controller, which runs on its own clock, so M5 includes the clock crossing. |
| M6 | With measured speed in hand: stay with the 7600, or model a slower machine first? |
