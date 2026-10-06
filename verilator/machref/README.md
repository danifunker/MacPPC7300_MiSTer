# machref: dingusppc's whole 7600, headless, logging every device access

`machref` builds a complete dingusppc machine (the Power Macintosh 7600 by
default) with all its devices, runs a ROM from the reset vector, and writes a
log of every access the CPU makes to a device. It is the reference for the
device side of `rtl/machine/PPCMac_machine.sv`: which registers the ROM
touches, in what order, and what dingusppc's devices answer. The CPU itself is
checked separately, in lockstep (`verilator/ref`, `run_machine.py`).

dingusppc is compiled **unmodified** from `..\dingusppc` (commit `3f070249`).
`null_host.cpp` replaces the four host files that need SDL or cubeb (display,
input events, sound, `main_sdl.cpp`): no window, no input, no sound, and the
sound DMA drained on a timer as a real backend would, so that the startup
chime can finish. GPL-3.0-or-later, as dingusppc.

| File | |
|---|---|
| `machref.cpp` | the program: builds the machine, puts a logging proxy in front of every device region, runs |
| `null_host.cpp` | the host side with nothing behind it |
| `Makefile` | builds `$HOME/.cache/ppcmac/machref/machref` under WSL |
| `devdiff.py` | compares the RTL machine's device log with machref's |

## Build and run

Under WSL:

    make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/machref
    ~/.cache/ppcmac/machref/machref --rom /mnt/c/Temp/mistercore/PPC_Mac/ppctest/runs/my7600.rom \
        --max 50000000 --sample 1000000 --log m.log

A clean build compiles all of dingusppc (about two minutes); 50 million
instructions run in under a second. Options: `--machine pm7600` (any
dingusppc machine), `--ram MB` (made of DIMMs of 4 MB or more), `--cpu 604`,
`--pvr 00040303` (the 604 measured on the 7600 and 7300, set after the
machine is built), `--max N` instructions, `--sample N` (log the pc every N
instructions), `--trace-from N --trace-count M` (log M instructions from the
Nth; opcodes only with translation off), `--set NAME=VALUE` (any dingusppc
machine property). `MACHREF_LOG=<n>` sets dingusppc's own log level on
stderr (default warnings).

The machine runs in dingusppc's deterministic mode: the same ROM and options
give the same log every time. The NVRAM starts as zeros (no file) and is not
saved.

## The log

    # device NAME at START-END                  a device region, as found
    A icount pc R|W size address value device   a device access
    S icount pc msr                             a sample of where the CPU is
    T icount pc opcode msr                      a traced instruction
    E icount pc msr                             the end of the run

`icount` is the number of instructions completed before the one making the
access. dingusppc's time is that counter (16 ns per instruction), so its
devices see time pass at 62.5 million instructions per second. RAM and ROM
accesses are not logged, nor are accesses to memory dingusppc does not map
(it reads all ones there; the 7300 measured zeros).

## Comparing with the RTL machine

`run_machine.py --dev-log FILE` writes the RTL machine's device accesses in
the same format, from the lockstep run (so each carries the pc and
instruction count of the instruction that made it). Then:

    python verilator\machref\devdiff.py rtl.log m.log
    python verilator\machref\devdiff.py rtl.log m.log --hunks 20
    python verilator\machref\devdiff.py rtl.log m.log --hunks 20 --no-values --rtl-first 140000 --ref-first 69000

Runs of the same access (polling loops) are collapsed, since the two machines
poll for different numbers of iterations. `--hunks N` lists N differences,
resynchronising after each; `--no-values` compares where the accesses go and
not what they return, which shows control-flow divergence alone; the
`--*-first` options skip the start of either log.

## What it found (2026-10-06, the 7600's ROM, 16 MB)

The ROM reaches the Mac OS ROM proper (user mode, the 68k emulator at
effective 68000000) after about 28 million instructions. Its device
traffic, in order of first use: Hammerhead's ID registers (instruction 39),
Bandit's configuration space and Grand Central's base address (95-127),
the VIA and Cuda (140-69,404: one exchange, `01 22 88 61 55`, most of the
time spent polling), the sound chip and its DMA channel (69,434), Hammerhead's
timing and bank registers (69,519-70,800), the NVRAM, RAM sizing, then Open
Firmware (from about 2 million instructions) with the VIA timers, NVRAM,
Ethernet ROM, SCC, Chaos's configuration space (26.9 million) and MESH (28.8
million). In 50 million instructions nothing touches the Control video
registers or VRAM.
