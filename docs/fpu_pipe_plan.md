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

### Overlap 1 as built (2026-10-16, `fpu-pipe2`)

The FPU is split in two halves with their own state: the front (the
request, the operand normaliser, the multiplier's two cycles or fadd's
alignment, the divider, the estimate) and the back (the adder, the
leading-zero count, normalise, shift, round, done). The front hands an
operation over when the back is free (idle, or answering this cycle): the
product and aligned addend (`p_q`, `zal`, `zst`), the window exponent and
distance, the signs, and the operation's own control (precision, integer,
negate, rounding mode, its FPSCR) go into the back's registers, and the
front takes the next request. A special result (a NaN operand, an
infinity, an exact zero) and a compare go to the back's done state when it
is free; a divide holds its last step until then. The unit answers in
order, one result at a time; `resp_valid` no longer depends on the
request, and a move or select (answered in the request cycle) is accepted
only while the back is idle, so its answer never meets a pending one.

The CPU keeps the one FP operation in EX as before and admits a second,
independent one from ID into the completion queue behind it, as the queue
admits ALU operations: the operation's registers and classes are read in
ID into an issue register (`fq_*`), which requests the FPU when its front
is free; EX's own request goes first while EX's operation is not yet in
the unit (`ex_fpu_taken`), so the unit sees them in program order. A
two-bit order FIFO (`fo_*`) names who the next answer is for, EX or a
queue slot; a slot's answer is taken at once into its entry: the 64-bit
value, whether the register is written (an enabled invalid operation or
zero divide leaves it), and the FPSCR effects as set bits, FR, FI and the
result class. The entry commits in order through MEM and WB as a queued
ALU result does, and at the pop the FPSCR is updated from the entry's
bits (`fpscr_update`, now in the package) and CR1 written for a record
form: the FPSCR's sticky bits merge in order whatever FPSCR the unit saw.
Admission: an FPU operation that writes a register (not a compare, not an
FPSCR instruction), its first and only operation, fetched sequentially,
MSR[FP] set and FP exceptions not trapping (MSR[FE0,FE1] clear: the trap
decision needs the result in EX), no in-flight writer of any source
register (EX, MEM's two slots, the queue, the issue register), the issue
register free and EX's operation already in the unit. An operation in EX
reading a register a queue entry writes waits for the entry to pop (no
forwarding from the entry). Every redirect flushes the unit (a kill of
the operation in EX kills the younger queued one too; a misfetched FP
operation leaving EX while its successor is in the unit, likewise).

Two things the vectors could not see (they issue one operation at a
time), found by the microbenchmarks and the random FP programs:

- A handoff in the cycle the back's answer is taken (the back in its
  round or done state with `resp_ready`) was lost: the back's own state
  machine, later in the same block, set the state idle over the front's
  write. The back's two answering states now leave the state and the
  result registers alone when `hand_now` is set. The order FIFO's
  overflow check ("more FPU requests outstanding than the order FIFO
  holds") caught it on the independent fadd stream, where the front frees
  faster than the back answers; the random programs hung on it.
- EX's own answer carried the FPSCR the unit saw at the request. Queued
  operations older than EX's pop between that request and EX's commit,
  and their FR, FI and sticky bits were overwritten (fcmpu lost FI, an
  fctiw's CR1 lost OX). The unit's effect outputs (`set_out`, `fr_out`,
  `fi_out`, `fprf_we_out`, `fprf_out`, and a new `cmp_out`: a compare's
  condition goes into FPCC with the C bit kept, without FR and FI) are
  now applied by EX too, to the FPSCR of the commit cycle, with the same
  `fpscr_update` as the pop; the unit's `fpscr_out` is for the vector
  benches. The rounding mode and the enable bits the unit took at the
  request are the commit's: only EX's own FPSCR instructions change
  them, in order. A popped entry whose write is suppressed (an enabled
  invalid operation with traps off) forwards nothing: the registered
  forwarding select now takes the entry's `we`, as `mem_rd_wr` does.

The core bench's microbenchmarks (`progs.py fpbench OUT KIND`, 2,000
operations, straight-line, no wait states; cycles per operation, the
lfd-lfd-fmadd loop per instruction):

| kind | shape | before | overlap 1 |
|---|---|---|---|
| dep | `fadd f3, f3, f1` repeated | 5.25 | 5.25 |
| indep | `fadd f3..f6 = f1 + f2` in turn | 5.25 | 3.27 |
| mul | `fmul f3..f6 = f1 * f2` in turn | 5.25 | 3.27 |
| madd | `fmadd f3..f6 = f1 * f2 + f2` in turn | 6.25 | 3.27 |
| mulchain | `fmul f3, f3, f2` repeated | 5.25 | 5.25 |
| lfdmadd | `lfd f1; lfd f2; fmadd f3, f1, f2, f3` | 3.27 | 3.27 |

Independent operations now stream at the back's rate (adder, count,
normalise, round: 3 cycles and the request); the dependent chains keep
their latency, as they must, and the load-fed loop gains nothing until
loads may pass a pending FP operation (overlap 2). The random FP programs
(`run_core.py`'s seeds 1 and 2, every third instruction or so an FP
operation among loads, stores and FPSCR instructions) run 2.72 and 3.23
cycles an instruction, 2.86 and 3.39 before (`Scratch/run_core_base.log`):
-5 %.

