# The AT speed session's log (2026-10-09/10)

Moved out of RESUME_speed.md when Dani's master (the cycle account, builds 47-53) was merged in. Chronological evidence of the isolated CPU candidates (AT and the CC-CM timing forks), their gates and fits.

# CPU goal: architecture at 70 MHz, then a higher clock

## Current handoff — 2026-10-10, approximately 12:24 PDT

**Read this snapshot first. Older entries below are chronological evidence,
and their live-job/board descriptions may be superseded here.** The active
goal is to implement the five CPU improvements, close full-machine timing at
**70 MHz**, and demonstrate **2x overall architecture performance at the same
clock versus commit `0186181`**. Only then pursue a higher clock. The goal
is **paused at the user's explicit request to write the handoff and stop**:
neither 70 MHz closure nor measured overall 2x is achieved.
No Speedometer scores or hardware before/after performance comparison exist.

**Resume state:** all owned full fits and local machine runs are terminal.
CL/CM reports are archived and both fail CPU setup; no timing fork is integrated.
Root still matches all19 retained-AT hashes (rechecked19:21UTC). The bounded
AT replay and original-baseline comparison both fail at the same required
string-boundary alignment exception, now decoded below. Do not restart any
of those completed jobs. The board still has baseline55/new Main/one SC0 disk,
with the Finder alert and no confirmed clean shutdown. Next: a focused strict
alignment/reference diagnostic, then measured BTB/control-path timing work
and an ordered FP-throughput prototype; obtain a working PPC image for scores.
No further experiments are authorized to continue during this pause. Resume
only when the user asks. Preserve the running board guest and its mounted
disk; the pause does not establish a clean Mac OS shutdown.

### CPU work retained and measured

The checkout retains verified **AT**, not the newer isolated timing forks.
All **19** CPU/auxiliary hashes were rechecked against
`Scratch/perf/gpr_ram/source-metadata.json` at this handoff. Retained work:

1. Fetch: four-entry instruction FIFO, bypass, and two registered response
   slots decouple fetch from downstream readiness.
2. Cache admission: independent RAM read admission and saved victim state
   reduce dependence on late grants/translation. Collision forwarding and
   cancellation guards preserve freshness and precise faults.
3. Memory: one elastic ordered MEM descriptor and cached-word throughput of
   one per cycle, including 64-bit FP pairs; precise exceptions, interrupts,
   stores and DMA coherence are covered by the existing regression suite.
4. Prediction: two-way 128-entry BTB and eight-entry return stack.
5. Overlap: eight-entry ordered ALU completion queue allows independent
   integer work behind long operations. The CPU still has **single issue,
   single retirement**, and an **unpipelined FPU**; wider issue is unfinished.

Normal/poison CPU suites, lint, real-604 vectors, cancellation/precise-IRQ
checks, trained discarded-fetch regression, 6 MB machine memtest and 300 M
ROM lockstep pass. The latter gives 481,830,131 post-Cuda cycles and matching
state/device accesses, but **zero completed host disk-block transfers**.
Supplying a disk is not evidence of OS boot or disk-DMA coverage.

Measured fixed-clock cycle ratios against `0186181` are workload-specific:

| Mix | Baseline cycles | AT cycles | Speedup |
| --- | ---: | ---: | ---: |
| Independent integer loads | 330,224 | 170,226 | 1.94x |
| Load then use | 330,223 | 250,221 | 1.32x |
| Stores | 470,234 | 170,236 | 2.76x |
| Store then load | 410,225 | 170,231 | 2.41x |
| FP loads | 650,224 | 170,226 | 3.82x |
| FP stores | 950,259 | 240,258 | 3.96x |
| Calls | 970,282 | 490,308 | 1.98x |
| FP multiply | 570,223 | 570,220 | approximately 1x |
| Independent ALU | 170,226 | 170,224 | approximately 1x |

These are not an overall benchmark score. The original baseline results are
`Scratch/perf/baseline/results.json`; `architecture/results.json` belongs to
an earlier improved candidate, not the original CPU. Retained AT results are
`Scratch/perf/gpr_ram/verification/performance-results.json`.
Remaining profiling evidence is
`Scratch/perf/wb_load_format/remaining-throughput-bottlenecks.json`. Long arithmetic
and load-use availability remain priorities. Exclusive stall buckets are
instantaneous classifications; do not infer causal stalls from their counts.

AT full-machine 70 MHz OFF/seed1: 34,701 ALMs (83%), CPU estimate **60.38 MHz**,
setup **-2.278 ns**; MEM100 min **+0.001 ns**, hold min **+0.087 ns**. All corners
matter. No unconstrained clocks, but stock external I/O is partly unconstrained.
AT55 and original baseline55 both pass all-corner setup/hold and are staged
for a matched hardware comparison. A passing 55 MHz build does not meet 70 MHz.

### Latest isolated timing experiments and jobs

All newer candidates stay outside the checkout; no failed-timing RBF deployed.

- **CC**, cache bus-address register: full 60.28 MHz; MEM100 all-corner
  min +0.121 ns. Worst CPU path was cache word selection/forwarding through
  MU formatting into WB. All functional gates passed.
- **CD**, per-way registered word selectors: rejected. 37,930 ALMs (91%),
  CPU 59.53 MHz, MEM100 cold -1.182 ns. All functional gates including 300 M
  passed, but logic growth and timing were worse. Reports archived.
- **CE**, move narrow-load formatting after WB register, direct CC fork:
  all normal/poison, 63 exact suite counts, 16 complete perf dictionaries,
  lint, negative corruption, specfetch, memtest and 300 M checks pass.
  Full build **finished**, compile/multicorner both 0; all 118 postbuild
  hashes match. **Reject integration**: 36,286 ALMs (87%), 38,903 registers,
  CPU hot -3.236/cold -3.445 ns (56.40 MHz), MEM cold -0.066 ns, hold min
  +0.074 ns. Worst EX operand-bank -> BTB-valid update. Reports/evidence:
  `Scratch/perf/wb_load_format/`. Remote runner2354580 is terminal.
- **CF**, earlier BY compact ID stage + CC bus-address + CE formatting:
  source `/tmp/macppc7300-wb-format-compact-id-src`; poison source
  `/tmp/macppc7300-wb-format-compact-id-poison-src`. CPU normal/poison suites,
  63 exact BY counts, 16 complete perf dictionaries, lint and machine build
  **pass**. Negative corruption, specfetch, memtest and 300 M runs are
  **NOT STARTED**. Machine binary is
  `/tmp/macppc7300-wb-format-compact-id-machine-test/machine_ref/machine_tb`.
  Full70 OFFseed1 is **complete**, runner **2367863** terminal on `misterubuntu`, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_wb_format_compact_id_no_retiming`.
  Compile/multicorner0,15m17; all118 postbuild hashes match. 36,589 ALMs(87%),
  38,319 registers/338RAM/48DSP; CPUhot-2.882/cold-2.401ns (58.25MHz),
  MEMcold-0.143ns,hold min+0.092ns. Worst WBraw result -> Dcache bus-address
  register. **Reject integration**; remaining machine gates were not run.
  Reports archived under `quartus/full_no_retiming/`. Evidence/status:
  `Scratch/perf/wb_format_compact_id/{source-metadata,quartus-job}.json`.
- **CG**, isolated CF fork, registers one ordered BTB training descriptor.
  Pending and landed forwarding cover valid/meta/target/LRU and replacement.
  An independent original predictor shadow compares predictions, lookup
  contents and replacement every cycle. Normal and full inherited poison
  suites PASS; all63 counts and all16 complete perf dictionaries EXACT CF.
  Corrupt registered-target negative rejected (return1). Self-modifying
  trained branch -> nonbranch golden/lockstep PASS normal/poison; all6
  training coverage bits seen across directed/perf logs. Lint/machine build,
  specfetch522 and6MB memtest27,333,623 PASS. 300M ROM lockstep **PASS**, exit0,
  481,830,131 post-Cuda cycles; all CE/CC progress/state/device counts exact.
  CF machine gate was not run, so this comparison is explicitly to CE/CC.
  Old bench leaves the CD probe unanswered and transfers zero disk blocks.
  Full70 OFFseed1 **COMPLETE**, remote runner **2384496** terminal, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_btb_training_no_retiming`.
  All118 transferred input hashes match; onlyCPU differs fromCF. Source
  `/tmp/macppc7300-btb-training-src`, poison `...-poison-src`, negative
  `...-negative-src`; evidence `Scratch/perf/btb_training/`.
  Compile/multicorner exit0,15m06; all118 postbuild hashes match. 36,025 ALMs
  (86%),38,525 registers/338RAM/48DSP. CPUhot -2.778/cold -2.387ns,
  estimate **58.61MHz**; MEMhot -0.255/cold -0.589ns; hold min +0.101ns.
  Worst WBraw result63 -> Dcache.r_wdata7. **Reject integration**: CPU and
  MEM setup fail. Reports and final JSON archived under this evidence tree.
  Initial poison patch-placement syntax failure was corrected before the
  passing rerun; failure log preserved. No owned remote full fits remain.
- **CH**, newest architecture experiment, direct retained-AT fork:
  `/tmp/macppc7300-fpu-product-round-src`; evidence
  `Scratch/perf/fpu_product_round/`. Only FPU RTL changes. Replace serial
  partial-product carry chains with two carry-save compressor levels plus
  one final adder. For a normal nonzero multiply without an addend, capture
  the original rounding inputs directly in S_MUL2 and bypass S_NORM/S_SHIFT,
  saving two cycles. Underflow, special-value and general rounding paths
  remain. This reduces latency; the FPU is still unpipelined.
  Independent original-product and original-rounding-input observers check
  equivalence. Both corruption negatives **PASS** (exit1 and exact fatal).
  Normal/full poison CPU suites, all16 lockstep/performance mixes, lint and
  machine build **PASS**. Real-604 vectors in operand modes0/1 each pass
  11,444 integer/25,598 FP plus132 undefined-divide vectors kept separate.
  Measured AT -> CH: FP multiply570,220 ->410,220 (1.39x), FP/integer
  mix580,220 ->420,220 (1.38x), FP/four-integer mix610,221 ->450,235
  (1.36x), FP stores240,258 ->220,258 (1.09x). Other12 complete performance
  dictionaries match AT. FP multiply FPU-wait480,000 ->320,000: two cycles
  saved for each of80,000 multiplies. Versus original0186181, FP/four-integer
  mix is1.98x; this is not overall2x proof. Comparisons/negatives/source19
  hashes are archived. Root19 AT hashes reverified unchanged.
  CH also copies the separately identified corrected disk-host C++ bench
  (below); this is not an RTL change. **Specfetch, memtest and300M machine
  gates: specfetch522,6MB memtest27,333,623 and300M ROM lockstep481,830,131
  PASS; all corrected-AT progress/state/device counts exact. Full70MHz
  OFF/seed1 **COMPLETE**, remote runner2403357 terminal,compile/multicorner0.**
  Path `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_fpu_product_round_no_retiming`;
  all118 inputs verified before/after transfer, onlyFPU differs fromAT.
  All118 postbuild hashes match,15m17. 34,658ALMs(83%),37,703regs/346RAM/
  48DSP. CPUhot -2.962/cold **-3.280ns**, estimate **56.93MHz**; MEM100 min
  +0.044ns,hold min +0.107ns. **Reject integration**:70MHz CPU setup fails.
  Reports archived in `fpu_product_round/quartus/full_no_retiming/`. Worst
  cache tag RAM port-B write-enable register -> cache hit/control -> EX
  memory/access/MSR qualification -> `ex_fc[61]` enable:15.007ns data delay,
  -2.478ns clock skew. This is the measured CH path, not an FPU-adder limit.
  Machine binary `/tmp/macppc7300-fpu-product-round-machine-test/machine_ref/machine_tb`.
  CPU, unit, negative-build, lint and machine-build sessions are terminal;
  do not restart them. All CH jobs are now terminal.
  Companion sources use `/tmp/macppc7300-fpu-product-round-poison-src`,
  `...-opreg-src`, `...-negative-src` and
  `/tmp/macppc7300-fpu-product-sum-negative-src`. Operand-mode1 uses a
  test-only `vector_dut.sv` instance parameter `.OPERAND_REG(1)`, not a
  changed FPU default. Durable candidate RTL/auxiliary copies, patch,
  metadata, vector/suite/perf and negative logs are in the evidence tree;
  corrected C++ is archived separately in `disk_host_probe/source/`.
- **CI**, isolated direct-CH timing fork, source
  `/tmp/macppc7300-cache-payload-capacity-src`, poison `...-poison-src`,
  negative `...-negative-src`; evidence `Scratch/perf/cache_payload_capacity/`.
  Cache write-data pair and wide flag capture whenever `can_take` capacity
  is available, rather than under late request qualification. Admission
  remains original `gnt`; descriptors hold during misses/uncached/snoops.
  Captures without a request affect only unused payload after completion.
  Independent original grant-qualified shadow checks every live payload;
  idle capture, cached-hit replacement and held descriptor coverage seen.
  Normal/full poisoned CPU suites PASS, all63 counts EXACT CH. All16 full
  performance dictionaries EXACT CH. Lint, machine build and corruption
  negative PASS (exit1 exactfatal). Initial normal compile rejected only
  simulation-counter PROCASSINIT declaration warning; existing compatibility
  flag rerun passes, failure log preserved. FPU RTL/vectors are inherited
  exactCH. Specfetch522 and6MB memtest27,333,623 PASS.300M ROM lockstep
  **PASS**,exit0,481,830,131 post-Cuda cycles; all CH/AT progress/state/device
  counts exact. Full70 OFF/seed1 **COMPLETE**,remote2408749 terminal, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_cache_payload_capacity_no_retiming`.
  All118 postbuild hashes verified; onlycache differs fromCH. Compile/
  multicorner0,15m36;35,265ALMs(84%),37,765regs/346RAM/48DSP. CPUhot
  **-2.639ns**/cold -2.453ns,estimate **59.09MHz**;MEMcold **-0.186ns**,
  hold min +0.081ns. **Reject integration**: CPU and MEM setup fail.
  Hot worst icache.r_addr30 -> machine.p_wd26 enable,16.315ns data delay/
  -0.529ns skew; cold worst mem_rd4 -> cr30,16.225ns/-0.433ns. The earlier
  CH FP-operand enable path is no longer leading. Reports archived in
  `cache_payload_capacity/quartus/full_no_retiming/`. Machine binary
  `/tmp/macppc7300-cache-payload-capacity-machine-test/machine_ref/machine_tb`.
  All CH/CI jobs are terminal. CJ/CK results follow below.
- **CJ**, direct CI fork, source `/tmp/macppc7300-peripheral-word-src`,
  poison `...-poison-src`, negative `...-negative-src`; evidence
  `Scratch/perf/peripheral_word/`. Only machine RTL changes; all19 CPU/aux
  hashes match CI. Corrected critical-path diagnosis: original `p_wd`
  already captures every cycle. The late address/admission path enters
  the eight-word selector before that register, rather than its enable.
  Capture the full256-bit peripheral payload/line flag and select the word
  using registered `p_k` after capture. Original request admission,
  address/byte enable, word order, latency and side effects remain exact.
  Independent original pre-register selector shadow compares every word;
  payload corruption negative rejects with exit1 and exactfatal.
  Lint/machine build, specfetch522,6MB memtest27,333,623 and **300M ROM
  lockstep PASS**, exit0,481,830,131 post-Cuda cycles. Progress/state/device
  counters EXACT CI/AT. All four peripheral coverage classes seen:
  word_read158872/word_write34489/line_read26760/line_write39576.
  CPU/perf/vector proofs inherited from identical CI CPU sources.
  Full70 OFF/seed1 **COMPLETE**, remote runner **2435377** terminal, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_peripheral_word_no_retiming`;
  started18:26:22UTC, compile finished18:42:45UTC (16m23), multicorner
  finished18:43:14UTC. Compile/multicorner0; all118 postbuild hashes match.
  34,597ALMs(83%),38,021regs/346RAM/48DSP; CPUhot -2.338/cold -2.029ns,
  estimate **60.16MHz**; MEMcold **-0.253ns**, hold min +0.106ns.
  **Reject integration**: CPU/MEMsetup fail. Hot path MEMwriter index ->
  operand forwarding -> ALU equality/trap/abort -> fetch `pc_f[21]`;
  cold Dcacheaddress/tag -> late ID admission -> `ex_fb[9]` enable.
  Reports archived in `peripheral_word/quartus/full_no_retiming/`.
  Machine binary `/tmp/macppc7300-peripheral-word-machine-test/machine_ref/machine_tb`.
  ROM session89798 is terminal exit0; do not restart it.
