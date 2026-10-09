"""On-disk and in-memory layout shared by the target program and host tools."""

BLOCK = 512
REC = 64                     # bytes per input / expected / result record
CHUNK_BLOCKS = 8             # the target works in 4096-byte chunks
CHUNK_RECS = CHUNK_BLOCKS * BLOCK // REC

# --- disk layout (512-byte blocks) -----------------------------------------
PART_START = 4               # partition holding everything below
BOOT_BLK = 4                 # boot code: blocks 4..7
BOOT_MAX = 2048              # same envelope NetBSD/macppc's bootxx uses
HDR_BLK = 8                  # blocks 9..12: Linux run status on a disk without slots
                             # (the ROM-dump disk)
ELF_BLK = 16                 # the same program as a Linux executable, always here:
ELF_MAX_BLKS = 32            #   dd if=DISK of=p bs=512 skip=16 count=32
SLOT_BLK = 48                # one group of SLOT_BLKS blocks per Linux run ("slot"):
SLOT_BLKS = 8                #   its header copy, then LNX_BLKS blocks of run status
NSLOT_MAX = 8
VEC_BLK = 128                # vector area starts here; the expected area and one
                             # result area per run follow

MAGIC = b"PPCTEST1"
VERSION = 2                  # 1: one result area, Linux program wherever H_ELFBLK says

# header block, big-endian words
H_MAGIC, H_VERSION, H_BUILD = 0x00, 0x08, 0x0C
H_NVEC, H_VECBLK, H_RESBLK, H_EXPBLK = 0x10, 0x14, 0x18, 0x1C
H_METABLK, H_METALEN = 0x20, 0x24       # host-only: compressed vector names
# ROM-dump disks only
H_ROMBLK, H_ROMADDR, H_ROMLEN = 0x28, 0x2C, 0x30
H_ELFBLK, H_ELFLEN = 0x34, 0x38         # host-only: where the Linux program is
# written back by the target
H_DONE, H_SUM, H_NMISS, H_WRFAIL = 0x40, 0x44, 0x48, 0x4C
H_PVR, H_MSR, H_HID0, H_SIM, H_NRUN = 0x50, 0x54, 0x58, 0x5C, 0x60
H_PATH, H_PATH_LEN = 0x80, 64
H_MISS, H_MISS_MAX = 0xC0, 32
DONE = 0x444F4E45            # 'DONE'
STARTED = 0x53545254         # 'STRT': a Linux run claimed this slot and has not finished
# result slots (version 2). Run s (1..H_NSLOT), from Open Firmware or Linux,
# keeps its header in block H_SLOTBLK + (s-1)*SLOT_BLKS and its results at
# H_RESBLK + s*H_STRIDE; a Linux run follows them with H_TRAPBLKS blocks holding
# one bit per vector that trapped. The header in HDR_BLK stays as built. (Slot
# 0, results at H_RESBLK itself, is where a version-1 disk kept its single run.)
H_AREA, H_STRIDE, H_TRAPBLKS = 0x140, 0x144, 0x148
H_NSLOT, H_SLOTBLK, H_SLOT = 0x14C, 0x150, 0x154
# the second-stage program (stage2.py) and its areas, see there
H_S2BLK, H_S2LEN = 0x158, 0x15C
H_SVBLK, H_NSV, H_SRBLK, H_SSTRIDE = 0x160, 0x164, 0x168, 0x16C
H_ROM2BLK = 0x170             # the ROM dump the second stage makes (one per disk)
# written back by the second stage into the run's slot header
H_S2DONE, H_S2NRUN, H_S2SUM = 0x180, 0x184, 0x188
H_S2FLAGS, H_S2ROMSUM = 0x18C, 0x190     # S2F_* below; checksum of the ROM dump it made
S2F_ROM_DUMPED, S2F_ROM_PRESENT, S2F_WRFAIL, S2F_SKIPPED = 1, 2, 4, 8
ROM2_BLKS = 0x400000 // BLOCK          # the dump itself, then one marker block:
ROM2_MAGIC = 0x524F4D32                # 'ROM2', PVR, checksum, slot that made it