The first fit of the whole (`Scratch/q70f2`, 70 MHz, the slow 100 C
model) against the branch before it (`q70c7`: 36,334 ALMs, 10,399 failing
pairs, -2.58 ns): 37,508 ALMs (89 %, +1,174), 19,175 pairs, -3.21 ns. The
worst families are the old ones (a WB result forwarded as the address
into the MMU's page compares and the memory unit's state, -3.21; through
the rotator into CR0, -2.38; both rule-2 cuts of the timing pass's list),
wider in this fit. The overlap's own: ID's instruction word through the
sequencer and the decoder into the admission (`completion_push_fp`), the
late enable of the 200-flop issue register and of the entry's register
number (`id_insn` → `fq_a/b/c` at -1.8 ns, 2,700 pairs; →
`completion_latest_younger` at -1.9). Cut as the timing pass did: the
issue register loads ID's operation every cycle it is free and the
admission sets only its valid; the entry's register number comes from
ID's registered decode (`frd_wr`), not from the admission. The second
fit (`q70f3`, the committed source): 37,296 ALMs (89 %, +962), 13,672
pairs, -2.65 ns, within the fitter's swing of `q70c7`; the issue-register
family is gone, and the overlap's remaining family is MEM's room through
`fpu_resp_ready` into the unit's `back_free` and the handoff's registers
(`mem_valid` → `r_q`, 120 pairs at -2.4: the handoff into the back in the
cycle its answer is taken, whose taking depends on MEM's room). The
memory clock passes.

On the board (the user's saved 100 MHz and 124 MB): Mac OS 7.6.1 to the
Finder; MacBench 4's Processor 167 and Floating Point 142, against 166
and 143 for the core's run of 2026-10-14 at 100 MHz: MacBench's FP test
does not move with overlap (1), as expected of code that loads and stores
around each operation (overlap (2)'s case). Boot to the menu bar 46-50 s
against 56 s for the build before. Speedometer at 100 MHz: CPU 5.485,
Math 369.5, Mix 21.68, Color 2.864, FPU 7.871 (KWhetstones 8.890, Matrix
Mult 8.534, FFT 6.187), Disk 1.725, against the release's 5.480, 369.5,
21.26, 2.810, 7.802, 1.737: the 1-2 % on Mix, Color and FPU is what the
emulated 68k FP code can take from overlap (1), as "Whether it pays"
below says.

### Overlaps 2 and 3: the design put to the user (2026-10-16)

What holds the pipeline today: EX keeps the FP operation until the
unit's answer (5 to 8 cycles), and nothing behind it moves except the one
FP operation overlap (1) admits from ID. The loop `lfd; lfd; fmadd; bdnz`
takes 9.8 cycles an iteration against the fmadd chain's own 5.25 to 6.25.

**The design: the FP operation leaves EX when the unit takes it.** The
machinery is overlap (1)'s: an FP operation that writes a register (no
compare, FP traps off) is pushed from EX into a completion-queue entry in
the cycle the unit takes it (`ex_fpu_taken`), the order FIFO marks the
answer as a slot's, and the entry commits in order at the pop with its
FPSCR and CR1 effects as today. EX is then free and the next instruction
executes in it, in order with MEM, while the FP result is computed. Two
rules make this correct without new ordering logic, because both already
exist for the queue's ALU entries:

- `ex_order_ready` (no older queue entry) gates every leave, commit and
  redirect from EX. A branch behind the FP operation resolves in EX at
  once but its redirect waits for the FP entry's pop: that is overlap (3)
  ("the redirect held until commit") as it stands, and a mispredicted
  branch cannot flush the older FP entry (the queue resets only on a
  redirect, which an older entry's presence holds back). An exception in
  EX likewise waits; a MEM fault flushes everything younger, the FP entry
  included, correctly: MEM's operation is older than the queue.
- A memory access's request waits for `ex_order_ready` too
  (`mu_valid`), so a load behind the FP operation would still wait for
  the answer. Overlap (2) is one exception to that: a plain cacheable
  load (no store, no lwarx/stwcx, dcbz or string, no update of a busy
  register) requests the memory unit before the older entries pop. Its
  data cache fill is the only side effect and harmless. Its leave into
  MEM stays in order, so the answer, if it comes first, is captured in EX
  (a 64-bit register and a valid, cleared by any flush) and passed to
  MEM in the operation's `mem_result` with `mem_load` clear, which WB
  takes as a non-load result: no new mux on the cache's data path. A
  faulting early load is not captured; it requests again in order and
  faults there, as today. A cache-inhibited load must not go early: the
  data cache learns I at its lookup (`r_ci`) and gets one input, "the
  requester is ordered", without which it does not grant an inhibited
  access (the memory unit's descriptor waits in `S_HOLD0` until the
  order comes). Interrupts keep their boundary: they are taken at an
  access before its first grant (`mu_pending`), and an early load that
  was granted completes before the interrupt, as the architecture allows.

The admission from ID (`fq_*`) stays as it is: with EX free after the
take, the next FP operation mostly walks into EX itself, and the issue
register saves a cycle when it is right behind.

**Cost.** Area about 300 ALMs (the capture register, the early-request
terms, the cache's input). Timing: EX's leave gains `is_fpu &
ex_fpu_taken` (registers) in its OR; `mem_result`'s load gains a select
by a registered valid in front of EX's result (one level on a path the
fits show at about -1.5 ns: to be watched in the fit); `mu_valid` loses
a term for loads. Cycles, estimated from the microbenchmarks: the
lfd-lfd-fmadd loop from 9.8 to about 6.3 cycles an iteration (the fmadd
chain's latency, the loads hidden), the random FP programs -15 to -20 %
(EX waits for the FPU in half their cycles today), MacBench's FP test
and Speedometer's FPU index some of the loads-around-each-operation
pattern of the 68k emulator. Behaviour it changes (rule 2): the point
where an FP operation leaves EX, a load's request ahead of its order,
the cache's grant of an inhibited access. Verification it needs beyond
the gates: directed programs for a load with a DSI behind a pending FP
operation, an external interrupt there, a cache-inhibited load and a
store there, a mispredicted branch there with the FP operation's result
and FPSCR checked after; then the lockstep, Debian on the board (its
exception paths), MacBench and Speedometer.

### Overlaps 2 and 3 as built (2026-10-16, the user's go-ahead on the design above)

**Kept: the FP operation leaves EX at the unit's take.** An FP operation
that writes a register, with FP traps off, fetched sequentially with
nothing folded after it, is pushed from EX into a completion-queue entry
in the cycle the unit takes it (`completion_push_ex`; `ex_fp_elig` is the
static eligibility, and while EX holds such an operation no admission
from ID is made, so the two pushes never meet). EX is free the next
cycle; the queue's order gate (`ex_order_ready`) makes everything behind
wait for the entry's pop only where it must: to leave, to commit, to
redirect, to request memory. Two things made it pay instead of cost:

- The entry joins the queue's *older* set at once (the bookkeeping at
  `ex_leave` adds it: the older count, the latest-writer bits, the FPR
  bitmap), since nothing younger is queued when it is pushed.
- **The head entry's answer pops it in the answer's own cycle** with the
  unit's live result and effects (`cq_live`, `cq_h_*`): without that,
  a dependent operation waited a cycle more than before (the chain
  microbenchmarks went from 5.25 to 6.25 cycles an operation, the random
  programs from 2.72 to 2.90), because the result reached it through the
  entry, the pop and MEM instead of the unit's direct answer. With it the
  chains are 5.25 again and the random FP programs 2.65 (2.72 before this
  step, 2.86 before overlap 1).

Branches behind a queued FP operation resolve in EX and their redirect
waits for the pop (overlap 3, as designed, no new logic); the directed
test `progs.py fpqtest` (an fmadd chain and an fmul leaving EX, a store
of the queued result, an alternating branch, an fcmpu, a system call,
loads, interrupts, wait states; dingusppc at every instruction) passes.

**Built, measured and removed: the early request of plain cacheable
loads.** It was built as designed (the request without the order gate
into an empty memory unit, the answer captured in EX and handed to MEM as
a non-load result, a faulting one requesting again in order, a flushed
one drained, the data cache holding an inhibited access until ordered or
abandoning it). Two bugs on the way are worth remembering: a load's done
flag sat in the integer unit's branch of EX's done expression (`lfdu` is
an integer-unit operation for its address), so the wait for the early
answer did not apply and MEM waited for an answer already taken; and a
captured load with update wrote its data, not its address, into rA,
because the update takes MEM's result's low word. Fixed, it passed, and
it gained nothing: the lfd-lfd-fmadd loop stayed at 3.27 cycles an
instruction and the random programs moved 0.1 %. The reason is EX's
in-order leave: the load's cache access overlaps the FP operation, but
the load itself holds EX until the entry pops, and nothing behind it can
enter. The gain the plan hoped for needs loads to leave EX into entries
of their own (64-bit data and, for the update forms, the address in each
entry; an answer FIFO for the memory unit's two descriptors; a fault at
the pop refetching the load), which is a larger change than the one
approved. Rather than carry a cache interface and a capture state
machine for nothing measurable, the early-load half was removed before
the commit; this record is what remains of it.

**Removed after it: the admission of an FP operation from ID.** With EX
pushing every eligible FP operation at its take, overlap (1)'s issue
register (`fq_*`) could only fill behind a compare or a traps-on
operation in EX, and the fit of the step (`Scratch/q70f4`: 37,662 ALMs,
-2.73 ns, the failing pairs past the script's 20,000) had ID's admission
as its worst families: the instruction word through the decoder into
`completion_count`, the entries' register number, the younger-writer
bitmap `cq_fpr_y`. Tied off, the microbenchmarks did not move and the
random FP program lost 0.7 % (2.67 against 2.65 cycles an instruction),
so the issue register, the admission and the FPR bitmap of younger
entries were removed: the queue's only FP writer is EX's push, the
order FIFO marks EX's or a slot's answer, and the ALU admission's
machinery (`completion_push_alu`, the younger-writer bits for GPRs)
stays for `COMPLETION_ALU`. The fit without it (`Scratch/q70f5`):
36,952 ALMs (88 %), 10,847 failing pairs, -2.70 ns, `q70c7`'s level
(36,334, 10,399, -2.58): the whole of the FPU's overlap work costs
618 ALMs and no timing the fitter's swing can tell.

Where this leaves the FP pipeline: independent operations stream at the
unit's rate (3.27 cycles an operation), dependent chains at its latency
(5.25), everything that does not depend on an FP operation runs in EX
while it computes, and a branch behind it resolves at once. What still
waits is anything that must *leave* EX behind a pending FP operation (a
load, a store, the next FP operation), because the leave is in order
through the queue; the paying next step is loads (and stores of other
registers) leaving EX into entries of their own, as the record above
says, and it is a design for the user, not a cut.

### Loads as queue entries: the design put to the user (2026-10-16, evening)

**What it does.** A load in EX behind a pending FP entry (today: it holds
EX until the entry pops) leaves EX into a completion-queue entry of its
own in the cycle the memory unit accepts its request, exactly as an FP
operation leaves at the unit's take. EX is free the next cycle; the
load's answer lands in its entry; the entry commits in order at its pop
(the register write, the update form's rA, the trace), as every entry
does. Loads whose order is ready go the normal way, unchanged. Stores
stay in EX until their order (a store's side effect is the store), as do
cache-inhibited loads in effect: the data cache holds one until its
entry is the head, and abandons it if a redirect has flushed it.

**The pieces.**

- *The entry* (`completion_t`) gains: `ld`, the effective address (32
  bits, for the update form's rA and the trace), `upd` and its rA (6
  bits), `fsgl` (an `lfs` is converted to the register's double as its
  answer is captured, one converter). The 64-bit value, rd (GPR or FPR)
  and the pending flag exist. A `fault` flag for a DSI on the early load.
- *The push* (`completion_push_ld`): a plain load (`CK_WORD`, no
  reservation, no string, one operation, any update form) accepted by
  the memory unit while `~ex_order_ready`; it joins the older set as the
  FP push does (the same bookkeeping at `ex_leave`), and `mu_valid`
  drops the order gate for such loads. The memory unit holds two
  descriptors, so up to two early loads may be in flight: a two-deep
  order FIFO (`lo_*`, as `fo_*` for the FPU) names the entry each answer
  is for; an answer is MEM's own access's whenever MEM or its older slot
  awaits one (they were accepted first), otherwise the FIFO head's.
- *The answer* into the entry's value (converted for `lfs`), or the fault
  flag. No live pop for loads: the answer's data path (the cache's word
  into `mu_rdata`) is the worst timing family of every fit and must not
  gain `mem_result` as another endpoint; the entry pops the cycle after
  its answer, which is one cycle later than a load in MEM reaches WB and
  matters only when the load is the critical path, which behind an FP
  operation it is not.
- *A faulting early load* is not committed: at its pop the queue is
  flushed and the fetch redirected to the load's own pc (`cq_refetch`
  into `redir`, the entry's pc into `redir_pc`), the FP entries before
  it having popped; the load then executes in EX in order and faults
  through the normal path with its DSISR and DAR. (The first redirect
  that comes from a pop; interrupts and the MEM fault keep their paths.)
- *GPR hazards*: an operation in EX reading a register a queued load
  writes waits for the pop, as FP operations wait on `cq_fpr_o`: a GPR
  bitmap of the older entries' destinations (`cq_gpr_o`, 32 bits, kept
  as the FPR one is) in `completion_dependency`, in place of the eight
  entry compares the ALU admission used. No forwarding from an entry.
  ID's reads already see WB's write; the issue of an operation into EX
  while an entry writes its source is covered by the stall in EX.
- *Flush*: a redirect clears the queue; the flushed early loads' answers
  are drained (a count of pending answers; `mu_valid` waits for zero)
  before the unit takes a request, so no answer is mistaken. The MEM
  interrupt resets the unit (its descriptors are ungranted then, as the
  interrupt boundary already requires), and `mem_irq` gains `mem_mem`
  so an early load's ungranted descriptor never raises it at a popped
  entry in MEM.
- *The data cache*: `ordered` (the request in hand is the queue head's,
  or no early load is pending) and `abandon` (flushed) inputs, held or
  answered-without-memory in its lookup state: as built on 2026-10-16
  afternoon for the removed version, then dropped with it.

**Cost.**

| | estimate |
|---|---|
| area | 500 to 700 ALMs: the entries' 40 new bits each, the GPR bitmap, the answer FIFO and drain, the converter, the refetch's pc mux; about 89 to 90 % of the device |
| timing | `ex_stall` gains the GPR bitmap's 32:1 select (one level, as the FPR one); `redir` gains a registered term and `redir_pc` a source; `mu_valid` loses a term; WB's update value gains a select; nothing on the cache's data path |
| cycles | lfd-lfd-fmadd loop 9.8 → about 6.3 an iteration (the chain's latency, the loads hidden), the random FP programs a further 5 to 10 % (a third of their instructions are loads), MacBench's FP test and Speedometer's FPU index the loads of the 68k emulator's load-operate-store pattern: a few per cent at most |
| rule 2 | a load's execution before older entries commit (its writes in order at the pop); the first redirect from a pop; the cache's hold and abandon of an inhibited access; GPR dependencies on queue entries |
| verification | directed programs with a page fault on an early load (translation on: the refetch path), interrupts over pending loads, a cache-inhibited load behind an FP operation, stores and loads to the same line behind one, loads with update; the random FP programs (they mix loads, stores, FP operations) and the integer random programs; the lockstep; the board with Debian, Mac OS, MacBench, Speedometer |
| effort | a session's day, with the debugging the afternoon's version took (two bugs of the same family: the done flag's branch, the update's value) |

**A smaller version**, if the cost is too much for the gain: FP loads
only (`lfd`, `lfdu`, `lfs`): no GPR bitmap, no change to `ex_stall`'s
GPR terms, and the FPR hazards exist; it covers the compiled FP loops
(the lfd-lfd-fmadd case in full) but not the 68k emulator's `lwz`
around each FP operation, so MacBench and Speedometer would not move.
About 350 ALMs.

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

## Later (2026-10-11 to 14)

The branch went on from here: the records are `docs/speed_results_20261011.md`
(the VIA timer fix, posted stores), `..._20261012.md` (MEM's second slot,
the cache banks, the BTB and ITT, branch folding), `docs/speed_results_20261013.md`
(the 110 MHz verdict) and `docs/speed_profile_20261013.md` (the profile,
the frame buffer's combiner, 100 MHz, the shrinking, the 64 KB I-cache).
The next-line prefetch above was overtaken by the 64 KB instruction cache
(fetch waits 23.5 % to 7.6 % on the idle desktop).