- **CK**, direct CJ fork, source `/tmp/macppc7300-cr-overwrite-port-src`,
  poison `...-poison-src`, negative `...-negative-src`; evidence
  `Scratch/perf/cr_overwrite_port/`. Only CPU.sv differs from CJ.
  Port verified old BV CR mechanism into the current CPU: registered
  overwrite keep/set masks, physical `cr_arch` update in MEM, and forwarding
  of the original EX-commit value. Neutral queued completions preserve CR;
  held overwrite descriptors are idempotent. Original next-value function,
  EX-commit shadow and MEM-snapshot shadow remain independent observers.
  Normal/full-poison CPU suites PASS, all63 instruction/cycle counts EXACT
  CI; all16 complete performance dictionaries EXACT CI. Lint/machine build,
  directed CR-setting ISA lockstep, missing-MEM-forward corruption negative,
  specfetch522 and6MB memtest27,333,623 PASS. Neutral/overwrite/held coverage
  seen across perf plus directed-positive logs; perf alone has no CR writes.
  FPU vectors inherited from exact CH FPU. **300M ROM lockstep PASS**,
  exec session **90655** terminal exit0,481,830,131 post-Cuda cycles,
  all progress/state/device counts EXACT CI/CJ/AT. CRcoverage:
  neutral229686318/overwrite88798488/held60351772; all4 peripheral classes
  also seen. Full70 OFF/seed1 **COMPLETE**, remote runner **2437841** terminal, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_cr_overwrite_port_no_retiming`;
  started18:30:15UTC,compile finished18:46:24UTC (16m09),multicorner0.
  All118 postbuild hashes match. 35,073ALMs(84%),37,996regs/346RAM/48DSP;
  CPUhot -3.729/cold -3.355ns,estimate **55.51MHz**; MEMcold **-0.077ns**,
  hold min +0.097ns. **Reject integration**: CPU/MEMsetup fail. Hot path
  WBwriter index -> operand forwarding/equality/trap -> MSR qualification ->
  MMU `d_cached_valid`; cold WBwriter -> operand/EA -> MMU cached-page enable.
  Reports archived in `cr_overwrite_port/quartus/full_no_retiming/`.
  Machine binary `/tmp/macppc7300-cr-overwrite-port-machine-test/machine_ref/machine_tb`.
- **CL**, direct CJ fork `/tmp/macppc7300-trap-compare-port-src`, poison
  `...-poison-src`, negative `...-negative-src`; evidence
  `Scratch/perf/trap_compare_port/`. OnlyCPU.sv changes. Compute trap
  predicates beside MEM/WB operand-source muxes, choose one predicate after
  forwarding selection. Signed/unsigned/equal conditions remain original;
  same-source pairs reduce to TO's equality bit. Original ALU b-a flags
  independently check the new predicate on every live unstalled trap.
  Normal/full inherited poison PASS, all63 counts EXACT CI. All16 complete
  performance case dictionaries EXACT CI. Lint/machine build/specfetch522/
  6MB memtest27,333,623 PASS. Directed warmed-code trap program PASS in
  lockstep333instr/557cycles, **all9 source combinations seen**. Taken TWI
  golden handler write PASS6instr/191cycles. Inverted-predicate negative
  rejects exit1/exactfatal. Initial asymmetric TW directed mismatch is a
  documented reference bug (TW swaps A/B); log preserved, final signed
  edge cases use correct TWI and EQ/same-value TW still cover forwarding.
  No reference/RTL semantics changed to accommodate it. Unit ALU/FPU RTL
  and both-mode vector proofs inherited exactCH. **300M ROM PASS**,
  session **22653** terminal exit0,481,830,131 post-Cuda cycles,
  all progress/state/device counts EXACT CJ/CI/AT. ROM trap coverage:
  source000000001/taken9919/nontaken0; directed tests supply the other8
  sources and nontaken coverage. Binary
  `/tmp/macppc7300-trap-compare-port-machine-test/machine_ref/machine_tb`.
  Full70 OFF/seed1 **COMPLETE** remote **2459974**, started18:57:35UTC, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_trap_compare_port_no_retiming`.
  Compile finished19:15:02UTC,17m27,compile/multicorner0; all118 postbuild
  hashes match. **35,044ALMs(84%),37,972regs/346RAM/48DSP**, CPUhot
  **-2.436ns**/cold -2.097ns,estimate **59.81MHz**; MEM100 min **+0.037ns**,
  all-clock hold min **+0.071ns**. **Reject integration**: CPU/all-clock
  setup fails. Hot path Cuda.cpu_reset -> BTB metadata RAM port-B address,
  16.398ns data/-0.243ns skew; cold Dcache tag write-enable -> fetch bypass,
  13.917ns/-2.385ns skew. Reports and `full-timing-summary.json` archived
  under `trap_compare_port/quartus/full_no_retiming/`. OnlyCPU differsCJ.
- **CM**, separate direct CJ fork `/tmp/macppc7300-fp-capture-port-src`,
  poison `...-poison-src`, negative `...-negative-src`; evidence
  `Scratch/perf/fp_capture_port/`. OnlyCPU.sv changes. Two banks for each
  of3 FP EX operands: capture unused bank every cycle, switch one-bit owner
  on original ID-to-EX admission, preserve WB forwarding to held owner.
  Adds192 payload bits; integer/HID0 banks remain original. Independent
  original qualified FP registers compare all owned operands every cycle.
  Normal/full inherited poison PASS, all63 counts EXACT CI. All16 complete
  performance dictionaries EXACT CI. Lint/machine build/specfetch522/6MB
  memtest27,333,623 PASS. Directed load->FP multiply->store lockstep PASS,
  golden2.25 result checked,11instr/209cycles, **held WB forwarding seen**.
  Admission/held-idle/held-WB coverage seen across perf plus directed log;
  perf alone has zero held-WB events. Missing heldFA WB capture negative
  rejects exit1/exactfatal on that same directed program. Initial corrupt
  unused-bank negative was only built, then replaced before running by
  this stronger held-WB control. ALU/FPU unit/vector proofs inherited exactCH.
  **300M ROM PASS** session **10355** terminal exit0,
  481,830,131 post-Cuda cycles, all progress/state/device counts EXACT
  CJ/CI/AT. ROM bank coverage admit335075272/heldidle61694915/heldWB0;
  directed test remains necessary for held-WB coverage. Binary
  `/tmp/macppc7300-fp-capture-port-machine-test/machine_ref/machine_tb`.
  Full70 OFF/seed1 **COMPLETE** remote **2459996**, started18:57:35UTC, path
  `/home/alans/.cache/macppc7300/cpu70_20261009_a/seed_fp_capture_port_no_retiming`.
  Compile finished19:15:01UTC,17m26,compile/multicorner0; all118 postbuild
  hashes match. **34,819ALMs(83%),38,061regs/346RAM/48DSP**, CPUhot
  **-2.480ns**/cold -2.416ns,estimate **59.65MHz**; MEM100 min **+0.142ns**,
  all-clock hold min **+0.102ns**. **Reject integration**: CPU/all-clock
  setup fails. Both slow corners limit EX system decode -> BTB target
  forwarding register (hot16.171ns data/-0.514ns skew). Reports and
  `full-timing-summary.json` archived in `fp_capture_port/quartus/full_no_retiming/`.
  CL/CM both remain isolated; no RBF downloaded/deployed or root RTL
  integration. Both runners are terminal/absent; no owned full fits remain.

### New simulation disk-host finding

The 120MB/no-L2 AT diagnostic (`board55/simulation120/`) reached300M and
captured an832x624 grey frame, but remained in target state28 (`T_PEEKW`).
Its owned PID34280 was deliberately terminated after discovering the host
only services `sd_rd/sd_wr & 3`. The target's initial CD capability probe
uses slot4/LBA7E120000 even with no CD image, and the shared block channel
cannot finish it. This explains why the older ROM-with-disk gates provide
**zero actual disk transfers**. It is a **bench gap**, not evidence that
the hardware Main has this failure.

Isolated retained-AT bench fork `/tmp/macppc7300-at-disk-host-src` modifies
only `verilator/core_main.cpp`: acknowledge that exact CD capability probe
with a zero-filled512-byte answer (no CD drive), keep its count separate
from actual disk reads/writes, and log the pending request. Diagnostic
`--disk-ignore-cd-probe` reproduces the old unanswered request. Bench binary
`/tmp/macppc7300-at-disk-host-machine-test/machine_ref/machine_tb` built.
Probe positive/control **both PASS10,000 ROM instructions in lockstep**,
345,312 post-Cuda cycles with identical state/device counts. Actual pending
request confirmed `sd_rd=10,sd_wr=00,LBA7E120000`; old control stays state28,
corrected completes exactly one absent-CD probe and returns state0 (`T_IDLE`).
Specfetch522 and6MB memtest27,333,623 **PASS**. Proof:
`Scratch/perf/disk_host_probe/probe-comparison.json` and source/hash/patch.
**Disk-host fix now integrated into root `verilator/core_main.cpp`**;
SHA256 `b3d146d781b529647bdba0feddeed27fe1251e93be28797640a72907f0cf33fa`
matches tested isolated C++ exactly. Root19 AT RTL/auxiliary hashes unchanged.
Root machine rebuild/specfetch and10k ROM positive/control lockstep PASS:
same state/cycles/device counts, positive oneCDprobe/target0, control
unanswered/target28. Evidence `disk_host_probe/root-validation/`.
Root binary `/tmp/macppc7300-root-disk-host-machine-test/machine_ref/machine_tb`.
Corrected-host300M/16MB lockstep is
**PASS**, exit0,481,830,131 post-Cuda cycles: all old-host progress, final
state and device counters exact; exactly one absent-CD probe, target0.
This16MB run still transfers zero actual disk blocks. Evidence
`Scratch/perf/disk_host_probe/rom-cycle-comparison.json`.
Corrected-host120MB/no-L2 diagnostic **COMPLETE**, owned PID **47387** absent,
metadata/command `Scratch/perf/disk_host_probe/simulation120/job.json`.
At max1B instructions it reports PASS,2,030,880,089 post-Cuda cycles,
PC68080364/MSRD076,**9,913 disk blocks read/10 written**,one absent-CD probe.
Writes remain in memory; source HDA is unchanged. Actual reads start at
473,500,694 instructions. Final inspected frame `frame-984895125.png` shows
Mac OS **Starting Up** with progress bar/background, not a Finder desktop.
No completed boot proof or lockstep in this actual120MB-bank diagnostic;
disk transfers alone do not prove CPU/DMA coherence. A longer120MB run may
be justified now that this run is terminal, but64MB lockstep below should
provide stronger CPU/DMA evidence first. Do not restart the completed1B run
unchanged and call it new coverage.
It uses70MHz simulated CPU vs55MHz board,120MB actual bank mapping without
the known flat-reference mismatch, slot0 only, original image opened
read-only with writes held in memory; captures frames and logs blocks.
It is not a hardware performance measurement. Old300M cycle baselines
remain old-bench evidence. No modified hardware deployment.
Root64MB/no-L2 ROM lockstep preflight **PASS**,exit0,3M instructions in
3,639,300 post-Cuda cycles,
`disk_host_probe/root-validation/ram64-preflight.log`, max3M instructions.
Rationale: single64MB bank may match flat reference while providing enough
RAM to verify actual disk-DMA/OS startup in a later long lockstep run.
No reference changes;120MB diagnostic remains no-lockstep. For any later
mismatch, retain evidence and check memory mapping/original baseline before
calling it a CPU regression. Long **64MB/no-L2 ROM lockstep FAILED** after
**867,478,809 instructions**,1,668,637,099 post-Cuda cycles. Owned PID59871
is absent (verified18:36UTC); do not restart unchanged. Root corrected-bench
binary, evidence `disk_host_probe/lockstep64/{job.json,run.log}`.
**5,346 actual disk blocks read/1 written** before terminal divergence:
core retired **FFF00600**, reference expected **6806A9BC**. State matched
through the preceding instruction; logged pre-divergence MSRD076/CR40100138,
LR680FE0A0. Final core MSR1040. This is an unresolved exception/CPU/reference
diagnostic, not a proven architecture regression or successful DMA gate.
Original-baseline64MB comparison and failure-focused trace are now terminal
below. Both CPUs reach the same string-boundary alignment failure.
Latest inspected `frame-802571915.png` shows Mac OS **Starting Up**, not
Finder; completed OS boot is unproved. Keep all frames and terminal log.
Original HDA opened read-only, writes held in memory, onlySC0; no reference
changes. These settings differ from16MB/L2 gates and120MB no-lockstep
diagnostic; don't compare their cycles as matched performance.

### Alignment-failure diagnosis — terminal, exact instruction identified

Evidence `Scratch/perf/disk_alignment/`. Root AT replay uses the **existing**
corrected-bench binary, no new RTL/bench/reference changes: exec session
**42030**, `at64-trace.log`, job `at64-trace-job.json`. Bounded retired trace
from867,478,700/count1000, dumps at867,478,808/809 (RAM files `at64-ram.*`),
full exception log `at64-exceptions.log`. Max870M instructions/3Bcycles,
same64MB/no-L2/onlySC0/original read-only HDA settings as failure. **FAILED**,
session42030 terminal exit1 at867,478,809instr/1,668,637,099 post-Cuda cycles,
same coreFFF00600/ref6806A9BC and5,346blocksR/1W as original AT failure.
Both64MB RAM dumps exist; do not rerun unchanged. All checks stayed active.

Original baseline fork `/tmp/macppc7300-baseline-disk-align-src`, all17 CPU
files exact git0186181; machine environment matches retainedroot. Corrected
diskhost C++ requires one compatibility edit: original has no `perf_events`
field, so that unused read is0; no --profile used and no checks altered.
Initial missing-field build failure preserved; corrected build PASS.
64MB preflight3M/3,668,690 post-Cuda cycles lockstep PASS. Long comparison
exec session **76907**, `baseline64-lockstep.log`, `baseline64-job.json`,
exception log `baseline64-exceptions.log`; max1B instructions/4Bcycles,
same64MB/no-L2/disk0/lockstep settings. **FAILED**, session76907 terminal
exit1 at847,494,845instr/1,643,965,655 post-Cuda cycles. **Same** coreFFF00600,
ref6806A9BC, pre-fault GPR/state values,5,346blocksR/1W,SRR0/SRR1/DAR/DSISR
as AT. This substantially weakens an architecture-change regression theory;
it is not a passing long disk-DMA gate. Binary
`/tmp/macppc7300-baseline-disk-align-machine-test/machine_ref/machine_tb`.
Do not restart either completed run. The instruction streams include real device
time/interrupts, so different progress-PC/cycles are not overall2x evidence.

Exact failing instruction: **7C60842A = lswx r3,0,r16** at virtual6806A9BC.
Unique preceding trace matches original ROM offset0036A9AC; the instruction
is at0036A9BC. Virtual PC is not a direct ROM-file offset. Immediately before
it, mtxer sets **XER=00000010**, so16 bytes are requested. R16=000F9FFA,
EA=000F9FFA, final byte000FA009: a **non-word-aligned string crossing4KB**.
604 manual section2.3.4.3.7,lines4949ff requires alignment exception for
this case. Both cores record SRR0=6806A9BC,SRR1=0000D076,DAR=000F9FFA,
DSISR=0000A062; AT's fault leaves GPRs unchanged. Dingus `ppc_lswx` simply
loops over memory reads without the whole-string boundary check; its MMU
allows32-bit unaligned cross-page reads bytewise. This points to a reference
limitation. The existing pre-PC divergence branch does not print ref_step's
error, so its exact failure mode still needs a focused reproduction.
Evidence and ROM hash are saved in `disk_alignment/reference-evidence.json`.

Next diagnostic must independently derive the required exception from the
opcode, EA/count and ISA, check precise state/SRR0/SRR1/DAR/DSISR, and also
reject **normal retirement when the instruction must fault**. Include
negative controls for missing/wrong exceptions and wrong saved state. No
alignment adapter is implemented yet; do not skip comparisons or copy the
core's exception state into the reference merely to make the run pass.

Read-only manual section4.5.6 (`/tmp/macppc604-review-manual.txt`:9173) and
existing APIselftest document reference missing alignment checks for lmw,
lwarx,stwcx.,lfs,stfs; real604 requires word alignment. Compiled existing
selftest against the **same** library without modifying reference code:
PASS **1,027,045 checks/10 known deviations**, includes lmw return0 versus
required0x600; no evidence PPC_TESTS suppression is active. Small core lmw
diagnostic also diverges, but the OS failure is the lswx case identified
above. Preserve failure
logs and reference-deviation evidence; do not weaken CPU comparisons.

### Board and disk state — do not discard the mounted guest

User authorized temporary testing on **10.0.2.14**, SSH alias `mister14`,
root/1. Quartus host is **misterubuntu**, not the board. User also explicitly
authorized installing bundled Main and saving/restarting the old binary.
New Main **261009**, MD5 `c641b24fec57a34de4b1b10b800a1639`, is installed;
old saved at `/media/fat/MiSTer.before_macppc7300_20261010_0837`, MD5
`2f21ff276ebf429ab91a8b4e33314623`. Keep the requested new Main.

Last audited Main PID **4333** runs baseline55 and
`/media/fat/_Unstable/Baseline55_Quadra81_clean.mgl`. **Exactly one SCSI disk**:
slot0 `/media/fat/games/MacPPC7300/quadra_clean_test81.hda`. Reverified MGL
(one index0 file), only saved `.s0`, Main's only open image (fd5), and no
slot1 saved mount. Main log confirms slot1 absent. No MacPPC default VHD;
other cores' `boot.vhd` files are unrelated. `boot0.rom` is the ROM. Backup
HDAs are unmounted. Audit changed no mounts. Evidence:
`Scratch/perf/board55/single-scsi-disk-audit.json` and `session.json`.

Fresh disk was size/MD5 checked before load and boots baseline into Mac OS
8.1 desktop, but Finder reports “The disk Mac cannot be used, because it
cannot be found.” No disk icon/Speedometer. Normal shutdown request repeats
that alert: **clean shutdown is NOT confirmed**. Do not reload the core or
restart Main while this mounted OS remains active. A screenshot timeout is
not proof of power-off (Main later produced the valid PNG). Latest screenshot
`Scratch/perf/board55/baseline-clean-power-dialog2.png`; desktop screenshot
`baseline-clean-after-click.png`. User is obtaining a proper PPC image;
Quadra image from Downloads is provisional. Original ZIP/prepared source
untouched; current guest-written image MD5 is unknown.

