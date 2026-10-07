# Resume prompt: read the 7300's Cuda firmware out through the VIA

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7600/7300 machine. Its Cuda (the ADB, power, reset, clock and PRAM microcontroller, a 68HC05) is built as the real chip running Apple's firmware: MAME's dump of 341S0060, Cuda 2.40 (`rtl\machine\cuda\341s0060.bin`). Which Cuda my machines really have is not known: my 7600 no longer powers on, no 341S-numbered part could be found on its board, and Apple marked some Cudas with 343S numbers. My working machine is a Power Macintosh 7300 of the same family. This session's job: a program that runs on the 7300 from Open Firmware, reads Cuda's firmware out of the chip through Grand Central's VIA, and writes it to a BlueSCSI disk image; and the host side that decodes it and says which Cuda it is.

Read these first:

- `README.md`, `docs\PPCMac_stubs.md` (its Cuda section), and the header of `rtl\machine\PPCMac_cuda.sv`: what is known about Cuda and how it talks to the VIA.
- `verilator\cuda_main.cpp`: a host that already speaks the protocol to the real firmware (in simulation): its `Via` and `Host` structs and their comments are the protocol as it works, with the timing the firmware needs.
- `rom7600\ppc\ppc_boot_FFF00000.lst` (git-ignored, local; the 7600 ROM disassembled): the ROM's own Cuda code, the best model for real-machine code: VIA set-up FFF04740/FFF04798, sync FFF047C0, a packet FFF048B4, a byte out FFF04B7C (note the ten VIA reads after each flag, FFF04BC4), a byte in FFF04BE4.
- `ppctest\README.md`: how test programs are booted from Open Firmware off the BlueSCSI and how results come back on the disk image; its Python tools (`ppcasm.py`, the image builder) are what to build on.
- `verilator\hc05dis.py`: a 68HC05 disassembler for the firmware, for later.

## What the program must do

- **Talk to Cuda directly**, from Open Firmware (`boot scsi-int/sd@N:0`, the console on the modem port as `ppctest\README.md` says), with external interrupts off (MSR[EE] = 0) while it drives the VIA. Find the VIA through Open Firmware's client interface (the `via-cuda` node under Grand Central, its `reg` and the parent's address; Grand Central's VIA is at F3016000 when Grand Central is at F3000000, as the 7600's ROM places it) and make sure the addresses are mapped for the program (Open Firmware runs clients with translation on: `map-in`, or its translations). VIA registers are 0x200 apart: vBufB 0x0000, vDirB 0x0400, vSR 0x1400, vACR 0x1600, vIFR 0x1A00, vIER 0x1C00; byte accesses with `eieio`. Port B: PB5 TIP (out, low asserts), PB4 BYTEACK (out), PB3 TREQ (in, low = Cuda wants to talk).
- **The protocol**, as the ROM and `cuda_main.cpp` do it: sync first; a packet goes out with the shift register set to output (ACR bit 4), TIP asserted, BYTEACK toggled after each byte; after the last byte the shift register back to input and TIP and BYTEACK negated; Cuda answers with an idle-acknowledge byte, then an attention byte with TREQ asserted; the reply is read with TIP asserted and BYTEACK toggled per byte, and ends when the host negates TIP (after enough bytes, or when TREQ goes high: then one last byte); then the idle-acknowledge again. After every shift-register flag, ten more VIA reads before touching SR or ACR (Cuda samples the last bit 3.8 us after the flag). Timeouts counted in VIA reads, as the ROM's. Cuda may have unsolicited packets queued (ADB auto-poll for Open Firmware's keyboard): read and discard any reply that is not ours.
- **Only read commands.** `READ_MCU_MEM` (packet `01 02 hi lo`; reply `01 00 02`, then the bytes from that address on for as long as the host keeps reading: checked in simulation, 0F00 gives the copyright "(c) 1989-94 Apple..."). Optionally `GET_REAL_TIME` (`01 03`) and `READ_PRAM` (`01 07 hi lo`). Never anything that writes or changes state: no WRITE_MCU_MEM (08), WRITE_PRAM (0C), SET_REAL_TIME (09), POWER_DOWN (0A), RESTART (11), autopoll, I2C, or anything else.
- **What to read**: RAM 0090-01FF (368 bytes: PRAM is 0100-01FF, the clock 00AB-00AE) and ROM 0B00-1FFF (5,376 bytes: that covers a 68HC05E1's ROM at 0F00-1FFF and a 68HC05E5's, Cuda 3.x, at 0B00-1FFF; on an E1, 0200-0EFF reads whatever the bus gives). Never read 0000-008F: on an E5 some registers there change when read. In chunks of 256 bytes a transaction (a byte takes about 200 us: the whole dump about a second and a half).
- **Write it to the disk image** with a status (how far it got, timeouts, the packets discarded) as `ppctest` does with its results, and print a short line on the console. One run per Open Firmware session; reset after.

