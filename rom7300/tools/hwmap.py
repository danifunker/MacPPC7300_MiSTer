"""Names for the Power Macintosh 7600's hardware addresses, PowerPC SPRs,
68k Mac low-memory globals and A-line traps, used to annotate the listings.

The hardware map is the one MacPPC7300's machine implements (Hammerhead, Bandit,
Chaos, Grand Central); register names inside the Grand Central devices follow
the chips' data sheets and dingusppc's models. Trap and low-memory names are
read from two local, independent tables at run time (MAME's
src/mame/apple/mactoolbox.cpp and Snow's frontend_egui/src/consts.rs)."""

import os
import re

# ---------------------------------------------------------------------------
# hardware

HH_REGS = {
    0x00: 'HH_CPU_ID', 0x10: 'HH_ASIC_REVISION', 0x20: 'HH_MOTHERBOARD_ID',
    0x30: 'HH_CPU_SPEED', 0x40: 'HH_MB_DRAM_CONFIG', 0x50: 'HH_MEM_TIMING_0',
    0x60: 'HH_MEM_TIMING_1', 0x70: 'HH_REFRESH_TIMING', 0x80: 'HH_ROM_TIMING',
    0x90: 'HH_ARBITER_CONFIG', 0xA0: 'HH_ARBUS_TIMEOUT', 0xB0: 'HH_WHO_AM_I',
    0xC0: 'HH_INT_REG', 0xE0: 'HH_L2_CACHE_CONFIG',
}

GC_DMA = ['SCSI_CURIO', 'FLOPPY', 'ETH_XMIT', 'ETH_RCV', 'SCC_A_XMIT', 'SCC_A_RCV',
          'SCC_B_XMIT', 'SCC_B_RCV', 'AUDIO_OUT', 'AUDIO_IN', 'SCSI_MESH']
DBDMA_REGS = {0x00: 'control', 0x04: 'status', 0x08: 'cmdptr_hi', 0x0C: 'cmdptr',
              0x10: 'int_select', 0x14: 'branch_select', 0x18: 'wait_select'}
GC_INT = {0x20: 'GC_INT_EVENTS', 0x24: 'GC_INT_MASK', 0x28: 'GC_INT_CLEAR', 0x2C: 'GC_INT_LEVELS'}
VIA_REGS = ['vBufB', 'vBufAH', 'vDirB', 'vDirA', 'vT1C', 'vT1CH', 'vT1L', 'vT1LH',
            'vT2C', 'vT2CH', 'vSR', 'vACR', 'vPCR', 'vIFR', 'vIER', 'vBufA']
CURIO_REGS = ['xfer_cnt_lo', 'xfer_cnt_mid', 'fifo', 'command', 'status/dest_id',
              'int_status/sel_timeout', 'seq_step/sync_period', 'fifo_flags/sync_offset',
              'config1', 'clock_factor', 'test', 'config2', 'config3', 'config4',
              'xfer_cnt_hi', 'fifo_bottom']
MESH_REGS = ['xfer_count0', 'xfer_count1', 'fifo', 'sequence', 'bus_status0', 'bus_status1',
             'fifo_count', 'exception', 'error', 'int_mask', 'interrupt', 'source_id',
             'dest_id', 'sync_params', 'mesh_id', 'sel_timeout']
SWIM3_REGS = ['data', 'timer', 'error', 'param', 'phase', 'setup', 'mode0(clear)',
              'mode1(set)', 'status', 'intr', 'step', 'cur_track', 'cur_sector', 'gap',
              'first_sector', 'sector_count']
MACE_REGS = ['RCVFIFO', 'XMTFIFO', 'XMTFC', 'XMTFS', 'XMTRC', 'RCVFC', 'RCVFS', 'FIFOFC',
             'IR', 'IMR', 'PR', 'BIUCC', 'FIFOCC', 'MACCC', 'PLSCC', 'PHYCC', 'CHIPID0',
             'CHIPID1', 'IAC', 'reserved13', 'LADRF', 'PADR', 'reserved16', 'reserved17',
             'MPC', 'reserved19', 'RNTPC', 'RCVCC', 'reserved1C', 'UTR', 'reserved1E', 'reserved1F']
