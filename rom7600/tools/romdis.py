#!/usr/bin/env python3
"""Generates the annotated disassembly of the Power Macintosh 7600 ROM
(077D.28F2, Open Firmware 1.0.5) into ../ (see ../README.md).

    python3 romdis.py --rom ROM --cov COVDIR --out OUTDIR [--build DIR]
                      [--mame DIR] [--snow DIR]

COVDIR is the output of run_cov.sh (romcov); without it the listings have
no execution marks. Runs under WSL/Linux (the disassemblers are built there
by build.sh)."""

import argparse
import collections
import os
import re
import struct
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import annotations        # noqa: E402
import hwmap              # noqa: E402
import layout             # noqa: E402
import m68klist           # noqa: E402
import ofw                # noqa: E402
import pef                # noqa: E402
import ppclist            # noqa: E402
import romctx             # noqa: E402

ROM_BASE = 0xFFC00000
EMU_EA = 0x68060000          # LA_EmulatorCode
TBL_EA = 0x68080000          # LA_DispatchTable
OF_EA = 0xFF800000           # LA_OpenFirmware
OF_PA = 0x00400000           # PA_OpenFirmware
OF_DUMP = 27400000           # RAM dump with Open Firmware fully built

VECTORS = {
    0x0100: 'reset', 0x0200: 'machine_check', 0x0300: 'dsi', 0x0400: 'isi',
    0x0500: 'external', 0x0600: 'alignment', 0x0700: 'program', 0x0800: 'fp_unavailable',
    0x0900: 'decrementer', 0x0A00: 'reserved_0A00', 0x0B00: 'reserved_0B00',
    0x0C00: 'system_call', 0x0D00: 'trace', 0x0E00: 'fp_assist', 0x0F00: 'perf_monitor_604',
    0x1000: 'itlb_miss_603', 0x1100: 'dtlb_load_miss_603', 0x1200: 'dtlb_store_miss_603',
    0x1300: 'iabr', 0x1400: 'smi', 0x2000: 'run_mode_601',
}

PEF_TYPES = ('ncod', 'nlib', 'ndrv', 'nitt')
M68K_CODE_TYPES = ('CDEF', 'WDEF', 'LDEF', 'MDEF', 'PACK', 'DRVR', 'proc', 'sift', 'adio',
                   'GARY', 'gcko', 'daud', 'dimg', 'sl00', 'sl01', 'sl02', 'sl04', 'sl05',
                   'sl06', 'sl07')


def log(msg):
    sys.stderr.write('[%s] %s\n' % (time.strftime('%H:%M:%S'), msg))
    sys.stderr.flush()


def hexdump(data, addr, width=16):
    out = []
    i = 0
    n = len(data)
    while i < n:
        chunk = data[i:i + width]
        if chunk.count(0) == len(chunk):
            j = i
            while j < n and data[j:j + width].count(0) == len(data[j:j + width]):
                j += width
            if j - i > 2 * width:
                out.append('%08X  ... %X zero bytes ...' % (addr + i, min(j, n) - i))
                i = j
                continue
        hx = ' '.join('%02X' % c for c in chunk)
        asc = ''.join(chr(c) if 0x20 <= c < 0x7F else '.' for c in chunk)
        out.append('%08X  %-*s  |%s|' % (addr + i, width * 3 - 1, hx, asc))
        i += width
    return out


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        for l in lines:
            f.write(l.rstrip() + '\n')


def safe(s):
    return re.sub(r'[^A-Za-z0-9_.-]+', '_', s).strip('_') or 'x'