## The host side

`... decode IMAGE`: print the firmware version (in 341S0060 the copyright string ends with its NUL at 0F35, and 0F36-0F3B hold `00 10 00 02 00 28`: version 0002.0028, which MAME calls 2.40; another firmware may lay this out differently), the CRC32 of the ROM part, and which of MAME's dumps it is. The chip stores no Apple part number; the match gives it:

| MAME's file | Version | Bytes, from | CRC32 |
|---|---|---|---|
| 341s0417 | 2.35 | 0x1100, 0F00 | 571F24C9 |
| 341s0788 | 2.37 | 0x1100, 0F00 | DF6E1B43 |
| 341s0789 | 2.38 | 0x1100, 0F00 | 682D2ACE |
| 341s0060 | 2.40 | 0x1100, 0F00 | 0F5E7B4A |
| 341s0262 | 3.02 (68HC05E5) | 0x1500, 0B00 | F43A803D |
| 341s0285 | Cuda Lite (68HC05E5) | 0x1400 | BA2707DA |

(From `..\mame\src\mame\apple\cuda.cpp`; the files are in `..\retrobios\bios\Arcade\MAME\cuda.zip`.) Also decode the clock (seconds since 1904) and show the PRAM. Save the ROM part as a local file; whether it goes into the repo beside 341S0060 is my decision once we see it.

## How to proceed

1. Propose where the tool lives (my suggestion: a new `cudadump\` at the top of the repo, using `ppctest`'s modules by import, never changing them: `ppctest\` belongs to the hardware session, which may have uncommitted work there) and which SCSI ID the image takes (`ppctest`'s image is ID 4), and wait for my answer.
2. Build it and test it first under emulation: `ppctest\ofemu.py` boots an image under the real ROM's Open Firmware in dingusppc (`ppctest\build_dingus.sh`). dingusppc's Cuda is not the chip (`..\dingusppc\devices\common\viacuda.cpp`): it answers READ_MCU_MEM of ROM addresses with made-up bytes, of PRAM addresses with its PRAM; enough to prove the protocol, the timeouts and the disk path, not the dump.
3. Give me the image and the exact steps for the 7300; I bring the image back; decode it.
4. Then, depending on the answer: if it is 341S0060, record in `docs\PPCMac_stubs.md` that the 7300's Cuda is the one built in, read from the chip. If it is another 68HC05E1 firmware (2.35-2.38, or one MAME does not have), tell me before anything changes: `verilator\cudarom.py` would take the new file and `run_cuda.py` would have to pass with it. If it is a 68HC05E5 (Cuda 3.x), `PPCMac_cuda.sv` needs the E5's memory map: a machine session's change, with my say-so.

## Rules

- Real hardware outranks every emulator. Nothing on the Mac is changed: no NVRAM or PRAM writes, no firmware settings.
- Edit files with the editor tools, not scripts or heredocs. Python 3.9 on Windows with no extra packages; WSL for dingusppc (launch it from PowerShell with Windows paths).
- Commit at verified points, never push; stage explicit paths, never `git add -A`. Do not modify anything under `ppctest\`, `sys\`, `rtl\DSPPC604\`, or the dingusppc and MAME trees. Disk images and dumps stay out of git (`*.hda` is ignored already).
