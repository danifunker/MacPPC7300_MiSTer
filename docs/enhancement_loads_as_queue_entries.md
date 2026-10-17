# Enhancement: loads as completion-queue entries behind a pending FP operation

Status: designed, not built. Written 2026-10-16 (evening) on `fpu-pipe2`
after the FPU overlap work of that day (commits 4435e46, 5c1fc34, 8d794c9,
3f2dab7), for the day it is wanted. The decision is the user's (rule 2 of
`docs/DSPPC604_plan.md`: a change to how a hazard is handled or how state
is committed). Everything below refers to `rtl/DSPPC604/DSPPC604.sv` as of
3f2dab7; signal names are that file's.

## 1. What it is for

### 1.1 The pipeline as it stands

- The CPU is in order: fetch, ID, EX, MEM (two slots: the newer, and an
  older access that a younger operation has passed), WB. Results commit
  in program order at WB; the trace (one architectural snapshot per
  instruction, compared with dingusppc in lockstep) depends on it.
- The **completion queue** (`completion_queue[8]`, `completion_head/tail`,
  `completion_count`) holds operations that have left EX before their
  result is final; an entry pops into MEM, then WB, in order
  (`completion_pop`), so the commit order is kept. `completion_older_count`
  counts the entries older than the operation now in EX; while it is not
  zero, that operation may not leave, commit, redirect or request memory
  (`ex_order_ready`, in `ex_leave`, `ex_ready`, `mem_payload_take`,
  `mu_valid`, `sys_write_commit`, `redir` through `ex_leave`).
- Since 2026-10-16 an **FP operation leaves EX into an entry in the cycle
  the FPU takes it** (`completion_push_ex`, eligibility `ex_fp_elig`: an
  operation writing a register, FP traps off, fetched sequentially, not
  folded, the queue with room). Its result arrives into the entry
  (`fpu_resp_q`, the order FIFO `fo_*` naming the slot), the head entry's
  answer pops it in the answer's own cycle with the live result
  (`cq_live`, `cq_h_*`), the FPSCR and CR1 effects are applied at the pop
  (`cq_fpscr_new`, `cq_cr_new`). The FPRs that older entries write are a
  bitmap, `cq_fpr_o`, which `completion_dependency` reads for the operands
  of the operation in EX; there is no forwarding from an entry.
