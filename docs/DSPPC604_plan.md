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
| M3 | Pipeline, user-mode integer | golden vectors pass *through the pipeline*; lockstep against a reference on random code | next, week 1-2 |
| M4 | Supervisor state, exceptions, FP in the pipeline | exception and SPR tests; lockstep with interrupts | week 2-3 |
| M5 | MMU and caches | translation and cache tests; lockstep with translation on | week 3-4 |
| M6 | Real ROM in simulation, first MiSTer build | the 7600 ROM runs from reset until it needs hardware; timing met at 66 MHz or better | week 4-5 |

## Rules that keep the pipeline from growing special cases

A CPU that is pipelined late ends up with one-off stall and fix-up paths per
instruction. These rules exist to prevent that, and every milestone is
reviewed against them.

1. **One commit point.** Registers, CR, XER, LR, CTR, FPSCR, MSR, the SPRs and
   memory writes change only when an instruction retires at the end of the
   pipeline. Exceptions and interrupts are taken only there, so they are
   always precise.
2. **One hazard mechanism.** The decoder declares what each instruction reads
   and writes (up to three GPRs, CR fields, XER[CA], XER[SO/OV], LR, CTR, up to
   three FPRs, FPSCR). A single forwarding-and-stall block works from those
   declarations. No instruction gets its own stall logic.
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

### M3: pipeline, user-mode integer

- The six stages above, the hazard block, the flush, the sequencer.
- All user-mode integer instructions: loads and stores in every form (update,
  indexed, byte-reversed, multiple, string), branches with a branch history
  table, CR logic, `mfcr`/`mtcrf`/`mcrf`/`mcrxr`, moves to and from LR, CTR
  and XER, `sc` and traps as far as raising the request.
- Memory is a simple bus model with random wait states; no caches yet.
- Verification:
  1. The golden vectors again, this time assembled into programs and run
     through the pipeline back to back, with random stalls. Same expected
     values, now also exercising forwarding.
  2. Lockstep against a reference simulator: after every retired instruction
     the architectural state is compared. Random instruction streams plus
     directed tests. The reference is dingusppc's CPU built as a library.
  3. Area and timing check of the whole pipeline.

### M4: supervisor state, exceptions, floating point in the pipeline

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
