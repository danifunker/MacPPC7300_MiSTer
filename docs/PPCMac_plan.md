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
| T | Serial console: the ESCC's modem port on the MiSTer's UART | Open Firmware's banner and `0 >` prompt over the UART on the board, words typed and answered | done 2026-10-07 |
| E | The empty machine: MESH and Curio with no targets, as Mac OS probes them | Mac OS's device traffic without a disk matching dingusppc's through the SCSI probing | done 2026-10-07, in simulation and on the board |
| V | Video: Control, RaDACal, the Athens clock chip on Cuda's I2C | Mac OS's screen on the MiSTer's output, in simulation as a frame compared with dingusppc's and on the board as a screenshot | done 2026-10-07, in simulation and on the board |
| K | ADB keyboard and mouse on Cuda's line | Open Firmware typed on from the keyboard; the cursor following the mouse in Mac OS | done 2026-10-07, on the board |
| S | SCSI: DBDMA, MESH, a disk image on the SD card | Mac OS booting from a disk image to the Finder | done 2026-10-08 on the board: Mac OS 7.6.1 to the Finder with every extension, Open Transport included; mouse, keyboard, Shut Down |
| A | Sound: AWACS and its DBDMA channels | the startup chime, and Mac OS's sound | the chime bit-exact in simulation (2026-10-08); on the board, to be heard |
| P | Persistence and the clock: the NVRAM and Cuda's PRAM on the SD card, the clock from the MiSTer's RTC | settings kept across a power-off; Mac OS showing the date | the clock from the RTC and the NVRAM on the SD card, on the board (2026-10-08); a setting's survival still to be shown |
| X | The PCI bus: Bandit's slots decoded by their BARs, a PCI card (a video card first) | a PCI card found by Open Firmware and driven by Mac OS | later |

The order is the ROM's: what it asks for first comes first, then what makes
the machine usable; the serial console comes first of all, because Open
Firmware over the modem port is how validation tests will be run (decided
2026-10-07; T does not depend on E: Open Firmware never touches MESH's ID,
Mac OS does).

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
| 225.7 million | SWIM3, the floppy controller: the .Sony driver's probe (the phase lines written and read back) | the chip with an empty drive (`PPCMac_swim3`): the driver must install, or the 7.6.1 System crashes while loading (S) |
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

**Built, in simulation, 2026-10-07.** `PPCMac_mesh.sv` and
`PPCMac_sc53c94.sv` (Curio's 53CF94 cell) inside `PPCMac_gc`, on Grand
Central's sources 0D and 0C, timed by a 25 MHz tick from the CPU's clock
(`SCSI_HZ` in `PPCMac_machine`). What each does and leaves out is in their
headers and in `PPCMac_stubs.md`. The selection timeouts follow the chips'
registers: MESH's in 10 ms units (the ROM computes it as milliseconds / 10,
`nitt` 43 at FFEB7C1C, and writes 0x19, dingusppc's fixed 250 ms), Curio's
as 8192 x the clock factor x the register in the chip's clocks (MAME's
formula; 25 MHz assumed, so the ROM's factor 5 and A7 make 273.6 ms).

The 7300's ROM ran 450 million instructions in lockstep with no difference
(1.95 cycles per instruction). Mac OS reads MESH's ID (E2, 82.0 million
instructions), resets the bus and MESH and sets it up; sets Curio up and
reads the high transfer count as dingusppc's run does (00, configuration 2
being 80 by then); from 146.7 million arbitrates and selects on MESH IDs 0,
6, 5, 4, 3, 2, 1, 0, each ending in the selection-timeout exception 250 ms
later (8.2 million instructions); then on Curio IDs 6 down to 0 (from 212.7
million, a disconnect interrupt 273.6 ms after each); then, waiting for a
startup disk, MESH ID 0 again and again. The same targets in the same order
as dingusppc's run, every register value the same, against a machref log of
10^9 instructions (which covers the RTL's 450 million: dingusppc's time is
16 ns an instruction, so its 250 ms is 15.6 million instructions). Two
differences in the SCSI traffic, both explained:

- After each arbitration and select, dingusppc's MESH keeps its interrupt
  line up although the select has cleared command done (its line is
  recomputed only at some events), so Grand Central's level for MESH reads
  high and Mac OS runs MESH's interrupt service once more, finding nothing
  (FFEBB27C reads 00). Here the line follows the registers, the level reads
  low and that service call does not happen. Both machines take the
  interrupt the stale 68k-mode event makes when Mac OS enables MESH in
  Grand Central's mask.
- Mac OS retries ID 0 on a timer while it waits for a disk, so the two
  machines make different numbers of retries in a stretch of instructions.

