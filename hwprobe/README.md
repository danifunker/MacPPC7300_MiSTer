# hwprobe — measure on the real 7300 what the emulators can only guess

A program that boots from Open Firmware on a Power Macintosh 7300/7600, runs
a table of register operations on Grand Central's devices, timed with the
time base, prints the results on the console and writes them back to its own
BlueSCSI disk image; and a host tool that builds the image and interprets
the results. Made for milestone E of the machine's plan
(`docs/MacPPC7300_plan.md`): what MESH and Curio do with an empty ID, which
dingusppc models only at a high level (`docs/MacPPC7300_stubs.md`).

Everything is Python 3 with no extra packages. It imports ppctest's modules
(`ppcasm.py`, `layout.py`, `image.py`) and changes nothing there; the boot
block is cudadump's (`..\cudadump\program.py`) with this disk's header.

## What it measures

| | why |
|---|---|
| 1000 reads each of the VIA's port B and IFR, MESH's ID, Curio's configuration 3, Grand Central's levels and a DMA channel's status | how long a device access takes on the real bus (the core paces only the VIA: `docs/MacPPC7300_stubs.md`, "VIA access time") |
| VIA timer 2 against the time base over 10 ms | the time base's rate (12.5 MHz expected), which every other number here is measured in |
| MESH's registers as Open Firmware leaves them | the reset or driver values of registers dingusppc reads as 0 (source ID, selection timeout, FIFO count, error) |
| MESH: arbitration, then bus status 0 and 1, exception and sequence | whether BSY or SEL show after a won arbitration (dingusppc: SEL only) |
| MESH: reselection off (0D), then the interrupt register; flush FIFO (0F), select (02), the interrupt register at once | whether 0D sets command done and whether the next command clears it (the stubs list's "MESH's interrupt line") |
| MESH: a selection of an empty ID with the timeout register at 0x19 and at 0x05 | the selection timeout's unit (10 ms in Linux's mesh.c; dingusppc a fixed 250 ms) |
| Curio's registers as left; the transfer count's high byte after a chip reset with ENF, after a DMA no-operation, and with configuration 2 at 80 | the part ID (the ROM reads it as a probe; dingusppc says 0C after a reset) |
| Curio: the ROM's set-up (factor 5, timeout A7), a selection with ATN of an empty ID, twice (timeout A7 and 10) | the chip's clock: the timeout is 8192 x 5 x the register in its clocks (the core assumes 25 MHz: 273.6 ms) |
| Grand Central's events, mask and levels before and after | what the probing leaves behind |

The selections go to SCSI ID 6 on each bus, which nothing should answer (a
7300's own disk is 0, its CD-ROM 3, the BlueSCSI 5). If something does
answer, the program resets that bus (RST for 25 us, then a second's rest)
and the decoder says so; build with `--target-id N` for another ID.
Nothing else changes: MESH's interrupt mask, destination ID and synchronous
parameters are put back, Curio is left set up as Mac OS's ROM sets it up,
and the program writes only its own blocks. External interrupts are off
throughout (MSR 0x3030).

## Build the image

```bash
python hwprobe.py build                     # -> TO_CARD/HD50_512_hwprobe_v1.hda
python hwprobe.py list                      # the operation table, with the result names
```

`HD50_512…` is BlueSCSI's naming for SCSI ID 5, LUN 0, 512-byte blocks, as
cudadump's image. The image is 1 MB.

## Run it on the 7300

The set-up of cudadump and ppctest's Open Firmware route: the BlueSCSI on
the internal bus as ID 5, a serial terminal on the modem port (38400 8N1, no
flow control), Cmd-Opt-O-F held at the chime.

1. At the `0 >` prompt: `boot scsi-int/sd@5:0` (`scsi` instead of
   `scsi-int` if the BlueSCSI is on the external bus). The first `boot` of a
   firmware session may print `RESETing to change Configuration!` and
   restart the machine: hold the keys again and retype it.
2. The run takes about two seconds (four selection timeouts) and prints

   ```
   hwprobe v1 scsi-int/sd@5 gc=F3000000t running
   results=00000076
   00000000: ........ ........ (eight words to a line, 0x76 words)
   ...
   hdr=ok write=ok
   ```

   Copy the whole terminal output: the result lines are the results, should
   the disk write fail.
3. Reset.

Back on the PC:

```bash
python hwprobe.py decode FROM_CARD/HD50_512_hwprobe_v1.hda
```

names every result and prints what follows from them: the time base's rate,
each access time in ns, MESH's arbitration and selection timeouts (ms per
unit of the register), what the interrupt register held after 0D, 0F and the
select, Curio's part ID and its clock.

## Files

| File | Purpose |
|---|---|
| `hwprobe.py` | command line: `build`, `list`, `decode`; the probe list (`default_program`) and the interpretation |
| `program.py` | the two on-target programs: the boot block (cudadump's) and the interpreter |
| `hwlayout.py` | the disk layout, the header and the operation codes shared by both sides |
| `TO_CARD/`, `FROM_CARD/` | the image for the BlueSCSI; the image brought back (both git-ignored) |

Disk layout (512-byte blocks): 0-7 ppctest's bootable envelope; 8 the
header; 16-31 the second stage; 32-39 the operation table (256 operations of
16 bytes: an opcode and three words); 40-41 the results (256 words).

The operations (`hwlayout.py`): store or load a byte or a word at an offset
from Grand Central's base, remember the time base, record the ticks since,
poll a byte until a mask matches or a time runs out, time N loads, wait,
skip the next N operations unless the last poll ran out of time, store a
byte taken from an earlier result. New probes are a few lines of Python in
`default_program`.

## Tests

**dingusppc, the real firmware** (`..\ppctest\ofemu.py`, WSL). dingusppc's
MESH cannot boot Open Firmware from the internal bus (the boot stops in its
data phases), so the image goes on the external bus there:

```bash
python hwprobe.py build --out _sim/hp.hda
wsl --cd C:\Temp\mistercore\PPC_Mac\ppctest -- python3 ofemu.py --rom runs/my7300.rom --machine pm7300 --cpu 604 --ext ../hwprobe/_sim/hp.hda "boot scsi/sd@0:0"
python hwprobe.py decode _sim/hp.hda
```

2026-10-07: the program finds Grand Central through the device tree, runs
all 212 operations, prints the 118 results, writes them and reads the header
back (`hdr=ok write=ok`), Open Firmware's prompt returns, also with the
Curio probe on the bus it booted from. dingusppc answers as its models do:
every device read in 32 ns (two instructions), the time base at 12.5019 MHz
against timer 2, MESH's arbitration done in about 4.3 us with SEL showing in
bus status 1, command done after 0D and cleared by 0F, both selections timed
out after 250 ms whatever the register says, Curio's part ID 0C after a
chip reset with ENF and 00 after a DMA no-operation.

## Results from the real 7300

None yet: the image is in `TO_CARD\` for the user's next session with the
machine. When they come, they go here, into `docs/MacPPC7300_stubs.md`
(the entries that name this probe), and into the RTL if they differ.