After a verified clean stop, eventually restore original
`_Computer/SharpMZ2500_20261008.rbf` and the previously stopped Remote service;
keep new Main. Remove only our two Remote startup lines after saving config.
Preserve verified disk backups; `.partial` is not a usable backup.

### Next steps, in priority order

1. All existing CL/CM ROM/full fits are terminal and archived. Both ROM
   gates pass exact parent counts; both full fits fail CPU setup despite
   passing MEM100 setup and all-clock hold. All118 postbuild hashes match.
   Read their `full-timing-summary.json` and detailed paths before selecting
   the next isolated experiment. Preserve all four corners, CPU/MEM and
   **all-clock setup/hold**; no failing RBF deployment. No owned jobs need
   polling/restarting. CH through CM remain isolated and rejected for70MHz.
2. Resolve the **lswx string-boundary reference diagnostic** above with a
   short independent ISA check and negative controls before another long
   machine run. ATtrace42030/baseline76907 are both terminal FAIL at the same
   fault; exactopcode/EA/count are now known. Do not rerun either unchanged
   or weaken lockstep. Do not claim successful disk-DMA coverage
   from blocks alone. The120MB no-lockstep run reachesStartingUp and9,913R/
   10W; root64 reachesStartingUp and5,346R/1W but fails CPU comparison.
   CD-probe bench fix remains root-integrated with positive/control proof.
3. Resolve the hardware missing-disk problem with the now-confirmed single
   SCSI disk. Inspect Mac-family Main/SCSI/driver behavior read-only first;
   try the proper PPC image when available. A 7.6.1-blessed **separate copy**
   is another diagnostic, not yet created. Do not alter original images or
   reload the mounted guest without a verified clean stop. Once boot works,
   run matched baseline55/AT55 Speedometer with identical settings/images.
4. CJ peripheral-word, CK CR-overwrite, CL parallel trap and CM FP capture
   banks are IMPLEMENTED; all full fits FAIL CPU setup. CL/CM are separate
   directCJ forks and now preserve MEM100 timing. Next inspect and shorten
   **BTB training/target-forwarding control and reset fanout** measured by
   CL/CM, along with the cache-to-fetch abort/admission path. Determine
   the logic causing each path before altering it; preserve reset and
   redirect behavior, and use original-predictor observers. A reset-origin
   reported path must not be declared false without evidence. A combination
   is untested; choose it only with measured justification/resources.
   CI's cold MEM100 path is stock `yc_out.chroma_LUT_BURST[0]` ->
   `yc_out.phase[2].v[9]`,-0.186ns. Do not modify stock sys or weaken its
   constraints; recheck its placement/timing after each actual CPU change.
   Preserve all-clock setup/hold.
   CH alone limits cache tag -> late EX admission -> FP-C register enable.
   CM implements just the3FP bank mechanism with original-operand shadow
   and missing-held-WB negative;300M passes but full timing fails. Older BW source
   `/tmp/macppc7300-capture-banks-src`, patch/evidence
   `Scratch/perf/capture_banks/capture-banks.patch` demonstrate the broader
   six-operand/HID0 mechanism on a different parent; that full fit failed at
   58.53MHz, so do not copy the entire old fork or assume timing improvement.
   CM adds192 payload bits versus the broader change.
   CG/CF instead limit WBraw -> Dcache; they are different forks. Preserve
   MEM100 setup and all-clock hold; no large remux without measured evidence.
5. For architecture, profile and improve long arithmetic overlap/throughput
   and load-use delays; evaluate pipelined FP/multiply or wider issue only
   with precise ordered exceptions/FPSCR handling and resource budgeting.
   Existing single-issue/unpipelined-FP limits remain. CH demonstrates useful
   two-cycle FP multiply latency savings but currently fails timing. Preserve
   those savings in a future measured implementation and profile FP
   add/normalize and load-use paths. Current detailed
   profile/next architecture evidence is `fpu_product_round/remaining-bottlenecks.json`.
   New controlled dependency/destination test evidence:
   `Scratch/perf/fp_issue_diagnostics/{results,next-architecture}.json` plus
   all6 lockstep/golden-memory logs. Each case performs80,000 multiplies
   with identical shared initialization/result2.0 and10,000 loops. Repeated
   f3 destination,8 independent destinations,and actual dependent f3 chain
   each take **570,219 cycles on AT**, **410,219 on CH**, with90,018 retired
   instructions. Changing dependencies/destinations alone gives no speedup
   in either CPU. Source confirms scalar EX/FPU serialization. This supports
   testing a pipelined FP product path plus ordered FP completion next,
   with explicit WAW/RAW/FPSCR/control/precise-fault/cancellation handling.
   That pipeline is **NOT IMPLEMENTED**; CL/CM are timing changes only.
   These synthetic results do not establish hardware or overall2x speedup.
   Wider issue still needs fetch/decode/register/retirement bandwidth;
   adding an ALU alone cannot achieve it. Preserve the five-area goal.
   Pure FP multiply still spends320,000 overlapping cycles waiting on FPU;
   FP/four-int retires410,017 instructions in450,235 cycles, nearing current
   single-issue capacity. Integer-divide mix has1,360,000 overlapping wait
   events. Event and exclusive-bucket counts are not causal attribution.
   A fully pipelined FPU
   or dual issue is not implemented and needs precise ordered completion,
   exceptions and FPSCR dependency handling rather than just extra ports.
6. Integrate only a correctness-verified measured improvement, rerun relevant
   gates and full four-corner timing. Prove 70 MHz plus matched overall 2x
   first; then increase CPU clock and close timing again. Do not weaken
   cancellation tests or claim closure from standalone Fmax/55 MHz results.

Use owned `/tmp` source forks/remote scratch; don't commit/push/release or
modify `sys`, reference, Quadra or Main source trees. User authorization
already covers board testing/new Main; don't ask again for the same actions.
SSH/SCP need sandbox escalation. Quartus 17.0.2 tools are at
`/home/alans/intelFPGA_lite/17.0/quartus/bin`. Native Verilator5.044 machine
lint/build requires inherited `-Wno-PROCASSINIT` compatibility. Existing
scripts, full logs, source hashes and detailed older experiments follow.

## Historical handoff entries — superseded by the current snapshot above

The following entries preserve earlier decisions and evidence. Their job,
board and implemented/not-implemented status is historical; use the current
snapshot above and the linked job JSON for resuming work.

Current work: **Quartus validation resumed** after the user supplied
`misterubuntu` and MiSTer `10.0.2.14`. SSH keys already provide access.
Quartus Lite 17.0.2 is at
`/home/alans/intelFPGA_lite/17.0/quartus/bin` on `misterubuntu`.
Remote scratch root: `/home/alans/.cache/macppc7300/cpu70_20261009_a/`.
Root CPU/video now match verified candidate AT: all 16 CPU and the video
source hashes match `Scratch/perf/gpr_ram/source-metadata.json`.
CPU/lint, 16 exact checked mixes, specfetch, 6 MB memtest and 300 M ROM/disk
lockstep pass (481,830,131 post-Cuda cycles, 25 I-device fetches). Unit vectors
in both operand modes pass for the inherited AJ FPU. Exact AT
collision-poisoned suite also passes, including cache/tag/data/TLB/BTB/target/FPR
RAMs. Strong cancelled-fault regression passes with 1,917 cancellations.
Root AT also passes the original asynchronous GPR shadow checker and all
five consumed read/write collision ports; removing sequence-C forwarding
fails the checker. Root CPU suite and lint were rerun after integration and pass.
Standalone AT reaches 61.16 MHz / 13,907 ALMs. Full-machine seed 1 with
retiming off fits at 34,701 ALMs (83%) but CPU setup fails at 60.38 MHz /
-2.278 ns. The 100 MHz memory domain passes all four corners with very
little margin: minimum setup +0.001 ns, minimum hold +0.087 ns. No
unconstrained clocks; external I/O remains partially unconstrained. Root
PLL/clocks/QSF/SDC are unchanged; the full result belongs to the prepared
retiming-off project. Newer AU–CG cuts remain isolated. Baseline55 is on the board;
70 MHz and matched
Speedometer 2x acceptance remain outstanding.

Earlier integrated candidate Z is archived in `Scratch/perf/fcmp_reg/`.
CPU/lint, real-604 unit vectors (operand register off/on), collision-poisoned
cache/tag/data/TLB suite, 16 checked mixes, 6 MB memtest, trained discarded
I-fetch regression and 300 M ROM/disk lockstep pass. Sticky walk cancellation
has positive coverage (1,999 cancellations) and a failing negative control.
Z uses 14,940 ALMs / 10,905 registers, 92 RAM blocks, reaching 58.97 MHz
(-2.672 ns at 70 MHz), retiming off. Retiming on uses 16,995 ALMs and reaches
59.31 MHz (-2.575 ns). Both fail 70 MHz. Full-machine seed 1 at
`seed_fcmp_reg_no_retiming_v2/` fits: 35,935 ALMs (86%), 38,531 registers,
337 RAM blocks, 49 DSP blocks. CPU timing fails at 55.17 MHz / -3.841 ns;
the 100 MHz memory domain fails at 88.83 MHz / -1.257 ns. All four corner
hold reports pass (minimum +0.090 ns); there are no unconstrained clocks.
Stock external I/O still has 26 input and 90 output ports unconstrained,
so this is not complete I/O signoff. The unused video-clock SDC filter warns;
the intermediate 700 MHz VCO is not its missing 20 MHz output clock.
The first scratch attempt omitted PLL inputs and stopped in synthesis;
v2 is prepared from the full root checkout. Reports are archived under
`Scratch/perf/fcmp_reg/quartus/full_no_retiming/`.
No bitstream has been deployed; 70 MHz and
matched Speedometer 2x acceptance remain outstanding.

The earlier elastic MEM/IRQ candidate E passed the following gates:
full CPU suite, lint, all 16 unchanged full-length performance counts,
6 MB machine memtest and 300 M ROM/disk lockstep pass. Standalone diagnostic
E finishes at 19,183 ALMs, 55.87 MHz worst case, -3.612 ns setup at 70 MHz.
The longest path is the asynchronous BTB lookup -> predicted address ->
MMU instruction segment read-ahead, with an 806-load BTB index signal.

Earlier isolated timing work: RAM predictor/FPRs, registered
data translation, cache forwarding/byte selection and pipelined RAS payload
writes are combined in `/tmp/macppc7300-ras-payload-src` (U). CPU/lint,
16 checked mixes, collision-poisoned CPU suite, trained discarded-I-fetch
regression and 6 MB memtest pass. Its 600 M ROM/disk lockstep passes with
identical architectural state and device accesses: 946,832,881 post-Cuda
cycles, 18 instruction fetches outside RAM/ROM. This is not OS boot or
Speedometer evidence. Diagnostic U (retiming off) reaches 57.33 MHz at
14,964 ALMs / 10,799 registers; V (retiming on, same source) reaches
59.32 MHz at 16,542 ALMs / 13,354 registers. Both fail 70 MHz setup.
`/tmp/macppc7300-pred-cr-src` (Y) additionally registers ICBI acknowledgement,
uses admission-independent data read-ahead with TLB collision freshness,
and registers predictor validity/one-hot branch CR selection. Full CPU,
lint and all 16 mixes pass with the registered-translation cycle counts.
Retiming-off/on Y diagnostics finish at 57.80 / 58.03 MHz, both failing 70.
`/tmp/macppc7300-fcmp-reg-src` (Z) additionally registers FP compare results
through the existing held-response state. Its full gates pass as noted above.
Compare gains one cycle; the zero-wait FP
vector program is 590,750 cycles versus Y's 590,423. Z was integrated before AF;
full-machine 70 MHz timing and matched Speedometer
2x performance remain outstanding. Other completed standalone results:
L 56.39 MHz, N 55.91, Q 58.62, T 57.41; all fail 70 MHz.

Earlier isolated candidates, now included in AF: AA `/tmp/macppc7300-dbattr-reg-src`
feeds data BAT/TLB lookup from registered `d_page_q` and requires freshness
even with DR off. CPU/lint and 16 mixes pass (1-3 extra total cycles);
14,936 ALMs / 10,736 registers, 58.34 MHz, -2.855 ns (fails 70).
AB `/tmp/macppc7300-id-predecode-src` captures completion eligibility and GPR
indices with ID and separates completion's ID-leave from sequencer-last.
CPU/lint, all 16 exact AA counts and 300 M machine lockstep pass.
Timing is 15,679 ALMs / 10,949 registers, worst 57.64 MHz at -40C
(100C report slack -2.772 ns). The new critical path is I-cache response
through early decode into those registers.
AC `/tmp/macppc7300-fetch-stage-src` adds two registered FIFO output slots,
so FIFO RAM control uses registered spare capacity rather than ID readiness.
CPU/lint and all 16 checked mixes pass (2-25 additional total cycles over
10,000 loops). Integer vectors improve 237,063 -> 236,102 cycles; FP vectors
591,164 -> 582,919 versus AB. AD `/tmp/macppc7300-cr-forward-src` captures the
one-hot CR selector into EX and reads committed CR there, removing selection
from the preceding CR writer's path. CPU/lint and exact AC mix counts pass;
the full collision-poisoned suite also passes, now including BTB metadata,
targets and all three FPR RAMs alongside cache data/tags and I/D TLBs.
AD's trained specfetch and 6 MB memtest pass (27,333,623 post-Cuda cycles,
zero errors). Its 300 M lockstep passes (481,830,131 post-Cuda cycles,
25 I-device fetches). AC reaches 56.93 MHz / 15,628 ALMs; AD reaches
59.14 MHz / 15,608 ALMs. Both fail 70 MHz. AB's 300 M lockstep also passes.
Evidence and complete CPU snapshots: `Scratch/perf/{dbattr_reg,id_predecode,
fetch_stage,cr_forward}/`. Do not claim 70 MHz or 2x from these checks.

AE `/tmp/macppc7300-fcmp-output-src` adds a measured-path correction to AD:
while compare response is invalid, the FPU exposes unchanged incoming
FPSCR/CR rather than the combinational compare update. S_DONE still exposes
the registered response. This removes a real FP-classification -> exception
-> redirect -> predictor-valid path without changing any valid result or
latency. CPU/lint, real-604 unit vectors (operand register off/on), exact AD
16-mix counts, full cache/tag/data/TLB/BTB/target/FPR collision poisoning,
trained specfetch and 6 MB memtest pass. Strong late-fault test passes with
1,917 cancellations; sticky-guard removal fails (expected 2,000 DSIs, got 1).
300 M machine lockstep passes (481,830,131 post-Cuda cycles, 25 I-device
fetches). Retiming off reaches 59.95 MHz / 15,627 ALMs; on reaches only
56.44 MHz / 17,370 ALMs. Both fail 70 MHz. Complete source and logs:
`Scratch/perf/fcmp_output/`. These cuts are included in integrated AF.

AF `/tmp/macppc7300-btb-valid-parallel-src` reads current/predicted BTB valid
rows in parallel before selecting with late fetch control. Its machine video
line-width multiply is replaced by the equivalent power-of-two shift:
1,048,576 delta/DAC cases confirm identical wrapped width and line word count.
CPU/lint, all 16 exact AE mix counts, trained discarded-I-fetch regression
and 6 MB memtest pass. Standalone diagnostic `cpu_diagnostic_af/` reaches
61.88 MHz / 15,599 ALMs / 11,157 registers, still failing 70 MHz.
The 300 M machine lockstep passes (481,830,131 post-Cuda cycles, 25 I-device
fetches). Full-machine seed 1 `seed_btb_valid_parallel_no_retiming/` fits at
36,631 ALMs (87%), 39,006 registers, 341 RAM blocks and 48 DSP blocks.
CPU setup still fails: 57.97 MHz / -2.965 ns. The video shift closes the
100 MHz memory domain at every corner: minimum setup +0.268 ns, worst
Fmax 102.75 MHz. All-corner hold passes (minimum +0.083 ns). No unconstrained
clocks; stock external I/O remains partially unconstrained. CPU critical path
is now WB LFS normalization -> FP magnitude comparison -> fin_cmp_cr.
Full path/corner reports are archived. CPU/video AF is integrated with exact
archived hashes; root PLL, clocks and SDC are unchanged.
Evidence and full source snapshot: `Scratch/perf/btb_valid_parallel/`.

AG `/tmp/macppc7300-single-store-src` is an isolated AF-derived experiment:
forward an LFS single word directly to STFS instead of single-to-double-to-
single conversion. Doubleword stores retain full converted forwarding;
MEM forwarding retains priority. CPU/lint, exact AF 16-mix counts and full
collision-poisoned suite pass. All 48 cached/uncached load/store edge cases
execute the bypass and pass measured-604 expectations, including signaling
NaNs. The software reference quiets SNaNs: the unchanged parent fails at
the identical byte; compatible cases pass exact reference lockstep. Specfetch
and 6 MB memtest pass. Its 300 M lockstep passes (481,830,131 post-Cuda cycles,
25 I-device fetches). Diagnostic AG reaches
58.70 MHz / 15,585 ALMs (-2.750 ns), worse than AF; the worst path shifts to
D-cache tag hit -> memory response -> EX commit enables. Evidence:
`Scratch/perf/single_store/`.

AH `/tmp/macppc7300-ex-capacity-src` uses descriptor capacity for ID-to-EX
admission, independently of late abort/fault decisions; redirect annuls
admitted work. A simulation invariant forbids overwriting live unflushed EX.
CPU/lint and exact AG mixes pass. Diagnostic AH reaches 60.68 MHz / 15,595
ALMs (-2.193 ns), limited by WB LFS -> FP compare. AI
`/tmp/macppc7300-ex-leave-src` simplifies EX leave to mu_ready: its outer
guards already qualify mu_valid, so mu_accept repeated those guards.
CPU/lint and exact AG mixes pass. Complete snapshots and logs:
`Scratch/perf/{ex_capacity,ex_leave}/`.

