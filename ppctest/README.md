# ppctest — PowerPC CPU test disk

Builds a SCSI disk image for a BlueSCSI. A program on it executes a set of
single-instruction test vectors on a real Power Mac and writes every result
back to the same image; the host tool then decodes the image. The program runs
two ways from the same image:

- **from Open Firmware**, booted with `boot scsi-int/sd@N:0`, with the console
  on a serial terminal;
- **under Linux** on the Mac, as a static executable carried on the disk.

Neither needs a firmware setting changed. From Open Firmware a **second stage**
follows the vectors: it dumps the Mac's ROM onto the disk and runs short
instruction sequences in supervisor mode, with the CPU's exception vectors
pointed at handlers of its own, recording what each exception saves.

Everything is Python 3 with no extra packages. Only the self-tests need WSL
(`qemu-ppc-static`, and dingusppc for the Open Firmware route).

## Build the image

```bash
python v4gen.py                                           # once: model-predicted vectors
python ppctest.py build --out TO_CARD/HD40_512_ppctest_v4d.hda
```

`HD40_512…` is BlueSCSI's naming for SCSI ID 4, LUN 0, 512-byte blocks; rename
for another ID. The image is about 80 MB because it has room for eight
separate runs, from either route, each with its second-stage results, plus
the ROM dump. (`rom-build` still makes the separate ROM-dump disk of version
4b; it is no longer needed.)

The version-4 vector set (79,624 vectors) is

| Source | Vectors | Expected value on the disk |
|---|---|---|
| `dingus-*`, `gen-*` | 37,174 | what the real 604 returned for them (`runs/results_604_run2.csv`); this is the whole version-3 set in its original order |
| `model` | 20,000 | `verilator/fpmodel.py random`: random arithmetic, all rounding modes |
| `model-enable` | 8,500 | model: overflow, underflow, zero divide, inexact and invalid with the matching FPSCR enable bits set |
| `model-ni`, `model-ni0` | 8,000 | model: denormal operands and results with FPSCR[NI] set, and the same vectors with it clear |
| `model-rsqrte`, `model-sweep` | 1,915 | model: `frsqrte` over every table entry, and finer `frsqrte` / `fres` sweeps |
| `model-mem` | 610 | model: `lfs`, `stfs`, `stfiwx` (and `lfd` / `stfd`) through a memory buffer |
| `v4-fpscr` | 2,989 | none: `mffs`, `mtfsf`, `mtfsfi`, `mtfsb0`, `mtfsb1`, `mcrfs` |
| `v4-xer` | 284 | none: which XER bits the register keeps, `mcrxr` |
| `v4-mem` | 152 | none: integer loads and stores, byte-reversed and string forms |

So on a 604 the program's `miss` count is the number of vectors on which the
processor disagrees with its own earlier run or with the model; on another CPU
it also counts every difference from the 604. Where the model says the
architecture leaves a result undefined, no expected value is stored.

`v4gen.py` imports `verilator/fpmodel.py` (it never changes it) and writes
`v4/model_random.csv`, `v4/model_targeted.csv` and `v4/MANIFEST.txt`, which
notes the model's SHA-256. Those CSVs are in the results format, so the
Verilator bench can replay them. `--set v3` builds the old set (dingusppc's
expected values, `--cpu 601` leaves out `fsel`, `fres`, `frsqrte`).

## Run it under Linux on the Mac

With the image on the BlueSCSI and Linux booted from another disk, as root:

```bash
cat /proc/partitions                             # find the test disk by its size (83968 blocks)
dd if=/dev/sdX of=p bs=512 skip=16 count=32      # the program, always at block 16
chmod +x p
./p
```

`./p` takes no arguments. It looks for its own disk (a `sim.hda` in the current
directory, then `/dev/sda`…`/dev/sdp`), recognises it by the image's build
number and writes nowhere else. It prints the disk it chose, one dot per 64
vectors (1,245), then

```
n=00013708 sum=XXXXXXXX miss=XXXXXXXX write=ok …
saved as run 1 of 8 on this disk
```

