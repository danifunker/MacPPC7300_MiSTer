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

## CPU performance goal (2026-10-09)

**Current handoff, 2026-10-10 12:24 PDT:** work is paused at the user's
request. [RESUME_speed.md](../RESUME_speed.md) is authoritative for retained
CPU work, exact source hashes, tests, candidate timing and next steps; the
older progression below is historical. Root retains AT. The goal remains
70 MHz full-machine closure plus measured overall2x at fixed clock against
0186181, followed by higher-clock work; neither acceptance gate is met.
Newest isolated CL/CM pass functional gates and300M ROM lockstep but fail
CPU setup at59.81/59.65 MHz. All owned builds/runs are terminal. The original
CPU and AT both diverge at the same lswx4KB-boundary alignment exception;
strict reference diagnosis is next. The board is baseline55/new Main/one
SC0 disk, with no confirmed clean shutdown or hardware performance scores.

Root now matches verified AT CPU/video source hashes. CPU/lint, all checked
mixes, specfetch, 6 MB memtest and 300 M ROM lockstep pass. Full-machine seed 1
with retiming off fits at 34,701 ALMs (83%): CPU setup still fails at
60.38 MHz / -2.278 ns. Memory 100 MHz setup passes with only +0.001 ns
minimum margin; all-corner hold passes (+0.087 ns). Newer AU–BY experiments
remain isolated. The passing AT55 comparison build is temporarily on the
board; failed 70 MHz candidates remain undeployed. The following measurements record
the progression to AT. Root clock/PLL/QSF/SDC are unchanged. The 70 MHz
and 2x board acceptance gates remain open.

Latest isolated timing candidate U combines RAM predictor/FPRs, registered
data translation, cache forwarding/byte selection and pipelined RAS payload
writes. CPU/lint, all 16 checked mixes, collision-poisoned suite, 6 MB memtest
and trained discarded-I-fetch regression pass. A 600 M ROM/disk lockstep
also passes with identical state/device accesses (946,832,881 post-Cuda
cycles, 18 out-of-RAM/ROM instruction fetches). This does not establish OS
boot or performance. U reaches 57.33 MHz / 14,964 ALMs with retiming off;
the same source reaches 59.32 MHz / 16,542 ALMs with retiming on (V).
Y adds registered ICBI ACK, data read-ahead/TLB collision freshness,
predictor validity and one-hot branch CR selection. CPU/lint and all 16
mixes pass; retiming-off/on diagnostics finish at 57.80 / 58.03 MHz. Z adds
a registered FP compare response (one additional compare cycle). It passes
CPU/lint/unit vectors (operand register off/on), cache/tag/data/TLB collision
poisoning, 16 checked mixes, 6 MB memtest, trained discarded-I-fetch regression
and 300 M ROM/disk lockstep (465,358,126 post-Cuda cycles; 16 I-device fetches).
The zero-wait FP vector program costs 590,750 cycles versus Y's 590,423.
Z reaches 58.97 MHz / 14,940 ALMs retiming off, 59.31 MHz / 16,995 ALMs on;
both fail 70 MHz. Z was integrated before verified AF. Full-machine
seed 1 (`seed_fcmp_reg_no_retiming_v2/`) fits at 35,935 ALMs (86%) but fails
setup: CPU 55.17 MHz / -3.841 ns; memory 88.83 MHz / -1.257 ns versus 100 MHz.
All four hold corners pass; clocks are constrained, but stock external I/O
still has unconstrained ports. The first scratch copy omitted the PLL inputs
and stopped before fitting. Full-machine timing at
70 MHz and the matched fixed-clock Speedometer 2x target are outstanding.

