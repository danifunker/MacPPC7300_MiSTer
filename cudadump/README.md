# cudadump — read Cuda's firmware out through the VIA

A program that boots from Open Firmware on a Power Macintosh 7300/7600,
asks Cuda (the 68HC05 behind Grand Central's VIA) for its memory with
read-only commands, writes every reply back to its own BlueSCSI disk image,
and a host tool that decodes the image and says which Cuda firmware the
machine has. Built to settle which Cuda the 7300 carries: the core runs
MAME's 341S0060 (Cuda 2.40), and no part number could be read off the board.

Everything is Python 3 with no extra packages. It imports ppctest's modules
(`ppcasm.py`, `layout.py`, `image.py`) and changes nothing there.

## Build the image

```bash
python cudadump.py build                       # -> TO_CARD/HD50_512_cudadump_v1.hda
```

`HD50_512…` is BlueSCSI's naming for SCSI ID 5, LUN 0, 512-byte blocks
(the ID the superseded ROM-dump disk used; ppctest's disk is ID 4). Rename
for another ID. The image is 1 MB.

## Run it on the 7300

Same set-up as ppctest's Open Firmware route (`..\ppctest\README.md`): a
serial terminal on the modem port (38400 8N1, no flow control), Cmd-Opt-O-F
held at the chime.

1. At the `0 >` prompt: `boot scsi-int/sd@5:0` (`scsi` instead of
   `scsi-int` if the BlueSCSI is on the external bus). The first `boot` of a
   firmware session may print `RESETing to change Configuration!` and
   restart the machine: hold the keys again and retype it.
2. The whole run takes about two seconds and prints

   ```
   cudadump v1 scsi-int/sd@5 via=F3016000t sync=ok
   .......................... hdr=ok
   jobs=0000001A ok=0000001A fail=00000000 disc=00000000 bytes=000017C6 write=ok
   ```

   `via=` is the VIA's address and how it was found (`t`: the device tree's
   `via-cuda` node, `a`: its `AAPL,address`, `d`: the default F3016000);
   one character per job: `.` a complete reply, `E` an error packet from
   Cuda, `T` a timeout; `hdr=ok` says the completion record was read back
   from the disk. If anything differs, write the lines down exactly.
3. Reset. One `boot` per firmware session, as with ppctest.

Back on the PC:

```bash
python cudadump.py decode FROM_CARD/HD50_512_cudadump_v1.hda --save runs
```

prints the run's status, every job's reply, the clock, the PRAM, the
copyright string and version words found in the ROM, the CRC32 of the ROM
part against MAME's six Cuda dumps and a byte-for-byte comparison with the
core's `rtl\machine\cuda\341s0060.bin` (and with MAME's files when
`..\..\retrobios\bios\Arcade\MAME\cuda.zip` is there, or `--mame FILE`).
`--save DIR` writes the memory image: the whole 8 KB, the 0F00-1FFF and
0B00-1FFF windows (the sizes MAME's files have) and a map of the bytes read.
Whether a new firmware goes into the repo is a decision for afterwards.

## What the program does

Only reads. The jobs, in order (`cudadump.py default_jobs`):

| Job | Packet | Reply taken |
|---|---|---|
| GET_REAL_TIME | `01 03` | 7 bytes: `01 00 03` and the seconds since 1904 |
| READ_MCU_MEM 0090, 0190 | `01 02 hi lo` | `01 00 02` and 256 / 112 bytes: RAM 0090-01FF (the clock at 00AB, PRAM 0100-01FF) |
| READ_MCU_MEM 0B00 … 1F00 | `01 02 hi lo` | 21 × 256 bytes: ROM 0B00-1FFF (a 68HC05E1's ROM is 0F00-1FFF; a 68HC05E5's, Cuda 3.x, 0B00-1FFF) |
| READ_PRAM 0000 | `01 07 00 00` | `01 00 07` and 256 bytes, to check against RAM 0100-01FF |
| GET_REAL_TIME | `01 03` | the clock again |

Never 0000-008F (on an E5 some registers there change when read), never
anything that writes or changes state. The program writes only to the disk
carrying its own header and only into its own blocks.

The protocol is the 7600 ROM's and `verilator\cuda_main.cpp`'s host's: sync
(BYTEACK asserted without TIP, Cuda asserts TREQ, BYTEACK negated, TREQ
negated), then for each job the packet out with the shift register set to
output and TIP asserted, BYTEACK toggled per byte, the shift register back
to input and TIP and BYTEACK negated; the idle acknowledge and the attention
byte in; the reply read with TIP asserted and BYTEACK toggled until Cuda
negates TREQ or enough bytes are in, then TIP negated and the idle
acknowledge read. Ten more VIA reads after every shift-register flag before
SR or ACR is touched (Cuda samples the last bit 3.8 us after the flag).
Timeouts are counted in VIA reads: eight times the ROM's 3A98, about 150 ms
on the machine. Anything Cuda offers on its own before a job (an ADB
auto-poll packet for the firmware's keyboard) is read, logged and discarded.
External interrupts are off throughout (MSR 0x3030, as ppctest's program
runs); the VIA's interrupt enables are not touched.

The VIA is found by walking the device tree through the client interface
(`peer`, `child`, `parent`, `getprop`) for the node named `via-cuda`: its
`reg` gives the offset (16000), its parent's `assigned-addresses` the base
(F3000000 on a 7600/7300). That megabyte is mapped with DBAT2
(cache-inhibited, guarded; the 7300's firmware leaves BAT0-2 clear, as
ppctest's probe sequences recorded), and DBAT2 is put back before the exit.

## Files

| File | Purpose |
|---|---|
| `cudadump.py` | command line: `build`, `decode`, `qemu`; the jobs; the decoder with MAME's table |
| `program.py` | the two on-target programs: the boot block (ppctest's harness.py start-up, loads the second stage) and the Cuda code |
| `cudalayout.py` | the disk layout and record formats shared by both sides |
| `qemuemu.py` | boots an image under QEMU's OpenBIOS on Windows |
| `TO_CARD/`, `FROM_CARD/` | the image for the BlueSCSI; the image brought back (both git-ignored) |

Disk layout (512-byte blocks): 0-7 ppctest's bootable envelope (driver
descriptor, Apple partition map, the boot block at 4); 8 the header; 16-31
the second stage; 32 the job table; 40-47 the log of discarded packets;
64-95 one result block per job (status, length, the reply).

## Tests

**dingusppc, the real firmware.** The image boots under the 7600's and the
7300's own ROM dumps (Open Firmware 1.0.5) in dingusppc, through
`..\ppctest\ofemu.py` (WSL):

```bash
python cudadump.py build --out _sim/cd.hda
wsl --cd C:\Temp\mistercore\PPC_Mac\ppctest -- python3 ofemu.py --rom runs/my7300.rom --nvram _sim/nvram_emu.bin --cpu 604e --ext ../cudadump/_sim/cd.hda "boot scsi/sd@0:0"
python cudadump.py decode _sim/cd.hda
```

All 26 jobs complete, the results and the completion record land on the
disk, the decoder reads them back. That proves the boot path, the client
interface calls, the device-tree search (F3016000), the handshake and the
timing against Apple's firmware and dingusppc's Cuda model. dingusppc's Cuda
is not the chip (`devices/common/viacuda.cpp`): a ROM read gets an empty
copyright string and version words 0019 0002 0029 at every address, so the
decoder names it and matches nothing.

**QEMU, OpenBIOS.** With QEMU for Windows installed (`C:\Program Files\qemu`):

```bash
python cudadump.py qemu TO_CARD/HD50_512_cudadump_v1.hda [--machine mac99]
```

OpenBIOS boots the same image: `boot hd:2,%BOOT` takes the raw boot code of
the second partition map entry from pmBootLoad with pmBootEntry, the Apple
way. The program finds the VIA through the device tree at QEMU's addresses
(mac-io at 81080000 on g3beige, 80000000 on mac99), syncs with QEMU's Cuda,
and GET_REAL_TIME answers; QEMU's Cuda (`hw/misc/macio/cuda.c`) knows no
READ_MCU_MEM or two-byte READ_PRAM and returns error packets (`E`), which
exercises that path. OpenBIOS's IDE driver has no `write`, so nothing lands
in the image there: the console line is the result.

## The result: the 7300, 2026-10-07

With the 604 card (PVR 00040303) and `boot scsi-int/sd@5:0`, the 7300
printed exactly the three lines above (all 26 jobs, `hdr=ok`, `write=ok`,
two seconds by Cuda's own clock). The decode of
`FROM_CARD\HD50_512_cudadump_v1_exec.hda`:

- ROM 0F00-1FFF: CRC32 0F5E7B4A = MAME's **341s0060, Cuda 2.40**, byte for
  byte the firmware built into the core (`rtl\machine\cuda\341s0060.bin`).
  Copyright `(c) 1989-94 Apple Computer, Inc. All rights reserved.` at 0F00,
  version words 0010 0002 0028 at 0F36.
- 0B00-0EFF reads back the low byte of its own address: nothing there, the
  68HC05E1's open bus (so not a 68HC05E5).
- RAM: the clock at 00AB is what GET_REAL_TIME returns (7C26C24C,
  1970-01-01 19:28, counting); PRAM 0100-01FF all zero, READ_PRAM agrees.
- No unsolicited packets, no timeouts, no collisions.

The memory image files are in `runs\` (git-ignored). Recorded in
`docs\PPCMac_stubs.md`'s Cuda table.

The same disk did not run with the 604e card; what the console showed there
is not recorded yet.