Elsewhere the traffic differs where it did before E (the real Cuda's
packets, VIA timer values, the RAM sizing) and where dingusppc has devices
we have not built: its Control video and RaDACal from 115 million (the
video driver's traffic; milestone V). The 7600's ROM runs 300 million
instructions in lockstep (2.11 cycles per instruction) through the same
probing: MESH's ID, MESH IDs 0, 6-1, 0 and on, Curio IDs 6-0. The serial
console still answers in lockstep (`dev / ls` now lists `/53c94@10000`
and `/mesh@18000` with their `sd` and `st` children, as before E).

**On the board, 2026-10-07.** 24,489 ALMs, 153 RAM blocks, 42 DSP blocks;
the CPU's clock closes at 63.03 MHz slow 100 C (slack -0.481 ns), run at
65. With the 7300's ROM, 16 MB and a blank NVRAM, Mac OS runs through the
probing and on (about 33 million instructions a second, 2.09 cycles per
instruction; the readout's pc samples in the SCSI Manager, FFEC4Cxx, among
the NanoKernel's and the 68k emulator's, nothing stuck), the device writes
growing as the simulation's at the same instruction counts: 26,858 against
26,852 at 23.7 million, 28,517 against 28,427 at 92.5 million, 36,182
against 35,678 at 450-460 million, the board a little ahead because its
instructions take a little more time (Mac OS's timer writes by real time).
With `syn/nvram_of_prompt.bin` Open Firmware answers on the modem port as
before, and its device tree gives the two controllers' clocks:
`/bandit/gc/mesh` `clock-frequency` 02FAF080 (50 MHz, `model`
AAPL,343S1146, interrupts 0D and DMA 0A), `/bandit/gc/53c94` 017D7840
(25 MHz, the clock assumed for Curio's selection timeout).

A probe disk for the real 7300 measures what the emulators can only guess
here (`hwprobe/`: MESH's and Curio's selection timeouts, MESH's command-done
behaviour, Curio's part ID, the time of a device access, the VIA's
included); built and checked under dingusppc with the 7300's ROM, waiting
for a run on the machine.

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

**Built, in simulation, 2026-10-07.** Open Firmware's driver (the ROM's
FCode image 6) resets channel A, sets the baud-rate generator's time
constant to 1 from RTxC (3.6864 MHz) in x16 mode, 8 data bits, 2 stop
bits, and transmits through the kernel's `scc-write` (waits for RR0's
transmit-buffer bit, gives up if a character has arrived) and receives
through `scc-read` (takes characters while RR0's receive bit is set):
38,400 baud. `PPCMac_escc.sv` is the Z85C30's asynchronous mode for both
channels, channel A on the modem port's pins, at the rate the registers
set (RTxC by phase accumulation from the CPU's clock). With a blank
NVRAM Open Firmware writes its defaults (it clears all 8 KB at 10.4
million instructions, then writes its partition at 1800: `auto-boot?`
true, `input-device` and `output-device` `ttya`); `verilator/nvram.py`
rebuilt that image from the device log and set `auto-boot?` false
(`syn/nvram_of_prompt.bin`). The machine loads an image through a port
into Grand Central's NVRAM while reset is held; the board takes it from
`boot1.rom`. The bench's terminal decodes the port and types lines at
prompts. With the image both ROMs stop at Open Firmware's prompt after 24.8
million instructions, in lockstep, the banner byte for byte what dingusppc
prints with the same image and its ESCC on stdio:

```
Open Firmware, 1.0.5
To continue booting the MacOS type:
BYE<return>
To continue booting from the default boot device type:
BOOT<return>
 ok
0 > 1 2 + . 3  ok
```

and `dev / ls` (the device tree) and `printenv` answer. Without an image
the device traffic is byte for byte what it was before the ESCC (both ROMs,
100 million instructions).

**On the board, 2026-10-07.** 26,019 ALMs, 153 RAM blocks, 41 DSP blocks;
the CPU's clock closes at 62.31 MHz slow 100 C (slack -0.666 ns), run at
65. With `syn\nvram_of_prompt.bin` as `boot1.rom` the banner and `0 >` come
over the MiSTer's UART about two seconds after the core starts, and lines
typed with `python syn\mister.py type` are answered: `1 2 + .` (3), `dev /
ls` (the whole device tree), `printenv auto-boot?` (false, default true),
`hex 7 d# 6 * .` (2A), `see bye`. Two lessons from getting there: a line
sent at full speed loses characters, because Open Firmware echoes each one
with a few bytes of escape sequences and the Z85C30's receive FIFO holds
three (so `type` sends a character every 15 ms, as typing does); and a
reader of `/dev/ttyS1` left running on the MiSTer takes part of the output
(so `uart` and `type` stop any before starting theirs). The OSD's other
UART choice, the debug readout's hex lines at 115,200, still works.

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
- The VRAM, all 4 MB (Control's standard 2 MB bank and the optional
  second), in the HPS's DDR3 through the framework's `DDRAM` port (decided
  2026-10-07): the CPU's accesses to Control's VRAM BAR go there, and the
  scan-out reads it a line ahead into a line buffer in block RAM, through
  RaDACal's colour table (block RAM too) at Control's timing to the
  framework's video output; the framework's scaler makes HDMI of it. Block
  RAM cannot hold the VRAM itself: the FPGA has 553 blocks of 10 Kbit,
  about 690 KB in all (the core uses 153 blocks), where one 640 x 480 frame
  is 300 KB at 8 bits a pixel and 1.2 MB at 32. The framework's direct
  framebuffer mode (`MISTER_FB`) was considered: it saves the scan-out but
  wants little-endian pixels and gives no analog output at the Mac's own
  timing.

Proof: in simulation, a frame from the bench's VRAM against dingusppc's at
the same point; on the board, a screenshot of Mac OS's screen without a disk.

**Built, 2026-10-07.** What Mac OS asks for (dingusppc's run, the 7300's
ROM): Open Firmware puts Control's registers at 94000000 and its VRAM
window at 90000000 (Chaos's BARs, 27.4 million instructions) and leaves the
screen alone (its console is the modem port); Mac OS's video driver, from
RAM, sets RaDACal up and loads a linear colour table (119.6 million), sets
MISC_ENABLES to wide VRAM (40, then 51), probes the VRAM's size (writes
"Nano" at the big-endian aperture's 0 and reads 8), programs Athens through
Cuda (30.215 MHz with the 13-inch monitor: 31.3344 x 27 / 28), disables the
timing, writes Swatch's values (640 x 480: exactly what Linux's
`controlfb.c` computes for 864 x 525, sync 64 dots and 3 lines), enables it
with two RESET_TIMING strobes (130.9 million), and fills the screen with the
50 % grey at 32 bits a pixel (ROW_WORDS 0A20, GBASE 200); then waits for the
VBL by polling INT_STATUS. dingusppc's default monitor, "AppleVision1710",
is only an alias for its 13-inch sense code, which is why its Mac OS picks
640 x 480.

The pieces: `PPCMac_control.sv` (Control's registers, and `PPCMac_swatch`,
its timing in the video clock), `PPCMac_radacal.sv` (in Grand Central, IOBus
device 2; its colour table has a second copy read by the scan-out),
`PPCMac_athens.sv` (an I2C slave on Cuda's pins: our Cuda is the chip, so
the driver's packets reach Athens as bits), `PPCMac_video.sv` (the dot clock
as a clock enable of the 100 MHz memory clock, Swatch, the line fetch into
two line buffers, the pixels: 8 bits through the colour table, 16 and 32
direct, the hardware cursor from the 16 bytes before each line; and the
VRAM's DDR3 port, the scan-out first and the CPU's accesses second). The
machine's decoder follows Control's two BARs; the VRAM is memory, not a
device: its own clock crossing (a second `DSPPC604_memcdc`) takes the CPU's
VRAM accesses to the picture side, after the machine has turned the window
offset into a VRAM address and the bytes into VRAM's order (the
little-endian aperture's per-pixel swap). Rule 1 is kept for the
registers; rule 2 does not apply (the VRAM is not main memory and nothing
but the CPU writes it). The bench models the DDRAM port (`core_main.cpp`,
4 MB, a few cycles of latency) and writes a frame of the picture
(`--frame-at N --frame-out FILE`); `machref` writes dingusppc's
(`null_host.cpp`: the video controller's converter, called at the first
refresh after N instructions).

In simulation: the 7300's ROM runs 145 million instructions in lockstep
through the video driver (655,341 device writes compared, nearly all
VRAM), and every Control, RaDACal and VRAM access of dingusppc's run, the
values included, comes in the same order (619,206 of them to 146 million),
leaving out only the VBL handler's (INT_ENABLE's clear and INT_STATUS's
polls, which come at frame times, real time on both machines); the driver
was loaded 2000 bytes lower in RAM here (dingusppc's Mac OS has its ADB
devices), so only the program counters differ. The frame after 141.8
million instructions is dingusppc's after 144.9 million pixel for pixel
(640 x 480, the grey). With the 16-inch monitor (`--monitor 16`; machref
`--set mon_id=MacRGB16in`) Mac OS picks 832 x 624, and the frames match
pixel for pixel again (519,168 pixels). The 7600's ROM runs 145 million
instructions in lockstep through its video driver too, its frame the same.

On the board: 26,874 ALMs (64 %), 165 RAM blocks, 46 DSP blocks; the CPU's
clock closes at 64.47 MHz slow 100 C (slack -0.127 ns), the memory and
video clock at 112.96 MHz (100 asked); run at 65. With a blank NVRAM Mac OS
draws its screen: the screenshot (the framework's, through the scaler) is
832 x 624 with the 16-inch monitor and 640 x 480 with the 13-inch, the
grey, the rounded corners and the arrow pointer of the hardware cursor at
the top left. The debug readout (OSD Picture) and Open Firmware's console
on the modem port still work.

**The pointer's trails, found and fixed 2026-10-07 (the S session).** The
user saw the pointer leave trails over Mac OS's screen on the board. Mac OS
maps the frame buffer cacheable and write-through (its VRAM traffic is word
writes and line reads), and it draws the pointer itself (no hardware cursor
in this mode: the 32-bit "grey" is alternating black and white pixels),
saving what is under it and putting it back. The machine bench's new
`--vram-check` (a copy of every VRAM byte the CPU writes, every CPU read
checked against it, and every read the picture side answers checked against
the DDR3) found the cause in minutes: the CPU's data cache asks for a line
with the address of the word that missed, and `PPCMac_video` started the
line's DDR3 burst at that word, not at the line's first, so a line whose
first touch was in its middle came back shifted, and the saved background
with it. The SDRAM controller had always started a line at its first word;
the frame comparisons of V passed because the driver only wrote. With the
burst at the line's start the same run (the mouse moving from 200 million
instructions, 13,394 VRAM line reads to 260 million) reads back every byte
as written, in lockstep throughout.

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

Done (2026-10-07). `PPCMac_adb.sv` puts both devices on the line, their
time in Cuda's 4,194,304 Hz ticks, the PS/2 inputs from `hps_io`; the
decisions are in the table below. `run_cuda.py` now has Cuda's firmware
talk to them (`cuda_tb_top.sv`): register 3 of each (62 02, 63 01), an
empty address (flags 02), a key (A down: 00 FF) and a mouse move (right 5,
up 3: FD 85), a move to address 9 and a handler change by Listen 3, the
keyboard's register 2 (FF FF), SendReset; twenty packets, every reply
checked, in lockstep with MAME's 6805. Two faults turned up on the way.
Cuda's PA6 had been taken inverted (it is the line's level: the firmware's
receive at 1CF3-1D88 shows it), so every ADB command came back with a
service request and no device could answer. And the devices' reset-pulse
detector read the high before each attention as a long low after more than
2 ms of idle, resetting them (the keyboard passed only because its test
came sooner).

On the board (26,869 ALMs, 64 %; the CPU's clock closes at 64.81 MHz slow
100 C): through the MiSTer Remote's virtual mouse, the pointer moves from
the top left corner right and down, then back up and left, over Mac OS's
grey screen and its flashing question-mark disk; with an NVRAM image whose
`input-device` is `kbd` (`syn\nvram_of_kbd.bin`), Open Firmware takes
`1 2 + .` and `words` from the Remote's virtual keyboard and answers on the
modem port (`3 ok`, its dictionary). Not tried on the board: Talk 2,
handler changes, service requests between the two devices with Mac OS
polling (all in the Cuda bench).

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

How the disks reach the core (decided 2026-10-07 at the user's request: do
it as the Mac Quadra 800 core does): the standard `hps_io` block interface,
with Main_MiSTer's Mac SCSI family support (`support/mac/`, upstream since
PRs 1255-1336). That code recognises a core by name prefix; branch
`ppcmac-scsi-family` of `..\Main_MiSTer` (commit 5797d42, in the worktree
`..\Main_MiSTer_ppcmac`; not pushed, not upstream yet) adds `ppcmac`. So
the core uses the family's slot layout (as MacLC's, `VDNUM` 6): hard disks
on slots 0 and 1, slot 2 free (the NVRAM, milestone P, as the Quadra keeps
its PRAM there), the BlueSCSI Toolbox on 3, the CD-ROM on 4 (later), the CD
changer on 5; `BLKSZ` 2 (512 bytes) with `sd_blk_cnt` for multi-block
transfers (Main's write buffer takes writes on slots 0 and 1 and writes
them out in runs; each unbuffered write costs about 4 ms on the card). What
to take from `..\MacQuadra800_MiSTer` (its README and the survey in this
session): the mount replay (`MacQuadra800.sv` 534-589: the core-start mount
lands inside reset, so the size and valid bit are latched and replayed after
every reset), the two-half sector buffer and the HPS byte order
(`rtl/ncr53c96.sv` 632-653, 1875-1977: the HPS gives disk byte 0 in bits
7-0, the Verilator harness big-endian), the target's command set
(`exec_cdb`: TEST UNIT READY, INQUIRY, MODE SENSE with Apple's page,
READ CAPACITY, READ and WRITE 6/10, ...) as a target module of its own
behind MESH, and `rtl/scsi_cache.sv` only if measurements ask for it (the
Quadra's release build runs with it off). Two differences here: this core's
`hps_io` runs in the memory clock (100 MHz) and the machine in the CPU's,
so the sector buffer is a dual-clock RAM with synchronised handshakes; and
DMA (DBDMA through the snoop port, rule 2) moves whole sectors, so
multi-block requests come naturally. Main's family code also zeroes two
words of DDR3 at byte 0x1FF04000 and 0x1FF20000 the first time it polls,
for any core (its Ethernet mailbox): V's VRAM must stay clear of
0x1FF00000-0x1FF21000. And Main does not flush its write buffer when a core
is reloaded (up to 20 ms of writes, 500 ms under continuous writing): wait
a moment after the last write before loading another core.

Proof: Mac OS booting from a disk image to the Finder, in simulation first
(the lockstep bench at 400,000 instructions a second reaches a billion in
about 40 minutes), then on the board.

**What Mac OS asks of the disk (dingusppc's 7300 with the 7.6.1 image on
MESH, 2026-10-07).** `machref --set hdd_img2=...` boots it to the happy Mac.
The ROM's boot code (FFEB....) selects without ATN and reads with READ(6) by
programmed I/O, 16 bytes at a time through the FIFO (polling the FIFO count
and the interrupt register): blocks 0, 1, 1, 2, 3, then the 19 blocks of
the disk's Apple_Driver43 at block 64, one READ(6). The driver it loads
selects with ATN, sends IDENTIFY (a one-byte MESSAGE OUT), and reads with
READ(10): the first bytes and the last by programmed I/O, the middle by DMA
(sequence 86 with MESH's count, then DBDMA channel A started with a
descriptor longer than the count; after MESH's command done it flushes the
channel and clears RUN). After every command phase the driver issues bus
free (09), which ends in a phase mismatch as soon as the target asks for
its data. After MESSAGE IN (count 1), ACK stays up until the bus free. No
INQUIRY, TEST UNIT READY, MODE SENSE or READ CAPACITY in the boot. At 464
million instructions Mac OS writes the volume's master directory block
(WRITE(10) of block 98 by DMA, sequence 85): dingusppc's MESH has no DMA
out, and its Mac OS waits there for ever; the frame at 590 million is the
happy Mac. So for writes the model is the real MESH, as Linux's `mesh.c`
drives it, not dingusppc.

**Built, 2026-10-07.** `PPCMac_dbdma.sv` (a DBDMA channel; channel A, MESH's,
in `PPCMac_gc`), MESH's information phases, FIFO and DMA in
`PPCMac_mesh.sv`, the disks in `PPCMac_scsidisk.sv` (IDs 0 and 1, hps_io's
slots 0 and 1), the DMA port in `PPCMac_machine` (through the CPU's snoop
port, sharing the memory port with the CPU); the core's top gives hps_io six
block devices (the Mac SCSI family's layout) and `SC0`/`SC1` entries in the
OSD. What each does and leaves out: their headers and `PPCMac_stubs.md`. The
machine bench serves disk images as hps_io would (`--disk0 FILE`, blocks
written kept in memory) and copies DMA writes into the reference's RAM. On
the board the stock Main mounts an image remembered in `config/PPCMac.s0`
(`python syn\mister.py mount 0 games/PPCMac/os761.hda`).

**The bus error at "Welcome to Mac OS" (2026-10-07, the targeted
session).** On the board and in the lockstep simulation alike, Mac OS 7.6.1
booted from its image to the welcome screen and bombed with "bus error"
about 30 s in. Found with an exception log added to the machine bench
(`--exc-log`: every exception's vector, SRR0, SRR1, DAR and DSISR, and
every `rfi`), register and RAM dumps at a given instruction
(`--dump-at`, `--dump-mem`, `--dump-bin`), and MacsBug 6.6.3 put into a
copy of the image with rb-cli (the two agree to the byte): at 497.8
million instructions the 68k emulator takes a DSI at 084BF6D6 from
`CMPM.W (A2)+,(A0)+` in System code loaded at 000FAFA4 (the board: 00110C64),
a few instructions after `MOVEA.L SonyVars,A1` and `MOVEA.L -4(A1),A2`.
SonyVars (low memory 0134) was FFFFFFFF, the ROM's value for "no floppy
driver": the ROM's .Sony driver probes the SWIM3 at 313 million
instructions (interrupt mask <- 0, mode set 01, mode clear 18, phase <- 5,
phase read back) and installs only if the phase lines read back; the stub
read 0. The 7.6.1 System's loading code assumes the driver is there,
takes the long before the Sony variables from the top of the ROM and
dereferences it. The fix is the chip: `PPCMac_swim3.sv`, dingusppc's
`swim3.cpp` register for register with an empty Superdrive
(`superdrive.cpp`), on Grand Central's interrupt source 13, with a
microsecond tick from `PPCMac_machine` for its timer and its steps. Found
on the way and recorded in `PPCMac_stubs.md`: the image runs with Virtual
Memory on (a 65 MB "VM Storage" file, logical memory 0x04100000), so the
NanoKernel's page faults from 466.66 million on are the VM's, handled by the
68k VM code without disk I/O; the lockstep's only difference up to the bus
error is the PTEs' R bit, which the core sets and dingusppc does not (now
an accommodation of the bench); MacsBug's own keyboard polling doubles and
drops keys typed through the Remote (an ADB keyboard detail, open). The
other images on the board before the fix: Mac OS 7.5.3 stops at "Starting
up..." with its progress bar at the start, 8.6 and 9.1 on the grey screen
before any welcome screen. With the SWIM3 built (the board, 2026-10-07,
28,437 ALMs), 7.6.1 passes the welcome screen and stops at that same
"Starting Up..." screen, the bar at its start for minutes, the pointer
following the mouse and the debug readout showing the 68k emulator running
with the device writes growing: Mac OS loops, waiting for something; the
next session's problem (`RESUME_disk.md`). The simulation reproduces it:
"Starting Up..." by 783 million instructions and, from 700 million on, the
CPU in native PowerPC code in RAM (user mode, 0019A5F4-0019A664), with
timer interrupts and kernel calls only.

**"Starting Up..." (2026-10-08, the stubs session).** Two causes, one under
the other. First, the native code was Mac OS 7.6.1's Control video driver
(r17 'ndrv') probing for a DDC monitor: it bit-bangs I2C on the monitor
sense lines (line 1 the clock, line 2 the data; addresses A0 and A1, the
EDID EEPROM's), and between up to four tries waits up to 1.7 s for the data
line to change (002164C8, 002163C8; the time from `UpTime`, the 64-bit
arithmetic at 0019A504 its conversions). Our MON_SENSE, dingusppc's, answered
any drive pattern but the three extended-sense ones with the standard code,
so a line the driver drove low read back high; the sense lines are now
wires (`PPCMac_control`), found with a device log from 705 million (17,537
reads of MON_SENSE), the trace and RAM dump at 750 million, and the driver
disassembled from the dump (`llvm-objdump` in WSL). Second, with that fixed
the board still stopped at "Starting Up...", the CPU in the 68k emulator:
Cuda's NMI, wired this session (Command-Menu), put MacsBug 6.6.3 at a 68k
loop (`TST.B $03A6(A2)` / `BNE.S`, 002F272C, a System heap block) whose
stack crawl runs from OpenAppleTalkServices through OTCreateATalkConfigurator,
the stream modules and TDLPIModule::ProcessUpperMessage into the fragment
OTLib$ATMM and the classic AppleTalk 68k link code: Open Transport bringing
up AppleTalk (the image's AppleTalk Preferences: 'neta' "OTOn", the default
port, the printer port's LocalTalk on the ESCC's channel B). With Shift
held through the start-up (extensions off: no Open Transport) Mac OS 7.6.1
reaches the Finder on the board (build of 2026-10-08, 31,825 ALMs):
"About This Computer" shows System Software 7.6.1 and 16,384K, the pointer
follows the mouse. The LocalTalk link waited for the line to be free: in
SDLC mode the Z85C30's sync/hunt bit reads 1 while the receiver hunts for
a flag, ours read 0 (a frame on the line); dingusppc found the same
(commit ad9a9dbf). With the ESCC's synchronous mode (sync/hunt, the
transmitter's CRC and EOM at underrun, the external/status interrupt,
Grand Central's LocalTalk registers; `PPCMac_escc.sv`) Mac OS 7.6.1 boots
to the Finder with all its extensions on the board (build 5 of
2026-10-08, 31,680 ALMs, the untouched image `os761ot.hda`): milestone S's
proof. Shut Down works from the keyboard's power key (the Menu key) and
its dialog. The user, separately, reached the Finder with Open Transport's
extensions moved out (`os761mb.hda`). Build 6 (32,301 ALMs) resets the
board's devices with every CPU reset Cuda makes, as a real restart does:
Restart from the power key's dialog blanks the screen and boots Mac OS
back to the Finder on the board.

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

**Built, 2026-10-08.** Cuda's clock is set from hps_io's TIMESTAMP when Cuda
first releases the CPU (RAM AB-AE, as MAME); Mac OS's menu bar shows the
time. Grand Central's NVRAM is kept in an 8 KB image on hps_io's block slot
2 (`PPCMac_nvsave.sv`, the OSD's "Mount NVRAM"; `syn\mister.py make-nvr`):
loaded when it mounts, the machine held in reset meanwhile, saved 2 s after
the CPU's last write or when the OSD opens. On the board the image filled
with Mac OS's XPRAM ("NuMc" at 1300) and Open Firmware's partitions and
Forth patches after one boot, and the next boot came up from it. Cuda's
own PRAM is not kept: on this machine Mac OS's XPRAM lives in the NVRAM.
Open: with the untouched image Mac OS showed the time an hour behind (5:33
against 6:33), with the user's copy of it right: the image's
daylight-saving setting (Date & Time) or the TIMESTAMP's time zone, to be
looked at.

### X: the PCI bus (later)

What it needs: Bandit 1's three slots (devices 0D-0F, interrupts 17-19)
with configuration space for the card, and the decoder following the BARs
Open Firmware assigns (today it ignores them, `PPCMac_stubs.md`; V needs
the same for Control's BARs on Chaos), a card's expansion ROM (its FCode
driver, which Open Firmware runs), and any bus master on the card going
through rule 2's DMA port. The first card: a video card, which dingusppc
models (`atimach64gx.cpp`: ATI Mach64 GX; `atirage.cpp`: Rage GT, GW, Pro),
with the card's own ROM dump supplied.

Proof: Open Firmware listing the card in its device tree and Mac OS
driving it.

## Not planned

- A network for Ethernet. MACE is modelled with its cable unplugged
  (2026-10-08, `PPCMac_mace.sv`: registers, transmit through DMA channel 2
  ending in loss of carrier, nothing received). A network would reuse the
  Quadra 800 core's path: Main's `support/mac/mac_eth.cpp` bridge and a DDR3
  mailbox like `sonic_mbx.sv`'s, with a MACE personality that only carries
  frames (the Quadra's SONIC model runs on the ARM; MACE's registers and
  Grand Central's DMA are already in the FPGA). The DDR3 window must stay
  clear of the VRAM.
- Floppy disks: the SWIM3 is modelled with an empty drive (2026-10-07,
  because Mac OS 7.6.1's System crashes while loading if the ROM's .Sony
  driver has not installed); floppy images are not planned.
- The ESCC's channel B (the printer port), the second CPU, the L2 cache.

## Backlog: what the Quadra 800 core has (surveyed 2026-10-08, at the user's request)

From `..\MacQuadra800_MiSTer` (MiSTer-devel's, branch `main`, 58a05e2: its
OSD menu in `MacQuadra800.sv`, its README and area table), each with what it
would be here. The user's order (2026-10-08): this parity first, starting
with the mouse and the joystick ("we need to fix the mouse joystick"), then
Mac OS 8.6's grey screen, then 9.1's. The Quadra repository is read only
for this work (it is in build mode: no edits, commits, pushes or fetches).

| Quadra 800 core | Here |
|---|---|
| SCSI disks 0 and 1 (SC0, SC1) | done (milestone S) |
| PRAM image on slot 2 (SC2, .NVR), loaded before the machine leaves reset, saved 2 s after the last change or when the OSD opens | done the same way for Grand Central's 8 KB NVRAM (2026-10-08, `PPCMac_nvsave`) |
| CD-ROM on slot 4 (ISO, TOAST; CUE, BIN, CHD through Main's `support/mac/mac_cdrom`), AppleCD target with TOC and CD audio (`cd_audio.sv`, about 3,000 ALMs) | an AppleCD target on MESH at ID 3 (the 7300's internal CD), its audio into AWACS's mix |
| BlueSCSI Toolbox (slot 3) and the CD changer (slot 5), Main fork | the same slots; the Toolbox's vendor commands in `PPCMac_scsidisk` |
| Ethernet (OSD on/off, net interface eth0, eth1, wlan0, tap0) through Main's `mac_eth` bridge and a DDR3 mailbox (`sonic_mbx.sv`) | MACE (cable unplugged today) given a MACE personality in Main: frames only, the registers and DMA stay in the FPGA |
| ADB game controllers from the MiSTer's joysticks: Gravis GamePad, Gravis MouseStick II, Gravis Firebird, SideWinder 3D Pro; "stick moves pointer" | more devices in `PPCMac_adb` (the same ADB protocols) |
| MT32-pi on the user port: MIDI out of the SCC's channel A, its OSD page (Munt or FluidSynth, MT-32 v1, v2, CM-32L ROM, SoundFont 0-7, info popups) | the ESCC's modem port at 31,250 bit/s to the user port, the same OSD page and MT32-pi module |
| Serial MIDI through the HPS (CONF_STR `UART57600:115200,MIDI`: MidiLink) | the modem port's UART option gaining the MIDI mode |
| Printer and the disk write buffer (Main branch `mac-printer-writebuffer`) | the write buffer already serves slots 0 and 1; a printer on the printer port (the ESCC's channel B) through Main |
| ALSA audio through the HPS, composite and Y/C video (`yc_out`) | the framework's, to switch on |
| Aspect ratio and Scale (Normal, V-Integer, HV-Integer) through `video_freak` | done (2026-10-08) |
| A second, smaller monitor choice (12-inch 512 x 384) | the 13- and 16-inch today; the 21-inch later |
| Speedometer against a real machine | Speedometer on the 7300 and the core |

## Decisions needed

| When | Question |
|---|---|
| ~~now~~ | ~~The order of the milestones after I.~~ Decided 2026-10-07: the order above, the serial console first, as soon as possible, for running validation tests from Open Firmware over the modem port. |
| ~~V~~ | ~~VRAM in the HPS's DDR3 or in the SDRAM?~~ Decided 2026-10-07: the DDR3, all 4 MB, block RAM for the line buffer and the colour table only. |
| X | Added 2026-10-07: the PCI bus and a card in a slot, for later. Which card first? |
| from E on | Decided 2026-10-07: the sessions from milestone E on work independently (`RESUME_scsi.md`): they decide what the documents leave open, record each decision in this table with its reason, and go on through the milestones in order. The CPU rule stands: a CPU change stops the session with a hand-off prompt. |
| ~~V~~ | ~~Which monitor the sense lines report (640 x 480 first, larger later?).~~ Answered 2026-10-07 (start of E): match the machine's default resolution (the user remembers it as "872 by something": to be found from Control's sense code and dingusppc's default monitor), with a forced 640 x 480 as an option; HDMI through the framework's scaler first, the analog output (a PC CRT) considered in the design (the MiSTer's `vga_scaler` puts the scaler's output on VGA). |
| ~~S~~ | ~~Which disk image format and Mac OS version to test with first.~~ Answered 2026-10-07: the session picks from the user's images (`\\daninas.local\Software\BlueSCSI Images\PowerPC Images`: zipped 512-byte-sector `.hda` images of Mac OS 7.5.3, 7.6.1, 8.5, 8.6 and 9.1 installed), copied in; a hard disk first, a CD-ROM target later. Later also Linux, which starts Mac OS and then BootX: the Debian 7 image there (`HD00_512 LINUX 8500MB.hda.zip`). |
| V | Decided by the session, 2026-10-07, from the user's answer: the monitor the sense lines report is an OSD choice, Apple's 16-inch RGB (sense 7, extended 2D: 832 x 624 at 75 Hz, 57.2832 MHz) by default, the 13-inch RGB (sense 6, extended 2B: 640 x 480 at 66.7 Hz, 30.24 MHz) as the forced 640 x 480; the 21-inch (1152 x 870, 100 MHz) later if the DDR3's bandwidth allows. Reason: the user remembers the default as "872 by something, kind of weird"; 832 x 624 is the odd Apple mode that fits, the 870-line modes the other candidates. dingusppc's default "AppleVision1710" is only an alias of its 13-inch code (`displayid.cpp`), which is why its Mac OS picks 640 x 480 (130.9 million instructions, 32 bits a pixel). The VRAM sits at the DDR3's byte 0x30000000 (the core's region, as the Quadra 800 core's), the scan-out in the 100 MHz memory clock, which is also the framework's video clock: every mode's pixel rate (30.24, 57.28, 100 MHz) is a clock enable of it. |
| E | Decided by the session, 2026-10-07: MESH's selection timeout follows its register in 10 ms units (the ROM computes ms / 10; dingusppc ignores the register and waits 250 ms, the ROM's value); Curio's follows the 53C94's formula with the chip's clock taken to be 25 MHz (MAME's way; dingusppc waits 250 ms); MESH's interrupt line follows its registers at all times, as a pin does (dingusppc recomputes it only at some events); Curio's initiator commands with no connected target are an invalid-command interrupt, as on the chip (dingusppc stops). Reason: real behaviour over an emulator's shortcut where the shortcut is visible, each to be checked by `hwprobe/` on the real 7300. |
| from E on | Answered 2026-10-07: the user can still run probe disks on the real 7300 (booted from Open Firmware over the modem port, as `cudadump`); where only the real machine can say (MESH's and Curio's selection timeout, the VIA's access time), the session builds such a disk and follows the emulators meanwhile, the guess written in the stubs list. |
| from K on | Asked by the user, 2026-10-07: Verilator as little as possible (the whole machine simulates at 0.6 MHz, 0.9% of real time); features are proven on the board, with unit benches where they take seconds (`run_cuda.py`) and whole-machine runs only to explain something the board shows. The board is driven through the MiSTer Remote (mrext, port 8182), as the user's other cores are (`tools\misterdeploy`): `syn\mister.py load`, `shot`, `keys`, `mouse`, `click`; SSH only copies files and reads the UART. |
| S | Decided by the session, 2026-10-07: DMA reaches memory through one DMA port in `PPCMac_machine`: each access's line through the CPU's snoop port, then the memory port, which the DMA takes before any new CPU access; a write's line is snooped again after it, to drop a copy fetched in between (holding the CPU's reads during the snoop deadlocked the board: a cache can need a fill to finish before it answers a snoop). DBDMA gathers data in into lines (a whole line written as a line, else the words with bytes, with byte enables). MESH's bus is modelled at the signal level with the targets as their own module (`PPCMac_scsidisk`), so programmed I/O, DMA and the bus-status registers see the same lines; the information phases as Linux's `mesh.c` uses them where dingusppc has no model (DMA out), a DMA data in's command done only once the FIFO and the channel have emptied (Mac OS's driver does not wait for the FIFO; Linux waits up to 50 us). The disks answer INQUIRY as "QUANTUM " (dingusppc's vendor) "MiSTer PPCMac HD", no synchronous transfers, an extended message answered with MESSAGE REJECT; a new phase's first REQ 10 us after the phase lines change, as a disk is slow to change phase (the ROM's SIM waits after the status byte for REQ to drop, FFEB8D98, and hung on the board while the disk asked at once); one block per hps_io request (`sd_blk_cnt` 0), two buffered each way; hps_io `WIDE` 0 (the ROM upload is byte-wide), `VDNUM` 6 (the Mac SCSI family's slots), `SC0`/`SC1` so the Main remembers the images; the images kept in registers the machine's reset does not touch, so no mount replay is needed. Reason: rule 2 (one way into memory, coherent); the real chip over an emulator's shortcut where the shortcut is visible (dingusppc's Mac OS cannot write its disk); the stock Main's block interface works on the board as it is. |
| S | Decided by the session, 2026-10-07 (the bus error at "Welcome to Mac OS"): the SWIM3 floppy controller is built as a device (`PPCMac_swim3.sv`), dingusppc's `swim3.cpp` register for register with one internal Superdrive that has no disk (its status lines as `superdrive.cpp` answers an empty drive), on Grand Central's interrupt source 13, with a 1 MHz tick from `PPCMac_machine` for the chip's timer and its 80 us steps; no disk is ever read. Reason: the ROM's .Sony driver installs only if the chip answers its probe, and Mac OS 7.6.1's System dereferences the driver's variables (SonyVars, low memory 0134, -1 without the driver) while loading: the bus error. A chip that answers but holds no disk is what a 7300 with an empty drive is. Also decided: the lockstep bench takes the core's R and C bits in a word loaded from the page table (dingusppc's MMU sets them differently), and MacsBug 6.6.3 (put into a copy of the image with rb-cli: `Scratch\disks\os761mb.hda`, on the card as `games/PPCMac/os761mb.hda`) is the board-side debugger from now on; its keyboard reading doubles keys typed through the Remote, noted in the stubs list under ADB. |
| S | Decided by the session, 2026-10-08, at the user's request ("fill in all the stubbed areas now that we are actually trying to boot Mac OS"): the devices Mac OS's start-up meets are built as the chips behave, not as register stubs. AWACS (`PPCMac_awacs.sv`) plays DMA channel 8's frames at the control register's rate to the MiSTer's audio and feeds channel 9 silence, the registers as dingusppc's; the rate code read as dingusppc and Linux read it (Screamer's table: the ROM's chime at 22,050 Hz; MAME's AWACS would play it at 44,100), to be checked by ear against a real 7300; the frame count counts (dingusppc's does not). DMA channels 2, 3, 8 and 9 are `PPCMac_dbdma` engines beside MESH's, through one arbiter in Grand Central (sound first). MACE (`PPCMac_mace.sv`) has its cable unplugged (the user's choice): dingusppc's registers, and every frame sent ends in loss of carrier with its transmit interrupt, as an Am79C940 reports in the link fail state (dingusppc's MACE cannot transmit at all). The ESCC gets the Z85C30's interrupts on a bus without acknowledge cycles (RR3, RR2's status in channel B, WR0's resets, WR9's master enable), one line a channel (0F, 10). Cuda's NMI (PC2) is Grand Central's source 14, and the PC keyboard's Menu key is ADB's power key, so Command-Menu enters MacsBug and Control-Command-Menu restarts (Cuda's firmware decides both). Cuda's clock is set from the MiSTer's RTC (hps_io's TIMESTAMP + 2,082,844,800) when Cuda first releases the CPU, as MAME does (RAM AB-AE). Reason: Mac OS's drivers wait on these chips' interrupts and status, and a stub that never answers looks like a hang; dingusppc where it models the chip, the chips' manuals and MAME where it does not. |
| S, P | Decided by the session, 2026-10-08 (later the same day): the monitor sense lines are modelled as wires (a driven-low line reads low, the AppleSense codes give the monitor's grounds and straps), against dingusppc's table, because Mac OS 7.6.1's Control driver bit-bangs a DDC probe on them and must read its own lines back; the ESCC gets the synchronous mode as far as LocalTalk with an empty printer port needs (sync/hunt 1, the transmitter's CRC and EOM at underrun, the external/status interrupt, Grand Central's LocalTalk registers as dingusppc's), which let Open Transport's AppleTalk start; the keyboard answers one key event a Talk and re-reports held modifiers after a reset (MacsBug's polling, Shift through the start-up); the NVRAM is kept on hps_io's slot 2 as the Quadra 800 core keeps its PRAM (load on mount with the machine held in reset, save 2 s after the last write or when the OSD opens); the Scale option (`video_freak`) as the other Mac cores have it. Reason: each was what Mac OS or the user needed, found on the board or in the trace; the Quadra 800 core's solutions where it has one. |
| K | Decided by the session, 2026-10-07: the ADB devices (`PPCMac_adb.sv`) at the wire level, the Mac LC core's structure and PS/2 table with dingusppc's registers: keyboard handler 2 (1 and 2 settable, 3 refused, so the right-hand modifiers give the left-hand codes), mouse handler 1 (1 and 2; not the extended protocol 4, which dingusppc's mouse takes: the Apple Mouse II has none), SRQ enabled from reset, a true service request (the stop bit held low to 300 us); Alt is Command, the Windows keys Option, Caps Lock locks. The line's timing is ADB's own, counted in Cuda's 4,194,304 Hz ticks so it keeps step when the bench runs Cuda fast; the answer 160 us after the stop bit. Reason: Cuda's own firmware is the judge, and its receive (1CF3-1D88) waits 283 us for the start bit and 79 us at most for any low. On the way, Cuda's PA6 turned out to be the line's level, not its inverse (corrected in `PPCMac_cuda.sv`; MAME agrees once its devices' ASSERT is read as high); with it inverted, every ADB command reported a service request and no device could answer. |