Later isolated cuts AA (registered data lookup page) and AB (ID completion
predecode) pass CPU/lint/performance but reach only 58.34 and 57.64 MHz.
AC adds two registered fetch FIFO output slots; AD selects branch CR from
committed CR using an EX one-hot selector. CPU/lint and all 16 checked mixes
pass for both; AD also passes full cache/tag/data/TLB/BTB/target/FPR collision
poisoning, trained discarded-I-fetch regression and 6 MB memtest. Their
standalone timing finishes at 56.93 / 59.14 MHz, both failing 70 MHz. AD's
300 M lockstep passes (481,830,131 post-Cuda cycles; 25 I-device fetches).
AE hides unused combinational compare FPSCR/CR outputs until its registered
response is valid. CPU/lint, unit vectors in both operand modes, all checked
mixes, full collision-poisoning suite, trained specfetch and memtest pass;
300 M lockstep passes (481,830,131 post-Cuda cycles). Standalone retiming
off/on reaches 59.95 / 56.44 MHz. AF parallelizes current/predicted BTB-valid
selection and replaces the video width's power-of-two multiply with a shift.
CPU/lint, exact AE performance counts, specfetch and memtest pass; standalone
timing improves to 61.88 MHz. AF 300 M lockstep passes. Its full-machine
build fits at 36,631 ALMs; CPU setup fails at 57.97 MHz, but the 100 MHz
memory domain passes all four corners (minimum setup +0.268 ns).
AG forwards an LFS word directly to STFS, removing the conversion round trip;
CPU/lint, exact checked mixes, collision poisoning and 48 directed edge cases
pass. Standalone timing worsens to 58.70 MHz as cache-hit-to-commit control
becomes critical. AH separates ID/EX admission capacity from abort/fault
decisions (60.68 MHz); AI simplifies repeated memory-acceptance qualification.
CPU/lint and exact mixes pass for both. AJ captures FP compare operands before
comparison, adding one cycle only for OPERAND_REG=0 compares. CPU and unit
vectors in both operand modes, full collision poisoning, 576 directed
compare cases and 300 M lockstep pass. Full-machine CPU timing reaches only
57.61 MHz (-3.074 ns). AK removes redundant redirect qualification from
completion admission (62.91 MHz standalone). AL/AM/AN remove late exception
control from admission/payload capture and reuse parallel BTB row equality.
AN passes CPU/lint, exact mixes, collision poisoning and 300 M lockstep;
its full-machine CPU timing worsens to 55.98 MHz while memory 100 MHz passes.
AO computes FPSCR candidates before selecting forwarding tags. CPU/lint,
exact mixes, collision poisoning and 480 directed field-mask/denormal/NaN
cases pass, including full-helper/original-updater equivalence assertions.
Standalone AO reaches 60.76 MHz; specfetch, memtest and 300 M lockstep pass.
AP compares cache tags before forwarded-hit selection: CPU/lint, exact mixes,
collision poisoning and specfetch/memtest pass. Standalone reaches 61.85 MHz;
300 M lockstep passes; full-machine CPU57.95/memory96.7 MHz both miss targets.
AQ registers cache-control
replies while preserving word throughput; it passes CPU/lint/exact mixes and
collision poisoning but standalone timing worsens to 60.65 MHz, so it stays
isolated. AR branches from AP and replaces LFS denormal conversion with
parallel fixed shifts/exponents. All 34.6 M equivalence checks pass, as do
CPU/lint, exact mixes, collision poisoning and directed edge cases. Machine
specfetch/memtest pass and 300 M lockstep is running. Standalone AR worsens
to 60.32 MHz: cache-response-to-BAT-write control becomes critical. AS tests
ordinary-capacity system-register commit with an assertion of exact original
commit equality. CPU/lint/exact mixes/collision poisoning pass; standalone
60.53 MHz. AT stores the integer register file in five synchronous RAMs,
with prospective instruction and sequencer reads independently of admission.
CPU/lint/exact mixes/collision poisoning against the original asynchronous
RF pass; all five forwarded collision samples have positive coverage.
Specfetch/memtest/300 M lockstep pass. Standalone AT uses 13,907 ALMs /
9,925 registers, saving 1,808 ALMs and 1,175 registers versus AS; timing is
61.16 MHz. Retiming on worsens standalone timing to 57.86 MHz. Full-machine
AT improves CPU timing by 2.41 MHz and saves 1,930 ALMs versus AF; AT is
integrated with exact hashes and the root suite/lint rerun passes.
AU compares branch PCs before selecting mismatch by outcome; CPU/lint,
exact mixes and collision poisoning pass; timing is 61.43 MHz.
Specfetch/memtest/300 M lockstep pass.
AV holds redirect payloads in alternating banks so late control updates
only selectors; CPU/lint/exact mixes/collision poisoning pass with exact
original PC state assertion. Standalone timing is 62.42 MHz; specfetch and
memtest/300 M lockstep pass; full-machine CPU reaches 58.69 MHz and MEM100
fails by -0.003 ns, worse than integrated AT. AW applies
the earlier registered cache-control reply cut to AU; CPU/lint/exact mixes/
collision poisoning pass, timing is 61.87 MHz. AX registers live GPR WB
forwarding indices; CPU/lint/exact mixes/collision poisoning pass, timing
improves to 62.66 MHz. AY replaces shift-mask boundary arithmetic with
constant comparisons; 192,512 RTL ALU equivalence cases and full correctness
gates pass, but timing worsens to 62.09 MHz. AZ tests alternating EX operand
banks to remove late cache replies from wide operand load enables; CPU/
lint/exact mixes/collision poisoning pass; timing reaches 62.73 MHz.
AU–BC pass specfetch, memtest and 300 M ROM lockstep. BA samples status
using earlier ordinary capacity; BB samples fault payload independently
of admission; BC uses a synchronous instruction-side SR copy. These reach
61.20, 62.09 and 60.68 MHz respectively. BD banks memory request payloads
and reaches 62.61 MHz. BE is a direct AT fork with registered forwarding
flags: full CPU/lint/exact mixes/collision tests pass, 62.27 MHz. Full BE
fits at 34,650 ALMs, CPU70 -2.723 ns, MEM100 -0.259 ns; keep it isolated.
BD/BE also pass specfetch/memtest/300 M machine lockstep. BF tests parallel
BTB validity candidates before late fetch admission; CPU/lint/exact mixes/
collision/specfetch/memtest/300 M pass, but timing worsens to 60.38 MHz.
Matched AT and original baseline builds at 60 MHz failed timing, including
both AT seeds and a retimed baseline. Matched 55 MHz builds pass CPU/MEM
setup and all-clock hold at all four corners, with verified derived clocks.
The AT55 build reaches OS8.1’s desktop background, but Finder reports the
Mac disk cannot be found and clean shutdown also fails. No scores or
baseline boot comparison yet; preserve the disposable disk and obtain an
explicit exception to the no-reload-while-mounted rule before resetting.
Root remains 70 MHz
and fixed-70 acceptance remains outstanding.
Root remains AT;
`RESUME_speed.md` records exact paths, hashes, measurements and active jobs.

Further isolated experiments: BG enables the existing registered D-cache
answer on BE. CPU/lint/16 lockstep mixes pass, standalone reaches 64.95 MHz,
but cached streams regress from roughly one to two cycles per access;
keep it isolated. BH's aggregate MLAB attribute leaves M10K inference and
timing unchanged. BI declares a packed tag array per generated way; full
CPU/lint/collision tests and all 16 exact BE mixes pass; Quartus still maps
tags to M10K and timing remains 62.27 MHz. Specfetch/memtest and 300 M
machine lockstep pass (481,830,131 post-Cuda cycles, 25 I-device fetches).
BJ's explicit QSF memory assignment was ignored: braced node pattern invalid
(Critical Warning 136021). BK corrects quotation; BL broadens the pattern;
both still produce identical M10K implementation/timing. A minimal Quartus17
probe proves the tested generated RAM declarations ignore the same hints
that work at module scope. BM places tag RAM declarations in a helper module:
CPU/full collision suites and all16 exact BI mixes/events pass. Synthesis
finally infers all8 tag RAMs as MLAB (22,528 bits), but final timing worsens
to 58.11 MHz with 14,628 ALMs / 10,149 registers / 93 RAM. Lint/specfetch/
6MB memtest pass; remaining 300M run stopped after timing rejected BM.
Keep this candidate isolated. Module-scope M10K RAMs with honored
no_rw_check may be worth testing next; currently a hypothesis.
BN applies module-scope M10K/no_rw_check to all72 cache tag/data RAMs;
synthesis confirms DONT_CARE; CPU/full collision/lint/exact mixes pass,
standalone63.34MHz. Full70 machine fails CPU59.84MHz/-2.426ns and
MEM10098.63MHz/-0.139ns; hold passes all4corners, minimum+0.076ns.
Keep isolated. Specfetch/memtest
and300M lockstep pass (481,830,131 post-Cuda cycles, 25 I-device fetches).
BO predecodes static FPSCR selectors at ID-to-EX to shorten the measured
FPSCR-to-redirect path; CPU/full collisions/lint/786432-case equivalence/
exact mixes pass; standalone63.32MHz. BP combines these independent cuts;
CPU/full collisions/lint/exact mixes/specfetch/6MB memtest pass, but timing
regresses to61.52MHz. Keep it isolated; no full-machine compile/300M/hardware.
BQ targets fullBN's CR-to-fetchFIFO RAM write-enable path by separating
physical stores from logical enqueues: redirect-discarded writes have no
visible effect. Original FIFO shadow checks every occupied word. CPU/full
collision/lint/exact mixes pass; seven mixes exercise discarded writes and
a wrong write-address negative control trips the shadow. Full70MHz timing
finishes at about60.71MHz (CPU setup-2.188ns); MEM100 cold also fails
(-0.099ns), while four-corner hold passes (minimum+0.091ns). Specfetch,
6MB memtest and300M lockstep pass; no OS boot or Speedometer proof.
BR reuses parallel row comparisons for BTB target forwarding too, avoiding
comparison after late fetch index selection. CPU/full collision/lint/exact
mixes/specfetch/6MB memtest pass. Standalone63.44MHz/-1.476ns improves
BQ's60.94MHz; full-machine timing remains necessary.
Full70MHz retiming-off seed1 completes at58.26MHz (CPUhot-2.878ns), worse
thanBQ/AT. MEM100 passes (+0.126ns minimum); all-corner hold passes
(+0.115ns minimum). Worst path is EX CR select -> MMU fault DAR capture.
Keep isolated; no300M or board result.
No new candidate is integrated or deployed.

