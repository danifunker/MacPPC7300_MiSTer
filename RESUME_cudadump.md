# Resume prompt: which Cuda does the 7300 have? Run cudadump, decode it

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano, Cyclone V) with a PowerPC CPU called `DSPPC604`, inside a Power Macintosh 7600/7300 machine. Its Cuda (the ADB, power, reset, clock and PRAM microcontroller, a 68HC05) is built as the real chip running Apple's firmware: MAME's dump of 341S0060, Cuda 2.40 (`rtl\machine\cuda\341s0060.bin`). Which Cuda my machines really have is not known: my 7600 no longer powers on, no 341S-numbered part could be found on its board, and Apple marked some Cudas with 343S numbers. My working machine is a Power Macintosh 7300 of the same family.

The tool that reads Cuda's firmware out through Grand Central's VIA exists and is tested under emulation: `cudadump\` (read its `README.md` first; `cudadump\cudadump.py` is the command line, `program.py` the on-target code, `qemuemu.py` the QEMU driver). The previous session built it and ran it

- under the real 7600 and 7300 ROMs (Open Firmware 1.0.5) in dingusppc: all 26 read-only jobs complete, the replies and the completion record land on the disk image, `decode` reads them back (dingusppc's Cuda model fakes the ROM, so the content means nothing there);
- under QEMU's OpenBIOS (g3beige and mac99, `boot hd:2,%BOOT`): boot, device-tree search at other VIA addresses, sync, GET_REAL_TIME; QEMU's Cuda answers READ_MCU_MEM with error packets and OpenBIOS cannot write a disk, so only the console line comes back.

What it has not done is run on the real chip. The image for the card is `cudadump\TO_CARD\HD50_512_cudadump_v1.hda` (SCSI ID 5, the superseded ROM-dump disk's ID; ppctest's disk is ID 4; rename for another ID). `python cudadump\cudadump.py build` makes it again.

## This session

1. I run it on the 7300: the README's steps (terminal on the modem port, `boot scsi-int/sd@5:0`, about two seconds, reset after; one `boot` per firmware session). I bring back the image as `cudadump\FROM_CARD\HD50_512_cudadump_v1.hda` and the console lines. If the console shows `T` or `E` characters, `sync=FAILED`, `hdr=STALE` or `write=FAILED`, or an `ERR` line, start from what the console said: the decoder shows every job's status and reply, including the log of unsolicited packets.
2. `python cudadump\cudadump.py decode cudadump\FROM_CARD\HD50_512_cudadump_v1.hda --save cudadump\runs`: the firmware's copyright and version words, the CRC32 of the ROM part against MAME's dumps (the table is in `cudadump.py`, `MAME_ROMS`; the files are in `..\retrobios\bios\Arcade\MAME\cuda.zip`), a byte comparison with the core's 341S0060, the clock, the PRAM. The saved memory image files stay local (`*.bin` under `cudadump\runs` is not for the repo unless I say so).
3. Then, depending on the answer:
   - **341S0060 (CRC 0F5E7B4A, identical to the core's file):** record in `docs\PPCMac_stubs.md`'s Cuda table ("Which Cuda" row) that the 7300's Cuda was read from the chip and is 341S0060, with the date and the clock/PRAM facts worth keeping; nothing in the RTL changes.
   - **Another 68HC05E1 firmware (2.35-2.38, or one MAME does not have):** tell me before anything changes. `verilator\cudarom.py` would take the new file (it checks the CRC: that check would move to a table) and `verilator\run_cuda.py` would have to pass with it; `verilator\hc05dis.py ROM.bin` disassembles it for a look.
   - **A 68HC05E5 (Cuda 3.x: code in 0B00-0EFF, 0x1500 bytes from 0B00):** `rtl\machine\PPCMac_cuda.sv` would need the E5's memory map; that is a machine session's change, with my say-so.
   - **Nothing MAME has:** the dumped file, named by what the version words say, beside the decode's report; where it goes is my decision.

## Rules

- Real hardware outranks every emulator. Nothing on the Mac is changed: no NVRAM or PRAM writes, no firmware settings. The tool sends only READ_MCU_MEM, GET_REAL_TIME and READ_PRAM.
- Edit files with the editor tools, not scripts or heredocs. Python 3.9 on Windows with no extra packages; WSL for dingusppc (launch it from PowerShell with Windows paths); QEMU for Windows is in `C:\Program Files\qemu`.
- Commit at verified points, never push; stage explicit paths, never `git add -A`. Do not modify anything under `ppctest\` (the hardware session may have uncommitted work there), `sys\`, `rtl\DSPPC604\`, or the dingusppc and MAME trees. Disk images and dumps stay out of git (`*.hda`, `*.rom` and `*_sim` are ignored already).
