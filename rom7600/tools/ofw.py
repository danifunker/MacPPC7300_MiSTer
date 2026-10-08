"""Open Firmware 1.0.5 in the 7600 ROM: the XCOFF bundle, the native Forth
kernel's dictionary headers, the tokenized (FCode) image that builds the rest
of the system at startup, and the dictionary and token table found in RAM
once Open Firmware has run.

Header layout (found by inspection, identical in ROM and RAM):
    +0  link     signed offset from this field to the previous header's link
    +4  flags    byte 0: 0x80 always, 0x40 immediate, 0x10 / 0x08 other flags
                 byte 1: kind (FCode defining token: B7 colon, BF code,
                         B8 value, B9 variable, BA constant, BB create,
                         BC defer, BD buffer:, DB field-like)
                 bytes 2-3: FCode token number
    +8  name     count byte and characters
    then padding to the next multiple of 8 (relative to the image start),
    then the code (native PowerPC: subroutine-threaded Forth) = the xt.
"""

import struct

KINDS = {0xB7: 'colon', 0xB8: 'value', 0xB9: 'variable', 0xBA: 'constant', 0xBB: 'create',
         0xBC: 'defer', 0xBD: 'buffer:', 0xBE: 'field', 0xBF: 'code', 0xDB: 'field?'}

