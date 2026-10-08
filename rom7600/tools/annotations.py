"""Hand-written notes for the listings, keyed by address: block comments
(lists of lines placed before the instruction) and inline comments. They
come from reading the code and from the coverage run's device log; the
generator only places them."""

# ---------------------------------------------------------------------------
# PowerPC boot code (physical addresses, ROM FFF00000-FFF0BFFF)

BOOT = {
    0xFFF00100: [
        'Reset vector (MSR[IP]=1 at reset, so the CPU starts here).',
        'r1 -> SPRG1, CR -> SPRG2, then SRR1 is moved to CR: "bne cr7" tests SRR1[RI]',
        '(bit 30). RI = 0 means a hard reset -> FFF03000. Otherwise HID0 goes to CR and',
        '"bns cr3" tests HID0 bit 15 (NHR, "not hard reset", 603/604): clear -> FFF03000.',
        'A soft reset (RI and NHR set) dispatches through the vector table SPRG3 points to',
        '(entry +4). An emulator/FPGA must present SRR1[RI]=0 or HID0[NHR]=0 at power-on.',
        'FFF00104 is the 601 variant of the same code (entered by "b" at 0x104).',
    ],
    0xFFF03000: [
        'Hardware start-up. PVR >> 16 selects the CPU set-up:',
        '  1 (601): HID0 |= 80000020',
        '  3, 6, 7 (603, 603e, 603ev): HID0 |= 02508000 | 4000 (caches on, DPM)',
        '  4 (604) and anything else: HID0 = 8000CC84 (caches enabled and invalidated,',
        '  BHT on), performance monitor (MMCR0, PMC1, PMC2, SDA) cleared.',
        'Then the start-up sequence at FFF030B4 calls, in order:',
        '  FFF03104  r21 = 1 if Hammerhead CPU_ID>>16 == 3001 (another machine), else 0',
        '  FFF03124  clear the BATs; map F0000000-FFFFFFFF 1:1 with DBAT0 (cache-',
        '            inhibited, 256 MB) and turn MSR[DR] on (601: SR15 = 87F0000F)',
        '  FFF031E8  Hammerhead WHO_AM_I bit 0x08000000 set -> secondary CPU: park',
        '  FFF03688  Bandit: config reg 0C of Bandit (IDSEL AD11), then Grand Central',
        '            (IDSEL AD16): BAR0 = F3000000, command = 0016; GC int mask',
        '  FFF0460C  MACE PLSCC = 07',
        '  FFF04620  (r21 = 1 only) Cuda I2C writes',
        '  FFF046E4  VIA init, Cuda synchronisation, Cuda I2C write (addr 88: 61 55)',
        '  FFF03D2C  start the boot chime: AWACS + DBDMA audio-out from ROM',
        '  FFF03E98  memory: Hammerhead timing from CPU_SPEED, bank bases, RAM sizing,',
        '            bank packing, bank table saved in NVRAM (1044, 1048+8n, 104C+8n)',
        '  FFF03D1C  r29 = ConfigInfo (FFF00000 + [FFF00080] = FFF0D000)',
        '  FFF04C24  run the HWInit/diagnostics code (FFF2003C); failure -> error beep',
        '  FFF0373C  r22 = first populated bank (from the NVRAM bank table); clear',
        '            1240 bytes there (dcbz): the boot info area',
        '  FFF03798  copy the bank table to the info area (r22+1000)',
        '  FFF03810  measure the bus clock (VIA T1 vs DEC) and CPU clock (DEC-timed',
        '            loop); store CPU/bus/timebase Hz at r22+1104/1108/110C',
        '  FFF03BBC  L2 cache (Hammerhead L2 register)',
        '  FFF0338C  clear the BATs',
        '  FFF04C5C  run Open Firmware (FFF3003C) with r3 = r22+1000, r4 = r22+1100,',
        '            r5 = PA_OpenFirmware (00400000); Open Firmware returns when it boots',
        '            the Mac OS',
        '  FFF0338C  clear the BATs',
        '  FFF04C94  jump to the NanoKernel (ConfigInfo + KernelCodeOffset = FFF10000)',
        '            with r3 = ConfigInfo, r4..r6 = info areas, r7 = Open Firmware result',
    ],
    0xFFF03104: [
        'Machine check: reads 32 bits at Hammerhead CPU_ID. The 7600\'s Hammerhead gives',
        '0x39 in the top byte (RISC machine, extended ID, TNT), so r21 = 0. r21 = 1',
        '(CPU_ID>>16 == 3001) selects code for another memory controller; most routines',
        'below test r21 and return or branch to that variant.',
    ],
    0xFFF03124: [
        'BAT set-up for the I/O space: DBAT0U = F0001FFF (EA F0000000, 256 MB, Vs Vp),',
        'DBAT0L = F0000032 (PA F0000000, WIMG 0110 = cache-inhibited, coherent; PP 10).',
        'Then MSR[DR] = 1; instruction fetch stays untranslated.',
    ],
    0xFFF031E8: [
        'Dual-CPU check: Hammerhead WHO_AM_I (F80000B0) bit 0x08000000 set means this is',
        'not the primary CPU; it then sets MSR[POW] in a loop (doze until interrupted)',
        'via FFF032C4. The primary CPU must read this bit as 0.',
    ],
    0xFFF032C4: [
        'Secondary CPU: MSR |= EE | POW in a loop. When woken, the handler at FFF032E4',
        'acknowledges via Hammerhead INT_REG (F80000C0) and jumps to the address it',
        'reads from Bandit CONFIG_ADDR (used as a mailbox).',
    ],
    0xFFF03468: [
        'CPU clock measurement: 8 dependent addi + bdnz, run 1 and then 1024 times with',
        'the decrementer as the clock (DEC runs at the timebase rate, r23 = bus/4).',
        'CPU Hz = 8192 * r23 / DEC ticks, which assumes 1 instruction per cycle for the',
        'addi chain; the result is rounded to the nearest entry (within 1/512) of the',
        'table below (20 MHz ... 200 MHz) or left as measured. A core that does not',
        'sustain 1 IPC on this loop reports a lower clock to Open Firmware and the OS.',
    ],
    0xFFF03578: [
        'Round r3 to a table entry if within 1/512; table follows the bl.',
    ],
    0xFFF035E0: [
        'NVRAM access (Grand Central): byte address A of the 8 KB NVRAM is split in a',
        'page and an index: (A >> 5) is written to NVRAM_ADDR F301D000 with stwbrx (so',
        'the page number lands in the low byte of the little-endian register), then',
        'the byte is at NVRAM_DATA F301F000 + (A & 1F) * 16. This routine adds 1300:',
        'the Mac OS parameter RAM (XPRAM) starts at NVRAM 1300.',
        'FFF03608 / FFF03648 write / read 32 bits as 4 consecutive NVRAM bytes.',
    ],
    0xFFF03688: [
        'Bandit PCI configuration (CONFIG_ADDR F2800000 / CONFIG_DATA F2C00000, both',
        'little-endian: stwbrx/lwbrx; values below are the little-endian register',
        'values). Type-0 addresses use one-hot IDSEL bits:',
        '  0000080C  Bandit itself (AD11), register 0C <- 00FF0000',
        '  00010010  Grand Central (AD16), BAR0 (reg 10) <- F3000000',
        '  00010004  Grand Central command register <- 0016 (memory space, bus master,',
        '            memory-write-and-invalidate)',
        'Each address write is read back. Grand Central does not respond at F3000000',
        'before this (on real hardware). Then GC_INT_MASK (F3000024) <- 80000000',
        '(again a little-endian value written with stwbrx).',
    ],
    0xFFF0373C: [
        'Find the first RAM bank with a non-zero size in the NVRAM bank table',
        '(NVRAM 1048+8n = base, 104C+8n = size, n < 26); none -> error beep and hang',
        '(FFF04CB8). r22 = its base; clear 1240 bytes there with dcbz (needs the data',
        'cache on and RAM working).',
    ],
    0xFFF03798: [
        'Copy the NVRAM bank table into the info area at r22+1000 (+30: base/size',
        'pairs, +0: total RAM from NVRAM 1044, +4: sum of the sizes).',
    ],
    0xFFF03810: [
        'Clock measurement: bus clock -> r25 (FFF03888), timebase = r25/4 -> r23',
        '(601: fixed constant), CPU clock -> r24 (FFF03468). Stored at r22+1104 (CPU',
        'Hz), r22+1108 (bus Hz), r22+110C (timebase Hz).',
    ],
    0xFFF038DC: [
        'Bus clock: VIA timer 1 is started at FFFF (vT1L low latch then vT1CH, which',
        'loads and starts the counter), the decrementer is set to 3FFFF and polled until',
        'it reaches 0; then the VIA counter is read (high, low, high again until the',
        'two high reads agree). Elapsed VIA ticks are looked up in the table below',
        '(pairs: tick threshold, bus Hz; 33/40/50 MHz ...). The VIA counts at 783.36 kHz',
        'and the decrementer at bus/4 on the real machine: an implementation must keep',
        'that ratio or the ROM measures a wrong bus clock (and timebase frequency).',
    ],
    0xFFF03BBC: [
        'L2 cache: Hammerhead L2 register (F80000E0) bit 7 set -> flush/enable sequence',
        'using F80000F0; the L2 size goes into the info area (r31 = r22+1000).',
    ],
    0xFFF03D2C: [
        'Boot chime: the sound is the ROM resource \'beep\' 0 ("Boot Beep Resource") at',
        'FFE00010. Its first words are 00000010 (header size), a rate code, the length,',
        'and at +10 a DBDMA command list (little-endian, OUTPUT_MORE commands) whose',
        'data addresses point into the ROM (FFE000A0...). FFF03E28 sets the AWACS rate',
        '(F3014000 control), the volume from XPRAM byte 8 (NVRAM 1308) through the',
        'AWACS codec control register (F3014010, waiting on its busy bit), then the',
        'DBDMA audio-out channel: cmdptr (F300880C) = the list, control (F3008800) =',
        'F0008000 (little-endian value: mask F000, RUN). DBDMA must read descriptors and data',
        'from ROM. The chime then plays while start-up continues. The error beep is',
        '\'beep\' 1 at FFE40010 (FFF03D44).',
    ],
    0xFFF03E98: [
        'Memory set-up (TNT path; r21 = 1 has its own at FFF04304):',
        '  FFF03ECC  Hammerhead MEM_TIMING_0/1, REFRESH_TIMING, ROM_TIMING from a',
        '            table indexed by the bus-speed bits of CPU_SPEED (F8000030);',
        '            ROM_TIMING value depends on MOTHERBOARD_ID bit 0x10; ARBITER_CONFIG',
        '            is read and written back',
        '  FFF0402C  all 26 bank base registers (F80001C0-F80004F0, MSB/LSB pairs) set',
        '            to distinct 64 MB slots so that banks do not overlap while sized',
        '  FFF04060  for each bank: size it (FFF0412C), set the size bit if the size',
        '            is not a power of two and resize, program its real base (banks',
        '            packed from 0), record base and size in NVRAM; total -> NVRAM 1044',
        '  FFF04278  pairs of equal, adjacent banks get an interleave bit',
    ],
    0xFFF03ECC: [
        'Hammerhead timing: the table after the bl has 4 entries of 32 bytes (by bus',
        'speed): MEM_TIMING_0, MEM_TIMING_1, REFRESH, ROM_TIMING (non-burst), ROM_TIMING',
        '(burst ROM: MOTHERBOARD_ID bit 0x10).',
    ],
    0xFFF0412C: [
        'RAM sizing of one bank (r3 = base, r4 = 64 MB maximum, r5 = 1 MB step), with',
        'data translation off. From the top down, every MB gets "Kurt" (4B757274) and',
        '"Lika" (4C697A61) in its last 8 bytes (old contents saved), dcbf + sync, then',
        'a dummy store of FFFFFFF0 to address FFFFFFF0 (ROM space: changes the data on',
        'the bus so that a missing bank cannot read back the last value written) with',
        'dcbf + sync, then the pattern is read back. The first MB where it reads back',
        'is the top of the bank; walking up from the base to the first place where the',
        'pattern appears (mirroring), then repeating with the words swapped, gives the',
        'size (returned in r3; 0 = empty). The machine must ignore stores to ROM.',
    ],
    0xFFF0460C: [
        'MACE (Ethernet) PLSCC register (F30110E0) <- 07: port select.',
    ],
    0xFFF046E4: [
        'Cuda (TNT path). FFF04740: VIA init: vBufA = 10, vDirA = 58, vBufB = 38,',
        'vDirB = 30 (PB5 = TIP and PB4 = BYTEACK outputs, PB3 = TREQ input), vPCR = 0,',
        'vACR = 1C (shift register under external clock), vIER = 7F (all off);',
        'FFF04798: shift in, vIER = 84 (SR interrupt on).',
        'FFF047C0 synchronises with Cuda (TIP/BYTEACK toggling, waiting for TREQ and for',
        'the shift-register flag in vIFR, timeouts of D05 and 3A98 loop iterations).',
        'If that succeeds, FFF048B4 sends a pseudo packet: type 01, command 22',
        '(read/write I2C), data 88 61 55: an I2C write to address 88 (8-bit form).',
    ],
    0xFFF047C0: [
        'Cuda synchronisation: TIP and BYTEACK high; wait D05 reads; if TREQ (PB3) is',
        'low, wait for vIFR bit 2 (SR); read vSR; BYTEACK low and wait (3A98 loops) for',
        'TREQ high, then SR flag, BYTEACK high, TREQ low, SR flag; finally TIP and',
        'BYTEACK high. Returns r5 = 0 on success, 1 on a timeout.',
    ],
    0xFFF048B4: [
        'Send a Cuda packet: r6 = packet type, r5 = command, r7 = up to 4 data bytes',
        '(low byte first), r8 = count; then reads the reply. Each byte: write vSR, toggle',
        'BYTEACK (vBufB bit 4), wait for vIFR SR flag (3A98 loops); TIP (bit 5) frames the',
        'packet; retried up to 10 times. r12 = 1 on failure.',
    ],
    0xFFF04C24: [
        'Run the HWInit code: LR = ConfigInfo + HWInitCodeOffset + 3C (= FFF2003C),',
        'r3 = ConfigInfo, r4/r5/r6 = info areas (r22+1100/1000/1140). A non-zero',
        'result plays the error beep (FFF03D44).',
    ],
    0xFFF04C5C: [
        'Run Open Firmware: LR = ConfigInfo + OpenFWBundleOffset + 3C (= FFF3003C, the',
        'XCOFF text), r3 = r22+1000, r4 = r22+1100, r5 = PA_OpenFirmware (00400000).',
        'When Open Firmware returns (after its boot of the Mac OS), r5 is stored at',
        'physical 00400000 and passed on to the NanoKernel in r7.',
    ],
    0xFFF04C94: [
        'Enter the NanoKernel: LR = ConfigInfo + KernelCodeOffset (FFF10000), r3 =',
        'ConfigInfo, r4 = r22+1100, r5 = r22+1000, r6 = r22+1140, r7 = Open Firmware',
        'result.',
    ],
}

