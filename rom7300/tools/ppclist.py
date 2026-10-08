"""PowerPC listing engine: runs dingusppc's disassembler over a block of
code, separates code from data, finds branch targets, and annotates.

Line format (see README):
    AAAAAAAAf WWWWWWWW  mnemonic operands            ; comment
f is '*' for a word the coverage run executed, ' ' for a word reachable by
control flow from executed code or a known entry point, '?' for a word that
decodes as an instruction but was neither executed nor reached (dead code or
data that happens to decode), and 'd' for words shown as data.
"""

import os
import re
import struct
import subprocess
import tempfile

import hwmap

U32 = struct.Struct('>I')


def sext(v, bits):
    m = 1 << (bits - 1)
    return (v & (m - 1)) - (v & m)


def printable(b):
    return 0x20 <= b < 0x7F


def ascii_of(bs):
    return ''.join(chr(c) if printable(c) else '.' for c in bs)


class Tools:
    def __init__(self, build_dir, tmp_dir):
        self.build = build_dir
        self.tmp = tmp_dir
        os.makedirs(tmp_dir, exist_ok=True)

    def dingus(self, data, base):
        """[(word, text, outs, ins)] for each word of data."""
        fd, path = tempfile.mkstemp(dir=self.tmp, suffix='.bin')
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        try:
            out = subprocess.run([os.path.join(self.build, 'ppcdis_dingus'), path, '0', str(len(data)),
                                  '0x%X' % base], capture_output=True, check=True).stdout.decode('latin-1')
        finally:
            os.unlink(path)
        res = []
        for line in out.split('\n'):
            if not line:
                continue
            head, _, rest = line.partition(' ')
            word, _, rest = rest.partition(' ')
            parts = rest.split('\t')
            text = parts[0].rstrip()
            outs = parts[1].split(',') if len(parts) > 1 and parts[1] else []
            ins = parts[2].split(',') if len(parts) > 2 and parts[2] else []
            res.append((int(word, 16), text, outs, ins))
        return res


def decode_flow(w, addr):
    """(kind, target): kind in 'b' (unconditional), 'bc' (conditional),
    'call', 'ret' (blr/bctr/rfi: ends flow), 'callr' (blrl/bctrl), 'trap',
    None (falls through)."""
    op = w >> 26
    if op == 18:
        li = sext(w & 0x03FFFFFC, 26)
        tgt = (li if w & 2 else addr + li) & 0xFFFFFFFF
        return ('call' if w & 1 else 'b'), tgt
    if op == 16:
        bo = (w >> 21) & 0x1F
        bd = sext(w & 0xFFFC, 16)
        tgt = (bd if w & 2 else addr + bd) & 0xFFFFFFFF
        if w & 1:
            return 'call', tgt
        if (bo & 0x14) == 0x14:
            return 'b', tgt
        return 'bc', tgt
    if op == 19:
        xo = (w >> 1) & 0x3FF
        bo = (w >> 21) & 0x1F
        if xo in (16, 528):
            if w & 1:
                return 'callr', None
            if (bo & 0x14) == 0x14:
                return 'ret', None
            return 'bcr', None
        if xo == 50:                       # rfi
            return 'ret', None
    if op == 17:                           # sc
        return None, None
    return None, None


def is_store(w):
    op = w >> 26
    return op in (36, 37, 38, 39, 44, 45, 52, 53, 54, 55, 47)


def mem_operand(w):
    """(rA, displacement, is_store, size) for D-form loads/stores, else None."""
    op = w >> 26
    sizes = {32: 4, 33: 4, 34: 1, 35: 1, 36: 4, 37: 4, 38: 1, 39: 1, 40: 2, 41: 2, 42: 2, 43: 2,
             44: 2, 45: 2, 46: 4, 47: 4, 48: 4, 49: 4, 50: 8, 51: 8, 52: 4, 53: 4, 54: 8, 55: 8}
    if op in sizes:
        return (w >> 16) & 31, sext(w & 0xFFFF, 16), op in (36, 37, 38, 39, 44, 45, 47, 52, 53, 54, 55), sizes[op]
    return None


