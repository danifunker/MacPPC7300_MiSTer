# dingusref: dingusppc's PowerPC interpreter as a lockstep reference

`libdingusref.a` is the CPU of the [dingusppc](https://github.com/dingusdev/dingusppc)
emulator (interpreter, FPU, MMU, exception code) with one RAM region and nothing
else, behind the small C API in `dingus_ref.h`. A Verilator test bench links it,
runs the same program on it and on the RTL, and compares the state after every
instruction.

dingusppc is compiled **unmodified**, straight from its tree (developed against
commit `3f070249`). It is GPL-3.0-or-later; so is anything linked with this library.

| File | |
|---|---|
| `dingus_ref.h` | the API |
| `dingus_ref.cpp` | glue: init, state access, `ref_step`, store log |
| `Makefile` | builds `libdingusref.a` and the self-test |
| `selftest.cpp` | self-test, see below |

## Build

Under WSL (g++ 13, GNU make, binutils; nothing else is needed):

    make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/ref              # -> $HOME/.cache/ppcmac/dingusref/libdingusref.a
    make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/ref BUILD=<dir>  # -> <dir>/libdingusref.a
    make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/ref selftest     # build + run the self-test

Variables: `BUILD` (all output goes there, default `$HOME/.cache/ppcmac/dingusref`),
`DINGUS` (dingusppc tree, default `/mnt/c/Temp/mistercore/dingusppc`), `OPT`
(default `-O2`), `HIDE` (default 1). It compiles in parallel by itself; a clean
build takes a few seconds. Run `make clean` (same `BUILD`) after changing a variable.

To use it: `#include "dingus_ref.h"` (C or C++), add `-I` for this directory, and
link `libdingusref.a` with g++. No other library is needed. With Verilator
(checked with 5.020 and a trivial model):
`verilator --cc --exe --build -CFLAGS "-I<this dir>" -LDFLAGS "<BUILD>/libdingusref.a" ...`

With `HIDE=1` the archive holds one relocatable object in which every symbol
except the `ref_*` functions is local, so dingusppc's 700 or so global names
(`ppc_state`, `power_on`, `int_pin`, ...) cannot collide with the test bench.
`HIDE=0` gives a plain archive of the individual objects.

What is compiled from dingusppc: `cpu/ppc/{ppcexec,ppcopcodes,ppcfpopcodes,poweropcodes,ppcmmu,ppcexceptions}.cpp`,
`devices/memctrl/memctrlbase.cpp`, `core/timermanager.cpp`, `thirdparty/loguru/loguru.cpp`,
with dingusppc's own settings (C++20, both little-endian options off) plus
`-fno-strict-aliasing -ffp-contract=off -DLOGURU_STACKTRACES=0`. Nothing is stubbed:
the memory controller is dingusppc's `MemCtrlBase` with a single RAM region, and its
timer manager is linked but never run. No SDL, cubeb, devices, machines or debugger.

## API semantics

- **`ref_init(ram_size, pvr)`**: zeroed RAM at physical 0 (size rounded up to 4 KiB;
  0 or more than 0xFFFFF000 fails with -1), CPU in dingusppc's power-on state:
  `pc = 0xFFF00100`, `MSR = 0x00000040` (IP; 601: `0x00001040`), everything else 0,
  PVR as given, DEC = 0xFFFFFFFF (601: 0), time base 0. That pc is outside RAM, so
  call `ref_set_state` before stepping. May be called again at any time; the old
  RAM pointer is then invalid.
  `pvr >> 16 == 1` selects the 601 (POWER instructions, MQ, RTC, unified BATs).
  Every other PVR gets one generic "PowerPC" instruction set and MMU; dingusppc does
  not model per-CPU differences beyond that (see caveats).
- **`ref_ram()`**: host pointer to the RAM, guest byte order (big-endian). It may be
  read and written freely between steps; nothing is cached (instructions are
  fetched from it on every step).
- **`ref_set_state` / `ref_get_state`**: exactly the fields of `ref_state_t`. The MSR is
  applied properly (FPU on/off, translation mode). The low two bits of `pc` are
  dropped. `ref_get_state` zero-fills the struct including its padding (4 bytes
  before `fpr`), so two states can be compared with `memcmp`. Not touched: all other
  SPRs, segment registers, RAM, and the lwarx reservation (a hidden flag: set by
  lwarx, cleared by stwcx. and `ref_init`, never by exceptions, no address compare).
- **`ref_get_spr(n)` / `ref_set_spr(n, v)`**: dingusppc's SPR array, n < 1024, no
  privilege or validity check, no masking (a guest `mtxer` masks with 0xE000FF7F,
  `ref_set_spr(1, v)` does not). Special cases: 268/269 are 284/285 (time base);
  DEC and TBL/TBU read and write the values a guest `mfdec`/`mftb` sees; SDR1 and the
  BATs (528-543) take effect immediately. Setting PVR changes only the register;
  the CPU type is fixed by `ref_init`.
- **`ref_step()`**: one instruction. Returns 0, or the vector offset of the exception
  taken (0x300, 0x400, 0x600, 0x700, 0x800, 0xC00), with SRR0/SRR1/MSR/DSISR/DAR and
  `pc` (= vector, at 0xFFFn_nnnn if MSR[IP]) as dingusppc's exception entry left
  them, or `REF_STEP_FAULT` (-1), see below. The host floating-point environment is
  saved and restored around the step.
- **`ref_last_store_count()` / `ref_last_store(i, ...)`**: the stores of the last
  `ref_step`, in the order made, at most 64. `addr` is the **effective** address
  (equal to the physical one in real mode), `value` the big-endian value of the
  `size` (1, 2, 4 or 8) bytes written. One entry per access dingusppc makes: stmw one
  per word; stswi/stswx words, then a halfword and/or a byte; stfd one of 8 bytes;
  dcbz four of 8 bytes of zero; sthbrx/stwbrx the already swapped value. A store
  that raised an exception is not listed; a store to outside RAM (dropped by
  dingusppc) is. Implemented by redirecting the calls to dingusppc's
  `mmu_write_vmem`/`mmu_dcbz` at compile time (`-D` in the Makefile).

### Deviations from the API as specified

- `ref_step` can also return **`REF_STEP_FAULT` (-1)**: dingusppc could not execute
  the instruction and would have called `abort()`. No exception is taken; in real
  mode nothing changes at all (with translation on, a PTE R bit may already be
  set). `ref_last_error()` (added) says why. The cases found:
  instruction fetch from outside RAM (`ppcmmu.cpp:790`), page table outside RAM
  (`:222`), a direct-store segment, SR[T]=1 (`:289`), and one this library screens
  out itself because it would kill the process with SIGFPE: the 601's `div` with
  rA:MQ = 0x8000000000000000 and rB = -1 (`poweropcodes.cpp:111`).
- Added `ref_get_sr(n)` / `ref_set_sr(n, v)`: segment registers are not SPRs.
- Nothing else. The store log is implemented.

## Determinism, time base, interrupts

dingusppc's virtual time is an instruction counter that only its own run loops
advance (host time is used only in a "realtime" mode, which is forced off). This
library never advances it and never runs dingusppc's timers, so **time stands
still**:

- `mftb`/`mftbu` (and `mfspr` 268/269/284/285) return the last value written by the
  guest or by `ref_set_spr`; 0 after `ref_init`.
- `mfspr DEC` returns the last value written; 0xFFFFFFFF after `ref_init` (601: 0).
- No decrementer, external, thermal or any other asynchronous exception ever
  occurs, whatever MSR[EE] and DEC are. MSR[POW] never stops anything. There is no
  call to inject an interrupt (the handler exists in dingusppc; a `ref_interrupt()`
  would be a few lines).

To follow the RTL's time base, write it with `ref_set_spr` before the `mftb`/`mfdec`.

## Outside RAM, exceptions

- Data **load** from outside RAM: no exception, reads all ones (0xFF per byte).
  Data **store** outside RAM: no exception, dropped (but logged). An access
  straddling the end of RAM is split bytewise. dingusppc never raises a machine check.
- Instruction **fetch** from outside RAM: `REF_STEP_FAULT`. This includes every
  exception vector while MSR[IP] = 1, so keep IP = 0.
- Exceptions come out of dingusppc by `longjmp`; `ref_step` contains that. They are
  taken by `ref_step` returning the vector offset; the next `ref_step` executes the
  handler's first instruction.
- Never produced: system reset, machine check, external, decrementer, trace
  (MSR[SE]/[BE] are ignored), FP-enabled program exceptions (FPSCR[FEX] with
  MSR[FE0/FE1]), performance monitor, IABR/DABR breakpoints, SMI.
- Little-endian mode is not compiled in: MSR[LE] is stored and otherwise ignored.

dingusppc's log messages go to stderr: errors and aborts by default;
`DINGUSREF_LOG=-9` silences them, `-1` adds warnings (e.g. each access outside
RAM), `0` adds info.

## Self-test

`make selftest` single-steps hand-encoded programs and compares, after every
step, the whole state, the store log and the whole RAM with values worked out
from the architecture; then checks the library-defined behaviour above and feeds
a million random instruction words (604, 601, 750 PVRs, translation off and on)
through `ref_step`. It prints `PASS` or the first mismatch and exits nonzero on
failure. Known disagreements between dingusppc and the architecture (or the 604
manual) are printed as `DEVIATION:` on every run and do not fail the test unless
it is run as `selftest --strict`; if dingusppc changes, the test says so.

## Caveats: where dingusppc differs from the architecture or from a real 604

File references are into the dingusppc tree. "[run]" = confirmed by executing it
(selftest or by hand), "[read]" = from reading the code only.

Against the PowerPC architecture (PEM):

1. **`tw` compares the operands the wrong way round** (`ppcopcodes.cpp:1628-1629`
   read rA from the rB field and vice versa): `twlt`, `twgt`, `twllt`, `twlgt` and
   combinations are reversed. `twi`, `tweq`, `twne`, `trap` are right. [run]
2. **`sc` sets SRR1[14]** (0x00020000) on every CPU (`ppcopcodes.cpp:1624`); that is
   601/POWER behaviour, the architecture clears SRR1[1-4,10-15]. [run]
3. **FP-unavailable exception sets SRR1[11]** (0x00100000) (`ppcexec.cpp:294`). [run]
4. **`fcmpu`/`fcmpo` clear FPSCR[VE]** (`ppcfpopcodes.cpp:1355,1381`, "kludge to pass
   tests"). [run]
5. **Inexact results are never flagged**: FPSCR[XX], [FI], [FR] are not set by
   arithmetic (`ppcfpopcodes.cpp:120-147`). [run] Enabled FP exceptions are never
   taken (`ppcexceptions.cpp:188`). `frsp` does not update FPRF. [read] The FPU
   computes with host doubles; it has not been validated here beyond this.
6. **FPSCR[RN]**: in dingusppc `mtfsf`/`mtfsfi`/`mtfsb0`/`mtfsb1` never change the host
   rounding mode (`ppcfpopcodes.cpp:1241,1262,1279,1296`; only its test harness
   calls `update_fpscr`), so RN has no effect on arithmetic there. [read]
   **This library differs from stock dingusppc here**: it sets the host rounding
   mode from FPSCR[RN] at every step, so RN is honoured. [run]
7. `eciwx` with EAR[E] = 0 raises DSI without setting DSISR (`ppcopcodes.cpp:2165`;
   `ecowx` sets it). [run]

Against the PowerPC 604 User's Manual (sections in parentheses):

8. **Alignment**: only `stmw` (`ppcopcodes.cpp:1827`) and 8-byte FP accesses
   (`ppcmmu.cpp:1515,1602`) raise 0x600 for a non-word-aligned address; `lmw`,
   `lwarx`, `stwcx.`, `lfs`, `stfs` do not (4.5.6 says all of them do). [run]
   Nor does a string operation that is not word-aligned and crosses a 4 KB
   boundary, or is word-aligned and crosses a 256 MB boundary (2.3.4.3). [run]
9. **Undefined SPRs are plain storage** for `mfspr`/`mtspr`, even in user mode
   (`ppcopcodes.cpp:1112,1236`); the 604 takes a program exception (4.5.7). `mfspr`
   268/269 is accepted as well as `mftb`. [run]
10. **Invalid forms trap instead of executing**: update forms with rA = 0 or rA = rD
    (`ppcopcodes.cpp:1746,1769,1860,1896`, ...) and instructions without a record
    form that have bit 31 set (the decode table has no entry) raise an
    illegal-instruction program exception; the 604 executes them with undefined
    rD/r0 or CR0 (2.3.4.3). Other reserved bits are ignored (any primary-opcode-17
    word is `sc`). [run]
11. **Instructions the 604 does not have are accepted** on every non-601 PVR:
    `tlbia` (2.3.1.2), and the 603's `tlbld`/`tlbli`, which are not even privileged
    (`ppcexec.cpp:944-949`). [run]
12. Reserved register bits are kept: `mtmsr` stores all 32 bits
    (`ppcopcodes.cpp:811`); `mtxer` keeps 0xE000FF7F on every CPU, i.e. also the
    601's bits 16-23 (`:1149`). [run]

With address translation on:

16. **Guarded memory is not checked**: an instruction fetch from a page or
    block with G = 1 does not raise an ISI (the OEA and 604 UM 4.5.4 say it
    does, with SRR1[3]). [read]
17. **`tlbie` flushes every page translation** (`ppcopcodes.cpp:2204`) instead
    of the congruence class. The same as a real 604 for software that issues a
    tlbie for every PTE it changes. [read]
18. The R bit is set only after the protection check passes, so a protection
    violation leaves R clear (`ppcmmu.cpp:343-368`); the architecture allows
    either. C is set on a successful store, as on the 604. [read]
19. Direct-store segments abort (see `REF_STEP_FAULT`); a real 604 would start
    a bus transaction and, on this machine, take a DSI with DSISR[0].

Undefined by the architecture, so check against real hardware:

13. `divw`/`divwu` by zero and 0x80000000 / -1 give quotient 0 on non-601 CPUs
    (`ppcopcodes.cpp:536-553,578-585`; the code says "tested on G4"). With OE they
    set OV/SO as required. [run]

Worked around in this library (they are dingusppc bugs all the same):

14. `ppc_cpu_init` leaves SPR DEC = 0xFFFFFFFF but its shadow at 0, so the first
    `mfdec` would read 0 (`ppcexec.cpp:1074,1086`); and when called a second time it
    does not reselect the FPU/no-FPU opcode table (`:1089`). `ref_init` fixes up both.
15. The 601 `div` host crash described under `REF_STEP_FAULT`.

Not verified: the 601's POWER instructions; floating point beyond items 4-6;
what a real 604 does in items 8-13 and 16-19 (the manual is the only source
used). With translation on, dingusppc has agreed with the RTL's walker on the
page tables' R and C bits over every lockstep program so far.
