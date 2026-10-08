#!/usr/bin/env python3
"""Runs on the MiSTer: copy PPCMac_trace's new records to a file as they come,
for longer than the ring holds.

    python3 trstream.py SECONDS OUT

Each record goes out after its 4-byte index (`mister.py trace --file` reads
them). Reads of Grand Central's interrupt registers (kind 4 at F30000xx, not
a write) are left out: the NanoKernel makes thousands a second.
"""
import mmap, os, struct, sys, time

BASE, RECS = 0x30500000, 2048
secs, out = float(sys.argv[1]), sys.argv[2]
f = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(f, 64 + RECS * 32, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
n0 = max(0, (struct.unpack('<Q', m[0:8])[0] & 0xFFFFFFFF) - RECS)    # what the ring still holds
o = open(out, 'wb')
end = time.time() + secs
last, lost = n0, 0
while time.time() < end:
    n = struct.unpack('<Q', m[0:8])[0] & 0xFFFFFFFF
    if n - last > RECS:
        lost += n - last - RECS
        last = n - RECS
    while last < n:
        r = m[64 + (last % RECS) * 32:][:32]
        last += 1
        if r[0] == 4 and not (r[1] & 0x10) and r[11] == 0xF3 and r[10] == 0x00 and r[9] == 0x00:
            continue
        o.write(struct.pack('<I', last - 1) + r)
    time.sleep(0.005)
o.close()
print('records %d..%d, lost %d' % (n0, last, lost))
