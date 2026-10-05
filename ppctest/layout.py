"""On-disk and in-memory layout shared by the target program and host tools."""

BLOCK = 512
REC = 64                     # bytes per input / expected / result record
CHUNK_BLOCKS = 8             # the target works in 4096-byte chunks
CHUNK_RECS = CHUNK_BLOCKS * BLOCK // REC

# --- disk layout (512-byte blocks) -----------------------------------------
PART_START = 4               # partition holding everything below
BOOT_BLK = 4                 # boot code: blocks 4..7
BOOT_MAX = 2048              # same envelope NetBSD/macppc's bootxx uses
HDR_BLK = 8
VEC_BLK = 16                 # vector area starts here; expected and result
                             # areas follow, each padded to whole chunks

MAGIC = b"PPCTEST1"
VERSION = 1

# header block, big-endian words
H_MAGIC, H_VERSION, H_BUILD = 0x00, 0x08, 0x0C
H_NVEC, H_VECBLK, H_RESBLK, H_EXPBLK = 0x10, 0x14, 0x18, 0x1C
# ROM-dump disks only (0x20/0x24 hold the host's vector-name table on test disks)
H_ROMBLK, H_ROMADDR, H_ROMLEN = 0x28, 0x2C, 0x30
# written back by the target
H_DONE, H_SUM, H_NMISS, H_WRFAIL = 0x40, 0x44, 0x48, 0x4C
H_PVR, H_MSR, H_HID0, H_SIM, H_NRUN = 0x50, 0x54, 0x58, 0x5C, 0x60
H_PATH, H_PATH_LEN = 0x80, 64
H_MISS, H_MISS_MAX = 0xC0, 32
DONE = 0x444F4E45            # 'DONE'

# --- input record ----------------------------------------------------------
I_INSN, I_FLAGS = 0x00, 0x04
I_R3 = 0x08                  # r3..r6
I_CR, I_XER, I_CTR, I_FPSCR = 0x18, 0x1C, 0x20, 0x24
I_F4 = 0x28                  # f4..f6 (f3 always starts as +0.0)
F_HAS_EXPECTED = 1

# --- output / expected record ----------------------------------------------
O_R3 = 0x00                  # r3..r6
O_CR, O_XER, O_CTR, O_FPSCR = 0x10, 0x14, 0x18, 0x1C
O_F3 = 0x20                  # f3..f6

# --- target RAM, offsets from the load address -----------------------------
M_ARGS = 0x0800              # client-interface argument array
M_STDOUT = 0x0840
M_OPNAME, M_IOBUF, M_IOLEN, M_MSR = 0x0844, 0x0848, 0x084C, 0x0850
M_HEX = 0x0860
M_PATH = 0x0880              # 128 bytes
M_MISS = 0x0900              # 32 words
M_HDR = 0x0A00               # 512 bytes
M_IN = 0x1000
M_OUT = 0x2000
M_EXP = 0x3000               # must be M_OUT + 0x1000
M_STACK = 0x7FF0

SIM_MAGIC = 0x53494D55       # 'SIMU' in r3 at entry: skip privileged setup