BS replaces binary completion occupancy with nine-bit one-hot shifts,
targeting BQ's cache-response-to-completion-count timing path. Original
binary shadows check both total and older counts; a wrong-shift negative
control trips the shadow. CPU/full collision/lint/exact mixes/specfetch/6MB
memtest pass. A Quartus17 simulation-guard error was corrected with explicit
synthesis translate_off/on, and final functional checks rerun. Corrected
standalone timing completes at62.20MHz (14,030 ALMs/10,051 registers),
belowBR63.44MHz. Full70MHz retiming-off seed1 completes at59.53MHz
(CPUhot-2.514ns), aboveBR but belowBQ/AT. MEM100 fails cold-0.306ns;
all-corner hold passes (+0.059ns minimum). Worst CPU is WB operand
forwarding -> rotate/shift -> CR record field. Keep isolated; no board claim.

BT imports BB's prospective D-fault payload capture into BS, targeting
BR's branch-to-DAR enable path. Original visible fault payload shadow,
CPU/full collisions/lint/exact mixes/specfetch/6MB memtest pass; wrong DAR
negative control trips the shadow. Standalone63.57MHz improvesBS by1.37MHz.
300M machine lockstep passes. Full70MHz retiming-off seed1 completes at
58.97MHz (CPUhot-2.674ns), belowBQ/AT. MEM100 and all-corner hold pass
(+0.116/+0.117ns minimum). Keep isolated: CPU70 fails; no board claim.

BU direct word shifts preserve all9 raw ALU outputs in1,179,648 old/new
cases; negative saturated-carry control trips the miter. CPU/full collision/
lint/exact mixes/specfetch/6MB memtest pass, but standalone61.91MHz is
belowBT. No full compile/300M/board claim; keep isolated.
BV moves final CR overwrite application to MEM, with same-cycle effective
CR forwarding. Original next-value/EX-commit/MEM-snapshot shadows, CPU/full
collisions/lint/exact mixes/specfetch/6MB memtest/300M lockstep pass. Disabled
forwarding negative control trips the shadow. Standalone61.74MHz still
misses70; full70MHz retiming-off seed1 completes at58.32MHz (CPUhot-2.862ns),
belowBT/BQ/AT. MEM100 and all-corner hold pass (+0.054/+0.066ns minimum).
Worst CPU cache tag RAM -> HID0[15] captures still expose late reply feedback.
Keep isolated: CPU70 fails. No board performance claim.

BW pre-captures EX operands and HID0 in alternating banks, switching only
one-bit owners on original admission/commit. Owned-operand/HID0 shadows,
CPU/full collisions/lint/exact16 mixes/specfetch/6MB memtest pass. Disabled
EX bank switch trips the shadow. Standalone59.73MHz is belowBV; its worst
path runs from system-op decode through exception/redirect into BTB target
forwarding. All63 reported suite cycle counts and 300M machine lockstep
also match BV (481,830,131postCuda cycles); no OS boot or Speedometer proof.
Full70MHz retiming-off seed1 completes at58.53MHz:CPUhot-2.799ns/cold-2.796ns,
35,348ALMs/37,998registers/346RAM/48DSP. MEM100 and all-corner hold pass
(+0.118/+0.096ns minimum). Worst cache tag RAM -> wide-response qualification
-> load-window/format -> WB result. Keep isolated; CPU70 fails, belowAT/BQ.
BX removes the late wide-response zero-fill mux from BW's first-phase load
window. Successful first-phase doublewords already require wide validity;
noncrossing narrow loads use only the first word, and fallback loads use
saved word0/current second word. Original successful-load formatting shadow,
CPU/full collisions/exact16 mixes/all63 suite counts pass. Nonzero discarded
second-word coverage and corrupted first-word negative control are exercised.
Lint/specfetch/6MB memtest pass with exact BW counts. Standalone63.56MHz
improvesBW by3.83MHz (14,507ALMs/10,368registers/101RAM), but still misses70.
300M machine lockstep also passes at481,830,131postCuda cycles,exactBW.
Full70MHz retiming-off seed1 completes at57.90MHz (CPUhot-2.985ns/cold-2.863ns),
35,335ALMs/38,052registers/346RAM/48DSP. MEM100 also fails (-0.237ns cold);
all-corner hold passes (+0.114ns minimum). Worst cache tag RAM -> data-way
selection/load formatting -> WB result; the late wide qualification is gone
but full timing worsens. Keep isolated; no70MHz or board performance claim.
BY revisits actual module-scope MLAB tag RAMs in a full fit, since BM's
earlier slower result was only standalone and M10K tag-to-CPU return paths
still carry about2.4ns clock skew. Separate fixed32x128 data-word helper
retains M10K/no_rw_check and identical synchronous read/write transitions.
CPU/full collisions/lint/exact16 mixes/all63 suite counts/specfetch/6MB
memtest pass. Actual mapping confirms8MLABtaginstances/22,528bits and
64M10Kdatawordinstances. Standalone60.75MHz is belowBX63.56MHz
(14,901ALMs/10,462registers/93RAM). 300M ROM lockstep passes at481,830,131
postCuda cycles,exactBX. Full70MHz retiming-off seed1 improves to61.39MHz
(CPUhot-2.004ns/cold-1.950ns),36,083ALMs/38,314registers/338RAM/48DSP.
Full mapping also confirms8MLABtags and64M10Kdataword memories. MEM100
still fails cold setup (-0.193ns); all-corner hold passes (+0.106ns minimum).
Worst Dcache request tag -> hit response/completion/admission -> MEMforward
flags,15.748ns data delay. The tag-memory clock skew family is removed;
late control feedback remains. Keep isolated; CPU70 fails, no board claim.
BZ implements that cut in an isolated directBY fork: registers all three
producer-by-two-consumer forwarding masks, registers narrow selectors with
original admission priority, and qualifies visible masks with registered
MEM/WB validity. CPU/full inherited collision-poison suite/lint pass; all63
suite counts and all16 cycle/event dictionaries exactly matchBY. Original
captured-mask and tag-match observers check every cycle including invalid
EX; inverted consumer selection fails the original observer. Specfetch/
6MB memtest pass at522/27,333,623postCuda cycles with zero errors. 300M ROM
lockstep passes at481,830,131postCuda cycles,exactBY state/device accesses.
Standalone completes at61.39MHz hot/61.87cold (-2.002ns worst),14,962ALMs/
10,582registers/93RAM. Worst cache hit -> ID admission/fetch delivery ->
fetch-stage RAM bypass; the two-entry133bit output stage maps to4M10Ks
with automatic pass-through logic. Full70MHz OFF seed1 completes at59.08MHz
(CPUhot-2.641ns/cold-2.448ns),36,262ALMs/38,342registers/338RAM/48DSP,
worseBY61.39MHz. MEM100 all-corner setup passes,min+0.272ns; all-corner
hold passes,min+0.114ns. Worst Dcache request tag -> hit response/MEMleave/
ID admission -> saved GPR index enable,16.433ns data delay/-0.413ns clock
skew; fetch-delivery control has225loads. Only the intended CPU file differs
among118 full inputs,postbuild RTL matches manifest. Reject for integration,
keep isolated. No closure or board performance claim.