Each run takes the next free result slot, so after swapping the CPU card just
boot Linux again and type `./p` again: the runs sit side by side on the image,
each with a copy of `/proc/cpuinfo`. Shut Linux down cleanly before pulling the
card. `p` must be extracted again whenever the image is rebuilt.

No card shuffling at all, if the Mac is on the network: copy the image to the
Mac as `sim.hda`, run the same `dd` with `if=sim.hda`, run `./p`, copy
`sim.hda` back.

What the Linux program does that the Open Firmware one need not:

- it asks the kernel to turn floating-point exception traps off for the
  process (`prctl(PR_SET_FPEXC, PR_FP_EXC_DISABLED)`), which is what
  MSR[FE0,FE1]=0 does under Open Firmware, and prints a warning if refused;
- it catches SIGILL, SIGTRAP, SIGBUS, SIGFPE and SIGSEGV. One raised by the
  instruction under test is logged and stepped over (the decoder marks the
  vector `TRAP`); one raised anywhere else ends the run with its status saved.

## Run it from Open Firmware

On a 7300/7600 Open Firmware talks to the modem serial port unless its
settings were changed, so no setting needs changing: connect a terminal there
(38400 baud, 8N1, no flow control; a Mac printer cable to a Keyspan USA-28X on
another Mac, then `screen /dev/cu.USA28X…P1.1 38400`) and hold Cmd-Opt-O-F at
the chime.

1. At the `0 >` prompt: `boot scsi-int/sd@4:0` (`scsi-int` is the internal bus,
   the external one is `scsi`). The first `boot` of a firmware session may
   print `RESETing to change Configuration!` and restart the machine (the
   firmware moves itself to `real-base` F00000): hold the keys again and
   retype the command.
2. Same banner, dots and summary line as under Linux, then the second stage:

   ```
   stage2 v4d rom=................................................................860538E0 seq.......
   s2 n=00002A14 sum=9041A305 exc=00001FF3 write=ok
   ```

   `rom=` is followed by one dot per 64 KB and the dump's checksum (or
   `present` when an earlier run on this disk made the dump), `seq` by one dot
   per 16 sequences; `n` is the number of sequences run and `exc` the number
   of exceptions they took in all, both in hex.
3. Reset; one `boot` per session (a second one fails with `CLAIM failed`).

An Open Firmware run takes the next free result slot just as a Linux run does
(`ERR full` when all eight are used), and records the PVR, entry MSR and HID0
directly. Floating-point traps are off because the program clears MSR[FE0,FE1]
itself. The second stage runs only on a 604, 604e, 604ev or 750 (it says
`skipped` otherwise) and only from Open Firmware.

## Decode the results

```bash
python ppctest.py results FROM_CARD/HD40_512_ppctest_v4d.hda
```

For every run on the image this prints the CPU, the Linux run status
(floating-point trap mode, trapped vectors), a table of matches and
differences per vector source with the first few differing vectors, and a
comparison with the 604 reference run. It writes `runs/results_<cpu>_<machine>_runN.csv`
(for example `results_604e_7300_run1.csv`) and a `.txt` beside it; an existing
file is never overwritten. `--name WHAT` chooses the name, `--slot N` picks one
run, `--force` also decodes a run that did not finish.

An Open Firmware run also gets `runs/sresults_<same name>.csv` with the
second stage's records (see below), and the report ends with the state of the
ROM dump on the disk, which `rom-extract` takes out:

```bash
python ppctest.py rom-extract FROM_CARD/HD40_512_ppctest_v4d.hda --out runs/my7300.rom
```

```bash
python ppctest.py diff runs/results_604_7300_run1.csv runs/results_604e_7300_run1.csv
python ../verilator/fpmodel.py check runs/results_604_7300_run1.csv
python ppctest.py vector IMAGE 11F 120           # look up vector numbers printed on screen
```

`diff` compares two results files vector by vector; `fpmodel.py check`
compares any results file with the model as it is now.

## The second stage