# IEEE 1275 FCode token names (the standard set; the ROM's own headers and
# the names defined in its FCode image take precedence where they exist)
STD_FCODE = {
    0x00: 'end0', 0x10: 'b(lit)', 0x11: "b(')", 0x12: 'b(")', 0x13: 'bbranch', 0x14: 'b?branch',
    0x15: 'b(loop)', 0x16: 'b(+loop)', 0x17: 'b(do)', 0x18: 'b(?do)', 0x19: 'i', 0x1A: 'j',
    0x1B: 'b(leave)', 0x1C: 'b(of)', 0x1D: 'execute', 0x1E: '+', 0x1F: '-', 0x20: '*', 0x21: '/',
    0x22: 'mod', 0x23: 'and', 0x24: 'or', 0x25: 'xor', 0x26: 'invert', 0x27: 'lshift',
    0x28: 'rshift', 0x29: '>>a', 0x2A: '/mod', 0x2B: 'u/mod', 0x2C: 'negate', 0x2D: 'abs',
    0x2E: 'min', 0x2F: 'max', 0x30: '>r', 0x31: 'r>', 0x32: 'r@', 0x33: 'exit', 0x34: '0=',
    0x35: '0<>', 0x36: '0<', 0x37: '0<=', 0x38: '0>', 0x39: '0>=', 0x3A: '<', 0x3B: '>',
    0x3C: '=', 0x3D: '<>', 0x3E: 'u>', 0x3F: 'u<=', 0x40: 'u<', 0x41: 'u>=', 0x42: '>=',
    0x43: '<=', 0x44: 'between', 0x45: 'within', 0x46: 'drop', 0x47: 'dup', 0x48: 'over',
    0x49: 'swap', 0x4A: 'rot', 0x4B: '-rot', 0x4C: 'tuck', 0x4D: 'nip', 0x4E: 'pick',
    0x4F: 'roll', 0x50: '?dup', 0x51: 'depth', 0x52: '2drop', 0x53: '2dup', 0x54: '2over',
    0x55: '2swap', 0x56: '2rot', 0x57: '2/', 0x58: 'u2/', 0x59: '2*', 0x5A: '/c', 0x5B: '/w',
    0x5C: '/l', 0x5D: '/n', 0x5E: 'ca+', 0x5F: 'wa+', 0x60: 'la+', 0x61: 'na+', 0x62: 'char+',
    0x63: 'wa1+', 0x64: 'la1+', 0x65: 'cell+', 0x66: 'chars', 0x67: '/w*', 0x68: '/l*',
    0x69: 'cells', 0x6A: 'on', 0x6B: 'off', 0x6C: '+!', 0x6D: '@', 0x6E: 'l@', 0x6F: 'w@',
    0x70: '<w@', 0x71: 'c@', 0x72: '!', 0x73: 'l!', 0x74: 'w!', 0x75: 'c!', 0x76: '2@',
    0x77: '2!', 0x78: 'move', 0x79: 'fill', 0x7A: 'comp', 0x7B: 'noop', 0x7C: 'lwsplit',
    0x7D: 'wljoin', 0x7E: 'lbsplit', 0x7F: 'bljoin', 0x80: 'wbflip', 0x81: 'upc', 0x82: 'lcc',
    0x83: 'pack', 0x84: 'count', 0x85: 'body>', 0x86: '>body', 0x87: 'fcode-revision',
    0x88: 'span', 0x89: 'unloop', 0x8A: 'expect', 0x8B: 'alloc-mem', 0x8C: 'free-mem',
    0x8D: 'key?', 0x8E: 'key', 0x8F: 'emit', 0x90: 'type', 0x91: '(cr', 0x92: 'cr',
    0x93: '#out', 0x94: '#line', 0x95: 'hold', 0x96: '<#', 0x97: 'u#>', 0x98: 'sign',
    0x99: 'u#', 0x9A: 'u#s', 0x9B: 'u.', 0x9C: 'u.r', 0x9D: '.', 0x9E: '.r', 0x9F: '.s',
    0xA0: 'base', 0xA1: 'convert', 0xA2: '$number', 0xA3: 'digit', 0xA4: '-1', 0xA5: '0',
    0xA6: '1', 0xA7: '2', 0xA8: '3', 0xA9: 'bl', 0xAA: 'bs', 0xAB: 'bell', 0xAC: 'bounds',
    0xAD: 'here', 0xAE: 'aligned', 0xAF: 'wbsplit', 0xB0: 'bwjoin', 0xB1: 'b(<mark)',
    0xB2: 'b(>resolve)', 0xB3: 'set-token-table', 0xB4: 'set-table', 0xB5: 'new-token',
    0xB6: 'named-token', 0xB7: 'b(:)', 0xB8: 'b(value)', 0xB9: 'b(variable)',
    0xBA: 'b(constant)', 0xBB: 'b(create)', 0xBC: 'b(defer)', 0xBD: 'b(buffer:)',
    0xBE: 'b(field)', 0xBF: 'b(code)', 0xC0: 'instance', 0xC2: 'b(;)', 0xC3: 'b(to)',
    0xC4: 'b(case)', 0xC5: 'b(endcase)', 0xC6: 'b(endof)', 0xC7: '#', 0xC8: '#s', 0xC9: '#>',
    0xCA: 'external-token', 0xCB: '$find', 0xCC: 'offset16', 0xCD: 'evaluate', 0xD0: 'c,',
    0xD1: 'w,', 0xD2: 'l,', 0xD3: ',', 0xD4: 'um*', 0xD5: 'um/mod', 0xD8: 'd+', 0xD9: 'd-',
    0xDA: 'get-token', 0xDB: 'set-token', 0xDC: 'state', 0xDD: 'compile,', 0xDE: 'behavior',
    0xF0: 'start0', 0xF1: 'start1', 0xF2: 'start2', 0xF3: 'start4', 0xFC: 'ferror',
    0xFD: 'version1', 0xFE: '4-byte-id', 0xFF: 'end1',
    0x101: 'dma-alloc', 0x102: 'my-address', 0x103: 'my-space', 0x104: 'memmap',
    0x105: 'free-virtual', 0x106: '>physical', 0x10F: 'my-params', 0x110: 'property',
    0x111: 'encode-int', 0x112: 'encode+', 0x113: 'encode-phys', 0x114: 'encode-string',
    0x115: 'encode-bytes', 0x116: 'reg', 0x117: 'intr', 0x118: 'driver', 0x119: 'model',
    0x11A: 'device-type', 0x11B: 'parse-2int', 0x11C: 'is-install', 0x11D: 'is-remove',
    0x11E: 'is-selftest', 0x11F: 'new-device', 0x120: 'diagnostic-mode?',
    0x121: 'display-status', 0x122: 'memory-test-suite', 0x123: 'group-code', 0x124: 'mask',
    0x125: 'get-msecs', 0x126: 'ms', 0x127: 'finish-device', 0x128: 'decode-phys',
    0x12B: 'interpose', 0x130: 'map-low', 0x131: 'sbus-intr>cpu', 0x150: '#lines',
    0x151: '#columns', 0x152: 'line#', 0x153: 'column#', 0x154: 'inverse?',
    0x155: 'inverse-screen?', 0x156: 'frame-buffer-busy?', 0x157: 'draw-character',
    0x158: 'reset-screen', 0x159: 'toggle-cursor', 0x15A: 'erase-screen',
    0x15B: 'blink-screen', 0x15C: 'invert-screen', 0x15D: 'insert-characters',
    0x15E: 'delete-characters', 0x15F: 'insert-lines', 0x160: 'delete-lines',
    0x161: 'draw-logo', 0x162: 'frame-buffer-adr', 0x163: 'screen-height',
    0x164: 'screen-width', 0x165: 'window-top', 0x166: 'window-left', 0x16A: 'default-font',
    0x16B: 'set-font', 0x16C: 'char-height', 0x16D: 'char-width', 0x16E: '>font',
    0x16F: 'fontbytes', 0x180: 'fb8-draw-character', 0x181: 'fb8-reset-screen',
    0x182: 'fb8-toggle-cursor', 0x183: 'fb8-erase-screen', 0x184: 'fb8-blink-screen',
    0x185: 'fb8-invert-screen', 0x186: 'fb8-insert-characters', 0x187: 'fb8-delete-characters',
    0x188: 'fb8-insert-lines', 0x189: 'fb8-delete-lines', 0x18A: 'fb8-draw-logo',
    0x18B: 'fb8-install', 0x1A4: 'mac-address', 0x201: 'device-name', 0x202: 'my-args',
    0x203: 'my-self', 0x204: 'find-package', 0x205: 'open-package', 0x206: 'close-package',
    0x207: 'find-method', 0x208: 'call-package', 0x209: '$call-parent', 0x20A: 'my-parent',
    0x20B: 'ihandle>phandle', 0x20D: 'my-unit', 0x20E: '$call-method', 0x20F: '$open-package',
    0x210: 'processor-type', 0x211: 'firmware-version', 0x212: 'fcode-version', 0x213: 'alarm',
    0x214: '(is-user-word)', 0x215: 'suspend-fcode', 0x216: 'abort', 0x217: 'catch',
    0x218: 'throw', 0x219: 'user-abort', 0x21A: 'get-my-property', 0x21B: 'decode-int',
    0x21C: 'decode-string', 0x21D: 'get-inherited-property', 0x21E: 'delete-property',
    0x21F: 'get-package-property', 0x220: 'cpeek', 0x221: 'wpeek', 0x222: 'lpeek',
    0x223: 'cpoke', 0x224: 'wpoke', 0x225: 'lpoke', 0x226: 'lwflip', 0x227: 'lbflip',
    0x228: 'lbflips', 0x229: 'adr-mask', 0x230: 'rb@', 0x231: 'rb!', 0x232: 'rw@', 0x233: 'rw!',
    0x234: 'rl@', 0x235: 'rl!', 0x236: 'wbflips', 0x237: 'lwflips', 0x238: 'probe',
    0x239: 'probe-virtual', 0x23B: 'child', 0x23C: 'peer', 0x23D: 'next-property',
    0x23E: 'byte-load', 0x23F: 'set-args', 0x240: 'left-parse-string',
}

