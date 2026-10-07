# PPCMac: plan for the machine

The CPU's plan ([DSPPC604_plan.md](DSPPC604_plan.md)) took `DSPPC604` from
nothing to running the 7600's ROM on the board. This plan takes the machine
around it, the Power Macintosh 7300/7600 (dingusppc's TNT), from Cuda to Mac
OS booting from a disk image with a picture, a keyboard, a mouse and sound,
and keeps the way open for the Pippin and the Performa 6200. The decisions
it rests on are in the [README](../README.md); everything the machine stubs
or leaves out is in [PPCMac_stubs.md](PPCMac_stubs.md).

The reference ROM is the 7300's (`077D.34F2`, `ppctest/runs/my7300.rom`);
the 7600's (`077D.28F2`) is the second run that must keep passing. Dates are
the day a milestone was closed; open ones carry no date.

| # | Milestone | Proof it is done | State |
|---|---|---|---|
| C | Cuda: the real 68HC05 and Apple's firmware behind the VIA | the ROM's Cuda traffic in lockstep, through Open Firmware into Mac OS; on the board, the CPU's reset released 1.28 s after the machine's and the ROM past Open Firmware's wait for Cuda | done 2026-10-07 |
| I | Interrupts through Grand Central, the VIA first | the ROM in lockstep with the VIA's interrupts taken; its device traffic against dingusppc's whole 7300 shows the same interrupt service; every later source wired with its device | the VIA: done 2026-10-07, in simulation and on the board |
| E | The empty machine: MESH and Curio with no targets, as Mac OS probes them | Mac OS's device traffic without a disk matching dingusppc's through the SCSI probing | |
| T | Serial console: the ESCC's modem port on the MiSTer's UART | Open Firmware's banner and `0 >` prompt over the UART on the board, words typed and answered | |
| V | Video: Control, RaDACal, the Athens clock chip on Cuda's I2C | Mac OS's screen on the MiSTer's output, in simulation as a frame compared with dingusppc's and on the board as a screenshot | |
| K | ADB keyboard and mouse on Cuda's line | Open Firmware typed on from the keyboard; the cursor following the mouse in Mac OS | |
| S | SCSI: DBDMA, MESH, a disk image on the SD card | Mac OS booting from a disk image to the Finder | |
| A | Sound: AWACS and its DBDMA channels | the startup chime, and Mac OS's sound | |
| P | Persistence and the clock: the NVRAM and Cuda's PRAM on the SD card, the clock from the MiSTer's RTC | settings kept across a power-off; Mac OS showing the date | |

The order is the ROM's: what it asks for first comes first, then what makes
the machine usable. Where it differs from the order first proposed, the
decisions table at the end says so.

## What the ROM asks for, in order

dingusppc's whole 7300 run for 10^9 instructions on the 34F2 ROM, 32 MB, no
disk, no keyboard (`rom7300/hw_access.txt`), shows what Mac OS touches after
the NanoKernel starts it at 27.96 million instructions:

| From (instructions) | What | Here |
|---|---|---|
| 28.7 million | Grand Central's interrupt mask gets the VIA (source 12) with the 68k-mode bit; the VIA's timer 2 interrupt (`vIER` A0) every 63,000 instructions or so, then the shift register's for Cuda (`vIER` 84, 29.4 million) | milestone I |
| 29.0 million | the SCC's channel B command register, polled 2,720 times | stub answers; T builds the chip |
| 29.1 million | MESH's bus status, polled 2,406 times; at 86 million its ID read (E2), its set-up, from 230 million selection of every target | E, then S |
| 86.8 million | Curio, the external SCSI controller: set up, and from 355 million selection of every target | E |
| 101 million | AWACS and the sound DMA channels (out and in) | A |
| 119.9 million | the Control video's registers and RaDACal's colour table: the video driver; 127,304 reads of Control's status from 134 million | V |
| 225.7 million | SWIM3, the floppy controller | no drive |
| throughout | the NVRAM, the VIA and Cuda | built |

Before Mac OS the start-up code plays the startup chime by DMA from the ROM
(the sound out channel's command list at FFE00020, instruction 69,494) and
Open Firmware runs with its console on `ttya`: with a blank NVRAM its
`input-device` and `output-device` default to `ttya`, the modem port, ESCC
channel A (`rom7300/of/of_fcode.txt`, FCode at 33F287), and nothing in the
first 119 million instructions draws on the screen.

## Rules that keep the machine from growing special cases

The CPU's rules have a counterpart here. Every milestone is reviewed against
them.

1. **One device port.** A device is a module with the port `PPCMac_gc` and
   `PPCMac_pcicfg` have: `sel` for one cycle, `we`, the word address, byte
   enables and write data, the read data in the next cycle. `PPCMac_machine`
   decodes the map and presents the access; a line is eight word accesses.
   A device that needs time gets it from one mechanism in `PPCMac_machine`
   (today the VIA's pacing), never from a handshake of its own.
2. **One way into memory for everything but the CPU.** A DMA master (the
   DBDMA channels first; anything that scans memory later) asks one DMA port
   in the machine, which takes the line through the CPU's snoop port first
   (the caches write it back or drop it) and then through the same clock
   crossing to the SDRAM. One arbiter between the CPU and DMA; no second
   path to memory. This is the README's coherence rule.
3. **One way into the CPU.** Every interrupt is a line into Grand Central's
   events and levels; the CPU's external interrupt is Grand Central's output
   and nothing else.
4. **Machine-specific things live in machine modules.** The CPU sees its
   memory port, the interrupt, the time base tick and reset, nothing of the
   machine. `PPCMac_machine` is the TNT (7300/7600). The Pippin (dingusppc:
   Aspen, Grand Central, Taos video, a 603) and the 6200 (PSX, O'Hare,
   Valkyrie, a 603e) will be machine modules of their own around the same
   device modules: Cuda, the VIA, the ESCC, SWIM3, MESH, DBDMA and AWACS are
   shared by these designs. A device module has no `if (machine == ...)`; a
   difference is a parameter or another module.
5. **Two checks before the board.** A device is checked in the lockstep run
   (the reference CPU is handed what the device answered, so the CPU is
   compared alone) and by its traffic against dingusppc's whole machine
   (`machref`, `devdiff.py`). Where dingusppc is high-level (Cuda) or
   missing, MAME; above both, the real 7300.
6. **Time from the CPU's clock by phase accumulation.** A device's own time
   base (the VIA's 783,360 Hz, the time base's 12.5 MHz, Cuda's 2 MHz bus)
   is made exactly from the CPU's clock, so the machine behaves the same at
   any `CPU_MHZ`. Clock crossings (video, the SD card, audio) are two-flop
   toggles or quasi-static, as now.
7. **Stubs are written down.** `PPCMac_stubs.md` changes in the same commit
   as the stub; an entry leaves only when the real thing is built and
   tested.

## Milestones in detail

### C: Cuda

Built 2026-10-06 (`rtl/machine/PPCMac_cuda.sv`, `PPCMac_hc05.sv`; the README
and the stubs document have the details): a 68HC05 checked instruction by
instruction against MAME's 6805, running Cuda 2.40 (341S0060, the 7300's own
chip, read out 2026-10-07), behind Grand Central's VIA with a real shift
register. In simulation the ROM's Cuda traffic goes through and both ROMs
run 60 million instructions in lockstep into Mac OS (2026-10-07). What
remains is the board.

**On the board, 2026-10-07.** The full build with Cuda (the debug readout's
status row now also showing how long Cuda held the CPU, in milliseconds):
25,521 ALMs (61 %), 153 RAM blocks, 41 DSP blocks; the CPU's clock closes at
61.26 MHz in the slow 100 C model (65 asked, slack -0.939 ns: every failing
path is inside the CPU, decode into the branch target buffer, a family the
placement moves; next come paths from the data cache through the device
decode into Grand Central's timers, -0.59 ns, which a register stage on
device requests in `PPCMac_machine` would take off at a cycle per device
access: not done yet). The board runs at 65 MHz.
With the 7300's ROM as `boot.rom`, 16 MB:

| | 7300's ROM | 7600's ROM |
|---|---|---|
| Cuda's hold (readout row 6) | 0504: 1,284 ms | 0504: 1,284 ms |
| Where it runs | Mac OS's 68k emulator, user mode (MSR D076), looping at 68067F48-68067F58, 68067640 | the same |
| Device writes, the last after | 28,043, 135,478,744 instructions, then no more for 3.9 billion | 28,043, 135,480,725 |

So Cuda's cold start on the board takes the time the firmware's own delays
predicted, and the ROM goes through Open Firmware's Cuda traffic into Mac
OS, where, with no interrupt yet (this build predates I), it ends in a loop
waiting for time to pass. Against the simulation of the same RTL (the 7300's
ROM, 140 million instructions in lockstep, 2.26 cycles per instruction),
the readout's device-write counts at four moments:

| Device writes | Board: instructions before the last | Simulation | Board - simulation |
|---|---|---|---|
| 27,744 | 28,712,039 | 28,863,964 | -151,925 |
| 27,815 | 32,925,990 | 33,075,867 | -149,877 |
| 27,935 | 101,946,913 | 102,096,232 | -149,319 |
| 28,043 (the last) | 135,478,744 | 135,630,409 (VIA port B, from 68066F70) | -151,665 |

The 7600's ROM likewise: 28,043 writes in its simulation too, the board
150,500 instructions ahead at the 27,885th and 151,348 at the last.
The same writes, the last one included, with a constant offset: the two
part once, before 28.7 million instructions, and then run alike. Before Cuda
the two agreed to three instructions, nothing then depending on time; now
the ROM's and Open Firmware's Cuda waits are polls whose length is real
time, and the bench's memory and its fast Cuda cold start (`CUDA_FAST_BOOT`)
differ from the board's in timing, not in what is done.

### I: interrupts through Grand Central

What it needs: each source's line into Grand Central; Grand Central's event,
mask, clear and level registers as MAME's `heathrow.cpp`
(`macio_device::set_irq_line`, `recalc_irqs`) and dingusppc's
`grandcentral.cpp` (`ack_int_common`, lines 525-589) have them: in native
mode an event at a line's rising edge (a falling edge takes it away); in 68k
mode (the mask's top bit, which the ROM sets at its 135th instruction and
Mac OS keeps) an event at either edge, so the NanoKernel, reading the
levels, follows the line both ways and moves the emulated 68k's interrupt
level up and down. The CPU's interrupt is any unmasked event.

dingusppc's run shows it: from 28.78 million instructions the NanoKernel's
handler (FFF15750, the same address in both ROMs) writes the clear register
(68k mode: everything), reads the mask and the levels; the 68k handler reads
the VIA's timer 2 (F3017000), which drops the line, and the next interrupt
sees the level fall. Two interrupts for each timer 2 period.

The VIA's line is IFR & IER (bits 0-6), as a 6522's IRQ. Its flags today: T1,
T2, the shift register. CA1, CA2, CB1 and CB2 flags are not modelled; Mac OS
enables only T2 and the shift register (`vIER` A0, 84), the ROM nothing else.

Sources to come, with their devices (Grand Central's numbers,
grandcentral.cpp:467-523): Curio 0C, MESH 0D, MACE 0E, SCC A 0F and B 10,
AWACS 11, SWIM3 13, the DMA channels 00-0A (dingusppc's `clear_dma_int`:
in 68k mode a DMA bit in the clear register makes an event of its level),
the PCI slots 17-19, the Control video 1A (through Chaos's map).

Proof: the 7300's ROM in lockstep past 28.8 million instructions with the
VIA's interrupts taken; `devdiff` against `machref` showing the handler's
traffic as dingusppc's; on the board, the device-write count growing as
Mac OS's timer runs.

**The VIA, in simulation, 2026-10-07.** `PPCMac_gc.sv`: the lines as
`int_lines_q` (the levels register, and the edge detector), the events set
at the edges as above, the VIA's IRQ as source 12. The 7300's ROM runs 100
million instructions in lockstep with no difference, 2.29 cycles per
instruction; the CPU takes Grand Central's interrupts from 24.9 million on
(the RTL reaches Mac OS 3.5 million instructions before dingusppc, Cuda
answering Open Firmware sooner than dingusppc's model of it). The first
interrupt is dingusppc's to the access: the NanoKernel's handler clears,
reads the mask (VIA enabled, 68k mode) and the levels (the VIA high), the
68k handler reads timer 2, and a second interrupt finds the level low. With
the handler's own accesses left out, the device traffic matches dingusppc's
access for access from the start of Mac OS to 56.6 million instructions
(dingusppc's 65.3 million), Mac OS's delay calibration (TimeVIADB: timer 2
against a loop of VIA reads) included, and the long polls end on time:
29,006 device reads in 100 million instructions where the run without the
interrupt made 219,264 in 60 million. Two differences follow, neither the
machine's fault: dingusppc re-signals the VIA's interrupt at every register
access while it is active, which in 68k mode makes events a real line
cannot (`PPCMac_stubs.md`); and the real Cuda sends packets dingusppc's
model does not. Then Mac OS reads MESH's ID register (82 million
instructions here, 86 million in dingusppc): dingusppc answers E2, the stub
0, and from there the SCSI Manager takes another path. That is milestone E.

**On the board, 2026-10-07.** The build with the interrupt: 25,379 ALMs,
153 RAM blocks, 41 DSP blocks, the CPU's clock closing at 62.70 MHz slow
100 C (slack -0.565 ns, total -0.883 ns), run at 65 MHz. With either ROM
Cuda releases the CPU after 1,284 ms and Mac OS now runs on its timer: the
device writes keep growing (7300's ROM: 38,489 after 666 million
instructions, about 4,000 every 64 million), and the readout's pc samples
alternate between the NanoKernel's interrupt code (FFF12xxx, FFF14xxx,
MSR 1040), the 68k emulator and native code in the ROM (FFD2xxxx). Against
the simulation: the 27,814th write comes 150,260 instructions earlier on
the board, the offset of the build without the interrupt; by 73 million
instructions the board is 1.08 million ahead (the timer's interrupts come
in real time, and the board's memory is not the bench's), the counts at the
same instruction differing by 18 writes in 28,000.

### E: the empty machine

Mac OS without a disk probes both SCSI buses: MESH (internal) from 86
million instructions in dingusppc's run (ID, set-up, then from 230 million
selection of every target, each ending in a selection timeout and an
interrupt), Curio (external, a 53C94) from 86.8 million, selecting every
target from 355 million. What it needs: MESH's registers as `mesh.cpp` has
them (the ID E2, the sequencer commands, the interrupt and exception
registers, the interrupt line 0D) with dingusppc's SCSI bus controller
sequence (`scsibusctrl.cpp`: arbitration, selection, the timeout) and no
target; Curio's (`sc53c94.cpp`) the same way, line 0C. The selection
timeout is real time (the sel_timeout register); the sequencer counts it
from the CPU's clock (rule 6). This is the half of S that needs no disk and
no DMA.

Proof: the 7300's ROM in lockstep through Mac OS's probing of both buses;
its device traffic, with the values, matching dingusppc's through 355
million instructions (dingusppc's count) apart from the differences
already explained.

### T: serial console

Open Firmware's console with a blank NVRAM is `ttya`, the modem port: the
ESCC's channel A (a Z85C30; dingusppc's `escc.cpp`, 479 lines, which this
stub follows for RR0). What it needs: the channel's asynchronous mode (the
write and read registers OF's driver and Mac OS's serial driver touch, the
transmit and receive data, RR0's status bits), a baud-rate generator that
can be ignored (the MiSTer's UART runs at the core's chosen rate), the
interrupt (0F) for Mac OS, and the MiSTer's UART pins as the port (an OSD
option choosing between the debug readout's hex lines and the modem port).
To stop at the prompt rather than boot, the NVRAM needs `auto-boot?` false:
an NVRAM image loaded at the core's start (as the ROM is), which is the first
half of P.

Proof: on the board, `python syn\mister.py uart` shows Open Firmware's banner
and `0 >`, and a word typed through the MiSTer's `/dev/ttyS1` answers. It
makes Open Firmware's own debugging words (dump, peek and poke of devices,
`see`) available on the board before there is a screen or a keyboard. The
real 7300 is used the same way (a serial terminal at 38400 baud).

### V: video

What it needs, from dingusppc's `control.cpp` (795 lines) and
`appleramdac.cpp` (288):

- Control, the video controller on Chaos (its configuration space is built):
  4 KB of registers at its second BAR (94000000 in dingusppc's run), the
  VRAM at its third (90000000, a 64 MB window; the 7300/7600 have 2 MB, 4 MB
  with the expansion): the timing generator (horizontal and vertical counts,
  sync and blanking), pixel depth (1 to 32 bits), the framebuffer's offset,
  the VRAM bank configuration, the monitor sense lines (the monitor
  attached is a choice: 640 x 480 is the safe one; dingusppc's default is an
  AppleVision 1710 with 4 MB of VRAM), its interrupt.
- RaDACal, its RAMDAC, at Grand Central's IOBus device 2 (F301B000): the
  256-entry colour table and the hardware cursor.
- The Athens clock generator, on Cuda's I2C bus at address 28 (dingusppc
  registers it with Cuda's I2C host): the pixel clock is set by the video
  driver through Cuda. Our Cuda is the chip, bit-banging I2C on its pins, so
  Athens is an I2C slave on those pins in RTL.
- Scan-out: the VRAM does not fit in block RAM. It goes either in the HPS's
  DDR3 (unused by the core so far; the scaler already uses it for its
  buffer) or in the SDRAM beside the RAM and the ROM (120-124 MB is free),
  read a line ahead into a line buffer and sent through the colour table at
  Control's timing to the framework's video output; the framework's scaler
  makes HDMI of it. The framework's direct framebuffer mode (`MISTER_FB`)
  was considered: it saves the scan-out but wants little-endian pixels in
  DDR3 and gives no analog output of the Mac's own timing.

Proof: in simulation, a frame from the bench's VRAM against dingusppc's at
the same point; on the board, a screenshot of Mac OS's screen without a disk.

### K: ADB

What it needs: a keyboard (address 2) and a mouse (address 3) on Cuda's ADB
line, which the firmware bit-banges (`adb_low`, `adb_line` on
`PPCMac_cuda`). The Mac LC core's `adb_device.sv` (938 lines, wire level:
attention, sync, command, Tlt, talk replies, service requests; the MiSTer's
PS/2 keyboard and mouse as the source) was written for an Egret on the same
kind of line; its cell timing is in 32 MHz cycles and moves to the CPU's
clock by parameter. dingusppc models ADB at the packet level
(`adbbus.cpp`, `adbkeyboard.cpp`, `adbmouse.cpp`) and attaches a mouse and
a keyboard by default, so its Mac OS finds two ADB devices where ours finds
none until K (a difference to expect in the Cuda traffic); the wire level is
checked against Cuda's own firmware: `run_cuda.py`'s ADB talk gets an
answer from address 2 and 3, still in lockstep with MAME's 6805.

### S: SCSI and the first disk

What it needs:

- DBDMA (dingusppc's `dbdma.cpp`, 640 lines): channels running descriptor
  programs from memory (INPUT and OUTPUT MORE and LAST, STORE and LOAD QUAD,
  NOP, STOP; interrupt, branch and wait conditions; status), the first bus
  master: through the DMA port of rule 2. Descriptors and data can be in
  the ROM (the chime's are).
- MESH (`mesh.cpp`, 335 lines), the internal SCSI controller, with its DMA
  channel (0A) and interrupt (0D); the SCSI bus and a hard disk target
  (`scsihd.cpp`, `scsicommoncmds.cpp`).
- The disk image on the SD card through `hps_io`'s block interface
  (`img_mounted`, `sd_lba`, `sd_rd`, `sd_wr`, `sd_ack`, the sector buffer),
  as the other MiSTer Mac cores mount theirs: an Apple partition-map image
  of Mac OS 7.5.2 or later (the first PCI Power Mac releases).
- MESH's data phases and DMA commands on top of E's selection; Curio
  stays an empty bus.

Proof: Mac OS booting from a disk image to the Finder, in simulation first
(the lockstep bench at 400,000 instructions a second reaches a billion in
about 40 minutes), then on the board.

### A: sound

What it needs: AWACS (`awacs.cpp`; the 7300/7600 codec, whose status the
stub already answers), the sound out channel (8; in: 9) through the same
DBDMA, the sample rate from the control register (Screamer's table: 44,100
down to 7,350 Hz), the framework's audio outputs. The audio processor on
Cuda's I2C (dingusppc: address 45) if Mac OS's sound driver asks for it.

Proof: the startup chime, which the start-up code plays from the ROM at
instruction 69,494, heard on the board.

### P: persistence and the clock

What it needs: the 8 KB NVRAM in Grand Central (Open Firmware's settings,
Mac OS's XPRAM at 1300-13FF, the RAM bank table) and Cuda's PRAM and clock
(its RAM 100-1FF; MAME writes the clock into Cuda's RAM when Cuda first
releases the CPU's reset, `cuda.cpp pc_w`): loaded at the core's start from
the SD card and written back when they change (the MiSTer's save files,
through `hps_io`'s block interface), and the clock taken from the MiSTer's
RTC (`hps_io`'s `RTC` output) at Cuda's cold start.

Proof: an Open Firmware setting and a Mac OS control panel setting kept across
a power-off of the core; Mac OS showing the MiSTer's date and time.

## Not planned

- Ethernet (MACE): reads 0; nothing waits for it.
- SWIM3 floppy: reads 0, no drive; Mac OS probes it at 226 million
  instructions and carries on.
- The ESCC's channel B (the printer port), PCI cards, the second CPU, the L2
  cache.

## Decisions needed

| When | Question |
|---|---|
| now | The order above puts the empty SCSI buses (E), the serial console (T) and the video (V) before ADB (K) and persistence (P), where the first proposal had ADB and persistence right after the interrupts and the video after them. The reasons: Mac OS asks for MESH right after the interrupt (it is where the RTL's path now leaves dingusppc's); Open Firmware's console is on the modem port; Mac OS reaches the video at 120 million instructions; nothing waits for ADB or saved settings. Keep this order? |
| V | VRAM in the HPS's DDR3 (no load on the SDRAM the CPU's caches use) or in the SDRAM (one memory path, rule 2 simpler)? |
| V | Which monitor the sense lines report (640 x 480 first, larger later?). |
| S | Which disk image format and Mac OS version to test with first. |
