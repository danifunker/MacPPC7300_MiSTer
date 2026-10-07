#!/usr/bin/env python3
"""A 68HC05 disassembler for Cuda's (and Egret's) firmware.

    python verilator\\hc05dis.py ROM.bin [BASE] > listing.txt

BASE is where the image sits in the 68HC05's space: 0x0F00 (the default)
for a 68HC05E1 Cuda or Egret (4,352 bytes), 0x0B00 for a 68HC05E5 Cuda
(Cuda 3.x, 5,376 bytes). The vectors at 1FF6-1FFF (reset, SWI, IRQ, timer,
one-second) are followed through every branch, call and jump the code makes
directly; what is reached only through jump tables or code built in RAM
(the pseudo-command handlers, READ_MCU_MEM's LDA in RAM) is printed as
bytes. Each line has the address, the bytes, the instruction with the
68HC05E1's register names (PORTA, DDRB, PLL, TCTL, ...) and its cycle count
from MAME's s_hc_cycles. This is how the facts in rtl/machine/PPCMac_cuda.sv's
header were found (the bus clock from the delay and ADB loops, the timer
interrupt's power-switch polling, the VIA handshake).
"""

import sys

IO = {0x00: 'PORTA', 0x01: 'PORTB', 0x02: 'PORTC', 0x04: 'DDRA', 0x05: 'DDRB',
      0x06: 'DDRC', 0x07: 'PLL', 0x08: 'TCTL', 0x09: 'TCNT', 0x12: 'ONESEC'}

CYC = [
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    5, 0, 0, 5, 5, 0, 5, 5, 5, 5, 5, 0, 5, 4, 0, 5,
    3, 0, 11, 3, 3, 0, 3, 3, 3, 3, 3, 0, 3, 3, 0, 3,
    3, 0, 0, 3, 3, 0, 3, 3, 3, 3, 3, 0, 3, 3, 0, 3,
    6, 0, 0, 6, 6, 0, 6, 6, 6, 6, 6, 0, 6, 5, 0, 6,
    5, 0, 0, 5, 5, 0, 5, 5, 5, 5, 5, 0, 5, 4, 0, 5,
    9, 6, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 2,
    0, 0, 0, 0, 0, 0, 0, 2, 2, 2, 2, 2, 2, 2, 0, 2,
    2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 0, 6, 2, 0,
    3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 3, 3, 2, 5, 3, 4,
    4, 4, 4, 4, 4, 4, 4, 5, 4, 4, 4, 4, 3, 6, 4, 5,
    5, 5, 5, 5, 5, 5, 5, 6, 5, 5, 5, 5, 4, 7, 5, 6,
    4, 4, 4, 4, 4, 4, 4, 5, 4, 4, 4, 4, 3, 6, 4, 5,
    3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 3, 3, 2, 5, 3, 4]

BR = ['bra', 'brn', 'bhi', 'bls', 'bcc', 'bcs', 'bne', 'beq',
      'bhcc', 'bhcs', 'bpl', 'bmi', 'bmc', 'bms', 'bil', 'bih']
RMW = {0: 'neg', 3: 'com', 4: 'lsr', 6: 'ror', 7: 'asr', 8: 'lsl', 9: 'rol', 0xA: 'dec', 0xC: 'inc', 0xD: 'tst', 0xF: 'clr'}
ALU = ['sub', 'cmp', 'sbc', 'cpx', 'and', 'bit', 'lda', 'sta', 'eor', 'adc', 'ora', 'add', 'jmp', 'jsr', 'ldx', 'stx']
INH = {0x80: 'rti', 0x81: 'rts', 0x83: 'swi', 0x8E: 'stop', 0x8F: 'wait', 0x97: 'tax', 0x98: 'clc', 0x99: 'sec',
       0x9A: 'cli', 0x9B: 'sei', 0x9C: 'rsp', 0x9D: 'nop', 0x9F: 'txa', 0x42: 'mul'}


def name(a):
    if a in IO:
        return IO[a]
    return '$%02X' % a if a < 0x100 else '$%04X' % a


