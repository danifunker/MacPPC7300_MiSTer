# MacPPC7300: plan for the machine

The CPU's plan ([DSPPC604_plan.md](DSPPC604_plan.md)) took `DSPPC604` from
nothing to running the 7600's ROM on the board. This plan takes the machine
around it, the Power Macintosh 7300/7600 (dingusppc's TNT), from Cuda to Mac
OS booting from a disk image with a picture, a keyboard, a mouse and sound,
and keeps the way open for the Pippin and the Performa 6200. The decisions
it rests on are in the [README](../README.md); everything the machine stubs
or leaves out is in [MacPPC7300_stubs.md](MacPPC7300_stubs.md).

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
| A | Sound: AWACS and its DBDMA channels | the startup chime, and Mac OS's sound | done 2026-10-10: the chime bit-exact in simulation (2026-10-08); on the board, heard right by the user once the codec's rate code 2 was 44,100 Hz (build 52; the record in `MacPPC7300_sound.md`) |
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
| 225.7 million | SWIM3, the floppy controller: the .Sony driver's probe (the phase lines written and read back) | the chip with an empty drive (`MacPPC7300_swim3`): the driver must install, or the 7.6.1 System crashes while loading (S) |
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

1. **One device port.** A device is a module with the port `MacPPC7300_gc` and
   `MacPPC7300_pcicfg` have: `sel` for one cycle, `we`, the word address, byte
   enables and write data, the read data in the next cycle. `MacPPC7300_machine`
   decodes the map and presents the access; a line is eight word accesses.
   A device that needs time gets it from one mechanism in `MacPPC7300_machine`
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
   machine. `MacPPC7300_machine` is the TNT (7300/7600). The Pippin (dingusppc:
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
7. **Stubs are written down.** `MacPPC7300_stubs.md` changes in the same commit
   as the stub; an entry leaves only when the real thing is built and
   tested.

## Milestones in detail

### C: Cuda

Built 2026-10-06 (`rtl/machine/MacPPC7300_cuda.sv`, `MacPPC7300_hc05.sv`; the README
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
device requests in `MacPPC7300_machine` would take off at a cycle per device
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

**The VIA, in simulation, 2026-10-07.** `MacPPC7300_gc.sv`: the lines as
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
cannot (`MacPPC7300_stubs.md`); and the real Cuda sends packets dingusppc's
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

**Built, in simulation, 2026-10-07.** `MacPPC7300_mesh.sv` and
`MacPPC7300_sc53c94.sv` (Curio's 53CF94 cell) inside `MacPPC7300_gc`, on Grand
Central's sources 0D and 0C, timed by a 25 MHz tick from the CPU's clock
(`SCSI_HZ` in `MacPPC7300_machine`). What each does and leaves out is in their
headers and in `MacPPC7300_stubs.md`. The selection timeouts follow the chips'
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
38,400 baud. `MacPPC7300_escc.sv` is the Z85C30's asynchronous mode for both
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

The pieces: `MacPPC7300_control.sv` (Control's registers, and `MacPPC7300_swatch`,
its timing in the video clock), `MacPPC7300_radacal.sv` (in Grand Central, IOBus
device 2; its colour table has a second copy read by the scan-out),
`MacPPC7300_athens.sv` (an I2C slave on Cuda's pins: our Cuda is the chip, so
the driver's packets reach Athens as bits), `MacPPC7300_video.sv` (the dot clock
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
with the address of the word that missed, and `MacPPC7300_video` started the
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
`MacPPC7300_cuda`). The Mac LC core's `adb_device.sv` (938 lines, wire level:
attention, sync, command, Tlt, talk replies, service requests; the MiSTer's
PS/2 keyboard and mouse as the source) was written for an Egret on the same
kind of line; its cell timing is in 32 MHz cycles and moves to the CPU's
clock by parameter. dingusppc models ADB at the packet level
(`adbbus.cpp`, `adbkeyboard.cpp`, `adbmouse.cpp`) and attaches a mouse and
a keyboard by default, so its Mac OS finds two ADB devices where ours finds
none until K (a difference to expect in the Cuda traffic); the wire level is
checked against Cuda's own firmware: `run_cuda.py`'s ADB talk gets an
answer from address 2 and 3, still in lockstep with MAME's 6805.

Done (2026-10-07). `MacPPC7300_adb.sv` puts both devices on the line, their
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
`..\Main_MiSTer_ppcmac`; not pushed, not upstream yet) adds `ppcmac` (`macppc7300` since the
rename of 2026-10-09, on the branch `Mac-ppc-enhancements`). So
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

**Built, 2026-10-07.** `MacPPC7300_dbdma.sv` (a DBDMA channel; channel A, MESH's,
in `MacPPC7300_gc`), MESH's information phases, FIFO and DMA in
`MacPPC7300_mesh.sv`, the disks in `MacPPC7300_scsidisk.sv` (IDs 0 and 1, hps_io's
slots 0 and 1), the DMA port in `MacPPC7300_machine` (through the CPU's snoop
port, sharing the memory port with the CPU); the core's top gives hps_io six
block devices (the Mac SCSI family's layout) and `SC0`/`SC1` entries in the
OSD. What each does and leaves out: their headers and `MacPPC7300_stubs.md`. The
machine bench serves disk images as hps_io would (`--disk0 FILE`, blocks
written kept in memory) and copies DMA writes into the reference's RAM. On
the board the stock Main mounts an image remembered in `config/MacPPC7300.s0`
(`python syn\mister.py mount 0 games/MacPPC7300/os761.hda`).

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
dereferences it. The fix is the chip: `MacPPC7300_swim3.sv`, dingusppc's
`swim3.cpp` register for register with an empty Superdrive
(`superdrive.cpp`), on Grand Central's interrupt source 13, with a
microsecond tick from `MacPPC7300_machine` for its timer and its steps. Found
on the way and recorded in `MacPPC7300_stubs.md`: the image runs with Virtual
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
wires (`MacPPC7300_control`), found with a device log from 705 million (17,537
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
Grand Central's LocalTalk registers; `MacPPC7300_escc.sv`) Mac OS 7.6.1 boots
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
2 (`MacPPC7300_nvsave.sv`, the OSD's "Mount NVRAM"; `syn\mister.py make-nvr`):
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
Open Firmware assigns (today it ignores them, `MacPPC7300_stubs.md`; V needs
the same for Control's BARs on Chaos), a card's expansion ROM (its FCode
driver, which Open Firmware runs), and any bus master on the card going
through rule 2's DMA port. The first card: a video card, which dingusppc
models (`atimach64gx.cpp`: ATI Mach64 GX; `atirage.cpp`: Rage GT, GW, Pro),
with the card's own ROM dump supplied.

Proof: Open Firmware listing the card in its device tree and Mac OS
driving it.

## Not planned

- A network for Ethernet. MACE is modelled with its cable unplugged
  (2026-10-08, `MacPPC7300_mace.sv`: registers, transmit through DMA channel 2
  ending in loss of carrier, nothing received). A network would reuse the
  Quadra 800 core's path: Main's `support/mac/mac_eth.cpp` bridge and a DDR3
  mailbox like `sonic_mbx.sv`'s, with a MACE personality that only carries
  frames (the Quadra's SONIC model runs on the ARM; MACE's registers and
  Grand Central's DMA are already in the FPGA). The DDR3 window must stay
  clear of the VRAM.
- Floppy disks: the SWIM3 was modelled with an empty drive (2026-10-07,
  because Mac OS 7.6.1's System crashes while loading if the ROM's .Sony
  driver has not installed); images are read since 2026-10-08 (the user
  asked; the decisions table), writing is left out.
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
| PRAM image on slot 2 (SC2, .NVR), loaded before the machine leaves reset, saved 2 s after the last change or when the OSD opens | done the same way for Grand Central's 8 KB NVRAM (2026-10-08, `MacPPC7300_nvsave`) |
| CD-ROM on slot 4 (ISO, TOAST; CUE, BIN, CHD through Main's `support/mac/mac_cdrom`), AppleCD target with TOC and CD audio (`cd_audio.sv`, about 3,000 ALMs) | built 2026-10-08 (build 8): the Quadra's target behaviour at ID 3 on MESH (`MacPPC7300_scsidisk`), the Main's optimized contract (macppc7300 added on the Main branch `Mac-ppc-enhancements`, aad7960), its audio (`MacPPC7300_cdaudio`) mixed after AWACS; `run_scsi.py` passes; works on the board with the branch's Main (2026-10-08: an ISO, a CUE/BIN with audio played by the AppleCD Audio Player) |
| BlueSCSI Toolbox (slot 3) and the CD changer (slot 5), Main fork | built 2026-10-08 (build 8): the Mac LC core's transport (the Quadra has none), file sharing on ID 0, the changer on ID 3; `run_scsi.py` passes; on the board file sharing downloads and uploads (BlueSCSI SD Transfer 1.1.0b5); the changer app finds no changer: parked (the user) |
| Ethernet (OSD on/off, net interface eth0, eth1, wlan0, tap0) through Main's `mac_eth` bridge and a DDR3 mailbox (`sonic_mbx.sv`) | written 2026-10-08 (build 10): frames only, MACE's registers and DMA in the FPGA, two rings in DDR3 (`MacPPC7300_enet`, `MacPPC7300_ddrarb`), the Main's side on the branch (7b3a601); works on the board since build 17 (2026-10-08): DHCP, a web page in Cyberdog, ping, FTP with Fetch, after MACE's loopback, the FCS and the DMA status bits (the decisions table) |
| ADB game controllers from the MiSTer's joysticks: Gravis GamePad, Gravis MouseStick II, Gravis Firebird, SideWinder 3D Pro; "stick moves pointer" | built 2026-10-08 (build 7) in `MacPPC7300_adb`; on the board the keyboard and mouse work beside a GamePad and a MouseStick; the controllers themselves wait for the user's gamepad |
| MT32-pi on the user port: MIDI out of the SCC's channel A, its OSD page (Munt or FluidSynth, MT-32 v1, v2, CM-32L ROM, SoundFont 0-7, info popups) | built 2026-10-08 (build 8): the modem port's transmit to the Pi, the OSD page, the info popups, the LCD overlay, the Pi's audio in the mix; waits for the user's MT32-pi |
| Serial MIDI through the HPS (CONF_STR `UART57600:115200,MIDI`: MidiLink) | built 2026-10-08 (build 8): `UART115200:57600:38400:19200:9600,MIDI`, the TRxC clock as a MIDI interface's; waits for the Discord testers (in and out) |
| PPP through the HPS (the UART's PPP mode) | built 2026-10-08 (build 8): the modem port's rates to 115,200, CTS and RTS; waits for a tester |
| Printer and the disk write buffer (Main branch `mac-printer-writebuffer`) | the write buffer serves slots 0 and 1 once macppc7300 is in the Mac family (the branch above); the modem port's CTS and RTS as the Quadra's (build 8), so the ImageWriter on the modem port through the Main's printer daemon |
| ALSA audio through the HPS, composite and Y/C video (`yc_out`) | on already (the framework's defaults: `MISTER_DISABLE_ALSA` and `MISTER_DISABLE_YC` not set in `MacPPC7300.qsf`) |
| Aspect ratio and Scale (Normal, V-Integer, HV-Integer) through `video_freak` | done (2026-10-08) |
| A second, smaller monitor choice (12-inch 512 x 384) | done 2026-10-08 (build 9; the Monitor option moved to O[16:15]): Apple's 12-inch RGB (sense 2, extended 21, 512 x 384 at 60.15 Hz, dingusppc's `displayid.cpp`); on the board Mac OS 7.6.1 comes up at 512 x 384; the 21-inch later |
| Speedometer against a real machine | Speedometer on the 7300 and the core: the Speed section below (2026-10-08) |

## Speed (2026-10-08, the speed session: `RESUME_speed.md`)

The measure is Speedometer 4.02 on the board, always under the same
conditions: `os761ot.hda` on SCSI disk 0 (Mac OS 7.6.1 with Open Transport,
as the image is: 256 colours, virtual memory on), RAM 120 MB, the 16-inch
monitor (832 x 624), Ethernet eth0, no floppy, nothing else mounted; the
Performance Rating and the CPU, Graphics, Disk and Math scores, and the
benchmark list, read off screenshots. The time from the core's load to the
Finder (the desktop drawn) is the cheap second measure. Quartus's figures
are the slow 100 C model's for the CPU clock (`general[1]`).

| Build | CPU MHz | L2 | Slack, fmax | ALMs, RAM blocks | Load to Finder | Speedometer |
|---|---|---|---|---|---|---|
| 28 (the third release) | 65 | none | -1.462 ns, 59.4 MHz | 35,642 (85 %), 195 | 101-109 s (the picture at 34 s, "Starting Up..." at 41-49 s, the menu bar at 101 s, the desktop at 109 s) | CPU 2.281, Graphics skipped, Disk 1.386, Math 95.006. Benchmark Mix: KWhetstones/s 13,746.649 (46.743), Dhrystones/s 43,211.925 (2.501), Towers 0.212 s (3.013), Quick Sort 0.167 (4.269), Bubble Sort 0.302 (2.518), Queens 0.158 (2.557), Puzzle 0.292 (3.745), Permutations 0.265 (3.068), Int. Matrix 0.186 (4.340), Sieve 0.497 (2.760), average 7.551. Color: 8-bit 8.556 s (1.238), 16-bit 11.906 s (1.140), average 1.189. FPU: KWhetstones/s 14,864.804 (2.854), Matrix Mult. 0.193 s (3.661), Fast Fourier 0.101 s (2.842), average 3.119 |
| 29 (the device register stage) | 65 | none | -1.092 ns, 60.7 MHz | 36,743 (88 %), 195 | 97-112 s | CPU 2.279, Graphics skipped (below), Disk 1.408, Math 95.027, PR not given. Benchmark Mix (Quadra 605 = 1): KWhetstones/s 16,150.653 (54.918), Dhrystones/s 43,151.547 (2.498), Towers 0.212 s (3.009), Quick Sort 0.167 (4.271), Bubble Sort 0.301 (2.522), Queens 0.158 (2.559), Puzzle 0.292 (3.741), Permutations 0.265 (3.067), Int. Matrix 0.186 (4.340), Sieve 0.497 (2.761), average 8.369. Color: 8-bit 9.260 s (1.144), 16-bit 11.992 s (1.132), average 1.138. FPU (Quadra 650 = 1): KWhetstones/s 16,181.753 (3.107), Matrix Mult. 0.193 s (3.665), Fast Fourier 0.101 s (2.839), average 3.204 |

| 30 (+ the 128 KB L2) | 65 | 128 KB | -2.013 ns, 57.5 MHz (the cache-answer family of build 29, -0.32 ns there, placed 1.7 ns worse at 90 %) | 37,883 (90 %), 329 | | CPU 2.321, Graphics skipped, Disk 1.544, Math 96.758. Benchmark Mix: KWhetstones/s 14,186.409 (48.238), Dhrystones/s 43,919.132 (2.542), Towers 0.209 s (3.065), Quick Sort 0.162 (4.389), Bubble Sort 0.296 (2.566), Queens 0.155 (2.603), Puzzle 0.287 (3.813), Permutations 0.261 (3.122), Int. Matrix 0.181 (4.451), Sieve 0.487 (2.821), average 7.761. Color: 8-bit 7.717 s (1.373), 16-bit 11.146 s (1.218), average 1.295. FPU: KWhetstones/s 15,187.412 (2.916), Matrix Mult. 0.187 s (3.774), Fast Fourier 0.099 s (2.907), average 3.199. Against build 28: the CPU tests 2-3 % faster (they live in the L1), the disk 11 %, the colour tests 6-10 % |

| 31 (+ the cache's delayed write) | 65 | 128 KB | -0.321 ns, 64.0 MHz (TNS -1.9 ns: the I-cache's unused write-back address into the machine, the D-cache's answer, the MMU's read-ahead, each a few tenths) | 37,765 (90 %), 329 | the menu bar at 86 s (97-101 s in builds 28 and 29: the L2) | CPU 2.317, Graphics skipped, Disk 1.533, Math 96.623. Benchmark Mix: KWhetstones/s 13,839.872 (47.060), Dhrystones/s 42,649.233 (2.469), Towers 0.226 s (2.822), Quick Sort 0.166 (4.295), Bubble Sort 0.297 (2.563), Queens 0.159 (2.538), Puzzle 0.287 (3.808), Permutations 0.287 (2.831), Int. Matrix 0.182 (4.435), Sieve 0.487 (2.819), average 7.564. Color: 8-bit 7.931 s (1.336), 16-bit 11.428 s (1.188), average 1.262. FPU: KWhetstones/s 14,564.732 (2.797), Matrix Mult. 0.188 s (3.753), Fast Fourier 0.100 s (2.870), average 3.140. Against build 30: the same within noise but Towers and Permutations, 8-10 % slower: their recursion stores and then asks again in the next cycle, which the delayed write makes wait a cycle (refined in the next build: only a request to the pending write's own set waits) |

| 32 (build 31's tree at 70 MHz) | 70 | 128 KB | -1.766 ns, 62.2 MHz (TNS -558 ns: at 14.29 ns a cycle the RAM-sourced families all fail by 1-1.8 ns) | 38,841 (93 %), 329 | the menu bar at 86 s | CPU 2.501, Graphics skipped, Disk 1.517, Math 104.328. Benchmark Mix: KWhetstones/s 14,815.253 (50.377), Dhrystones/s 46,163.661 (2.672), Towers 0.209 s (3.052), Quick Sort 0.154 (4.638), Bubble Sort 0.275 (2.768), Queens 0.147 (2.740), Puzzle 0.266 (4.113), Permutations 0.266 (3.057), Int. Matrix 0.168 (4.791), Sieve 0.451 (3.046), average 8.125. Color: 8-bit 7.462 s (1.420), 16-bit 10.818 s (1.255), average 1.337. FPU: KWhetstones/s 15,962.201 (3.065), Matrix Mult. 0.174 s (4.057), Fast Fourier 0.093 s (3.098), average 3.407. Against build 31: everything 8 % faster, the clock's ratio; the Mac's clock right (the VIA's and Cuda's pacing follow CPU_HZ); the boot the same (I/O bound) |

| 33 (the cache's gate refined to the pending write's set; a read-only cache off the write-back muxes) | 65 | 128 KB | -0.494 ns, 63.0 MHz (TNS -2.2 ns) | 37,629 (90 %), 329 | the menu bar at 90 s | **Broken on the board**: Mac OS 7.6.1 bombs in the Finder ("error type 10") minutes after booting, Mac OS 9.1 sits at the ROM's grey screen; every simulation gate passed (lint, the suite, `run.py`, the 300 M lockstep). Bisected with builds 33a (the gate alone) and 33b (the guards alone) |
| 34 (build 33's tree at 70 MHz) | 70 | 128 KB | -1.967 ns (TNS -543 ns) | 38,055 (91 %), 329 | | not run: build 33's bug |
| 33a (build 31 + the refined gate alone, 65 MHz) and 33b (build 31 + the read-only guards alone, 65 MHz) | 65 | 128 KB | 33a -2.371 ns (a poor fit), 33b -0.822 ns | | 33b: the menu bar at 86 s | the bisection of build 33's bug (found by reading before the builds finished: the gate's take fell through a clashing snoop to an ungranted request). 33b: a clean run with build 31's numbers to the digit (CPU 2.319, Disk 1.531, Math 96.633, Towers 0.226, Permutations 0.287, FPU 3.156) |
| 36 (the gate fixed, the guards, the FPU: operand register off, fmul a cycle shorter; 70 MHz; the fourth release) | 70 | 128 KB | -2.556 ns (TNS -833 ns: the forwarding into the FPU's first stage is back, as the operand register was there for) | 38,452 (92 %), 329 | the menu bar at 86 s | CPU 2.504, Graphics skipped, Disk 1.556, Math 106.764. Benchmark Mix: KWhetstones/s 15,717.092 (53.443), Dhrystones/s 46,559.139 (2.695), Towers 0.204 s (3.131), Quick Sort 0.153 (4.663), Bubble Sort 0.275 (2.768), Queens 0.146 (2.757), Puzzle 0.266 (4.115), Permutations 0.252 (3.224), Int. Matrix 0.168 (4.791), Sieve 0.451 (3.044), average 8.463. Color: 8-bit 7.391 s (1.433), 16-bit 10.747 s (1.264), average 1.348. FPU: KWhetstones/s 17,163.256 (3.296), Matrix Mult. 0.170 s (4.162), Fast Fourier 0.088 s (3.253), average 3.570. Against build 32 (the same clock): Towers and Permutations back to build 30's (the refined gate), the FPU 5 % faster (Fast Fourier 0.093 to 0.088), Math 2 % |
| 38 (build 36 renamed MacPPC7300, the disks' INQUIRY as the Mac LC core's; the fifth release) | 70 | 128 KB | -1.970 ns (TNS -457 ns; the same logic, another fit) | 38,452 (92 %), 329 | | CPU 2.501, Graphics skipped, Disk 1.570, Math 106.772. Benchmark Mix: KWhetstones/s 15,950.235 (54.236), Dhrystones/s 46,607.096 (2.698), Towers 0.204 s (3.130), Quick Sort 0.153 (4.659), Bubble Sort 0.275 (2.768), Queens 0.146 (2.761), Puzzle 0.266 (4.113), Permutations 0.253 (3.220), Int. Matrix 0.168 (4.795), Sieve 0.451 (3.046), average 8.543. Color: 8-bit 7.411 s (1.430), 16-bit 10.732 s (1.265), average 1.347. FPU: KWhetstones/s 16,969.573 (3.259), Matrix Mult. 0.170 s (4.167), Fast Fourier 0.088 s (3.254), average 3.560. Build 36's numbers within noise. Also on the board: Mac OS 9.1 to the Finder with the CD; a second disk on ID 1 (os753.hda beside os761ot.hda: the 7.5.3 System Folder duplicated on it, 67 MB, and a folder copied from ID 0 to ID 1). The first time 7.6.1 opened the second disk its Finder stopped with a bus error, then "error type 10" at Restart; after the restart (and the disk check after it) the same open, the copies and the Speedometer run were clean. Open: whether that was the old image's state (os753.hda was last written in the bus-error days of milestone S) or a rare race |
| 43 (the sound fixes of builds 39-42; the trace and the sound-input DMA channel off, the slow DMA channels a word at a time) | 70 | 128 KB | -2.404 ns with seed 1 (build 42, the same CPU: -3.296 with seed 1, -2.252 with seed 2; 357 of the 400 worst paths one path: `wb_result` through lfs's single-to-double conversion and the forwarding into `fop_b`, then the FPU's NaN/infinity/zero tests and the special result's select into `fin_result`, all in the request cycle) | 35,551 (85 %), 322 | | as build 38 |
| 44 (the FPU's special result a cycle later: NaN, infinity and zero operands found in the cycle after the request, from the operand registers) | 70 | 128 KB | -2.074 ns, seed 1 (the FPU family gone from the 400 worst; the worst is `wb_result` through the conversion into `fop_b`, the compare's NaN class, FPSCR[FEX], `x_fpen` and `redir_pc` into `pc_f`: the enabled-exception trap of a combinational `fcmp`) | 35,657 (85 %), 322 | not run on the board | not run on the board |
| 45 (+ the operands' classes from the core, beside the conversion: a forwarded single classed from its own fields) | 70 | 128 KB | -1.350 ns, seed 1 (no FPU path among the 400 worst; the worst: the D-cache's tag RAM into the I-cache's PLRU address, 210 paths, then CPU paths into RAMs, -1.07) | 35,725 (85 %), 322 | the menu bar at 85 s | CPU 2.503, Graphics skipped, Disk 1.571, Math 106.797. Benchmark Mix: KWhetstones/s 15,953.797 (54.248), Dhrystones/s 46,560.137 (2.695), Towers 0.204 s (3.132), Quick Sort 0.153 (4.664), Bubble Sort 0.275 (2.767), Queens 0.146 (2.759), Puzzle 0.266 (4.111), Permutations 0.252 (3.223), Int. Matrix 0.168 (4.794), Sieve 0.451 (3.043), average 8.544. Color: 8-bit 7.381 s (1.435), 16-bit 10.721 s (1.267), average 1.351. FPU: KWhetstones/s 17,135.317 (3.290), Matrix Mult. 0.170 s (4.159), Fast Fourier 0.088 s (3.247), average 3.566. Build 38's numbers within noise: the cuts change no cycle count but the special operands' |
| 46 (S_LZC skipped where the leading-zero count is known: `fmul` 6 cycles, `fdiv` 33, `frsp` and `fctiw` 7, a sum with a pinned addend or a dominant product 7; an addend-dominant sum still 8) | 70 | 128 KB | -2.249 ns, seed 1 (the fetch address into the I-cache's way RAMs and PLRU, the family that limited build 45, placed 0.9 ns worse; no FPU path among the 400 worst); -3.356 ns with seed 2 (`Scratch\qbuild9`, 35,217 ALMs: all 400 the I-cache's tag RAM into its PLRU address, no FPU path either). Three fits of a near-identical CPU at -1.35, -2.25 and -3.36: the fetch-address family's placement swings 2 ns, and it is the family to cut next | 35,238 (84 %), 322 | the menu bar at 85 s | CPU 2.504, Graphics skipped, Disk 1.573, Math 108.111. Benchmark Mix: KWhetstones/s 16,153.262 (54.927), Dhrystones/s 46,528.724 (2.693), Towers 0.204 s (3.129), Quick Sort 0.153 (4.662), Bubble Sort 0.275 (2.768), Queens 0.146 (2.758), Puzzle 0.266 (4.109), Permutations 0.252 (3.223), Int. Matrix 0.168 (4.794), Sieve 0.451 (3.046), average 8.611. Color: 8-bit 7.382 s (1.435), 16-bit 10.720 s (1.267), average 1.351. FPU: KWhetstones/s 17,316.017 (3.325), Matrix Mult. 0.169 s (4.174), Fast Fourier 0.087 s (3.299), average 3.600. Against build 45: Math 1.2 % and the FPU tests 1 % faster, the rest unchanged. Matrix Mult. hardly moves because a dot product's running sum is larger than each product: the addend-dominant sum, the one case that still counts in S_LZC |
| 47 (build 46 + the performance counters and the trace: `PERF = 1`, `TRACE = 1`; a measuring build) | 70 | 128 KB | -2.301 ns, seed 1 | 37,550 (90 %), 322 | the menu bar at 85 s | CPU 2.505, Graphics skipped, Disk 1.462 (the trace's DDR3 writes and the ARM reading the ring take from the disk path), Math 108.076. Benchmark Mix: KWhetstones/s 16,091.140 (54.715), Dhrystones/s 46,643.357 (2.700), Towers 0.204 s (3.130), Quick Sort 0.153 (4.662), Bubble Sort 0.275 (2.768), Queens 0.146 (2.756), Puzzle 0.266 (4.114), Permutations 0.252 (3.223), Int. Matrix 0.168 (4.792), Sieve 0.451 (3.046), average 8.591. Color: 8-bit 7.433 s (1.425), 16-bit 10.757 s (1.262), average 1.344. FPU: KWhetstones/s 17,278.319 (3.318), Matrix Mult. 0.170 s (4.166), Fast Fourier 0.087 s (3.303), average 3.596. Build 46's numbers: the counters cost nothing |
| 48 (the counters refined to 28: MEM's wait split four ways, the doubles counted) | 70 | 128 KB | -2.077 ns, seed 1 | 37,402 (89 %), 322 | the menu bar at 86 s | CPU 2.503, Graphics skipped, Disk 1.157 (the trace captured through the whole run, `trstream.py` polling the ring), Math 107.975. Benchmark Mix: KWhetstones/s 16,057.808 (54.602), Dhrystones/s 46,644.575 (2.700), Towers 0.204 s (3.133), Quick Sort 0.153 (4.662), Bubble Sort 0.275 (2.766), Queens 0.146 (2.761), Puzzle 0.265 (4.116), Permutations 0.253 (3.221), Int. Matrix 0.168 (4.794), Sieve 0.451 (3.041), average 8.580. Color: 8-bit 7.413 s (1.429), 16-bit 10.789 s (1.259), average 1.344. FPU: KWhetstones/s 17,466.333 (3.354), Matrix Mult. 0.169 s (4.174), Fast Fourier 0.087 s (3.303), average 3.610. The account of this run is below, "Where the cycles go" |
| 49-52, 54 (the sound session, 2026-10-10: 49 a scratch build with rate code 2 at 44,100 Hz; 50 the sound trace; 51 the fallback video alone; 52 code 2 at 44,100 and the fallback video, released and withdrawn the same day, an octave high; 54 the table restored, the fallback video kept, release flags, dated 2026-10-11: **the sixth release**, `releases/MacPPC7300_20261011.rbf`) | 70 | 128 KB | 52: -2.313 ns, seed 1 | 52: 35,362 (84 %), 322 | the grey picture at 30 s from the launch | not run (no CPU change: build 46's logic). On the board: the chime and Mac OS's sounds right by the user's ear; a screenshot after Mac OS's shutdown returns the fallback's black 640 x 480 frame (it failed before, there being no video); Mac OS 7.6.1 and 9.1 to the Finder and shut down, the black frame after each |
| **The real Power Macintosh 7300/120** (the user's, 2026-10-10: a 604 at 120 MHz on a 40 MHz bus, 256 MB, ROM 077D; the same Speedometer 4.02, Mac OS 7.6.1, 832 x 624, 256 colours) | 120 | the board's | | | | CPU 7.800, Graphics skipped (the monochrome, 2- and 4-bit tests 0.000 with 0 iterations: a real 7300 skips them too), Disk 3.544, Math 320.232, PR not given. Benchmark Mix: KWhetstones/s 51,514.527 (175.168), Dhrystones/s 162,591.579 (9.413), Towers 0.057 s (11.192), Quick Sort 0.050 (14.182), Bubble Sort 0.079 (9.640), Queens 0.048 (8.448), Puzzle 0.067 (16.248), Permutations 0.076 (10.776), Int. Matrix 0.057 (14.173), Sieve 0.121 (11.343), average 28.058. Color: 8-bit 3.379 s (3.136), 16-bit 4.334 s (3.134), average 3.135. FPU: KWhetstones/s 52,518.250 (10.086), Matrix Mult. 0.038 s (18.838), Fast Fourier 0.020 s (14.065), average 14.329. **Against build 48**: CPU 3.12x, Disk 3.06x, Math 2.97x; Dhrystones 3.49x, KWhetstones 3.21x, Towers 3.58x, Quick Sort 3.06x, Bubble Sort 3.48x, Queens 3.04x, Puzzle 3.96x, Permutations 3.33x, Int. Matrix 2.95x, Sieve 3.73x; Color 8-bit 2.19x, 16-bit 2.49x; FPU KWhetstones 3.01x, Matrix Mult. 4.45x, Fast Fourier 4.35x. The clock is 1.71x of it (120 against 70), so the cycles-per-instruction gap is 1.7-2.3x on the integer tests, 2.5-2.6x on the FPU's matrix and FFT, 1.3-1.5x on Color |

Speedometer 4.02 is at the root of `os761ot.hda` (copied from the floppy
image `games/MacPPC7300/floppy/speedo.img`, the volume of `Speedo402.sit`'s
DiskCopy image cloned into a 1440K HFS floppy with rb-cli; the image was
backed up as `games/MacPPC7300/os761ot_backup.zip` before the first run, 67 MB,
checked). A run is scripted from an off machine (the session's
`speedo_run.py`: load, boot, the Finder's windows closed, "Mac" Command-O,
"Spee" Command-O, the splash clicked, "Not Yet" clicked, Command-A, Command-D
"Mac" Return for the temporary file's drive, Return at the Graf notice, 100 s,
a screenshot, Command-Q, "No" clicked, the power key; the clicks find the
pointer in a screenshot and correct: 7.5 minutes). Builds 28 and 29 agree
within 1 % on every number but KWhetstones/s, which swings 15 % between runs
(13.7-16.2 k): a timed test, not a counted one. It skips the Graf
Test and the 1-, 2- and 4-bit colour tests: "This machine does not support
monochrome graphics" (Mac OS 7.6.1 at 832 x 624 in 256 colours). Answered
2026-10-10 by the user's run on a real 7300/120 (the reference row above):
it skips them too (0.000, 0 iterations), so the Control driver sees what a
real one sees.

Where build 28's time goes (TimeQuest, `Scratch\qbuild\worst28.tcl`): its 60
worst paths are one family, the data cache's tag RAM (the M10K's 2.5 ns
clock-to-out and 2.4 ns of clock skew against the logic's flip-flops) through
the CPU's memory address mux (`cpu|mem_addr`, the write-back address off the
tag RAM), the machine's `ram_map` and device decode, Grand Central's register
selects and the ESCC's read mux into `gc|rdata_q`: 14.1-14.4 ns of data
delay, 83 % of it routing. Build 26's were the same family into `gc|nv_hi`
and the VIA's `t1_left` through `cpu|mem_wdata` (the write-back data off the
cache RAMs). The CPU's own worst path (the I-cache's tag RAM into the MMU's
segment-register read-ahead, `mmu|i_sr_q`) was -1.33 ns in build 26.

### Where the cycles go (2026-10-10, the cycles-per-instruction work)

The clock explains 0.58 of the gap to a real 7600/120 on Speedometer's CPU
tests; the rest, about 2.3x, is cycles per instruction. The 604's numbers
(its User's Manual, chapter 6, "Instruction Timing"), against this core's:

| | 604 | DSPPC604 |
|---|---|---|
| Issue | four instructions a cycle to six units (two single-cycle integer, a multi-cycle integer, the FPU, the load/store unit, the branch unit), out of order, with two reservation stations a unit; four retired a cycle | one operation a cycle, in order |
| Integer | every one-cycle instruction 1 cycle, forwarded from the result buses; multiply 4 (3 for 32 x 16), divide 20 | 1; multiply and divide behind the unit's handshake |
| Load | 2 cycles latency, one a cycle | 2 cycles in MEM (the cache answers the cycle after the grant), so the pipeline waits a cycle on every load or store; a use the cycle after waits another (`ex_stall`) |
| Floating point | `fadd`, `fmul`, `fmadd`, `fcmp` 3 cycles, pipelined one a cycle; `fdivs` 18, `fdiv` 31 | 7-8, 33, one at a time (`docs/DSPPC604_plan.md`, M2) |
| Branch | the 64-entry BTAC predicts in the fetch cycle (a hit costs nothing), the 512-entry two-bit BHT corrects it at decode (1 cycle), the dispatcher at dispatch (2); a branch resolved in execute costs 3; two branches unresolved at a time | the 128-entry buffer predicts in the fetch cycle; everything else is resolved in EX: 3 cycles for a taken branch the buffer does not know, and for every misprediction |
| Caches | 16 KB four-way each, a hit in one cycle, the load/store unit pipelined; a line read in 4 bus beats (3x the bus) | 16 KB four-way each, the same hit timing; the line from the L2 or the SDRAM across the clock crossing |

Measured on the golden programs before this work: 1.85 cycles an
instruction integer, 3.45 floating point; the 7300's ROM in lockstep 1.57.

**The counters** (`DSPPC604_perf`, `PERF = 1`; `perf_cnt`, 28 free-running
32-bit counters): the cycles, the operations and the instructions retired,
and a class for every cycle in which no operation leaves EX: EX waiting for
MEM (the cycle an access is granted, answered in the next: every load and
store costs it; a cycle the cache does not grant; the memory unit's own
cycle between the two accesses of a double or a misaligned operand; the
data cache busy beyond a lookup: a miss, a write-back, a snoop), for a
load's data (`ex_stall`), for the multiplier, the divider, the FPU, or
anything else; EX empty in the three cycles after a redirect, empty for the
fetch (an instruction cache miss, or the one cycle ID holds a word delivered
late), empty with ID waiting for XER. Then the events: branches, taken,
mispredicted (and of those, taken while predicted not taken), exceptions,
refetches (`rfi`, `mtmsr`, the translation changes), loads, stores, doubles
among them, the two caches' memory transactions, the cycles a fetch waits
beyond a hit and the cycles the instruction cache does not grant one. The
benches print the account at the end of every run (`core_main.cpp`,
`print_perf`); on the board a `PERF = 1`, `TRACE = 1` build writes the
counters into the DDR3 trace every 2^23 cycles (kind 12, five records) and
`syn\perf.py` turns a capture, or the ring, into one line per 120 ms
interval: the cycles per instruction and the classes of every 100 cycles,
so that each of Speedometer's tests can be read off its own interval.

What the suite's programs said first (2026-10-10, the first version of the
counters, before the MEM class was split): the floating-point golden program
(3.46 cycles an instruction, 128 k loads in 282 k instructions) spends 40.6
of every 100 cycles with EX waiting for MEM, about 3 cycles a load, because
an 8-byte `lfd` or `stfd` is two word accesses with a cycle between them on
the 32-bit data path (the 604 moves a double in one); the FPU itself takes
12.2. The integer golden program's 1.85 is its own shape (26 of 100 cycles
the fetch: 527 KB of straight-line code, every line a compulsory miss; 18.5
the divider). The random lockstep programs (2.6, 3.0 with translation on):
44 an operation leaves EX, 14 (25 translated) MEM, 13 after a redirect
(half their branches mispredict, as random branches do), 16 the fetch, 9
the divider. None of them is Mac OS: the board's account decides.

**The board's account (build 48, 2026-10-10; `Scratch\speedo_b48\perf.csv`,
one row per 120 ms; the tests identified by their profile and the run's
screenshots).** Of every 100 cycles:

| Phase | CPI | an operation leaves EX | MEM: granted | not granted | between a double's accesses | data cache busy | load-use | mul | div | FPU | after a redirect | the fetch | branches of instructions, mispredicted | loads, stores of 100 instructions |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Dhrystones (9 s) | 1.39 | 75 | 13 | 0.5 | 0.2 | 1.6 | 0.1 | 0 | 0 | 0 | 3 | 6 | 29 %, 4.5 % | 17, 0.8 |
| KWhetstones (CPU and FPU lists) | 5.4 | 19 | 2 | 0.2 | 0.7 | 0.4 | 0.6 | 3 | 53 | 19 | 0.6 | 1.3 | 12 %, 9 % | 6, 1.3 |
| the integer tests (Towers to Sieve, 20 s) | 1.2-2.0 | 55-81 | 11-25 | 0.2-5 | 0-0.6 | 0.4-7 | 2.5-9 | 0-6 | 0-8 | 0 | 3-9 | 1-4 | 7-17 %, 7-34 % | 4-24, 1-22 |
| the FPU tests (Matrix Mult., Fast Fourier) | 1.9-2.1 | 50-54 | 12-16 | 0.6-1.4 | 0.1-0.3 | 0.6-1.4 | 2.3-2.7 | 0.4 | 0-7 | 18-27 | 1-1.4 | 1.5 | 4-8 %, 8-17 % | 15-25, 6-7 |
| Color 8- and 16-bit | 5-9 (peaks 10.6) | 10-25 | 8-13 | 0.3-2 | 4-8 | 48-72 | 0.1 | 0 | 0 | 0 | 1-3 | 2-4 | 16-25 %, 10-20 % | 5-28, 18-42 (38-43 % doubles) |
| the Finder idle (between the tests, and after) | 2.90 | 40 | 10 | 1.9 | 1.8 | 7.8 | 0.1 | 0 | 0 | 0 | 18 | 21 | 30 %, 58 % | 22, 3 |

What it says, in the order of the cycles it would give back on the CPU
tests, against the 1.7-2.3x gap to the real 7300/120 at the same clock:

1. **MEM's granted cycle** (11-25 of 100 cycles in the integer tests, 13 in
   Dhrystones, 12-16 in the FPU tests): every load and store holds EX a
   cycle because MEM takes two (the request, then the answer) and the next
   operation cannot enter it until the answer. MEM as two stages, the
   request's and the answer's, would take an access a cycle, as the cache
   already grants a read hit behind another. The forwarding then has one
   more source and `ex_stall` one more case, and a store's data must be
   held across the second stage: rule 2 of `docs/DSPPC604_plan.md` (how a
   hazard is handled) **needs the user's go-ahead**. Worth about 0.15-0.3
   cycles an instruction on the integer tests.
2. **Load-use** (2.5-9): a load's data reaches EX only from WB. With MEM in
   two stages it could be forwarded from the answer stage, the same cycle
   count as now (the 604's loads are two cycles too), so this is part of 1,
   not a separate cut; it does not shrink without a cut rule 2 forbids.
3. **Redirects** (3-9 in the integer tests, 6-9 where the sorts and Puzzle
   branch most; 18 in the Finder's idle loop, whose branches mispredict 58
   %): a return-address stack for `blr` and a branch target buffer of 512
   or 1,024 entries in M10K (128 today, in registers; the plan's M5 notes
   record the RAM form that was tried and why it mispredicted the entry it
   had just written). A better predictor leaves the handshakes alone: no
   go-ahead needed.
4. **The divider** (53 of 100 cycles in Whetstones, up to 8 in the integer
   tests that divide): 35 cycles against the 604's 20; a radix-4 divider
   (two quotient bits a cycle, 18 cycles) is a cut inside the unit.
5. **The FPU** (18-27 in its tests, 19 in Whetstones): 7-8 cycles one at a
   time against the 604's 3 pipelined; the latency list in M2 and overlap
   are the known work, deferred.
6. **The Color tests** are not the CPU's: 48-72 of 100 cycles the data
   cache sits in an uncached access (the frame buffer, write-through or
   cache-inhibited), 38-43 % of the operations doubles, 8 of 100 cycles the
   memory unit's gap between a double's two words. A posted write for
   uncached stores (the 604 has one) and a 64-bit path for a double would
   take most of it; the gap to the 7300 there is 1.3-1.5x at the clock.
7. **The fetch** is small during the tests (1-6) and large only in the
   Finder's idle loop (21) and the boot (10-20), where the instruction
   cache misses to the L2: not a benchmark matter.

The user's decision, 2026-10-10, after build 48: the speed work stops here
and the sound issues come first; this account is the starting point when it
resumes, with 1 (the go-ahead question), 3 and 4 the first cuts.

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
| S | Decided by the session, 2026-10-07: DMA reaches memory through one DMA port in `MacPPC7300_machine`: each access's line through the CPU's snoop port, then the memory port, which the DMA takes before any new CPU access; a write's line is snooped again after it, to drop a copy fetched in between (holding the CPU's reads during the snoop deadlocked the board: a cache can need a fill to finish before it answers a snoop). DBDMA gathers data in into lines (a whole line written as a line, else the words with bytes, with byte enables). MESH's bus is modelled at the signal level with the targets as their own module (`MacPPC7300_scsidisk`), so programmed I/O, DMA and the bus-status registers see the same lines; the information phases as Linux's `mesh.c` uses them where dingusppc has no model (DMA out), a DMA data in's command done only once the FIFO and the channel have emptied (Mac OS's driver does not wait for the FIFO; Linux waits up to 50 us). The disks answer INQUIRY as "QUANTUM " (dingusppc's vendor) "MiSTer MacPPC7300 HD", no synchronous transfers, an extended message answered with MESSAGE REJECT; a new phase's first REQ 10 us after the phase lines change, as a disk is slow to change phase (the ROM's SIM waits after the status byte for REQ to drop, FFEB8D98, and hung on the board while the disk asked at once); one block per hps_io request (`sd_blk_cnt` 0), two buffered each way; hps_io `WIDE` 0 (the ROM upload is byte-wide), `VDNUM` 6 (the Mac SCSI family's slots), `SC0`/`SC1` so the Main remembers the images; the images kept in registers the machine's reset does not touch, so no mount replay is needed. Reason: rule 2 (one way into memory, coherent); the real chip over an emulator's shortcut where the shortcut is visible (dingusppc's Mac OS cannot write its disk); the stock Main's block interface works on the board as it is. |
| S | Decided by the session, 2026-10-07 (the bus error at "Welcome to Mac OS"): the SWIM3 floppy controller is built as a device (`MacPPC7300_swim3.sv`), dingusppc's `swim3.cpp` register for register with one internal Superdrive that has no disk (its status lines as `superdrive.cpp` answers an empty drive), on Grand Central's interrupt source 13, with a 1 MHz tick from `MacPPC7300_machine` for the chip's timer and its 80 us steps; no disk is ever read. Reason: the ROM's .Sony driver installs only if the chip answers its probe, and Mac OS 7.6.1's System dereferences the driver's variables (SonyVars, low memory 0134, -1 without the driver) while loading: the bus error. A chip that answers but holds no disk is what a 7300 with an empty drive is. Also decided: the lockstep bench takes the core's R and C bits in a word loaded from the page table (dingusppc's MMU sets them differently), and MacsBug 6.6.3 (put into a copy of the image with rb-cli: `Scratch\disks\os761mb.hda`, on the card as `games/MacPPC7300/os761mb.hda`) is the board-side debugger from now on; its keyboard reading doubles keys typed through the Remote, noted in the stubs list under ADB. |
| S | Decided by the session, 2026-10-08, at the user's request ("fill in all the stubbed areas now that we are actually trying to boot Mac OS"): the devices Mac OS's start-up meets are built as the chips behave, not as register stubs. AWACS (`MacPPC7300_awacs.sv`) plays DMA channel 8's frames at the control register's rate to the MiSTer's audio and feeds channel 9 silence, the registers as dingusppc's; the rate code read as dingusppc and Linux read it (Screamer's table: the ROM's chime at 22,050 Hz; MAME's AWACS would play it at 44,100), to be checked by ear against a real 7300; the frame count counts (dingusppc's does not). DMA channels 2, 3, 8 and 9 are `MacPPC7300_dbdma` engines beside MESH's, through one arbiter in Grand Central (sound first). MACE (`MacPPC7300_mace.sv`) has its cable unplugged (the user's choice): dingusppc's registers, and every frame sent ends in loss of carrier with its transmit interrupt, as an Am79C940 reports in the link fail state (dingusppc's MACE cannot transmit at all). The ESCC gets the Z85C30's interrupts on a bus without acknowledge cycles (RR3, RR2's status in channel B, WR0's resets, WR9's master enable), one line a channel (0F, 10). Cuda's NMI (PC2) is Grand Central's source 14, and the PC keyboard's Menu key is ADB's power key, so Command-Menu enters MacsBug and Control-Command-Menu restarts (Cuda's firmware decides both). Cuda's clock is set from the MiSTer's RTC (hps_io's TIMESTAMP + 2,082,844,800) when Cuda first releases the CPU, as MAME does (RAM AB-AE). Reason: Mac OS's drivers wait on these chips' interrupts and status, and a stub that never answers looks like a hang; dingusppc where it models the chip, the chips' manuals and MAME where it does not. |
| S, P | Decided by the session, 2026-10-08 (later the same day): the monitor sense lines are modelled as wires (a driven-low line reads low, the AppleSense codes give the monitor's grounds and straps), against dingusppc's table, because Mac OS 7.6.1's Control driver bit-bangs a DDC probe on them and must read its own lines back; the ESCC gets the synchronous mode as far as LocalTalk with an empty printer port needs (sync/hunt 1, the transmitter's CRC and EOM at underrun, the external/status interrupt, Grand Central's LocalTalk registers as dingusppc's), which let Open Transport's AppleTalk start; the keyboard answers one key event a Talk and re-reports held modifiers after a reset (MacsBug's polling, Shift through the start-up); the NVRAM is kept on hps_io's slot 2 as the Quadra 800 core keeps its PRAM (load on mount with the machine held in reset, save 2 s after the last write or when the OSD opens); the Scale option (`video_freak`) as the other Mac cores have it. Reason: each was what Mac OS or the user needed, found on the board or in the trace; the Quadra 800 core's solutions where it has one. |
| K | Decided by the session, 2026-10-07: the ADB devices (`MacPPC7300_adb.sv`) at the wire level, the Mac LC core's structure and PS/2 table with dingusppc's registers: keyboard handler 2 (1 and 2 settable, 3 refused, so the right-hand modifiers give the left-hand codes), mouse handler 1 (1 and 2; not the extended protocol 4, which dingusppc's mouse takes: the Apple Mouse II has none), SRQ enabled from reset, a true service request (the stop bit held low to 300 us); Alt is Command, the Windows keys Option, Caps Lock locks. The line's timing is ADB's own, counted in Cuda's 4,194,304 Hz ticks so it keeps step when the bench runs Cuda fast; the answer 160 us after the stop bit. Reason: Cuda's own firmware is the judge, and its receive (1CF3-1D88) waits 283 us for the start bit and 79 us at most for any low. On the way, Cuda's PA6 turned out to be the line's level, not its inverse (corrected in `MacPPC7300_cuda.sv`; MAME agrees once its devices' ASSERT is read as high); with it inverted, every ADB command reported a service request and no device could answer. |
| parity | Answered by the user, 2026-10-08 (start of the Quadra-parity session, the user away from the board): the board may be used remotely unless the user asks for it, what needs the user (sound, controllers, MT32-pi, printer) waits on a list; "fix the mouse joystick" means the ADB game controllers, the MouseStick II first (its axes may be reversed and "Stick moves pointer" seemed not to work on the Quadra 800 core: findings for that core in `docs/quadra800_adb_joystick_prompt.md`); the user has an MT32-pi and a gamepad, Discord testers will try serial MIDI in and out; the Main's work goes on the user's branch `Mac-ppc-enhancements` in `..\Main_MiSTer`, with far fewer comments in new code; PPP is part of parity; BlueSCSI, CD audio and the second disk too, and the build's size reported after them (a floppy drive if it fits); the clock an hour behind was Mac OS's daylight-saving setting; the scaling's odd text is the framework's (all the Mac cores). |
| parity | Decided by the session, 2026-10-08: the ADB controllers as the Quadra 800 core's (devices, handlers, formats, Talk 1 and 2), at the wire level with answers up to eight bytes and Talk 3 collisions (the lowest device answers, the others keep their address at Listen 3's FE), latched under reset; but None by default (the Quadra: the GamePad), the menu in the internal order (None, MouseStick II, Firebird, GamePad, SideWinder), and "Stick moves pointer" also for the GamePad's analog stick and for None, through the mouse. Reason: the bus stays as proven unless a controller is chosen (a GamePad shares the keyboard's address on every boot); the Quadra's option does nothing with its default GamePad, which is probably what the user saw. |
| parity | Decided by the session, 2026-10-08: the serial port as the Quadra 800 core's: WR11's TRxC source a MIDI interface's 1 MHz at all times (the chip's reset value 08 already selects it for the transmitter; every driver sets WR11), the modem port's CTS uninverted from the UART, its RTS "a received byte waits", DTR looped to DSR, the MT32-pi on the modem port's transmit and, in MIDI mode, on its receive; the UART's speeds 115,200 (the default, as before), 57,600, 38,400, 19,200, 9,600 and MIDI. Reason: the Quadra settled the polarities on the board (an ImageWriter); MIDI interfaces on a Mac clock the SCC through TRxC. |
| parity | Decided by the session, 2026-10-08: the CD-ROM speaks the Quadra 800 core's optimized contract with the Main (its answers from the Main's windows, the transport executed by the Main, frames from it), macppc7300 added to both the Mac family and the optimized contract on the Main branch; without that Main there is no CD drive at all, and nothing is ever written to slot 4. The BlueSCSI Toolbox as the Mac LC core's (the Quadra has none), capabilities 82. Reason: the least logic in the FPGA (the floppy may need the room), and the Main's code is proven on the Quadra; a drive answering with garbage is worse than none. |
| after parity | Answered by the user, 2026-10-08 (start of the session after parity): install the Main branch's binary on the board (done: `a2546ea7`, the official one kept as `/media/fat/MiSTer.official`, `eb1799eb`); MacPPC7300 stays in the Main's Mac family, which sends local time with daylight saving; `releases/boot0.rom` in git is how the core is distributed for now; the CD changer is parked; never change anything under `sys/` (a fix there is the user's to make); the scaler fault must be fixed outside `sys/`. |
| after parity | Decided by the session, 2026-10-08: a trace in DDR3 for debugging on the board (`MacPPC7300_trace.sv`, 2,048 records of 32 bytes at 0x30500000, after the network's rings; a queue of 16; read by `syn\mister.py trace` through `/dev/mem`): the SCSI targets' commands, bus resets and CD mounts; the CPU's accesses to MACE, DMA channels 2 and 3 and Grand Central's interrupt registers (MESH and channel A behind `TR_MESH`); DMA channels 2 and 3's finished commands; the ADB keyboard. About 900 ALMs and 9 RAM blocks. Reason: the Toolbox apps, the CD and Mac OS's Ethernet driver are closed code that only the board runs; a whole-machine simulation to the Finder takes hours. |
| after parity | Decided by the session, 2026-10-08: `ALLOW_POWER_UP_DONT_CARE OFF` in `MacPPC7300.qsf` (the template sets it ON). Reason: the Quadra 800 core's scaler fault (its `docs/perf/fix_hw_20261001/SCALER_FAULT.md`: on some loads of some fits the scaler's DDR3 port takes a stream of bursts during the core's first reset and every later burst lands k beats early, the picture displaced) needs ascal's `avl_write_i` to hold a 1 when that reset arrives; ascal sets no reset or initial value for it, `avl_write_sr` or `avl_state`, so with power-up don't care the fit chooses what they hold, which is why some fits fail and others never do. With the option off every register without an initial value powers up 0, so the scaler starts idle. The Quadra's own fix is in `sys/sysmem.sv`, which this core does not change (the user). Cost: about 450 ALMs, no slower (build 13 against 12, the same RTL). Likely the Discord tester's picture in four strips; not reproduced here, so not proven. |
| after parity | Measured by the session, 2026-10-08, at the user's request for a ROM with the start-up memory test patched out: the 7300's ROM runs no size-dependent memory test. The 68k start-up code's RAM test (FFCC7620) is skipped on a cold start (the branch at FFCC750E takes FFCC7594, which writes the warm-start signature; dingusppc's coverage run never reaches the test), and on the board the start to the question-mark disk takes 49-58 s at 16 MB, 50-61 s at 96 MB warm and 49-57 s at 96 MB after the memory-test boot had overwritten all of RAM (a cold start). No patched ROM made: nothing to remove. The 50 s is the search for a start-up disk with none mounted. |
| after parity | Decided by the session, 2026-10-08, from the trace of Mac OS 7.6.1's MACE driver on the board: MACE loops a frame back to its receiver when UTR's LOOP bits are set (every loopback mode as the internal one; the driver's open sends a frame to itself in internal loopback and gives up after 2 s); MACE delivers a real FCS (CRC-32); Grand Central's Ethernet DMA channels get device status bits: channel 2's s5 is MACE's XMTSV (the driver's OUTPUT_LAST waits on it), and on channel 3 the frame's end ends an INPUT_MORE as well as an INPUT_LAST, s6 reading 1 while that command finishes (the driver uses 1,536-byte INPUT_MOREs; NetBSD's if_mc tests s6 in xferStatus). Reason: none of the emulators models these (dingusppc's MACE cannot transmit, its DBDMA has no end of frame, MAME has no MACE); the driver's own programs, read off the board with the trace, and NetBSD's driver are the evidence. Left: the driver's LOAD_QUADs of MACE registers through the system space read 0 (DMA reaches only memory). |
| after parity | Decided by the session, 2026-10-08: LOAD_QUAD writes its value into the command's cmdDep (as dbdma.cpp's `xfer_quad`; it never reached memory before), and DMA channels 2 and 3 reach MACE's registers with a quad through the system space (key 6, Grand Central's window), a byte in a clock the CPU leaves Grand Central alone; quads to other devices, and from the other channels outside RAM, read 0. Reason: Mac OS's MACE driver ends each transmit with LOAD_QUADs of XMTRC, XMTFS and IR (the trace), which on the chip also clear XMTSV and IR; only MACE's registers are asked for, and reaching every device would put a second master on Grand Central's whole register bus. |
| after parity | Found and decided by the session, 2026-10-08: Mac OS 8.5-9.1's grey screen was their disk driver (Apple's 8.1.2, Drive Setup 1.7: with 7.6.1's driver in its partition the 8.6 image starts). Its first command through SCSI Manager 4.3 selects with IDENTIFY and SDTR; the disk answered MESSAGE REJECT; the 7300's SIM then raises ATN and issues MESH's bus free, and MESH held ACK while ATN was up (as dingusppc's, whose target is then moved on by hand), so the target never saw the byte end and the SIM polled MESH's interrupt register for ever (the trace with `--trace-mesh`). Now the disks answer SDTR with offset 0 (asynchronous, which the bus is) and WDTR with 8 bits, as a real drive negotiates; MESH's bus free lets ACK go whatever ATN says; and a target answers ATN at the end of a message in with MESSAGE OUT. Reason: Apple's drives negotiate, so the reject path is one the SIM rarely meets; answering keeps the driver on the path real machines take, and the other two make the reject path work too (the bench's test 12 runs both). On the board (build 20): Mac OS 8.5, 8.6 and 9.1 start from their own images to the Finder. 8.5 and 9.1 then warn that the clock is not set: the time shown is right, and the classic Mac OS takes no year after 2019 as valid (the "Y2K20" limit; the 2020Patch extension lifts it), so not the core's. |
| after parity | Asked by the user, 2026-10-08 ("build the floppy drive"), decided by the session: the floppy as dingusppc models SWIM3, at the level of sectors (the chip finds address fields and moves a sector's bytes by DMA itself, so no GCR or MFM bit stream is needed, unlike the Mac LC core's IWM/SWIM), read only (dingusppc does not write either; every disk reports write-protected), the image on hps_io's block slot 6 (VDNUM 7; the Main branch's per-slot code covers only slots 0-1, so slot 6 takes the generic path, no Main change) rather than loaded whole into memory as the LC core does, raw or DiskCopy 4.2 told by the size, not remembered across starts (the ROM tries a floppy first). Reason: the least logic (about one more DBDMA engine and a 1 KB buffer) for what Mac OS needs; writing can follow if wanted. |
| after parity | Found by the Linux test (an Opus agent on the board, 2026-10-08, at the user's request; stopped by the user once this was found) and decided by the session: Debian 7.11's PowerPC kernel (3.2, from the image's Mac OS 8.5 through BootX) starts on the core (Grand Central's interrupts, controlfb, both serial ports with the console on ttyPZ0, Cuda and ADB, the RTC, SWIM3, MACE; MD5s of the initramfs's files as the PC computes them), but its MESH driver printed "interrupt in idle phase?" and found no disk, so the root file system never came. MESH's reselection on and off (0C, 0D) now set no command done. Reason: Linux's `mesh.c` issues 0C in its idle phase after every command and reset, and takes any interrupt after 0D, just before arbitration, for a reselection: with command done set (as dingusppc sets it) its state machine ran ahead; on a real 7300 it prints nothing, so the chip sets none. Mac OS never waits for it (its trace: 0D, 0F, select at once; after 0C a stray interrupt cleared). |
| after parity | Asked by the user, 2026-10-08 (watching Debian on the board): Linux's console was barely visible, the Ethernet options become one (Off or the interface), the memory-test boot option goes, the largest RAM is 120 MB (not 112 and 124). Done: 32-bit pixels go through RaDACal's colour table a component at a time (Linux's controlfb is DirectColor: its grey is pixel 07-07-07 and table entry 7); "Ethernet (on reset)" is O[19:17], 0 off, 1-4 eth0, eth1, wlan0, tap0, with the Main branch's `mac_eth.cpp` reading the same field; RAM 120 MB in place of the option index 6; the memory-test boot tied off (the RTL stays for the bench). Also found on the way: the disks answered every logical unit (Linux saw each eight times); now only LUN 0 is there (INQUIRY of another: 7F; other commands: ILLEGAL REQUEST, LOGICAL UNIT NOT SUPPORTED). The image's BootX needs 96 MB or more (with 16 MB BootX ends in "unimplemented trap") and "Force SCSI ON" off (a PowerBook option; on it BootX stops at Mac OS's "Starting Up..."). |
| after parity | Asked by the user, 2026-10-08 ("when I selected 120mb I got 96"; "changing the memory amount or anything that really requires a reboot requires a restart"; less debugging, the UART kept for Open Firmware), decided by the session: the 7300's ROM (FFF041B8-FFF04454) puts DIMM bank k at k x 64 MB, probes each in 1 MB steps up to 64 MB, cuts a size that is not a power of two to one, and packs the banks from 0: flat RAM gave bank 1 56 MB, cut to 32, so 120 came up as 96. The machine now has Hammerhead's banks: one per power of two in the option (120: 64, 32, 16, 8 MB in banks 0-3, the SDRAM largest first), each answering only within its size at the base the ROM writes (bank registers' bits 30-22), flat until a base is set (so 16 and 64 MB, one bank at 0, are as before, and the dingusppc lockstep at 16 MB is untouched). RAM and Monitor are taken only while the machine is held in reset (the OSD says "on reset"; a change no longer resets a running system); the debug readouts (UART and picture), TV Mode and `MacPPC7300_debug` are gone from the core; the UART is the modem port always; the user LED is the CPU's heartbeat. |
| after parity | Found by the user, 2026-10-08 (Debian's `shutdown -h now` ended in "BUG: soft lockup" in `pmac_power_off` / `cuda_poll`), decided by the session: Linux, like Mac OS, sends Cuda POWER_DOWN and waits for the power to go; nothing switched it off, so the CPU spun until the kernel's watchdog spoke (the disks were already synced and unmounted: harmless, but it read as a crash). Cuda's firmware switches a 7300 off by driving PA0 low (115B, 1161-1163) and waiting over a second; the core now takes PA0 driven low for 256 bus cycles (the cold start's port set-up drives it 65) as the power going off: the CPU and the board are held in reset (a black screen) until the OSD's reset or the keyboard's power key (the Menu key), which restarts the machine as the OSD's reset does. `run_cuda.py` ends with POWER_DOWN: off 17 ms later (the firmware sends no reply first), the CPU held, the power key seen; MAME's 6805 lockstep identical. |
| after parity | Found on the board by the session, 2026-10-08 (build 26), decided by the session: Mac OS 7.6.1 found every 400K and 800K floppy image "unreadable" (insertion and the address fields worked). Apple's SWIM3 driver (SonySWIM3.a, the same code as the 7300 ROM's DRVR 4) wants a GCR sector as the chip leaves it: 704 bytes of 6-bit values (the sector number, 12 tag bytes and 512 data bytes in three-byte groups with three running checksums, the checksums) and decodes them itself (DeNibbleize); SWIM3 sent the 512 decoded bytes, as dingusppc does (dingusppc cannot read GCR with Apple's driver either; MAME stops on a GCR read). `MacPPC7300_swim3.sv` now encodes each GCR sector so (zeros for the tags), MFM unchanged; the bench decodes with Apple's routine. Also: the Mac's clock now counts on from the HPS's time in the core (it went back to the core's load time at every reset or power-on). |
| parity | Decided by the session, 2026-10-08: Ethernet carries frames only. MACE (registers, DMA channels 2 and 3) stays in the FPGA; `MacPPC7300_enet` keeps a transmit and a receive ring (8 x 2 KB each) at DDR3 0x30400000 (after the VRAM, in the cores' half of DDR3), the Main sends and receives them on its interface; the receive DMA gets what Linux's `mace.c` expects (the frame, the FCS, RFS0-3; the INPUT_LAST ends with the frame); the link is up only while the Main serves the rings, so with the official Main the cable stays unplugged. Reason: MACE's DMA is Grand Central's, already in the FPGA, so the Quadra's way (the Main models the chip and reaches guest memory through a mailbox) would be more work and slower; frames are what crosses to the HPS either way. |
| speed | Decided by the session, 2026-10-08 (the speed session): the machine presents a device access to the devices from a register (`MacPPC7300_machine` p_*: the word, address, byte enables and the one-hot decode, a cycle after the CPU's request), so the device answer comes two cycles after a word request and the line's eight words a cycle later than before. Reason: build 28's 60 worst paths all ran from the data cache's tag RAM through the CPU's memory address (a write-back's, straight off the RAM) and the machine's decode into Grand Central's registers (-1.46 ns); a device access is some 1 % of the CPU's accesses and the VIA's are paced in microseconds anyway, so the cycle is cheap and the CPU is untouched. |
| speed | Found on the board by the session, 2026-10-09 (build 33: Mac OS 7.6.1 bombing in the Finder, 9.1 stuck at the grey screen, every simulation gate green): the refined cache gate took a request the cache had not granted when a DMA snoop to the pending write's set and a CPU request to another set met in the same cycle (the sequential take skipped the clashing snoop and fell through to the request, while `gnt` refused it for the snoop). Fixed to mirror `gnt` exactly. Decided: the core bench gets a snoop storm (`--snoop-every N`: a read snoop of a random line, half of them lines the program stored to, every N cycles; read snoops change no program state, so any program runs under them), and `run_core.py` runs the golden programs and the 7300's load/store set under it. Reason: the lockstep's disk-less boot has almost no DMA, so the caches' arbitration against snoops was tested only by the directed DMA test's few lines; the board's disk DMA found the race within minutes. |
| speed | Decided by the session, 2026-10-09: the CPU clock is 70 MHz (`CPU_MHZ` in `MacPPC7300.sv`; the PLL's 1400 MHz VCO). Reason: build 32, build 31's tree at 70 MHz, boots Mac OS 7.6.1 and 9.1 to the Finder on the board, runs Speedometer's whole suite with every number 8 % above build 31's (the clock's ratio, nothing lost) and keeps the clock right; its slow-corner slack is -1.77 ns (62.2 MHz), which is what builds 26-28 carried at 65 MHz on this board for days. The slow 100 C model stays the figure of merit in the tables; the board at room temperature is the proof. If any build later misbehaves at 70 and not at 65, the clock goes back first. |
| speed | Decided by the session, 2026-10-08: the L2 cache is `MacPPC7300_l2.sv` on the machine's single memory port in the CPU's clock, in front of the clock crossing: 128 KB to begin with (256 KB when the fit allows), direct-mapped like the cache DIMMs, 32-byte lines, write-back and write-allocate for lines (the L1's write-backs stay in it, dirty), words (cache-inhibited accesses) served from a line they hit and otherwise passed to memory without allocating; indexed by SDRAM offset, so RAM and the ROM are cached and no device ever is; a hit answered from a register two cycles after the request; invalidated by the machine's reset (the ROM upload writes the SDRAM behind it) and kept across Cuda's restart; an OSD option "L2 cache (on reset)" (O[4]) with Off as a wire, for the measurements. Not reported to the software (Hammerhead's register 0E still reads 0): the ROM's L2 code (FFF03D48) sizes the L2 from a word read of 0E whose value on a real Hammerhead is not known. Reason: that port is where the CPU's and the DMA's accesses already meet, so the L2 is coherent with DMA by construction and the L1's snoop stays as it is; write-back because the L1's write-backs then cost two cycles instead of a trip to the SDRAM. |
| name | Asked by the user, 2026-10-09: the core is **MacPPC7300** everywhere. The core's name (CONF_STR, so `games/MacPPC7300/` and `config/MacPPC7300.*` on the card), the Quartus project and the bitstream, the machine modules' prefix (`MacPPC7300_*`; the CPU stays `DSPPC604_*`), the documents, the tools and the WSL cache (`~/.cache/macppc7300`; the old `~/.cache/ppcmac` is a link to it); on the Main branch `Mac-ppc-enhancements`, 24832a2: the Mac family, the optimized CD contract and the Ethernet card match "macppc7300". The disks answer INQUIRY as the Mac LC core's do (the user's choice; the Quadra 800 core's "WOMBAT33" was considered and declined): vendor "MiSTer", product "VIRTUAL DISKn" with n the SCSI ID, the revision empty; before, "QUANTUM" (dingusppc's vendor) and "MiSTer PPCMac HD". Decided by the session: the repository's folder (`PPC_Mac`) and the older Main branch names are left as they are; the board's folders, NVRAM file and config files moved to the new name, the old core file removed, the renamed Main installed (the old one kept as `MiSTer.9e88154e`), at the user's go-ahead. |
| sound | Reported to the user, 2026-10-09: sound glitches in games, on this core and the Quadra 800 core (no game or kind of glitch named yet). Found by the session, without the board (the user's wish): AWACS kept a part frame a stopped DMA channel left in its FIFO, so every frame after the next start came byte-shifted (distorted sound until another stop realigned it; a stop leaves a part frame only within the few clocks of a refill or a line fetch, about one stop in a hundred), and played 0 for a frame the channel had not delivered (a click). Decided by the session: the part frame is dropped once the channel stops, and a late frame holds the last one (MAME's and the Quadra core's EASC behaviour); `run_scsi.py` test 14 drives DMA channel 8 into AWACS and fails on the old RTL. Measured there: the FIFO lasts about three frames (68 µs at 44,100 Hz) against the DMA's line fetch, and the caches answer a DMA snoop before the CPU's next access, so starvation is unlikely. Not changed: the Quadra core (read only); its EASC holds the last sample, runs at 22,252 Hz from 33 MHz, and interrupts at half empty as MAME's, so nothing there was found wrong in its sound chip. Then on the board (the user's video of Altair 2.0's splash, build 39): every sound played at exactly half speed (the capture matches the game's own 'snd ' resources at half rate, correlation 0.99-1.00), and after about 0.6 s the splash turned to noise. MacsBug read the control register as the chime's 22,050 Hz; the board's trace (build 40, AWACS accesses added) showed Mac OS doing two read-modify-writes of it through little-endian accessors, the first setting 44,100 Hz, and our register reading back byte-swapped, so the second put 22,050 back. Decided by the session: the little-endian registers read back as written (dingusppc has the same asymmetry); byte and halfword writes are taken too (they were dropped; none seen from Mac OS). The bench replays the trace's sequence. |
| area | Asked by the user, 2026-10-09 (tired of re-rolling fitter seeds at 91 % of the ALMs, fits swinging -1.97 to -3.30 ns): build flags for the trace and for DMA channel 9, both off, and the DMA channels' line buffers made cheaper; the FPU's timing cuts left to a CPU session (`RESUME_speed.md`). Done: `TRACE` and `SOUND_IN_DMA` in `MacPPC7300.sv` (0; the modules default to 1, so the benches keep both): without the trace its records lose their load and synthesis drops them; channel 9 becomes its registers alone (ACTIVE never set: a recording program would wait for ever; it only ever recorded silence). Decided by the session: `MacPPC7300_dbdma`'s `LINE` 0 for channels 1, 2, 3, 8 and 9 (floppy, Ethernet, sound: at most 1.25 MB/s), a 4-byte buffer and a memory access a word instead of a 32-byte line; MESH's channel A keeps the line; and every channel's 256-bit write register gone (a line write takes the buffer itself, steady while it waits; a word write a 32-bit register). Build 43 (seed 1): 35,551 ALMs (85 %) against build 42's 38,228 (91 %), Grand Central 4,671 against 6,368 (channels 1: 680 to 363, 2: 497 to 350, 3: 776 to 369, 8: 476 to 333, 9: 631 to the stub), slack -2.404 ns (build 42 seed 1: -3.296), TNS -462 ns (-1,462). Gates: lint with both flag settings, `run_scsi.py` (MESH, the floppy, the sound), the 300 M lockstep (identical, 1.57 cycles an instruction, the chime through channel 8), and on the board Speedometer as build 38 (Disk 1.571), a 400K floppy opened, Ethernet's DHCP and a ping from the PC. |
| speed | Asked by the user, 2026-10-10 (the FPU's timing cuts, in the order of `RESUME_speed.md`), decided by the session on the shape: (1) the FPU's results that need no arithmetic (NaN operands, infinities, zeros, the invalid operations) are found in the cycle after the request, from the operand, control and FPSCR registers the unit already latched, while the first stage (S_MUL1, S_PREA, S_DIV0 or S_RSQ) has begun; a special result abandons that stage for S_DONE, so only an operation with such operands takes a cycle more (the FP golden programs 3.45 to 3.49 cycles an instruction, the 7300's 3.73 to 3.74: they are dense with them; ordinary code barely sees it); EX waits for `resp_valid` as before, so no hazard changes. (2) The operands' classes (`fp_cls_t`: sign, exponent zero, zero, denormal, infinity, NaN, signalling) come from the requester through ports beside the operands: the core finds them with `fp_classify` on each forwarding source, and for an lfs result still in its single format with `fp_classify_single` from the single's own fields, so lfs's conversion (the denormal's leading-zero count and shift, 4.5 ns) is no longer in front of the class. Reason: build 42's 400 worst paths were that one path (the conversion, the forwarding mux, the class tests and the special select, 16 ns); after (1) the worst was the same path by its other consumer (`fcmp`'s FPSCR[FEX] into `x_fpen` and `redir_pc`). Measured: -2.404 (build 43) to -2.074 (44) to -1.350 ns (45), the FPU gone from the 400 worst; the unit alone 3,374 to 3,294 ALMs, 72 to 75.5 MHz worst case. Not taken: `FPU_OPERAND_REG = 1` (a cycle on every FP operation) was not needed. Gates: lint, both vector files, `run_core.py`, the 300 M lockstep (identical), the board (the Speed table). |
| sound | Reported by the user, 2026-10-10, by ear on build 47: the startup chime's tone is too low, and it crackles. Found by the session: the chime is not starved. The build 48 trace shows the ROM's last chime command (11,104 bytes) done 2.35 s after the control register was set, the ROM polling the channel in 60 ms bursts meanwhile; the machine bench's WAV (`run_machine.py --wav`, `syn\wavstat.py`) plays the same chime in 2.2 s with every frame delivered on its clock (no held frames beyond the 22,050 Hz doubling), full scale, both channels smooth, so the stream reaches the codec whole and on time. The ROM's command list (`FFE00000`-`FFE00090`: six OUTPUT_MOREs of 32,768 bytes and an OUTPUT_LAST of 11,104 from `FFE000A0`) is 51,928 stereo frames with rate code 2 written to the sound control register (`00020000`): 2.36 s at the 22,050 Hz our table gives code 2 (dingusppc's `screamer_freqs`, Linux's `awacs_freqs`), 1.18 s an octave higher at 44,100. Mac OS's sounds use code 0 (44,100) and were verified at speed (build 40), so only code 2's meaning on the 7300's Screamer was in question. Settled by the user's ear, 2026-10-10: build 49 (a scratch build with code 2 played at 44,100 Hz) chimes "mostly correct"; the codec's output was also captured digitally on the board (build 50, the sound trace: every frame the ROM's, none held, the frame clock measured at 44,247 a second against the PC's clock), so the data and the clock were never at fault, only the table. Decided then: code 2 is 44,100 Hz (build 52, released). **Wrong, withdrawn the same day**: listening afresh to build 52 the user heard every sound an octave high; the table (code 2 = 22,050 Hz) had been right all along, as every measurement said, and what had made the sound seem low was the hung MT32-pi's click train. The table restored in build 54 (dated 2026-10-11); the whole trail in `MacPPC7300_sound.md`. The lesson: never change a measured hardware behaviour on an ear test made while another variable changed at the same time. The crackle: the user's MT32-pi had hung and its I2S stream was being mixed in (clicks on a 50 Hz grid in the recording); after a restart, with the Pi enabled again, the user hears the system sounds and the ROM's "100 % correct" on build 49 (2026-10-10). **Altair's startup sound** (open, not the core's): one second of buzz at the game's start, clean sounds after. Measured 2026-10-10 with the trace (build 53) and the sound trace (build 50): the Sound Manager's looping double buffer of 192 one-millisecond commands runs on time, its interrupts are taken within the millisecond, and the codec plays exactly what is in memory; the buzz segments are the Sound Manager's 8-bit expansion (a byte replicated into both bytes of both channels, as every Mac OS sound here) without the 0x80 sign flip, silence at 0x8080 and a full-scale jump at every midpoint crossing. The same from a RAM disk (the app copied there, no SCSI read during its start), so the disk path is out; the Quadra core shows the same glitch with another CPU and sound chip, so the CPU is out. It is the app's (or the Sound Manager's) conversion racing the playback at the game's start, lost on both cores; whether a real 7300 loses it is for the user's machine to tell. Parked: re-judge after the speed work. Also from this: the video timing now runs a fixed black 640 x 480 at 60 Hz while the Mac's timing is off (`MacPPC7300_swatch`'s fallback), so the framework has a picture from power-up as every other core gives it. |
| speed | Asked by the user, 2026-10-10 (the cycles-per-instruction work, `RESUME_speed.md`): the account before any cut. Decided by the session: counters in the CPU (`DSPPC604_perf`, `PERF`), read on the board through the DDR3 trace (five records every 2^23 cycles) rather than a debug readout or the 604's performance-monitor SPRs (no program on the Mac could be asked to read them during Speedometer), and in the benches as a port; every cycle classed, so the classes sum to the cycles. Measured (builds 47 and 48, the Speed table and "Where the cycles go"): on the integer tests MEM's granted cycle is the largest wait (11-25 of 100 cycles), then load-use, redirects and the divider; the FPU tests wait on the FPU 18-27; the Color tests sit in uncached frame-buffer stores 48-72. The user's real 7300/120 measured the same day: 3.0-4.5x on the CPU and FPU tests, 2.2-2.5x on Color, of which the clock is 1.71x. The user's decision after build 48: the speed work stops here and the sound issues come first; the ranked cuts are recorded for its resumption (the first needs the user's go-ahead under rule 2). Not changed: no cut was built. |