DEFINERS = {0xB7: ':', 0xB8: 'value', 0xB9: 'variable', 0xBA: 'constant', 0xBB: 'create',
            0xBC: 'defer', 0xBD: 'buffer:', 0xBE: 'field'}
BRANCHES = {0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1C, 0xC6}


def parse_xcoff(b, off):
    """XCOFF file header and section headers of the Open Firmware bundle."""
    magic, nscns, timdat, symptr, nsyms, opthdr, flags = struct.unpack_from('>HHIIIHH', b, off)
    secs = []
    p = off + 20 + opthdr
    for i in range(nscns):
        name = b[p:p + 8].rstrip(b'\0').decode('latin-1')
        paddr, vaddr, size, scnptr, relptr, lnnoptr, nreloc, nlnno, sflags = struct.unpack_from('>IIIIIIHHI', b, p + 8)
        secs.append({'name': name, 'paddr': paddr, 'vaddr': vaddr, 'size': size, 'scnptr': scnptr,
                     'flags': sflags, 'nreloc': nreloc})
        p += 40
    return {'magic': magic, 'nscns': nscns, 'timdat': timdat, 'symptr': symptr, 'nsyms': nsyms,
            'opthdr': opthdr, 'flags': flags, 'sections': secs}


def scan_headers(mem, lo, hi, origin):
    """Dictionary headers in mem[lo:hi]. origin is the offset that the image's
    8-byte alignment is relative to. Returns {offset: header dict}."""
    hdrs = {}
    for p in range(lo + ((origin - lo) % 4), hi - 12, 4):
        link = struct.unpack_from('>i', mem, p)[0]
        if not (-0x80000 < link < 0) or (p + link) % 4 != (p % 4):
            continue
        f0, kind = mem[p + 4], mem[p + 5]
        if not f0 & 0x80:
            continue
        if f0 & 0x20:
            # headerless definition: link and flags/token only, code at +8
            if kind not in KINDS or (origin - p) % 8:
                continue
            tok = struct.unpack_from('>H', mem, p + 6)[0]
            hdrs[p] = {'off': p, 'link': p + link, 'flags': f0, 'kind': kind, 'token': tok,
                       'name': None, 'xt': p + 8}
            continue
        n = mem[p + 8]
        if n == 0 or n > 63 or p + 9 + n > hi:
            continue
        name = mem[p + 9:p + 9 + n]
        if not all(0x21 <= c < 0x7F for c in name):
            continue
        tok = struct.unpack_from('>H', mem, p + 6)[0]
        end = p + 9 + n
        xt = end + ((origin - end) % 8)
        hdrs[p] = {'off': p, 'link': p + link, 'flags': f0, 'kind': kind, 'token': tok,
                   'name': name.decode('latin-1'), 'xt': xt}
    # keep headers whose link reaches another header, or that start a chain
    linked = {h['link'] for h in hdrs.values()}
    out = {}
    for p, h in hdrs.items():
        if h['link'] in hdrs or p in linked:
            out[p] = h
    return out