AJ `/tmp/macppc7300-fcmp-operands-src` compares only captured request
operands/classes/control/FPSCR before its registered response, separating
LFS normalization from magnitude comparison. OPERAND_REG=0 compare gains
one cycle; mode 1 and arithmetic latencies are unchanged. Full CPU suite
and real-604 unit vectors in both operand modes pass. Integer vectors remain
236,102 cycles; FP vectors are 583,396 versus 582,919 (477 additional cycles).
Lint, all 16 exact AF mixes, full collision-poisoned suite, specfetch and
6 MB memtest pass. All 576 cached/uncached LFS-to-CMPU/CMPO cases pass the
measured-604 model (both operand positions, VE off/on, denormals and NaNs).
The 300 M machine lockstep passes (481,830,131 post-Cuda cycles, 25 I-device
fetches). Full-machine seed 1 `seed_fcmp_operands_no_retiming/` fits at 36,315
ALMs but CPU setup fails: 57.61 MHz / -3.074 ns. Memory 100 MHz has no
reported violations (cold setup rounded +0.000 ns); minimum hold +0.096 ns.
All inputs are immutable and hashed; full corner reports are archived.
Standalone `cpu_diagnostic_aj/` finishes at 60.31 MHz / 15,659 ALMs /
11,122 registers (-2.294 ns). The critical path moves to CR -> branch
resolution -> redirect -> completion admission -> ID/fetch readiness.
This was tested before AT integration. Evidence: `Scratch/perf/fcmp_operands/`.

AK `/tmp/macppc7300-completion-gate-src` replaces the completion queue's
`~redir` admission guard with `~mem_fault`. Admission already requires
`~ex_done`, so EX cannot leave/redirect then. The older MEM fault is the only
possible redirect; a simulation assertion forbids pushing during redirect.
This removes branch resolution from ID readiness without changing cycles.
Full CPU suite, lint and all 16 exact AJ mix counts pass with both admission
invariants active. Standalone `cpu_diagnostic_ak/` reaches 62.91 MHz /
15,649 ALMs / 11,165 registers (-1.609 ns). This was tested before AT integration.
Exact source/logs: `Scratch/perf/completion_gate/`.

AL (admission-capacity) uses ordinary EX completion and MEM capacity for
admission, leaving interrupt/exception qualification to existing commit and
redirect rules. AM (btb-collision) reuses the current/predicted row equality
for RAM collision forwarding, before late fetch control. AN (mem-payload)
captures completed EX payload using ordinary capacity; valid commitment
is unchanged. Assertions prohibit overwriting unfinished MEM, competing
with queued completion, or committing without captured payload.
AN CPU/lint, exact AJ mixes, full RAM collision poisoning, focused single
store/compare edge cases, specfetch and 6 MB memtest pass. The 300 M lockstep
passes (481,830,131 post-Cuda cycles, 25 I-device fetches). Standalone AN
reaches 59.54 MHz / 15,608 ALMs. Full seed 1 fits at 36,186 ALMs (86%),
39,182 registers, 341 RAM / 48 DSP blocks but CPU setup worsens to 55.98 MHz
(-3.580 ns cold). Memory 100 MHz passes (minimum +0.262 ns), hold minimum
+0.105 ns. Worst path is cache tag -> hit -> response -> EX operand capture.
Source/evidence: `Scratch/perf/{admission_capacity,btb_collision,mem_payload}/`.

AO (fpscr-forward) computes FPSCR candidates from MEM/WB/held FP operands
in parallel before selecting by forwarding tags. A constant-bit helper
provides the WB single-load low word without full normalization. No latency
change. CPU/lint, exact AN mixes and full collision-poisoned suite pass.
480 cached/uncached LFS-to-MTFSF cases pass measured-604 expectations;
poisoned directed cases additionally compare every helper bit with the full
single-to-double conversion and selected FPSCR with the original updater.
Standalone AO reaches 60.76 MHz / 15,737 ALMs / 11,255 registers (-2.173 ns).
Trained specfetch, 6 MB memtest and 300 M lockstep pass (481,830,131
post-Cuda cycles, 25 I-device fetches).
Source/evidence: `Scratch/perf/fpscr_forward/`.
AP (tag-compare) compares RAM, pending and colliding cache tags in parallel,
then applies the same pending > colliding > RAM priority to hit bits. This
moves the wide forwarding mux after tag comparison, without adding cycles.
CPU/lint, all 16 exact AO mixes, full collision poisoning and 480 directed
FPSCR checks pass. Poisoned cache tests also assert each hit bit equals the
original fully forwarded-tag comparison. Specfetch and 6 MB memtest pass;
300 M lockstep passes (481,830,131 post-Cuda cycles, 25 I-device fetches).
Quartus 17 rejected an inline genvar declaration;
corrected module-scope genvar source is verified. Cache hit is exposed for
the existing Verilator machine debug print. Diagnostic `cpu_diagnostic_ap_v2`
reaches 61.85 MHz / 15,429 ALMs / 11,203 registers (-1.882 ns). The prior cache
path is off the worst-path position; the new worst is WB LFS normalization
through FP store data to cache r_wdata. Full-machine seed 1
`seed_tag_compare_no_retiming/` finishes successfully but fails timing:
36,653 ALMs (87%), 38,997 registers, 341 RAM / 48 DSP blocks; CPU 57.95 MHz
(-2.971 ns cold), memory 96.7 MHz (-0.341 ns cold against 100 MHz). Hold
passes all corners (minimum +0.100 ns). CPU worst is cache tag -> EX C
capture; memory worst is stock yc_out chroma LUT -> phase. All corner paths
and clock/unconstrained reports are archived. No integration/deployment.
Source/evidence: `Scratch/perf/tag_compare/`.

AQ (cache-reply) is a separate AP descendant: register cache-control replies
(one extra cycle), retaining same-cycle cached word and memory-ACK uncached
word replies. Word grant removes redundant uncached qualifications under a
hit. CPU/lint, exact AP mixes and full collision poisoning pass, including
word-reply equality and response non-overlap assertions. Standalone timing
worsens to 60.65 MHz / 15,477 ALMs / 11,182 registers. No full-machine build
or integration planned for this cut while it lacks timing improvement.
Source/evidence: `Scratch/perf/cache_reply/`.

AR (single-normalize) branches from AP, excluding AQ. Replace WB LFS
conversion's encoded leading-zero count, exponent subtraction and variable
shift with highest-bit one-hot selection of fixed shifts/exponents. All
results and cycles are preserved. 34,566,116 equivalence checks pass, including
all signed zero/subnormal and all Inf/NaN encodings, normal-exponent edge
patterns and one million deterministic random words. CPU/lint, exact AP
mixes, collision poisoning and directed stores/compares/FPSCR updates pass.
No FPU arithmetic module changed; the function is used only by CPU WB LFS.
Machine specfetch, 6 MB memtest and 300 M lockstep pass (481,830,131
post-Cuda cycles, 25 I-device fetches). Standalone timing
`cpu_diagnostic_ar/` finishes at 60.32 MHz / 15,597 ALMs / 11,162 registers
(-2.197 ns cold). The normalization path is off the worst-path position, but
cache reply -> generic EX commit -> BAT write enable becomes critical.
Full-machine build/integration is deferred; source/evidence:
`Scratch/perf/single_normalize/`.

AS (system-write) branches from AR: MTSR/MTSPR register-bank writes use
ordinary MEM capacity and existing abort/fault/order/stall guards, avoiding
generic memory-descriptor and long-unit qualification. Simulation asserts
exact equality with original architectural EX commit and rejects a memory
descriptor for these operations. No latency changes. Full CPU suite, lint and all 16 exact AR mix counts pass.
Source is `/tmp/macppc7300-system-write-src`. Standalone AS reaches 60.53 MHz
/ 15,715 ALMs / 11,100 registers (-2.235 ns). BAT enable path is off the
worst-path position; EX register forwarding -> ALU -> XER now leads. Full
collision-poisoned suite passes. Machine specfetch, 6 MB memtest and 300 M lockstep pass (481,830,131
post-Cuda cycles, 25 I-device fetches). No full-machine timing build yet. Source/evidence: `Scratch/perf/system_write/`.

AT (gpr-ram) replaces the 33-word integer register file with five synchronous
M10K copies: fetched A/B/C and speculative next-micro-op A/C. The sequencer
exposes next RA/RC independently of take; RB never changes across a macro.
Late admission selects registered samples, with held-operand capture and
explicit WB/collision forwarding. The completion queue reuses sampled A/B.
CPU/lint and all 16 exact AS mixes pass without additional cycles. Full RAM
collision poisoning plus shadow original asynchronous RF checks pass,
including scratch register 32 and sequencer steps. Directed coverage run
proves all five collision samples are consumed: 274/61/6 fetched A/B/C and
49/5 sequence A/C in the translated random case (70% waits, seed 19).
Removing sequence-C collision forwarding fails the shadow RF assertion
(`GPR RAM C differs from architectural register read`, exit 1), confirming
positive collision coverage. Standalone retiming off uses 13,907 ALMs /
9,925 registers / 101 RAM blocks, 61.16 MHz (-2.064 ns): 1,808 ALMs and
1,175 registers saved versus AS without added cycles. Retiming-on diagnostic
uses 15,399 ALMs / 12,237 registers and worsens timing to 57.86 MHz.
Specfetch, 6 MB memtest and
300 M lockstep pass (481,830,131 post-Cuda cycles, 25 I-device fetches).
Full-machine seed 1 `seed_gpr_ram_no_retiming/` fits at 34,701 ALMs (83%),
37,724 registers, 346 RAM blocks and 48 DSP blocks. CPU setup fails at
60.38 MHz / -2.278 ns; MEM100 passes with minimum setup +0.001 ns.
All-corner hold passes (+0.087 ns minimum); no unconstrained clocks,
stock external I/O remains partially unconstrained. Compared with AF this
saves 1,930 ALMs and improves full CPU Fmax by 2.41 MHz. AT is now integrated;
all 17 CPU/video hashes match, and the root suite/lint rerun passes.
Source: `/tmp/macppc7300-gpr-ram-src`; evidence and immutable hashes:
`Scratch/perf/gpr_ram/`.

AU (prediction-compare) compares target and sequential PCs with the captured
EX prediction before selecting the mismatch by late CR/CTR branch outcome.
RFI already redirects unconditionally; target PC payload is unchanged. An
assertion requires exact original next-PC mismatch for every valid non-RFI
EX. CPU/lint, exact AT mixes and full collision-poisoned suite pass.
Standalone `cpu_diagnostic_au/` reaches 61.43 MHz / 14,043 ALMs /
9,984 registers (-1.992 ns). Machine specfetch and memtest pass;
300 M lockstep passes (481,830,131 post-Cuda cycles, 25 I-device fetches).
Source/evidence:
`Scratch/perf/prediction_compare/`.

AV (pc-redirect) branches from AU: retain accepted-prediction PC separately
from two alternating redirect payload banks. The inactive bank captures
every cycle using a registered selector. Late redirect changes only one-bit
read/write/active flags; redirect wins over a simultaneous wrong-path fetch.
The selected PC changes at the same edge and holds until a target fetch is
accepted. An assertion compares every cycle with original fetch-PC state.
CPU/lint, all 16 exact AU mixes and full collision poisoning pass.
Standalone timing reaches 62.42 MHz / 14,093 ALMs / 10,016 registers
(-1.734 ns). The worst path is ID decode -> GPR forwarding -> EX operand,
followed by MEM forwarding -> ALU -> CR. Machine specfetch/memtest pass;
300 M lockstep passes (481,830,131 post-Cuda cycles, 25 I-device fetches).
Source `/tmp/macppc7300-pc-redirect-src`; immutable snapshot:
`Scratch/perf/pc_redirect/`. Full-machine seed 1 fits at 34,792 ALMs (83%),
37,796 registers, 346 RAM blocks and 48 DSP blocks. CPU setup fails at
58.69 MHz / -2.753 ns; MEM100 fails cold at 99.97 MHz / -0.003 ns.
All-corner hold passes (+0.088 ns); no unconstrained clocks, stock external
I/O partially unconstrained. Worst CPU path is EX RB forwarding -> cache
CI/WT capture; worst MEM path is stock scaler RAM -> pixel register.
Full reports are archived. This is worse than integrated AT and stays isolated.



AW (word-reply) branches from AU, excluding AV: apply the earlier AQ
registered cache-control response and fast word reply cut to the smaller
RAM-based CPU. CPU/lint and all 16 exact AU mixes pass. Ordinary word-hit
and uncached ACK replies retain their cycles; cache-control replies gain
one cycle. Full collision poisoning, fast-word equality and reply no-overlap
assertions pass. Standalone uses 14,057 ALMs / 10,004 registers / 101 RAM
blocks and reaches 61.87 MHz (-1.876 ns), still failing 70. Machine specfetch,
memtest and 300 M lockstep pass (481,872,861 post-Cuda cycles). Source/evidence:
`Scratch/perf/word_reply/`.

AX (gpr-index) branches from AV: live WB forwarding compares indices
captured with fetched/next-sequencer GPR samples rather than decoded ID
indices. Assertions check each consumed index against the sequencer.
No cycles added. CPU/lint, all 16 exact AV mixes and full collision
poisoning with shadow original RF pass. Standalone timing
`cpu_diagnostic_ax/` reaches 62.66 MHz / 14,134 ALMs / 9,998 registers /
101 RAM blocks (-1.673 ns). ID decode is off the worst-path position;
cache hit -> EX operand enables and MEM forwarding -> ALU -> CR lead.
Specfetch, memtest and 300 M lockstep pass (481,830,131 post-Cuda cycles).
Source/evidence: `Scratch/perf/gpr_index/`.

AY (shift-mask) branches from AX: SLW/SRW/SRAW mask bits compare shift
counts with constant bit boundaries, avoiding variable boundary arithmetic
and shifts in mask_gen. General rotate masks are unchanged. CPU/lint and
all 16 exact AX mixes pass. 192,512 full RTL ALU equivalence cases against
the unchanged AX ALU pass, covering every shift count, register/immediate
selection, input basis/inverse, wrapping rotate mask and rotate amount.
Standalone timing `cpu_diagnostic_ay/` reaches 62.09 MHz / 13,913 ALMs /
10,056 registers / 101 RAM blocks (-1.821 ns), worse than AX's 62.66 MHz.
Full collision suite passes. Machine specfetch and memtest pass;
300 M lockstep passes (481,830,131 post-Cuda cycles).
Source/evidence: `Scratch/perf/shift_mask/`.

AZ (ex-operand-banks) branches from AY: two alternating EX operand banks
capture ID using registered bank selectors. Admission only switches read/
write selectors; WB refreshes the active bank. Late cache replies leave
the wide operand load-enable path. An assertion checks all six operands
against the exact original EX capture/WB-refresh state whenever EX is valid,
and checks that banks differ. CPU/lint and all 16 exact AY mixes pass.
Full collision suite passes. Diagnostic `cpu_diagnostic_az/` reaches
62.73 MHz / 14,502 ALMs / 10,340 registers / 101 RAM blocks (-1.656 ns).
The wide EX operand-enable path is off the worst-path position; MEM
forwarding -> trap equality -> generic XER enable and MMU fault DAR enable
lead. Machine specfetch, memtest and 300 M lockstep pass (481,828,716
post-Cuda cycles). Invalid EX operand refresh can alter speculative
translation previews; all valid EX operands and fixed performance mixes
remain equal to the parent.
Source/evidence: `Scratch/perf/ex_operand_banks/`.

BA (status-capacity) branches from AZ: status next-values capture using
ordinary MEM capacity/order/ex_done with pre-exceptions excluded, without
late memory-descriptor/trap/alignment qualification. Precise exception
writes retain priority. An assertion requires each extra capture to leave
all six status registers unchanged and forbids missing an original commit.
CPU/lint, all 16 exact AZ mixes and full collision poisoning pass.
A privileged MSR-write program passes lockstep; removing the pre-exception
guard fails the status invariant (exit 1). Standalone uses 14,337 ALMs /
10,244 registers / 101 RAM blocks, 61.20 MHz (-2.054 ns), worse than AZ.
Specfetch, memtest and 300 M lockstep pass (481,828,716 post-Cuda cycles).
Source/evidence: `Scratch/perf/status_capacity/`.

BB (fault-payload) branches from BA: prospective MMU D-fault payloads
capture by D_IDLE/D_WALK state independently of request/cancellation.
The fault state machine is unchanged, and D_FAULT holds the sampled values.
An assertion checks DSISR/alignment/DAR against the exact original fault
capture when visible. CPU/lint, all 16 exact BA mixes and full collision
poisoning pass. Standalone uses 14,428 ALMs / 10,297 registers / 101 RAM,
62.09 MHz (-1.821 ns). Specfetch, memtest and 300 M lockstep pass
(481,828,716 post-Cuda cycles).
Source/evidence: `Scratch/perf/fault_payload/`.

BC (isegment-ram) branches from BB: an instruction-side segment-register
RAM copy is written with original MTSR commit/index/data. Per-row valid
bits make reset read zero; same-edge collisions forward explicitly. CPU
architectural SR bank and data-side SR reads are unchanged. An assertion
checks every fresh translated instruction sample against architectural SR.
CPU/lint, all 16 exact BB mixes, collision poisoning (including the new SR
RAM), specfetch, memtest and 300 M lockstep pass. Standalone diagnostic
`cpu_diagnostic_bc/` reaches 60.68 MHz / 14,178 ALMs / 10,208 registers /
102 RAM blocks (-2.195 ns), worse than BB.
Source/evidence: `Scratch/perf/isegment_ram/`.