CA directBY fork excludesBZ and replaces the admission-enabled181bit ID
packet with two explicit named banks. The inactive bank samples the next
fetch packet; original delivery changes only a one-bit owner. Owner starts
at power-up and retains across CPU reset to preserve the original unreset
payload. Original181bit shadow compares every nonreset cycle including
invalid ID; disabled owner switching fails it. CPU/full inherited collisions/
lint/all63 suite counts/exact16 mixes/specfetch/6MB memtest pass with exact
BY cycles and zero memory errors. 300M ROM lockstep passes at481,830,131
postCuda cycles,exactBY state/device accesses. Standalone58.66MHz hot/
59.40cold (-2.761ns worst),15,045ALMs/10,688registers/93RAM; the worst
owner signal has680loads into raw instruction decode/sequence/EX operands.
Full70 OFF seed1 timing is running. Only the intended CPU file differs among118
full inputs. Validate mapping/owner fanout/EX-input mux costs against full
timing; keep isolated, no closure or board performance claim.

CB directCA fork captures the existing222bit fetch decode in the packet
banks (403bits per bank), moving raw decoding before ID selection. ISI
packets preserve the original all-zero decode of insn=0. An independent
original decoder compares every nonreset cycle including invalid ID;
corrupted decoded-valid fails this checker. CPU/full inherited collisions/
lint/exact16 mixes/all63 counts/specfetch/6MB memtest pass with exactCA
cycles and zero memory errors. 300M ROM lockstep and standalone/full70 OFF
seed1 timing are running. All118 full input hashes compared againstCA;
only intended CPU file differs,transferred hashes verified. Keep isolated;
no decoder-rule,operand,stage-handshake or latency change; no closure/board claim.

The user authorized the five architectural changes proposed in the CPU review:
buffered fetch, cache RAM addressing independent of grants, pipelined L1
accesses, improved branch prediction, and execution overlap or dual issue.
The first acceptance target is **2x Speedometer CPU performance at the same
70 MHz clock**, against build 46 / commit `0186181`, with full-machine
70 MHz timing closure. Only after that should a higher clock contribute to
the performance target. Quartus validation resumed when the user supplied
`misterubuntu` and MiSTer `10.0.2.14`; its objective is unchanged. Simulation cases that
exceed 2x are evidence about individual bottlenecks, not achievement of
the whole-machine target.

The implementation keeps the two architectural commit points, the existing
unit interfaces, and WB availability for load consumers:

- Fetch has a four-word queue with capacity reserved for its outstanding
  response. Admission uses registered occupancy, independent of ID/EX/MEM
  readiness. An empty queue passes a response directly to ID, retaining
  the original branch-recovery latency. Redirects discard queued words and
  drain an already accepted request. The MMU prevents an ISI from overtaking
  an older cache response and cancels ungranted walks on a redirect.
- Cache RAMs read a candidate set without waiting for a grant. The set bits
  come directly from the untranslated page offset. A dirty victim's tag and
  full line are captured before a speculative read replaces the RAM outputs;
  write-back uses those registers. Pending cache writes and writes colliding
  with a RAM read are forwarded per word and tag, allowing consecutive store
  hits and store/load pairs to the same set. Snoops still wait for pending
  same-set writes, and snoop priority is unchanged.
- The memory unit accepts a descriptor when a memory operation leaves EX.
  It retains that descriptor for response alignment and any second word.
  A subsequent request can be accepted during the preceding response, so
  independent L1 word loads sustain one per cycle. Data accesses still
  fault in MEM, stores still wait for all older faults to resolve, and load
  consumers still receive their result through WB. An interrupt can cancel
  a walk before acceptance; a cancelled walk cannot later fabricate a DSI.
  Doubleword hits within a line transfer both words in one access. Uncached,
  write-through stores, and line/page crossings retain the two-word fallback.
- The branch target buffer has two ways and 64 sets, retaining 128 total
  entries, with folded address indexing. An eight-entry speculative return
  stack is restored from committed call/return state on every redirect,
  including the branch committing at that edge. Predictions remain hints
  checked against the actual next PC in EX.
- An eight-entry completion FIFO holds speculative ALU results behind a
  multiply, divide or FP operation. Eligibility comes from the decoder's
  unit, register and side-effect declarations: no memory, traps, privilege,
  carry input, or status writes. Operands select the latest writer in program
  order; older and younger writer masks distinguish each side of the current
  EX operation. Older queued results drain through ordinary MEM/WB while
  independent younger ALU work appends. EX cannot commit status or issue a
  memory request ahead of older entries. A redirect discards younger results.
  This provides execution overlap; fetch and architectural retirement still
  sustain at most one instruction per cycle, and FP arithmetic is not pipelined.

`verilator/perf.py --tb PATH --out Scratch/perf/architecture --lockstep`
generates and checks repeatable warm-cache cases. The original CPU executable
was built before the architectural edits; both versions run the same programs
for 10,000 loop iterations. Cycle counts include setup and final cache drain.

