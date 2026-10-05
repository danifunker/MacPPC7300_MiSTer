# PPCMac_MiSTer

A PowerPC Macintosh core for the [MiSTer](https://github.com/MiSTer-devel) FPGA
platform. Work in progress: the CPU is being built and verified first, and
there is no machine around it yet. The bitstream this tree builds today is
still the MiSTer template's test pattern.

`PPCMac` is a working name and may change.

## Status

| Piece | State |
|---|---|
| Project skeleton (MiSTer framework, Quartus project) | imported, unmodified template |
| Golden-vector test bench (Verilator) | working, one command |
| DSPPC604 integer execute unit | all 11,576 real-604 vectors pass |
| DSPPC604 floating-point unit | all 25,598 real-604 vectors pass; 1.8 million random vectors agree with the software model |
| DSPPC604 pipeline, memory access, exceptions, MMU, caches | not started; see [the plan](docs/DSPPC604_plan.md) |
| Machine (chipset, video, SCSI, ...) | not started |

Size and speed of what exists, each synthesised on its own for the DE10-Nano's
FPGA with Quartus 17.0 (`syn\check.py`), constrained to 75 MHz:

| Block | ALMs | DSP blocks | Worst-case Fmax |
|---|---|---|---|
| Integer decode + execute, with the execute-to-execute forwarding loop | 901 (2%) | 3 | 92.4 MHz |
| Floating-point unit | 3,303 (8%) | 4 | 73.5 MHz (75.2 MHz at the hot corner) |

So 66 MHz is met with room, and 75 MHz is within reach but not yet met by the
FPU's rounding stage at the cold corner.

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
  750, because `dcbz` makes that size visible to software.
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
  7600: `ppctest/runs/results_604_run2.csv`.

**Still open**

- Whether part of the CPU could run on the DE10-Nano's ARM. Not planned; the
  floating-point unit's request/response boundary is where such a split would
  go if it is ever needed.
- Main memory: SDRAM module or the HPS DDR3.
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
  exponent bit and the top four fraction bits. The data confirms 8 of the 32
  entries; the rest follow the same rule and still need a hardware sweep.
- `fctiw` and `fctiwz` write `FFF80000` to the upper word of the result, with
  the lowest bit set when a negative operand converts to zero.
- When a disabled overflow delivers infinity or the largest number, FPSCR[FR]
  is left as the rounding of the significand set it.
- Single-precision instructions clear the 29 payload bits of a NaN result
  that a single cannot hold.

Apart from these, the 604 follows the architecture manual to the bit. The 34
vectors where it differs from dingusppc are 24 undefined divides and 10
`fmuls` cases where the chip is simply correctly rounded.

## Running the tests

```
python verilator\run.py
```

Builds the Verilator model (under WSL on Windows) and replays every golden
vector, printing pass counts per instruction and each mismatch with the fields
that differ. Useful options: `--only int`, `--only fp`, `--name ADDE,DIVW`,
`--show 20`, `--variants`.

Divides whose result the architecture leaves undefined are counted apart from
the rest, so they can never hide a real failure or be hidden by one.

```
python verilator\fpmodel.py check
python verilator\fpmodel.py random 300000 1 x.csv
python verilator\run.py --csv x.csv
```

`fpmodel.py` is a bit-exact software model of the 604's floating-point unit and
the specification the RTL was written to. `check` compares the model itself
with the hardware data. `random` writes vectors (count, seed, file) with
modelled results in the golden CSV format, and `run.py --csv` replays them.
They reach datapath corners (random significands, enabled exceptions,
denormals, near cancellation) that the hardware set, which is heavy on special
values, does not.

```
python syn\check.py int
python syn\check.py fpu
```

Synthesises the integer decode-and-execute path, or the floating-point unit,
on its own for the DE10-Nano's FPGA and prints its size and maximum clock.

## Layout

| Path | Contents |
|---|---|
| `PPCMac.sv`, `PPCMac.qsf`, `files.qip` | MiSTer core top level and Quartus project |
| `sys/` | MiSTer framework (do not edit) |
| `rtl/DSPPC604/` | the CPU |
| `rtl/` (other files) | template demo logic, to be replaced by the machine |
| `verilator/` | golden-vector test bench and the floating-point software model |
| `syn/` | stand-alone area and timing checks |
| `ppctest/` | tool that builds the test disk for real Macs and decodes its results |
| `ppctest/runs/results_*.csv` | golden results from real hardware |
| `docs/` | plans and design notes |

## License

GPL-2.0-or-later, as the MiSTer framework.