BD (mu-payload-banks) branches from BC: accepted memory descriptor fields
use two alternating payload banks; late request acceptance switches only
selectors. An assertion compares the active descriptor with original
accepted payload throughout the request. CPU/lint, all 16 exact BC mixes
and collision poisoning pass. Standalone reaches 62.61 MHz / 14,368 ALMs /
10,378 registers / 102 RAM blocks (-1.685 ns). Specfetch/memtest pass;
300 M lockstep passes (481,828,716 post-Cuda cycles).
Source: `Scratch/perf/mu_payload_banks/`.

BE (forwarding-flags) is a direct AT fork, excluding AU–BD. It includes
registered ID GPR indices and registers twelve EX forwarding masks with
stage handoffs after parallel producer/consumer comparisons. All masks
must equal original live MEM/WB matches every cycle, including invalid EX.
CPU/lint, all 16 exact AT mixes and full collision poisoning pass. Extended
GPR shadow/collision checks were added and rerun successfully. Timing
reaches 62.27 MHz / 14,177 ALMs / 9,915 registers / 101 RAM (-1.774 ns).
The worst path is FPSCR handling -> exception/redirect -> fetch admission
-> BTB sampled validity. Specfetch/memtest and 300 M lockstep pass.
Source: `Scratch/perf/forwarding_flags/`. Full-machine seed 1 OFF fits at
34,650 ALMs (83%) / 37,712 registers / 346 RAM / 48 DSP. CPU70 fails cold
at -2.723 ns (about 58.79 MHz); MEM100 fails cold at -0.259 ns (about
97.48 MHz). All-clock hold passes (+0.097 ns minimum). Worst CPU path is
cache tag RAM -> late commit/translation control -> MMU walk payload;
MEM is stock yc_out chroma LUT -> phase. Reports are archived. This is
worse than integrated AT; keep BE isolated.

BF (btb-candidates) branches from BE: resolve validity/collision priority
for current and predicted BTB rows in parallel before selecting by late
fetch admission. A cycle-by-cycle assertion compares all four sampled
validity/forwarding flags with original logic. CPU/lint/all 16 exact BE mixes,
full cache/TLB/BTB/FPR/GPR collision poisoning with shadow GPR checks,
specfetch and memtest pass. Standalone reaches 60.38 MHz / 14,007 ALMs /
9,884 registers / 101 RAM (-2.058 ns), worse than BE. ID decode -> forwarding
mask update becomes critical. 300 M machine lockstep passes
(481,830,131 post-Cuda cycles, 25 I-device fetches).
Source `/tmp/macppc7300-btb-candidates-src`; archive
`Scratch/perf/btb_candidates/`. Root remains AT.

BG (late-dreply) directly branches from BE, excluding BF. Enable existing
data-cache LATE_ANSWER=1 to measure a fully registered answer now that EX
forwarding compares have moved. CPU suite/lint and all 16 lockstep mixes
pass, but cached load/store/FP-load streams fall from ~170k to ~330k cycles
per 10k loops (one per two cycles); load-use becomes ~330k vs ~250k.
This sacrifices much of the architecture gain. Standalone timing improves
to 64.95 MHz / 13,725 ALMs / 10,094 registers / 101 RAM (-1.102 ns),
still failing 70 MHz. Do not promote this CPI regression.
No full-machine/collision/hardware claim. Source: `Scratch/perf/late_dreply/`.

BH (tag-mlab) directly branches from BE, excluding BF/BG. Only cache tag
RAM's ramstyle attribute changes to `MLAB, no_rw_check`. Simulation semantics
are byte-identical to BE after stripping that attribute change, so BE's
CPU/lint/16 mixes/poison/machine evidence is reused explicitly. Quartus still
implements tag RAMs as M10K with OLD_DATA collision behavior; the aggregate
attribute did not select MLAB. Same 62.27 MHz / 14,177 ALMs / 9,915 registers /
101 RAM (-1.774 ns) as BE. No improvement.
This is motivated by the full BE cache-tag clock-to-out -> MMU walk path.
Source: `Scratch/perf/tag_mlab/`.

BI (tag-mlab-ways) branches from BH: declare a packed-word tag array per
generated cache way so each memory receives its own MLAB/no_rw_check hint.
Read/write indexes, output registers, collision forwarding and cycles are
unchanged. Full CPU/lint/full poisoned collision checks and all 16 exact
BE performance mixes pass under `/tmp/macppc7300-tag-mlab-ways{-poison}-src`.
Diagnostic `cpu_diagnostic_bi/` finishes at 62.27 MHz / 14,177 ALMs /
9,915 registers / 101 RAM (-1.774 ns), identical BE. Quartus still maps
tags to M10K OLD_DATA despite per-way attributes; no MLAB or timing benefit.
Reports are archived. Machine specfetch
and 6 MB memtest pass; 300 M ROM lockstep passes (481,830,131 post-Cuda
cycles, PC 680613F4 / MSR 0000D076, 25 I-device fetches, 158,874 reads /
655,483 writes). This is ROM/reference proof, not OS boot or performance.
Full machine remains unverified. No new hardware candidate.
Source/evidence: `Scratch/perf/tag_mlab_ways/`. Root stays AT.

BJ (tag-mlab-assignment) has exactly BI CPU RTL and reuses its completed
CPU/lint/16 exact mixes/full poisoned collisions/specfetch/memtest evidence.
Only isolated syn/check.py adds a Quartus RAMSTYLE_ATTRIBUTE MLAB instance
assignment for `*|way*.tags*`. Diagnostic `cpu_diagnostic_bj/` finishes at
the same 62.27 MHz / 14,177 ALMs / 9,915 registers / 101 RAM as BE/BI.
Critical Warning 136021 says the braced node pattern is invalid and the
assignment was ignored. Zero MLAB bits; no implementation/timing benefit.
Source/reports: `Scratch/perf/tag_mlab_assignment/`.
Main source/tool settings and root AT remain unchanged.

BK (tag-mlab-qsf) corrects BJ's QSF node quotation to double quotes. CPU RTL
is exactly BI and reuses the same completed functional gates. Diagnostic
finishes with identical 62.27 MHz / 14,177 ALMs / 9,915 regs / 101 RAM,
zero MLAB bits. Reports: `Scratch/perf/tag_mlab_qsf/`.
Root source and main QSF are unchanged; no timing/hardware improvement.

BL (tag-mlab-qsf-match) broadens BK's pattern to `*tags*`. The actual
synthesized RAM name is `|altsyncram:way[0].tags…`, which the BK `|way…`
pattern cannot match. Same BI CPU RTL/completed functional gates; diagnostic
again finishes with identical 62.27 MHz / 14,177 ALMs / 9,915 regs / 101 RAM,
zero MLAB bits. Reports: `Scratch/perf/tag_mlab_qsf_match/`. No benefit.

RAM-inference probe (`Scratch/perf/tag_mlab_probe/`): same 128x22 memory
outside generate maps to MLAB/DONT_CARE; generated literal reg, literal
logic and $bits-width logic arrays all ignore the same MLAB/no_rw_check
hint and map to AUTO/OLD_DATA. Quartus17.0.2 Build602; map only, not a
CPU timing result. Initial probe omitted explicit generate syntax and
failed parsing; the corrected probe synthesizes with zero errors/warnings.

BM (tag-mlab-module) moves only tag RAM declarations into a helper module
in existing cache_ram.sv, instantiated per way. Same synchronous read/write
and explicit cache collision forwarding. Full CPU, full GPR shadow and
GPR/cache/tag/data/FPR/BTB/TLB collision-poisoned suites pass. All16 mixes
and event counts are EXACT BI. Synthesis finally maps all8 tag RAMs to
MLAB (22,528 MLAB bits). Final fit uses 14,628 ALMs / 10,149 regs / 93 RAM;
timing worsens to 58.11 MHz cold (-2.923 ns), 58.93 hot (-2.683 ns), versus
BI62.27 MHz. Critical path now forwarded operands -> BTB target forwarding.
Reject this regression: no full Quartus compile or promotion.
Lint and trained specfetch pass (150instr/522postCuda cycles).
Initial memtest command omitted --machine and stopped with CLI exit2;
Corrected 6MB memtest passes with 0 errors / 27,333,623 post-Cuda cycles.
300M run started, then intentionally stopped after the final timing failure;
do not claim a completed BM300M result. CPU suites/performance/inference/
timing reports and partial machine log are archived.
Source/evidence:
`Scratch/perf/tag_mlab_module/`; root AT remains unchanged.

Potential next timing check: generated cache data-word RAMs also still map
to OLD_DATA despite no_rw_check. A module-scope helper may enable that
attribute without selecting MLAB; use M10K for tags/data to avoid BM's
placement/resource regression. This is a hypothesis, not a speedup claim.
Verify actual DONT_CARE inference, collisions and unchanged performance
before full-machine timing.

BN (cache-m10k-module) extends BM's module-scope declaration to all8 tags
and all64 data-word RAMs, with M10K/no_rw_check instead of MLAB. Same RTL
read/write/collision behavior. CPU and full GPR/cache/tag/data/FPR/BTB/TLB
poison/lint suites pass. All16 mixes/events EXACT BI. Synthesis confirms
all72 helper RAMs as M10K/DONT_CARE, zero MLAB bits. Standalone reaches
63.34 MHz (-1.502 ns), 14,357 ALMs / 10,030 regs / 101 RAM: +1.07 MHz
versus BI, still70FAIL. Full-machine 70MHz retiming-off seed1 is prepared
at `/tmp/macppc7300-cache-m10k-module-full-seed1`; all remote snapshot
hashes verified before launch in `seed_cache_m10k_module_no_retiming/`.
Full compile/four-corner timing finishes: 35,108 ALMs (84%), 37,827 regs,
346 RAM / 48 DSP. CPU70 fails at59.84MHz (-2.426ns hot / -2.374cold),
MEM100 cold fails at98.63MHz (-0.139ns; hot+0.164). Hold passes all4corners
(minimum+0.076ns). Worse than retainedAT CPU60.38/MEMpass. No promotion
or deployment. Full reports: `Scratch/perf/cache_m10k_module/quartus/full_no_retiming/`.
Specfetch/6MB memtest PASS (522/27,333,623 post-Cuda cycles); 300M lockstep
PASS (481,830,131 post-Cuda cycles, PC680613F4/MSR0000D076,
158,874 reads / 655,483 writes, 3,320/4,947 lines, 25 I-device fetches).
No OS boot or Speedometer proof. Source/evidence:
`Scratch/perf/cache_m10k_module/`. Root unchanged; no hardware.

BO (fpscr-predecode) directBE fork, excludes BF-BN. Capture static FPSCR
bit/destination/source selection with ID-to-EX admission, before late EX
FPSCR/FEX/redirect computation. No added instruction latency. Assertions
require exact original selectors for every valid EX instruction. CPU,
786,432 exhaustive instruction-field/basis/random FPSCR equivalence cases
and all16 exact BE mixes/events pass. Poison checker initially omitted
new unused default-mode ports (PINMISSING), corrected full poison suite PASS.
Lint PASS; standalone63.32 MHz / -1.506 ns, 13,930 ALMs / 10,002 regs /
101 RAM (+1.05MHz vs BE, still70FAIL). Final reports archived. Source:
`Scratch/perf/fpscr_predecode/`. No full-machine timing or board performance claim.

BP (cache-fpscr) combines BO static FPSCR selection and BN module-scope
M10K cache RAMs. Full CPU/full GPR shadow/collision/lint suites PASS;
FPSCR module exact BO, reuses its 786,432-case equivalence. All16 mixes/
events EXACT BN. Specfetch and6MB memtest PASS (522/27,333,623postCuda
cycles). Final standalone61.52MHz/-1.969ns, 14,273 ALMs / 10,033 regs /
101 RAM regresses versus BN63.34 and BO63.32. Reports archived; no full
compile or 300M run for this regression. Source/evidence
`Scratch/perf/cache_fpscr/`. Root remains AT; no hardware.

BQ (fetch-store) directBN fork, excludesBO/BP. FullBN worst CPU path is
CR branch/exception -> fetchFIFO RAM write enable (17.707ns data delay).
Separate physical RAM store from logical enqueue: redirect may write an
otherwise discarded slot, but all original FIFO count/pointer/kill/ID/
prediction state transitions remain unchanged. Every occupied entry is
checked against an original FIFO shadow; extra writes require a redirect.
CPU/full GPR/cache/tag/data/FPR/BTB/TLB poison/lint suites PASS. All16
mixes/events EXACT BN. Seven mixes cover extra discarded writes; a wrong
RAM write-address negative control trips occupied-word shadow (exit1).
Standalone finishes at60.94MHz/-2.124ns, 14,237 ALMs / 10,012 regs / 101RAM,
below BN63.34. Full70MHz retiming-off seed1 has completed: 35,237 ALMs,
37,754 registers, 346 RAM blocks and 48 DSPs. CPU setup is -2.188ns hot /
-1.997ns cold (about60.71MHz), improving BN by0.87MHz and AT by0.33MHz.
MEM100 still fails cold (-0.099ns), despite hot +0.070ns. All four hold
corners pass, minimum+0.091ns. No unconstrained clocks; stock external IO
remains partially constrained. All transferred hashes were verified before
launch in `seed_fetch_store_no_retiming/` (PID2049876, now complete).
Specfetch/6MB memtest PASS (522/27,333,623postCuda cycles). 300M lockstep
PASS (481,830,131postCuda cycles), with no OS boot or Speedometer proof.
Keep isolated: full timing fails. Reports under `quartus/full_no_retiming/`.
Source/evidence `Scratch/perf/fetch_store/`; rootAT unchanged.

BR (btb-target-flags) directBQ fork, excludesBO/BP. Target forwarding flags
reuse parallel current/predicted write-row comparisons, as metadata/validity
already do, instead of comparing after late fetch-controlled index selection.
Assert exact original row match for every target write. No added latency.
CPU/full GPR shadow and all collision-poison suites PASS. Lint and all16
mixes/events EXACT BQ PASS. Specfetch/6MB memtest PASS (522/27,333,623
postCuda cycles). Standalone `cpu_diagnostic_br/` PID2058082 has completed:
63.44MHz/-1.476ns, 14,297 ALMs / 9,961 registers / 101RAM. This improves
BQ standalone by2.50MHz, but does not establish full-machine timing.
Full70MHz retiming-off seed1 in
`seed_btb_target_flags_no_retiming/` (PID2069577) has completed; all transferred
source hashes were verified before launch. Full resources:34,582 ALMs /
37,703 registers /346RAM /48DSP. CPU hot-2.878ns/cold-2.740ns (about58.26MHz),
worse thanBQ60.71 andAT60.38. MEM100 passes all corners (minimum+0.126ns);
all-corner hold passes (minimum+0.115ns). Worst CPU path is EX CR select ->
MMU fault DAR capture,16.451ns data delay. No unconstrained clocks; stock
external IO remains partially constrained. Keep isolated: CPU70 fails.
Reports under `quartus/full_no_retiming/`; no300M or board result.
Source/evidence `Scratch/perf/btb_target_flags/`. RootAT unchanged; no claim.

BS (completion-occupancy) directBR fork. BQ full timing ends its worst CPU
path at the binary completion count, after cache hit/response/MEM retirement.
Use nine-bit one-hot total/older occupancy, shifting on push/pop with the
original eight-entry capacity, EX handoff and reset/redirect priorities.
Admission and EX ordering use full/empty bits directly. Original binary
counter shadows and one-hot checks prove exact counts every cycle.
CPU/full GPR/cache/tag/data/FPR/BTB/TLB poison/lint suites PASS. All16
cycle counts/events EXACT BR PASS. A deliberately two-entry shift trips
the binary shadow (exit1). Specfetch/6MB memtest PASS (522/27,333,623
postCuda cycles). Initial Quartus compile failed on simulation-only $onehot:
Quartus17 does not define SYNTHESIS. Explicit synthesis translate_off/on
now excludes the observer; final functional suites were rerun and pass.
Initial failure archived under `quartus/initial_guard_failure/`. Corrected
standalone diagnostic `cpu_diagnostic_bs_guarded/` PID2074376 completed:
14,030 ALMs / 10,051 registers / 101RAM,62.20MHz hot/62.51cold, worst
setup-1.792ns. Worst path is cache tag RAM to next store payload; the
counter endpoint is off the leading standalone paths. This is belowBR's
63.44MHz. Full70MHz retiming-off seed1 in
`seed_completion_occupancy_no_retiming/` (PID2084000) has completed, with
all transferred source hashes verified. Full resources:34,974 ALMs /
37,686 registers /346RAM /48DSP. CPUhot-2.514ns/cold-2.458ns (about59.53MHz),
improvingBR by1.27MHz but still belowBQ/AT. MEM100 fails hot-0.166ns /
cold-0.306ns (97.03MHz cold). All4holdcorners pass, minimum+0.059ns.
No unconstrained clocks; stock external IO partial. Worst CPU path is WB
forwarding flag -> integer rotate/shift -> CR[29],16.213ns data delay.
Keep isolated: full timing fails. Reports under `quartus/full_no_retiming/`.
No300M or board result yet.
Source/evidence `Scratch/perf/completion_occupancy/`. RootAT unchanged.