def wordlists(hdrs):
    """Groups headers into chains: {head offset: [offsets newest first]}."""
    pointed = {h['link'] for h in hdrs.values()}
    chains = {}
    for p in sorted(hdrs):
        if p in pointed:
            continue
        seq = []
        q = p
        seen = set()
        while q in hdrs and q not in seen:
            seen.add(q)
            seq.append(q)
            q = hdrs[q]['link']
        chains[p] = seq
    return chains


class Detokenizer:
    """Turns the ROM's FCode image back into Forth-like text. Token numbers
    after new-token/named-token/external-token are encoded like tokens (one
    byte below 0x100, else two), which differs from the IEEE 1275 encoding."""

    def __init__(self, data, start, names):
        self.d = data
        self.start = start
        self.names = dict(STD_FCODE)
        self.names.update(names)
        self.defs = {}          # token -> {name, kind, offset, visibility}
        self.offset16 = False

    def token(self, p):
        t = self.d[p]
        if 0x01 <= t <= 0x0F:
            return (t << 8) | self.d[p + 1], p + 2
        return t, p + 1

    def name_of(self, t):
        return self.names.get(t, 'tok_%03X' % t)

    def run(self, limit):
        d = self.d
        p = self.start
        out = []
        hdr = d[p]
        if hdr in (0xF0, 0xF1, 0xF2, 0xF3, 0xFD):
            fmt, csum, length = d[p + 1], struct.unpack_from('>H', d, p + 2)[0], struct.unpack_from('>I', d, p + 4)[0]
            out.append((p, '\\ FCode header: %s format %02X checksum %04X length %X' % (
                STD_FCODE[hdr], fmt, csum, length)))
            self.offset16 = hdr != 0xFD
            end = min(limit, p + length)
            p += 8
        else:
            end = limit
        line = []
        line_at = p
        indent = 0

        def flush():
            nonlocal line, line_at
            if line:
                out.append((line_at, '  ' * indent + ' '.join(line)))
            line = []

        while p < end:
            at = p
            t, p = self.token(p)
            if not line:
                line_at = at
            if t == 0x00 or t == 0xFF:
                flush()
                out.append((at, '\\ %s' % STD_FCODE[t]))
                break
            if t == 0x10:
                v = struct.unpack_from('>I', d, p)[0]
                p += 4
                line.append('h# %X' % v if v > 9 else str(v))
            elif t == 0x11 or t == 0xC3 or t == 0xDA or t == 0xDB:
                t2, p = self.token(p)
                pre = {0x11: "[']", 0xC3: 'to', 0xDA: "get-token'", 0xDB: "set-token'"}[t]
                line.append('%s %s' % (pre, self.name_of(t2)))
            elif t == 0x12:
                n = d[p]
                raw = d[p + 1:p + 1 + n]
                p += 1 + n
                # IEEE 1275 string syntax: bytes outside printable ASCII as "(hh hh)
                s = ''
                k = 0
                while k < len(raw):
                    if 0x20 <= raw[k] < 0x7F and raw[k] != 0x22:
                        s += chr(raw[k])
                        k += 1
                    else:
                        e = k
                        while e < len(raw) and not (0x20 <= raw[e] < 0x7F and raw[e] != 0x22):
                            e += 1
                        s += '"(' + ' '.join('%02X' % c for c in raw[k:e]) + ')'
                        k = e
                line.append('" %s"' % s)
            elif t in BRANCHES:
                if self.offset16:
                    off = struct.unpack_from('>h', d, p)[0]
                    p += 2
                else:
                    off = struct.unpack_from('>b', d, p)[0]
                    p += 1
                tgt = at + 1 + off if not self.offset16 else at + 1 + off
                line.append('%s(%+d->%X)' % (STD_FCODE[t], off, tgt))
            elif t == 0xCC:
                self.offset16 = True
                line.append('offset16')
            elif t == 0x401:                   # Apple: start of locals, one count byte
                line.append('{(%d)' % d[p])
                p += 1
            elif 0x410 <= t <= 0x417:          # Apple: fetch local n
                line.append('l%d' % (t - 0x410))
            elif 0x418 <= t <= 0x41F:          # Apple: store into local n
                line.append('->l%d' % (t - 0x418))
            elif t in (0xB5, 0xB6, 0xCA):
                flush()
                name = None
                if t != 0xB5:
                    n = d[p]
                    name = d[p + 1:p + 1 + n].decode('latin-1')
                    p += 1 + n
                tok, p = self.token(p)
                kind_t = d[p]
                kind = DEFINERS.get(kind_t, '?%02X' % kind_t)
                p += 1
                vis = {0xB5: 'headerless', 0xB6: 'named', 0xCA: 'external'}[t]
                if name:
                    self.names[tok] = name
                elif tok not in self.names or self.names[tok].startswith('tok_'):
                    self.names[tok] = 'tok_%03X' % tok
                self.defs[tok] = {'name': name, 'kind': kind, 'offset': at, 'vis': vis}
                shown = name if name else self.names[tok]
                if kind == ':':
                    out.append((at, ': %s   \\ token %03X %s' % (shown, tok, vis)))
                    indent = 1
                else:
                    out.append((at, '%s %s   \\ token %03X %s' % (kind, shown, tok, vis)))
                line_at = p
            elif t == 0xC2:
                line.append(';')
                flush()
                indent = 0
            else:
                line.append(self.name_of(t))
            if len(line) >= 12:
                flush()
        flush()
        return out, p