| Case | Original cycles | Current architecture | Speedup at fixed clock |
|---|---:|---:|---:|
| Independent ALU operations | 170,226 | 170,219 | 1.00x |
| Dependent ALU operations | 170,226 | 170,219 | 1.00x |
| Independent L1 loads | 330,224 | 170,221 | 1.94x |
| Load followed by use | 330,223 | 250,213 | 1.32x |
| L1 store hits | 470,234 | 170,229 | 2.76x |
| Store/load pairs | 410,225 | 170,224 | 2.41x |
| Multiply/integer mix | 330,222 | 260,210 | 1.27x |
| FP multiply | 570,223 | 570,211 | 1.00x |
| FP/integer mix, one ALU per FP | 650,225 | 580,211 | 1.12x |
| FP/integer mix, four ALUs per FP | 890,237 | 610,213 | 1.46x |
| Divide/integer mix | 1,570,223 | 1,450,208 | 1.08x |
| Divide with younger overwrite/ALU chain | 1,570,223 | 1,450,208 | 1.08x |
| Divide with dependent next operands | 790,219 | 790,208 | 1.00x |
| Independent FP doubleword loads | 650,224 | 170,217 | 3.82x |
| FP doubleword stores | 950,259 | 240,247 | 3.96x |
| Calls and returns with predictor conflicts | 970,282 | 490,281 | 1.98x |

The scalar ALU already sustains approximately one instruction per cycle.
Long arithmetic and dependent operands still limit throughput. These cases
do not demonstrate a general 2x CPU improvement. The golden integer program
is 243,770 -> 237,063 cycles (1.85 -> 1.80 CPI, 1.03x); the golden FP program
is 973,140 -> 589,997 cycles (3.46 -> 2.10 CPI, 1.65x). These programs are
correctness workloads, not substitutes for Speedometer. First measure the
current implementation on the board and fit it at 70 MHz. If CPU performance
is short of 2x, use its measured mix to choose between wider fetch/issue,
earlier load availability, a shorter divider, and pipelined FP arithmetic.
Any wider issue still needs ordered completion and decoder-based dependencies.

Verification so far: the complete `run_core.py` suite passes, with 535,481
random instructions compared in lockstep, golden integer/FP programs, snoop
storms, exceptions, interrupts, MMU/cache/reservation/update-form checks,
clock-crossing tests and SDRAM-controller tests. The execute-unit vector
suite passes 11,444 defined integer, 25,598 FP, and 132 undefined-divide
vectors. New interrupt/walk tests include a faulting-page run with 997
cancelled walks and exactly 2,000 expected DSIs; removing the cancellation
guard in a temporary RTL copy makes that test fail. Simulation-only events
and exclusive cycle buckets are available with `core_tb --profile` or
`machine_tb --profile`; they add no FPGA counters. The bench samples request
data before the accepting edge, including the DMA trigger's value.
The new doubleword alias tests check both words at offsets 0, 4, 8, 24, 28
and 4092 under cache hits/misses, write-through, cache-inhibited, locked and
disabled caches, including heavy wait states and snoops. A temporary RAM
model that returns deliberately incorrect words/tags on read/write collisions
also passes the complete CPU suite, exercising forwarding independently of
the RAM's collision behavior. Interrupt tests fill and wrap the completion
FIFO; enabled FP exceptions discard speculative increments, which execute
exactly once after return. Checked overlap mixes require simultaneous FIFO
append/pop and test younger overwrites and dependent next operands.
The full-machine 6 MB memory-test boot passes with zero errors: 19,660,841
instructions in 26,938,856 cycles after Cuda releases reset (1.37 CPI).
Logs, checked programs, cycle/event results, and source hashes are retained
under `Scratch/perf/architecture/`; the original results are under
`Scratch/perf/baseline/`. Full-machine ROM lockstep now passes
3,000,000 instructions using the bundled 7300 ROM (`releases/boot0.rom`,
md5 `edcf3422d712f61f83c07efc2401cbb8`): 3,606,216 cycles after Cuda releases
reset, 6,635 device reads and 7,342 writes compared, identical state. Its
log is `Scratch/perf/architecture/verification/rom-lockstep.log`. Extending
the run to 60,000,000 instructions also passes (60,839,260 cycles, 34,413
device reads and 7,342 writes compared); the last PC is `FF808764`, still
in firmware polling. This run does not establish NanoKernel or disk-boot
coverage. Log: `verification/rom-lockstep60m.log` in the same archive. These
simulated CPU/memory/ROM tests do not replace disk boot and board DMA validation.

This Mac has Verilator 5.044. Full lint passes with the new `PROCASSINIT`
warning disabled for the existing machine register initializers; those
initializers were not changed. `MACPPC7300_CACHE` lets `run_core.py` place
its reference build under a writable test directory. The original pinned
dingusppc tree (`3f070249`) builds unmodified with `HIDE=0` on macOS.

Still required: Quartus area and full-machine timing reports at 70 MHz,
disk/DMA boot tests, the additional 7300 vector file, and
fixed-condition board Speedometer runs. Quartus Lite 17.0.2 is now available
on `misterubuntu`. Original full-machine seeds 1 and 2 in
`/home/alans/.cache/macppc7300/cpu70_20261009_a/` failed area as detailed below.
`compile.pid`, `compile.log`, and eventual `compile.exit` record its status.
A standalone CPU diagnosis from the same sources completed under
`cpu_diagnostic/` beside the two seeds, using `syn/check.py core --mhz 70
--paths 40 --detail 6`. Its result does not replace full-machine timing.
The supplied MiSTer runs SharpMZ2500 and has no MacPPC7300 test directory;
the user authorized taking it for temporary testing after timing passes,
and a Quadra disk from Downloads is prepared below. No clock or SDC
constraints, board core or Main have been changed. Earlier simulation jobs
have all exited successfully, and archived source hashes match the checkout.
The bundled `releases/boot0.rom` is the documented 7300 ROM and is available
for ROM lockstep. The additional 7300 vectors remain unavailable.

Timing work resumes with `syn/check.py core --mhz 70 --paths 40 --detail 6`
for CPU area/path diagnosis, followed by a full-machine Quartus fit. The
70 MHz period is 14.286 ns; require nonnegative setup and hold slack and no
unconstrained CPU paths at the required corners. Compare at least two fitter
seeds because the prior builds varied by about 2 ns. Check RAM inference,
ALMs, RAM blocks and routing headroom: cache write forwarding, wide response
selection and completion operand selection add logic that has not been
timed. The former grant-to-I-cache-address chain is removed structurally;
that does not establish timing closure. If the new worst path is the queue's
operand/ALU path or cache forwarding, cut that measured path and rerun both
timing and fixed-clock performance; extra latency can erase the CPI gain.