def is_valid(w, text):
    """False for words that are not instructions of the 601/603/604: what
    dingusppc rejects, plus encodings it accepts although reserved fields are
    set (found by the cross-check against MAME's disassembler)."""
    if not text or text.startswith('dc.l') or text.startswith('<') or 'illegal' in text:
        return False
    op = w >> 26
    if op == 17 and w != 0x44000002:                 # sc with reserved bits set
        return False
    if op in (10, 11) and (w >> 21) & 1:             # cmpli/cmpi with L = 1 (64-bit)
        return False
    if op == 31 and (w & 1) and ((w >> 1) & 0x3FF) in (339, 467, 371, 83, 146, 595, 659, 210, 242):
        return False                                 # mfspr/mtspr/mftb/mfmsr/... with Rc = 1
    return True


def fix_text(w, text):
    """Rewrites dingusppc's text where it is unhelpful or wrong: SPR moves get
    names, lis/addis get unsigned upper halves, and two encodings dingusppc
    rejects by mistake are restored (603 tlbld/tlbli with rS = rA = 0, and
    lfsu/lfdu where rA equals the FPR number)."""
    op = w >> 26
    if op in (49, 51) and text.startswith('dc.l'):   # lfsu / lfdu
        rd, ra, d = (w >> 21) & 31, (w >> 16) & 31, sext(w & 0xFFFF, 16)
        if ra:
            return '%-7s f%d, %s0x%X(r%d)' % ('lfsu' if op == 49 else 'lfdu', rd, '-' if d < 0 else '', abs(d), ra)
    if op == 31:
        xo = (w >> 1) & 0x3FF
        if xo in (978, 1010) and not (w >> 16) & 0x3FF and text.startswith('dc.l'):
            return '%-7s r%d' % ('tlbld' if xo == 978 else 'tlbli', (w >> 11) & 31)
        if xo in (339, 467):
            rs = (w >> 21) & 31
            spr = ((w >> 16) & 31) | (((w >> 11) & 31) << 5)
            name = hwmap.spr_name(spr)
            if xo == 339:
                return 'mfspr   r%d, %s' % (rs, name)
            return 'mtspr   %s, r%d' % (name, rs)
        if xo == 371:                     # mftb
            rs = (w >> 21) & 31
            tbr = ((w >> 16) & 31) | (((w >> 11) & 31) << 5)
            return 'mftb    r%d, %s' % (rs, {268: 'TBL', 269: 'TBU'}.get(tbr, 'tbr%d' % tbr))
    if op == 15:
        rd, ra, imm = (w >> 21) & 31, (w >> 16) & 31, w & 0xFFFF
        if ra == 0:
            return 'lis     r%d, 0x%04X' % (rd, imm)
        return 'addis   r%d, r%d, 0x%04X' % (rd, ra, imm)
    return text


