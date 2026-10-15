"""Runs on the MiSTer: the machine's serial console (/dev/ttyS1, set first with
`stty -F /dev/ttyS1 38400 raw -echo`) into OUT, each line after the wall-clock
seconds it arrived at, for SECONDS. Against Linux's own [timestamps] it checks
the time base; between two boots it compares the CPU's speed.

    scp syn/uartts.py root@MISTER:/tmp/ ; ssh ... "setsid sh -c 'python3 /tmp/uartts.py 400 /tmp/u.txt' &"

Only one reader of /dev/ttyS1 at a time: two split the lines between them."""
import os, select, sys, time

secs, out = float(sys.argv[1]), sys.argv[2]
f = os.open('/dev/ttyS1', os.O_RDONLY | os.O_NONBLOCK)
o = open(out, 'w')
t0, buf = time.time(), b''
while time.time() - t0 < secs:
    r, _, _ = select.select([f], [], [], 0.5)
    if not r:
        continue
    buf += os.read(f, 4096)
    while b'\n' in buf:
        line, buf = buf.split(b'\n', 1)
        o.write('%9.3f %s\n' % (time.time() - t0, line.decode('latin-1').rstrip('\r')))
        o.flush()
o.close()