BT (fault-capture) directBS fork, imports only BB's prospective MMU D-fault
payload capture. Targets BR full branch-to-DAR capture enable. Registered
D_IDLE/D_WALK state samples DAR/DSISR/alignment independently of late
request/cancellation. Original state machine alone exposes D_FAULT, where
payload holds. A shadow compares every visible payload with original capture.
CPU/full GPR/cache/tag/data/FPR/BTB/TLB poison/lint suites PASS. All16
cycle counts/events EXACT BS PASS. Wrong prospective DAR+4 negative control
trips original capture shadow (exit1). Specfetch/6MB memtest PASS (522 /
27,333,623postCuda cycles). Standalone14,193 ALMs /9,955 registers /101RAM,
63.57MHz hot/63.76cold (-1.445ns worst), +1.37MHz overBS; RAS recovery ->
MMU instruction segment sample is the leading standalone path.
300M machine lockstep PASS (481,830,131postCuda cycles), with no OS boot or
Speedometer proof. Full70MHz retiming-off seed1 in
`seed_fault_capture_no_retiming/` (PID2098634) completes:34,829 ALMs /
37,788 registers /346RAM /48DSP. CPUhot-2.674ns/cold-2.437ns (58.97MHz),
belowBQ/AT. MEM100 passes all corners (+0.116ns minimum); all-corner hold
passes (+0.117ns minimum). Worst CPU MEMresult -> rotate/shift -> CR[14],
16.786ns data delay. No unconstrained clocks; stock external IO partial.
Keep isolated: CPU70 fails. Reports under `quartus/full_no_retiming/`.
Source/evidence `Scratch/perf/fault_capture/`. RootAT unchanged; no hardware.

BU (direct-shifts) directBT fork. SLW/SRW/SRAW results use direct word shifts,
preserving six-bit count saturation, signed fill, lost-bit carry and all
rotate/insert outputs. Raw old/new ALU equivalence PASS 1,179,648 cases,
all9 outputs: every encoded rotate op/count/mask pair/count source, single/
inverse bits, and other ALU modes. Wrong saturated SRAW carry trips miter
(exit1). CPU/full poison/lint/all16 exact BT mixes/specfetch/6MB memtest PASS.
Standalone14,446 ALMs /9,969 registers /101RAM,62.39MHz hot/61.91cold,
belowBT63.57. Keep isolated; no full-machine compile/300M/board claim.
Source/evidence `Scratch/perf/direct_shifts/`.

BV (cr-delta) directBT fork excludesBU. Move final CR mask/merge into MEM
using registered overwrite keep/set payload. Forward effective CR to all
consumers at the original EX commit edge; physical CR absorbs each owned
MEM overwrite. Reapplying a fixed overwrite is idempotent, including held
or faulting entries. Completion entries carry neutral overwrite. Original
next-value function, EX-commit state and MEM-snapshot shadows match every
cycle. CPU/full GPR/cache/tag/data/FPR/BTB/TLB poison/lint suites PASS.
All16 cycles/events EXACT BT PASS. Disabled MEM-to-CR forwarding negative
control trips original EX-commit shadow (exit1). Specfetch/6MB memtest and
300M machine lockstep PASS (522/27,333,623/481,830,131postCuda cycles).
No OS boot or Speedometer proof. Standalone14,206 ALMs /10,108 registers /
101RAM,61.74MHz hot/62.19cold (-1.912ns hot), belowBT. Leading path is
cache tag RAM -> EX FP operand payload. Full70MHz retiming-off seed1 in
`seed_cr_delta_no_retiming/` (PID2137739) completes, all transferred hashes
verified:34,913 ALMs /37,828 registers /346RAM /48DSP. CPUhot-2.862ns /
cold-2.702ns (58.32MHz), belowBT/BQ/AT. MEM100 passes all corners (+0.054ns
minimum); all-corner hold passes (+0.066ns minimum). Worst CPU cache tag RAM
-> HID0[15],14.648ns data delay with -2.419ns clock skew. No unconstrained
clocks; stock external IO partial. Keep isolated: CPU70 fails. Full reports
under `quartus/full_no_retiming/`. Source/evidence `Scratch/perf/cr_delta/`.
RootAT unchanged; no hardware.

BW (capture-banks) directBV fork. Alternating banks pre-capture the six EX
operands and HID0 independently of late memory completion. Original ID
admission and HID0 commitment switch only one-bit owners. Held EX values
retain WB forwarding; extra writes affect only unowned operands after EX
leaves. Original owned-operand and architectural HID0 shadows match.
CPU/full GPR/cache/tag/data/FPR/BTB/TLB collision-poison suites/lint PASS;
all16 cycle/event dictionaries EXACT BV. Disabled EX bank switch negative
control trips the operand shadow (exit1). Specfetch/6MB memtest PASS
(522/27,333,623postCuda cycles), unchanged. Standalone14,271 ALMs /
10,396 registers /101RAM,59.73MHz hot/60.86cold (-2.456ns worst), belowBV.
Worst standalone path EX system-op decode -> FPSCR/exception/redirect controls ->
BTB target forwarding. Keep isolated; no timing closure or performance gain.
All63 reported normal-suite cycle counts EXACT BV. 300M machine lockstep
PASS,481,830,131postCuda cycles, identical architectural state/device accesses
and25I-device fetches. No OS boot/Speedometer proof. Full70MHz retiming-off
seed1 in `seed_capture_banks_no_retiming/` (PID2167628) completes:35,348 ALMs
/37,998 registers /346RAM /48DSP. All118 transferred source hashes were
verified; postbuild RTL also matches the manifest. CPUhot-2.799ns/cold-2.796ns
(58.53MHz), belowAT/BQ. MEM100 passes all corners (+0.118ns minimum);
all-corner hold passes (+0.096ns minimum). No unconstrained clocks; stock
external IO26input/90outputports partial. Worst CPU cache tag RAM -> MMU
wide-response qualification -> load window/format -> WBresult[7],14.655ns
data delay and -2.349ns clock skew. Full reports archived under
`quartus/full_no_retiming/`. Keep isolated: CPU70 fails. Source/evidence
`Scratch/perf/capture_banks/`. RootAT unchanged; no hardware deployment.

BX (load-window) directBW fork removes the late `dbus_rwide` zero-fill mux
from the first-phase load window. A successful first-phase doubleword
response already requires wide validity. Noncrossing narrow loads select
only the first word; a crossing load or declined doubleword uses saved
word0/current second word in the second phase. Handshakes, faults and state
transitions are unchanged. Original wide-qualified formatting shadow checks
every successful CK_WORD load; unused store/cache-control/fault payloads
have no load-result guarantee. CPU/full GPR/cache/tag/data/FPR/BTB/TLB
collision-poison suites PASS. All16 cycle/event dictionaries and all63
normal-suite cycle counts EXACT BW. Nonzero discarded second-word coverage
is exercised; corrupted first-word negative control trips the shadow
(exit1). Lint/specfetch/6MB memtest PASS (522/27,333,623postCuda cycles,
unchanged). Standalone70MHz retiming-off diagnostic `cpu_diagnostic_bx`
(PID2191826) completes:14,507 ALMs /10,368 registers /101RAM,63.56MHz hot /
64.70cold (-1.446ns worst), +3.83MHz versusBW. Worst standalone EX operand
hazard/admission -> ID one-hot CR selector. Reports archived under
`quartus/no_retiming/`. 300M machine lockstep PASS,481,830,131postCuda cycles,
identical final state/device accesses and25I-device fetches. No OS boot or
Speedometer proof. Full70MHz retiming-off seed1
`seed_load_window_no_retiming/` (PID2193215) completes:35,335 ALMs /38,052
registers /346RAM /48DSP. CPUhot-2.985ns/cold-2.863ns (57.90MHz), belowBW/AT/BQ.
MEM100 also fails (hot-0.002ns/cold-0.237ns); all-corner hold passes
(+0.114ns minimum). No unconstrained clocks; stock external IO26input/
90outputports partial. Worst CPU cache tag RAM -> hit-word/data-way selection
-> load-window/format -> WBresult[4],14.827ns data delay/-2.363ns clock skew.
The intended wide-qualification path is removed, but full timing regresses.
All118 transferred full source hashes were verified; postbuild RTL matches
the manifest. Full sources differ from BW only in the memory unit. Full
reports archived under `quartus/full_no_retiming/`. Keep isolated. Source/evidence
`Scratch/perf/load_window/`. RootAT unchanged; no hardware deployment.

BY (mlab-tags-full) directBX fork. Cache tag helper uses module-scope
MLAB/no_rw_check. Data words use a separate fixed32x128 module-scope M10K
helper with identical synchronous read/write transitions. All tag/data
collision forwarding is unchanged. This tests the full-design RAM return
path instead of relying on BM's earlier slower standalone ranking. CPU/
full GPR/cache/tag/data/FPR/BTB/TLB collision-poison/lint suites PASS; all16
cycle/event dictionaries and all63 normal-suite counts EXACT BX.
Lint/specfetch/6MB memtest PASS (522/27,333,623postCuda cycles,unchanged).
Standalone `cpu_diagnostic_by` (PID2215703) completes:14,901ALMs /
10,462registers /93RAM,61.04MHz hot/60.75cold (-2.096ns worst), belowBX.
Actual mapping:8MLABtaginstances /22,528bits and64M10Kdatawordinstances.
Worst standalone D-cache request tag -> response/redirect/fetch -> BTB valid.
Reports archived under `quartus/no_retiming/`. 300M ROM lockstep PASS,
481,830,131postCuda cycles, identical state/device accesses and25I-device
fetches. No OS boot or Speedometer proof. Full70MHz retiming-off seed1
`seed_mlab_tags_full_no_retiming/` (PID2216771) completes:36,083ALMs (86%) /
38,314registers /338RAM /48DSP. Full mapping also confirms8MLABtaginstances
and64M10Kdatawordinstances. CPUhot-2.004ns/cold-1.950ns (61.39MHz), above
BX57.90/AT60.38/BQ60.71 but still failing70. MEM100 fails cold setup
(-0.193ns, hot+0.055ns); all-corner hold passes (+0.106ns minimum).
Worst CPU Dcache request tag r_addr[16] -> hit compare/response -> completion/
admission -> MEMforward_q[1],15.748ns data delay/-0.461ns clock skew.
The M10K tag-clock skew family is removed, but late hit-control feedback
remains. The failing MEM100 path is stock yc_out sine lookup -> DSP multiplier
-> phase[2].v, not the CPU's SDRAM request path. No unconstrained clocks;
stock external IO26input/90outputports partial.
All118 transferred full source hashes verified; postbuild RTL matches manifest.
Full sources differ fromBX only in cache RAM helper. Reports/inference summaries
archived under `quartus/full_no_retiming/`. Keep isolated. Source/
evidence `Scratch/perf/mlab_tags_full/`. RootAT unchanged; no hardware.

BZ (forward-select) directBY fork implements that measured control cut.
All three producer-by-two-consumer forwarding alternatives register in
parallel; narrow producer/consumer selectors follow original admission
priority. Registered MEM/WB validity qualifies the selected masks. WB
reuses the current-MEM candidate registers. No cycle or operand change.
Original captured masks and actual tag matches compare every cycle,
including invalid EX. CPU/full inherited collision-poison suites/lint PASS;
all63 suite counts and all16 cycle/event dictionaries EXACT BY. Inverting
the consumer selector fails the original-capture observer as required.
Specfetch/6MB memtest PASS,522/27,333,623postCuda cycles,zero errors.
300M ROM lockstep PASS,481,830,131postCuda cycles,exactBY state/device
accesses and25I-device fetches. No OS boot or Speedometer proof.
Standalone `cpu_diagnostic_bz` (PID2242016)
completes:14,962ALMs/10,582registers/93RAM,61.39MHz hot/61.87cold,
-2.002ns worst,still fails70. Worst Dcache request tag -> hit response ->
ID-admission/fetch-delivery -> fetch_stage RAM bypass. Quartus maps the
two-entry133bit output stage to4M10Ks with automatic pass-through logic.
Full70MHz OFF seed1 `seed_forward_select_no_retiming` (PID2244126) completes:
36,262ALMs(87%)/38,342registers/338RAM/48DSP. CPUhot-2.641ns/cold-2.448ns
(59.08MHz),worseBY61.39MHz. MEM100 setup passes all corners,min+0.272ns;
all-corner hold passes,min+0.114ns. Worst Dcache request tag r_addr[25] ->
hit response/MEMleave/ID admission -> id_gpr_ra[4] enable,16.433ns data
delay/-0.413ns clock skew. Fetch-delivery control has225loads in this path.
No unconstrained clocks;stock26input/90outputIOpartial. Full reports
archived under `quartus/full_no_retiming/`; postbuild RTL matches manifest.
All118 full input hashes compared againstBY; only DSPPC604.sv
differs. All118 transferred hashes verified before launch. The added
EX-input mux moves the critical path but full timing worsens. Reject this
candidate for integration;keep isolated. No timing closure or board claim.
Source/evidence `Scratch/perf/forward_select/`. All jobs complete.

Measured next possibility, not implemented: replace the two-entry fetch
output array with two explicit named133bit payload registers, retaining
original push/tail/head/count/redirect controls and the same visible word.
This may avoid inferred RAM look-ahead/read-write bypass on late delivery.
Compare both stored rows and the visible word against the original every
cycle; poison a selected row as a negative control. Measure full timing:
the cost is266payload registers and a two-way output mux. Prefer the actual
full-fit critical path before choosing this cut. BZ's full worst path is
the saved GPR index enable, not this RAM bypass: prioritize late ID-admission
fanout before selecting a frontend-only RAM change. Root remains unchanged.

CA (id-payload) directBY fork, excludesBZ. The admission-enabled181bit ID
packet becomes two explicit named payload banks. The inactive bank samples
the prospective fetch packet; original fetch delivery changes a one-bit
owner. Owner initializes at FPGA power-up and retains across CPU reset,
matching the original unreset held packet. IDvalid/FIFO/sequence/GPR indices
and operand controls retain their original transitions. Original packet
shadow compares all181bits every nonreset cycle, including invalid ID.
CPU/full inherited collision-poison suites/lint PASS; all63 normal-suite
counts and all16 cycle/event dictionaries EXACT BY. Disabled owner switching
fails that packet shadow. Specfetch/6MB memtest PASS,522/27,333,623postCuda
cycles,zero errors. 300M ROM lockstep PASS,481,830,131postCuda cycles,
exactBY state/device accesses and25I-device fetches. No OS boot proof.
Standalone70 OFF `cpu_diagnostic_ca` (PID2266499) completes:
15,045ALMs/10,688registers/93RAM,58.66MHz hot/59.40cold,-2.761ns worst.
Worst owner (680loads) -> raw instruction decode/sequence -> EXoperand bank.
The admission enable is removed, but selection before decode costs timing.
Full70 OFF seed1 `seed_id_payload_no_retiming` (PID2268892) completes:
36,089ALMs(86%)/38,418registers/338RAM/48DSP. CPUhot-2.780ns/cold-2.687ns
(58.60MHz),worseBY61.39MHz. MEM100 cold-0.019ns/hot+0.119ns;
all-corner hold passes,min+0.081ns. Worst Dcache writeback state ->
CPU memory-address mux -> Hammerhead RAM mapping/device decode -> VIA wait
state (machine.vw),16.498ns data/-0.487ns clock skew. This is VIA control,
not video control. Data routing contributes13.141ns (80%) over10logic levels.
Reject for integration; no70MHz closure. All118 postbuild input hashes
match manifest; full reports archived under `quartus/full_no_retiming/`.
All118 full input hashes
compared againstBY; only DSPPC604.sv differs. All118 transferred hashes
verified before launch. Test the actual register mapping, owner fanout/mux
paths and full timing before choosing it. RootAT unchanged; no hardware,
timing closure or Speedometer claim. Source/evidence `Scratch/perf/id_payload/`.

CB (id-decode) directCA fork. Capture the existing222bit fetch decode beside
the181bit ID payload (403bits per explicit bank). ID consumes the selected
decoded bundle, moving the raw decoder before bank selection. ISI packets
retain the original all-zero decode of insn=0. No decoder rules, stage
handshakes, operands or cycles changed. An independent original decoder
observes id_insn and compares the entire decoded bundle every nonreset
cycle,including invalid ID; the full held-packet shadow remains. CPU/full
inherited collision-poison suites/lint PASS; all63 normal-suite counts and
all16 cycle/event dictionaries EXACT CA. Corrupt decoded-valid negative
control fails the independent decoder. Specfetch/6MB memtest PASS,
522/27,333,623postCuda cycles,zero errors. 300M ROM lockstep PASS,
481,830,131postCuda cycles,exactCA state/device accesses and25I-device fetches.
Standalone70 OFF `cpu_diagnostic_cb` (PID2276984) completes:
15,079ALMs/11,043registers/93RAM,62.32MHz hot/63.24cold,-1.759ns worst.
Worst Dcache request tag/hit control -> MEM payload admission -> MEMforward_q;
raw owner-to-decoder critical path removed. Full70 OFF seed1
`seed_id_decode_no_retiming` (PID2282009) completes:
35,998ALMs(86%)/38,841registers/338RAM/48DSP. CPUhot-3.171ns/cold-2.868ns
(57.29MHz),worseCA58.60/BY61.39MHz. MEM100cold-0.142ns/hot+0.083ns;
all-corner hold passes,min+0.117ns. Worst MEMvalid -> frontend PC,16.820ns
data/-0.556ns skew; Dcache tag -> MEMforward remains another violating family.
All118 postbuild input hashes match manifest; full reports archived under
`quartus/full_no_retiming/`. Reject integration: standalone improvement does
not survive full fit. All118 full input hashes
compared againstCA; only DSPPC604.sv differs. All118 transferred hashes
verified before launch. Keep isolated; no timing/board/OS benchmark claim.
Source/evidence `Scratch/perf/id_decode/`. RootAT unchanged.

