"""On-disk layout of the Cuda dump disk, shared by the target program
(program.py) and the host tool (cudadump.py).

The disk is ppctest's bootable envelope (image._disk: driver descriptor,
Apple partition map, the boot block at block 4, as NetBSD/macppc's bootxx
and as Open Firmware 1.0.5 booted it on the 7600 and the 7300), followed by
our own blocks:

    8       the header (this file's H_* fields; the target writes its
            status back into it)
    16-31   the second stage (the Cuda code: the boot block loads it 64 KB
            above itself)
    32      the job table: up to 32 jobs of 16 bytes, each a packet to send
            and how many reply bytes to take
    40-47   the log of unsolicited packets the target read and discarded
    64-95   one 512-byte result block per job
"""

BLOCK = 512
HDR_BLK = 8
S2_BLK, S2_MAX_BLKS = 16, 16
JOB_BLK, JOB_MAX = 32, 32
LOG_BLK, LOG_BLKS = 40, 8
RES_BLK = 64
END_BLK = RES_BLK + JOB_MAX

MAGIC = b"CUDADMP1"
VERSION = 1

# header block, big-endian words. Set by the host:
H_MAGIC, H_VERSION, H_BUILD = 0x00, 0x08, 0x0C
H_NJOB, H_S2BLK, H_S2LEN = 0x10, 0x14, 0x18
H_JOBBLK, H_RESBLK, H_LOGBLK, H_LOGBLKS = 0x1C, 0x20, 0x24, 0x28
# written back by the target:
H_DONE, H_PVR, H_MSR, H_VIA = 0x40, 0x44, 0x48, 0x4C
H_NOK, H_NFAIL, H_NDISC, H_NBYTES = 0x50, 0x54, 0x58, 0x5C
H_SYNC, H_WRFAIL, H_HOW, H_DBAT2U, H_DBAT2L, H_BLKOFF = 0x60, 0x64, 0x68, 0x6C, 0x70, 0x74
H_PATH, H_PATH_LEN = 0x80, 64
DONE = 0x444F4E45            # 'DONE': the run finished
STARTED = 0x53545254         # 'STRT': the run began (written before the first packet)
# H_HOW: how the VIA's address was found
HOW_TREE, HOW_AAPL, HOW_DEFAULT = 1, 2, 3
DEFAULT_VIA = 0xF3016000     # Grand Central's VIA on a 7600/7300

# job table entry, 16 bytes
J_LEN, J_PKT, J_PKT_MAX, J_MAX, J_TAG, J_SIZE = 0, 1, 8, 10, 12, 16

# result block, 512 bytes
R_STATUS, R_LEN, R_DISC, R_WAITS, R_DATA = 0x00, 0x04, 0x08, 0x0C, 0x10
R_DATA_MAX = BLOCK - R_DATA
# R_STATUS values
ST_OK = 0
ST_SEND_TIMEOUT = 1          # no shift-register flag after a byte went out
ST_NO_REPLY = 2              # no reply (no flag, or flags without TREQ)
ST_COLLISIONS = 3            # Cuda kept wanting to talk first
ST_READ_TIMEOUT = 4          # a reply byte never came (what came is kept)
ST_ACK_TIMEOUT = 5           # the reply is complete but the idle acknowledge never came
ST_NAMES = {ST_OK: "ok", ST_SEND_TIMEOUT: "send timeout", ST_NO_REPLY: "no reply",
            ST_COLLISIONS: "collisions", ST_READ_TIMEOUT: "reply cut short (timeout)",
            ST_ACK_TIMEOUT: "ok, no idle acknowledge"}
# sync result (H_SYNC)
SYNC_NAMES = {0: "ok", 1: "Cuda did not assert TREQ", 2: "no flag after TREQ",
              3: "Cuda did not negate TREQ", 4: "no flag after TREQ negated"}

# discard log entry, 16 bytes: the length (bit 7 set: the read timed out),
# then the first 15 bytes
LOG_ENTRY = 16
LOG_DATA_MAX = 15

# the target's timeouts, in VIA reads: the 7600's ROM uses 3A98 (15,000,
# about 19 ms at the 783,360 Hz Grand Central paces VIA accesses at); eight
# times that keeps the emulators, whose VIA reads take no time, from timing
# out before their Cuda models answer
TIMEOUT_READS = 8 * 0x3A98
RETRIES = 4                  # sends abandoned to Cuda's own packets before a job fails
