# Cuda identity: settled (2026-10-07); one open question, the 604e card

The question this prompt was written for is answered. On 2026-10-07 the
7300 ran `cudadump\TO_CARD\HD50_512_cudadump_v1.hda` from Open Firmware
(`boot scsi-int/sd@5:0`, 604 card, PVR 00040303): all 26 read-only jobs
completed, and the decode of `cudadump\FROM_CARD\HD50_512_cudadump_v1_exec.hda`
says the chip's ROM 0F00-1FFF is **341S0060, Cuda 2.40**, byte for byte the
firmware built into the core (CRC32 0F5E7B4A). 0B00-0EFF read back the low
byte of the address (open bus: a 68HC05E1). PRAM all zero; the clock at
1970-01-01 19:28 and counting. Recorded in `docs\PPCMac_stubs.md` (Cuda
table) and `cudadump\README.md`. Nothing in the RTL changes.

Open: the same disk did not run with the 604e card in the 7300. What the
console showed there was not written down. If that is to be chased:

- ask for the exact console lines with the 604e card (nothing after `boot`,
  an `ERR` line, the banner and then a stop, a reset?);
- the start-up code (`cudadump\program.py`, `build_stage1`) is ppctest's
  harness.py start-up instruction for instruction (bootxx: cache flush,
  BAT3 over the low 256 MB, MSR 0x3030), so ppctest's disk would show the
  same; a PVR-specific branch exists only for the 601;
- `ppctest\` belongs to the hardware session; a fix found there goes in as a
  proposal, not an edit.

Rules as before: real hardware outranks every emulator; nothing on the Mac
is changed; editor tools only; commit with explicit paths, never push.