class Gen:
    def __init__(self, args):
        self.args = args
        self.rom = romctx.Rom(args.rom)
        self.d = self.rom.data
        self.cov = romctx.Coverage(args.cov)
        self.out = args.out
        self.tools = ppclist.Tools(args.build, args.tmp)
        nt, nl = hwmap.load_tables(args.mame, args.snow)
        log('trap names %d, low-memory names %d' % (nt, nl))
        self.regions = []            # (start, end, name, file, how)
        self.symbols = {}            # address -> name (global)
        self.files = []
        self.ram_copies = []         # (ram_lo, ram_hi, rom_off)
        self.stats = collections.OrderedDict()

    # ---- helpers -------------------------------------------------------------

    def region(self, start, end, name, file, how):
        self.regions.append((start, end, name, file, how))

    def region_of(self, addr):
        """Name of the ROM region a physical or mapped address falls in."""
        if EMU_EA <= addr < EMU_EA + 0x20000:
            addr = addr - EMU_EA + 0xFFF60000
        elif TBL_EA <= addr < TBL_EA + 0x80000:
            addr = addr - TBL_EA + 0xFFF80000
        elif OF_EA <= addr < OF_EA + 0x100000:
            return 'Open Firmware (RAM)'
        if addr < ROM_BASE:
            if addr >= 0xF0000000:
                return hwmap.hw_name(addr) or 'I/O'
            return None
        off = addr - ROM_BASE
        for s, e, name, f, how in getattr(self, 'detail_regions', []):
            if s <= off < e:
                return name
        for s, e, name, f, how in self.regions:
            if s <= off < e:
                return name
        return None

    def ppc_exec(self, pa):
        if self.cov.rom_executed(pa):
            return True
        off = pa - ROM_BASE
        for lo, hi, ro in self.ram_copies:
            if ro <= off < ro + (hi - lo):
                if self.cov.ram_executed(lo + off - ro):
                    return True
        return False

    def lines_header(self, title, info):
        h = ['; ' + '=' * 76, '; ' + title, '; ' + '=' * 76]
        for i in info:
            h.append('; ' + i if i else ';')
        h.append(';')
        h.append('; Columns: address, flag, raw bytes, instruction, ; comment.')
        h.append(";   flag '*' executed in the coverage run, ' ' reached by control flow,")
        h.append(";   '?' decodes as code but neither executed nor reached, 'd' data.")
        h.append('')
        return h

    # ---- RAM copies of ROM code ----------------------------------------------

    def find_ram_copies(self):
        rf = self.cov.ram_first
        if not len(rf):
            return
        dumps = {}
        for ic in (OF_DUMP, 1000000000, 400000000):
            dmp = self.cov.ram_dump(ic)
            if dmp:
                dumps[ic] = dmp
        if not dumps:
            return
        runs = []
        start = None
        for i in range(len(rf)):
            if rf[i] and start is None:
                start = i
            elif not rf[i] and start is not None:
                if runs and start - runs[-1][1] < 256:
                    runs[-1][1] = i
                else:
                    runs.append([start, i])
                start = None
        found = []
        for s, e in runs:
            lo, hi = s * 4, e * 4
            first = min(rf[j] for j in range(s, e) if rf[j])
            order = sorted(dumps, key=lambda ic: (ic < first, ic))
            for ic in order:
                mem = dumps[ic]
                probe = mem[lo:lo + 32]
                if probe.count(0) > 24:
                    continue
                ro = self.d.find(probe)
                if ro < 0:
                    continue
                same = sum(1 for k in range(lo, hi, 4) if mem[k:k + 4] == self.d[ro + k - lo:ro + k - lo + 4])
                if same * 10 >= (hi - lo) // 4 * 8:
                    found.append((lo, hi, ro, first, ic))
                    break
        # extend OF copy to the whole kernel text when it starts there
        self.ram_copies = [(lo, hi, ro) for lo, hi, ro, f, ic in found]
        self.ram_copy_info = found
        log('RAM copies of ROM code: %d runs' % len(found))

    # ---- layout --------------------------------------------------------------

    def parse(self):
        d = self.d
        self.hdr68k = layout.header68k(d)
        self.rsrc_hdr, self.rsrc_first, self.res = layout.resources(d)
        self.res_by_data = sorted(self.res, key=lambda r: r['data'])
        self.ci_off = 0x30D000
        self.ci = layout.configinfo_dict(d, self.ci_off)
        self.disp = struct.unpack_from('>I', d, 0x22)[0]
        self.xcoff = ofw.parse_xcoff(d, self.ci_off + self.ci['OpenFWBundleOffset'])
        self.declrom = layout.declrom(d, 0x300000)
        self.pefs = {}
        for r in self.res:
            if d[r['data']:r['data'] + 8] == b'Joy!peff':
                try:
                    self.pefs[r['data']] = pef.PEF(d[r['data']:r['data'] + r['size']], r['data'])
                except Exception as ex:  # noqa: BLE001
                    log('PEF at %06X: %s' % (r['data'], ex))
        # MacsBug names in the 68k ROM
        self.macsbug = {}
        pat = re.compile(rb'(\x4e\x75|\x4e\xd0|\x4e\x73|\x4e\x74..)([\x81-\x9f])([A-Za-z_%.][A-Za-z0-9_%.]{1,30})')
        for m in pat.finditer(d[:0x300000]):
            n = m.group(2)[0] & 0x7F
            name = m.group(3)[:n]
            if len(name) == n:
                self.macsbug[m.start(2)] = name.decode('latin-1')
        # trap tables
        self.traps = {}
        tb = [struct.unpack_from('>I', d, self.disp + 4 * i)[0] for i in range(1024)]
        os_ = [struct.unpack_from('>I', d, self.disp + 0x1000 + 4 * i)[0] for i in range(256)]
        os2 = [struct.unpack_from('>I', d, self.disp + 0x1400 + 4 * i)[0] for i in range(256)]
        self.trap_tb, self.trap_os, self.trap_os2 = tb, os_, os2
        for i, v in enumerate(tb):
            if v:
                nm = hwmap.trap_name(0xA800 | i)
                self.traps.setdefault(ROM_BASE + v, '_' + nm if nm else '_trap_A%03X' % (0x800 | i))
        for i, v in enumerate(os_):
            if v:
                nm = hwmap.trap_name(0xA000 | i)
                self.traps.setdefault(ROM_BASE + v, '_' + nm if nm else '_trap_A0%02X' % i)

    def build_symbols(self):
        S = self.symbols
        for v, nm in VECTORS.items():
            S[0xFFF00000 + v] = 'vec_%04X_%s' % (v, nm)
        ci = self.ci
        S[EMU_EA + ci['EmulatorEntryOffset']] = 'EmulatorEntry'
        S[EMU_EA + ci['KernelTrapTableOffset']] = 'KernelTrapTable'
        S[0xFFF60000 + ci['EmulatorEntryOffset']] = 'EmulatorEntry'
        for a, nm in self.traps.items():
            S.setdefault(a, nm)
        for off, p in self.pefs.items():
            r = next(x for x in self.res if x['data'] == off)
            lib = r['name'] or '%s%d' % (r['type'], r['id'])
            code_secs = {s.index: s for s in p.sections if s.kind == 0}
            for (si, o), nm in p.code_names().items():
                if si in code_secs:
                    S.setdefault(ROM_BASE + off + code_secs[si].container_off + o, '%s::%s' % (lib, nm))

    # ---- region list ---------------------------------------------------------

    def plan_regions(self):
        ci = self.ci
        R = self.region
        R(0x000000, 0x0D3500, '68k ROM: header and code', '68k/68k_main_FFC00000.lst',
          'ROM header (RomSize 0x300000, DispTableOff, RomRsrc); 68k execution under the emulator')
        R(0x0D3500, 0x0D4D00, '68k trap dispatch tables', '68k/68k_traptable_FFCD3500.txt',
          'header DispTableOff = 0x0D3500; entries match the RAM trap tables at $E00/$400 after boot')
        R(0x0D4D00, 0x0D4D10, 'ROM resource list header', 'resources/resources.txt', 'header RomRsrc = 0x0D4D00')
        self.detail_regions = []
        for r in self.res_by_data:
            kind = 'PEF' if r['data'] in self.pefs else ('68k code' if r['type'] in M68K_CODE_TYPES else 'data')
            self.detail_regions.append((r['data'] - 16, r['data'] + r['size'],
                                        "resource '%s' %d %s (%s)" % (r['type'], r['id'], r['name'], kind),
                                        'resources/' + self.res_file(r), 'ROM resource list entry at %06X' % r['entry']))
        rend = max(max(r['data'] + r['size'], r['entry'] + r['entry_size']) for r in self.res)
        npef = sum(1 for r in self.res if r['data'] in self.pefs)
        n68k = sum(1 for r in self.res if r['type'] in M68K_CODE_TYPES)
        R(0x0D4D10, rend, 'ROM resources: %d (%d PEF, %d 68k code, %d data), entries interleaved' % (
            len(self.res), npef, n68k, len(self.res) - npef - n68k), 'resources/ (index resources.txt)',
          'resource list from header RomRsrc; data blocks tagged "Kurt"')
        if rend < self.declrom['start']:
            R(rend, self.declrom['start'], 'fill ("kc" pattern)', '', 'pattern 6B63')
        dr = self.declrom
        R(dr['start'], 0x300000, 'slot 0 declaration ROM (DeclROM)', '68k/68k_declrom_FFEFFED4.txt',
          'format block at the top of the 68k ROM: test pattern 5A932BC7, length %X' % dr['length'])
        b = 0x30D000
        R(b + ci['ExceptionTableOffset'], b + ci['ExceptionTableOffset'] + ci['ExceptionTableSize'],
          'PowerPC exception vectors and boot code', 'ppc/ppc_boot_FFF00000.lst',
          'ConfigInfo ExceptionTableOffset/Size; reset fetch at FFF00100')
        R(0x30C000, 0x30D000, 'LA_HardwarePriv (empty)', 'ppc/ppc_configinfo_FFF0D000.txt', 'ConfigInfo LA_HardwarePriv = FFF0C000')
        R(0x30D000, 0x30E000, 'ConfigInfo (NanoKernel configuration)', 'ppc/ppc_configinfo_FFF0D000.txt',
          'BootstrapVersion "Boot TNT 0.1p"; ROMImageBaseOffset = -0x30D000')
        R(b + ci['KernelCodeOffset'], b + ci['KernelCodeOffset'] + ci['KernelCodeSize'], 'NanoKernel',
          'ppc/ppc_nanokernel_FFF10000.lst', 'ConfigInfo KernelCodeOffset/Size; executed with MSR IR=0 in place')
        R(b + ci['HWInitCodeOffset'], b + ci['HWInitCodeOffset'] + ci['HWInitCodeSize'], 'HWInit / diagnostics',
          'ppc/ppc_hwinit_FFF20000.lst', 'ConfigInfo HWInitCodeOffset/Size; Serial Test Manager strings')
        R(b + ci['OpenFWBundleOffset'], b + ci['OpenFWBundleOffset'] + ci['OpenFWBundleSize'],
          'Open Firmware 1.0.5 bundle (XCOFF)', 'ppc/ppc_openfirmware_FFF30000.lst',
          'ConfigInfo OpenFWBundleOffset/Size; XCOFF magic 01DF; kernel copied to PA 00408000 = EA FF808000')
        R(b + ci['EmulatorCodeOffset'], b + ci['EmulatorCodeOffset'] + ci['EmulatorCodeSize'], '68k emulator',
          'ppc/ppc_emulator_68060000.lst', 'ConfigInfo EmulatorCodeOffset/Size; runs mapped at LA_EmulatorCode 68060000')
        R(b + ci['OpcodeTableOffset'], b + ci['OpcodeTableOffset'] + ci['OpcodeTableSize'],
          '68k emulator opcode dispatch table', 'ppc/ppc_opcodetable_68080000.lst',
          'ConfigInfo OpcodeTableOffset/Size; 8 bytes per 68k opcode; mapped at LA_DispatchTable 68080000')

    def res_file(self, r):
        nm = ('_' + safe(r['name'])) if r['name'] else ''
        ext = '.lst' if (r['data'] in self.pefs or r['type'] in M68K_CODE_TYPES) else '.txt'
        return '%06X_%s_%d%s%s' % (r['data'], safe(r['type']), r['id'], nm, ext)

    # ---- PowerPC regions -----------------------------------------------------

    def ppc_region(self, off, size, base, title, info, *, roots=(), labels=None, data_ranges=(),
                   comments=None, notes=None, exe=None, toc=None, path=None):
        data = self.d[off:off + size]
        exe = exe or (lambda a: self.ppc_exec(a - base + ROM_BASE + off))
        lab = dict(labels or {})
        for a, nm in self.symbols.items():
            if base <= a < base + size and a not in lab:
                lab[a] = nm.replace('::', '.')
        L = ppclist.Listing(self.tools, data, base, executed=exe, labels=lab, comments=comments,
                            data_ranges=list(data_ranges), roots=roots, symbols=self.symbols,
                            regions=self.region_of, toc=toc, notes_at=notes).build()
        body = L.render()
        n_exe = sum(1 for x in L.exe if x)
        n_code = sum(1 for x in L.isdata if not x)
        self.stats[title] = 'words %d, code %d, executed %d' % (size // 4, n_code, n_exe)
        if path:
            write(os.path.join(self.out, path), self.lines_header(title, info) + body)
            self.files.append(path)
        return L, body

    def gen_boot(self):
        off, size = 0x300000, self.ci['ExceptionTableSize']
        roots = [0xFFF00000 + v for v in VECTORS]
        info = ['ROM offset 300000-%06X, physical FFF00000-%08X (MSR[IP]=1 at reset: vectors here).' % (off + size - 1, 0xFFF00000 + size - 1),
                'Exception vectors every 0x100 bytes; the reset vector (FFF00100) branches into the',
                'hardware start-up at FFF03000 (CPU type, BATs, Hammerhead, Bandit PCI, Cuda, RAM sizing)',
                'and then hands over to Open Firmware (FFF3003C). Later the NanoKernel installs its',
                'own vectors. Hardware addresses of the 7600 map are annotated where the code forms them.']
        self.ppc_region(off, size, 0xFFF00000, 'PowerPC exception vectors and boot code (FFF00000)', info,
                        roots=roots, notes=annotations.BOOT, comments=annotations.BOOT_INLINE,
                        path='ppc/ppc_boot_FFF00000.lst')

    def gen_kernel(self):
        ci = self.ci
        off = self.ci_off + ci['KernelCodeOffset']
        size = ci['KernelCodeSize']
        info = ['ROM offset %06X, physical %08X, %X bytes (ConfigInfo KernelCodeOffset/Size).' % (off, ROM_BASE + off, size),
                'The NanoKernel runs in place, with instruction translation off (MSR 00001040/00001050',
                'in the coverage run). Exceptions taken while the 68k emulator runs (user mode, MSR',
                '0000D072) enter here. "twi 31,r31,n" in the emulator are kernel calls.']
        self.ppc_region(off, size, ROM_BASE + off, 'NanoKernel (FFF10000)', info,
                        roots=[ROM_BASE + off], notes=annotations.KERNEL, path='ppc/ppc_nanokernel_FFF10000.lst')

    def gen_hwinit(self):
        ci = self.ci
        off = self.ci_off + ci['HWInitCodeOffset']
        size = ci['HWInitCodeSize']
        info = ['ROM offset %06X, physical %08X, %X bytes (ConfigInfo HWInitCodeOffset/Size).' % (off, ROM_BASE + off, size),
                'ROM-based diagnostics and the Serial Test Manager (menu text below), from',
                '"HD:SRC:BootPowerPC.admin:BootPowerPC.src:Diagnostics:DiagnosticsSrcs:Diagnostics.s".']
        self.ppc_region(off, size, ROM_BASE + off, 'HWInit / diagnostics (FFF20000)', info,
                        roots=[ROM_BASE + off], notes=annotations.HWINIT, path='ppc/ppc_hwinit_FFF20000.lst')

    def gen_configinfo(self):
        d = self.d
        b = self.ci_off
        out = ['; ' + '=' * 76, '; ConfigInfo (NanoKernel configuration record) at ROM offset 30D000 = FFF0D000',
               '; ' + '=' * 76,
               '; Field names from Apple\'s NanoKernel ConfigInfo layout; offsets in this record.',
               '; "-> " gives the ROM offset / physical address an offset field resolves to.', '']
        for f in layout.configinfo(d, b):
            vals = f['vals']
            if f['fmt'] == '16s':
                txt = repr(vals[0].split(b'\0')[0].decode('latin-1'))
            elif len(vals) == 1:
                v = vals[0]
                txt = '%08X' % (v & 0xFFFFFFFF) if f['fmt'] != 'B' else '%02X' % v
                if f['name'].endswith('Offset') and f['name'] not in ('EmulatorEntryOffset', 'KernelTrapTableOffset',
                                                                       'PageMapIRPOffset', 'PageMapKDPOffset',
                                                                       'PageMapEDPOffset', 'BootVersionOffset',
                                                                       'ECBOffset', 'IplValueOffset'):
                    t = (b + v) & 0xFFFFFFFF
                    txt += '   -> ROM %06X = %08X' % (t, ROM_BASE + t)
                if f['name'] in ('EmulatorEntryOffset', 'KernelTrapTableOffset'):
                    eo = b + self.ci['EmulatorCodeOffset'] + v
                    txt += '   -> ROM %06X = %08X = EA %08X' % (eo, ROM_BASE + eo, EMU_EA + v)
                if f['name'].startswith('LA_') or f['name'].startswith('PA_'):
                    hn = hwmap.hw_name(v)
                    if hn:
                        txt += '   (%s)' % hn
            else:
                txt = ' '.join('%08X' % x for x in vals)
            out.append('%03X  %-24s %s%s' % (f['off'], f['name'], txt, ('    ; ' + f['note']) if f['note'] else ''))
        out.append('')
        cpa = ROM_BASE + b
        out.append('; BATRangeInit decoded. Upper word: BEPI, BL (size), Vs/Vp. Lower word: BRPN, WIMG, PP;')
        out.append('; when bit 0x200 is set (inferred from the values) the BRPN part is an offset from this')
        out.append('; record (%08X), as for the other offsets.' % cpa)
        bat = layout.configinfo_dict(d, b)['BATRangeInit']
        for i in range(0, 32, 2):
            u, l = bat[i], bat[i + 1]
            if u == 0 and l == 0:
                continue
            bepi = u & 0xFFFE0000
            size = (((u >> 2) & 0x7FF) + 1) << 17
            pa = (cpa + (l & 0xFFFFF000)) & 0xFFFFFFFF if l & 0x200 else l & 0xFFFE0000
            out.append(';   pair %2d: %08X %08X  EA %08X, %X bytes -> PA %08X%s, WIMG %X, PP %d' % (
                i // 2, u, l, bepi, size, pa, ' (relative)' if l & 0x200 else '', (l >> 3) & 0xF, l & 3))
        out.append('')
        out.append('; Page map initialisation (PageMapInitOffset, %X bytes): pairs of words, as the' % self.ci['PageMapInitSize'])
        out.append('; SegMap tables index them. Interpretation (inferred): word 1 = first page within the')
        out.append('; segment << 16 | (page count - 1); word 2 = physical page | PTE flags (WIMG, PP), with')
        out.append('; bit 0x200 marking a page offset relative to this record; FFFF/A00/A01-style entries')
        out.append('; are placeholders the kernel fills in.')
        pm = b + self.ci['PageMapInitOffset']
        for i in range(0, self.ci['PageMapInitSize'], 8):
            w1, w2 = struct.unpack_from('>II', d, pm + i)
            first, count = w1 >> 16, (w1 & 0xFFFF) + 1
            pa = (cpa + (w2 & 0xFFFFF000)) & 0xFFFFFFFF if w2 & 0x200 else w2 & 0xFFFFF000
            out.append(';   +%03X  %08X %08X   pages %04X+%-5X -> PA %08X%s flags %03X' % (
                i, w1, w2, first, count, pa, ' (rel)' if w2 & 0x200 else '      ', w2 & 0xFFF))
        out.append('')
        out.append('; Hex dump of 30C000-30FFFF (LA_HardwarePriv page, ConfigInfo page, empty page)')
        out += hexdump(d[0x30C000:0x310000], 0xFFF0C000)
        write(os.path.join(self.out, 'ppc/ppc_configinfo_FFF0D000.txt'), out)
        self.files.append('ppc/ppc_configinfo_FFF0D000.txt')

    # ---- 68k emulator and its opcode table -----------------------------------

    def opcode_mnemonics(self):
        """MAME's text for each 68k opcode word, followed by zero bytes."""
        path = os.path.join(self.args.tmp, 'opcodes.bin')
        with open(path, 'wb') as f:
            for op in range(65536):
                f.write(struct.pack('>H', op) + bytes(8))
        srv = m68klist.M68kServer(self.args.build, path, 0)
        addrs = [op * 10 for op in range(65536)]
        srv.batch(addrs)
        res = [srv.cache[a]['text'] for a in addrs]
        srv.close()
        os.unlink(path)
        return res

    def gen_emulator(self):
        ci = self.ci
        off = self.ci_off + ci['EmulatorCodeOffset']
        size = ci['EmulatorCodeSize']
        toff = self.ci_off + ci['OpcodeTableOffset']
        tsize = ci['OpcodeTableSize']
        self.op_text = self.opcode_mnemonics()
        # handlers reached from the opcode table
        handlers = collections.defaultdict(list)
        for op in range(tsize // 8):
            for slot in (0, 4):
                w = struct.unpack_from('>I', self.d, toff + op * 8 + slot)[0]
                kind, tgt = ppclist.decode_flow(w, TBL_EA + op * 8 + slot)
                if kind in ('b', 'bc') and EMU_EA <= tgt < EMU_EA + size:
                    handlers[tgt].append(op)
        labels = {}
        comments = {}
        for tgt, ops in handlers.items():
            first = min(ops)
            labels[tgt] = 'op%04X' % first
            mn = self.op_text[first].split(';')[0].strip()
            comments[tgt] = 'opcode handler: %d opcode%s, first %04X (%s)' % (len(ops), 's' if len(ops) > 1 else '', first, mn)
        self.emu_handlers = labels
        info = ['ROM offset %06X-%06X = physical %08X, run at effective %08X (LA_EmulatorCode),' % (off, off + size - 1, ROM_BASE + off, EMU_EA),
                'mapped by the NanoKernel; executed in user mode (MSR 0000D072).',
                'Register use (from the code): r24 = 68k PC (points 2 past the opcode being',
                'dispatched; lhau r27,2(r24) fetches), r27 = prefetched 16-bit word, r29 = dispatch',
                'address (opcode table base + opcode*8), r8-r15 = D0-D7, r16-r22 = A0-A6, r1 = A7,',
                'r30 = emulator code base, r31 = emulator data (LA_EmulatorData 68FFF000).',
                'Labels opXXXX mark handlers reached from the opcode table (see the table listing).',
                'Addresses below are effective addresses; physical = address - 68060000 + FFF60000.']
        roots = list(handlers) + [EMU_EA + ci['EmulatorEntryOffset']]
        self.ppc_region(off, size, EMU_EA, '68k emulator (runs at 68060000)', info, roots=roots, labels=labels,
                        comments=comments, notes=annotations.EMULATOR, path='ppc/ppc_emulator_68060000.lst',
                        exe=lambda a: self.ppc_exec(a - EMU_EA + ROM_BASE + off))
        # the opcode table
        dis = self.tools.dingus(self.d[toff:toff + tsize], TBL_EA)
        out = self.lines_header('68k emulator opcode dispatch table (runs at 68080000)', [
            'ROM offset %06X-%06X = physical %08X, mapped at effective %08X (LA_DispatchTable).' % (toff, toff + tsize - 1, ROM_BASE + toff, TBL_EA),
            'Two PowerPC instructions per 68k opcode word, in opcode order: entry = 68080000 + opcode*8.',
            'The emulator dispatches with mtlr r29 / blr where r29 = table + opcode*8. The comment on',
            'each entry is MAME\'s disassembly of that opcode word (extension words shown as zero).',
            "Flag '*': the entry was executed in the coverage run."])
        for op in range(tsize // 8):
            a = TBL_EA + op * 8
            out.append('op_%04X:%s; %s' % (op, ' ' * 10, self.op_text[op].split('; ')[0]))
            for slot in (0, 1):
                w, text, outs, ins = dis[op * 2 + slot]
                text = ppclist.fix_text(w, text)
                kind, tgt = ppclist.decode_flow(w, a + 4 * slot)
                if tgt is not None:
                    nm = self.emu_handlers.get(tgt) or self.symbols.get(tgt)
                    if nm:
                        text = re.sub(r'0x%X\b' % tgt, nm, text, count=1)
                flag = '*' if self.cov.rom_executed(ROM_BASE + toff + op * 8 + 4 * slot) else ' '
                out.append('%08X%s %08X  %s' % (a + 4 * slot, flag, w, text))
        write(os.path.join(self.out, 'ppc/ppc_opcodetable_68080000.lst'), out)
        self.files.append('ppc/ppc_opcodetable_68080000.lst')
        n = sum(1 for op in range(tsize // 8) if self.cov.rom_executed(ROM_BASE + toff + op * 8))
        self.stats['68k emulator opcode table'] = '%d entries, %d executed' % (tsize // 8, n)

    # ---- Open Firmware ---------------------------------------------------------

    def hname(self, h):
        """A header's name; headerless definitions are named from the FCode."""
        if h['name']:
            return h['name']
        return getattr(self, 'of_detok_names', {}).get(h['token'], 'tok_%03X' % h['token'])

    def gen_openfirmware(self):
        d = self.d
        ci = self.ci
        boff = self.ci_off + ci['OpenFWBundleOffset']
        bsize = ci['OpenFWBundleSize']
        x = self.xcoff
        text = x['sections'][0]
        toff = boff + text['scnptr']
        tsize = text['size']
        # the text section's own header: offsets of its parts
        thw = struct.unpack_from('>' + 'I' * 24, d, toff)
        kernel_size = thw[2]            # 0x67A8: native kernel part, copied to RAM
        self.of_text = toff
        self.of_kernel_end = toff + kernel_size
        fcode_start = toff + kernel_size
        fcode_end = toff + thw[17] if thw[17] > kernel_size else toff + tsize
        self.of_fcode = (fcode_start, toff + tsize)
        hdrs = ofw.scan_headers(d, toff, toff + kernel_size, toff)
        self.of_rom_headers = hdrs
        labels, data_ranges, comments = {}, [], {}
        for p, h in hdrs.items():
            labels[ROM_BASE + h['xt']] = self.hname(h)
            data_ranges.append((ROM_BASE + p, ROM_BASE + h['xt'], 'header %s, token %03X, %s%s' % (
                self.hname(h), h['token'], ofw.KINDS.get(h['kind'], '%02X' % h['kind']),
                ', immediate' if h['flags'] & 0x40 else '')))
        data_ranges.append((ROM_BASE + boff, ROM_BASE + toff, 'XCOFF file and section header'))
        data_ranges.append((ROM_BASE + toff + 8, ROM_BASE + toff + 0x60, 'Open Firmware image header'))
        data_ranges.append((ROM_BASE + fcode_start, ROM_BASE + boff + bsize, 'FCode images'))
        info = ['ROM offset %06X-%06X = physical %08X (ConfigInfo OpenFWBundleOffset/Size).' % (boff, boff + bsize - 1, ROM_BASE + boff),
                'An XCOFF file (magic 01DF, timestamp field "Gary", one .text section of %X bytes at' % tsize,
                'file offset %X = ROM %06X). The text starts with Open Firmware\'s own header, then the' % (text['scnptr'], toff),
                'native Forth kernel (%X bytes: PowerPC code with dictionary headers), then FCode images' % kernel_size,
                '(ROM %06X-%06X) that build the rest of the system at startup.' % (fcode_start, toff + tsize),
                'The first part runs here from ROM (entry FFF3003C, MSR 00000040..00003070), copies the',
                'kernel to physical %08X (= ROM %06X + %X) and maps it at %08X; see' % (OF_PA + 0x8000, toff, OF_PA + 0x8000 - toff, OF_EA + 0x8000),
                'of/of_runtime_FF800000.lst for the image as it runs, of/of_fcode.txt for the',
                'detokenized FCode and of/of_words.txt for the dictionary.',
                'Labels are Forth word names at their code (xt).']
        exe = lambda a: self.ppc_exec(a)  # noqa: E731
        notes = dict(annotations.OF_ROM)
        notes.setdefault(ROM_BASE + toff, []).insert(0, 'Open Firmware text section (entry point)')
        self.ppc_region(boff, bsize, ROM_BASE + boff, 'Open Firmware 1.0.5 bundle (FFF30000)', info,
                        roots=[ROM_BASE + toff], labels=labels, data_ranges=data_ranges, notes=notes,
                        exe=exe, path='ppc/ppc_openfirmware_FFF30000.lst')

    def gen_of_runtime(self):
        ram = self.cov.ram_dump(OF_DUMP)
        if not ram:
            log('no RAM dump at %d: skipping the Open Firmware runtime listing' % OF_DUMP)
            return
        lo, hi = OF_PA, OF_PA + 0x100000
        # extent of Open Firmware's image: up to the last non-zero 4K page below 0x500000
        last = lo
        for a in range(lo, hi, 0x1000):
            if ram[a:a + 0x1000].count(0) != 0x1000:
                last = a + 0x1000
        hdrs = ofw.scan_headers(ram, lo + 0x8000, last, lo)
        self.of_ram_headers = hdrs
        self.of_ram = ram
        chains = ofw.wordlists(hdrs)
        # token table at 404000
        tt = OF_PA + 0x4000
        tokens = {}
        for t in range(0x1000):
            v = struct.unpack_from('>I', ram, tt + 4 * t)[0]
            tokens[t] = v
        default_xt = collections.Counter(tokens.values()).most_common(1)[0][0]
        self.of_tokens = tokens
        self.of_default_xt = default_xt
        labels, data_ranges, comments = {}, [], {}
        names_by_xt = collections.defaultdict(list)
        for p, h in hdrs.items():
            xt = OF_EA + (h['xt'] - OF_PA)
            names_by_xt[xt].append(self.hname(h))
            data_ranges.append((OF_EA + p - OF_PA, xt, 'header %s, token %03X, %s%s' % (
                self.hname(h), h['token'], ofw.KINDS.get(h['kind'], '%02X' % h['kind']),
                ', immediate' if h['flags'] & 0x40 else '')))
        for xt, nms in names_by_xt.items():
            labels[xt] = nms[0] if len(nms) == 1 else nms[0]
            if len(nms) > 1:
                comments[xt] = 'also: ' + ' '.join(nms[1:])
        # headerless FCode tokens: name them from the detokenized image
        detok_names = getattr(self, 'of_detok_names', {})
        for t, v in tokens.items():
            xt = v & ~1
            if v == default_xt or not (OF_EA <= xt < OF_EA + 0x100000):
                continue
            if xt not in labels:
                labels[xt] = detok_names.get(t, 'tok_%03X' % t)
        data_ranges.append((OF_EA, OF_EA + 0x4000, 'Open Firmware data'))
        data_ranges.append((OF_EA + 0x4000, OF_EA + 0x8000, 'FCode token table'))
        tcom = {}
        for t in range(0x1000):
            v = tokens[t]
            if v != default_xt:
                nm = detok_names.get(t) or STDNAME(t)
                tcom[OF_EA + 0x4000 + 4 * t] = 'token %03X%s%s' % (t, (' ' + nm) if nm else '', ' (immediate)' if v & 1 else '')
        comments.update(tcom)
        exe = lambda a: self.cov.ram_executed(a - OF_EA + OF_PA)  # noqa: E731
        size = last - lo
        kend = OF_PA + 0x8000 + (self.of_kernel_end - self.of_text)
        compiled = sorted(p for p in hdrs if p >= kend)
        first_c = OF_EA + compiled[0] - OF_PA if compiled else 0
        last_c = OF_EA + compiled[-1] - OF_PA if compiled else 0
        if first_c:
            data_ranges.append((OF_EA + kend - OF_PA, first_c, 'start of a copy of the FCode image'))
        info = ['Open Firmware as it runs: physical %08X-%08X mapped at %08X-%08X,' % (lo, last - 1, OF_EA, OF_EA + size - 1),
                'from the RAM dump taken at instruction %d of the coverage run (Open Firmware' % OF_DUMP,
                'complete, just before it starts the Mac OS ROM).',
                '  FF800000-FF803FFF  data (variables, stacks, buffers)',
                '  FF804000-FF807FFF  FCode token table: 4 bytes per token = xt, bit 0 = immediate',
                '  FF808000-FF80E7A7  the native kernel, copied from ROM %06X-%06X' % (self.of_text, self.of_kernel_end - 1),
                '  %08X-%08X  the start of a copy of the FCode image (overwritten after this)' % (OF_EA + kend - OF_PA, first_c - 1),
                '  %08X-...       definitions compiled at startup from the FCode images (last' % first_c,
                '                     header at %08X), then free dictionary space and buffers' % last_c,
                'The dictionary holds %d headers in %d wordlists (one per package/device node).' % (len(hdrs), len(chains)),
                'Labels are Forth names (headers) or names from the detokenized FCode (headerless',
                'tokens: tok_XXX). Execution flags are from the coverage run (RAM fetches).']
        data = ram[lo:last]
        L = ppclist.Listing(self.tools, data, OF_EA, executed=exe, labels=labels, comments=comments,
                            data_ranges=data_ranges, roots=[OF_EA + 0x8000], symbols={}, regions=self.region_of,
                            notes_at=annotations.OF_RAM).build()
        body = L.render()
        write(os.path.join(self.out, 'of/of_runtime_FF800000.lst'),
              self.lines_header('Open Firmware runtime image (FF800000)', info) + body)
        self.files.append('of/of_runtime_FF800000.lst')
        self.stats['Open Firmware runtime image'] = 'words %d, executed %d' % (len(data) // 4, sum(1 for x in L.exe if x))
        self.gen_of_words(hdrs, chains, tokens, default_xt)

    def gen_of_fcode(self):
        d = self.d
        names = {h['token']: h['name'] for h in self.of_rom_headers.values() if h['name']}
        fs, fe = self.of_fcode
        out = ['\\ ' + '=' * 76,
               '\\ Open Firmware 1.0.5 FCode images, detokenized (ROM %06X-%06X, physical %08X)' % (fs, fe - 1, ROM_BASE + fs),
               '\\ ' + '=' * 76,
               '\\ The first image builds most of the system (memory allocator, device tree, NVRAM,',
               '\\ boot); the others are programs the first one loads with byte-load-file for',
               '\\ built-in devices (identified by the header before each).',
               '\\ Format: ROM offset, then Forth reconstructed from the tokens. Token numbers after',
               '\\ new-token/named-token/external-token use the token encoding (1 or 2 bytes), and',
               '\\ tokens 401 (start of locals, one count byte), 410-417 (local fetch, lN) and 418-41F',
               '\\ (local store, ->lN) are Apple extensions, identified from their use.',
               '\\ Names: the kernel\'s headers, the IEEE 1275 FCode table, and the names the images',
               '\\ define; headerless definitions are tok_XXX. Branches show offset and target.',
               '\\ In strings, bytes outside printable ASCII are written "(hh hh) as in IEEE 1275.',
               '']
        all_defs = {}
        p = fs
        img = 0
        while p < fe:
            # find the next FCode header
            if d[p] not in (0xF0, 0xF1, 0xF2, 0xF3, 0xFD) or d[p + 1] not in (0x03, 0x08):
                p += 1
                continue
            length = struct.unpack_from('>I', d, p + 4)[0]
            if not (8 < length <= fe - p):
                p += 1
                continue
            if img:
                hdr = struct.unpack_from('>IIII', d, p - 16)
                out.append('')
                out.append('\\ ' + '-' * 76)
                ids = '%08X %08X' % (hdr[1], hdr[2])
                note = ''
                if hdr[1] != 0xFFFFFFFF and (hdr[1] & 0xFFFF) == 0x106B:
                    note = ' (PCI vendor 106B = Apple, device %04X)' % (hdr[1] >> 16)
                out.append('\\ FCode image %d at ROM %06X, directory entry %06X: link %08X, id %s%s' % (
                    img, p, p - 16, hdr[0], ids, note))
                out.append('\\ ' + '-' * 76)
            dt = ofw.Detokenizer(d, p, names)
            lines, end = dt.run(p + length)
            for a, t in lines:
                out.append('%06X  %s' % (a, t))
            for tok, df in dt.defs.items():
                all_defs.setdefault(tok, []).append((img, df))
            if img == 0:
                self.of_detok_names = {t: n for t, n in dt.names.items() if t >= 0x400}
                names = dict(names)
                names.update({t: n for t, n in dt.names.items() if t < 0x800})
            img += 1
            p = p + length
        self.of_defs = all_defs
        self.stats['Open Firmware FCode'] = '%d images, %d token definitions' % (img, sum(len(v) for v in all_defs.values()))
        write(os.path.join(self.out, 'of/of_fcode.txt'), out)
        self.files.append('of/of_fcode.txt')

    def gen_of_words(self, hdrs, chains, tokens, default_xt):
        out = ['Open Firmware 1.0.5 dictionary of the 7600 ROM',
               '=' * 60,
               'From the RAM dump at instruction %d of the coverage run: every header found in' % OF_DUMP,
               'Open Firmware\'s image (physical %08X, effective %08X), grouped by wordlist.' % (OF_PA, OF_EA),
               'Columns: header address, xt (code) address, FCode token, kind, flags, name, the value',
               'of constants (decoded from their code), origin.',
               'origin "ROM xxxxxx": the header is in the native kernel copied from that ROM offset;',
               'otherwise the word was compiled at startup from the FCode images.',
               'Kinds are the FCode defining words (colon, code, value, variable, constant, create,',
               'defer, buffer:, field). Flags: I = immediate.',
               '']
        kdelta = self.of_text - (OF_PA + 0x8000)

        def origin(h):
            if OF_PA + 0x8000 <= h['off'] < OF_PA + 0x8000 + (self.of_kernel_end - self.of_text):
                return 'ROM %06X' % (h['off'] + kdelta)
            return ''

        # name the wordlists by their newest word / package
        total = 0
        for head in sorted(chains, key=lambda p: -len(chains[p])):
            seq = chains[head]
            out.append('-' * 100)
            out.append('wordlist with %d words, newest first (head %08X "%s")' % (
                len(seq), OF_EA + head - OF_PA, self.hname(hdrs[head])))
            out.append('-' * 100)
            for p in seq:
                h = hdrs[p]
                val = ''
                if h['kind'] == 0xBA:              # constant: li/lis+ori r20 after the push
                    w1, w2, w3 = struct.unpack_from('>III', self.of_ram, h['xt'] + 4)
                    if w1 >> 16 == 0x3A80:
                        val = '= %X' % (ppclist.sext(w1 & 0xFFFF, 16) & 0xFFFFFFFF)
                    elif w1 >> 16 == 0x3E80 and w2 >> 16 == 0x6294:
                        val = '= %X' % (((w1 & 0xFFFF) << 16) | (w2 & 0xFFFF))
                out.append('%08X  %08X  %03X  %-9s %-2s %-32s %-11s %s' % (
                    OF_EA + p - OF_PA, OF_EA + h['xt'] - OF_PA, h['token'], ofw.KINDS.get(h['kind'], '%02X' % h['kind']),
                    'I' if h['flags'] & 0x40 else '', self.hname(h) + ('' if h['name'] else ' (headerless)'), val, origin(h)))
                total += 1
            out.append('')
        out.append('=' * 100)
        out.append('FCode token table (physical %08X): tokens whose xt differs from the default' % (OF_PA + 0x4000))
        out.append('(%08X = undefined token). Name from a header with that xt, else from the FCode.' % default_xt)
        out.append('=' * 100)
        by_xt = {}
        for p, h in hdrs.items():
            by_xt.setdefault(OF_EA + h['xt'] - OF_PA, self.hname(h))
        dn = getattr(self, 'of_detok_names', {})
        for t in range(0x1000):
            v = tokens[t]
            if v == default_xt:
                continue
            nm = by_xt.get(v & ~1) or dn.get(t) or STDNAME(t) or ''
            out.append('token %03X  xt %08X%s  %s' % (t, v & ~1, ' I' if v & 1 else '  ', nm))
        write(os.path.join(self.out, 'of/of_words.txt'), out)
        self.files.append('of/of_words.txt')
        self.stats['Open Firmware dictionary'] = '%d headers, %d wordlists' % (total, len(chains))

    # ---- 68k ROM -------------------------------------------------------------

    def m68k_listing(self, srv, off, size, title, info, path, roots=(), labels=None, data_ranges=(),
                     comments=None, notes=None):
        base = ROM_BASE + off
        lab = dict(labels or {})
        for a, nm in self.symbols.items():
            if base <= a < base + size and a not in lab:
                lab[a] = nm.replace('::', '.')
        L = m68klist.Listing(srv, self.d[off:off + size], base, executed=self.cov.m68k_executed, roots=roots,
                             labels=lab, comments=comments, data_ranges=list(data_ranges), symbols=self.symbols,
                             regions=self.region_of, notes_at=notes).build()
        body = L.render()
        n_exe = sum(1 for a in L.code if L.status.get(a) == '*')
        n_reach = sum(1 for a in L.code if L.status.get(a) == ' ')
        n_q = sum(1 for a in L.code if L.status.get(a) == '?')
        self.stats[title] = 'instructions %d (executed %d, reached %d, unverified %d)' % (len(L.code), n_exe, n_reach, n_q)
        if path:
            write(os.path.join(self.out, path), self.lines_header(title, info) + body)
            self.files.append(path)
        return L, body

    def gen_68k_main(self, srv):
        d = self.d
        roots = []
        notes = dict(annotations.M68K)
        comments = {}
        data_ranges = []
        for f in self.hdr68k:
            o, size, name = f['off'], f['size'], f['name']
            if name.endswith('JMP'):
                roots.append(ROM_BASE + o)
                comments[ROM_BASE + o] = 'header: ' + name
            else:
                data_ranges.append((ROM_BASE + o, ROM_BASE + o + size, 'header %s = %s' % (name, f['raw'].hex().upper())))
        # header words after SubVers (offsets into the ROM) up to the bra.l at 6A
        data_ranges.append((ROM_BASE + 0x50, ROM_BASE + 0x6A, 'header: more offsets'))
        data_ranges.append((ROM_BASE + 0x70, ROM_BASE + 0x74, 'pmove source (TC = 0)'))
        roots += list(self.traps)
        labels = {}
        for a, nm in self.traps.items():
            if a < ROM_BASE + 0x0D3500:
                labels[a] = nm
        for a, nm in self.macsbug.items():
            if a < 0x0D3500:
                comments[ROM_BASE + a - 2 if d[a - 2:a] == b'\x4e\x75' else ROM_BASE + a] = 'MacsBug name follows: %s' % nm
        hv = {f['name']: f['value'] for f in self.hdr68k}
        info = ['ROM offset 000000-0D34FF = physical FFC00000-FFCD34FF; the 68k ROM is used in place',
                '(ROMBase = $FFC00000 in low memory after boot), interpreted by the 68k emulator.',
                'Header: checksum %08X, reset PC +%X, machine %02X version %02X, release %04X,' % (
                    hv['Checksum'], hv['ResetPC'], hv['MachineNumber'], hv['ROMVersion'], hv['ROMRelease']),
                'resources at +%X, trap dispatch tables at +%X, 68k ROM size %X.' % (hv['RomRsrc'], hv['DispTableOff'], hv['RomSize']),
                'Disassembled as 68040 code by MAME\'s 68k disassembler. Entry points: the header',
                'vectors, every trap implementation in the dispatch tables (labels _TrapName), and the',
                '68k instructions executed in the coverage run (the emulator\'s PC, r24, at dispatch).',
                'A-line traps are shown by name; low-memory globals by name in the comments.']
        self.m68k_listing(srv, 0, 0x0D3500, '68k ROM: header and code (FFC00000)', info, '68k/68k_main_FFC00000.lst',
                          roots=roots, labels=labels, data_ranges=data_ranges, comments=comments, notes=notes)

    def gen_traptable(self):
        out = ['68k trap dispatch tables (ROM offset %06X = %08X)' % (self.disp, ROM_BASE + self.disp),
               '=' * 76,
               'Three tables of 32-bit offsets from the ROM base, read by the 68k ROM\'s',
               'dispatcher initialisation to fill the RAM trap tables (Toolbox at $E00, OS at $400):',
               '  %06X  Toolbox traps A800-ABFF (1024 entries)' % self.disp,
               '  %06X  OS traps A000-A0FF (256 entries)' % (self.disp + 0x1000),
               '  %06X  OS traps A000-A0FF, second copy (256 entries)' % (self.disp + 0x1400),
               'Verified against the RAM trap tables after boot (most entries equal offset+FFC00000;',
               'the others were patched later by the system). 0 = no ROM implementation.',
               'Names from the local MAME and Snow trap tables.', '']
        ram = self.cov.ram_dump(1000000000) or self.cov.ram_dump(400000000)
        for title, base, entries, first in (('Toolbox', self.disp, self.trap_tb, 0xA800),
                                            ('OS', self.disp + 0x1000, self.trap_os, 0xA000),
                                            ('OS (second copy)', self.disp + 0x1400, self.trap_os2, 0xA000)):
            out.append('-' * 76)
            out.append('%s traps' % title)
            out.append('-' * 76)
            for i, v in enumerate(entries):
                trap = first + i
                nm = hwmap.trap_name(trap) or ''
                ramv = ''
                if ram:
                    rv = struct.unpack_from('>I', ram, (0xE00 if first == 0xA800 else 0x400) + 4 * i)[0]
                    ramv = '' if rv == (v + ROM_BASE) & 0xFFFFFFFF else ' (RAM table after boot: %08X)' % rv
                tgt = '%08X' % (v + ROM_BASE) if v else '--------'
                out.append('%08X  %04X  %08X -> %s  %-28s%s' % (ROM_BASE + base + 4 * i, trap, v, tgt, nm, ramv))
        write(os.path.join(self.out, '68k/68k_traptable_FFCD3500.txt'), out)
        self.files.append('68k/68k_traptable_FFCD3500.txt')

    def gen_declrom(self):
        d = self.d
        dr = self.declrom
        out = ['Slot 0 declaration ROM at the top of the 68k ROM (ROM %06X-2FFFFF = %08X)' % (dr['start'], ROM_BASE + dr['start']),
               '=' * 76,
               'Format block (last 20 bytes): directory offset %+d -> %06X, length %X, CRC %08X,' % (
                   dr['dir_offset'], dr['directory'], dr['length'], dr['crc']),
               'revision %d, format %d, test pattern %08X, byte lanes %02X.' % (dr['revision'], dr['format'], dr['test_pattern'], dr['byte_lanes']),
               'The Slot Manager reads it like a NuBus card ROM; it describes the main logic board', 'sResource directory (id, offset -> target):']
        for p, rid, off, tgt in layout.sresource_dir(d, dr['directory'], dr['start'], 0x300000):
            out.append('  %06X  id %02X  offset %+6d -> %06X' % (p, rid, off, tgt))
            if rid != 0xFF and dr['start'] <= tgt < 0x300000:
                for q, rid2, off2, tgt2 in layout.sresource_dir(d, tgt, dr['start'], 0x300000):
                    extra = ''
                    if dr['start'] <= tgt2 < 0x300000 and rid2 in (2, 0x24, 0x25):
                        s = d[tgt2:tgt2 + 64].split(b'\0')[0]
                        if s and all(0x20 <= c < 0x7F for c in s):
                            extra = '  "%s"' % s.decode()
                    out.append('      %06X  id %02X  offset %+6d -> %06X%s' % (q, rid2, off2, tgt2, extra))
        out.append('')
        out += hexdump(d[dr['start']:0x300000], ROM_BASE + dr['start'])
        write(os.path.join(self.out, '68k/68k_declrom_FFEFFED4.txt'), out)
        self.files.append('68k/68k_declrom_FFEFFED4.txt')

    # ---- resources -------------------------------------------------------------

    def gen_resources(self, srv):
        d = self.d
        idx = ['ROM resources of the 7600 ROM',
               '=' * 76,
               'Resource list header at ROM %06X (header field RomRsrc): first entry %06X.' % (self.rsrc_hdr, self.rsrc_first),
               'Entries: combo mask (8 bytes), next entry, data offset, type, id, attributes, name.',
               'Data is preceded by a 16-byte header: tag "Kurt", flags, size, and a fourth word.',
               'Listed in address order of the data. Kind: PEF (PowerPC code fragment, listed with',
               'its code disassembled), 68k (68k code resource, disassembled), data (hex dump).', '',
               '%-8s %-8s %-8s %-6s %6s %-4s %-26s %-8s %s' % ('data', 'phys', 'size', 'type', 'id', 'attr', 'name', 'kind', 'file')]
        for r in self.res_by_data:
            kind = 'PEF' if r['data'] in self.pefs else ('68k' if r['type'] in M68K_CODE_TYPES else 'data')
            f = self.res_file(r)
            idx.append('%06X   %08X %06X   %-6s %6d %02X   %-26s %-8s %s' % (
                r['data'], ROM_BASE + r['data'], r['size'], r['type'], r['id'], r['attr'], r['name'][:26], kind, f))
            path = 'resources/' + f
            title = "ROM resource '%s' %d %s at %08X" % (r['type'], r['id'], r['name'], ROM_BASE + r['data'])
            info = ['data at ROM %06X (%X bytes), entry at %06X, attributes %02X, combo %s' % (
                r['data'], r['size'], r['entry'], r['attr'], r['combo']),
                'data header: %s' % r['hdr'].hex(' ', 4)]
            if r['data'] in self.pefs:
                self.gen_pef(r, path, title, info)
            elif r['type'] in M68K_CODE_TYPES:
                roots = [ROM_BASE + r['data']]
                drs = []
                comments = {}
                if r['type'] == 'DRVR':
                    flags, delay, emask, menu = struct.unpack_from('>HHHH', d, r['data'])
                    offs = struct.unpack_from('>HHHHH', d, r['data'] + 8)
                    nl = d[r['data'] + 18]
                    hend = r['data'] + 19 + nl
                    hend += hend & 1
                    drs.append((ROM_BASE + r['data'], ROM_BASE + hend, 'DRVR header: flags %04X, entries open/prime/control/status/close %s, name %s' % (
                        flags, ' '.join('%X' % o for o in offs), d[r['data'] + 19:r['data'] + 19 + nl].decode('mac_roman'))))
                    roots = [ROM_BASE + r['data'] + o for o in offs if o]
                    for nm, o in zip(('Open', 'Prime', 'Control', 'Status', 'Close'), offs):
                        if o:
                            comments[ROM_BASE + r['data'] + o] = 'driver %s entry' % nm
                elif r['type'].startswith('sl0') and r['id'] == 0:
                    roots = []
                    drs.append((ROM_BASE + r['data'], ROM_BASE + r['data'] + r['size'], 'library descriptor'))
                self.m68k_listing(srv, r['data'], r['size'], title, info + [
                    '68k code resource, disassembled from its start (entry points: offset 0, driver',
                    'header entries for DRVR, and executed addresses).'], path, roots=roots, data_ranges=drs,
                    comments=comments)
            else:
                out = ['; ' + title] + ['; ' + i for i in info] + ['']
                out += self.describe_data_resource(r)
                out += hexdump(d[r['data']:r['data'] + r['size']], ROM_BASE + r['data'])
                write(os.path.join(self.out, path), out)
                self.files.append(path)
        write(os.path.join(self.out, 'resources/resources.txt'), idx)
        self.files.append('resources/resources.txt')

    def describe_data_resource(self, r):
        d = self.d
        o = r['data']
        out = []
        if r['type'] == 'thng':
            typ, sub, man = d[o:o + 4], d[o + 4:o + 8], d[o + 8:o + 12]
            out.append('; component description: type %r subtype %r manufacturer %r' % (
                typ.decode('mac_roman'), sub.decode('mac_roman'), man.decode('mac_roman')))
        if r['type'] in ('STR ', 'STR'):
            n = d[o]
            out.append('; string: %r' % d[o + 1:o + 1 + n].decode('mac_roman'))
        return out

    def gen_pef(self, r, path, title, info):
        p = self.pefs[r['data']]
        d = self.d
        off = r['data']
        out = self.lines_header(title, info)
        out.append('; PEF container: architecture pwpc, format version %d, timestamp %08X, versions %08X/%08X/%08X' % (
            p.format_version, p.timestamp, p.old_def_version, p.old_imp_version, p.current_version))
        out.append(';   %d sections (%d instantiated)' % (p.section_count, p.inst_section_count))
        for s in p.sections:
            out.append(';   section %d %-9s %s container +%05X len %05X (ROM %06X = %08X), unpacked %05X, total %05X, share %d, align %d' % (
                s.index, s.kind_name, ('"%s"' % s.name) if s.name else '', s.container_off, s.container_len,
                off + s.container_off, ROM_BASE + off + s.container_off, s.unpacked_len, s.total_len, s.share, s.align))
        for label, ent in (('main', p.main), ('init', p.init), ('term', p.term)):
            if ent:
                out.append(';   %s: section %d offset %X' % (label, ent[0], ent[1]))
        for lib in p.libraries:
            out.append(';   imports from %s: %d symbols%s' % (lib['name'], lib['count'], ' (weak)' if lib['options'] & 0x40 else ''))
        out.append(';')
        # code sections
        names = p.code_names()
        tocs = p.toc_bases()
        VB = 0x80000000
        for s in p.sections:
            if s.kind != 0:
                continue
            base = ROM_BASE + off + s.container_off
            labels = {}
            for (si, o), nm in names.items():
                if si == s.index:
                    labels[base + o] = nm
            toc = None
            if tocs:
                (dsi, toff), _ = max(tocs.items(), key=lambda kv: kv[1])
                syms = {}
                for o, val in p.data_symbols(dsi).items():
                    if val[0] == 'import':
                        syms[VB + o] = val[1].split('::', 1)[1] if '::' in val[1] else val[1]
                    elif val[0] == 'sect' and val[1] == s.index:
                        tgt = base + val[2]
                        syms[VB + o] = '&' + (labels.get(tgt) or 'code+%X' % val[2])
                    elif val[0] == 'sect':
                        syms[VB + o] = '&data+%X' % val[2]
                toc = (VB + toff, syms)
            # cross-TOC glue
            code = d[off + s.container_off:off + s.container_off + s.container_len]
            if toc:
                for i in range(0, len(code) - 24, 4):
                    w = struct.unpack_from('>6I', code, i)
                    if (w[0] & 0xFFFF0000) == 0x81820000 and w[1] == 0x90410014 and w[2] == 0x800C0000 \
                            and w[3] == 0x804C0004 and w[4] == 0x7C0903A6 and w[5] == 0x4E800420:
                        dd = ppclist.sext(w[0] & 0xFFFF, 16)
                        nm = toc[1].get((toc[0] + dd) & 0xFFFFFFFF)
                        if nm and (base + i) not in labels:
                            labels[base + i] = 'glue_' + nm.lstrip('&')
            info2 = ['code section %d: ROM %06X-%06X = %08X' % (s.index, off + s.container_off, off + s.container_off + s.container_len - 1, base)]
            exe = lambda a, base=base, so=off + s.container_off: self.ppc_exec(a - base + ROM_BASE + so)  # noqa: E731
            L = ppclist.Listing(self.tools, code[:len(code) // 4 * 4], base, executed=exe, labels=labels,
                                roots=list(labels), symbols=self.symbols, regions=self.region_of, toc=toc).build()
            body = L.render()
            out.append('; ' + '-' * 76)
            out += ['; ' + x for x in info2]
            if toc:
                out.append('; TOC (r2) = data section + %X; TOC[d] comments name the word at that offset.' % (toc[0] - VB))
            out.append('; ' + '-' * 76)
            out += body
            self.stats['PEF %s' % (r['name'] or r['type'] + str(r['id']))] = 'code words %d, executed %d' % (
                len(code) // 4, sum(1 for x in L.exe if x))
        # data sections: unpacked image with relocations
        for s in p.sections:
            if s.kind not in (1, 2, 3, 6):
                continue
            img = p.section_image(s)
            syms = p.data_symbols(s.index)
            out.append('')
            out.append('; ' + '-' * 76)
            out.append('; data section %d (%s), unpacked %X bytes; addresses are offsets in the section;' % (s.index, s.kind_name, len(img)))
            out.append('; relocated words are named (imports) or point into a section (code+X / data+X).')
            out.append('; ' + '-' * 76)
            for i in range(0, len(img) // 4 * 4, 4):
                if i in syms:
                    v = syms[i]
                    if v[0] == 'import':
                        txt = v[1]
                    else:
                        cs = p.sections[v[1]]
                        if cs.kind == 0:
                            a = ROM_BASE + off + cs.container_off + v[2]
                            txt = 'code+%X = %08X %s' % (v[2], a, self.symbols.get(a, '').split('::')[-1])
                        else:
                            txt = 'data+%X' % v[2]
                    out.append('+%05X  %s  -> %s' % (i, img[i:i + 4].hex().upper(), txt))
            out.append('; full unpacked image:')
            out += hexdump(img, 0)
        # exports and imports
        out.append('')
        out.append('; exports (%d):' % len(p.exports))
        for e in sorted(p.exports, key=lambda e: (e['section'], e['value'])):
            out.append(';   %-40s class %-7s section %2d offset %X' % (e['name'], pef.SYMBOL_CLASSES.get(e['class'], e['class']), e['section'], e['value']))
        out.append('; imports (%d):' % len(p.imports))
        for i, imp in enumerate(p.imports):
            out.append(';   %4d %-24s %-40s %s%s' % (i, imp.get('lib', ''), imp['name'], pef.SYMBOL_CLASSES.get(imp['class'], imp['class']), ' weak' if imp['weak'] else ''))
        write(os.path.join(self.out, path), out)
        self.files.append(path)

    # ---- strings, regions, coverage --------------------------------------------

    def gen_strings(self):
        d = self.d
        out = ['Strings in the 7600 ROM: runs of 8 or more printable ASCII characters of which at',
               'least 80% are letters, digits or spaces (text in code and data alike), with ROM',
               'offset, physical address and region. Runs of the "kc" fill pattern and of one',
               'repeated character are left out; shorter strings (e.g. Pascal names) are not listed',
               'here but show in the hex dumps and listings.', '']
        for m in re.finditer(rb'[\x20-\x7E]{8,}', d):
            s = m.group()
            if s.count(b'kc') * 2 >= len(s) - 2 or len(set(s)) <= 2:
                continue
            good = sum(1 for c in s if chr(c).isalnum() or c == 0x20)
            if good * 5 < len(s) * 4:
                continue
            o = m.start()
            reg = self.region_of(ROM_BASE + o) or ''
            out.append('%06X  %08X  %-40s %s' % (o, ROM_BASE + o, reg[:40], s.decode('latin-1')))
        write(os.path.join(self.out, 'strings.txt'), out)
        self.files.append('strings.txt')

    def gen_regions(self):
        regs = sorted(self.regions)
        out = ['Region map of the 7600 ROM (ROM offset = physical - FFC00000)', '=' * 76,
               '%-8s %-8s %-8s %-8s  %-55s %s' % ('start', 'end', 'size', 'phys', 'what', 'file / how known')]
        pos = 0
        for s, e, name, f, how in regs:
            if s > pos:
                gap = self.d[pos:s]
                kind = 'zero' if gap.count(0) == len(gap) else ('kc fill' if gap.count(b'kc') * 2 >= len(gap) - 2 else 'other')
                out.append('%06X   %06X   %06X   %08X  %-55s %s' % (pos, s - 1, s - pos, ROM_BASE + pos, '(gap: %s)' % kind, ''))
            out.append('%06X   %06X   %06X   %08X  %-55s %s; %s' % (s, e - 1, e - s, ROM_BASE + s, name, f, how))
            pos = max(pos, e)
        if pos < len(self.d):
            out.append('%06X   %06X   %06X   %08X  (gap)' % (pos, len(self.d) - 1, len(self.d) - pos, ROM_BASE + pos))
        out.append('')
        out.append('ROM resources in address order (data block with its 16-byte header; list entries sit')
        out.append('between the blocks):')
        for s, e, name, f, how in sorted(self.detail_regions):
            out.append('%06X   %06X   %06X   %08X  %-55s %s; %s' % (s, e - 1, e - s, ROM_BASE + s, name, f, how))
        write(os.path.join(self.out, 'regions.txt'), out)
        self.files.append('regions.txt')

    def gen_coverage(self):
        out = ['Coverage run summary', '=' * 76]
        out += [x for x in self.cov.summary.split('\n') if x]
        out.append('68k instructions executed (distinct addresses): %d' % len(self.cov.m68k))
        out.append('')
        out.append('Per listing:')
        for k, v in self.stats.items():
            out.append('  %-60s %s' % (k, v))
        out.append('')
        out.append('RAM code that is a copy of ROM code (matched byte for byte; execution in the copy')
        out.append('counts as execution of the ROM words in the listings):')
        for lo, hi, ro, first, ic in getattr(self, 'ram_copy_info', []):
            reg = self.region_of(ROM_BASE + ro) or ''
            out.append('  RAM %08X-%08X  <- ROM %06X (%s), first executed at instruction %d' % (lo, hi - 1, ro, reg, first))
        p = os.path.join(self.cov.dir or '', 'pages.txt')
        if os.path.exists(p):
            out.append('')
            out.append('Where code ran (first instruction count, effective page, physical page, MSR low 16 bits):')
            out.append('see pages.txt in the coverage directory; summary by kind:')
            kinds = collections.OrderedDict()
            for line in open(p):
                if line.startswith('#'):
                    continue
                ic, ea, pa, msr = line.split()
                eav, pav = int(ea, 16), int(pa, 16)
                key = (msr, 'EA=PA' if eav == pav else 'EA %s.. -> PA %s..' % (ea[:3], pa[:3]))
                kinds.setdefault(key, [int(ic), 0])
                kinds[key][1] += 1
            for (msr, how), (ic, n) in kinds.items():
                out.append('  MSR %s  %-28s %4d pages, first at instruction %d' % (msr, how, n, ic))
        write(os.path.join(self.out, 'coverage.txt'), out)
        self.files.append('coverage.txt')


def STDNAME(t):
    return ofw.STD_FCODE.get(t)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument('--rom', required=True)
    ap.add_argument('--cov', default='')
    ap.add_argument('--out', default=os.path.dirname(here))
    ap.add_argument('--build', default=os.path.expanduser('~/.cache/macppc7300/romdisasm/build'))
    ap.add_argument('--tmp', default=os.environ.get('TMPDIR', os.path.expanduser('~/.cache/macppc7300/romdisasm/tmp')))
    ap.add_argument('--mame', default='/mnt/c/Temp/mistercore/mame')
    ap.add_argument('--snow', default='/mnt/c/Temp/mistercore/snow')
    ap.add_argument('--only', default='', help='comma-separated parts to generate (default all)')
    args = ap.parse_args()
    g = Gen(args)
    only = set(args.only.split(',')) if args.only else None

    def want(x):
        return only is None or x in only

    g.parse()
    g.build_symbols()
    g.plan_regions()
    g.find_ram_copies()
    if want('boot'):
        log('boot'); g.gen_boot()
    if want('configinfo'):
        log('configinfo'); g.gen_configinfo()
    if want('kernel'):
        log('kernel'); g.gen_kernel()
    if want('hwinit'):
        log('hwinit'); g.gen_hwinit()
    if want('of') or want('emulator'):
        pass
    if want('of'):
        log('openfirmware'); g.gen_openfirmware()
        log('fcode'); g.gen_of_fcode()
        log('of runtime'); g.gen_of_runtime()
    if want('emulator'):
        log('emulator'); g.gen_emulator()
    srv = m68klist.M68kServer(args.build, args.rom, ROM_BASE)
    if want('68k'):
        log('68k main'); g.gen_68k_main(srv)
    if want('traps'):
        g.gen_traptable()
    if want('declrom'):
        g.gen_declrom()
    if want('resources'):
        log('resources'); g.gen_resources(srv)
    srv.close()
    if want('strings'):
        g.gen_strings()
    g.gen_regions()
    g.gen_coverage()
    log('done: %d files' % len(g.files))


if __name__ == '__main__':
    main()