class Listing:
    """Builds the lines of one PowerPC listing."""

    def __init__(self, tools, data, base, *, executed=None, labels=None, comments=None,
                 data_ranges=None, roots=None, symbols=None, regions=None, toc=None,
                 phys_of=None, notes_at=None):
        self.tools = tools
        self.data = data
        self.base = base
        self.n = len(data) // 4
        self.executed = executed or (lambda a: False)
        self.labels = dict(labels or {})
        self.comments = dict(comments or {})
        self.data_ranges = data_ranges or []
        self.roots = set(roots or [])
        self.symbols = symbols or {}
        self.regions = regions or (lambda a: None)
        self.toc = toc                  # (r2 value, {addr: name}) or None
        self.phys_of = phys_of
        self.notes_at = notes_at or {}  # addr -> list of block comment lines

    def build(self):
        dis = self.tools.dingus(self.data, self.base)
        n = self.n
        base = self.base
        words = [d[0] for d in dis]
        texts = [fix_text(d[0], d[1]) for d in dis]
        outs = [d[2] for d in dis]
        valid = [is_valid(d[0], t) for d, t in zip(dis, texts)]
        exe = [self.executed(base + 4 * i) for i in range(n)]
        forced = [None] * n
        for (s, e, kind) in self.data_ranges:
            for a in range(max(s, base), min(e, base + 4 * n), 4):
                forced[(a - base) >> 2] = kind
        # ASCII runs that were not executed are data
        i = 0
        while i < n:
            j = i
            chars = 0
            while j < n and not exe[j]:
                bs = self.data[4 * j:4 * j + 4]
                if all(printable(c) or c == 0 for c in bs) and any(printable(c) for c in bs):
                    chars += sum(1 for c in bs if printable(c))
                    j += 1
                    if 0 in bs:
                        break
                else:
                    break
            if j - i >= 2 and chars >= 6:
                for k in range(i, j):
                    if forced[k] is None:
                        forced[k] = 'ascii'
                i = j
            else:
                i += 1
        isdata = [forced[i] is not None or not valid[i] for i in range(n)]
        flows = [decode_flow(words[i], base + 4 * i) for i in range(n)]
        # "bl over a table": a call to a nearby routine whose first instruction
        # is mflr rN (N != 0) uses the return address as a data pointer; the
        # words between the bl and the routine are its table
        self.tables = {}
        for i in range(n):
            kind, tgt = flows[i]
            if kind != 'call' or isdata[i] or not (base + 4 * i < tgt <= base + 4 * i + 0x800):
                continue
            ti = (tgt - base) >> 2
            if ti >= n or tgt & 3:
                continue
            tw = words[ti]
            rn = (tw >> 21) & 31
            if (tw & 0xFC1FFFFF) != 0x7C0802A6 or rn == 0:
                continue
            if any(exe[k] for k in range(i + 1, ti)):
                continue                   # the words after the bl ran: code
            # the routine must load through the return address within a few
            # instructions (a normal function only saves it)
            uses = False
            for k in range(ti + 1, min(n, ti + 13)):
                w2 = words[k]
                op2 = w2 >> 26
                if op2 in (32, 33, 34, 35, 40, 41, 42, 43) and (w2 >> 16) & 31 == rn:
                    uses = True
                    break
                if op2 == 31 and ((w2 >> 1) & 0x3FF) in (23, 55, 87, 119, 279, 311, 343) and \
                        rn in ((w2 >> 16) & 31, (w2 >> 11) & 31):
                    uses = True
                    break
            if not uses:
                continue
            for k in range(i + 1, ti):
                if forced[k] is None:
                    forced[k] = 'table (address taken by bl %08X)' % (base + 4 * i)
                    isdata[k] = True
            self.tables[i] = ti
        # reachability from executed words and roots
        reach = [False] * n
        stack = [i for i in range(n) if exe[i]]
        for a in list(self.roots) + list(self.labels):
            if base <= a < base + 4 * n:
                stack.append((a - base) >> 2)
        while stack:
            i = stack.pop()
            while 0 <= i < n and not reach[i] and not isdata[i]:
                reach[i] = True
                kind, tgt = flows[i]
                if tgt is not None and base <= tgt < base + 4 * n and kind in ('b', 'bc', 'call'):
                    stack.append((tgt - base) >> 2)
                if kind in ('b', 'ret') or i in self.tables:
                    break
                i += 1
        # ROM addresses in unreached words are data
        for i in range(n):
            if not isdata[i] and not reach[i] and not exe[i] and words[i] >= 0xFFC00000:
                isdata[i] = True
        # labels at branch targets
        callers = {}
        for i in range(n):
            if isdata[i]:
                continue
            kind, tgt = flows[i]
            if tgt is None or kind not in ('b', 'bc', 'call'):
                continue
            if base <= tgt < base + 4 * n:
                ti = (tgt - base) >> 2
                if tgt & 3 or isdata[ti]:
                    continue
                if tgt not in self.labels:
                    self.labels[tgt] = None
                if kind == 'call':
                    callers.setdefault(tgt, 0)
                    callers[tgt] += 1
        for a in list(self.labels):
            if self.labels[a] is None:
                self.labels[a] = ('sub_%08X' if a in callers else 'loc_%08X') % a
        self.words, self.texts, self.outs, self.isdata = words, texts, outs, isdata
        self.exe, self.reach, self.flows, self.forced = exe, reach, flows, forced
        return self

    # ---- annotation ------------------------------------------------------

    def target_name(self, tgt):
        if tgt in self.labels:
            return self.labels[tgt]
        if tgt in self.symbols:
            return self.symbols[tgt]
        return None

    def render(self):
        n, base = self.n, self.base
        words, texts, outs, isdata = self.words, self.texts, self.outs, self.isdata
        lines = []
        regs = {}
        i = 0
        while i < n:
            a = base + 4 * i
            if a in self.notes_at:
                for t in self.notes_at[a]:
                    lines.append('; ' + t if t else ';')
            if a in self.labels:
                regs = {}
                name = self.labels[a]
                if name.startswith('sub_') or not (name.startswith('loc_') or re.match(r'op[0-9A-F]{4}$', name)):
                    lines.append('')
                lines.append('%s:' % name)
            if isdata[i]:
                # gather a run of data words (up to the next label)
                j = i + 1
                while j < n and isdata[j] and (base + 4 * j) not in self.labels and (base + 4 * j) not in self.notes_at:
                    j += 1
                lines.extend(self.render_data(i, j))
                regs = {}
                i = j
                continue
            w = words[i]
            text = fix_text(w, texts[i])
            comment = []
            kind, tgt = self.flows[i]
            if tgt is not None:
                nm = self.target_name(tgt)
                if nm:
                    text = re.sub(r'0x%X\b' % tgt, nm, text, count=1)
                if not (base <= tgt < base + 4 * n):
                    reg = self.regions(tgt)
                    comment.append('-> %s' % (nm + ' in ' + reg if nm and reg else (reg or 'outside')))
            c = self.annotate(i, w, regs)
            if c:
                comment.append(c)
            if a in self.comments:
                comment.append(self.comments[a])
            flag = '*' if self.exe[i] else (' ' if self.reach[i] else '?')
            line = '%08X%s %08X  %s' % (a, flag, w, text)
            if comment:
                line = '%-62s ; %s' % (line, '; '.join(comment))
            lines.append(line)
            # register tracking ends at branches
            if kind is not None:
                regs = {}
            i += 1
        return lines

    def render_data(self, i, j):
        base = self.base
        out = []
        k = i
        while k < j:
            a = base + 4 * k
            w = self.words[k]
            # zero runs
            z = k
            while z < j and self.words[z] == 0:
                z += 1
            if z - k >= 4:
                out.append('%08Xd %s  .space  0x%X%s; zero to %08X' % (a, '........', 4 * (z - k), ' ' * 22, base + 4 * z))
                k = z
                continue
            kind = self.forced[k]
            if kind == 'ascii':
                e = k
                while e < j and self.forced[e] == 'ascii':
                    e += 1
                bs = self.data[4 * k:4 * e]
                for o in range(0, len(bs), 16):
                    chunk = bs[o:o + 16]
                    out.append('%08Xd %-8s  .ascii  "%s"' % (a + o, chunk[:4].hex().upper(), ascii_of(chunk)))
                k = e
                continue
            # long runs of one forced kind (images, tables) as hex dump lines
            if isinstance(kind, str) and kind not in ('data', 'ascii') and not kind.startswith('header'):
                e = k
                while e < j and self.forced[e] == kind and (base + 4 * e) not in self.comments:
                    e += 1
                if e - k >= 16:
                    out.append('%08Xd %s  ; %s, %X bytes:' % (a, '........', kind, 4 * (e - k)))
                    bs = self.data[4 * k:4 * e]
                    o = 0
                    while o < len(bs):
                        chunk = bs[o:o + 16]
                        if chunk.count(0) == 16:
                            z2 = o
                            while z2 < len(bs) and bs[z2:z2 + 16].count(0) == len(bs[z2:z2 + 16]):
                                z2 += 16
                            if z2 - o >= 64:
                                out.append('%08Xd ........  .space  0x%X' % (a + o, min(z2, len(bs)) - o))
                                o = z2
                                continue
                        out.append('%08Xd %s  |%s|' % (a + o, ' '.join(chunk[q:q + 4].hex().upper() for q in range(0, len(chunk), 4)), ascii_of(chunk)))
                        o += 16
                    k = e
                    continue
            if isinstance(kind, str) and kind not in ('data', 'ascii') and (k == i or self.forced[k - 1] != kind):
                note = kind
            else:
                note = ''
            bs = self.data[4 * k:4 * k + 4]
            cm = []
            if note:
                cm.append(note)
            if a in self.comments:
                cm.append(self.comments[a])
            if any(printable(c) for c in bs) and all(printable(c) or c == 0 for c in bs):
                cm.append("'%s'" % ascii_of(bs))
            hw = hwmap.hw_name(w)
            in_header = isinstance(kind, str) and kind.startswith('header')
            if in_header:
                pass                      # link fields are offsets, not addresses
            elif hw:
                cm.append(hw)
            elif w in self.symbols:
                cm.append(self.symbols[w])
            elif 0xFFC00000 <= w and self.regions(w):
                cm.append('-> ' + self.regions(w))
            line = '%08Xd %08X  .long   0x%08X' % (a, w, w)
            if cm:
                line = '%-62s ; %s' % (line, '; '.join(cm))
            out.append(line)
            k += 1
        return out

    def annotate(self, i, w, regs):
        """Comment for one instruction; updates the constant-register map."""
        op = w >> 26
        rd = (w >> 21) & 31
        ra = (w >> 16) & 31
        imm = w & 0xFFFF
        a = self.base + 4 * i
        note = None
        newval = None
        # memory access through a register holding a known address
        m = mem_operand(w)
        if m:
            rA, d, st, size = m
            if rA in regs or (rA == 0):
                ea = ((regs.get(rA, 0) if rA else 0) + d) & 0xFFFFFFFF
                note = self.describe_ea(ea, st, size)
            elif rA == 2 and self.toc:
                ea = (self.toc[0] + d) & 0xFFFFFFFF
                nm = self.toc[1].get(ea)
                if nm:
                    note = 'TOC[%+d] %s' % (d, nm)
        if op == 14:                           # addi / li
            if ra == 0:
                newval = sext(imm, 16) & 0xFFFFFFFF
            elif ra in regs:
                newval = (regs[ra] + sext(imm, 16)) & 0xFFFFFFFF
            elif ra == 2 and self.toc:
                ea = (self.toc[0] + sext(imm, 16)) & 0xFFFFFFFF
                nm = self.toc[1].get(ea)
                if nm:
                    note = 'TOC[%+d] %s' % (sext(imm, 16), nm)
        elif op == 15:                         # addis / lis
            if ra == 0:
                newval = (imm << 16) & 0xFFFFFFFF
            elif ra in regs:
                newval = (regs[ra] + (imm << 16)) & 0xFFFFFFFF
        elif op in (24, 25) and ((w >> 21) & 31) in regs:   # ori / oris rA, rS
            rs = (w >> 21) & 31
            v = regs[rs] | (imm if op == 24 else imm << 16)
            rd = ra
            newval = v & 0xFFFFFFFF
        elif op == 31 and ((w >> 1) & 0x3FF) == 444 and ((w >> 21) & 31) == ((w >> 11) & 31):  # mr
            rs = (w >> 21) & 31
            if rs in regs:
                rd, newval = ra, regs[rs]
        elif op in (17,):
            note = 'system call'
        elif op == 3 and rd == 31:
            note = 'twi 31: trap (kernel call %d)' % sext(imm, 16)
        # registers written by this instruction lose their values
        for r in self.outs[i]:
            if r.startswith('r') and r[1:].isdigit():
                regs.pop(int(r[1:]), None)
        if op in (14, 15) or (op == 31 and newval is not None):
            pass
        if newval is not None:
            regs[rd] = newval
            if not note:
                if op == 15 and ra == 0:                     # lis: name the block only
                    nm = hwmap.hw_base_name(newval)
                else:
                    nm = hwmap.hw_name(newval)
                    if nm and '+' in nm and not nm.startswith('GC_'):
                        nm = hwmap.hw_base_name(newval)
                if nm:
                    note = '= %08X %s' % (newval, nm)
                elif op != 15 and newval >= 0xFFC00000 and newval in self.symbols:
                    note = '= %s' % self.symbols[newval]
        return note

    def describe_ea(self, ea, st, size):
        nm = hwmap.hw_name(ea)
        if nm:
            return '%s %s %08X (%d)' % ('W' if st else 'R', nm, ea, size)
        if ea in self.symbols:
            return '%s %s' % ('W' if st else 'R', self.symbols[ea])
        if ea < 0x4000:
            ln = hwmap.lowmem_name(ea)
            if ln:
                return '%s low memory %s ($%X)' % ('W' if st else 'R', ln, ea)
        return None


def write_listing(path, header_lines, body_lines):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        for h in header_lines:
            f.write(('; ' + h).rstrip() + '\n')
        f.write('\n')
        for l in body_lines:
            f.write(l + '\n')
