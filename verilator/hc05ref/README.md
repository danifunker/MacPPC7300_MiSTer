# hc05ref: MAME's 6805 core as a lockstep reference

`libhc05ref.a` is MAME's 6805 CPU core with the 68HC05's opcode and cycle
tables and the 68HC05E1's parameters (13 address bits, the stack at
00C0-00FF), behind the small C API in `hc05_ref.h`. `verilator/cuda_main.cpp`
links it and runs Cuda's firmware on it and on the RTL
(`rtl/machine/MacPPC7300_hc05.sv`) at the same time, comparing after every
instruction.

MAME's instruction code is compiled **unmodified** from its tree:
`src/devices/cpu/m6805/m6805defs.h` and `6805ops.hxx` (BSD-3-Clause, Aaron
Giles and Vas Crabb), included into `hc05_ref.cpp`, which supplies the small
class those two files are written against (the members of MAME's
`m6805_base_device` they use) and copies MAME's `s_hc_s_ops` and
`s_hc_cycles` tables. The interrupt's entry is this library's own, as the
chip and the RTL take it: pc, X, A and the condition codes as 111HINZC
pushed, I set, the vector read; 10 cycles. (MAME's pushes the condition
codes as stored and counts 11.)

| File | |
|---|---|
| `hc05_ref.h` | the API |
| `hc05_ref.cpp` | the class MAME's code needs, the tables, the API |
| `Makefile` | builds `$HOME/.cache/macppc7300/hc05ref/libhc05ref.a` under WSL |

## Build

    make -C /mnt/c/Temp/mistercore/PPC_Mac/verilator/hc05ref [BUILD=<dir>] [MAME=<dir>]

`MAME` defaults to `/mnt/c/Temp/mistercore/mame`. One file, a second to
compile. `run_cuda.py` builds it.

## API

- `hc05_ref_init(rom, base, size)`: an 8 KB space with the ROM at `base`,
  RAM 0090-01FF zeroed, everything else reading 0; then the reset (SP FF, I
  set, the pc from 1FFE).
- `hc05_ref_set_io(fn, ctx)`: reads of 0000-001F (the 68HC05E1's registers)
  call `fn`; the bench answers with what the RTL read, in order.
- `hc05_ref_set_irq(asserted)`: the IRQ pin, for BIL and BIH.
- `hc05_ref_step()`: one instruction; returns its cycles from the table.
- `hc05_ref_interrupt(vector)`: an interrupt's entry (1FFA, 1FF8, 1FF6).
- `hc05_ref_write_count()`, `hc05_ref_write(i, &addr, &data)`: the writes of
  the last step or interrupt, in order (registers included).
- `hc05_ref_get_state`, `hc05_ref_set_state`, `hc05_ref_peek`,
  `hc05_ref_poke`.