- The ALU admission from ID (`completion_push_alu`, `COMPLETION_ALU = 0`
  since 2026-10-11) is the only other writer of the queue, and it is off:
  its machinery (`completion_match`, `completion_latest_younger`,
  `completion_read`, the queue's ALU) is kept for the parameter.

### 1.2 What waits today

Everything behind a pending FP entry runs in EX, but whatever must
*leave* EX waits for the entry's pop:

| behind a pending FP operation | today |
|---|---|
| an integer operation | executes in EX, waits there to leave (one cycle of EX occupancy each; the next instruction waits behind it) |
| a branch | resolves at once; its redirect, if any, waits (overlap 3) |
| a load | its request waits too (`mu_valid` has `ex_order_ready`): the cache access does not even start |
| a store | waits (and must: the store is its side effect) |
| the next FP operation | taken by the unit as soon as its front is free (independent streams: one per 3.27 cycles); if it depends on the pending one, waits for the pop (`cq_fpr_o`) |

The measurements that show the cost (`progs.py fpbench`, `Scratch/fpbench`,
cycles an operation; `run_core.py`'s random FP programs, cycles an
instruction, seed 1 at 20 % wait states):

| program | before overlap 1 | overlap 1 (5c1fc34) | overlaps 2 and 3 (3f2dab7) |
|---|---|---|---|
| dependent fadd chain | 5.25 | 5.25 | 5.25 |
| independent fadd/fmul/fmadd | 5.25 / 5.25 / 6.25 | 3.27 | 3.27 |
| `lfd; lfd; fmadd f3,f1,f2,f3` loop | 3.27 an instruction (9.8 an iteration) | 3.27 | 3.27 |
| random FP program, seed 1 | 2.86 | 2.72 | 2.67 |

The lfd-lfd-fmadd loop is the shape of compiled floating-point code (a
dot product, a filter, a matrix multiply's inner loop). Its iteration is
9.8 cycles; the fmadd chain's own latency is 5.25; the difference is the
two loads sitting in EX until the fmadd pops. That is the gap this
enhancement closes.

### 1.3 What was tried first, and why it did not pay

On 2026-10-16 afternoon a smaller version was built: the load *stayed in
EX* but requested the memory unit early (without `ex_order_ready`), its
answer captured in EX (`ex_ld_cap`) and handed to MEM as a non-load
result when the load's turn came. It passed every test and gained
nothing measurable (the loop unchanged at 3.27, the random programs
0.1 %): the cache access overlapped the FP operation, but the load still
held EX, so the second load and the next fmadd could not enter. The
record is in `docs/fpu_pipe_plan.md`, "Overlaps 2 and 3 as built". Two
bugs of that version are instructive for this one:

- A load's "done" flag was placed in the default branch of EX's done
  expression, but a load with update (`lfdu`, `lwzu`) is an integer-unit
  operation for its address (`is_int`), so the flag did not apply and the
  load left EX in the cycle its early answer arrived, MEM then waiting
  for an answer already taken. Any per-load state must gate `ex_done`
  outside the unit selection.
- A captured load with update wrote its data into rA: the update's value
  is MEM's result's low word (`wb_upd_val <= mem_result[31:0]`), which for
  a normal load is the effective address (`ex_result`) while the data
  comes from the memory unit at WB. An entry that holds the data needs
  the address as well.

## 2. The design

### 2.1 One sentence

A plain load in EX whose order is not ready leaves EX into a
completion-queue entry in the cycle the memory unit accepts its request;
its answer lands in the entry; the entry commits in order at its pop.

### 2.2 Eligibility (`ex_ld_elig`, static, from EX's registers)

```
ex_dec.mem_rd & ~ex_dec.mem_wr            a load
& (ex_dec.cop == CK_WORD)                 not dcbz, dcbf, dcbst, dcbi, icbi
& (ex_dec.resv == RESV_NONE)              not lwarx
& (ex_dec.str_bytes == 7'd0)              not lswi, lswx
& ex_first & ex_last                      one operation (not lmw's)
& ~x_pre                                  not already aborted
```

Update forms are allowed (section 2.5). `lfs` is allowed (section 2.6).
Cache-inhibited loads are allowed to be pushed: the data cache holds them
(section 2.8); the eligibility cannot know WIMG, which is the MMU's
translation of this cycle's address.

### 2.3 The push

```
completion_push_ld = ex_ld_elig & mu_accept & ~ex_order_ready
                   & (completion_count < 4'd8) & ~mem_fault & ~ex_abort
```

with `mu_valid` losing the order gate for eligible loads:

```
mu_valid = ex_valid & ex_done & mem_room
         & (ex_order_ready | (ex_ld_elig & (completion_count < 4'd8) & ~lo_drain))
         & ~mem_fault & ~ex_abort & ex_mem_access
```

(`mem_room` stays: MEM's room is not needed for an entry, but keeping it
keeps the request's conditions those of today plus one, and MEM has room
nearly always.) When the order *is* ready the load goes the normal way
(`mem_payload_take` into MEM), unchanged.

`ex_leave` gains `| completion_push_ld` as it gained `completion_push_ex`;
`ex_done` is unchanged (a load is done in EX in its cycle). The leave's
commits do nothing for a load (no CR, XER, LR, CTR, FPSCR, MSR). The
bookkeeping at `ex_leave` that adds the pushed entry to the *older* set
(`completion_older_count + 1`, `completion_latest_older[tail]` and the
clearing of the same-destination bits, the `cq_fpr_o` or `cq_gpr_o` bit)
is the FP push's, with `completion_push_ld` added to its condition and
`completion_push_rd` carrying the load's `ex_rd` (bit 6 for an FPR).
`mem_valid` is not set at that leave (as for the FP push).

The sim checks "committed EX operation did not capture its MEM payload"
and "two operations entered MEM" exclude the push, as they do for the FP
one; "memory access overtook queued result" excludes `ex_ld_elig`.

Two pushes cannot meet: `completion_push_ex` needs `is_fpu`,
`completion_push_ld` needs `mem_rd`; the ALU admission (`COMPLETION_ALU`)
needs `completion_wait`, which an eligible load does not satisfy. A sim
check says so.

### 2.4 The entry

`completion_t` (package) gains:

| field | bits | use |
|---|---|---|
| `ld` | 1 | a load's entry: its value comes from the memory unit |
| `ea` | 32 | the effective address: the update form's rA value, MEM's `mem_ea` (the trace's and the DAR's) |
| `upd`, `upd_ra` | 1 + 5 | the update form: rA <- EA at WB (`mem_upd`, `mem_upd_ra`) |
| `fsgl` | 1 | an `lfs`: the answer is converted on capture (section 2.6); the pop sets nothing single about it |
| `fault` | 1 | the answer was a fault: the pop refetches (section 2.7) |

`value` (64), `rd` (7), `we`, `pc`, `insn`, `rc` exist. The pending flag
`completion_fp_pend` becomes `completion_pend` (an FP or load answer
awaited). Eight entries: 40 new bits each, 320 flops.

The pop into MEM for a load entry: `mem_valid <= 1`, `mem_pc`, `mem_insn`
from the entry, `mem_last <= 1`, `mem_first <= 1`, `mem_fold <= 0`,
`mem_upd <= entry.upd`, `mem_upd_ra <= entry.upd_ra`, `mem_rd <= entry.rd`,
`mem_rd_wr <= 1`, `mem_result <= entry.value`, `mem_ea <= entry.ea`,
`mem_load <= 0` (the data is in the result: WB takes `wb_other`),
`mem_store <= 0`, `mem_fp <= entry.rd[6]`, `mem_fsgl <= 0`, the trace
registers as for an FP pop but with `cr`, `fpscr` unchanged. WB's update
value: today `wb_upd_val <= mo_valid ? mo_result : mem_result[31:0]`;
a popped load entry needs `mem_ea` instead, so `mem_upd_val_sel` (a
register set at the pop) selects `mem_ea` into `wb_upd_val` for that
operation. One 2:1 select on a WB register's input; not on a timed path.

### 2.5 The update forms

`lwzu`, `lfdu`, `lbzu`, `lhzu`, `lhau`, `lfsu`, `lwzux` and the rest: the
entry's `ea` carries the address; the write of rA happens at WB in order
(section 2.4). The rA hazard: an operation in EX reading rA while the
entry is queued stalls on the GPR bitmap (section 2.9), since the entry's
destinations are *two* registers: `cq_gpr_o` gets both bits at the push
(`ex_rd` when it is a GPR, and `ex_dec.ra` when `ex_dec.upd`), and the
pop clears both (the latest-writer rule per register: a later entry
writing the same register keeps the bit; see `cq_pop_clear`'s form).

### 2.6 `lfs`

The register file holds doubles; an `lfs`'s single is converted at WB
(`wb_value = wb_fsgl ? fp_single_to_double(wb_result[31:0]) : wb_result`),
and a forwarded `lfs` carries its single with `wb_fsgl` for the readers
(`wb_fwd`, `wb_fden` for the denormal stall). For an entry, the conversion
happens at the capture: `value <= entry.fsgl ? fp_single_to_double(mu_rdata[31:0]) : mu_rdata`
(one converter, about 50 ALMs, on the capture path, which is not timed
tightly: the memory unit's `rdata` into the entry's register). The pop
then presents a double, `mem_fsgl = 0`, and the forwarding from MEM of a
popped entry is a double's: no `wb_fden` case arises for it.

### 2.7 A faulting early load

The memory unit answers a fault (`mu_resp & mu_fault`: a DSI, or an
alignment exception, `mu_falign`) with DSISR and DAR in `mu_dsisr`,
`mu_dar`. An early load's fault cannot be taken when it arrives (older
entries have not committed) and carrying DSISR and DAR in the entry would
be 64 more bits and a second fault path into `redir_pc`, SRR0, SRR1, DAR
and DSISR. Instead the entry is marked `fault` and **its pop refetches
it**:

```
cq_refetch = completion_pop & completion_queue[head].ld & completion_queue[head].fault
redir      = mem_fault | cq_refetch | (ex_leave & (...))
redir_pc   = mem_fault ? vector : cq_refetch ? completion_queue[head].pc : ...
```

The pop then does not enter MEM (`completion_pop` still advances the
head, and `redir` clears the queue anyway). The redirect flushes EX, ID
and the fetch, and the load is fetched and executed again, in EX, with
its order ready (the FP entries before it have popped), so it requests
the memory unit the normal way and faults through the normal path, with
the DSISR and DAR of that execution and the pipeline state the handler
expects (SRR0 at the load, the MSR, the update not done). The second
execution may not fault (a page mapped meanwhile): then it completes
normally, which is also right. `refetches` in the perf counters counts
it.

`redir` is a hot signal (every commit, the fetch, the BTB); `cq_refetch`
is a register AND of two entry bits and the pop, which itself is
registered state (counts, `completion_pend`) and `mem_room`: one input
more on `redir`'s OR, and a 32-bit source more on `redir_pc`'s mux. The
`d_xl_flush` into the MMU and the `btb_rd_redir` need the same term where
they look at redirects from EX. The sim check "completion admitted during
redirect" (`completion_push & redir`) must allow `completion_push_ex &
cq_refetch`: the FP push does not wait for the order, so EX may push an
FP operation in the cycle a faulting load entry pops; that entry is
younger than the faulting load and the redirect clears it with the rest,
correctly. A load push cannot coincide (it needs `~ex_order_ready`, and
a refetching head means the order is not ready either; but the push's
`~mem_fault`-like gating must include `~cq_refetch` so that no entry is
written in the redirect's cycle).

### 2.8 Cache-inhibited loads

An inhibited load (a device register) must not be performed before its
order: a read may have a side effect (an interrupt status cleared, a FIFO
advanced). The eligibility cannot know, so the **data cache** gets two
inputs:

- `ordered`: the request in hand may go to memory uncached. From the CPU:
  `~(lo_count != 0) | (lo_slot[lo_head] == completion_head)`: no early
  load pending, or the oldest pending early load is the queue's head
  (every entry before it has popped). While not ordered, an `unc` access
  waits in `S_LOOK` (the sequential machine does not go to `S_UNC`; the
  combinational answer is 0). Cached hits and misses proceed regardless.
- `abandon`: the requester is gone (a redirect flushed the entries): the
  held access is answered without memory (`ans_now = 1`, data zero) and
  the machine returns to idle; the answer is drained (section 2.10).

The afternoon's version had exactly these two inputs in
`DSPPC604_cache.sv` (`S_LOOK`: `if (unc) ans_now = ordered ? post_take :
abandon;` and the state transition `if (ordered) S_UNC else if (abandon)
S_IDLE`), tied to 1 and 0 at the instruction cache; it was removed with
that version (commit 3f2dab7's parent has it in the working tree's
history only through this record: re-add it from the description).

While an inhibited early load is held, the data cache is in `S_LOOK` and
takes no other request; the snoop port (DMA) waits too. The hold ends
when the FP entry before it pops (a few cycles). A write-through store
miss is `unc` as well but a store never comes early.

### 2.9 Hazards

**GPR destinations.** Today `completion_dependency`'s GPR terms
(`completion_match` over eight entries for `ra`, `rb`, `rc`) are gated by
`COMPLETION_ALU != 0`. With load entries they are needed, and the cheaper
form is the FPR one: a 32-bit bitmap `cq_gpr_o` of the GPRs the older
entries write, set at the push (the destination, and rA for an update
form), cleared at the pop of the latest older writer (the
`completion_latest_older` bit, as `cq_pop_clear` does for FPRs),
transferred at `ex_leave` exactly as `cq_fpr_o` is. `completion_dependency`
gains `(ex_dec.ra_rd & cq_gpr_o[ra]) | (ex_use_b & cq_gpr_o[rb]) | (ex_dec.rc_rd & cq_gpr_o[rc])`:
three 32:1 selects by registered indices, one level into `ex_stall`. A sim
check compares the bitmap with `completion_match` as the FPR one is
compared with `completion_fmatch`.

**FPR destinations.** `cq_fpr_o` as today; `lfd` and `lfs` entries set it.

**ID's admission** (the ALU one, off) reads `completion_a/b` with
`completion_read` over entries: an entry that is a pending load has no
value yet; `completion_read` must treat a pending entry as "in flight"
(bit 32 set), as it does for EX's result. Only matters with
`COMPLETION_ALU = 1`.

**Stores behind a queued load.** A store in EX waits for its order
(unchanged), so it never passes a queued load to the same address. A
load behind a *store* in MEM: the store was accepted by the memory unit
first; the data cache merges a pending store into a later read of the
same line (`forward_pending`), as today for any load after a store.

**Loads behind loads.** Two early loads may be in flight (the memory
unit's two descriptors). They are answered in order of acceptance; the
order FIFO names their entries (section 2.10). A third eligible load
waits for `mu_ready` as any request does.

**The next FP operation** reading a queued load's register: `cq_fpr_o`
stalls it until the pop, as it stalls behind an FP entry today. No
forwarding from an entry (as decided for overlap 1: an 8:1 64-bit mux on
the FPU's operand path, on a critical register bank).

**Exceptions of the operation in EX** behind queued loads wait for
`ex_order_ready` (unchanged); a MEM fault (the access in MEM, older than
every entry) flushes the entries (unchanged); interrupts: section 2.11.

**The update form's rA as a source of the next instruction**
(`lwzu r5, 4(r5)` then `lwz r6, 0(r5)`): the bitmap holds rA until the
pop; the next load stalls in EX; correct and the common idiom's cost (the
next load waits for the pop, then goes early itself if the FP entry is
still pending).

### 2.10 The memory unit's answers and the order FIFO

The memory unit (`DSPPC604_mem_unit`) holds up to two descriptors and
answers them in order (`resp_valid` one cycle each, `rdata` then). Who an
answer belongs to:

1. If MEM's older slot holds an access (`mo_valid`), or MEM's newer slot
   holds an unanswered access (`mem_valid & mem_mem`), the answer is
   theirs: they were accepted before any early load (an early load is
   pushed only while EX holds it, after MEM's access was accepted).
2. Otherwise it is the head of the load order FIFO `lo_*`: `lo_slot[2]`
   (entry indices), `lo_head`, `lo_tail`, `lo_count` (0 to 2), pushed at
   `completion_push_ld`, popped at the answer. A sim check: an answer with
   nothing in MEM and `lo_count == 0` is a fatal ("unowned memory
   response"), unless draining.

The capture: `completion_queue[lo_slot[lo_head]].value <= converted mu_rdata`,
`.fault <= mu_fault`, `completion_pend[slot] <= 0`, in the answer's cycle.
No live pop (section 3 says why): the entry pops in the next cycle at the
earliest, if it is the head.

`mem_dsi` (`~mo_valid & mem_valid & mu_bfault`) must not fire for an early
load's fault: add `mem_mem` (MEM's own access awaits the answer); the
sim check "the DSI differs from the answer's fault" gets the same term.
`mem_leave` for a non-access in MEM is immediate and does not look at
`mu_resp`; for an access, the answer is its by rule 1.

**Drain.** A redirect clears the queue while early loads may be in the
memory unit. Their answers still come; `lo_drain <= lo_count` at the
flush (minus an answer in that cycle), decremented by each answer while
not zero; while `lo_drain != 0`, `mu_valid` is held (no request may be
accepted behind the stale ones, or its answer would be mistaken), the
answers are dropped by everyone (`mem_dsi` is already gated; the capture
is gated by `lo_count`, which the flush zeroed), and the data cache sees
`abandon` for a held inhibited access. The MEM interrupt resets the
memory unit (`reset | mem_irq`), after which no answer comes: the drain
is not set when the flush is `mem_irq`. (The interrupt boundary already
requires the current descriptor to be ungranted; a queued second
descriptor is ungranted too, the unit grants in order.) After a redirect,
EX is empty for three cycles, so the drain costs nothing unless an early
load had missed the cache.

### 2.11 Interrupts

`mem_irq` is raised at MEM's operation when it is an access whose
descriptor is ungranted (`mu_pending = S_HOLD0`): add `mem_mem`, so a
popped non-access in MEM with an early load's ungranted descriptor behind
it does not take the interrupt "at" an already committed operation (a
popped FP entry's FPSCR is committed at its pop; taking an interrupt at
it would repeat it). An interrupt is then taken at the next access, or at
EX (`irq_ext`, `irq_dec` at `ex_first`), as today. The redirect of the
interrupt flushes the queue's younger entries, correctly: they are after
the interrupted instruction.

An early load that was *granted* (performed, a cache fill under way) when
an interrupt is taken at an older access: impossible by rule 1 of 2.10
(an older access in MEM awaiting its grant means the early load's
descriptor is behind it and ungranted) and by the unit granting in order.

### 2.12 Flush of EX itself

`ex_flush` (the operation in EX aborted, or a MEM fault) with
`completion_push_ld` in the same cycle: `completion_push_ld` has
`~mem_fault & ~ex_abort`, so no push. A redirect from a branch in EX
needs `ex_order_ready`, a load push needs its opposite: exclusive. A
redirect from a pop (2.7) is gated out of the push explicitly.

### 2.13 What the trace sees

The pop into MEM carries `pc`, `insn`, `ea`; WB emits one snapshot per
instruction in order as today. The lockstep bench compares every
instruction's registers and the device accesses' addresses and data in
order; an early load's *bus access* happens earlier than in the reference
(dingusppc executes in order), which the comparison of device accesses
could see only for inhibited loads, and those are held until ordered. A
cacheable load's early cache fill is invisible to the comparison.

## 3. Timing and area

| | estimate | why |
|---|---|---|
| entries | 320 flops | 40 new bits in each of 8 entries |
| `cq_gpr_o` and its logic | 32 flops, ~60 ALMs | as `cq_fpr_o` |
| `lo_*`, drain | ~12 flops | |
| the converter | ~50 ALMs | `fp_single_to_double` on the capture path |
| `redir_pc` source, `redir` term | ~40 ALMs | a 32-bit 2:1 more in the mux |
| the cache's inputs | ~10 ALMs | |
| the pop's new MEM fields, WB's update select | ~50 ALMs | |
| **total** | **about 500 to 700 ALMs** | 89 to 90 % of the device (36,952 ALMs, 88 %, at 3f2dab7) |

Timing, by the fits' known families (`docs/MacPPC7300_plan.md`, "timing",
and the FPU overlap rows):

- The cache's answer into `wb_result` and its readers is the worst family
  of every fit (-2.0 to -2.7 ns). **No live pop for loads**: the answer
  goes into the entry's register (a plain register load from `mu_rdata`
  through the converter's mux), never into `mem_result` in the same
  cycle. The converter adds levels to that register path but it is a
  register endpoint with no further logic.
- `ex_stall` gains three 32:1 selects (`cq_gpr_o`): one LUT level, as the
  FPR terms added in overlap 1 (which the fits did not show).
- `redir` gains one registered term; `redir_pc` a mux source. `redir` is
  in the fetch's and the BTB's paths; the fits of the timing pass had the
  fetch's grant with the redirect cut out already (2026-10-15), so a term
  on `redir` is one input on an AND-OR, to be seen in the fit.
- `mu_valid` loses `ex_order_ready` for eligible loads: fewer inputs.
- The push's bookkeeping at `ex_leave` is the FP push's with one more
  OR input.

Judge over two fits, as the timing pass learned: the fitter swings a
family 0.5 to 1 ns between fits of the same source.

## 4. Expected performance

| program | today (3f2dab7) | expected | why |
|---|---|---|---|
| `lfd; lfd; fmadd f3,f1,f2,f3` loop (`fpbench lfdmadd`) | 9.8 cycles an iteration | about 6.3 | the loads leave EX at once; the chain's latency (5.25) plus the fmadd's and bdnz's cycles in EX remain |
| the same with two accumulators (unrolled) | not measured | about 3.5 an fmadd | the independent streams' rate (3.27) plus the loads' |
| dependent and independent FP chains alone | 5.25, 3.27 | unchanged | no loads |
| random FP programs (`run_core.py`, a third loads and stores) | 2.67 cycles an instruction (seed 1) | 2.4 to 2.5 | every load behind a pending FP operation leaves early; stores still wait |
| integer code (Dhrystone, Speedometer CPU and Mix, the ROM boot) | | **identical to the cycle** | no FP entry pending, no early load: the condition `~ex_order_ready` is never true |
| 68k-emulated FP (Speedometer FPU, KWhetstones, MacBench FP) | FPU 7.87, MacBench 142 at 100 MHz | a few per cent at most | each FP operation is wrapped in the emulator's `lwz`/`stw`: the loads after it leave early, the stores still wait |
| native PowerPC FP code (compiled programs, Mac OS's FP routines) | | the loop's gain, 20 to 35 % on load-fed FP loops | the shape of 1.2 |

Measure: `fpbench` (add an unrolled two-accumulator kind and an
`lfdu`-based loop), the random FP programs, the lockstep's cycle count
(the ROM boot has almost no FP: identical expected), MacBench 4 and
Speedometer on the board (an Opus session), and if a native FP benchmark
can be put on a disk (a compiled Whetstone or Linpack for Mac OS, or
Debian's), that is the number that shows the gain.

## 5. Verification

Gates as always (`make -s lint`, `run_core.py` whole, `run.py`'s vectors
unaffected but run once, `run_machine.py` 300 M identical), plus directed
programs in `progs.py`, each in lockstep with dingusppc, with wait states
and under interrupts (`--irq-every`), in `run_core.py`'s list:

1. **`fpqtest`** extended: `lfd`/`lwz`/`lfdu`/`lwzu`/`lfs` behind a queued
   fmadd, their results used by the next FP operation and by integer
   operations (the GPR bitmap), a store of a queued load's register
   right after it (the store waits), two loads back to back behind one
   FP operation (both descriptors), a third (waits for `mu_ready`).
2. **A page fault on an early load** (translation on, as `irqtest`'s
   `faulting` variant does with a page table whose data page is
   invalidated): the entry's refetch, the DSI then taken in order with
   the right DSISR, DAR and SRR0, the FP result before it committed, the
   update form's rA untouched. With an interrupt arriving at the same
   time (`--irq-every`).
3. **A cache-inhibited load behind an FP operation**: the bench has a
   device region (`core_main.cpp`'s memory map; `mmutest` maps pages
   with WIMG) with a readable register whose read count the program
   checks (or the bench reports the number of device reads: it does,
   "device accesses ... compared"): exactly one read, after the FP
   operation's commit; and the same with a redirect (a mispredicted
   branch before the load... the load is younger than the branch, so a
   misprediction flushes it: zero reads) to exercise `abandon` and the
   drain.
4. **Interrupts over pending loads**: `irqtest`'s loop with an fmadd
   and two loads, external and decrementer interrupts every 61 and 97
   cycles, 3,000 loops: the handler's counts and the loop's results.
5. **Loads with update as the address of the next load** (`lwzu r5,4(r5);
   lwz r6,0(r5)` behind an fmadd): the bitmap's rA bit and its clearing.
6. **Random FP programs** (`fprandom`): already mix loads, stores, FP
   operations and FPSCR instructions at every wait-state setting; add
   update forms and `lfs` to the generator if missing.
7. **The integer random programs**, unchanged by construction: identical
   cycles expected (the check is the diff of `run_core.py`'s cycle
   counts, as this session did).

Then the board (an Opus session, per the user's wish of 2026-10-16):
Mac OS 7.6.1, 9.1, Debian for a while (its exception paths), MacBench 4,
Speedometer, and a native FP benchmark if one is on a disk.

## 6. The smaller version

**FP loads only** (`lfd`, `lfdu`, `lfs`, `lfsu`, and their indexed forms):
the eligibility adds `ex_dec.mem_fp`. No GPR bitmap, no change to
`ex_stall`'s GPR terms (the FPR hazards exist); the update form's rA is
still a GPR (`lfdu`), so either the update forms are excluded too (then
no `ea` field, no `cq_gpr_o`: about 250 ALMs) or the GPR bitmap is kept
for rA alone. It covers the compiled FP loops in full (the lfd-lfd-fmadd
case) and nothing of the 68k emulator's integer loads around each FP
operation, so MacBench's FP test and Speedometer's FPU index would not
move. About 350 ALMs with the update forms, 250 without.

## 7. Open questions (to settle when building)

- Whether `mem_room` should stay in `mu_valid` for an early load: it is
  not needed (no MEM slot is taken), but dropping it changes the request's
  conditions in the normal path's cone; keep it unless the fit asks.
- The order FIFO's depth: two, the memory unit's capacity; a third eligible
  load waits for `mu_ready`, which is the unit's own backpressure.
- Whether a load entry should pop live when it is the head and its answer
  arrives (saving a cycle for the consumer): no, for the data path's
  timing (section 3); revisit if a fit shows slack there.
- Whether to let *stores* behind a pending FP operation into entries
  (a store queue: data and address per entry, performed at the pop; the
  memory unit would need a request from the pop, which today only EX
  makes): out of scope here; it is what would move the 68k emulator's
  pattern (`lwz, FP op, stw`), and it is a bigger change.
- `COMPLETION_ALU = 1` together with load entries: `completion_read` must
  see a pending load entry as in flight; otherwise untested together.

## 8. References

- `docs/fpu_pipe_plan.md`: step 2's overlaps, "Overlap 1 as built",
  "Overlaps 2 and 3 as built" (the afternoon's early-load version and
  its two bugs), "Loads as queue entries: the design put to the user".
- `docs/MacPPC7300_plan.md`, decisions rows "FPU overlap", "FPU overlaps
  2 and 3" (the measurements, the fits `q70f2` to `q70f5`, the board).
- `docs/DSPPC604_plan.md`: the rules, M4 (the pipeline, the queue).
- `docs/speed_AT_log.md`: the completion queue's origin (the ALU
  admission).
- `verilator/progs.py`: `fpbench`, `fprandom`, `fpqtest`, `irqtest`;
  `verilator/run_core.py`: the suite.
