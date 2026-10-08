"""Structures of an Old World Power Macintosh ROM: the 68k ROM header, the
ROM resource list, the PowerPC ConfigInfo record and the slot-0 declaration
ROM. Field layouts follow Apple's published/universal ROM formats; the
values come from the image itself."""

import struct

ROM_BASE = 0xFFC00000

# 68k ROM header (offsets from the start of the ROM)
HEADER_FIELDS = [
    (0x00, 4, 'Checksum', 'sum of the 16-bit words of the 68k ROM after this field'),
    (0x04, 4, 'ResetPC', 'initial PC as an offset from the ROM base'),
    (0x08, 1, 'MachineNumber', ''),
    (0x09, 1, 'ROMVersion', '$7D: the PowerPC "TNT" universal ROM'),
    (0x0A, 4, 'ReStartJMP', 'jmp (d16,pc)'),
    (0x0E, 4, 'BadDiskJMP', 'jmp (d16,pc)'),
    (0x12, 2, 'ROMRelease', 'release (BCD-ish) - here 28F2'),
    (0x14, 1, 'PatchFlags', ''),
    (0x15, 1, 'unused', ''),
    (0x16, 4, 'ForeignOSTbl', 'offset of the foreign-OS vector table'),
    (0x1A, 4, 'RomRsrc', 'offset of the ROM resource list header'),
    (0x1E, 4, 'EjectJMP', 'jmp (d16,pc)'),
    (0x22, 4, 'DispTableOff', 'offset of the compressed trap dispatch tables'),
    (0x26, 4, 'CriticalJMP', 'jmp (d16,pc)'),
    (0x2A, 4, 'ResetEntryJMP', 'jmp (d16,pc): the 68k cold start'),
    (0x2E, 1, 'RomLoc', ''),
    (0x2F, 1, 'unused', ''),
    (0x30, 16, 'CheckSum0-3', 'four checksums (byte lanes)'),
    (0x40, 4, 'RomSize', 'size of the 68k ROM'),
    (0x44, 4, 'EraseIconOff', ''),
    (0x48, 4, 'InitSys7ToolboxOff', ''),
    (0x4C, 4, 'SubVers', ''),
]

# PowerPC ConfigInfo (NanoKernel configuration record), offsets in bytes
CONFIGINFO_FIELDS = [
    (0x000, '8L', 'ROMByteCheckSums', 'one 32-bit sum per byte lane'),
    (0x020, '2L', 'ROMCheckSum64', '64-bit sum of double words'),
    (0x028, 'l', 'ROMImageBaseOffset', 'offset of the ROM image from this record'),
    (0x02C, 'L', 'ROMImageSize', ''),
    (0x030, 'L', 'ROMImageVersion', ''),
    (0x034, 'l', 'Mac68KROMOffset', ''),
    (0x038, 'L', 'Mac68KROMSize', ''),
    (0x03C, 'l', 'ExceptionTableOffset', ''),
    (0x040, 'L', 'ExceptionTableSize', ''),
    (0x044, 'l', 'HWInitCodeOffset', ''),
    (0x048, 'L', 'HWInitCodeSize', ''),
    (0x04C, 'l', 'KernelCodeOffset', ''),
    (0x050, 'L', 'KernelCodeSize', ''),
    (0x054, 'l', 'EmulatorCodeOffset', ''),
    (0x058, 'L', 'EmulatorCodeSize', ''),
    (0x05C, 'l', 'OpcodeTableOffset', ''),
    (0x060, 'L', 'OpcodeTableSize', ''),
    (0x064, '16s', 'BootstrapVersion', ''),
    (0x074, 'L', 'BootVersionOffset', ''),
    (0x078, 'L', 'ECBOffset', ''),
    (0x07C, 'L', 'IplValueOffset', ''),
    (0x080, 'L', 'EmulatorEntryOffset', 'from the emulator code'),
    (0x084, 'L', 'KernelTrapTableOffset', 'from the emulator code'),
    (0x088, 'L', 'TestIntMaskInit', 'interrupt controller masks'),
    (0x08C, 'L', 'ClearIntMaskInit', ''),
    (0x090, 'L', 'PostIntMaskInit', ''),
    (0x094, 'L', 'LA_InterruptCtl', 'logical address of the interrupt controller'),
    (0x098, 'B', 'InterruptHandlerKind', ''),
    (0x09C, 'L', 'LA_InfoRecord', 'logical addresses the kernel maps'),
    (0x0A0, 'L', 'LA_KernelData', ''),
    (0x0A4, 'L', 'LA_EmulatorData', ''),
    (0x0A8, 'L', 'LA_DispatchTable', ''),
    (0x0AC, 'L', 'LA_EmulatorCode', ''),
    (0x0B0, 'L', 'MacLowMemInitOffset', 'from this record'),
    (0x0B4, 'L', 'PageAttributeInit', ''),
    (0x0B8, 'L', 'PageMapInitSize', ''),
    (0x0BC, 'L', 'PageMapInitOffset', 'from this record'),
    (0x0C0, 'L', 'PageMapIRPOffset', ''),
    (0x0C4, 'L', 'PageMapKDPOffset', ''),
    (0x0C8, 'L', 'PageMapEDPOffset', ''),
    (0x0CC, '32L', 'SegMap32SupInit', 'pairs: page map offset, segment register flags'),
    (0x14C, '32L', 'SegMap32UsrInit', ''),
    (0x1CC, '32L', 'SegMap32CPUInit', ''),
    (0x24C, '32L', 'SegMap32OvlInit', ''),
    (0x2CC, '32L', 'BATRangeInit', 'pairs: BAT upper, BAT lower (lower relative to this record)'),
    (0x34C, 'L', 'BatMap32SupInit', 'which BATRangeInit pairs each mode uses'),
    (0x350, 'L', 'BatMap32UsrInit', ''),
    (0x354, 'L', 'BatMap32CPUInit', ''),
    (0x358, 'L', 'BatMap32OvlInit', ''),
    (0x35C, 'L', 'SharedMemoryAddr', ''),
    (0x360, 'L', 'PA_RelocatedLowMemInit', ''),
    (0x364, 'l', 'OpenFWBundleOffset', 'from this record'),
    (0x368, 'L', 'OpenFWBundleSize', ''),
    (0x36C, 'L', 'LA_OpenFirmware', 'logical address Open Firmware runs at'),
    (0x370, 'L', 'PA_OpenFirmware', 'physical RAM address it is loaded to'),
    (0x374, 'L', 'LA_HardwarePriv', ''),
]