AWACS_REGS = {0x00: 'control', 0x10: 'codec_control', 0x20: 'codec_status',
              0x30: 'clipping_count', 0x40: 'byte_swapping'}
SCC_COMPAT = {0: 'SCC_B_ctrl', 2: 'SCC_A_ctrl', 4: 'SCC_B_data', 6: 'SCC_A_data'}
SCC_MACRISC = {0x00: 'SCC_B_ctrl', 0x10: 'SCC_B_data', 0x20: 'SCC_A_ctrl', 0x30: 'SCC_A_data'}


def _gc(off):
    """Name of an offset inside Grand Central's 128 KB (F3000000)."""
    if off < 0x8000:
        if off in GC_INT:
            return GC_INT[off]
        return 'GC_BASE' if off == 0 else 'GC+%X' % off
    if off < 0x10000:
        ch, r = (off - 0x8000) >> 8, off & 0xFF
        name = GC_DMA[ch] if ch < len(GC_DMA) else 'ch%d' % ch
        return 'GC_DBDMA_%s.%s' % (name, DBDMA_REGS.get(r, '+%X' % r))
    dev, r = (off >> 12) & 0xF, off & 0xFFF
    if dev == 0x0:
        return 'GC_CURIO_SCSI.%s' % (CURIO_REGS[r >> 4] if r < 0x100 else '+%X' % r)
    if dev == 0x1:
        return 'GC_MACE.%s' % (MACE_REGS[r >> 4] if r < 0x200 else '+%X' % r)
    if dev == 0x2:
        return 'GC_%s' % SCC_COMPAT.get(r, 'SCC_compat+%X' % r)
    if dev == 0x3:
        return 'GC_%s' % SCC_MACRISC.get(r, 'SCC+%X' % r)
    if dev == 0x4:
        return 'GC_AWACS.%s' % AWACS_REGS.get(r, '+%X' % r)
    if dev == 0x5:
        return 'GC_SWIM3.%s' % (SWIM3_REGS[r >> 4] if r < 0x100 else '+%X' % r)
    if dev in (0x6, 0x7):
        vo = off - 0x16000
        if vo % 0x200 == 0 and 0 <= vo < 0x2000:
            return 'GC_VIA.%s' % VIA_REGS[vo // 0x200]
        return 'GC_VIA+%X' % vo
    if dev == 0x8:
        return 'GC_MESH_SCSI.%s' % (MESH_REGS[r >> 4] if r < 0x100 else '+%X' % r)
    if dev == 0x9:
        return 'GC_ETHERNET_ROM+%X' % r
    if dev == 0xA:
        return 'GC_BOARD_REG1+%X' % r if r else 'GC_BOARD_REG1'
    if dev == 0xB:
        return 'GC_IOBUS2(RaDACal)+%X' % r
    if dev == 0xC:
        return 'GC_IOBUS3(sixty6)+%X' % r
    if dev == 0xD:
        return 'GC_NVRAM_ADDR+%X' % r if r else 'GC_NVRAM_ADDR'
    if dev == 0xE:
        return 'GC_BOARD_REG2+%X' % r if r else 'GC_BOARD_REG2'
    return 'GC_NVRAM_DATA+%X' % r if r else 'GC_NVRAM_DATA'


def hw_name(addr):
    """A name for a physical address in the 7600's I/O map, or None."""
    addr &= 0xFFFFFFFF
    if 0xF8000000 <= addr < 0xF8000500:
        off = addr - 0xF8000000
        if off >= 0x1C0:
            bank, half = (off - 0x1C0) >> 5, ((off - 0x1C0) >> 4) & 1
            return 'HH_BANK%d_BASE_%s' % (bank, 'LSB' if half else 'MSB') + ('' if off & 0xF == 0 else '+%X' % (off & 0xF))
        if off in HH_REGS:
            return HH_REGS[off]
        base = off & ~0xF
        return (HH_REGS.get(base, 'HH') + '+%X' % (off & 0xF)) if base in HH_REGS else 'HH+%X' % off
    if 0xF8000500 <= addr < 0xF9000000:
        return 'Hammerhead space+%X' % (addr - 0xF8000000)
    if 0xF3000000 <= addr < 0xF3020000:
        return _gc(addr - 0xF3000000)
    if addr == 0xF2800000:
        return 'BANDIT_CONFIG_ADDR'
    if addr == 0xF2C00000:
        return 'BANDIT_CONFIG_DATA'
    if 0xF2000000 <= addr < 0xF3000000:
        return 'BANDIT+%X' % (addr - 0xF2000000)
    if addr == 0xF0800000:
        return 'CHAOS_CONFIG_ADDR'
    if addr == 0xF0C00000:
        return 'CHAOS_CONFIG_DATA'
    if 0xF0000000 <= addr < 0xF1000000:
        return 'CHAOS+%X' % (addr - 0xF0000000)
    if 0xF1000000 <= addr < 0xF2000000:
        return 'Chaos/Control space+%X' % (addr - 0xF1000000)
    if 0xF3020000 <= addr < 0xF4000000:
        return 'GC space+%X' % (addr - 0xF3000000)
    if 0x90000000 <= addr < 0x94000000:
        return 'Control VRAM (Chaos PCI BAR, set by OF)+%X' % (addr - 0x90000000)
    if 0x94000000 <= addr < 0x94001000:
        return 'Control registers (Chaos PCI BAR, set by OF)+%X' % (addr - 0x94000000)
    if 0xFFC00000 <= addr:
        return None
    return None


def hw_base_name(addr):
    """A coarse name for an address formed by lis (an upper half): the block
    it starts, or None."""
    names = {
        0xF8000000: 'Hammerhead registers', 0xF2000000: 'Bandit (PCI bridge) space',
        0xF2800000: 'BANDIT_CONFIG_ADDR', 0xF2C00000: 'BANDIT_CONFIG_DATA',
        0xF0000000: 'Chaos (video bridge) space', 0xF0800000: 'CHAOS_CONFIG_ADDR',
        0xF0C00000: 'CHAOS_CONFIG_DATA', 0xF1000000: 'Chaos/Control space',
        0xF3000000: 'Grand Central base', 0xF3010000: 'Grand Central device space',
    }
    if addr in names:
        return names[addr]
    if 0x90000000 <= addr < 0x94000000 and not addr & 0xFFFF:
        return 'Control VRAM (Chaos PCI BAR)+%X' % (addr - 0x90000000)
    if addr == 0x94000000:
        return 'Control registers (Chaos PCI BAR)'
    return None


def hw_region_for(hi16):
    """True if an upper halfword (lis) points at I/O space."""
    return hi16 in range(0xF000, 0xF400) or hi16 == 0xF800 or hi16 in range(0x9000, 0x9400)


# ---------------------------------------------------------------------------
# PowerPC SPRs (601, 603, 604; 601-only names noted)

SPR_NAMES = {
    0: 'MQ(601)', 1: 'XER', 4: 'RTCU(601)', 5: 'RTCL(601)', 6: 'DEC(601 read)', 8: 'LR', 9: 'CTR',
    18: 'DSISR', 19: 'DAR', 20: 'RTCU(601 write)', 21: 'RTCL(601 write)', 22: 'DEC', 25: 'SDR1',
    26: 'SRR0', 27: 'SRR1', 268: 'TBL(read)', 269: 'TBU(read)', 272: 'SPRG0', 273: 'SPRG1',
    274: 'SPRG2', 275: 'SPRG3', 282: 'EAR', 284: 'TBL', 285: 'TBU', 287: 'PVR',
    528: 'IBAT0U', 529: 'IBAT0L', 530: 'IBAT1U', 531: 'IBAT1L', 532: 'IBAT2U', 533: 'IBAT2L',
    534: 'IBAT3U', 535: 'IBAT3L', 536: 'DBAT0U', 537: 'DBAT0L', 538: 'DBAT1U', 539: 'DBAT1L',
    540: 'DBAT2U', 541: 'DBAT2L', 542: 'DBAT3U', 543: 'DBAT3L',
    936: 'UMMCR0', 937: 'UPMC1', 938: 'UPMC2', 939: 'USIA', 940: 'UMMCR1', 941: 'UPMC3', 942: 'UPMC4',
    952: 'MMCR0(604)', 953: 'PMC1(604)', 954: 'PMC2(604)', 955: 'SIA(604)', 956: 'MMCR1(604e)',
    957: 'PMC3(604e)', 958: 'PMC4(604e)', 959: 'SDA(604)',
    976: 'DMISS(603)', 977: 'DCMP(603)', 978: 'HASH1(603)', 979: 'HASH2(603)', 980: 'IMISS(603)',
    981: 'ICMP(603)', 982: 'RPA(603)',
    1008: 'HID0', 1009: 'HID1', 1010: 'IABR(HID2 on 601)', 1013: 'DABR(HID5 on 601)',
    1017: 'L2CR(750)', 1019: 'ICTC(750)', 1020: 'THRM1(750)', 1021: 'THRM2(750)', 1022: 'THRM3(750)',
    1023: 'PIR(HID15 on 601)',
}


def spr_name(n):
    return SPR_NAMES.get(n, 'spr%d' % n)


# ---------------------------------------------------------------------------
# traps and low memory, from the local MAME and Snow trees

_TRAPS = None
_LOWMEM = None


def _read(path):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def load_tables(mame_dir, snow_dir):
    """Reads the trap and low-memory tables; returns (n_traps, n_globals)."""
    global _TRAPS, _LOWMEM
    _TRAPS, _LOWMEM = {}, {}
    snow = _read(os.path.join(snow_dir, 'frontend_egui', 'src', 'consts.rs'))
    for num, name in re.findall(r'\(0x(A[0-9A-Fa-f]{3}),\s*"([^"]+)"\)', snow):
        _TRAPS[int(num, 16)] = name.lstrip('_')
    mame = _read(os.path.join(mame_dir, 'src', 'mame', 'apple', 'mactoolbox.cpp'))
    for num, name in re.findall(r'\{\s*0x(A[0-9A-Fa-f]{3}),\s*"([^"]+)"\s*\}', mame):
        _TRAPS[int(num, 16)] = name.lstrip('_')          # MAME's wins where both have one
    m = re.search(r'pub static GLOBALS[^=]*=\s*\[(.*?)\n\];', snow, re.S)
    if m:
        for name, addr in re.findall(r'\(\s*"([^"]+)",\s*0x([0-9A-Fa-f]+),', m.group(1)):
            _LOWMEM.setdefault(int(addr, 16), name)
    return len(_TRAPS), len(_LOWMEM)


def trap_name(word):
    """Name of an A-line trap word (A000-AFFF), e.g. 'GetResource'. The
    tables list OS traps with their usual flag bits (A11E NewPtr), so the
    exact word is tried first, then the same trap number with other flags."""
    if not _TRAPS:
        return None
    if word in _TRAPS:
        return _TRAPS[word]
    if word & 0x0800:                      # Toolbox: A800-ABFF, autoPop in bit 10
        cands = [0xA800 | (word & 0x03FF), 0xAC00 | (word & 0x03FF)]
    else:                                  # OS: A0nn, flags in bits 8-10
        cands = [0xA000 | (f << 8) | (word & 0xFF) for f in range(8)]
    for c in cands:
        if c in _TRAPS:
            return _TRAPS[c]
    return None


def trap_exact(word):
    """True if the tables name this exact trap word (flags included)."""
    return bool(_TRAPS) and word in _TRAPS


def trap_flags(word):
    """The modifier bits of a trap word, as text ('' if none)."""
    if word & 0x0800:
        return ',autoPop' if word & 0x0400 else ''
    f = word & 0x0700                      # OS traps: bits 8-10 (SYS/CLEAR/ASYNC/HFS/no-A0)
    return (',flags $%03X' % f) if f else ''


def lowmem_name(addr):
    if _LOWMEM is None:
        return None
    return _LOWMEM.get(addr)


def lowmem_table():
    return dict(_LOWMEM or {})


def trap_table():
    return dict(_TRAPS or {})