`stage2.py` is a 4 KB program the boot program loads 64 KB above itself and
jumps to after the vectors, from Open Firmware only. It dumps the 4 MB ROM
at FFC00000 to the disk (once per disk; the dump is checked the same way as
the separate ROM-dump disk's), then runs the sequences `svectors.py` makes:
up to 32 instructions each, under a chosen MSR, with the exception vectors
pointed at the program's own handlers while they run. For every sequence a
256-byte record keeps r3..r12, CR, XER, CTR, LR, the final MSR, the first 64
bytes of a scratch buffer, and up to five exceptions with the vector, SRR0,
SRR1, DAR, DSISR and the MSR the handler was entered with. The sequence
groups:

| Group | Sequences | What they record |
|---|---|---|
| `probe` | 13 | MSR, SRR0/1, PVR, HID0, the segment registers and BATs as found |
| `spr`, `sr`, `bat` | 116 | read-back after writing two patterns into each supervisor register, with restore |
| `msr`, `rfi` | 63 | which MSR bits `mtmsr` keeps, which SRR1 bits `rfi` copies, what each entry MSR looks like |
| `exc` | 81 | what is saved for illegal, privileged, trap, `sc`, alignment, FP-unavailable, FP-enabled, protection and page faults, decrementer, trace, IABR, DABR (750) and performance-monitor exceptions |
| `lmw` | 16 | `lmw`/`stmw`/`lswi`/`lswx`/`stswi`/`stswx` edge cases |
| `sweep` | 8,435 | every extended opcode of primary opcodes 19, 31, 59 and 63 and every other primary opcode, in supervisor and in user mode: exception or not |
| `sprsweep` | 2,048 | `mfspr` of all 1,024 SPR numbers, in both modes |

MSR[POW], ILE, IP and LE are never changed; HID0, HID1 and L2CR are only
read; `rfi` is left out of the supervisor-mode sweep (it has its own group).
A sequence that faults on instruction fetch, takes a machine check or a sixth
exception is abandoned and marked `ABANDONED` in the CSV. In
`sresults_*.csv`, SRR0 and LR values inside the sequence are written as
`C+offset` and DAR values inside the scratch buffer as `S+offset`, so runs on
different machines compare directly. The emulator's CPU model takes far fewer
exceptions than a real CPU (it has no trace, breakpoint or alignment
exceptions, for instance): what it records is only a check of the mechanism.

## Dumping the Mac's ROM separately

The test image dumps the ROM itself from Open Firmware (above). The separate
disk is still available for the Linux route: under Linux, as root, with the
ROM-dump image on the BlueSCSI (8192 blocks in `/proc/partitions`):

```bash
dd if=/dev/sdX of=r bs=512 skip=16 count=32
chmod +x r
./r
```

It maps the 4 MB at physical address FFC00000 read-only through `/dev/mem`,
prints `romdump v4b`, 64 dots and `rom sum=XXXXXXXX write=ok`. From Open
Firmware: `boot scsi-int/sd@5:0`. Back on the PC:

```bash
python ppctest.py rom-extract FROM_CARD/HD50_512_romdump_v4b.hda --out runs/my7300.rom
python ppctest.py rom-check runs/my7300.rom other.rom
```

`rom-extract` checks the transfer and the ROM's own checksum; `rom-check`
runs the ROM checksum test on any 4 MB Old World ROM file and, given two,
says whether they are identical.

## If it does not get that far

Under Linux the program says what is wrong (`ERR: …`): no disk found, not
root, every slot used. From Open Firmware, write down exactly what is printed:

- nothing at all after `boot …` or an Open Firmware error: the loader did not
  accept the disk;
- `ppctest v4d` appears, then `ERR …`: the program started but could not find
  or read its disk, or every result slot is used (`ERR full`);
- dots appear and then it stops: a test vector trapped; count the dots.

If the summary says `write=FAILED`, the results are not on the disk.

## Self-tests

```bash
python ppctest.py selftest
python ppctest.py rom-selftest
```

Both run the real Linux executable, extracted from the image as `dd` would,
under QEMU's user-mode PowerPC emulator. `selftest` runs the whole vector set
three times on an image with two slots: two runs must finish with identical
results and the third must be refused; it then runs a variant of the test
program that picks its result slot itself, which is the code used from Open
Firmware. `rom-selftest` dumps the program's own
memory, then 4 MB through a sparse file standing in for `/dev/mem`. This proves
the program logic, the slot handling, the signal handler, the record formats
and the decoder. QEMU cannot turn floating-point traps off, so vectors that
start with FPSCR[FEX] set are left out there, and it says nothing about Apple's
Open Firmware or the second stage.

The Open Firmware route, second stage included, is tested in dingusppc with
the real 7600 ROM dump (`runs/my7600.rom`). Build the emulator once under WSL
(`bash ./build_dingus.sh`, from a dingusppc checkout at `..\..\dingusppc`),
make it an NVRAM with the console on the serial port and `real-base` preset,
then boot an image:

```bash
python ofnvram.py set PM7600-nvram-backup.bin _sim/nvram_emu.bin "auto-boot?=false" "real-base=F00000"
python ppctest.py build --set v3 --no-extras --out _sim/s2test.hda --slots 2       # a small image
wsl --cd C:\Temp\mistercore\PPC_Mac\ppctest -- python3 ofemu.py --rom runs/my7600.rom --nvram _sim/nvram_emu.bin --ext _sim/s2test.hda --cpu 604 "boot scsi/sd@0:0"
python ppctest.py results _sim/s2test.hda --out-dir _sim --name emu604
```

`--cpu` takes 601, 604, 604e or 750; the emulated disk must be on the
external bus (`--ext`, `scsi`). This proves the boot path, the client
interface calls, the slot handling and the second stage against Apple's
firmware; what the emulated CPU returns is only the emulator's opinion.

## What is and is not tested

- The disk layout and start-up sequence copy NetBSD/macppc's first-stage boot
  block (`bootxx`). Version 3 of this tool booted that way on a Power
  Macintosh 7600 (604, Open Firmware 1.0.5): two complete, bit-identical runs
  and a verified ROM dump.
- Version 4 has run under QEMU and under the real firmware in dingusppc only.
  Its start-up from Open Firmware is the version-3 code; what is new there
  (result slots, memory vectors, the second stage with its exception handlers
  and ROM dump) has run in the emulator as a 604 and as a 750. Its Linux
  route, and whether the kernel honours the request to turn floating-point
  traps off, are unproven on a real Mac until the first run.
- The second stage saves and restores the firmware's low memory around every
  group of sequences and puts the segment registers, BATs, SPRGs and SDR1
  back after every sequence; it leaves the decrementer at a large positive
  value.
- The test program only writes to the disk carrying its own signature (and,
  under Linux, its own build number), and only to its result slot.
- Each vector sets r3–r6, CR, XER, CTR, FPSCR and f4–f6, runs one instruction
  and records r3–r6, CR, XER, CTR, FPSCR and f3–f6. A memory vector also gets
  the address of an 8-byte buffer in r6; the buffer starts as the f6 pattern
  and is recorded in f6's place, and r6 is recorded less the buffer address.
- Floating-point exceptions are never taken. Branches, privileged
  instructions, `lmw` / `stmw` and anything that traps are not covered.

## Files

| File | Purpose |
|---|---|
| `ppctest.py` | command line |
| `harness.py` | the on-target program (under 2,048 bytes of PowerPC code) |
| `stage2.py` | the second stage: ROM dump, supervisor-mode sequences, exception handlers |
| `svectors.py` | the second stage's sequences and the `sresults` CSV format |
| `simelf.py` | the Linux wrapper around it: disk search, result slots, signals, `/dev/mem` |
| `ppcasm.py` | minimal PowerPC assembler |
| `vectors.py` | vector sources: dingusppc CSVs, generated cases, results-format CSV loader |
| `v4gen.py` | writes the model-predicted vectors of the version-4 set |
| `image.py` | disk image builder and result reader |
| `layout.py` | shared disk and record layout |
| `ofnvram.py` | edits Open Firmware variables in a copy of `/dev/nvram` |
| `ofemu.py`, `build_dingus.sh` | boot an image under the real firmware in dingusppc (WSL); build that emulator |
| `TO_CARD/`, `FROM_CARD/` | the one current image pair for the BlueSCSI; images brought back |
| `runs/` | decoded results (`results_*.csv`), ROM dumps, earlier images |
