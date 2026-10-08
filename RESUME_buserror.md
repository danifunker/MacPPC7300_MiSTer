# Targeted session: the bus error at "Welcome to Mac OS" when Mac OS boots from disk

(Written 2026-10-07 at the end of the session that built milestone S's
machinery. A focused investigation: find the cause of one fault, fix it,
prove the fix on the board, hand back. The general continuation of the
machine's plan is `RESUME_disk.md`; this comes first.)

Paste everything below the line into a new session started in `C:\Temp\mistercore\PPC_Mac`.

---

I'm building a MiSTer FPGA core (DE10-Nano) with a PowerPC CPU, `DSPPC604`, inside a Power Macintosh 7300/7600. Milestone S (SCSI and the first disk) is built: MESH with its DBDMA channel, SCSI disks from the SD card's images, the DMA port through the CPU's snoop port. On the board, Mac OS 7.6.1 now boots from its disk image to the "Welcome to Mac OS" screen and stops there with **"Sorry, a system error occurred. bus error"**. Your task in this session is that fault and nothing else: find why it happens, fix it in the machine, show on the board that Mac OS gets past it, record what you found, and hand back.

**Work independently.** I am not available to answer questions. Decide what the documents leave open, the way their rules point, and record each decision in `docs/PPCMac_plan.md`'s decisions table ("decided by the session, DATE", with the reason) and in the commit message. Two rules stand above everything: **the CPU rule** (if the cause is in the CPU, `rtl/DSPPC604/`, do not change it: write `RESUME_cpu.md` with the evidence for a CPU session, commit it, and stop) and **never push** (this repository or `..\Main_MiSTer`).

**When you are done** (fixed and shown on the board, or stopped by the CPU rule, or out of leads), update `RESUME_disk.md` (the state, what you found, the next step) and `docs/PPCMac_plan.md`'s S section, commit, and stop. If Mac OS then reaches the Finder, say so: that is S's proof.

## Read first

- `RESUME_disk.md`: the state of milestone S, the tools it added, the board's state, the rules and the environment (all of which apply here).
- `docs/PPCMac_plan.md`, the S section ("What Mac OS asks of the disk", "Built") and the decisions table's S row; `docs/PPCMac_stubs.md` (MESH, the disks, DBDMA, the DMA port's window: everything the machine leaves out is listed there, and is a suspect).
- `README.md` for how to run the benches.

## What is known

- Reproduces every time on the board: `python syn\mister.py load` (the board is left with the build of 6407e7d, the 7300's ROM, `games/PPCMac/os761.hda` mounted as SCSI disk 0 by `config/PPCMac.s0`), wait 45 s, `python syn\mister.py shot out.png`. The welcome screen, then the bomb dialog, about 30 s after the core starts.
- The same with the 7600's ROM (077D.28F2), and with Shift held from the start (no "Extensions Off" appears: the fault comes before extensions load, in the System's own start-up). I have seen this error sometimes on my physical 7600, which says it can come from a timing or hardware condition Mac OS meets, not only from a broken machine.
- Mac OS 9.1 (`games/PPCMac/os91.hda`, a newer 36-block driver at block 59) does not even reach its welcome screen: grey screen, the CPU in the SCSI Manager (FFEC4C6C) and Mac OS's idle loops. Possibly a second, separate problem; possibly the same one earlier.
- dingusppc cannot help past 464 million instructions: its MESH has no DMA out, and its Mac OS hangs at the first write. Before that its log (`verilator\machref --set hdd_img2=Scratch\disks\os761_ref.hda`) is the reference for the disk traffic.
- In the lockstep simulation (the CPU checked against dingusppc's after every instruction, every device read handed to the reference, every DMA write copied into the reference's RAM) the boot runs identically through 227 blocks read, the first write (block 98, 431 million instructions) and the happy Mac (452 million); it then hung on a MESH handshake race (the SIM waiting for REQ to drop after a status byte), fixed in 6407e7d (MESH holds ACK after the status byte). The run on 6407e7d past that point was never finished: start there.
- On the board the debug readout at the bomb dialog shows Mac OS's 68k emulator running normally (pc 6806xxxx, MSR D076), device writes growing: the machine is alive, Mac OS gave up.

## How to find the faulting access

A "bus error" in Mac OS on a PowerPC is the 68k emulator's exception 2: the NanoKernel turns a data access fault (a DSI at vector 300, or an ISI at 400, or a machine check at 200: this CPU raises none) in emulated or native code into it. So the cause is an access to an address Mac OS's page tables do not map, or a fault the NanoKernel decides is fatal. Find the first such exception before the dialog and its DAR and SRR0:

1. Run the lockstep disk boot on the current tree, to past the dialog (about a billion instructions, 40-50 minutes):
   `python verilator\run_machine.py --monitor 16 --disk0 Scratch\disks\os761.hda --disk-log --max-instr 1500000000 --progress 10000000 --frame-at 450000000 --frame-every 25000000 --frame-out f%llu.png`
   (run it from a WSL script, `cd /mnt/c/Temp/mistercore/PPC_Mac/verilator; python3 run_machine.py ...`, with Linux paths: PowerShell's `Start-Process -ArgumentList` splits arguments with spaces). A lockstep MISMATCH stops it at the guilty instruction: if it is a load returning data the reference disagrees with after DMA, suspect the DMA path's coherence (the second snoop, the window in the stubs list) or DBDMA's byte placement; if it is a device read, the device.
2. Add to `verilator\core_main.cpp`, machine mode, an option that prints every exception the core takes (the trace's pc reaching a vector 100-1300 with the previous pc not adjacent, or better the CPU's own trace: SRR0, SRR1, DAR and DSISR as written), with the instruction count; DSIs are frequent (the NanoKernel fills its page table on demand), so print each vector's count and the DSIs whose DAR is outside RAM, or the last N before a given count. Use the frames to find when the dialog appears, and the exceptions just before it.
3. With the faulting instruction's count, rerun with `--trace-from N --trace-count M` around it (and `--dev-log FILE`, which slows the run six times, only for that stretch: its log has the pc of every device access) to see what Mac OS was doing: what address it took, from where (a value read from a device, from a disk block, from a structure DMA filled).

## Suspects, roughly in order

1. **A device answer Mac OS's start-up does not expect.** At this stage the System initializes its managers and drivers: the Sound Manager (AWACS, DMA channel 8: its registers are stored but the channel never runs, so a driver waiting for its interrupt or reading back its command pointer as it moves would be fooled), the floppy (SWIM3 reads 0), Ethernet (MACE reads 0), the serial driver (the ESCC has no interrupts), the clock and PRAM through Cuda (the clock is 1956, PRAM zero), the second SCSI bus (Curio, empty). dingusppc models SWIM3, MACE and AWACS's DMA; compare what its devices answer in the log with what ours do (`verilator\machref\devdiff.py` on device logs of the two machines, as far as dingusppc gets).
2. **The disk's answers.** The 7.6.1 driver may issue commands at this point that the boot did not (MODE SENSE, READ CAPACITY, INQUIRY, a SCSI bus scan of IDs 1-6 and Curio's, a SYNCHRONIZE CACHE...): `--disk-log` shows blocks only; log the CDBs the target executes (a print in the bench from the MESH FIFO writes in the device log, or a debug output of `PPCMac_scsidisk`'s command) and check each answer against `scsihd.cpp`/`scsiblockcmds.cpp` and the SCSI-2 standard.
3. **DMA data or coherence.** A block written into memory wrong (DBDMA's partial words, the byte enables of a line's edges, a descriptor's resCount or status written where Mac OS did not expect), or a cache line stale after DMA (the stubs list's window: a store into a line refetched between the two snoops). The lockstep run catches the second as a mismatch and the first as different data than the reference would have read from the file; `run_scsi.py` can be extended with the exact descriptors and alignments the driver uses (they are in memory: the bench's log of DMA register writes gives the command pointer).
4. **Timing.** The SD card answers in microseconds, a real disk in milliseconds; MESH runs a byte every 7 clocks; the selection of an absent ID times out after the register's 250 ms. A Mac OS race (my 7600's occasional bus error) could come from a disk answering faster than Mac OS's code is ready for (an interrupt arriving before its handler's state is set). Try slowing the target (`PPCMac_scsidisk`'s `PHASE_US`, a delay before data phases) as an experiment once the access is known.
5. **The CPU.** Only if the evidence points there: then the CPU rule.

Other data points that cost little: Mac OS 7.5.3, 8.5 or 8.6 from `\\daninas.local\Software\BlueSCSI Images\PowerPC Images` (zipped 512-byte-sector `.hda`; copy into `Scratch\disks\`, `python syn\mister.py put-disk FILE`, `mount 0 games/PPCMac/NAME`, `load`). Whether they get past the welcome screen narrows the field.

## Rules and environment

As in `RESUME_disk.md` (SystemVerilog both tools accept, Verilator `-Wall` clean via `make -s lint`, machine modules `PPCMac_*`, `sys/` untouched, edits with the editor tools, explicit-path commits with messages through a file and the harness's co-author line, `PPCMac.qsf` left out of commits, nothing under `ppctest\` or the dingusppc tree modified, one Verilator build per build directory, Quartus in the background about 15 minutes, the board left with default options and the menu loaded).
