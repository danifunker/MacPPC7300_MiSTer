#!/usr/bin/env python3
"""From a device log: VRAM writes per million instructions, and the SCSI
commands (MESH sequence 03 followed by FIFO writes) with their CDBs, in a
window.

    python3 devstat.py LOG FROM TO
"""
import sys
from collections import Counter

log, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
vram = Counter()
cmds = []
cur = None
mesh_lines = 0
with open(log) as f:
    for line in f:
        if not line.startswith("A "):
            continue
        p = line.split()
        n = int(p[1])
        if n < lo:
            continue
        if n > hi:
            break
        addr = int(p[5], 16)
        if 0x90000000 <= addr < 0x94000000:
            if p[3] == "W":
                vram[n // 1000000] += 1
            continue
        if 0xF3018000 <= addr < 0xF3018100:
            mesh_lines += 1
            reg = addr & 0xF0
            if reg == 0x30 and p[3] == "W":
                seq = int(p[6], 16) >> 24
                if seq == 0x03:
                    cur = [n, p[2], []]
                    cmds.append(cur)
                elif cur is not None and cur[2]:
                    cur = None
            elif reg == 0x20 and p[3] == "W" and cur is not None:
                cur[2].append("%02X" % (int(p[6], 16) >> 24))
print("VRAM writes per million instructions:")
for m in sorted(vram):
    print("  %4dM: %d" % (m, vram[m]))
print("MESH accesses in the window: %d; SCSI commands: %d" % (mesh_lines, len(cmds)))
for n, pc, cdb in cmds[:60]:
    print("  %d (pc %s): %s" % (n, pc, " ".join(cdb)))
if len(cmds) > 60:
    print("  ... the last:")
    for n, pc, cdb in cmds[-5:]:
        print("  %d (pc %s): %s" % (n, pc, " ".join(cdb)))
