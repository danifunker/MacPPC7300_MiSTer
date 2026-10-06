/*
 * dingus_ref.h - C API around the dingusppc PowerPC interpreter, for running it
 * in lockstep with the DSPPC604 RTL in a Verilator test bench.
 *
 * See README.md in this directory for semantics and caveats.
 */
#ifndef DINGUS_REF_H
#define DINGUS_REF_H

#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t pc;
    uint32_t gpr[32];
    uint64_t fpr[32];      /* raw 64-bit patterns */
    uint32_t cr, xer, lr, ctr, msr, fpscr;
} ref_state_t;

/* One CPU with ram_size bytes of RAM at physical address 0. pvr e.g. 0x00040303 (604).
   Returns 0 on success. May be called again to start over. */
int      ref_init(uint32_t ram_size, uint32_t pvr);
uint8_t *ref_ram(void);                  /* host pointer to the RAM; guest is big-endian */
void     ref_set_state(const ref_state_t *s);
void     ref_get_state(ref_state_t *s);
uint32_t ref_get_spr(unsigned n);
void     ref_set_spr(unsigned n, uint32_t v);
/* Execute exactly one instruction at pc. Returns 0 if it completed normally,
   otherwise a nonzero code: the PowerPC exception vector offset that was taken
   (0x700 program, 0x300 DSI, 0xC00 system call, ...), with the state left as the
   exception entry left it (SRR0/SRR1/MSR/pc set). Must never abort the process,
   longjmp past the caller, or hang, whatever the instruction word is. */
int      ref_step(void);
/* Bytes written by the last ref_step: number of bytes (0 if none), address and
   big-endian value. For multi-word stores (stmw, stsw) report count only as
   the number of separate accesses via ref_last_store_count() and let
   ref_last_store(i, ...) return each. */
unsigned ref_last_store_count(void);
void     ref_last_store(unsigned i, uint32_t *addr, unsigned *size, uint64_t *value);

/* ---- Additions to the API as specified (see README.md, "Deviations") ---- */

/* ref_step() returns this (negative, so it cannot be mistaken for a vector
   offset) when dingusppc itself could not execute the instruction and would
   have aborted the process: instruction fetch from outside RAM, page table
   outside RAM, direct-store segment, ... No PowerPC exception is taken; pc is
   not advanced. ref_last_error() describes the reason. */
#define REF_STEP_FAULT (-1)
const char *ref_last_error(void);

/* Segment registers are not SPRs, so they are not reachable through
   ref_get_spr/ref_set_spr. n = 0..15. */
uint32_t ref_get_sr(unsigned n);
void     ref_set_sr(unsigned n, uint32_t v);

/* ---- A machine around the CPU (for running a real ROM in lockstep) ----------
   All of these must be called again after every ref_init(). */

/* Read-only memory at base (instructions can be fetched from it, as from RAM).
   The data is copied. Returns 0, or -1 if the range overlaps another region. */
int      ref_add_rom(uint32_t base, const uint8_t *data, uint32_t size);

/* A device range: every load from it calls rd(ctx, address, size) for the value
   (size 1, 2 or 4; an 8-byte access is two 4-byte calls, the lower address
   first), every store calls wr(ctx, address, size, value). The address is the
   physical one; the value is the number the access reads or writes, right-
   aligned, as dingusppc's devices see it. Returns 0, or -1 on an overlap. */
typedef uint32_t (*ref_mmio_read_fn)(void *ctx, uint32_t addr, unsigned size);
typedef void     (*ref_mmio_write_fn)(void *ctx, uint32_t addr, unsigned size, uint32_t value);
int      ref_add_mmio(uint32_t base, uint32_t size, ref_mmio_read_fn rd, ref_mmio_write_fn wr, void *ctx);

/* Take an asynchronous interrupt now, before the instruction at pc: vector
   0x500 (external) or 0x900 (decrementer). SRR0 = pc, SRR1 = the MSR bits as
   dingusppc's exception entry saves them, MSR as it leaves it, pc = the
   vector. Returns the vector, or 0 for any other number (nothing is done). */
int      ref_interrupt(unsigned vector);

#ifdef __cplusplus
}
#endif

#endif /* DINGUS_REF_H */