`syn/prepare_timing.py --out NEW_DIRECTORY --seed N` prepares an isolated
full-machine project and rejects CPU sources differing from the archived
verification hashes. It verifies the 70 MHz PLL selection, preserves the
main project's settings, and enables multicorner analysis in the copy.
Projects for seeds 1 and 2 are prepared under `Scratch/cpu70_seed1/` and
`Scratch/cpu70_seed2/`, with source manifests. A Tcl reference check confirms
all 103 project/QIP inputs exist; this is not Quartus elaboration or timing
validation. Run `quartus_sh --flow compile MacPPC7300` inside each copy on a
Quartus 17 machine, then inspect the fitter and all timing reports. Use a
new directory to regenerate a snapshot; the helper never overwrites one.

The synthesis review also moved the overlap block's stall/done signal
declarations ahead of their uses, following the Quartus compatibility rule.
Simulation's executed-uop event now includes completion-FIFO retirement;
cycles and architectural behavior are unchanged. The complete CPU suite,
full lint and checked performance cases pass after those corrections.

First Quartus results on `misterubuntu`: both full-machine seeds fail
fitting because the design exceeds the device's capacity. Seed 1 needs
45,475 ALMs / 4,576 LABs; the device has 41,910 ALMs / 4,191 LABs.
The standalone CPU fits at 24,512 ALMs but closes at only 43.85 MHz
(slow -40 C; 44.18 MHz at 100 C). Its worst setup slack is -8.349 ns.
The path runs from the D-cache tags through the response, memory-unit
descriptor selection and next-word adder, MMU translation, then ID/fetch
readiness. Reports are archived under `Scratch/perf/architecture/quartus/`.

The memory-unit timing cut presents the candidate first descriptor throughout
the first response phase and captures the fallback's next-word address at
acceptance. The response still gates acceptance; it no longer selects the
address ahead of translation. A two-word fallback waits until S_REQ0 before
accepting a new operation (one extra admission cycle only for that fallback).
The complete CPU suite, lint, and all 16 checked performance cases pass;
all 16 cycle counts are unchanged. New evidence is in `Scratch/perf/timing_cut/`.
The corrected standalone run, `cpu_diagnostic_b/` on the host, completes
at 25,749 ALMs, 52.35 MHz worst case (52.80 MHz at 100 C), and -4.655 ns
setup slack. The new critical family is ID decode -> forwarded integer
operands -> completion ALU -> completion FIFO. The memory-path cut helps,
but the speculative ALU currently combines decode, operand selection and
execution in one cycle. Log: `Scratch/perf/timing_cut/cpu-diagnostic-retiming-on.log`.
The corrected full-machine 6 MB memtest also passes with zero errors over
19,660,841 instructions; its log is in `timing_cut/verification/`.

The first full fit also shows the CPU's own combinational ALUTs rising from
11,765 after synthesis to 23,234 after physical synthesis. The next comparison
disables physical register retiming in isolated projects, using the verified
memory-unit cut: host `cpu_diagnostic_c/` and `seed_cut_no_retiming/`, under
`/home/alans/.cache/macppc7300/cpu70_20261009_a/`. The main QSF is untouched.
`syn/check.py --no-retiming` and `syn/prepare_timing.py --no-retiming
--verification ...` reproduce that comparison. The standalone comparison
finishes at 19,958 ALMs (5,791 fewer than retiming on), 50.33 MHz worst case
and -5.582 ns setup, with the same decode-to-completion-ALU family.
Log: `Scratch/perf/timing_cut/cpu-diagnostic-retiming-off.log`.
The full-machine comparison fails routing at 41,100 / 41,910 ALMs (98%).

The next measured-path cut registers the speculative ALU's operands and
control, reserving its FIFO entry at admission and writing its value one
cycle later. Pending results forward into the next registered operands;
retirement waits until the value is stored. This separates decode/operand
selection from execution while retaining dependent issue throughput. The
complete CPU suite, full lint and all 16 checked performance cases pass,
with all 16 cycle counts unchanged. Evidence and source hashes:
`Scratch/perf/completion_stage/`. Standalone `cpu_diagnostic_d/` completes
at 19,806 ALMs, 52.99 MHz worst case, -4.587 ns setup. Its new critical
path is WB forwarding -> effective-address adder -> MMU translation ->
pipeline readiness (469-load ID-to-EX enable). The full-machine
`seed_completion_stage_no_retiming/` finishes with routing failure at
41,200 ALMs / 44,514 registers (compile exit 3), retiming off.
A 300 M instruction ROM/disk lockstep with 16 MB RAM fails
with the ACK-owner fix below; the older 60 M checks did not reach the documented long
chime wait's completion. Timing and board acceptance remain unproved.
The attempted 120 MB lockstep reproduces the same divergence before and
after this cut at instruction 15,778 / FFF04360. The reference's flat RAM
map does not model Hammerhead bank placement during sizing. Keep the
documented 16 MB lockstep gate and test 120 MB sizing separately without
lockstep.
The 120 MB non-lockstep 3 M run passes, with final bank bases 0, 64, 96,
112 MB. The initial longer 16 MB run reached NanoKernel code but stopped
at 175,866,608 instructions / 68065E98 on a missing F8000020 read in the
bench's device queue. The machine bench now samples CPU accepted transfers
and DMA data before the clock edge changes ownership/buffer state. That
alone reproduces the same failure and is not its resolution.

A short held-ACK test exposes a bus ownership bug: after an I-cache
response, the still-high ACK could be routed to the D-cache, which returned
instruction word 38840001 in place of data 42 at instruction 7. The arbiter
now retains the acknowledged owner, delivers the response only while that
transaction is busy, and drains a high ACK before presenting another
request. The checked 8,009-instruction case passes after the fix, and three
suite cases cover I/D turnover, longer ACK levels and doublewords with
snoops. The complete CPU suite passes; all 16 full-length performance cycle
counts remain unchanged. Evidence is being archived in `Scratch/perf/ack_owner/`.
The rerun still fails at the same 175,866,608-instruction device comparison.
The original `0186181` CPU passes the matched 300 M check with identical
state and device accesses (469,681,030 cycles after Cuda reset), archived
as `ack_owner/verification/baseline-quadra300m.log`. Bounded current-core
trace shows the correct physical F8000020 request and motherboard ID
90000000 in r4, while the reference queue has no matching access. Further
bus/cache and queue diagnosis is required; no current-core long pass is claimed.
Older Quartus snapshots exclude the ACK fix.