def decode(rom, base, pc):
    """-> (text, length, targets, falls_through)"""
    def b(i):
        return rom[(pc + i) - base] if 0 <= (pc + i) - base < len(rom) else 0
    op = b(0)
    hi, lo = op >> 4, op & 15

    def rel(off, n):
        return (pc + n + (off - 256 if off & 0x80 else off)) & 0x1FFF
    if hi == 0:
        t = rel(b(2), 3)
        return ('br%s %d,%s,L%04X' % ('clr' if lo & 1 else 'set', lo >> 1, name(b(1)), t), 3, [t], True)
    if hi == 1:
        return ('b%s %d,%s' % ('clr' if lo & 1 else 'set', lo >> 1, name(b(1))), 2, [], True)
    if hi == 2:
        t = rel(b(1), 2)
        return ('%s L%04X' % (BR[lo], t), 2, [t], op != 0x20)
    if op == 0x42:
        return ('mul', 1, [], True)
    if hi in (3, 4, 5, 6, 7) and lo in RMW:
        m = RMW[lo]
        if hi == 3:
            return ('%s %s' % (m, name(b(1))), 2, [], True)
        if hi == 4:
            return ('%sa' % m, 1, [], True)
        if hi == 5:
            return ('%sx' % m, 1, [], True)
        if hi == 6:
            return ('%s $%02X,x' % (m, b(1)), 2, [], True)
        return ('%s ,x' % m, 1, [], True)
    if op in INH:
        m = INH[op]
        return (m, 1, [], m not in ('rti', 'rts', 'swi', 'stop'))
    if op == 0xAD:
        t = rel(b(1), 2)
        return ('bsr L%04X' % t, 2, [t], True)
    if hi >= 0xA:
        m = ALU[lo]
        if hi == 0xA:
            if lo in (7, 12, 15):
                return ('db $%02X' % op, 1, [], False)
            return ('%s #$%02X' % (m, b(1)), 2, [], True)
        if hi == 0xB:
            a = b(1)
            return ('%s %s' % (m, name(a)), 2, [a] if lo in (12, 13) else [], lo != 12)
        if hi == 0xC:
            a = (b(1) << 8) | b(2)
            return ('%s %s' % (m, name(a)), 3, [a] if lo in (12, 13) else [], lo != 12)
        if hi == 0xD:
            return ('%s $%04X,x' % (m, (b(1) << 8) | b(2)), 3, [], lo != 12)
        if hi == 0xE:
            return ('%s $%02X,x' % (m, b(1)), 2, [], lo != 12)
        return ('%s ,x' % m, 1, [], lo != 12)
    return ('db $%02X' % op, 1, [], False)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rom = open(sys.argv[1], 'rb').read()
    base = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0x0F00
    if base + len(rom) != 0x2000:
        print('; note: %d bytes at %04X do not end at 1FFF' % (len(rom), base))
    vec = {}
    for v, n in ((0x1FFE, 'RESET'), (0x1FFC, 'SWI'), (0x1FFA, 'IRQ'), (0x1FF8, 'TIMER'), (0x1FF6, 'ONE-SECOND')):
        if 0 <= v - base < len(rom) - 1:
            vec[(rom[v - base] << 8 | rom[v - base + 1]) & 0x1FFF] = n
    code, todo, labels = {}, list(vec), set(vec)
    while todo:
        pc = todo.pop()
        while pc not in code and base <= pc < base + len(rom) - 10:
            t, n, tg, ft = decode(rom, base, pc)
            code[pc] = (t, n)
            for x in tg:
                if base <= x < base + len(rom):
                    labels.add(x)
                    todo.append(x)
            if not ft:
                break
            pc += n
    pc = base
    out = []
    while pc < base + len(rom):
        if pc in code:
            t, n = code[pc]
            lab = ('L%04X:' % pc) if pc in labels else ''
            if pc in vec:
                out.append('; ---- %s vector' % vec[pc])
            by = ' '.join('%02X' % rom[pc - base + i] for i in range(n))
            out.append('%-7s %04X  %-9s %-28s ; %d' % (lab, pc, by, t, CYC[rom[pc - base]]))
            pc += n
        else:
            s = pc
            while pc < base + len(rom) and pc not in code:
                pc += 1
            for k in range(s, pc, 16):
                e = min(k + 16, pc)
                ch = ''.join(chr(c) if 32 <= c < 127 else '.' for c in rom[k - base:e - base])
                out.append('        %04X  .db %-48s %s' % (k, ' '.join('%02X' % c for c in rom[k - base:e - base]), ch))
    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