CC (cache-bus-address) isolated directCB fork. Register the external cache
address on original request/snoop capture or on entry to dirty writeback;
restore the request address on writeback ACK. Remove the current-state
writeback address mux without changing request cycles. Compare every active
memory address with the original state expression; log writeback/fill/uncached
coverage separately. Normal CPU suite PASS; all63 instruction/cycle counts
EXACT CB. Full inherited GPR/cache/tag/data/FPR/BTB/TLB collision-poison suite,
lint and all16 complete cycle/event dictionaries PASS/EXACT CB. Corrupt address
negative fails the independent original-state observer (return1). Specfetch
PASS522postCuda cycles;6MB memtest PASS27,333,623postCuda cycles,zero errors,
exactCB. Dirty writeback, fill and uncached/write-through observer coverage
seen. 300M ROM lockstep PASS481,830,131postCuda cycles,all progress/final
state/device counters EXACT CB,PC680613F4/MSR0000D076,25I-device fetches.
This remains ROM/device coverage,not OS boot or Speedometer proof.
Standalone70 OFF `cpu_diagnostic_cc`
PID2311391 completes:15,307ALMs/11,087registers/93RAM,59.49MHz hot/59.98cold,
-2.523ns worst,still fails70. Worst EXinstruction field -> FPSCR held/memory
operations -> EXexception -> redirect -> fetch-stage RAM bypass,16.176ns
data. 19postbuild source hashes match; diagnostic reports archived under
`quartus/no_retiming/`. InitialPID2309582 preflight failed because diagnostic
package omitted CPU QIP; failure logs preserved in `preflight_missing_qip/`,
exactQIP supplied and all19+QIP hashes verified before retry. Full70 OFFseed1
`seed_cache_bus_address_no_retiming` PID2309577 completes:
36,111ALMs(86%)/38,819registers/338RAM/48DSP. CPUhot-2.305ns/cold-2.218ns
(60.28MHz),improvesCB57.29butfails70. MEM100 passes all corners,min+0.121ns;
all-corner hold passes,min+0.100ns. Worst Dcache.r_addr[2] (874loads) ->
word selection/pending collision forwarding -> hit-word select -> MU load
formatting -> WBresult[29],16.060ns data/-0.450ns skew. Full reports archived
under `quartus/full_no_retiming/`;all118 postbuild input hashes match manifest.
This removes the state-selected external address path, but load-data selection
and formatting now dominate. Keep isolated;no timing closure/deployment.
All118 transferred
source hashes verified,only cache.sv differs fromCB. Timing still unproven.
Source `/tmp/macppc7300-cache-bus-address-src`, poison
snapshot `/tmp/macppc7300-cache-bus-address-poison-src`, evidence
`Scratch/perf/cache_bus_address/`. No other candidate is promoted or deployed.

CD (cache-word-select), isolated directCC fork. Capture per-way one-hot
word selection alongside the existing synchronous cache set read. Select
raw, pending and landed words with those local registered masks, retaining
the original pending-over-landed forwarding priority and next-word wrap.
The original full-line forwarded data independently checks both selected
words on every lookup; the original granted address checks the masks.
Normal CPU suite and full inherited collision-poison suite PASS. All63
normal instruction/cycle counts and all16 complete performance cycle/event
dictionaries EXACT CC. Corrupt selector negative rejected (return1).
Whole-machine lint/build PASS with the inherited Verilator5.044 PROCASSINIT
compatibility flag; initial omitted-flag failures preserved. Specfetch
PASS522postCuda cycles and6MB memtest PASS27,333,623postCuda cycles,zero
errors,exactCC.
300M ROM lockstep PASS481,830,131postCuda cycles;all progress/final state and
device counters EXACT CC,25I-device fetches. Full70 OFF seed1
`seed_cache_word_select_no_retiming`, runnerPID2345326, completes
compile0/multicorner0:37,930ALMs(91%)/38,816registers/338RAM/48DSP.
CPUhot-2.513ns/cold-2.055ns (59.53MHz),worseCC60.28MHz. MEM100hot-0.757ns/
cold-1.182ns;hold passes all corners,min+0.082ns. Worst CPU path now
IDpayload owner -> EXoperand bank. All118 postbuild input hashes match;
reports archived under `quartus/full_no_retiming/`. Reject integration:
selection logic expands and CPU/memory setup fail. No deployment. Source
`/tmp/macppc7300-cache-word-select-src`, evidence
`Scratch/perf/cache_word_select/`. RootAT remains unchanged.

CE (WB-load-format), isolated directCC fork, excluding CD. Capture the raw
memory window and its saved byte-format controls in WB, then select bytes
and sign extension after the register. EX already waits for a load in WB,
so latency, forwarding and retirement keep their cycles. The original
pre-WB formatted value independently checks every valid WB result.
Normal and full inherited collision-poison CPU suites PASS;all63 normal
instruction/cycle counts and all16 complete performance cycle/event
dictionaries EXACT CC. Inherited CPU poison edits independently compared
and identical. Lint PASS with inherited PROCASSINIT compatibility flag.
Load-producing corrupt raw-data negative rejected by original WB observer
(return1);the arithmetic-only golden did not exercise load corruption.
Specfetch PASS522postCuda cycles;6MB memtest PASS27,333,623postCuda cycles,
zero errors,exactCC. 300M ROM lockstep PASS481,830,131postCuda cycles;
all progress/final state/device counters EXACT CC. Zero completed host
disk-block transfers; this is not OS boot or disk-DMA coverage.
Full70 OFFseed1 `seed_wb_load_format_no_retiming`, runnerPID2354580,
finished compile0/multicorner0,16m11. All118 postbuild input hashes match;
only CPU and MU differ fromCC. 36,286ALMs(87%)/38,903registers/338RAM/48DSP.
CPUhot-3.236ns/cold-3.445ns (56.40MHz),MEMcold-0.066ns;
all-corner hold passes,min+0.074ns. Worst EXoperand bank -> BTBvalid.
Reject integration; reports archived under `quartus/full_no_retiming/`.
Source `/tmp/macppc7300-wb-load-format-src`, evidence
`Scratch/perf/wb_load_format/`. No integration or deployment.

CF (WB-format-compact-ID), BY original ID capture plus CC cache bus address
and CE WB formatting; excludes CA/CB ID payload/decode banks and CD selectors.
Normal/poison CPU suites PASS;all63 counts and16 complete perf dictionaries
EXACT BY. Poison edit set independently matches inherited BY. Lint/machine
build PASS with PROCASSINIT compatibility. Negative and machine runs NOT
STARTED. Full70 OFFseed1 `seed_wb_format_compact_id_no_retiming`,runner2367863,
completed compile0/multicorner0,15m17;all118 postbuild hashes match.
36,589ALMs87%,38,319registers338RAM48DSP;CPUhot-2.882/cold-2.401ns58.25MHz,
MEMcold-0.143ns,hold min+0.092ns. Worst WBraw result -> Dcache bus-address.
Reject integration; functional negative/machine runs remain NOT STARTED.
Reports archived. Source
`/tmp/macppc7300-wb-format-compact-id-src`,evidence
`Scratch/perf/wb_format_compact_id/`. No integration or deployment.

CG implements the earlier proposed control cut: pipeline BTB training writes
with pending/landed forwarding for validity, metadata, target and LRU.
BP's worst path is late EX completion -> 64-bit validity bank updates.
Forwarding must preserve the original predictions and replacement choices
including back-to-back same-row writes and invalidations; require an
original predictor shadow and negative collision controls before timing.
CG normal/poison, all63 and16 complete perf counts exactCF, independent
target-corruption negative and trained-branch-to-nonbranch clear test pass.
All6 predictor coverage bits seen. Lint/machine/specfetch/memtest pass;
300M local81122 running. Remote full70 OFFseed1 runner2384496 running after
118 input hashes verified. Source `/tmp/macppc7300-btb-training-src`,
evidence `Scratch/perf/btb_training/`. No integration or timing claim.

Root remains verified AT; none of these timing-failing candidates is deployed.

Provisional fixed-clock board comparison: matched full projects at 60 MHz
are prepared under `/tmp/macppc7300-{at60,baseline60}-full-seed1/` and remote
`seed_{at60,baseline60}_comparison/`. All sources outside the CPU match.
Baseline CPU SV/QIP hashes were checked against original commit `0186181`;
AT matches the integrated verified CPU. Root clock remains 70 MHz.
Both seed-1 builds and four-corner reports have completed.
AT60 seed 1 fits at 34,173 ALMs (82%), 37,775 registers, but CPU60 misses
hot setup by -0.104 ns (59.63 MHz). MEM100 passes (+0.229 ns minimum),
all-corner hold passes (+0.077 ns). AT60 seed 2 is worse: CPU 58.62 MHz /
-0.393 ns and MEM100 cold 98.07 MHz / -0.197 ns; hold +0.069 ns. Baseline60
seed 1 fails CPU60 at 57.63 MHz / -0.687 ns; MEM100 passes (+0.098 ns),
hold +0.073 ns. Baseline60 retiming-on seed 2 also fails CPU (-1.119 ns)
and cold hold (-0.107 ns), despite MEM100 setup passing. Reports are archived
in `Scratch/perf/{at60_comparison,baseline60_comparison}/`.

Matched AT55 and original baseline55 projects pass all-clock setup and hold
across all four corners. Actual derived clocks are CPU55/MEM100; no
unconstrained clocks, stock I/O partially unconstrained. Retiming off, seed 1;
sources outside the CPU match, remote hashes match manifests exactly.
AT55 uses 33,822 ALMs / 37,643 registers / 346 RAM / 48 DSP, CPU minimum
+0.981 ns, MEM +0.186 ns, hold +0.087 ns. Baseline55 uses 33,129 ALMs /
37,963 registers / 322 RAM / 48 DSP, CPU +1.528 ns, MEM +0.034 ns,
hold +0.082 ns. Reports, RBFs and validated manifests are in
`Scratch/perf/{at55_comparison,baseline55_comparison}/`.
AT55 RBF SHA256 `78e81b9b1104920efbd394257c2abe420b34c6af09c64b0b6283dd77a84ace9d`;
baseline55 `cc34ce968b21c7103946f66b509bb413b4ac0af94f50417f7924517911a3b583`.
AT55 is now loaded temporarily on the authorized MiSTer, with the prepared
Quadra disk, RAM120/16-inch monitor/Ethernet off/L2 off for fixed comparison.
OS8.1 reaches startup and its desktop background, but Finder reports
`The disk "Mac" cannot be used, because it cannot be found.` No desktop icons
or Speedometer score yet. The disk has only one Apple_Driver43 partition;
whether this is image compatibility or a CPU/machine issue is unproven.
Clean shutdown returns the same missing-disk alert. Finder recovery reaches
its force-quit dialog but cannot establish a clean power-off, including
normal and system shutdown key attempts. The board remains on AT55;
no baseline boot comparison yet. A full 2,146,461,696-byte recovery copy is
complete as `quadra_at55_recovery_backup.hda`. Active disk and recovery copy
MD5 both equal `d25de0d4f724a359d71fd91ed6ad4d85` (guest startup modified
the test image from its staged MD5). Explicit approval is pending to override
the no-reload-while-mounted rule for this backed-up disposable copy. Do not
reset while approval remains pending. Session: `Scratch/perf/board55/session.json`.
Read-only recheck at06:54PDT confirms live core name MacPPC7300 and the
Force Finder to quit confirmation still displayed. Screenshot
`Scratch/perf/board55/at/recovery-status-20261010-0654.png`; no input/reload
was sent, and clean shutdown remains unproven.
Original Downloads ZIP and locally prepared source remain untouched.
Read-only inspection of the local prepared image finds both m68k/pwpc PEF
headers in Finder8.1 and System8.1, and a pwpc PEF header in Speedometer4.02.
This excludes an absence of PowerPC fragments in those files; it does not
establish complete image compatibility or explain the missing-disk alert.
MDB, root-folder catalog key and root-thread name all consistently say Mac.
Fork hashes/header offsets: `Scratch/perf/board55/quadra-finder-system-inspection.json`.
Screenshots:
`Scratch/perf/board55/at/`. Main remains unchanged.
Only temporary project CPU/PLL frequency differs; root stays 70 MHz. A lower-clock board
comparison can establish provisional architecture performance and boot
behavior; it does not fulfill the 70 MHz or fixed-70 2x acceptance.

The RAM-based BTB experiment at `/tmp/macppc7300-btb-ram-src` passes the full
CPU suite, lint and all 16 unchanged cycle counts. Diagnostic F finishes at
16,558 ALMs / 12,694 registers, 54.19 MHz worst case (-4.136 ns at 70 MHz):
2,625 fewer ALMs than E, but no overall timing improvement. Its worst path is
forwarded effective address -> DBAT translation -> D-cache admission.
The 6 MB machine memtest passes. `Scratch/perf/btb_ram/specfetch-ram.py`
trains both the loop and call for synchronous prediction: 150 instruction
machine lockstep passes with one discarded I-fetch and one matched device
read. The original single-training program has no I-fetch coverage with F.
The first synchronous FP-register candidate at `/tmp/macppc7300-fpr-ram-src`
passes the CPU suite, lint, all 16 unchanged counts, 6 MB memtest, and 300 M
ROM/disk lockstep (436,875,363 post-Cuda cycles). Diagnostic G finishes at
16,138 ALMs / 13,268 registers, 49.76 MHz (-5.783 ns). Its three-read array
does not infer additional RAM; ID admission -> FP read selection is worse.
Keep G out of root. An explicit three-copy single-read FP RAM candidate at
`/tmp/macppc7300-fpr-ram-explicit-src` passes the CPU suite, lint, all 16
unchanged counts and trained I-fetch regression. Diagnostic I finishes at
14,744 ALMs / 10,624 registers, 58.39 MHz (-2.778 ns); its map confirms
three 32x64 M10K simple dual-port RAMs (six physical blocks).
A registered one-page data-translation candidate at
`/tmp/macppc7300-dtranslation-src` passes the full CPU suite and lint.
Warm throughput is retained; the 16 full-length cases cost 0-4 extra initial
lookup cycles. The faulting-walk test exercises 1,999 cancellations and
passes; removing the sticky cancellation guard fails. The combined explicit
FP RAM/data-translation candidate at `/tmp/macppc7300-dtranslation-ram-src`
passes CPU/lint, checked performance, memtest and 300 M ROM/disk lockstep.
Diagnostic J finishes at 14,781 ALMs, 53.10 MHz (-4.548 ns).
The successful RAM/data-translation changes are now included in root Z.
Archives: `Scratch/perf/btb_ram/`, `fpr_ram/`, and `data_translation/`.
Both original full-machine seeds have finished with area failures: seed 1
needs 45,475 ALMs / 4,576 LABs against 41,910 / 4,191 available. The original
standalone CPU also finishes: 24,512 ALMs, 43.85 MHz worst case, -8.349 ns
setup. Reports: `Scratch/perf/architecture/quartus/`. Its path is D-cache
tags -> response -> memory descriptor/next-word address -> MMU -> ID/fetch
readiness. With the memory-unit cut and retiming on, the standalone CPU
improves to 52.35 MHz, -4.655 ns setup, at 25,749 ALMs. Its new worst path
is ID decode -> forwarded operands -> completion ALU -> completion FIFO.
The memory-unit cut removes the response-dependent address mux
and captures the fallback next-word address on acceptance. The complete
CPU suite, lint and 16 checked mixes pass; all 16 cycles are unchanged.
Evidence: `Scratch/perf/timing_cut/`. The retiming-off CPU comparison
(`cpu_diagnostic_c/`) finishes at 19,958 ALMs, 50.33 MHz worst case,
-5.582 ns setup, with the same decode/operand/ALU critical family.
`seed_cut_no_retiming/` (full machine, retiming off) finishes with routing
congestion at 41,100 ALMs / 41,910 (98%), 44,412 registers, compile exit 3.
Report: `timing_cut/quartus/full_no_retiming/MacPPC7300.fit.rpt`. CPU totals
20,136.6 ALMs, including 11,592.1 ALMs / 12,278 ALUTs / 14,467 registers
in its control, register files and predictor (excluding submodules). Each writes its
`compile.log` / `compile.exit` or `diagnostic.log` / `diagnostic.exit`.
The comparison addresses the CPU's own ALUTs growing 11,765 -> 23,234
during physical synthesis. Main QSF, clock, and SDC are untouched.