The queue diagnostic identifies an unrelated 6806D940 line ahead of the
two correct motherboard reads. The machine bench now records the saved I/D
owner and sends only data transactions to the interpreter's data-device
queue. `progs.py specfetchrom` trains a conditional call with instruction
translation on, then takes its fallthrough with translation off: the stale
prediction reads a discarded instruction line at 68000400. The old bench
fails at instruction 40 because that I-owned line blocks a D-owned F8000020
load. The corrected bench passes all 100 instructions, counts the instruction
fetch separately and still compares the device read. Before/after evidence
is in `ack_owner/verification/`; the matched 300 M rerun passes with
435,386,869 post-Cuda cycles, identical state and device accesses, and
16 instruction fetches outside RAM/ROM counted separately. No disk blocks
were accessed; this is long ROM/NanoKernel coverage, not a booted OS or
Speedometer acceptance. Timer-driven paths differ between architectures,
so comparing these fixed instruction counts is not the performance gate.
This correction changes no RTL or CPU cycle counts.

An elastic memory-descriptor experiment is parked in
`Scratch/perf/memory_descriptor_experiment/`, outside the checkout. Its
architectural-result tests pass, but accepting into MEM before translation
makes interrupts wait for the older memory operation and removes pre-grant
data-walk cancellations. The existing cancellation coverage fails and was
not weakened. Revisit this measured timing cut after resolving boot, with
explicit interrupt-boundary semantics and meaningful verification.

A revised isolated candidate now accepts the memory descriptor before its
grant and takes an interrupt in MEM only while the first micro-op's first
bus access remains ungranted. It saves the operation's PC for retry, keeps
DAR/DSISR, suppresses the ungranted request and cancels/drains its MMU walk.
The full CPU suite, lint, all 16 unchanged full-length performance counts,
the 6 MB machine memtest and the speculative-fetch ROM pass. The stronger
late-fault test passes with 1,999 cancellations; removing the sticky
cancellation guard makes it fail (expected 2,000 DSI counts, got 1).
That case is added to the normal CPU suite. Evidence:
`Scratch/perf/elastic_irq/`. Its 300 M machine check passes with identical
state and device accesses (435,400,392 post-Cuda cycles; no disk blocks
accessed). Diagnostic E finishes at 19,183 ALMs / 19,986 registers,
55.87 MHz worst case, -3.612 ns setup. E was integrated before the later Z
RAM/translation improvements above. Its longest path is an 806-load BTB lookup index -> predicted
address -> MMU instruction segment read-ahead. A synchronous BTB experiment
passes the complete CPU suite, lint and all 16 unchanged full-length cycle
counts; diagnostic F finishes at 16,558 ALMs / 12,694 registers and
54.19 MHz worst case (-4.136 ns), versus E's 19,183 ALMs. The BTB path is
removed, but EA forwarding -> DBAT -> D-cache admission now limits timing.
The first synchronous FP-register read experiment passes CPU/lint/performance,
6 MB memtest and 300 M ROM/disk lockstep, but adds no inferred RAM and
finishes at 49.76 MHz / 16,138 ALMs. It is excluded from root. Explicit
three-copy FPR RAM with admission-independent fetch indices passes CPU,
lint, all 16 unchanged counts and the trained speculative-fetch regression;
diagnostic I confirms three 32x64 M10Ks and finishes at 14,744 ALMs,
58.39 MHz worst case (-2.778 ns at 70 MHz).
A registered one-page data-translation experiment also passes CPU/lint and
all checked cases (0-4 initial lookup cycles added, warm throughput retained).
Its 1,999-cancellation test passes; removing the sticky guard fails. The
combined explicit FPR/data-translation candidate passes CPU/lint, all checked
cases, memtest and 300 M ROM/disk lockstep. It finishes at 14,781 ALMs,
53.10 MHz (-4.548 ns).
The verified Z combination is integrated in root, with evidence under
`Scratch/perf/`. The older full-machine
memory cut, retiming off, fails routing at 41,100 / 41,910 ALMs (98%),
so reducing area and congestion is required alongside shorter logic paths.

The user authorized temporary tests on `10.0.2.14` after timing passes and
asked to try a Quadra disk while obtaining a PPC image. A copy extracted
from `~/Downloads/QuadSquad8.hda.zip` is staged as
`games/MacPPC7300/quadra_test81.hda`, with its System Folder 8.1 still blessed,
volume named Mac, and Speedometer 4.02 / Machine Records copied to the root
with both forks preserved through rb-cli. SCP succeeded; size 2,146,461,696
and MD5 `9645f183ddb14eac752bbb43c23b30e0` match the prepared local copy.
The original ZIP is untouched.
The bundled ROM is staged too. MiSTer Remote was initially stopped and is
started for testing; restore its stopped state afterward. The passing AT55
core is temporarily loaded. OS8.1 reaches startup/desktop background, but
Finder cannot find the Mac volume; no Speedometer scores or baseline boot
comparison have been obtained. A verified full recovery copy of the test
disk is retained. Clean shutdown has failed, so reset approval is pending
under the no-reload-while-mounted rule. The Main remains unchanged (md5
`2f21ff276ebf429ab91a8b4e33314623`); restore SharpMZ2500 after testing.
Benchmark launch tools now locate `mister.py`
beside themselves instead of using the older Windows path. Their dependencies
are in `/tmp/macppc7300-board-venv`. No 2x board measurement or timing closure
has been obtained.

After 70 MHz closure and the architectural performance target, try higher
frequencies supported by the generated PLL and close the entire machine at
each setting. `MacPPC7300.sv` currently maps CPU_MHZ only to 60, 70, 100
(since 2026-10-15, for the overclocked test builds) or a default 65 MHz PLL
frequency: changing the integer to 75 or 80 alone would
silently select 65 MHz while CPU_HZ says otherwise. Extend the PLL selection
and verify its actual output and CPU_HZ together, retain the 20/100 MHz
outputs and CDC constraints, then repeat boot/DMA/Speedometer checks.

