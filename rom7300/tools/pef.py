"""Reader for PEF containers ('Joy!peffpwpc'), the Code Fragment Manager's
format, as found in the ROM's ncod/nlib/ndrv/nitt resources.

Parses the section table, the loader section (imports, exports, main/init/
term entry points, relocations) and unpacks pattern-initialized data, so that
the code listings can name exported functions, TOC entries and the cross-TOC
glue that calls imported functions. Layout per Apple's PEFBinaryFormat.h."""

import struct

SECTION_KINDS = {0: 'code', 1: 'data', 2: 'pidata', 3: 'constant', 4: 'loader',
                 5: 'debug', 6: 'execdata', 7: 'exception', 8: 'traceback'}
SYMBOL_CLASSES = {0: 'code', 1: 'data', 2: 'tvector', 3: 'toc', 4: 'glue'}


def _u32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def _s32(b, o):
    return struct.unpack_from('>i', b, o)[0]


def _u16(b, o):
    return struct.unpack_from('>H', b, o)[0]


def _cstr(b, o):
    e = b.index(b'\0', o)
    return b[o:e].decode('mac_roman')


class Section:
    def __init__(self, idx, b, o):
        (self.name_off, self.default_addr, self.total_len, self.unpacked_len,
         self.container_len, self.container_off) = struct.unpack_from('>iIIIII', b, o)
        self.kind, self.share, self.align = b[o + 24], b[o + 25], b[o + 26]
        self.index = idx
        self.name = None

    @property
    def kind_name(self):
        return SECTION_KINDS.get(self.kind, 'kind%d' % self.kind)


def unpack_pidata(raw, size):
    """Expands pattern-initialized data to its unpacked image."""
    out = bytearray()
    i = 0

    def varint():
        nonlocal i
        v = 0
        while True:
            c = raw[i]
            i += 1
            v = (v << 7) | (c & 0x7F)
            if not c & 0x80:
                return v

    while i < len(raw):
        op = raw[i]
        i += 1
        code, count = op >> 5, op & 0x1F
        if count == 0:
            count = varint()
        if code == 0:                         # zero fill
            out += bytes(count)
        elif code == 1:                       # block copy
            out += raw[i:i + count]
            i += count
        elif code == 2:                       # repeated block
            rep = varint() + 1
            blk = raw[i:i + count]
            i += count
            out += blk * rep
        elif code == 3:                       # interleave common data with custom data
            custom = varint()
            rep = varint()
            common = raw[i:i + count]
            i += count
            out += common
            for _ in range(rep):
                out += raw[i:i + custom]
                i += custom
                out += common
        elif code == 4:                       # interleave zeros with custom data
            custom = varint()
            rep = varint()
            out += bytes(count)
            for _ in range(rep):
                out += raw[i:i + custom]
                i += custom
                out += bytes(count)
        else:
            raise ValueError('bad pidata opcode %d' % code)
    if len(out) < size:
        out += bytes(size - len(out))
    return bytes(out)


