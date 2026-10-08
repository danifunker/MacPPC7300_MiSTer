"""68k listing engine: MAME's 68k disassembler (68040) through mamedis,
with recursive descent from known entry points and executed addresses to
separate code from data, A-line trap names and low-memory names.

Line format (see README):
    AAAAAAAAf HEXBYTES             mnemonic operands       ; comment
f is '*' for an instruction the coverage run executed (the 68k emulator's
PC, r24, at its opcode dispatch), ' ' for one reached by control flow from
executed code or a known entry point, '?' for bytes outside any reached flow
that still decode as a plausible run of instructions, 'd' for data.
"""

import os
import re
import subprocess

import hwmap

TERMINATORS = ('rts', 'rte', 'rtd', 'rtr', 'jmp', 'bra')
ADDR_RE = re.compile(r'\$([0-9a-fA-F]{1,8})')


class M68kServer:
    """mamedis in server mode on one file mapped at base."""

    def __init__(self, build_dir, path, base):
        self.p = subprocess.Popen([os.path.join(build_dir, 'mamedis'), 'm68k-server', path, '0x%X' % base],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        self.cache = {}

    def get(self, addr):
        r = self.cache.get(addr)
        if r is None:
            self.p.stdin.write(b'%X\n' % addr)
            line = self.p.stdout.readline().decode('latin-1').rstrip('\n')
            r = parse_line(line)
            self.cache[addr] = r
        return r

    def batch(self, addrs):
        """Decodes many addresses with one round trip."""
        need = [a for a in addrs if a not in self.cache]
        # in chunks: the replies must not fill the pipe while requests are
        # still being written, or both sides block
        for k in range(0, len(need), 256):
            part = need[k:k + 256]
            self.p.stdin.write(b''.join(b'%X\n' % a for a in part))
            for a in part:
                line = self.p.stdout.readline().decode('latin-1').rstrip('\n')
                self.cache[a] = parse_line(line)

    def close(self):
        self.p.stdin.close()
        self.p.wait()


def parse_line(line):
    head, _, text = line.partition('\t')
    parts = head.split()
    return {'addr': int(parts[0], 16), 'len': int(parts[1]), 'flags': parts[2],
            'hex': parts[3] if len(parts) > 3 else '', 'text': text.strip()}


def mnemonic(text):
    return text.split(None, 1)[0] if text else ''


def is_invalid(ins):
    """Not an instruction: MAME's dc.w (except A-line traps), its "unknown"
    and placeholder texts, and its decodings of F-line words for coprocessor
    IDs other than the FPU and MMU (mnemonics like "6gen" or "3b?")."""
    t = ins['text']
    if t == '' or t.startswith('?') or 'ILLEGAL' in t or t.startswith('unknown'):
        return True
    if t.startswith('dc.w') and 'opcode 1010' not in t:
        return True
    m = mnemonic(t)
    return m[:1].isdigit() or '?' in m


def is_aline(ins):
    return 'opcode 1010' in ins['text']


def flow(ins):
    """(ends_flow, targets, is_call)."""
    t = ins['text']
    m = mnemonic(t)
    ops = t[len(m):].strip()
    base = m.split('.')[0]
    tgts = []
    if base in ('bra', 'bsr') or (base.startswith('b') and base not in ('bchg', 'bclr', 'bset', 'btst',
                                                                      'bfchg', 'bfclr', 'bfexts', 'bfextu',
                                                                      'bfffo', 'bfins', 'bfset', 'bftst',
                                                                      'bkpt')) \
            or base.startswith('db') or base.startswith('fb') or base.startswith('fdb'):
        mm = ADDR_RE.findall(ops)
        if mm:
            tgts.append(int(mm[-1], 16))
    elif base in ('jmp', 'jsr'):
        mm = re.match(r'\(\$([0-9a-fA-F]+),PC\)$', ops) or re.match(r'\$([0-9a-fA-F]+)(\.[wl])?$', ops)
        if mm:
            v = int(mm.group(1), 16)
            if ops.endswith('.w') and v & 0x8000:
                v |= 0xFFFF0000
            tgts.append(v)
    ends = base in TERMINATORS
    call = base in ('bsr', 'jsr')
    return ends, tgts, call


def lea_target(ins):
    t = ins['text']
    m = mnemonic(t)
    if m in ('lea', 'pea'):
        mm = re.match(r'\s*\(\$([0-9a-fA-F]+),PC\)', t[len(m):])
        if mm:
            return int(mm.group(1), 16)
    return None


class Listing:
    def __init__(self, server, data, base, *, executed=None, roots=None, labels=None,
                 comments=None, data_ranges=None, symbols=None, regions=None, notes_at=None,
                 heuristic=True):
        self.srv = server
        self.data = data
        self.base = base
        self.end = base + len(data)
        self.executed = executed or (lambda a: False)
        self.roots = set(roots or [])
        self.labels = dict(labels or {})
        self.comments = dict(comments or {})
        self.data_ranges = data_ranges or []
        self.symbols = symbols or {}
        self.regions = regions or (lambda a: None)
        self.notes_at = notes_at or {}
        self.heuristic = heuristic

    def inside(self, a):
        return self.base <= a < self.end

    def build(self):
        base, end = self.base, self.end
        forced = bytearray(len(self.data))           # 1 = data
        for s, e, _ in self.data_ranges:
            for a in range(max(s, base), min(e, end)):
                forced[a - base] = 1
        self.forced_kind = {}
        for s, e, k in self.data_ranges:
            self.forced_kind[max(s, base)] = (min(e, end), k)
        owner = {}                                     # byte -> instruction start
        code = {}                                      # start -> ins
        status = {}                                    # start -> '*', ' ' or '?'
        exe = [a for a in range(base, end, 2) if self.executed(a)]
        stack = list(reversed(exe)) + [a for a in sorted(self.roots | set(self.labels)) if self.inside(a)]
        targets = set()
        calls = set()
        while stack:
            a = stack.pop()
            while self.inside(a) and a not in code and not forced[a - base] and not (a & 1):
                if a in owner:                         # lands inside another instruction
                    break
                ins = self.srv.get(a)
                if is_invalid(ins) or a + ins['len'] > end:
                    break
                if any(forced[b - base] or b in owner for b in range(a, a + ins['len'])):
                    break
                code[a] = ins
                for b in range(a, a + ins['len']):
                    owner[b] = a
                ends, tgts, call = flow(ins)
                for t in tgts:
                    t &= 0xFFFFFFFF
                    targets.add(t)
                    if call:
                        calls.add(t)
                    if self.inside(t):
                        stack.append(t)
                lt = lea_target(ins)
                if lt is not None and self.inside(lt) and self.executed(lt):
                    targets.add(lt)
                if ends:
                    break
                a += ins['len']
        for a in code:
            status[a] = '*' if self.executed(a) else ' '
        # gaps: plausible instruction runs become '?', the rest data
        if self.heuristic:
            a = base
            while a < end:
                if a in owner or forced[a - base]:
                    a += 1
                    continue
                g = a
                while g < end and g not in owner and not forced[g - base]:
                    g += 1
                self._fill_gap(a, g, code, owner, status)
                a = g
        # labels
        for t in targets:
            if self.inside(t) and t in code and t not in self.labels:
                self.labels[t] = ('sub_%08X' if t in calls else 'loc_%08X') % t
        self.code, self.owner, self.status = code, owner, status
        return self

    def _fill_gap(self, s, e, code, owner, status):
        """Decodes a gap linearly; keeps runs that look like code."""
        if s & 1:
            s += 1
        if e - s < 4:
            return
        a = s
        run = []
        runs = []
        while a < e:
            ins = self.srv.get(a)
            if is_invalid(ins) or a + ins['len'] > e:
                if run:
                    runs.append(run)
                run = []
                a += 2
                continue
            run.append(ins)
            a += ins['len']
            if flow(ins)[0]:
                runs.append(run)
                run = []
        if run:
            runs.append(run)
        for r in runs:
            ok = len(r) >= 3 and flow(r[-1])[0]
            # long runs of tiny 'instructions' over zero/fill bytes are data
            body = b''.join(bytes.fromhex(i['hex']) for i in r)
            if body.count(0) > len(body) * 0.6 or body.count(b'kc') * 2 > len(body) * 0.5:
                ok = False
            # text decodes as plausible 68k too often: mostly printable bytes is data
            if sum(1 for c in body if 0x20 <= c < 0x7F) > len(body) * 0.75:
                ok = False
            # memory-indirect modes are rare in this ROM's code and common in decoded data
            if sum(1 for i in r if '([' in i['text']) * 4 > len(r):
                ok = False
            if ok:
                for ins in r:
                    code[ins['addr']] = ins
                    status[ins['addr']] = '?'
                    for b in range(ins['addr'], ins['addr'] + ins['len']):
                        owner[b] = ins['addr']

    # ---- rendering ---------------------------------------------------------

    def render(self):
        base, end = self.base, self.end
        out = []
        a = base
        while a < end:
            if a in self.notes_at:
                for t in self.notes_at[a]:
                    out.append('; ' + t if t else ';')
            if a in self.labels:
                nm = self.labels[a]
                if not nm.startswith('loc_'):
                    out.append('')
                out.append('%s:' % nm)
            if a in self.code:
                ins = self.code[a]
                out.append(self.render_ins(ins))
                a += ins['len']
                continue
            # data up to the next instruction, label or note
            e = a + 1
            while e < end and e not in self.code and e not in self.labels and e not in self.notes_at:
                e += 1
            out.extend(self.render_data(a, e))
            a = e
        return out

    def render_ins(self, ins):
        a = ins['addr']
        text = ins['text']
        comment = []
        if is_aline(ins):
            w = int(ins['hex'][:4], 16)
            nm = hwmap.trap_name(w)
            flags = '' if hwmap.trap_exact(w) else hwmap.trap_flags(w)
            text = '_%s%s' % (nm, flags) if nm else 'dc.w    $%04X' % w
            comment.append('A-line trap %04X' % w)
        else:
            text = text.replace('; opcode 1111', '')
            if ins['hex'] == 'F0002400':          # 68030 PMMU PFLUSHA; MAME prints "pflushr 0, 0, D0"
                text = 'pflusha'
                comment.append('68030 MMU')
            ends, tgts, call = flow(ins)
            for t in tgts:
                t &= 0xFFFFFFFF
                nm = self.labels.get(t) or self.symbols.get(t)
                if nm:
                    text = re.sub(r'\$%x\b' % t, nm, text, flags=re.I, count=1)
                if not self.inside(t):
                    reg = self.regions(t)
                    comment.append('-> %s' % (nm + ' in ' + reg if nm and reg else (reg or 'outside')))
            for m in re.finditer(r'\$([0-9a-fA-F]+)\.w', text):
                v = int(m.group(1), 16)
                ln = hwmap.lowmem_name(v)
                if ln:
                    comment.append(ln)
            for m in re.finditer(r'\(\[\$([0-9a-fA-F]+)\]\)', text):
                v = int(m.group(1), 16)
                if v < 0x4000:
                    ln = hwmap.lowmem_name(v)
                    comment.append('through the vector at $%X%s' % (v, (' (' + ln + ')') if ln else ''))
            for m in re.finditer(r'\$([0-9a-fA-F]{5,8})(?:\.l)?', text):
                v = int(m.group(1), 16)
                hn = hwmap.hw_name(v)
                if hn:
                    comment.append(hn)
                elif v in self.symbols and v not in tgts:
                    comment.append(self.symbols[v])
        if a in self.comments:
            comment.append(self.comments[a])
        flag = self.status.get(a, ' ')
        line = '%08X%s %-20s %s' % (a, flag, ins['hex'], text)
        if comment:
            line = '%-72s ; %s' % (line, '; '.join(comment))
        return line

    def render_data(self, s, e):
        out = []
        kind = None
        if s in self.forced_kind:
            kind = self.forced_kind[s][1]
        a = s
        while a < e:
            # zero / fill runs
            z = a
            while z < e and self.data[z - self.base] == 0:
                z += 1
            if z - a >= 16:
                out.append('%08Xd %-20s .space  $%X%s; zero to %08X' % (a, '', z - a, ' ' * 18, z))
                a = z
                continue
            n = min(16, e - a)
            chunk = self.data[a - self.base:a - self.base + n]
            asc = ''.join(chr(c) if 0x20 <= c < 0x7F else '.' for c in chunk)
            line = '%08Xd %-20s dc.b    %s' % (a, chunk[:8].hex().upper(), ','.join('$%02X' % c for c in chunk))
            line = '%-72s ; |%s|' % (line, asc)
            if kind and a == s:
                line += ' ' + kind
            out.append(line)
            a += n
        return out
