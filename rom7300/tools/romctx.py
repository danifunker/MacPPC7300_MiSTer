"""The ROM image and the coverage run's results, shared by the generators."""

import array
import os
import struct

ROM_BASE = 0xFFC00000


class Coverage:
    """Executed words from romcov's output directory (empty if absent)."""

    def __init__(self, cov_dir):
        self.dir = cov_dir
        self.rom_first = self._load('rom_first.bin')
        self.rom_ea = self._load('rom_ea.bin')
        self.ram_first = self._load('ram_first.bin')
        self.ram_ea = self._load('ram_ea.bin')
        self.m68k = {}
        p = os.path.join(cov_dir, 'm68k_pcs.txt') if cov_dir else None
        if p and os.path.exists(p):
            for line in open(p):
                if line.startswith('#'):
                    continue
                v, c = line.split()
                self.m68k[int(v, 16)] = int(c)
        self.summary = ''
        p = os.path.join(cov_dir, 'summary.txt') if cov_dir else None
        if p and os.path.exists(p):
            self.summary = open(p).read()

    def _load(self, name):
        a = array.array('I')
        if self.dir:
            p = os.path.join(self.dir, name)
            if os.path.exists(p):
                with open(p, 'rb') as f:
                    a.frombytes(f.read())
                if struct.pack('=I', 1) != struct.pack('<I', 1):
                    a.byteswap()
        return a

    def rom_executed(self, pa):
        """True if the ROM word at physical address pa was executed."""
        i = (pa - ROM_BASE) >> 2
        return 0 <= i < len(self.rom_first) and self.rom_first[i] != 0

    def rom_first_at(self, pa):
        i = (pa - ROM_BASE) >> 2
        return self.rom_first[i] if 0 <= i < len(self.rom_first) else 0

    def ram_executed(self, pa):
        i = pa >> 2
        return 0 <= i < len(self.ram_first) and self.ram_first[i] != 0

    def m68k_executed(self, a):
        return a in self.m68k

    def ram_dump(self, icount):
        p = os.path.join(self.dir, 'ram_%d.bin' % icount)
        if os.path.exists(p):
            with open(p, 'rb') as f:
                return f.read()
        return None


class Rom:
    def __init__(self, path):
        with open(path, 'rb') as f:
            self.data = f.read()
        self.path = path
        self.size = len(self.data)

    def u32(self, off):
        return struct.unpack_from('>I', self.data, off)[0]

    def s32(self, off):
        return struct.unpack_from('>i', self.data, off)[0]

    def u16(self, off):
        return struct.unpack_from('>H', self.data, off)[0]

    def bytes(self, off, n):
        return self.data[off:off + n]

    @staticmethod
    def pa(off):
        return ROM_BASE + off