# --- second-stage records (stage2.py), 256 bytes in and out ------------------
SREC = 256
SCHUNK_RECS = CHUNK_BLOCKS * BLOCK // SREC        # 16 per 4096-byte chunk
S_CODE_MAX = 32                                   # instructions per sequence
# input
SI_FLAGS, SI_MSR, SI_NCODE = 0x00, 0x04, 0x08
SI_R3 = 0x10                                      # r3..r8
SI_CR, SI_XER, SI_CTR = 0x28, 0x2C, 0x30
SI_SCRATCH = 0x40                                 # 16 words: the scratch buffer's start
SI_CODE = 0x80                                    # up to S_CODE_MAX words
SF_R4_SCRATCH = 1        # r4 = scratch buffer address (plus the r4 given)
SF_CTR_END = 2           # CTR = address of the sequence's end (the appended sc)
SF_ONLY_750 = 4          # run only on a 750; else recorded as skipped
SF_ONLY_604 = 8          # run only on a 604/604e/604ev
# output
SO_STATUS, SO_MSR = 0x00, 0x04                    # status: flags | exceptions << 8
SO_R3 = 0x08                                      # r3..r12
SO_CR, SO_XER, SO_CTR, SO_LR = 0x30, 0x34, 0x38, 0x3C
SO_SCRATCH = 0x40                                 # 16 words after the sequence
SO_EXC, SO_EXC_MAX, SO_EXC_SIZE = 0x80, 5, 24     # vector, SRR0, SRR1, DAR, DSISR, MSR
SO_SLOT, SO_SCRATCHADDR = 0xF8, 0xFC              # where the code and the buffer were
SS_RAN, SS_RECOVERED, SS_SKIPPED = 1, 2, 4
S_EXC_LIMIT = 6          # the sequence is abandoned at this many exceptions

# --- Linux run status, written by the Linux wrapper (simelf.py) ---------------
LNX_BLKS = 4
LNX_MAGIC = 0x4C4E5853       # 'LNXS'
L_MAGIC, L_VERSION = 0x00, 0x04
L_FPEXC0 = 0x08              # PR_GET_FPEXC before (FFFFFFFF: the call failed)
L_SETRET, L_SETCR = 0x0C, 0x10   # r3 and CR after PR_SET_FPEXC(PR_FP_EXC_DISABLED)
L_FPEXC1 = 0x14              # PR_GET_FPEXC after
L_NTRAP, L_CPULEN, L_SLOT = 0x18, 0x1C, 0x20
L_FATALSIG, L_FATALNIP, L_FATALVEC = 0x24, 0x28, 0x2C
L_LOG, L_LOG_MAX = 0x40, 120     # first traps: vector number, signal << 16 | si_code
L_CPUINFO, L_CPUINFO_MAX = 0x400, 1024
TRAPMAP_MAX = 0x8000         # bytes of trap bitmap the wrapper keeps (262,144 vectors)

# --- input record ----------------------------------------------------------
I_INSN, I_FLAGS = 0x00, 0x04
I_R3 = 0x08                  # r3..r6
I_CR, I_XER, I_CTR, I_FPSCR = 0x18, 0x1C, 0x20, 0x24
I_F4 = 0x28                  # f4..f6 (f3 always starts as +0.0)
F_HAS_EXPECTED = 1
F_MEM = 2                    # r6 = address of an 8-byte buffer (plus the r6 given);
                             # the buffer starts as the f6 pattern and is recorded
                             # in place of f6, and r6 is recorded less the address

# --- output / expected record ----------------------------------------------
O_R3 = 0x00                  # r3..r6
O_CR, O_XER, O_CTR, O_FPSCR = 0x10, 0x14, 0x18, 0x1C
O_F3 = 0x20                  # f3..f6

# --- target RAM, offsets from the load address -----------------------------
M_ARGS = 0x0800              # client-interface argument array
M_STDOUT = 0x0840
M_OPNAME, M_IOBUF, M_IOLEN, M_MSR = 0x0844, 0x0848, 0x084C, 0x0850
M_HDRBLK = 0x0854            # block the completion record goes to (this run's slot)
M_HEX = 0x0860
M_PATH = 0x0880              # 128 bytes
M_HDR = 0x0A00               # 512 bytes
M_SCRATCH = 0x0C10           # the F_MEM buffer, with 16 spare bytes either side
M_IN = 0x1000
M_OUT = 0x2000
M_EXP = 0x3000               # must be M_OUT + 0x1000
M_STACK = 0x7FF0

SIM_MAGIC = 0x53494D55       # 'SIMU' in r3 at entry: skip privileged setup