class PEF:
    def __init__(self, data, base_off=0):
        """data: bytes starting at the container; base_off: its ROM offset."""
        self.data = data
        self.base_off = base_off
        if data[:12] != b'Joy!peffpwpc':
            raise ValueError('not a PowerPC PEF container')
        (self.format_version, self.timestamp, self.old_def_version, self.old_imp_version,
         self.current_version) = struct.unpack_from('>IIIII', data, 12)
        self.section_count, self.inst_section_count = struct.unpack_from('>HH', data, 32)
        self.sections = [Section(i, data, 40 + 28 * i) for i in range(self.section_count)]
        self.size = max((s.container_off + s.container_len for s in self.sections), default=40)
        self.imports, self.libraries, self.exports = [], [], []
        self.main = self.init = self.term = None
        self.relocs = {}               # section index -> {offset: ('sect', idx) | ('import', n)}
        self.loader = None
        for s in self.sections:
            if s.kind == 4:
                self.loader = s
        if self.loader:
            self._parse_loader()
        for s in self.sections:
            if s.name_off >= 0 and self.loader:
                try:
                    s.name = _cstr(self.data, self.loader.container_off + self.lstr + s.name_off)
                except ValueError:
                    s.name = None

    def section_image(self, s):
        """The section's unpacked contents (as instantiated, before relocation)."""
        raw = self.data[s.container_off:s.container_off + s.container_len]
        if s.kind == 2:
            return unpack_pidata(raw, s.unpacked_len)
        img = bytes(raw)
        if s.unpacked_len > len(img):
            img += bytes(s.unpacked_len - len(img))
        return img

    def _parse_loader(self):
        b, lo = self.data, self.loader.container_off
        (ms, mo, is_, io, ts, to, nlib, nimp, nrel, relinstr, lstr, hashoff, hashpow,
         nexp) = struct.unpack_from('>iIiIiIIIIIIIII', b, lo)
        self.lstr = lstr
        if ms >= 0:
            self.main = (ms, mo)
        if is_ >= 0:
            self.init = (is_, io)
        if ts >= 0:
            self.term = (ts, to)

        def lname(off):
            return _cstr(b, lo + lstr + off)

        p = lo + 56
        for i in range(nlib):
            name_off, oldimp, cur, cnt, first, opts = struct.unpack_from('>IIIIIB', b, p)
            self.libraries.append({'name': lname(name_off), 'count': cnt, 'first': first,
                                   'options': opts, 'old_imp': oldimp, 'current': cur})
            p += 24
        for i in range(nimp):
            w = _u32(b, p)
            cls, off = w >> 24, w & 0xFFFFFF
            self.imports.append({'name': lname(off), 'class': cls & 0xF, 'weak': bool(cls & 0x80)})
            p += 4
        for lib in self.libraries:
            for k in range(lib['first'], lib['first'] + lib['count']):
                if k < len(self.imports):
                    self.imports[k]['lib'] = lib['name']
        relhdrs = []
        for i in range(nrel):
            sidx, _, cnt, first = struct.unpack_from('>HHII', b, p)
            relhdrs.append((sidx, cnt, first))
            p += 12
        for sidx, cnt, first in relhdrs:
            try:
                self.relocs[sidx] = self._run_relocs(lo + relinstr + first, cnt, sidx)
            except (IndexError, struct.error, ValueError):
                self.relocs[sidx] = {}
        # exports: hash table, key table, symbol table
        nhash = 1 << hashpow
        keys = lo + hashoff + 4 * nhash
        syms = keys + 4 * nexp
        for i in range(nexp):
            klen = _u32(b, keys + 4 * i) >> 16
            w, val, sec = struct.unpack_from('>IIh', b, syms + 10 * i)
            off = w & 0xFFFFFF
            name = b[lo + lstr + off:lo + lstr + off + klen].decode('mac_roman')
            self.exports.append({'name': name, 'class': (w >> 24) & 0xF, 'value': val, 'section': sec})

    def _run_relocs(self, p, count, sidx):
        """Interprets the relocation instructions for one section; returns
        {byte offset: ('sect', n) or ('import', n)}."""
        b = self.data
        words = [_u16(b, p + 2 * i) for i in range(count)]
        out = {}
        pos = 0
        imp = 0
        sect_c, sect_d = 0, 1
        i = 0
        history = []                     # (start index of each instruction) for repeats

        def run(i, depth=0):
            nonlocal pos, imp, sect_c, sect_d
            w = words[i]
            n = 1
            if w >> 14 == 0:                                # RelocBySectDWithSkip
                skip, cnt = (w >> 6) & 0xFF, w & 0x3F
                pos += 4 * skip
                for _ in range(cnt):
                    out[pos] = ('sect', sect_d)
                    pos += 4
            elif w >> 13 == 0b010:                           # run group
                sub, length = (w >> 9) & 0xF, (w & 0x1FF) + 1
                for _ in range(length):
                    if sub == 0:
                        out[pos] = ('sect', sect_c); pos += 4
                    elif sub == 1:
                        out[pos] = ('sect', sect_d); pos += 4
                    elif sub == 2:
                        out[pos] = ('sect', sect_c); out[pos + 4] = ('sect', sect_d); pos += 12
                    elif sub == 3:
                        out[pos] = ('sect', sect_c); out[pos + 4] = ('sect', sect_d); pos += 8
                    elif sub == 4:
                        out[pos] = ('sect', sect_d); pos += 8
                    elif sub == 5:
                        out[pos] = ('import', imp); imp += 1; pos += 4
                    else:
                        raise ValueError('reloc run sub %d' % sub)
            elif w >> 13 == 0b011:                           # small index group
                sub, idx = (w >> 9) & 0xF, w & 0x1FF
                if sub == 0:
                    out[pos] = ('import', idx); imp = idx + 1; pos += 4
                elif sub == 1:
                    sect_c = idx
                elif sub == 2:
                    sect_d = idx
                elif sub == 3:
                    out[pos] = ('sect', idx); pos += 4
                else:
                    raise ValueError('reloc small sub %d' % sub)
            elif w >> 12 == 0b1000:                          # increment position
                pos += (w & 0xFFF) + 1
            elif w >> 12 == 0b1001:                          # small repeat
                blocks, rep = ((w >> 8) & 0xF) + 1, (w & 0xFF) + 1
                start = len(history) - blocks
                seq = history[start:len(history)]
                for _ in range(rep):
                    for j in seq:
                        run(j, depth + 1)
            elif w >> 10 == 0b101000:                        # set position
                pos = ((w & 0x3FF) << 16) | words[i + 1]; n = 2
            elif w >> 10 == 0b101001:                        # large by import
                idx = ((w & 0x3FF) << 16) | words[i + 1]; n = 2
                out[pos] = ('import', idx); imp = idx + 1; pos += 4
            elif w >> 10 == 0b101100:                        # large repeat
                blocks = ((w >> 6) & 0xF) + 1
                rep = (((w & 0x3F) << 16) | words[i + 1]) + 1; n = 2
                start = len(history) - blocks
                seq = history[start:len(history)]
                for _ in range(rep):
                    for j in seq:
                        run(j, depth + 1)
            elif w >> 10 == 0b101101:                        # large set or by section
                sub = (w >> 6) & 0xF
                idx = ((w & 0x3F) << 16) | words[i + 1]; n = 2
                if sub == 0:
                    out[pos] = ('sect', idx); pos += 4
                elif sub == 1:
                    sect_c = idx
                elif sub == 2:
                    sect_d = idx
            else:
                raise ValueError('reloc opcode %04X' % w)
            return n

        while i < len(words):
            w = words[i]
            is_repeat = (w >> 12 == 0b1001) or (w >> 10 == 0b101100)
            n = run(i)
            if not is_repeat:
                history.append(i)
            i += n
        return out

    def code_names(self):
        """{(section index, offset): name} for code reached from exports and
        the main/init/term entry points, through their transition vectors."""
        names = {}
        images = {}

        def image(si):
            if si not in images:
                images[si] = self.section_image(self.sections[si])
            return images[si]

        def via_tvector(si, off, name):
            s = self.sections[si]
            if s.kind == 0:
                names[(si, off)] = name
                return
            rel = self.relocs.get(si, {})
            r = rel.get(off)
            if r and r[0] == 'sect' and r[1] < len(self.sections) and self.sections[r[1]].kind == 0:
                img = image(si)
                if off + 4 <= len(img):
                    names[(r[1], _u32(img, off))] = name

        for e in self.exports:
            if e['section'] >= 0 and e['section'] < len(self.sections):
                via_tvector(e['section'], e['value'], e['name'])
        for label, ent in (('__main', self.main), ('__init', self.init), ('__term', self.term)):
            if ent:
                via_tvector(ent[0], ent[1], label)
        return names

    def toc_bases(self):
        """Data-section offsets that exported transition vectors load into r2."""
        bases = {}
        for e in list(self.exports) + [{'section': m[0], 'value': m[1]} for m in (self.main, self.init, self.term) if m]:
            si = e['section']
            if si < 0 or si >= len(self.sections) or self.sections[si].kind == 0:
                continue
            rel = self.relocs.get(si, {})
            off = e['value']
            r = rel.get(off + 4)
            if r and r[0] == 'sect':
                img = self.section_image(self.sections[si])
                if off + 8 <= len(img):
                    bases[(r[1], _u32(img, off + 4))] = bases.get((r[1], _u32(img, off + 4)), 0) + 1
        return bases

    def data_symbols(self, si):
        """{offset: text} for relocated words of a data section: imports by
        name, pointers into code by offset."""
        out = {}
        img = None
        for off, r in self.relocs.get(si, {}).items():
            if r[0] == 'import':
                if r[1] < len(self.imports):
                    imp = self.imports[r[1]]
                    out[off] = ('import', '%s::%s' % (imp.get('lib', '?'), imp['name']))
            else:
                if img is None:
                    img = self.section_image(self.sections[si])
                if off + 4 <= len(img) and r[1] < len(self.sections):
                    out[off] = ('sect', r[1], _u32(img, off))
        return out
