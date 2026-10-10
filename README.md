# MacPPC7300_MiSTer

A PowerPC Macintosh core for the [MiSTer](https://github.com/MiSTer-devel) FPGA
platform. Work in progress: the CPU is built and verified, and the machine
around it (the Power Macintosh 7300/7600) has begun: the 7300's and the
7600's own ROMs run from reset through Open Firmware into Mac OS, in
simulation and on the board. The bitstream this tree builds runs the CPU and
the machine on the DE10-Nano with the SDRAM; its screen shows Mac OS's (the
Control video: with no disk yet, the grey desktop and the pointer), or, as
the OSD chooses, a debug readout of rows of squares.

`MacPPC7300` is a working name and may change.

## Status

| Piece | State |
|---|---|
| Project skeleton (MiSTer framework, Quartus project) | the template's framework, unmodified; its demo logic replaced by the machine |
| Golden-vector test bench (Verilator) | working, one command |
| DSPPC604 integer execute unit | all 11,576 real-604 vectors pass |
| DSPPC604 floating-point unit | all 25,598 real-604 vectors pass, and all 64,013 of the 7300 run (non-IEEE mode, every exception enable, the whole `frsqrte` table); 1.8 million random vectors agree with the software model |
| DSPPC604 pipeline, user-mode integer code | the same vectors pass when run as a program, XER and the integer loads and stores of the 7300 run included; random programs match dingusppc instruction for instruction |
| Floating point in the pipeline | the FP vectors of both machines pass when run as a program; FP loads, stores and the FPSCR instructions as a real 604 does them (7300 run) |
| Exceptions, supervisor state | program, FP unavailable, system call, alignment, external and decrementer interrupts; MSR and the SPRs; SRR1, DSISR, the SPR set and the bits each keeps as a real 604 delivers them (7300 run); checked in lockstep and by directed tests |
| MMU | BATs, segment registers, hardware page-table walk with R and C bits, ITLB and DTLB, `tlbie`, DSI and ISI; directed tests and lockstep with translation on |
| `lwarx`/`stwcx.`, `dcbz`, cache instructions | done |
| Caches | two 16 KB four-way caches with 32-byte lines (the 604's shape), write-back, one line port to memory, a snoop port for DMA; directed tests and the whole suite through them |
| Clock crossing to the SDRAM controller | done, checked at several clock ratios; the controller itself comes with the machine |
| Timing and area pass | in progress: 55 to 64-65 MHz so far with eleven cuts that cost no cycles, plus the FPU operand register on (2 % of floating-point cycles) to take its forwarding path off the list; the slowest families now sit at the 66 MHz line and move across it with the fitter's placement; what remains and what it would cost is in [the plan](docs/DSPPC604_plan.md) |
| Machine: the 7600's address map and device stubs | `rtl/machine/`: Hammerhead, Bandit and Chaos configuration space, Grand Central (interrupt and DMA registers, VIA with timers, NVRAM, board register) and its devices, each built as the chip behaves where Mac OS needs it (below) and otherwise answering as dingusppc's devices do; [docs/MacPPC7300_stubs.md](docs/MacPPC7300_stubs.md) lists every stub and what it leaves out |
| The ROM in simulation | the 7300's (the reference) and the 7600's each run from the reset vector in lockstep with dingusppc, Cuda answering, for 60 million instructions with no difference (2026-10-07): through Open Firmware (which waits for Cuda at 18.3 million and gets its answer), the NanoKernel's start-up and into Mac OS's 68k emulator, running in user mode from 28 million on. Before Cuda existed, 150 million instructions to Open Firmware's endless poll for it |
| Memory-test boot program | selectable in place of the ROM; passes in the bench over 1 and 6 MB and finds an injected fault |
| SDRAM controller | `rtl/machine/MacPPC7300_sdram.sv`, adapted from Sorgelig's; passes its bench against a model of the 128 MB board that checks every command and timing |
| First bitstream | `MacPPC7300.sv`: CPU at 65 MHz, SDRAM at 100 MHz, ROM upload, OSD options, debug readout on screen and UART; on the board the memory test passes at every RAM size (6-96 MB) |
| The 7600's ROM on the board | runs exactly as in simulation: the same 26,771 device writes, the last after the same 18.27 million instructions, then the same wait for Cuda (before Cuda was built) |
| Cuda (ADB, power, reset, clock, PRAM) | the real chip: a 68HC05 (`rtl/machine/MacPPC7300_hc05.sv`, checked instruction by instruction against MAME's 6805 core) running Apple's firmware 341S0060 (Cuda 2.40), behind Grand Central's VIA with a real shift register; it holds the CPU in reset until its firmware powers the machine up. The firmware is the 7300's own: read out of its chip through the VIA (`cudadump/`, 2026-10-07), byte for byte MAME's dump. In simulation the ROM's Cuda traffic goes through and the ROM runs on through the NanoKernel into Mac OS (the CPU bug the lockstep found at 24.4 million instructions is fixed: the plan's M6 section). On the board (2026-10-07) Cuda releases the CPU 1,284 ms after the machine's reset and both ROMs run through Open Firmware into Mac OS. On its ADB line the keyboard and the mouse, on its I2C lines Athens |
| Interrupts | Grand Central's events, mask and levels as MAME's and dingusppc's; the VIA is the first source (2026-10-07): the 7300's ROM runs 100 million instructions in lockstep with Mac OS's timer interrupts, its device traffic matching dingusppc's through Mac OS's start-up to where Mac OS probes MESH ([docs/MacPPC7300_plan.md](docs/MacPPC7300_plan.md), milestone I) |
| Serial console | the ESCC (a Z85C30's asynchronous mode, `rtl/machine/MacPPC7300_escc.sv`); its modem port is the MiSTer's UART, Open Firmware's console: with an NVRAM image that sets `auto-boot?` false, Open Firmware's prompt over the UART, in simulation (in lockstep, the banner byte for byte dingusppc's) and on the board (2026-10-07) |
| SCSI controllers, with empty buses | MESH (`rtl/machine/MacPPC7300_mesh.sv`) and Curio's 53CF94 (`MacPPC7300_sc53c94.sv`) as dingusppc models them, with no targets: Mac OS reads MESH's ID, sets both up and selects every target on both buses, each selection ending in a timeout and an interrupt; in simulation the 7300's ROM runs 450 million instructions in lockstep through that probing, its SCSI traffic matching dingusppc's, and on the board Mac OS runs through it as in the simulation (milestone E, 2026-10-07; [docs/MacPPC7300_plan.md](docs/MacPPC7300_plan.md)) |
| Disks (milestone S, in progress) | MESH's information phases, FIFO and DMA; DBDMA (`MacPPC7300_dbdma.sv`, MESH's channel A) through the CPU's snoop port; SCSI disks on IDs 0 and 1 (`MacPPC7300_scsidisk.sv`) from the SD card's images through hps_io's block devices (the OSD's `SC0`/`SC1`, the Mac SCSI family's slot layout). `python verilator\run_scsi.py` drives them the way the ROM and Mac OS's driver do (programmed I/O and DMA reads, DMA writes, the card's blocks checked): passes. On the board Mac OS 7.6.1 boots from its image to the Finder with all its extensions, Open Transport included (2026-10-08: milestone S done), and shuts down from the keyboard's power key (the PC keyboard's Menu key); since 2026-10-08 a shut-down machine (Mac OS or Linux) is off, black, until the OSD's Reset or the power key starts it. On the way: the bus error at the welcome screen was the floppy controller's stub, the first "Starting Up..." stop the monitor sense lines (the Control driver's DDC probe read its own driven lines back high), the second Open Transport's AppleTalk waiting for LocalTalk's line (the ESCC's synchronous mode's sync/hunt). Mac OS 8.5, 8.6 and 9.1 start from their images to the Finder too (2026-10-08, build 20): their grey screen was their disk driver's SDTR (Apple's 8.1.2 and 8.1.3), which the disks now answer with offset 0, and MESH's bus free, which now lets ACK go under ATN (the 8.6 image then starts BeOS R4.5's loader from its Startup Items; it has no BeOS partition) |
| NVRAM and clock | Grand Central's NVRAM kept on the SD card (an 8 KB .nvr on block slot 2, `MacPPC7300_nvsave.sv`); Cuda's clock from the MiSTer's RTC |
| Sound | AWACS (`rtl/machine/MacPPC7300_awacs.sv`) and its DMA channels 8 and 9: the startup chime plays from the ROM by DMA, bit-exact in simulation (`--wav`), to the MiSTer's audio outputs. On the board the chime and Mac OS's sounds are right by the user's ear (2026-10-10, build 49 and after): the codec's rate code 2 plays at 44,100 Hz on a real 7300, not the 22,050 of the emulators' tables |
| Serial, Ethernet, NMI, clock | the ESCC's interrupts (both channels); MACE (`MacPPC7300_mace.sv`) with its cable unplugged (frames sent by DMA end in loss of carrier); Cuda's NMI on Grand Central's source 14 (Command-Menu: MacsBug, or the ROM's debugger); Cuda's clock set from the MiSTer's RTC |
| Floppy controller | the SWIM3 (`rtl/machine/MacPPC7300_swim3.sv`) as dingusppc models it, with an empty Superdrive: the ROM's .Sony driver finds the chip and installs, which Mac OS 7.6.1's System requires (it dereferences the driver's variables while loading: with the chip stubbed to read 0 that was the "bus error" at the welcome screen). Floppy disks (2026-10-08, build 21): an image (raw or DiskCopy 4.2; 400K, 800K, 720K, 1440K) from the OSD's "Insert floppy disk" (hps_io slot 6, `MacPPC7300_fdblk.sv`) read at the level of its sectors as dingusppc's SWIM3 reads one, into memory by DMA channel 1; read only (disks show as locked). `run_scsi.py` test 13 reads a 1440K DiskCopy image and an 800K raw one |
| Video | the Control video controller (registers, Swatch's timing), RaDACal (colour table, hardware cursor), the Athens clock chip on Cuda's I2C, the 4 MB VRAM in the HPS's DDR3, the scan-out through the framework's scaler; the monitor an OSD choice (Apple's 16-inch, 832 x 624, or 13-inch, 640 x 480). In simulation the ROM runs in lockstep through Mac OS's video driver, every video access as dingusppc's, and the frames match dingusppc's pixel for pixel at both sizes; on the board Mac OS's screen (milestone V, 2026-10-07) |
| Keyboard and mouse | an ADB keyboard and mouse on Cuda's line (`rtl/machine/MacPPC7300_adb.sv`), from the MiSTer's keyboard and mouse: Cuda's own firmware talks to them in `run_cuda.py` (registers 0, 2 and 3, a key, a mouse move, an address and handler change, SendReset); on the board the pointer follows the mouse over Mac OS's screen and Open Firmware takes typed lines from the keyboard (milestone K, 2026-10-07). Keys now and then lost or changed into others were the keyboard's clock crossing of hps_io's key code (fixed 2026-10-08, build 15) |
| Game controllers | the Quadra 800 core's ADB controllers from the MiSTer's joystick 0 (OSD "ADB controller (on reset)", "Stick moves pointer"): Gravis MouseStick II, Firebird, Mac GamePad, SideWinder 3D Pro, with ADB's address collisions; Cuda's firmware takes their answers in `run_cuda.py`; on the board Mac OS 7.6.1 separates a GamePad from the keyboard and a MouseStick from the mouse (2026-10-08, build 7); the controllers themselves are the user's to try |
| Serial MIDI, MT32-pi, PPP, printer | as the Quadra 800 core: the modem port's TRxC clock a MIDI interface's (31,250 bit/s), the UART's MIDI mode, the MT32-pi on the user port (its OSD page, popups, LCD, audio), CTS and RTS for PPP and the Main's printer daemon; `run_escc.py` measures the rates (2026-10-08, build 8); the devices are the user's and the Discord testers' to try |
| CD-ROM, BlueSCSI Toolbox | the CD-ROM drive at SCSI ID 3 (slot 4: ISO, TOAST, CUE, BIN, CHD), speaking the Quadra 800 core's contract with the Main's Mac CD layer, its audio (`MacPPC7300_cdaudio.sv`) mixed after AWACS; the Toolbox's file sharing (ID 0, slot 3) and CD changer (ID 3, slot 5) as the Mac LC core's; `run_scsi.py` checks them against a model of the Main (2026-10-08, build 8). Needs the Main branch `Mac-ppc-enhancements` (macppc7300 in the Mac family); with the official Main there is no CD drive. On the board with that Main (2026-10-08): ISO and CUE/BIN discs mount and run, CD audio plays from the right tracks, BlueSCSI SD Transfer downloads and uploads; the CD changer app does not find the changer (parked) |
| Ethernet | MACE's frames through two rings in DDR3 (`MacPPC7300_enet.sv`, the DDR3 port shared with the video by `MacPPC7300_ddrarb.sv`) to the Main's interface (OSD "Ethernet (on reset)": Off or the interface, eth0, eth1, wlan0, tap0, one option since 2026-10-08; the Main branch's `mac_eth.cpp`); receive into DMA channel 3 as Linux's `mace.c` reads it (2026-10-08, build 10). On the board with the Main branch (build 17): Mac OS 7.6.1's TCP/IP takes an address by DHCP, Cyberdog loads web pages from the LAN, the LAN pings it, Fetch reaches FTP servers; it took MACE's internal loopback (the driver's self-test), the FCS, and Grand Central's DMA status bits (s5 on the transmit channel, an INPUT_MORE ended by the frame and s6 on the receive one). Off, MACE's cable stays unplugged as before |

The first full build of the core (2026-10-06: the CPU at 65 MHz, the
machine, the SDRAM controller at 100 MHz, the debug readout, the MiSTer
framework), Quartus 17.0, slow 100 C model; this is the number that counts:

| Build | ALMs | RAM blocks | DSP blocks | CPU clock closes at |
|---|---|---|---|---|
| `MacPPC7300` with the memory test, 2026-10-06 | 24,757 of 41,910 (59%); the CPU 13,883, the machine 2,673, the SDRAM controller 367, the readout 455 | 144 of 553 (26%) | 40 of 112 (36%) | 64.59 MHz (65 MHz asked: slack -0.099 ns); memory 107.3 MHz (100 asked) |
| The same with fourteen readout rows | 25,051 (60%) | 144 | 40 | 64.64 MHz (slack -0.086 ns); memory 110.7 MHz |
| With Cuda, 2026-10-07 | 25,521 (61%) | 153 | 41 | 61.26 MHz (slack -0.939 ns; every failing path inside the CPU, decode into the branch target buffer); memory 107.8 MHz. Runs on the board at 65 MHz |
| With Grand Central's interrupt | 25,379 (61%) | 153 | 41 | 62.70 MHz (slack -0.565 ns); memory 107.7 MHz. Runs on the board at 65 MHz |
| With the ESCC and the NVRAM loader | 26,019 (62%) | 153 | 41 | 62.31 MHz (slack -0.666 ns); memory 104.1 MHz. Runs on the board at 65 MHz |
| With MESH and Curio | 24,489 (58%) | 153 | 42 | 63.03 MHz (slack -0.481 ns); memory 109.5 MHz. Runs on the board at 65 MHz |
| With the Control video | 26,874 (64%) | 165 | 46 | 64.47 MHz (slack -0.127 ns); memory and video 113.0 MHz. Runs on the board at 65 MHz |
| With the ADB keyboard and mouse | 26,869 (64%) | 166 | 46 | 64.81 MHz (slack -0.046 ns); memory and video 109.9 MHz. Runs on the board at 65 MHz |
| With the disks (MESH's data phases, DBDMA, the SD card's images) and the SWIM3 (the committed tree, 2026-10-07) | 28,437 (68%) | 168 | 46 | 60.4 MHz (slack -1.172 ns); memory and video 98.4 MHz (slack -0.167 ns). Runs on the board at 65 MHz |
| With AWACS, DMA channels 2, 3, 8, 9, MACE, the ESCC's interrupts, the NMI, the clock, the sense lines as wires (2026-10-08) | 31,825 (76%) | 168 | 46 | 61.7 MHz (slack -0.828 ns); memory and video meet 100 MHz. Runs on the board at 65 MHz |
| With the ESCC's synchronous mode, the NVRAM on the SD card, the Scale option (2026-10-08, build 5) | 31,680 (76%) | 168 | 46 | 59.6 MHz (slack -1.469 ns); memory and video meet 100 MHz. Runs on the board at 65 MHz: Mac OS 7.6.1 to the Finder |
| With the board reset with the CPU (build 6) | 32,301 (77%) | 168 | 46 | 60.6 MHz (slack -1.108 ns). Runs on the board at 65 MHz: Restart works |
| With the ADB game controllers (build 7, 2026-10-08) | 31,898 (76%) | 168 | 46 | 62.1 MHz (slack -0.729 ns). On the board: the keyboard and mouse beside a GamePad and a MouseStick |
| With serial MIDI, the MT32-pi, CTS and RTS, the CD-ROM and its audio, the BlueSCSI Toolbox (build 8) | 33,762 (81%) | 178 | 48 | 63.1 MHz (slack -0.472 ns). On the board with the official Main: Mac OS 7.6.1 from disk 0 as before (no CD drive), Open Firmware boots it with a blank NVRAM; 256 colours, thousands and millions all shown right at 832 x 624 |
| With the 12-inch monitor (build 9) | 33,460 (80%) | 178 | 48 | 60.3 MHz (slack -1.287 ns; placement). On the board Mac OS 7.6.1 at 512 x 384 |
| With the Ethernet bridge (build 10) | 34,115 (81%) | 182 | 48 | 62.4 MHz (slack -0.852 ns). On the board with Ethernet off: Mac OS 7.6.1 to the Finder as before |
| With the SCSI trace in DDR3 (build 11) | 35,007 (84%) | 182 | 48 | 62.2 MHz (slack -0.683 ns). On the board with the Main branch: the CD-ROM (ISO, CUE/BIN with audio) and the Toolbox's file sharing work |
| With MACE's loopback and the bus trace (build 12) | 35,104 (84%) | 191 | 48 | 59.9 MHz (slack -1.310 ns) |
| The same with `ALLOW_POWER_UP_DONT_CARE OFF` (build 13) | 35,556 (85%) | 192 | 48 | 60.9 MHz (slack -1.023 ns) |
| With the FCS, the DMA and ADB records (build 14) | 35,272 (84%) | 192 | 48 | 60.8 MHz (slack -1.074 ns) |
| With the keyboard's clock crossing fixed, s6 on the Ethernet receive channel (build 15) | 35,360 (84%) | 192 | 48 | 58.6 MHz (slack -1.669 ns). On the board: 186 characters typed through the Remote, none lost (about one in fifty before) |
| With the DMA fetch and stop records (build 16) | 34,828 (83%) | 192 | 48 | 60.8 MHz (slack -1.157 ns) |
| With s5 on the Ethernet transmit channel and INPUT_MOREs ended by the frame (build 17) | 35,708 (85%) | 192 | 48 | 61.7 MHz (slack -0.949 ns). On the board: Ethernet works (DHCP, web, ping, FTP) |
| With the DMA's quads reaching MACE and LOAD_QUAD's value written back (build 18) | 35,039 (84%) | 192 | 48 | 62.3 MHz (slack -0.659 ns). On the board: the Ethernet driver's LOAD_QUADs read XMTRC 00, XMTFS 80, IR 03; 60 pings of 1,400 bytes, none lost; the MESH trace found Mac OS 8.6's stall |
| With SDTR answered, MESH's bus free letting ACK go, the MESH interrupt records (build 20) | 35,089 (84%) | 192 | 48 | 60.3 MHz (slack -1.200 ns). On the board: Mac OS 8.5, 8.6 and 9.1 start from their own images to the Finder (8.5 and 9.1 then say the clock is not set: Mac OS's own 2019 limit) |
| With the floppy drive: SWIM3 reading images, DMA channel 1 (build 21) | 35,626 (85%) | 193 | 49 | 61.7 MHz (slack -0.950 ns). On the SCSI bench: DiskCopy and raw images read; the board test waits for the board |
| With MESH's reselection commands setting no command done (build 22) | 35,914 (86%) | 193 | 49 | 59.6 MHz (slack -1.448 ns). On the board: Debian 7.11 finds its disk and boots |
| With LUN 0 only, 32-bit pixels through the colour table, 120 MB, one Ethernet option (build 24) | 35,618 (85%) | 195 | 49 | 59.5 MHz (slack -1.466 ns). On the board: Debian 7.11 sees one disk and one CD, its console readable |
| With Hammerhead's RAM banks, the options on reset, the power-off (build 26) | 35,525 (85%) | 195 | 49 | 57.7 MHz (slack -1.943 ns). On the board: Mac OS 7.6.1 sees 120 MB; Shut Down turns the machine off, the Menu key on; 9.1 and Debian at 120 MB start; 1440K floppies read, 400K and 800K do not |
| With GCR sectors as Apple's driver wants them, the clock counted on (build 28, the third release) | 35,642 (85%) | 195 | 49 | 59.4 MHz (slack -1.462 ns). On the board: 400K, 800K and 1440K floppies open in the Finder; the clock right after two minutes off |
| With the device access from a register in the machine (build 29, the speed session) | 36,743 (88%) | 195 | 49 | 60.7 MHz (slack -1.092 ns, total -12 ns against -186: the device family is gone; what leads is the data cache's store-hit write). On the board: Mac OS 7.6.1 to the Finder in the same time as build 28; Speedometer 4.02's first numbers (`docs/MacPPC7300_plan.md`, Speed) |
| With the 128 KB L2 cache (`MacPPC7300_l2`, build 30) | 37,883 (90%) | 329 | 49 | 57.5 MHz (slack -2.013 ns: the cache's answer into `wb_result`, placed 1.7 ns worse under the L2's pressure). On the board: Speedometer's CPU tests 2-3 % faster, the disk 11 %, the colour tests 6-10 % |
| With the data cache's tag-decided writes landed a cycle later (build 31) | 37,765 (90%) | 329 | 49 | 64.0 MHz (slack -0.321 ns, total -1.9 ns). On the board: the Finder's menu bar at 86 s (97-101 s before the L2); Speedometer as build 30 but Towers and Permutations 8-10 % slower (a request right after a store hit waited a cycle) |
| The same at 70 MHz (build 32) | 38,841 (93%) | 329 | 49 | 62.2 MHz (slack -1.766 ns at 70 asked). On the board: Mac OS 7.6.1 and 9.1 to the Finder, Speedometer's every number 8 % above build 31's, the clock right: 70 MHz is the clock from here |
| With the cache's wait narrowed to the pending write's set, a read-only cache off the write-back muxes, the FPU's operand register off and `fmul` a cycle shorter, 70 MHz (build 36, the fourth release; build 33, the first form of the narrowed wait, took an ungranted request when a snoop and a request met and bombed on the board; the core bench's snoop storm catches that class now) | 38,452 (92%) | 329 | 49 | slack -2.556 ns at 70 asked (the forwarding into the FPU's first stage, which the operand register was there for). On the board: a clean run; CPU 2.504, Math 106.8, FPU 3.570 against a Quadra 650, Towers and Permutations back; the FP golden program 3.45 cycles per instruction |
| Build 36 renamed MacPPC7300 (from PPCMac), the disks' INQUIRY as the Mac LC core's (build 38, the fifth release) | 38,452 (92%) | 329 | 49 | slack -1.970 ns at 70 asked (the same logic, another fit). On the board: Speedometer as build 36 (CPU 2.501, Disk 1.570, Math 106.8, FPU 3.560), Mac OS 9.1, a second disk on ID 1 |
| AWACS reading back as written (Mac OS's sounds at their own speed), the trace and the sound-input DMA channel left out by build flags, the slow DMA channels a word at a time (build 43) | 35,551 (85%) | 322 | 49 | slack -2.404 ns at 70 asked (build 42, the same CPU at 91%: -3.296 with the same seed). On the board: Speedometer as build 38 (Disk 1.571), a floppy, Ethernet |
| The FPU's special results (NaN, infinity, zero operands) found a cycle after the request (build 44) | 35,657 (85%) | 322 | 49 | slack -2.074 ns at 70 asked (the FPU's select gone from the 400 worst paths; the worst is lfs's conversion forwarded into `fcmp`'s exception trap) |
| The operands' classes found in the core beside lfs's conversion, from the single's own fields (build 45) | 35,725 (85%) | 322 | 49 | slack -1.350 ns at 70 asked (no FPU path among the 400 worst; the D-cache's tag RAM into the I-cache's PLRU leads). On the board: Speedometer as build 38 |
| S_LZC skipped where the FPU knows its leading-zero count: `fmul` 6 cycles, `fdiv` 33, `frsp` and `fctiw` 7 (build 46) | 35,238 (84%) | 322 | 49 | slack -2.249 ns at 70 asked, seed 1 (the fetch address into the I-cache's way RAMs, the same family placed worse). On the board: Math 108.1 (106.8), FPU 3.60 (3.57) |
| The performance counters (`DSPPC604_perf`, `PERF = 1`) and the trace on, a measuring build (build 47) | 37,550 (90%) | 322 | 49 | slack -2.301 ns at 70 asked. On the board: Speedometer as build 46 (CPU 2.505, Math 108.1, FPU 3.60); the counters into the trace every 2^23 cycles |
| The counters refined to 28 (MEM's wait split four ways, doubles counted; build 48) | 37,402 (89%) | 322 | 49 | slack -2.077 ns at 70 asked. On the board: Speedometer as build 46 (CPU 2.503, Math 108.0, FPU 3.61); the whole run's account in `docs/MacPPC7300_plan.md`, "Where the cycles go". A release build keeps `PERF = 0`, `TRACE = 0` |

On the board (DE10-Nano, 128 MB SDRAM) the memory test passes at every RAM
size the OSD offers (6 to 96 MB, three or more passes each, no error) at
65 MHz, the 7600's ROM ran exactly as in simulation before Cuda, and with
Cuda both ROMs run through Open Firmware into Mac OS (2026-10-07). The
slow 100 C model is pessimistic for a board on a desk: the build with Cuda
misses 65 MHz there by 0.94 ns and runs.

Each block synthesised on its own for the DE10-Nano's FPGA with Quartus
17.0 (`syn\check.py`), constrained to 75 MHz:

| Block | ALMs | DSP blocks | Worst-case Fmax |
|---|---|---|---|
| The whole CPU (pipeline, FPU, exceptions, SPRs, MMU, two 16 KB caches), after the update-form fix of 2026-10-07 (the sequencer's third operation for an indexed load with rD = rB) | 15,711 (37%), 77 RAM blocks | 7 | 64.96 MHz (the same slowest paths) |
| The same after the timing pass's eleven cuts and the FPU operand register (2026-10-06) | 15,678 (37%), 77 RAM blocks | 7 | 63.7-64.8 MHz (two fits) |
| The same when the caches were first added | 14,234 (34%), 77 RAM blocks | 7 | 55.2 MHz |
| The same before the caches | 12,049 (29%) | 7 | 61-65 MHz (three runs) |
| The same before the MMU | 10,781 (26%) | 7 | 69.5 MHz |
| The integer pipeline alone, before the FPU was connected | 3,208 (8%) | 3 | 78.6 MHz |
| Floating-point unit alone | 3,303 (8%) | 4 | 73.5 MHz |

So the CPU is above its 50 MHz floor and below the 66 MHz target, and the
timing pass is in progress (the plan's M5 step 4 has every measurement).
The Fmax figure swings by 2-3 MHz between fits of near-identical designs;
the slowest paths, taken apart cell by cell, are the measure. What sets the
clock now is the data cache: its answer, made in the cycle after the
request from the tag RAM's output (2.5 ns of the 13.3), and its request
address for the second word of a misaligned access; then the cache's hit
decision through the fetch handshake into the redirect. The register files
and SPRs are still flip-flops, the main area to be had.

## Decisions that are locked in

These were agreed before any RTL was written. Change them deliberately, here,
not by drift.

**Platform**

- MiSTer on the DE10-Nano (Cyclone V `5CSEBA6U23I7`), built with Quartus 17.0.x.
- `sys/` is the MiSTer framework exactly as in Template_MiSTer (commit
  `3ea1134`, 2026-08-26). It is never edited here.

**Machine**

- First target: the Power Macintosh 7600 (the 7300/7500/7600/8500/9500 board
  family), with its single internal SCSI controller. The 7300 is the same
  machine to this core: dingusppc builds both from one definition with the
  same devices (`machinetnt.cpp`), the 7300 defaulting to a 604e.
- The real machine we measure is the 7300 (changed 2026-10-06: the 7600 no
  longer powers on). So the reference ROM becomes the 7300's
  (`ppctest/runs/my7300.rom`): version `077D.34F2`, header checksum
  `960E4BE9`, the "7300/7600/8600/9600" ROM, which later 7600s carried too.
  The 7600's own ROM (`my7600.rom`: `077D.28F2`, checksum `9630C68B`, the
  "7200/7500/8500/9500 v2" ROM, Open Firmware 1.0.5) stays as a second test:
  M6 and Cuda were proven on it. Since 2026-10-07 the benches
  (`run_machine.py`, `--rom7600` for the other), `machref` (`pm7300`) and
  the board's `boot.rom` use the 7300's ROM. The two share Open Firmware
  1.0.5 and the 68k emulator byte for byte; `rom7300/README.md`
  (with the disassembly) says where the rest differs.
- The machine's own plan, with its milestones and rules, is
  [docs/MacPPC7300_plan.md](docs/MacPPC7300_plan.md).
- Long-term goal: the Apple/Bandai Pippin (a PowerPC 603).
- This CPU will be a good deal slower than a real 604 (see below), so the
  first machine may yet change to something more modest. Nothing
  machine-specific goes into the CPU.

**CPU**

- The CPU is `DSPPC604`: a 32-bit PowerPC 604-class core. Standard PowerPC
  user and supervisor instruction set, hardware page-table walk, no POWER
  instructions.
- In-order and pipelined from the start. No out-of-order execution, no
  register renaming. Multi-cycle work (multiply, divide, floating point)
  happens in execute units behind a request/response handshake, so the
  pipeline never needs special cases for them.
- The floating-point unit is a separate module with its own request/response
  interface. It can be tested alone, the integer side alone, and the two
  together. It is meant to be reused by later CPU models.
- The execute units hold no architectural state. Whatever wraps them (the test
  wrapper today, the pipeline later) owns the registers and commits results.
- Each CPU model gets its own named version: `DSPPC604` first, then
  `DSPPC603` (the Pippin's CPU: software TLB reload), `DSPPC750` (G3) and
  `DSPPC601` last. A new model may start from an existing one or instantiate
  its modules; module and file names carry the model they belong to
  (`DSPPC604_fpu`, `DSPPC604_int_unit`, ...).
- Built-in caches: yes. A pipelined CPU on MiSTer memory needs instruction and
  data caches in block RAM. The cache line is 32 bytes, as on the 604, 603 and
  750, because `dcbz` makes that size visible to software. Anything else that
  reads or writes memory (DMA, the HPS) goes through the CPU's snoop port
  first; that is the whole coherence protocol.
- Clock target: 66 MHz, 75 MHz if it can be had; 50 MHz is the floor.
- Results the architecture leaves undefined follow the real chip where we have
  data. Divide by zero and `0x80000000 / -1` return what a real 604 returns.

**Language and tools**

- SystemVerilog, limited to what both Verilator 5.020 and Quartus 17.0 accept:
  `logic`, `always_ff`/`always_comb`, packages, enums, packed structs. No
  interfaces, no classes.
- No vendor primitives inside the CPU. Multipliers and memories are inferred.
- Verilator is the verification tool. The RTL is kept clean under `-Wall`.

**What counts as correct**

- Real hardware outranks every emulator. Of the emulators, dingusppc is
  trusted most; QEMU is the more careful floating-point reference; MAME is not
  used for floating point.
- The golden data is 37,174 single-instruction vectors recorded twice,
  bit-identically, on a real PowerPC 604 (PVR `00040303`) in a Power Macintosh
  7600: `ppctest/runs/results_604_run2.csv`; and the 79,624 vectors of the
  version-4 set (those again, plus 39,025 the software model had predicted
  and 3,425 with no prediction) recorded on a 604 of the same revision in a
  Power Macintosh 7300, identical to the 7600 where they overlap:
  `ppctest/runs/results_604_7300_of_run1.csv`. The same run's second stage,
  10,772 supervisor-mode sequences recording what every kind of exception
  saves, which SPRs and opcodes exist and which bits each register keeps, is
  `sresults_604_7300_of_run1.csv`.

**Memory**

- Main memory lives on the MiSTer SDRAM module, the 128 MB one (the board
  here has it). The machine's installed RAM is a core option: 6, 16, 24, 48,
  64, 96 or 120 MB (changed 2026-10-06 from 6, 16, 24, 32, 64, 128: the
  ROM takes the module's top 4 MB, so 124 MB is the most a 128 MB module
  allows; 6 MB is the Pippin's; 120 added 2026-10-08, the user's choice for
  the largest). The OSD's memory-test boot is gone (2026-10-08, the user);
  `MacPPC7300_bootrom` stays for the bench. The caches fill their lines from the SDRAM, so the cache
  line-fill bus is designed for that controller. 128 MB of RAM would need the
  ROM elsewhere (the HPS's DDR3 or a second SDRAM board): left out for now.

**Still open**

- Whether part of the CPU could run on the DE10-Nano's ARM. Not planned; the
  floating-point unit's request/response boundary is where such a split would
  go if it is ever needed.
- Which machine the first release actually models.

## How fast will it be

An in-order core at 66-75 MHz executes somewhere around one instruction per
1.3-1.6 clocks once caches are warm. That is the territory of a Power Macintosh
6100/60 or a Pippin, and roughly a third of a real 7600/120, whose 604 issues
several instructions per clock.

Measured (2026-10-09, build 36 at 70 MHz with the 128 KB L2, Speedometer
4.02 on Mac OS 7.6.1; the whole table and the conditions are in
`docs/MacPPC7300_plan.md`, "Speed"): CPU 2.50, Disk 1.56, Math 106.8 against a
Quadra 605 = 1.0; Dhrystones 46,559 a second; the FPU 3.57 against a Quadra
650; Mac OS 7.6.1 from the core's load to the Finder's menu bar in 86 s. The
lockstep runs of the 7300's ROM retire 1.57 cycles an instruction with the L2
(2.2 before it); the integer golden program 1.85, the floating-point one 3.45.
The user's real Power Macintosh 7300/120 (a 604 at 120 MHz, 256 MB) ran
the same Speedometer on 2026-10-10: CPU 7.800, Disk 3.544, Math 320.232;
Dhrystones 162,592 a second; the FPU 14.33; Color 3.135. Against build 48
that is 3.0-4.0x on the integer tests, 3.0-4.5x on the FPU's, 2.2-2.5x on
Color, with the clock 1.71x of ours: the rest is cycles per instruction,
accounted in `docs/MacPPC7300_plan.md`, "Where the cycles go" (the
performance counters of builds 47 and 48): every load and store holds the
pipeline a cycle in MEM, then load-use, redirects, the divider and the
non-pipelined FPU.

## What the real 604 turned out to do

Measured on the chip, and reproduced by the RTL:

- Divide by zero returns the dividend shifted left four bits, with the low
  four bits 0000 for a negative signed dividend and 1111 otherwise.
  `0x80000000 / -1` returns 1.
- `fres` is not an estimate. It is a full divide of 1.0 by the operand,
  rounded to single precision, with every status bit a divide would set.
- `frsqrte` is a 32-entry table with seven fraction bits, indexed by the low
  exponent bit and the top four fraction bits; every entry is measured.
- `fctiw` and `fctiwz` write `FFF80000` to the upper word of the result, with
  the lowest bit set when a negative operand converts to zero. `mffs` writes
  the same upper word.
- When a disabled overflow delivers infinity or the largest number, FPSCR[FR]
  is left as the rounding of the significand set it.
- Single-precision instructions clear the 29 payload bits of a NaN result
  that a single cannot hold.
- Non-IEEE mode (FPSCR[NI]) flushes a result that would be denormalised to a
  signed zero and calls it an inexact underflow; denormal operands are
  computed with as usual, whatever the manual's table says.
- An enabled underflow or overflow in single precision whose scaled
  exponent still does not fit a double (the architecture: undefined) delivers
  the exponent field with bit 10 as bits 11 and 10 of the wider internal
  exponent XORed, and classes the result as normal.
- `stfs` denormalises for every exponent of 896 or less, so anything below
  the single denormal range, double denormals included, stores a signed zero.
- XER keeps `E000FF7F` (bits 16-23 too); MSR keeps `0005FF77` (bit 29, PM,
  is implemented); SRR0 keeps bits 0-29, SDR1 `FFFF01FF`, EAR `8000003F`,
  PIR four bits, the BATs `FFFE1FFF` and `FFFE007B`.
- The SPRs it has: 1, 8, 9, 18, 19, 22, 25, 26, 27, 268, 269, 272-275, 282,
  284, 285, 287, 528-543, 952-955, 959, 1008, 1010, 1013, 1023. Any other
  number is an illegal instruction in user mode as in supervisor mode, not a
  privileged one as the manual says. `mfspr` 268/269 reads the time base in
  user mode.
- `stwcx` without the record bit is illegal; other instructions without a
  record form ignore bit 31; `tlbia`, `tlbld`, `tlbli` and an opcode-17 word
  without bit 30 are illegal; `FFFFFFFF` is a valid `fnmadd.`.
- SRR1 holds only the MSR bits for `sc`, FP unavailable, alignment and DSI;
  a pending enabled FP exception taken at a later instruction sets SRR1[15].
  The alignment DSISR carries rD and rD - 1 (8 and 7 for `dcbz`) where the
  architecture says rD and rA. Trace saves `40000000` and the MSR, the IABR
  the breakpoint's own address.
- `lwarx`/`stwcx.` on a cache-inhibited page take no DSI; `dcbz` there is an
  alignment exception; a load beyond the installed memory returns 0 and no
  exception.

Apart from these, the 604 follows the architecture manual to the bit. The 34
vectors where it differs from dingusppc are 24 undefined divides and 10
`fmuls` cases where the chip is simply correctly rounded. The RTL reproduces
all of the above; `docs/DSPPC604_plan.md` has the details and what the
tests still do not cover.

## Running the tests

```
python verilator\run.py
```

Builds the Verilator model (under WSL on Windows) and replays every golden
vector through the execute units, printing pass counts per instruction and
each mismatch with the fields that differ. Useful options: `--only int`,
`--only fp`, `--name ADDE,DIVW`, `--show 20`, `--variants`, and
`--csv ppctest\runs\results_604_7300_of_run1.csv` for the 7300 run (its
loads, stores and moves to and from XER and FPSCR are reported as
unimplemented here and run by `run_core.py`).

Divides whose result the architecture leaves undefined are counted apart from
the rest, so they can never hide a real failure or be hidden by one.

```
python verilator\run_core.py
```

Tests the pipeline, and the memory path behind it, seven ways:

1. The real-604 integer vectors, assembled into one program and run with and
   without random bus wait states.
2. The real-604 floating-point vectors, the same way; then both halves of the
   7300 run, whose loads and stores get a buffer each.
3. Random floating-point programs (arithmetic, loads, stores, FPSCR
   instructions) with the state `fpmodel.py` expects after every instruction.
4. Each exception once, with what its handler must find; the update forms,
   the indexed loads with rD = rB first (cache off, miss, hit, with and
   without wait states); address translation with every cause of DSI and
   ISI and the page table's R and C bits; `lwarx`/`stwcx.`, `dcbz` and the
   cache instructions; the caches (evictions, write-back, every cache
   instruction and HID0 bit seen through a cache-inhibited alias,
   self-modifying code, DMA through the snoop port); and a loop with known
   results under thousands of external and decrementer interrupts.
5. Random programs in lockstep with dingusppc's interpreter
   (`verilator/ref` builds it as a library from `..\dingusppc`), including
   supervisor instructions, mode switches and exceptions: the registers and
   MSR are compared after every instruction and memory at the end. Then the
   same with address translation on, page faults included.
6. The memory port carried across a clock boundary, at several clock
   ratios.
7. The SDRAM controller (`rtl/machine/MacPPC7300_sdram.sv`) behind the clock
   crossing, against a behavioural model of the 128 MB board in
   `verilator/sdram_main.cpp` that holds the data and checks every command
   and timing: the power-up sequence, tRCD, tRP, tRAS, tRC, tWR, tRFC,
   refresh at 7.8 us, bus turnaround; random line and word requests and a
   ROM upload, every read checked and the whole 128 MB compared at the end.

`--seeds N` runs more random programs.

```
python verilator\run_machine.py --max-instr 30000000 --progress 1000000
python verilator\run_machine.py --boot memtest --memtest-passes 2
```

Runs the whole machine (`MacPPC7300_system`: the CPU, the 7600's address map and
device stubs, the clock crossing, and a software memory in its own clock
standing in for the SDRAM) on the 7300's ROM (`--rom7600` for the 7600's,
`--rom FILE` for any) from the reset vector, in
lockstep with dingusppc: every device read returns the same value to both
(the reference has no devices; it is handed what the machine answered), and
the registers and MSR are compared after every instruction. About 400,000
instructions a second. `--dev-log FILE` writes every device access;
`verilator\machref` runs dingusppc's whole 7300 (all its devices, headless)
and writes the same log, and `verilator\machref\devdiff.py` compares the two
to show where the stubs answer differently. The second command runs the
memory-test boot program instead of the ROM (1 MB unless `--ram`;
`--mem-fault ADDR` must be found).

The machine bench starts with Cuda's cold start: Cuda holds the CPU in
reset until its firmware has powered the machine up, 5.4 million cycles
(the bench runs Cuda's clock fast while it waits; 1.28 s on the board).

```
python verilator\run_machine.py --max-instr 145000000 --frame-at 141000000 --frame-out f.ppm [--monitor 16]
```

```
python verilator\run_gui.py [--monitor 16|13] [--rom FILE | --rom7600] [--nvram FILE] [--ram MB] [--pause]
```

The machine in a window, with the framework the other cores' Verilator
benches use (Dear ImGui, SDL2, OpenGL; `verilator/sim/`, the template's
files as they are), to watch it run (`gui_main.cpp`, `make gui`; from
Windows it runs in WSL and the window comes up through WSLg). The Control
window has RUN, reset and stepping, the frame counter and the machine's
frames a second (its share of real time times its refresh rate, measured
once it scans out), the speed in simulated MHz and instructions a second;
the Machine window the pc, MSR and counts; the Video window the Control
video's picture with a zoom; the Debug log what happens and what the
machine sends on the modem port, with a line to type at it (Open
Firmware's console with `--nvram syn\nvram_of_prompt.bin`). No lockstep:
`run_machine.py` is the bench that checks. It runs at about 0.6 MHz, 0.9%
of real time, 260,000 instructions and 0.67 of the machine's frames a
second; Mac OS turns the video on at about 128 million instructions, eight
minutes in.

The Control video: the bench models the VRAM's DDR3 port and writes the
picture's next whole frame after N instructions as a PPM (PNG if the name
ends in .png; `--frame-every N` again every N instructions); `--monitor 16`
makes the sense lines report Apple's 16-inch RGB (832 x 624) instead of
the 13-inch (640 x 480, dingusppc's default). `machref --frame-at N
--frame-out FILE [--set mon_id=MacRGB16in]` writes dingusppc's frame to
compare (Mac OS draws its screen at about 131 million instructions in
dingusppc, 3.5 million earlier here).

```
python verilator\run_machine.py --nvram syn\nvram_of_prompt.bin --serial-in "1 2 + ." --serial-stop
```

Open Firmware on the modem port. `--nvram` loads an 8 KB image into Grand
Central's NVRAM during reset; `syn\nvram_of_prompt.bin` is the one Open
Firmware writes into a blank NVRAM, with `auto-boot?` set false, so it
stops at its prompt on its console, `ttya`, the modem port. The bench has a
terminal on that port (38,400 baud unless `--serial-baud`): it prints what
the machine sends (`serial:` lines; `--serial-log FILE` keeps the raw
bytes) and types each `--serial-in` line at the next prompt;
`--serial-stop` ends the run at the prompt after the last. The prompt comes
after about 24 million instructions, a minute.
`python verilator\nvram.py` rebuilds an NVRAM image from a device log,
shows Open Firmware's variables and changes them (`set IMG OUT
auto-boot?=true`), and writes one for dingusppc (`dingus`).

On the board the same image goes in as `boot1.rom`, which the MiSTer loads
at the core's start, and the MiSTer's UART is the modem port (the OSD's
UART option; the debug readout's hex lines are the other choice):

```
python syn\mister.py put-nvram
python syn\mister.py load
python syn\mister.py uart 40
python syn\mister.py type "1 2 + ." "words"
```

The OSD's Picture option chooses Mac OS's screen or the debug readout,
its Monitor option the 16-inch or 13-inch RGB (a change resets the
machine); `python syn\mister.py cfg --picture mac|debug --monitor 16|13`
sets them, `shot` takes a screenshot through the framework.

The board is controlled through the MiSTer Remote (mrext, port 8182), as
the other cores' tooling does (`tools\misterdeploy`): `load` and `menu`
(`/api/launch`), `shot` (`/api/screenshots`), and the Remote's keyboard
and mouse, which reach the core's ADB keyboard and mouse as a USB keyboard
and mouse would (`keys TEXT`, `mouse DX DY`, `click`, or any `ws_send.py`
steps with `ws`). SSH copies files to the card and reads the UART.

`uart` shows what Open Firmware prints (the prompt about 2 s after the
core starts), `type` types lines at it and shows the answers. From a shell
on the MiSTer, `/dev/ttyS1` at 38,400 baud is the port itself.

```
python verilator\run_cuda.py
```

Cuda alone (`MacPPC7300_cuda`: the 68HC05, its firmware, its RAM and
peripherals), with a model of the VIA and a host speaking the Cuda protocol
around it: the cold start, the host's sync, then packets whose replies are
checked (Cuda's ROM through READ_MCU_MEM, the clock, PRAM written and read
back, the ROM's own first packet, an ADB talk). Every instruction is
compared with MAME's 6805 core (`verilator/hc05ref`, built from `..\mame`):
registers, the bytes written, and the instruction's length in bus cycles.
Two seconds of Cuda's time take a few seconds. `--log-via` prints every
VIA access the host makes; `--trace-from N --trace-count M` Cuda's
instructions.

```
python verilator\run_scsi.py
```

MESH, its DBDMA channel and the disks (`scsi_tb_top`: Grand Central and
`MacPPC7300_scsidisk` on the internal bus), driven through Grand Central's
registers the way the 7300's ROM and Mac OS 7.6.1's driver drive them in
dingusppc's log of a boot from the 7.6.1 image: READ(6) by programmed I/O
(block 0, then 19 blocks), READ(10) with its middle by DMA into memory at an
odd address (a descriptor longer than MESH's count, flushed and stopped),
three blocks by DMA through two descriptors, WRITE(10) by DMA out and read
back, INQUIRY, READ CAPACITY, a selection of an absent ID. A memory answers
the DMA port, hps_io's block side serves a made-up image (`--disk FILE` for
a real one); every byte is checked. A few seconds.

The machine bench serves disk images the same way (`--disk0 FILE`,
`--disk1 FILE`; blocks written are kept in memory, the file is not
changed; `--disk-log` prints every block) and copies DMA writes into the
reference's RAM. `--mouse N:DX:DY` moves the PS/2 mouse after N
instructions; `--vram-check` keeps a copy of every byte the CPU writes into
Control's VRAM and checks every CPU read of it, and every read the picture
side answers against the DDR3 model; `--vram-log FILE` writes every CPU
access to the VRAM.

For a fault inside Mac OS: `--exc-log FILE` writes every exception the CPU
takes (`E count vector pc-before srr0 srr1 dar dsisr`) and every `rfi`
(`R count pc srr0 srr1`), with the counts by vector in the progress lines;
`--dump-at N` prints the registers after N instructions (repeatable),
`--dump-mem START:LEN` a range of RAM with them (hex; the reference's RAM in
lockstep, which has every store, else the bench's memory, which lacks what
the caches hold), `--dump-bin FILE` all of RAM raw to `FILE.N`. In the 68k
emulator r24 is the 68k PC, r8-r15 D0-D7, r16-r22 A0-A6, r1 A7; a DSI from
the emulator whose rfi goes to 6806D358 is a bus error handed to the 68k
code (the NanoKernel's own faulting access at FFF11518 or FFF11A10 comes
first). The 7.6.1 bus error at "Welcome to Mac OS" was found this way
(2026-10-07): the exception log gave the fault's count and address, the
dump the 68k registers and SonyVars, the trace the 68k instructions, and
MacsBug on the board (`games/MacPPC7300/os761mb.hda`, the image with MacsBug
6.6.3 in its System Folder) the same fault to the byte.

For a hang: `--dev-log-from N` starts the device log at the Nth instruction
(the run is at full speed before it), and on the board Command-Menu (Alt
and the PC keyboard's Menu key; through the Remote `ws kbdRawDown:56
kbdRaw:127 kbdRawUp:56`) is the NMI: MacsBug's `sc` (the calling chain,
with Open Transport's and the CFM fragments' names) and `wh ADDR`, or
without MacsBug the ROM's debugger. Native code can be read out of a
`--dump-bin` image with `llvm-objdump-18 --triple=powerpc` in WSL after
`objcopy -I binary`. The "Starting Up..." stop of 2026-10-08 (the video
driver's DDC probe, then Open Transport's AppleTalk) was found this way.
`--wav FILE` records the sound AWACS plays; `--clock SECS` sets Cuda's
clock as the machine starts (seconds since 1904; the MiSTer gives its RTC).

On the board, `python syn\mister.py trace [--last N] [--from K]` reads the
trace the core keeps in DDR3 (`MacPPC7300_trace.sv`, a ring of 2,048 records at
0x30500000, read through `/dev/mem` on the MiSTer): every SCSI command the
targets answer (ID, CDB, status, sense, bytes moved, the Toolbox's answer
from the Main), bus resets and CD mounts; the CPU's accesses to MACE and
its DMA channels 2 and 3 (with `cfg --trace-mesh`, status bit 29, also
MESH's and channel A's, and each change of MESH's and channel A's
interrupt on its way through Grand Central); each command those two DMA
channels fetch, finish (its bits, counts, status, a quad's value, whether
its interrupt fired) or are stopped in; and the ADB keyboard's queued keys
(and drops) and the commands Cuda sends it. Each record has a microsecond
time stamp. `trace-capture SECONDS` streams the new records to a file on
the MiSTer (`syn\trstream.py`) for longer than the ring holds;
`trace-fetch OUT` and `trace --file OUT` read it. A CPU polling a register
in a loop fills the queue faster than DDR3 takes it: the records it drops
are counted.
Never reload the core on the board while Mac OS has its disk mounted: shut
it down from the Finder's Special menu first.

```
python verilator\fpmodel.py check
python verilator\fpmodel.py random 300000 1 x.csv
python verilator\run.py --csv x.csv
```

`fpmodel.py` is a bit-exact software model of the 604's floating-point unit and
the specification the RTL was written to. `check` compares the model itself
with the hardware data (the 7600 file by default; give it the 7300 one for
the rest). `random` writes vectors (count, seed, file) with modelled results
in the golden CSV format, and `run.py --csv` replays them.
They reach datapath corners (random significands, enabled exceptions,
denormals, near cancellation) that the hardware set, which is heavy on special
values, does not.

```
python syn\check.py core
python syn\check.py fpu
python syn\check.py int
```

Synthesises the pipeline, the floating-point unit, or just the integer
decode-and-execute path on its own for the DE10-Nano's FPGA and prints its
size and maximum clock. `--paths 10` also lists the slowest paths.

## Layout

| Path | Contents |
|---|---|
| `MacPPC7300.sv`, `MacPPC7300.qsf`, `files.qip` | MiSTer core top level and Quartus project |
| `sys/` | MiSTer framework (do not edit) |
| `rtl/DSPPC604/` | the CPU |
| `rtl/machine/` | the machine: the 7600's address map and device stubs (`MacPPC7300_*`), Cuda (`MacPPC7300_cuda`, `MacPPC7300_hc05`, the ROM `MacPPC7300_cudarom` generated by `verilator/cudarom.py`) |
| `rtl/machine/cuda/` | Cuda's firmware, Apple's 341S0060 (Cuda 2.40), as MAME's `cuda` set has it and byte for byte as read out of the 7300's own chip (`cudadump/`) |
| `rtl/pll.v`, `rtl/pll/` | the core's PLL (the template's, edited to three outputs) |
| `syn/mister.py` | puts the core, the ROM and an NVRAM image on the MiSTer over SSH, sets options (RAM, boot, UART, picture, monitor), loads, screenshots, reads the UART and types at it |
| `syn/nvram_of_prompt.bin` | an NVRAM image: Open Firmware's defaults with `auto-boot?` false (made by `verilator/nvram.py` from the bench's device log) |
| `verilator/` | test benches (single instructions, programs on the pipeline, the whole machine), the floating-point software model, `run_gui.py` (the machine in a window) |
| `verilator/ref/` | dingusppc's interpreter as a library, for lockstep runs |
| `verilator/machref/` | dingusppc's whole 7600, headless, logging every device access |
| `verilator/hc05ref/` | MAME's 6805 core as a library, for Cuda's lockstep runs |
| `docs/MacPPC7300_plan.md` | the machine's plan: milestones, rules, what the ROM asks for next |
| `docs/MacPPC7300_stubs.md` | everything the machine stubs, simplifies or leaves out |
| `syn/` | stand-alone area and timing checks |
| `ppctest/` | tool that builds the test disk for real Macs and decodes its results |
| `cudadump/` | a disk that reads Cuda's firmware out of a real 7300 |
| `hwprobe/` | a disk that measures, on a real 7300, the device behaviour the emulators guess (SCSI selection timeouts, access times) |
| `ppctest/runs/results_*.csv` | golden results from real hardware |
| `docs/` | plans and design notes |

## License

GPL-2.0-or-later, as the MiSTer framework. `rtl/machine/cuda/341s0060.bin`
(and the ROM module generated from it) is Apple's Cuda firmware as MAME's
romset has it, not covered by that license.