Current checkout additionally registers the completion ALU's operands and
control, reserves its FIFO entry at admission, and writes the value one
cycle later. The pending result forwards into the next registered operands,
preserving dependent throughput. The complete CPU suite, full lint and all
16 checked cases pass; cycle counts are unchanged. Source hashes and logs:
`Scratch/perf/completion_stage/`. The standalone `cpu_diagnostic_d/`
finishes at 19,806 ALMs, 52.99 MHz worst case, -4.587 ns setup. The new
path is WB forwarding -> effective-address adder -> MMU translation ->
pipeline readiness (469-load ID-to-EX enable). Full-machine
`seed_completion_stage_no_retiming/` finishes with routing failure at
41,200 ALMs / 44,514 registers (compile exit 3), retiming off. Local machine
bench: `/tmp/macppc7300-completion-stage-machine/machine_ref/machine_tb`.
A 300 M instruction ROM/disk lockstep with the prepared Quadra disk and
16 MB RAM fails with the ACK-owner fix below (log
`/tmp/macppc7300-ack-owner-quadra300m.log`). The old 60 M run was too
short for the documented ~150 M chime wait and ~200 M OS start.
The attempted 120 MB lockstep diverges at instruction 15,778, FFF04360,
identically before and after the ALU-stage cut. The reference maps RAM flat;
the machine models Hammerhead bank placement during ROM sizing. Use the
documented 16 MB lockstep gate and a separate non-lockstep 120 MB bank test.
That non-lockstep 3 M check passes and confirms bank bases 0, 64, 96 and
112 MB (`completion_stage/verification/machine-bank120.{log,dev}`).
The initial longer 16 MB run reached NanoKernel code and failed a device
comparison at 175,866,608 instructions / 68065E98 (F8000020 read missing
from the bench's queue). It is archived as `quadra-rom-device-mismatch.log`.
The bench now snapshots CPU accepted transfers and DMA data before the
rising edge rather than after ownership/buffer advancement. That alone
reproduces the same failure and is not its resolution.

Current checkout additionally retains a memory ACK's saved I/D owner,
delivers it only while that transaction is busy, and drains a still-high
ACK before presenting the next request. A short checked test with an ACK
held one extra cycle fails before this fix at instruction 7: r3 receives
instruction word 38840001 instead of data 42. After the fix, all 8,009
instructions match. `acktest` / `--ack-hold` and three suite cases cover
I/D turnover and doublewords with snoops. The complete CPU suite passes;
lint, real-604 vectors and all 16 full-length checked mixes also pass;
cycle counts are unchanged. The corrected 6 MB machine memtest passes
with zero errors. New machine
bench: `/tmp/macppc7300-ack-owner-machine/machine_ref/machine_tb`.
Archive/source metadata for this revision is in `Scratch/perf/ack_owner/`;
older Quartus snapshots exclude the fix. Its longer ROM run still reproduces
the same F8000020 comparison at 175,866,608 instructions, so the held-ACK
fix is a separately proven bug fix, not a resolution of that boot check.
The original `0186181` machine is reconstructed read-only under
`/tmp/macppc7300-baseline-machine-src`, binary under
`/tmp/macppc7300-baseline-machine/machine_ref/machine_tb`; its matched
300 M check passes with identical state and device accesses (469,681,030
cycles after Cuda reset; `verification/baseline-quadra300m.log` in the
ACK-owner archive). Current-core bounded cache/retire trace reproduces the
failure (`/tmp/macppc7300-ack-owner-device-trace.log`). It confirms a data
request at physical F8000020 and r4 = 90000000, the motherboard ID, while
the reference's device queue has no matching access. Diagnose the bus/cache
and queue tracking before attributing the failure to the load's value.
Bounded CPU-bus logging confirms that this is an uncached request (ci = 1,
no cache hit), with req/ack high at F8000020 and data 90000000. Log:
`verification/quadra-device-bus.log`. The queue-diagnostic rerun fails with
three entries: an unrelated 6806D940 line read, then the correctly acknowledged
F8000000 and F8000020 word reads (`verification/quadra-device-queue.log`).
The bench now captures the ACK's saved I/D owner and enqueues only data
transactions for the interpreter's data-device comparison. New
`progs.py specfetchrom` reproduces the failure at instruction 40: an I-owned
68000400 speculative line blocks the D-owned F8000020 read. With the bench
fix, the same 100 instructions pass with one instruction fetch counted
separately and one device read compared. Before/after logs are archived.
The fixed-bench 300 M Quadra-disk run passes with identical state and device
accesses: 435,386,869 post-Cuda cycles; 16 instruction fetches outside RAM
and ROM counted separately. Archive: `verification/quadra300m-pass.log`.
No disk blocks were accessed, so this proves the long ROM/NanoKernel path,
not a booted Quadra OS or a Speedometer measurement. Elapsed cycles and
timer-driven paths differ from baseline; the 300 M cycles are not the 2x performance test.
No RTL changed for this bench fix.
These machine-only
logging changes are newer than the archived C++ hash;
preserve that distinction when updating verification metadata.

The memory-descriptor-buffer experiment is parked under
`Scratch/perf/memory_descriptor_experiment/` and removed from the checkout.
Its architectural-result tests pass, but early MEM ownership makes
interrupts wait for older memory operations and eliminates pre-grant
data-walk cancellations. The existing cancellation coverage fails; it was
not weakened. Revisit this timing cut after the boot regression is resolved,
with an explicit decision on interrupt boundaries and meaningful coverage.
A revised isolated experiment now lives in `/tmp/macppc7300-elastic-irq-src`.
It buffers the descriptor and accepts an interrupt in MEM only before the
first bus grant of the first micro-op, saving the operation's PC for retry
and leaving DAR/DSISR unchanged. Its reset suppresses the ungranted request;
the existing MMU cancellation drains the walk. Full suite
`/tmp/macppc7300-elastic-irq-suite.log`, lint and all 16 full-length performance
cases pass; every cycle count matches the ACK-owner revision. A stronger
faulting-walk case (IRQ period 97, 90% waits, seed 11) passes with 1,999
cancellations, but fails with the sticky cancellation guard removed
(expected 2,000 DSI counts, got 1). That case is now in `run_core.py` and
also passes on the root CPU. The candidate's 6 MB machine memtest and
speculative-fetch directed ROM pass. Its 300 M ROM/disk run also passes:
435,400,392 post-Cuda cycles, identical state and device accesses, no disk
blocks accessed (`quadra300m-pass.log`). Proofs and
metadata: `Scratch/perf/elastic_irq/`; positive and negative binaries are
separate. Remote `cpu_diagnostic_e/` measures this exact candidate at 70 MHz
with retiming off: 19,183 ALMs, 19,986 registers, 55.87 MHz worst case,
-3.612 ns setup. Root now matches those 16 SV source files exactly.
This is measured progress, not 70 MHz closure.

The board initially ran SharpMZ2500; the all-corner-passing AT55 build is now
loaded temporarily for testing. The user authorized taking it for temporary
testing after timing passes and trying a Quadra image from Downloads while
they obtain a PPC image. A copy of `~/Downloads/QuadSquad8.hda.zip` was
extracted to `/tmp/macppc7300-quadra-assets/QuadSquad8.hda`, volume renamed
Mac, with Speedometer 4.02 and Machine Records copied to the root (both
forks preserved with rb-cli). System Folder 8.1 remains blessed. The ZIP
is untouched. SCP completed successfully to
`games/MacPPC7300/quadra_test81.hda`; its exact size is 2,146,461,696 bytes.
Local and remote prepared-copy MD5 both match:
`9645f183ddb14eac752bbb43c23b30e0`. The bundled
ROM is staged as `boot0.rom`. MiSTer Remote was stopped; it is now started
for testing (restore it afterward). Main md5 `2f21ff276ebf429ab91a8b4e33314623`,
no MacPPC7300 string found; Main was initially unchanged.
On2026-10-10 the user explicitly requested installing the new Main, saving
the old binary and restarting it. Installed the bundled `releases/MiSTer`
(version261009,md5c641b24fec57a34de4b1b10b800a1639); old Main moved to
`/media/fat/MiSTer.before_macppc7300_20261010_0837`
(md52f21ff276ebf429ab91a8b4e33314623). Restarted Main asPID3507 with the
passingAT55 core; process/core identity and both binary hashes verified.
User's restart instruction resolves the previous reset-approval wait.
Active disk was still md5d25de0d4f724a359d71fd91ed6ad4d85, matching the
already fully verified `quadra_at55_recovery_backup.hda`. A redundant fresh
copy was stopped because synchronous SD writes were slow; its incomplete
file is `games/MacPPC7300/quadra_before_main_20261010_0837.partial`, not a
usable backup. Keep the newly installed Main; user requested the upgrade.
Screenshot `Scratch/perf/board55/at/main-installed-20261010-0840.png` shows
a flashing-question-mark startup disk. Main log confirms slot0 mounted
`games/MacPPC7300/quadra_test81.hda`; cause still unproven. No Speedometer.
Restore SharpMZ2500 and stopped Remote after testing. Portable benchmark tools use
`/tmp/macppc7300-board-venv/bin/python`, `MISTER_HOST=10.0.2.14`, and
`MISTER_KEY=/Users/alans/.ssh/id_ed25519_mister`.

Explicit board launch comparison after installing Main261009:
`_Unstable/AT55_Quadra81_test.mgl` points to passing AT55 and slot0
`quadra_test81.hda`; mount delay1s, reset delay2s/hold1s, no setname override.
Main process confirms MGL argument, selected disk and MacPPC7300 identity.
Still startup-disk icon; screenshot `board55/at/mgl-first-20261010.png`.
Then staged the all-corner-passing original0186181 CPU55 as
`_Unstable/MacPPC7300_baseline55.rbf` (sha256cc34ce968b21c7103946f66b509bb413b4ac0af94f50417f7924517911a3b583),
loaded `Baseline55_Quadra81_test.mgl` with the same slot0 image and settings.
PID3848, coreMacPPC7300, CFG1c000000000000000000000000000000 unchanged.
Baseline also remains at blinking startup-disk icon after its scan; screenshots
`board55/baseline-new-main-{first,later}.png`. No successful OS boot or scores
from either CPU under newMain, so this does not implicate architecture changes
alone. Main holds the actual image open on fd5. Boot-metadata comparison
against pristine prepared image: driver/partition first96sectors identical;
changed prefix sectors98,99,105; volumeMac and blessedCNID3544 unchanged.
Filesystem mount attribute changed0100->0000 (dirty); write count44662->44729.
Evidence `board55/current-boot-metadata-comparison.json`.
A fresh image finished copying to `games/MacPPC7300/quadra_clean_test81.hda`;
2146461696bytes/md59645f183ddb14eac752bbb43c23b30e0 verified before loading.
`Baseline55_Quadra81_clean.mgl` explicitly selects it in slot0; PID4333
holds that exact disk open. Baseline55 reaches the MacOS8.1 desktop, responds
to keyboard/mouse, and shows QuickTime startup warnings followed by
"The disk Mac cannot be used, because it cannot be found." Dismissing the
alert leaves no disk icon; normal power-key shutdown returns the disk alert.
No successful Speedometer launch or clean shutdown confirmed. Leave this
mounted guest intact; do not reload based on a screenshot timeout. The first
screenshot timed out while Main subsequently generated a valid PNG, proving
that capture failure alone does not establish power-off. Screenshots:
`board55/baseline-clean-{first,after-click,power-dialog2}.png`; actual state
in `board55/session.json`. Source ZIP and prepared local image unchanged.
The bundled `releases/boot0.rom` is the documented 7300 ROM; use it for
ROM lockstep instead of treating the ROM as unavailable. The new
full-machine lockstep runs pass 3,000,000 and 60,000,000 instructions with
identical state and device accesses; logs:
`Scratch/perf/architecture/verification/rom-lockstep{,60m}.log`.
The longer run still polls at `FF808764`; it does not prove NanoKernel or
disk boot. The corrected CPU also passes the same 60 M run with the Quadra
disk supplied, but no disk blocks were accessed; that is still only polling
coverage. The corrected full-machine 6 MB memtest passes: 19,660,841
instructions, 26,938,856 cycles after Cuda reset, zero errors. Log:
`Scratch/perf/timing_cut/verification/machine-memtest6m.log`.

The user authorized implementing all five findings of the CPU review and
created an active goal: first a measured 2x CPU speedup from architecture at
the same 70 MHz clock, with timing closure, then further timing work to raise
the clock. This supersedes the older request to ask again before hazard or
commit changes. Temporary board testing is authorized; release publication
is not; Main replacement/restart was subsequently explicitly authorized and
completed (see board notes above).

Work in progress in this checkout, based on `0186181`, 2026-10-09:

- Four-entry fetch response queue with one reserved outstanding slot and
  empty-queue bypass; requests depend on registered occupancy instead of
  downstream readiness. Redirects discard queued words and drain accepted
  requests. MMU instruction walks can be cancelled, and an ISI cannot
  overtake an older instruction-cache response.
- Cache RAM read address independent of the grant; untranslated page-offset
  set bits; dirty victims captured before speculative reads replace the
  RAM outputs. Pending-write conflicts and snoop priority retained.
- Memory requests accepted as operations leave EX, descriptor saved in the
  memory unit, response/next-request overlap. Independent warm L1 loads now
  sustain one per cycle. Same-line doubleword hits use one 64-bit access;
  uncached and crossing accesses keep the two-word fallback. Cache pending
  and colliding writes are forwarded by word/tag, enabling one cached store
  or store/load operation per cycle. Data walks can be cancelled before grant; cancelled
  faults are discarded. Existing WB forwarding and commit points retained.
- Two-way 128-entry BTB with folded indexing and speculative eight-entry
  return stack, restored from committed state on redirects.
- Eight-entry completion FIFO for speculative ALU work behind multiply,
  divide and FP operations. Decoder-declared side effects qualify candidates;
  older/younger writer masks resolve operands in order. Older entries drain
  through MEM/WB while younger ones append; EX status/memory commit waits
  for older entries. One redirect discards younger results. No dual issue or
  pipelined FP arithmetic yet.
- Simulation-only event accounting (`--profile`), fetch/response ownership
  assertions, checked performance programs (`verilator/perf.py`), and new
  interrupt/page-walk tests. The faulting-walk case observes 997 cancellations
  and fails when its cancellation guard is deliberately removed.

Read `docs/DSPPC604_plan.md`, "CPU performance goal", for exact results,
verification and the remaining work. The full CPU suite passes (535,481
random instructions in lockstep), the original execute-unit vectors pass,
and lint passes with Verilator 5.044's `PROCASSINIT` warning disabled for
existing machine initializers. Independent loads: 1.94x; load-use: 1.32x;
store hits: 2.76x; store/load: 2.41x; FP loads/stores: 3.82x/3.96x;
calls/returns with predictor conflicts: 1.98x; multiply/integer: 1.27x;
FP/four-ALU mix: 1.46x. Pure ALU and FP arithmetic throughput have barely
changed. Golden integer: 1.85 -> 1.80 CPI; golden FP: 3.46 -> 2.10 CPI.
The complete suite also passes with deliberately wrong RAM read/write
collision outputs. New overlap tests exercise simultaneous append/pop,
wraparound, younger overwrites, dependent next operands, interrupts and
FP-exception cancellation. **The overall
2x goal and 70 MHz timing closure are not achieved.**

Next: obtain Quartus area/path reports and full-machine timing at 70 MHz,
then fixed-clock board Speedometer results before choosing further issue,
load-use or arithmetic throughput work. All five areas have an implementation
validated in simulation. The first synthesis exposed an area failure and
a long response-to-translation path; the corrective fits above are running.
Do not count a higher clock toward the architecture target. Obtain full
Quartus timing and fixed-condition board Speedometer results before claiming
success. Quartus and board access are now available, and a Quadra disk is
prepared for testing; the extra 7300 CSV is still absent. No clock/SDC changes,
deployments, commits or pushes have been made in this session.

Local verification environment (macOS, not the older Windows environment):

    MACPPC7300_CACHE=/tmp/macppc7300-tests \
    MACPPC7300_BUILD=/tmp/macppc7300-final \
    MAKEFLAGS='DINGUS=/tmp/macppc7300-dingus HIDE=0' \
    python3 -u verilator/run_core.py

    make -s -C verilator lint \
      WARN='-Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PROCASSINIT'

The pinned, unmodified reference (`3f070249`) is extracted under
`/tmp/macppc7300-dingus`; its library is
`/tmp/macppc7300-tests/dingusref/libdingusref.a`. On macOS use `HIDE=0` to
avoid GNU linker/object-copy flags. Build outputs stay under `/tmp`; logs
and checked performance programs/results are also retained under
`Scratch/perf/`. `Scratch/perf/baseline/` uses the original architecture;
`Scratch/perf/architecture/` uses the current implementation. The baseline
binary is `/tmp/macppc7300-baseline-profile/core_ref/core_tb`.
Current CPU binary: `/tmp/macppc7300-final/core_ref/core_tb`; full suite log:
`/tmp/macppc7300-final-suite.log`. The checked benchmark runner is now part
of that suite, with required nonzero simultaneous overlap events. Current
results and verification logs are retained under `Scratch/perf/architecture/`.
Final standalone vectors and full lint pass. The full-machine 6 MB memory
test checks the CPU/cache/L2/CDC/SDRAM path; its latest result is recorded in
the CPU plan and `Scratch/perf/architecture/machine-memtest.log`.

Important clock trap: MacPPC7300.sv's PLL frequency ternary recognizes only
60 and 70, defaulting to 65. Setting CPU_MHZ to 75 or 80 alone would clock
at 65 while passing an incorrect CPU_HZ into the machine. After the 70 MHz
target, extend and verify both together and preserve the 20/100 MHz outputs.
The new cache and completion forwarding paths need actual timing reports;
removing the old grant-to-fetch-address dependency is no proof of closure.

Quartus handoff is prepared: `Scratch/cpu70_seed1/` and
`Scratch/cpu70_seed2/` are isolated full-machine projects at 70 MHz, with
multicorner analysis enabled and source manifests matching the verified CPU.
All 103 project/QIP input paths were checked using Tcl stubs; this does not
validate Quartus elaboration or settings. Run
`quartus_sh --flow compile MacPPC7300` in each copy on the Quartus host.
`syn/prepare_timing.py --out NEW_DIRECTORY --seed N` recreates a snapshot
only if the current CPU matches archived verification hashes. Existing
snapshots are never overwritten. The earlier `_before_declarations` copies
are obsolete; use the two directories above. Full lint/core/performance
checks pass after moving stall/done declarations before overlap uses and
including queued ALU results in the executed-uop event.

---

# Previous speed-session context (before this active goal)

(Rewritten 2026-10-10 at the end of the FPU session (builds 44-46) for a
Claude Fable session. It is the only resume prompt: everything it needs is
here or in the files it names; the board's tools, the Main, the rules and the
environment are at the end.)