BOOT_INLINE = {
    0xFFF0011C: 'SRR1[RI] = 0: hard reset',
    0xFFF00128: 'HID0[NHR] = 0: hard reset',
    0xFFF03110: 'TNT: CPU_ID top byte 0x39',
    0xFFF031F8: 'bit 0x08000000: secondary CPU',
    0xFFF04178: 'dummy store to ROM space (FFFFFFF0)',
    0xFFF04200: 'dummy store to ROM space (FFFFFFF0)',
    0xFFF04238: 'dummy store to ROM space (FFFFFFF0)',
    0xFFF03E74: 'DBDMA audio out: cmdptr = command list in the beep resource',
    0xFFF03E88: 'DBDMA audio out: control = RUN',
    0xFFF04C48: 'call HWInit at FFF2003C',
    0xFFF04C7C: 'call Open Firmware at FFF3003C',
    0xFFF04CB4: 'jump to the NanoKernel at FFF10000',
}

KERNEL = {
    0xFFF10000: [
        'NanoKernel entry from the boot code (FFF04C94): r3 = ConfigInfo, r4..r6 = boot',
        'info areas, r7 = Open Firmware result. It sets up its data (LA_KernelData),',
        'the page table and BATs from the ConfigInfo tables, its exception vectors,',
        'interrupt handling through Grand Central (LA_InterruptCtl F3000000, masks from',
        'ConfigInfo), and starts the 68k emulator in user mode at EmulatorEntry',
        '(6806E660).',
    ],
}

