// hc05ref: MAME's 6805 core (the 68HC05's tables) as a lockstep reference.
// See README.md.
#ifndef HC05_REF_H
#define HC05_REF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	uint16_t pc;
	uint8_t  a, x;
	uint8_t  sp;           // 00C0-00FF
	uint8_t  cc;           // MAME's byte; bits 4-0 are H I N Z C
} hc05_state_t;

// a read of 0000-001F (the registers) asks the bench, which answers what the
// RTL read there
typedef uint8_t (*hc05_io_read_fn)(void* ctx, uint16_t addr);

// the 68HC05E1 as Cuda has it: 8 KB space, RAM 0090-01FF (zeroed), ROM of
// rom_size bytes at rom_base, the rest reading 0. Then the reset: SP FF,
// I set, the pc from 1FFE.
void hc05_ref_init(const uint8_t* rom, uint16_t rom_base, uint16_t rom_size);
void hc05_ref_set_io(hc05_io_read_fn fn, void* ctx);
void hc05_ref_set_irq(int asserted);          // the IRQ pin, for BIL/BIH

void hc05_ref_get_state(hc05_state_t* s);
void hc05_ref_set_state(const hc05_state_t* s);

// one instruction; returns its cycles from MAME's s_hc_cycles
int  hc05_ref_step(void);
// an interrupt's entry, as the RTL takes it: pc, X, A, 111HINZC pushed, I set,
// the pc from vector (1FFA, 1FF8 or 1FF6)
void hc05_ref_interrupt(uint16_t vector);

// the writes of the last step or interrupt, in order
unsigned hc05_ref_write_count(void);
void     hc05_ref_write(unsigned i, uint16_t* addr, uint8_t* data);

uint8_t  hc05_ref_peek(uint16_t addr);        // RAM or ROM, no side effects
void     hc05_ref_poke(uint16_t addr, uint8_t data);

#ifdef __cplusplus
}
#endif

#endif
