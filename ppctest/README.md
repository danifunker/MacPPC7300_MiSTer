# ppctest — PowerPC CPU test disk

Builds a small bootable SCSI disk image. Booted from Open Firmware on a real
Power Mac, it executes a set of single-instruction test vectors, prints a
summary, and writes every result back to the same disk. The host tool then
decodes the image and compares the results with dingusppc's expected values.

Everything is Python 3 with no extra packages. Only the self-test needs WSL
(`qemu-ppc-static`).

## Build the image

```bash
python ppctest.py build --cpu 604e --out HD40_512_ppctest.hda
```

`--cpu` matters: the test program cannot survive an exception, so instructions
the chosen CPU does not have are left out (`601` drops `fsel`, `fres`,
`frsqrte`). `--no-extras` builds only dingusppc's 7,674 vectors, all of which
have expected values.

## Run it on the Power Mac 7600

1. Copy the `.hda` to the BlueSCSI card. Rename it for a free SCSI ID if 4 is
   taken (`HD40_512…` = ID 4, LUN 0, 512-byte blocks).
2. Start the Mac into Open Firmware (Cmd-Opt-O-F).
3. At the `0 >` prompt:

   ```
   boot scsi-int/sd@4:0
   ```

   Use the ID you chose. `scsi-int` is the internal bus; the external one is
   `scsi`.
4. Expected output: a banner with the boot device, one dot per 64 vectors
   (581 dots for the full set), then a line like

   ```
   n=00009136 sum=XXXXXXXX miss=XXXXXXXX write=ok 0000011F 00000120 …
   ```

   `miss` counts vectors that differ from dingusppc's expected values; up to 32
   of their numbers follow.
5. Power off, move the card back, and copy the `.hda` to the PC.

## Or run it from Linux on the Mac

The image also carries the same test program as a static Linux/PowerPC
executable, so Open Firmware is not needed for these user-level tests. With the
image on the BlueSCSI and Linux booted from another disk, as root (replace
`sdX` with the BlueSCSI test disk; `build` prints the exact numbers):

```bash
dd if=/dev/sdX of=ppctest bs=512 skip=13963 count=132 && chmod +x ppctest
ln -sf /dev/sdX sim.hda && ./ppctest
```

It prints the same dots and summary line and writes results to the same place
on the disk. Double-check `sdX`: the program refuses a disk without its
signature, but `dd` and the symlink are yours to get right. The CPU type is
not recorded in this mode (reading it is privileged), so note `/proc/cpuinfo`.
If it dies with a floating-point exception, rebuild with `--no-fp-enables`.

## Decode the results

```bash
python ppctest.py results HD40_512_ppctest.hda
```

Prints which CPU ran it, every differing vector with the fields that differ,
and writes all results to `results_<PVR>.csv`. That CSV is the golden data for
that CPU.

If the screen says `write=FAILED`, the results are not on the disk. Note the
whole summary line; the vector numbers can be looked up with

```bash
python ppctest.py vector HD40_512_ppctest.hda 11F 120
```

## If it does not get that far

Write down exactly what Open Firmware prints. The useful distinctions are:

- nothing at all after `boot …` or an Open Firmware error: the loader did not
  accept the disk;
- `ppctest v1` appears, then `ERR …`: the program started but could not find or
  read its disk;
- dots appear and then it stops: a test vector trapped; count the dots.

## Dumping the Mac's ROM

```bash
python ppctest.py rom-build --out HD40_512_romdump.hda
```

Boot it the same way (`boot scsi-int/sd@4:0`). It prints `romdump v1`, 64 dots
and `rom sum=XXXXXXXX write=ok`, having copied the 4 MB at physical address
FFC00000 onto the disk. Back on the PC:

```bash
python ppctest.py rom-extract HD40_512_romdump.hda --out my7600.rom
```

This checks the transfer and the ROM's own checksum. `rom-check FILE` runs the
same ROM checksum test on any 4 MB Old World ROM file. The dump disk is also
the simplest first thing to boot: it uses no floating point and no patched
code, so it separates "does the boot method work" from "do the tests work".

## Self-test

```bash
python ppctest.py selftest
```

Runs the same test program under QEMU's user-mode PowerPC emulator with a
stand-in for the Open Firmware client interface. It proves the program logic,
record formats and decoder. It does not prove anything about Apple's Open
Firmware.

## What is and is not tested

- The disk layout and start-up sequence copy NetBSD/macppc's first-stage boot
  block (`bootxx`), which boots this way on Open Firmware 1.0.5. The copy is
  from memory of that code, cross-checked against OpenBIOS's `mac-parts.c`.
- No part of this has run on real hardware or under Apple's Open Firmware yet.
- The test program only writes to the disk it booted from, and only after
  finding its own signature on it.
- Each vector sets r3–r6, CR, XER, CTR, FPSCR and f4–f6, runs one instruction
  and records r3–r6, CR, XER, CTR, FPSCR and f3–f6. Floating-point exceptions
  are never taken (MSR[FE0]=MSR[FE1]=0). Loads, stores, branches, privileged
  instructions and anything that traps are not covered yet.

## Files

| File | Purpose |
|---|---|
| `ppctest.py` | command line |
| `harness.py` | the on-target program (under 2,048 bytes of PowerPC code) |
| `ppcasm.py` | minimal PowerPC assembler |
| `vectors.py` | vector sources: dingusppc CSVs plus generated cases |
| `image.py` | disk image builder and result reader |
| `layout.py` | shared disk and record layout |
| `simelf.py` | ELF wrapper and fake client interface for the self-test |
