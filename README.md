# PPCMac_MiSTer

A PowerPC Macintosh core for the [MiSTer](https://github.com/MiSTer-devel) FPGA
platform. Work in progress: the CPU is built and verified, and the machine
around it (the Power Macintosh 7600) has begun: in simulation the 7600's own
ROM runs from reset into Open Firmware. The bitstream this tree builds runs
the CPU and the machine on the DE10-Nano with the SDRAM; its screen shows a
debug readout (rows of squares), not yet a Mac.

`PPCMac` is a working name and may change.

## Status

| Piece | State |
|---|---|
| Project skeleton (MiSTer framework, Quartus project) | the template's framework, unmodified; its demo logic replaced by the machine |
| Golden-vector test bench (Verilator) | working, one command |
| DSPPC604 integer execute unit | all 11,576 real-604 vectors pass |
| DSPPC604 floating-point unit | all 25,598 real-604 vectors pass, and all 64,013 of the 7300 run (non-IEEE mode, every exception enable, the whole `frsqrte` table); 1.8 million random vectors agree with the software model |
| DSPPC604 pipeline, user-mode integer code | the same vectors pass when run as a program, XER and the integer loads and stores of the 7300 run included; random programs match dingusppc instruction for instruction |
| Floating point in the pipeline | the FP vectors of both machines pass when run as a program; FP loads, stores and the FPSCR instructions as a real 604 does them (7300 run) |
| Exceptions, supervisor state | program, FP unavailable, system call, alignment, external and decrementer interrupts; MSR and the SPRs; SRR1, DSISR, the SPR set and the bits each keeps as a real 604 delivers them (7300 run); checked in lockstep and by directed tests |
| MMU | BATs, segment registers, hardware page-table walk with R and C bits, ITLB and DTLB, `tlbie`, DSI and ISI; directed tests and lockstep with translation on |
| `lwarx`/`stwcx.`, `dcbz`, cache instructions | done |
| Caches | two 16 KB four-way caches with 32-byte lines (the 604's shape), write-back, one line port to memory, a snoop port for DMA; directed tests and the whole suite through them |
| Clock crossing to the SDRAM controller | done, checked at several clock ratios; the controller itself comes with the machine |
| Timing and area pass | in progress: 55 to 64-65 MHz so far with eleven cuts that cost no cycles, plus the FPU operand register on (2 % of floating-point cycles) to take its forwarding path off the list; the slowest families now sit at the 66 MHz line and move across it with the fitter's placement; what remains and what it would cost is in [the plan](docs/DSPPC604_plan.md) |
| Machine: the 7600's address map and device stubs | `rtl/machine/`: Hammerhead, Bandit and Chaos configuration space, Grand Central (interrupt and DMA registers, VIA with timers, NVRAM, board register, SCC and sound registers) as register stubs that answer as dingusppc's devices do; [docs/PPCMac_stubs.md](docs/PPCMac_stubs.md) lists every stub and what it leaves out |
| The 7600's ROM in simulation | runs from the reset vector in lockstep with dingusppc for 150 million instructions with no difference; reaches Open Firmware, which after 18.3 million instructions waits for Cuda (the ADB/power microcontroller, not built) and polls for it forever |
| Memory-test boot program | selectable in place of the ROM; passes in the bench over 1 and 6 MB and finds an injected fault |
| SDRAM controller | `rtl/machine/PPCMac_sdram.sv`, adapted from Sorgelig's; passes its bench against a model of the 128 MB board that checks every command and timing |
| First bitstream | `PPCMac.sv`: CPU at 65 MHz, SDRAM at 100 MHz, ROM upload, OSD options, debug readout on screen and UART; on the board the memory test passes at every RAM size (6-96 MB) |
| Machine (video, SCSI, Cuda, sound, ...) | not started |

The first full build of the core (2026-10-06: the CPU at 65 MHz, the
machine, the SDRAM controller at 100 MHz, the debug readout, the MiSTer
framework), Quartus 17.0, slow 100 C model; this is the number that counts:

| Build | ALMs | RAM blocks | DSP blocks | CPU clock closes at |
|---|---|---|---|---|
| `PPCMac` with the memory test, 2026-10-06 | 24,757 of 41,910 (59%); the CPU 13,883, the machine 2,673, the SDRAM controller 367, the readout 455 | 144 of 553 (26%) | 40 of 112 (36%) | 64.59 MHz (65 MHz asked: slack -0.099 ns); memory 107.3 MHz (100 asked) |

On the board (DE10-Nano, 128 MB SDRAM) the memory test passes at every RAM
size the OSD offers (6 to 96 MB, three or more passes each, no error) at
65 MHz.

Each block synthesised on its own for the DE10-Nano's FPGA with Quartus
17.0 (`syn\check.py`), constrained to 75 MHz:

| Block | ALMs | DSP blocks | Worst-case Fmax |
|---|---|---|---|
| The whole CPU (pipeline, FPU, exceptions, SPRs, MMU, two 16 KB caches), after the timing pass's eleven cuts and the FPU operand register (2026-10-06) | 15,678 (37%), 77 RAM blocks | 7 | 63.7-64.8 MHz (two fits) |
| The same when the caches were first added | 14,234 (34%), 77 RAM blocks | 7 | 55.2 MHz |
| The same before the caches | 12,049 (29%) | 7 | 61-65 MHz (three runs) |
| The same before the MMU | 10,781 (26%) | 7 | 69.5 MHz |
| The integer pipeline alone, before the FPU was connected | 3,208 (8%) | 3 | 78.6 MHz |
| Floating-point unit alone | 3,303 (8%) | 4 | 73.5 MHz |

So the CPU is above its 50 MHz floor and below the 66 MHz target, and the
timing pass is in progress (the plan's M5 step 4 has every measurement).
The Fmax figure swings by 2-3 MHz between fits of near-identical designs;
the slowest paths, taken apart cell by cell, are the measure. What sets the
clock now is the data cache: its answer, made in the cycle after the
request from the tag RAM's output (2.5 ns of the 13.3), and its request
address for the second word of a misaligned access; then the cache's hit
decision through the fetch handshake into the redirect. The register files
and SPRs are still flip-flops, the main area to be had.

## Decisions that are locked in

These were agreed before any RTL was written. Change them deliberately, here,
not by drift.

**Platform**

- MiSTer on the DE10-Nano (Cyclone V `5CSEBA6U23I7`), built with Quartus 17.0.x.
- `sys/` is the MiSTer framework exactly as in Template_MiSTer (commit
  `3ea1134`, 2026-08-26). It is never edited here.

**Machine**

- First target: the Power Macintosh 7600 (the 7300/7500/7600/8500/9500 board
  family), with its single internal SCSI controller. The reference ROM is the
  one dumped from a real 7600: version `077D.28F2`, Open Firmware 1.0.5.
- Long-term goal: the Apple/Bandai Pippin (a PowerPC 603).
- This CPU will be a good deal slower than a real 604 (see below), so the
  first machine may yet change to something more modest. Nothing
  machine-specific goes into the CPU.

**CPU**

- The CPU is `DSPPC604`: a 32-bit PowerPC 604-class core. Standard PowerPC
  user and supervisor instruction set, hardware page-table walk, no POWER
  instructions.
- In-order and pipelined from the start. No out-of-order execution, no
  register renaming. Multi-cycle work (multiply, divide, floating point)
  happens in execute units behind a request/response handshake, so the
  pipeline never needs special cases for them.
- The floating-point unit is a separate module with its own request/response
  interface. It can be tested alone, the integer side alone, and the two
  together. It is meant to be reused by later CPU models.
- The execute units hold no architectural state. Whatever wraps them (the test
  wrapper today, the pipeline later) owns the registers and commits results.
- Each CPU model gets its own named version: `DSPPC604` first, then
  `DSPPC603` (the Pippin's CPU: software TLB reload), `DSPPC750` (G3) and
  `DSPPC601` last. A new model may start from an existing one or instantiate
  its modules; module and file names carry the model they belong to
  (`DSPPC604_fpu`, `DSPPC604_int_unit`, ...).
- Built-in caches: yes. A pipelined CPU on MiSTer memory needs instruction and
  data caches in block RAM. The cache line is 32 bytes, as on the 604, 603 and
  750, because `dcbz` makes that size visible to software. Anything else that
  reads or writes memory (DMA, the HPS) goes through the CPU's snoop port
  first; that is the whole coherence protocol.
- Clock target: 66 MHz, 75 MHz if it can be had; 50 MHz is the floor.
- Results the architecture leaves undefined follow the real chip where we have
  data. Divide by zero and `0x80000000 / -1` return what a real 604 returns.

**Language and tools**

- SystemVerilog, limited to what both Verilator 5.020 and Quartus 17.0 accept:
  `logic`, `always_ff`/`always_comb`, packages, enums, packed structs. No
  interfaces, no classes.
- No vendor primitives inside the CPU. Multipliers and memories are inferred.
- Verilator is the verification tool. The RTL is kept clean under `-Wall`.

**What counts as correct**

- Real hardware outranks every emulator. Of the emulators, dingusppc is
  trusted most; QEMU is the more careful floating-point reference; MAME is not
  used for floating point.
- The golden data is 37,174 single-instruction vectors recorded twice,
  bit-identically, on a real PowerPC 604 (PVR `00040303`) in a Power Macintosh
  7600: `ppctest/runs/results_604_run2.csv`; and the 79,624 vectors of the
  version-4 set (those again, plus 39,025 the software model had predicted
  and 3,425 with no prediction) recorded on a 604 of the same revision in a
  Power Macintosh 7300, identical to the 7600 where they overlap:
  `ppctest/runs/results_604_7300_of_run1.csv`. The same run's second stage,
  10,772 supervisor-mode sequences recording what every kind of exception
  saves, which SPRs and opcodes exist and which bits each register keeps, is
  `sresults_604_7300_of_run1.csv`.

**Memory**

- Main memory lives on the MiSTer SDRAM module; a 64 MB or 128 MB module is
  expected. The machine's installed RAM is a core option: 6, 16, 24, 32, 64
  or 128 MB (6 MB is the Pippin's). The caches fill their lines from the
  SDRAM, so the cache line-fill bus is designed for that controller.

**Still open**

- Whether part of the CPU could run on the DE10-Nano's ARM. Not planned; the
  floating-point unit's request/response boundary is where such a split would
  go if it is ever needed.
- Which machine the first release actually models.

## How fast will it be

An in-order core at 66-75 MHz executes somewhere around one instruction per
1.3-1.6 clocks once caches are warm. That is the territory of a Power Macintosh
6100/60 or a Pippin, and roughly a third of a real 7600/120, whose 604 issues
several instructions per clock. Measured numbers will replace this estimate
when the pipeline runs real code.

## What the real 604 turned out to do

Measured on the chip, and reproduced by the RTL:

- Divide by zero returns the dividend shifted left four bits, with the low
  four bits 0000 for a negative signed dividend and 1111 otherwise.
  `0x80000000 / -1` returns 1.
- `fres` is not an estimate. It is a full divide of 1.0 by the operand,
  rounded to single precision, with every status bit a divide would set.
- `frsqrte` is a 32-entry table with seven fraction bits, indexed by the low
  exponent bit and the top four fraction bits; every entry is measured.
- `fctiw` and `fctiwz` write `FFF80000` to the upper word of the result, with
  the lowest bit set when a negative operand converts to zero. `mffs` writes
  the same upper word.
- When a disabled overflow delivers infinity or the largest number, FPSCR[FR]
  is left as the rounding of the significand set it.
- Single-precision instructions clear the 29 payload bits of a NaN result
  that a single cannot hold.
- Non-IEEE mode (FPSCR[NI]) flushes a result that would be denormalised to a
  signed zero and calls it an inexact underflow; denormal operands are
  computed with as usual, whatever the manual's table says.
- An enabled underflow or overflow in single precision whose scaled
  exponent still does not fit a double (the architecture: undefined) delivers
  the exponent field with bit 10 as bits 11 and 10 of the wider internal
  exponent XORed, and classes the result as normal.
- `stfs` denormalises for every exponent of 896 or less, so anything below
  the single denormal range, double denormals included, stores a signed zero.
- XER keeps `E000FF7F` (bits 16-23 too); MSR keeps `0005FF77` (bit 29, PM,
  is implemented); SRR0 keeps bits 0-29, SDR1 `FFFF01FF`, EAR `8000003F`,
  PIR four bits, the BATs `FFFE1FFF` and `FFFE007B`.
- The SPRs it has: 1, 8, 9, 18, 19, 22, 25, 26, 27, 268, 269, 272-275, 282,
  284, 285, 287, 528-543, 952-955, 959, 1008, 1010, 1013, 1023. Any other
  number is an illegal instruction in user mode as in supervisor mode, not a
  privileged one as the manual says. `mfspr` 268/269 reads the time base in
  user mode.
- `stwcx` without the record bit is illegal; other instructions without a
  record form ignore bit 31; `tlbia`, `tlbld`, `tlbli` and an opcode-17 word
  without bit 30 are illegal; `FFFFFFFF` is a valid `fnmadd.`.
- SRR1 holds only the MSR bits for `sc`, FP unavailable, alignment and DSI;
  a pending enabled FP exception taken at a later instruction sets SRR1[15].
  The alignment DSISR carries rD and rD - 1 (8 and 7 for `dcbz`) where the
  architecture says rD and rA. Trace saves `40000000` and the MSR, the IABR
  the breakpoint's own address.
- `lwarx`/`stwcx.` on a cache-inhibited page take no DSI; `dcbz` there is an
  alignment exception; a load beyond the installed memory returns 0 and no
  exception.

Apart from these, the 604 follows the architecture manual to the bit. The 34
vectors where it differs from dingusppc are 24 undefined divides and 10
`fmuls` cases where the chip is simply correctly rounded. The RTL reproduces
all of the above; `docs/DSPPC604_plan.md` has the details and what the
tests still do not cover.

## Running the tests

```
python verilator\run.py
```

Builds the Verilator model (under WSL on Windows) and replays every golden
vector through the execute units, printing pass counts per instruction and
each mismatch with the fields that differ. Useful options: `--only int`,
`--only fp`, `--name ADDE,DIVW`, `--show 20`, `--variants`, and
`--csv ppctest\runs\results_604_7300_of_run1.csv` for the 7300 run (its
loads, stores and moves to and from XER and FPSCR are reported as
unimplemented here and run by `run_core.py`).

Divides whose result the architecture leaves undefined are counted apart from
the rest, so they can never hide a real failure or be hidden by one.

```
python verilator\run_core.py
```

Tests the pipeline, and the memory path behind it, seven ways:

1. The real-604 integer vectors, assembled into one program and run with and
   without random bus wait states.
2. The real-604 floating-point vectors, the same way; then both halves of the
   7300 run, whose loads and stores get a buffer each.
3. Random floating-point programs (arithmetic, loads, stores, FPSCR
   instructions) with the state `fpmodel.py` expects after every instruction.
4. Each exception once, with what its handler must find; address
   translation with every cause of DSI and ISI and the page table's R and C
   bits; `lwarx`/`stwcx.`, `dcbz` and the cache instructions; the caches
   (evictions, write-back, every cache instruction and HID0 bit seen
   through a cache-inhibited alias, self-modifying code, DMA through the
   snoop port); and a loop with known results under thousands of external
   and decrementer interrupts.
5. Random programs in lockstep with dingusppc's interpreter
   (`verilator/ref` builds it as a library from `..\dingusppc`), including
   supervisor instructions, mode switches and exceptions: the registers and
   MSR are compared after every instruction and memory at the end. Then the
   same with address translation on, page faults included.
6. The memory port carried across a clock boundary, at several clock
   ratios.
7. The SDRAM controller (`rtl/machine/PPCMac_sdram.sv`) behind the clock
   crossing, against a behavioural model of the 128 MB board in
   `verilator/sdram_main.cpp` that holds the data and checks every command
   and timing: the power-up sequence, tRCD, tRP, tRAS, tRC, tWR, tRFC,
   refresh at 7.8 us, bus turnaround; random line and word requests and a
   ROM upload, every read checked and the whole 128 MB compared at the end.

`--seeds N` runs more random programs.

```
python verilator\run_machine.py --max-instr 30000000 --progress 1000000
python verilator\run_machine.py --boot memtest --memtest-passes 2
```

Runs the whole machine (`PPCMac_system`: the CPU, the 7600's address map and
device stubs, the clock crossing, and a software memory in its own clock
standing in for the SDRAM) on the 7600's ROM from the reset vector, in
lockstep with dingusppc: every device read returns the same value to both
(the reference has no devices; it is handed what the machine answered), and
the registers and MSR are compared after every instruction. About 400,000
instructions a second. `--dev-log FILE` writes every device access;
`verilator\machref` runs dingusppc's whole 7600 (all its devices, headless)
and writes the same log, and `verilator\machref\devdiff.py` compares the two
to show where the stubs answer differently. The second command runs the
memory-test boot program instead of the ROM (1 MB unless `--ram`;
`--mem-fault ADDR` must be found).

```
python verilator\fpmodel.py check
python verilator\fpmodel.py random 300000 1 x.csv
python verilator\run.py --csv x.csv
```

`fpmodel.py` is a bit-exact software model of the 604's floating-point unit and
the specification the RTL was written to. `check` compares the model itself
with the hardware data (the 7600 file by default; give it the 7300 one for
the rest). `random` writes vectors (count, seed, file) with modelled results
in the golden CSV format, and `run.py --csv` replays them.
They reach datapath corners (random significands, enabled exceptions,
denormals, near cancellation) that the hardware set, which is heavy on special
values, does not.

```
python syn\check.py core
python syn\check.py fpu
python syn\check.py int
```

Synthesises the pipeline, the floating-point unit, or just the integer
decode-and-execute path on its own for the DE10-Nano's FPGA and prints its
size and maximum clock. `--paths 10` also lists the slowest paths.

## Layout

| Path | Contents |
|---|---|
| `PPCMac.sv`, `PPCMac.qsf`, `files.qip` | MiSTer core top level and Quartus project |
| `sys/` | MiSTer framework (do not edit) |
| `rtl/DSPPC604/` | the CPU |
| `rtl/machine/` | the machine: the 7600's address map and device stubs (`PPCMac_*`) |
| `rtl/pll.v`, `rtl/pll/` | the core's PLL (the template's, edited to three outputs) |
| `syn/mister.py` | puts the core and ROM on the MiSTer over SSH, sets options, loads, screenshots, reads the UART |
| `verilator/` | test benches (single instructions, programs on the pipeline, the whole machine) and the floating-point software model |
| `verilator/ref/` | dingusppc's interpreter as a library, for lockstep runs |
| `verilator/machref/` | dingusppc's whole 7600, headless, logging every device access |
| `docs/PPCMac_stubs.md` | everything the machine stubs, simplifies or leaves out |
| `syn/` | stand-alone area and timing checks |
| `ppctest/` | tool that builds the test disk for real Macs and decodes its results |
| `ppctest/runs/results_*.csv` | golden results from real hardware |
| `docs/` | plans and design notes |

## License

GPL-2.0-or-later, as the MiSTer framework.