**Linux's regression, found 2026-10-15.** From e30309d (the AT work) on,
Debian died at its first user process ("Non-recoverable exception at PC=0",
or an exception storm and a hang) at any clock; Mac OS was unaffected. An
exception trace on the board (a debug build recording every exception and
rfi into the DDR3 ring, frozen when Linux reaches `nonrecoverable_exception`)
showed a user DSI followed 164 cycles later by an ISI at 0300 itself, in real
mode, SRR1 "no page": the ISI's prologue then saw MSR[PR] clear and built
its frame on the user's stack. The cause was in the MMU's instruction side:
a walk that starts in the cycle of a redirect lost its cancel (I_IDLE to
I_WALK cleared `i_cancelled`; the data side already registered its cancel
there). The return stack makes such walks: the vectors' `bl` into
`transfer_to_handler` and `hash_page` are never returned from, so a user
`blr` can be predicted into page 0. Its fetch waits for the walker while a
load's walk runs; that walk ends in the DSI, the fetch's walk starts in the
same cycle, and the DSI's vector, in page 0 too, matched the walk's page and
took its "no page". Fixed: the walk starts cancelled when its first cycle
redirects. `progs.py vecwalktest` (in `run_core.py`, lockstep) builds the
case without Linux and fails on the old MMU at every wait state (an endless
exception storm, as on the board). Fixed on the way, older (M4): an
interrupt taken at an `sc` saved the address after it in SRR0, so the system
call was lost; found when the CPU bench began forcing the core's interrupts
into the reference in CPU runs too, as the machine bench did. Also seen on the way: every isync steps
the fold epoch, so Linux, with one on each exception return, sweeps the
whole BTB (1,024 cycles without predictions or learning) every sixteen
exceptions; a cost, not a fault, left for the speed work.

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
| EX | ALU, effective address, branch resolution, multiply/divide/FPU request; memory request acceptance |
| MEM | data cache/MMU response, load alignment |
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

The unit in two halves (2026-10-16, `fpu-pipe2`; the design and the
measurements in `docs/fpu_pipe_plan.md`, "Overlap 1 as built"): a front
(the request, the operands, the multiplier's two cycles or the add's
alignment, the divider, the estimate; `fstate`) and a back (add, count,
normalise, shift, round, done; `state`), the front handing over when the
back is idle or answering, so a second independent operation is computed
while the first is rounded. The protocol changed with it: a request is
withdrawn once taken (`req_ready` in the request cycle: the front is free
before the answer) except a move's or select's (`req_simple`, answered in
its own cycle while the back is idle); `resp_valid` is the back's answer,
in request order, for whoever asked; and the answer's FPSCR effects come
out on their own (`set_out`, `fr_out`, `fi_out`, `fprf_we_out`, `fprf_out`,
`cmp_out`) for a requester that commits later against the FPSCR of that
time, `fpscr_out` being only the effects applied to the request's
snapshot. Latencies as before; independent operations stream one per
3 cycles plus the request.

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
  Since 2026-10-16 a second, independent FP operation is admitted from ID
  into the completion queue behind EX's (the user's go-ahead for overlap 1
  of `docs/fpu_pipe_plan.md`, which has the design and the hazards: the
  issue register `fq_*`, the order FIFO `fo_*`, the queue's FP register
  bitmaps `cq_fpr_o/y`, the FPSCR and CR1 committed at the pop). EX's own
  FP answer is applied to the FPSCR of its commit cycle, as the pop's is.
  Since the same day an FP operation that writes a register also leaves EX
  into a queue entry in the cycle the unit takes it (`completion_push_ex`),
  so the instructions behind it run in EX while it computes, their leave,
  commit, redirect and memory request held by the order gate until its
  pop; the head entry's answer pops it in the answer's own cycle with the
  live result (`cq_live`), which keeps dependent chains at their latency
  (overlaps 2 and 3 of `docs/fpu_pipe_plan.md`, "as built": the early
  request of loads was built, measured at no gain and removed).
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
- The cycle accounting (2026-10-10): `DSPPC604_perf` behind the `PERF`
  parameter, 24 counters that class every cycle in which no operation leaves
  EX (MEM's second cycle, the data cache busy, a load's data, the multiplier,
  the divider, the FPU, the three cycles after a redirect, the fetch, ID) and
  count the events (branches, mispredictions, exceptions, refetches, loads,
  stores, the caches' memory transactions). The benches print it; a
  `PERF = 1`, `TRACE = 1` build writes it into the DDR3 trace for
  `syn\perf.py`. The 604's own numbers for the comparison are in
  `docs/MacPPC7300_plan.md`, "Where the cycles go".
- The 70 MHz timing pass of 2026-10-15 (`fpu-pipe2`, eleven commits a08ed6d
  to f5cd1dd, each one cut; the account in `docs/MacPPC7300_plan.md`'s
  decisions table, "timing"): every cut restructures inside a cycle and
  leaves the pipeline's behaviour alone (checked: `run_core.py` +0.011 %
  cycles over the suite, the 300 M lockstep identical, 312.13 M cycles).
  The method that found them: `syn\sta_cpupaths.tcl` on each fit, the
  pairs grouped by source and endpoint (`syn\cpupaths_families.py`), the
  worst of each family reported with `-detail full_path`
  (`syn\sta_pathsum.py` prints the cells and arrival times), and a cut
  aimed at the structure
  the path shows (a late enable on a wide register bank, a mux chain
  behind a compare, a register far from its readers), never at one fit's
  worst pair: the fitter moves a family by 0.5-1 ns between fits.
  Patterns that paid: a one-hot select registered with the operation in
  ID, and a flat AND-OR in EX (the SPR read, the unit's result); a
  register loaded while its stage is free, the late signal gating only
  the valid (IF2, the FPU's operands); a write landing a cycle after its
  commit where nothing can read it in between (mtsr's queue, now the
  BATs'); copies of far registers beside their compares, with the lag
  covered (the MMU's MSR copy from `msr_d`, the IBATs' by `i_stale`); a
  decision made from the decoder's operation with the sequencer's own
  cases known apart. What is left needs a cycle: the data cache's answer
  (`LATE_ANSWER`), the effective address registered before translation.

## Decisions needed along the way

| When | Question |
|---|---|
| ~~now~~ | ~~When the 7300 is running tests: build the extra floating-point vector set listed under M2?~~ Done 2026-10-06: the version-4 set ran on the 7300, with a supervisor-mode second stage; M2 and M4 have what it changed. |
| M6 or later | Trace and the IABR, cheap now that their SRR1 is measured: add them when a debugger or the ROM's own tests want them, or leave them out? |
| M3 | Is dingusppc built as a library acceptable as the lockstep reference, given it is the reference trusted most? |
| M5 | ~~Main memory on the SDRAM module or on the HPS DDR3?~~ Decided 2026-10-05: the SDRAM module, 64-128 MB fitted; the machine offers 6, 16, 24, 32, 64 or 128 MB (changed 2026-10-06 to 6, 16, 24, 48, 64 and 96 MB on the 128 MB module, the ROM taking its top 4 MB; 128 MB would need the ROM elsewhere and is left out). The line-fill bus therefore targets the SDRAM controller, which runs on its own clock, so M5 includes the clock crossing. |
| M6 | With measured speed in hand: stay with the 7600, or model a slower machine first? |
