"""Group a sta_cpupaths.tcl cpupaths.txt by source and endpoint family: python syn\cpupaths_families.py FILE [N]"""
import re,collections,sys
f=sys.argv[1]; fam=collections.Counter(); worst={}
for line in open(f):
    s,fr,t,l=line.rstrip("\n").split("\t"); s=float(s)
    def mod(x):
        x=re.sub(r"emu:emu\|MacPPC7300_system:system\|","",x); x=re.sub(r"\|altsyncram.*","|RAM",x)
        m=re.match(r"((?:[A-Za-z0-9_]+:[A-Za-z0-9_\[\]\.]+\|)+)",x); base=(m.group(1) if m else "")
        leaf=x[len(base):] if m else x; leaf=re.sub(r"\[\d+\]","[]",leaf); leaf=re.sub(r"(_OTERM\d+|~DUPLICATE|~\d+|_RETIME\d*|_RTM\d+|_NEW_REG\d+|_NEW\d+|DUPLICATE)","",leaf)
        return (base+("RAM" if "|RAM" in x else leaf))[:58]
    k=(mod(fr),mod(t)); fam[k]+=1; worst[k]=min(worst.get(k,0),s)
print(f, sum(fam.values()), "pairs; within 0.5:", sum(1 for l in open(f) if float(l.split("\t")[0])>-0.5))
for k,n in sorted(fam.items(), key=lambda kv: worst[kv[0]])[:int(sys.argv[2]) if len(sys.argv)>2 else 40]: print("%4d %7.3f  %s -> %s"%(n,worst[k],k[0],k[1]))
