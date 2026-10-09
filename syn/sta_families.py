"""Group a TimeQuest summary report's paths by source and destination module."""
import re, sys, collections
fam = collections.Counter(); worst = {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if not line.startswith("; -") and not line.startswith("; 0"): continue
    f = [x.strip() for x in line.split(";")]
    try: slack = float(f[1])
    except ValueError: continue
    def mod(s):
        s = re.sub(r"emu:emu\|PPCMac_system:system\|", "", s)
        s = re.sub(r"\|altsyncram.*", "|RAM", s)
        m = re.match(r"((?:[A-Za-z0-9_]+:[A-Za-z0-9_\[\]\.]+\|)+)", s)
        return ((m.group(1) if m else s) + ("RAM" if "|RAM" in s else ""))[:60]
    k = (mod(f[2]), mod(f[3]))
    fam[k] += 1
    worst[k] = min(worst.get(k, 0), slack)
for k, n in fam.most_common(30):
    print("%4d %7.3f  %s -> %s" % (n, worst[k], k[0], k[1]))
