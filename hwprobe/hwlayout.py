"""On-disk layout of the hardware probe disk, shared by the target program
(program.py) and the host tool (hwprobe.py).

The disk is ppctest's bootable envelope (image._disk: driver descriptor,
Apple partition map, the boot block at block 4, as Open Firmware 1.0.5 boots
it on the 7600 and the 7300), followed by our own blocks:

    8       the header (this file's H_* fields; the target writes its
            status back into it)
    16-31   the second stage (the interpreter: the boot block loads it 64 KB
            above itself)
    32-39   the operation table: up to 256 operations of 16 bytes
    40-41   the results: up to 256 words, in the order the operations make them
"""

BLOCK = 512
HDR_BLK = 8
S2_BLK, S2_MAX_BLKS = 16, 16
OPS_BLK, OPS_BLKS = 32, 8
RES_BLK, RES_BLKS = 40, 2
END_BLK = 48
OPS_MAX = OPS_BLKS * BLOCK // 16
RES_MAX = RES_BLKS * BLOCK // 4

MAGIC = b"HWPROBE1"
VERSION = 1

# header block, big-endian words. Set by the host:
H_MAGIC, H_VERSION, H_BUILD = 0x00, 0x08, 0x0C
H_NOPS, H_S2BLK, H_S2LEN, H_OPSBLK, H_RESBLK = 0x10, 0x14, 0x18, 0x1C, 0x20
# written back by the target:
H_DONE, H_PVR, H_MSR, H_GC, H_NRES = 0x40, 0x44, 0x48, 0x4C, 0x50
H_WRFAIL, H_HOW, H_DBAT2U, H_DBAT2L, H_BLKOFF = 0x54, 0x58, 0x5C, 0x60, 0x64
H_PATH, H_PATH_LEN = 0x80, 64
DONE = 0x444F4E45            # 'DONE': the run finished
STARTED = 0x53545254         # 'STRT': the run began
# H_HOW: how Grand Central's address was found
HOW_TREE, HOW_AAPL, HOW_DEFAULT = 1, 2, 3
DEFAULT_GC = 0xF3000000      # Grand Central on a 7600/7300

# an operation, 16 bytes: the opcode (byte 0), then three words
O_OP, O_OFF, O_VAL, O_ARG = 0, 4, 8, 12

# opcodes; "off" is an offset from Grand Central's base, a result is a word
OP_END = 0       # stop
OP_W8 = 1        # store byte val at off
OP_R8 = 2        # load byte at off -> result
OP_W32 = 3       # store word val at off
OP_R32 = 4       # load word at off -> result
OP_TB0 = 5       # remember the time base
OP_TBD = 6       # the time base ticks since TB0 -> result
OP_POLL8 = 7     # load byte at off until (byte & val) != 0 or arg ticks pass -> result:
                 #   the last byte, plus 0x100 if the time ran out
OP_REP8 = 8      # arg loads of the byte at off -> result: the ticks they took
OP_REP32 = 9     # the same with words
OP_WAIT = 10     # spin for arg ticks
OP_SKIPEQ = 11   # if (the last result & val) == arg, skip the next off operations
OP_W8R = 12      # store the low byte of result number val at off
