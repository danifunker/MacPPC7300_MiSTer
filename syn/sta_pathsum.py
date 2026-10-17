"""Print a report_timing -detail full_path report as cells and arrival times: python syn\sta_pathsum.py detail.txt"""
import re,sys
txt=open(sys.argv[1],encoding="utf-8",errors="replace").read()
blocks=re.split(r"\n(?=Path #\d+: Setup slack)", txt)
short=lambda s: s.replace("emu:emu|MacPPC7300_system:system|DSPPC604:cpu|","cpu|").replace("emu|system|cpu|","cpu|")
for p in blocks[1:]:
    m=re.match(r"Path #(\d+): Setup slack is (-?[\d.]+)",p)
    print("=== slack",m.group(2))
    launched=False
    for line in p.splitlines():
        if not line.startswith(";"): continue
        f=[x.strip() for x in line.strip(";").split(";")]
        if len(f)<7: continue
        if f[3]=="uTco": launched=True; print("  launch %s"%short(f[6])); continue
        if launched and f[3] in ("CELL","IC"): print("  %7s %6s %-4s %s"%(f[0],f[1],f[3],short(f[6])[:150]))
        if launched and f[3]=="uTsu": break