HWINIT = {
    0xFFF2003C: [
        'HWInit entry, called by the boot code (FFF04C24) with r3 = ConfigInfo. Runs the',
        'ROM diagnostics; the Serial Test Manager (menu text below) is entered only on',
        'request. First it stores LR (NVRAM 1250), CTR (1270) and r0-r31 (11D0 + 4n)',
        'into NVRAM through FFF21164 (a 32-bit NVRAM write): every boot rewrites this',
        'register dump area of the NVRAM.',
    ],
}

EMULATOR = {
    0x6806E660: [
        'EmulatorEntry (ConfigInfo EmulatorEntryOffset E660): the NanoKernel starts the',
        '68k emulator here with r3 = emulator data; sets r1 = r3 + 1000 and calls the',
        'initialisation at 6806E6C0. The words at 6806E680 are the KernelTrapTable',
        '(twi 31,r31,0..F: the kernel calls the emulator uses).',
    ],
}

OF_ROM = {}
OF_RAM = {}

M68K = {
    0xFFC0002A: [
        'ResetEntryJMP: 68k cold start (the emulator starts the 68k ROM here, the reset',
        'PC in the header is +2A).',
    ],
    0xFFC00074: [
        '68k start-up: interrupts off, caches (CACR, 68040 cinva), MMU off (TC, DTT0/1),',
        'then the universal ROM\'s hardware identification and Toolbox start-up.',
    ],
    0xFFC14844: [
        'Board identification (universal ROM): Hammerhead CPU_ID byte == 39 (TNT), then',
        'MOTHERBOARD_ID bit 0x40000000 -> 3020, else Grand Central board register 1 bit',
        '0x00080000 -> 3022, else 3021 (taken in the coverage run). Otherwise a CPU_ID top',
        'half of 3001 selects the other memory controller. Result in D0, returns via A6.',
    ],
    0xFFC0218A: [
        'Hottest loop of the coverage run: when the search for a start-up device finds',
        'nothing, wait 15 ticks (Ticks, $16A, advanced by the 60 Hz interrupt) and try',
        'again (back to FFC0211A). With no disk attached the run ends circling here.',
    ],
}