def u32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def s32(b, o):
    return struct.unpack_from('>i', b, o)[0]


def header68k(rom):
    out = []
    for off, size, name, note in HEADER_FIELDS:
        raw = rom[off:off + size]
        out.append({'off': off, 'size': size, 'name': name, 'raw': raw, 'note': note,
                    'value': int.from_bytes(raw, 'big')})
    return out


def resources(rom):
    """The ROM resource list, oldest entry last. Each entry:
    combo(8) next(4) data(4) type(4) id(2) attr(1) name(pstring);
    the data is preceded by a 16-byte header ('Kurt' tag, flags, size)."""
    hdr = u32(rom, 0x1A)
    first = u32(rom, hdr)
    res = []
    e = first
    seen = set()
    while e and e not in seen and e < len(rom):
        seen.add(e)
        nxt, data = u32(rom, e + 8), u32(rom, e + 12)
        typ = rom[e + 16:e + 20].decode('mac_roman')
        rid = struct.unpack_from('>h', rom, e + 20)[0]
        attr = rom[e + 22]
        nl = rom[e + 23]
        name = rom[e + 24:e + 24 + nl].decode('mac_roman')
        size = u32(rom, data - 8)
        res.append({'entry': e, 'entry_size': 24 + nl, 'combo': rom[e:e + 8].hex(), 'next': nxt,
                    'data': data, 'size': size, 'type': typ, 'id': rid, 'attr': attr, 'name': name,
                    'hdr': rom[data - 16:data]})
        e = nxt
    return hdr, first, res


def configinfo(rom, off):
    out = []
    for fo, fmt, name, note in CONFIGINFO_FIELDS:
        n = struct.calcsize('>' + fmt)
        vals = struct.unpack_from('>' + fmt, rom, off + fo)
        out.append({'off': fo, 'fmt': fmt, 'name': name, 'note': note, 'vals': vals, 'size': n})
    return out


def configinfo_dict(rom, off):
    d = {}
    for f in configinfo(rom, off):
        d[f['name']] = f['vals'][0] if len(f['vals']) == 1 else f['vals']
    return d


def declrom(rom, end):
    """The slot declaration ROM whose format block ends at 'end' (exclusive)."""
    fb = end - 20
    diroff = u32(rom, fb) & 0xFFFFFF          # 24-bit signed, from the field itself
    if diroff & 0x800000:
        diroff -= 0x1000000
    length = u32(rom, fb + 4)
    crc = u32(rom, fb + 8)
    rev, fmt = rom[fb + 12], rom[fb + 13]
    test = u32(rom, fb + 14)
    lanes = rom[fb + 19]
    d = {'format_block': fb, 'dir_offset': diroff, 'directory': fb + diroff, 'length': length,
         'start': end - length, 'crc': crc, 'revision': rev, 'format': fmt, 'test_pattern': test,
         'byte_lanes': lanes}
    return d


def sresource_dir(rom, at, lo, hi):
    """Walks an sResource list (id byte, 24-bit offset) until id FF."""
    out = []
    p = at
    while lo <= p < hi:
        rid = rom[p]
        off = int.from_bytes(rom[p + 1:p + 4], 'big')
        if off & 0x800000:
            off -= 0x1000000
        out.append((p, rid, off, p + off))
        if rid == 0xFF:
            break
        p += 4
    return out
