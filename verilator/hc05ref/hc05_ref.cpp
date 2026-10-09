// hc05ref: MAME's 6805 core (the 68HC05's tables) as a lockstep reference
// for rtl/machine/MacPPC7300_hc05.sv.
//
// MAME's instruction code is compiled unmodified from its tree:
// src/devices/cpu/m6805/m6805defs.h (addressing, stack, flags) and
// 6805ops.hxx (every instruction), BSD-3-Clause, copyright Aaron Giles and
// Vas Crabb. What it needs from MAME's device classes is the small class
// below, with the members those two files use. The opcode and cycle tables
// are s_hc_s_ops and s_hc_cycles of m6805.cpp, copied, with the 68HC05E1's
// parameters (13 address bits, the stack at 00C0-00FF, SWI's vector at
// 1FFC: m68hc05e1.cpp). The interrupt's entry is this file's, as the RTL
// takes it (MAME's m6805_base_device::interrupt pushes the CC as it is and
// counts 11 cycles; the chip pushes 111HINZC).

#include "hc05_ref.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace hc05ref {

using u8  = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using s8  = int8_t;
using s16 = int16_t;
using s32 = int32_t;

template <typename T, typename U> constexpr T BIT(T x, U n) noexcept { return (x >> n) & T(1); }

// emucore.h's PAIR, little-endian host
union PAIR {
	struct { u8 l, h, h2, h3; } b;
	struct { u16 l, h; } w;
	struct { s8 l, h, h2, h3; } sb;
	struct { s16 l, h; } sw;
	u32 d;
	s32 sd;
};

class m6805_base_device {
public:
	enum class addr_mode { IM, DI, EX, IX, IX1, IX2 };
	enum { CFLAG = 0x01, ZFLAG = 0x02, NFLAG = 0x04, IFLAG = 0x08, HFLAG = 0x10 };

	struct configuration_params {
		u32 m_addr_width, m_sp_mask, m_sp_floor;
		u16 m_vector_mask, m_swi_vector;
	};
	typedef void (m6805_base_device::*op_handler_func)();

	// the 68HC05E1 (m68hc05e1.cpp: s_hc_s_ops, s_hc_cycles, 13, 0x00ff, 0x00c0, 0xfffc)
	configuration_params const m_params{13, 0x00ff, 0x00c0, 0x1fff, 0xfffc};

	PAIR m_ea, m_pc, m_s;
	u8   m_a = 0, m_x = 0, m_cc = 0;

	// the space: RAM and ROM here, the registers through the bench
	u8   mem[0x2000];
	hc05_io_read_fn io_fn = nullptr;
	void* io_ctx = nullptr;
	bool irq = false;
	std::vector<std::pair<u16, u8>> writes;

	unsigned read(u32 addr) {
		addr &= 0x1fff;
		if (addr < 0x20) return io_fn ? io_fn(io_ctx, (u16)addr) : 0;
		return mem[addr];
	}
	void write(u32 addr, u8 v) {
		addr &= 0x1fff;
		writes.push_back({(u16)addr, v});
		if (addr >= 0x90 && addr < 0x200) mem[addr] = v;
	}

	// m6805.h's accessors
	template <bool big> unsigned rdmem(u32 addr) { return read(addr); }
	template <bool big> void     wrmem(u32 addr, u8 value) { write(addr, value); }
	template <bool big> unsigned rdop(u32 addr) { return read(addr); }
	template <bool big> unsigned rdop_arg(u32 addr) { return read(addr); }
	template <bool big> unsigned rm(u32 addr) { return rdmem<big>(addr); }
	template <bool big> void     wm(u32 addr, u8 value) { wrmem<big>(addr, value); }
	template <bool big> void rm16(u32 addr, PAIR &p);
	template <bool big> void pushbyte(u8 b);
	template <bool big> void pushword(PAIR const &p);
	template <bool big> void pullbyte(u8 &b);
	template <bool big> void pullword(PAIR &p);
	template <bool big, typename T> void immbyte(T &b);
	template <bool big> void immword(PAIR &w);
	template <bool big> void skipbyte();

	// m6805.h's flag helpers
	void clr_nz()   { m_cc &= ~(NFLAG | ZFLAG); }
	void clr_nzc()  { m_cc &= ~(NFLAG | ZFLAG | CFLAG); }
	void clr_hc()   { m_cc &= ~(HFLAG | CFLAG); }
	void clr_hnzc() { m_cc &= ~(HFLAG | NFLAG | ZFLAG | CFLAG); }
	void set_z8(u8 a)                 { if (!a) m_cc |= ZFLAG; }
	void set_n8(u8 a)                 { m_cc |= (a & 0x80) >> 5; }
	void set_h(u8 a, u8 b, u8 r)      { m_cc |= (a ^ b ^ r) & 0x10; }
	void set_c8(u16 a)                { m_cc |= BIT(a, 8); }
	void set_nz8(u8 a)                { set_n8(a); set_z8(a); }
	void set_nzc8(u16 a)              { set_nz8(a); set_c8(a); }
	void set_hnzc8(u8 a, u8 b, u16 r) { set_h(a, b, r); set_nzc8(r); }

	bool test_il() { return irq; }
	const char* tag() const { return "hc05ref"; }
	void logerror(const char*, ...) {}
	[[noreturn]] void fatalerror(const char* fmt, ...) {
		va_list ap;
		va_start(ap, fmt);
		std::vfprintf(stderr, fmt, ap);
		va_end(ap);
		std::fprintf(stderr, "\n");
		std::exit(3);
	}

	// the instructions, as m6805.h declares them
	template <bool big, unsigned B> void brset();
	template <bool big, unsigned B> void brclr();
	template <bool big, unsigned B> void bset();
	template <bool big, unsigned B> void bclr();
	template <bool big, bool C> void bra();
	template <bool big, bool C> void bhi();
	template <bool big, bool C> void bcc();
	template <bool big, bool C> void bne();
	template <bool big, bool C> void bhcc();
	template <bool big, bool C> void bpl();
	template <bool big, bool C> void bmc();
	template <bool big, bool C> void bil();
	template <bool big> void bsr();
	template <bool big, addr_mode M> void neg();
	template <bool big, addr_mode M> void com();
	template <bool big, addr_mode M> void lsr();
	template <bool big, addr_mode M> void ror();
	template <bool big, addr_mode M> void asr();
	template <bool big, addr_mode M> void lsl();
	template <bool big, addr_mode M> void rol();
	template <bool big, addr_mode M> void dec();
	template <bool big, addr_mode M> void inc();
	template <bool big, addr_mode M> void tst();
	template <bool big, addr_mode M> void clr();
	template <bool big> void nega();
	template <bool big> void mul();
	template <bool big> void coma();
	template <bool big> void lsra();
	template <bool big> void rora();
	template <bool big> void asra();
	template <bool big> void lsla();
	template <bool big> void rola();
	template <bool big> void deca();
	template <bool big> void inca();
	template <bool big> void tsta();
	template <bool big> void clra();
	template <bool big> void negx();
	template <bool big> void comx();
	template <bool big> void lsrx();
	template <bool big> void rorx();
	template <bool big> void asrx();
	template <bool big> void lslx();
	template <bool big> void rolx();
	template <bool big> void decx();
	template <bool big> void incx();
	template <bool big> void tstx();
	template <bool big> void clrx();
	template <bool big> void rti();
	template <bool big> void rts();
	template <bool big> void swi();
	template <bool big> void stop();
	template <bool big> void wait();
	template <bool big> void tax();
	template <bool big> void txa();
	template <bool big> void clc();
	template <bool big> void sec();
	template <bool big> void cli();
	template <bool big> void sei();
	template <bool big> void rsp();
	template <bool big> void nop();
	template <bool big, addr_mode M> void suba();
	template <bool big, addr_mode M> void cmpa();
	template <bool big, addr_mode M> void sbca();
	template <bool big, addr_mode M> void cpx();
	template <bool big, addr_mode M> void anda();
	template <bool big, addr_mode M> void bita();
	template <bool big, addr_mode M> void lda();
	template <bool big, addr_mode M> void sta();
	template <bool big, addr_mode M> void eora();
	template <bool big, addr_mode M> void adca();
	template <bool big, addr_mode M> void ora();
	template <bool big, addr_mode M> void adda();
	template <bool big, addr_mode M> void jmp();
	template <bool big, addr_mode M> void jsr();
	template <bool big, addr_mode M> void ldx();
	template <bool big, addr_mode M> void stx();
	template <bool big> void illegal();

	static const op_handler_func s_hc_s_ops[256];
	static const u8 s_hc_cycles[256];

	int step();
	void interrupt(u16 vector);
	void reset();
};

#include "m6805defs.h"
#include "6805ops.hxx"

// m6805.cpp's table macros and the HC05 table, s_hc_s_ops
#define OP(name)        (&m6805_base_device::name<big>)
#define OPN(name,n)     (&m6805_base_device::name<big, n>)
#define OP_T(name)      (&m6805_base_device::name<big, true>)
#define OP_F(name)      (&m6805_base_device::name<big, false>)
#define OP_IM(name)     (&m6805_base_device::name<big, addr_mode::IM>)
#define OP_DI(name)     (&m6805_base_device::name<big, addr_mode::DI>)
#define OP_EX(name)     (&m6805_base_device::name<big, addr_mode::EX>)
#define OP_IX(name)     (&m6805_base_device::name<big, addr_mode::IX>)
#define OP_IX1(name)    (&m6805_base_device::name<big, addr_mode::IX1>)
#define OP_IX2(name)    (&m6805_base_device::name<big, addr_mode::IX2>)

#define big false
const m6805_base_device::op_handler_func m6805_base_device::s_hc_s_ops[256] =
{
	/*      0/8          1/9          2/A          3/B          4/C          5/D          6/E          7/F */
	/* 0 */ OPN(brset,0),OPN(brclr,0),OPN(brset,1),OPN(brclr,1),OPN(brset,2),OPN(brclr,2),OPN(brset,3),OPN(brclr,3),
			OPN(brset,4),OPN(brclr,4),OPN(brset,5),OPN(brclr,5),OPN(brset,6),OPN(brclr,6),OPN(brset,7),OPN(brclr,7),
	/* 1 */ OPN(bset,0), OPN(bclr,0), OPN(bset,1), OPN(bclr,1), OPN(bset,2), OPN(bclr,2), OPN(bset,3), OPN(bclr,3),
			OPN(bset,4), OPN(bclr,4), OPN(bset,5), OPN(bclr,5), OPN(bset,6), OPN(bclr,6), OPN(bset,7), OPN(bclr,7),
	/* 2 */ OP_T(bra),   OP_F(bra),   OP_T(bhi),   OP_F(bhi),   OP_T(bcc),   OP_F(bcc),   OP_T(bne),   OP_F(bne),
			OP_T(bhcc),  OP_F(bhcc),  OP_T(bpl),   OP_F(bpl),   OP_T(bmc),   OP_F(bmc),   OP_T(bil),   OP_F(bil),
	/* 3 */ OP_DI(neg),  OP(illegal), OP(illegal), OP_DI(com),  OP_DI(lsr),  OP(illegal), OP_DI(ror),  OP_DI(asr),
			OP_DI(lsl),  OP_DI(rol),  OP_DI(dec),  OP(illegal), OP_DI(inc),  OP_DI(tst),  OP(illegal), OP_DI(clr),
	/* 4 */ OP(nega),    OP(illegal), OP(mul),     OP(coma),    OP(lsra),    OP(illegal), OP(rora),    OP(asra),
			OP(lsla),    OP(rola),    OP(deca),    OP(illegal), OP(inca),    OP(tsta),    OP(illegal), OP(clra),
	/* 5 */ OP(negx),    OP(illegal), OP(illegal), OP(comx),    OP(lsrx),    OP(illegal), OP(rorx),    OP(asrx),
			OP(lslx),    OP(rolx),    OP(decx),    OP(illegal), OP(incx),    OP(tstx),    OP(illegal), OP(clrx),
	/* 6 */ OP_IX1(neg), OP(illegal), OP(illegal), OP_IX1(com), OP_IX1(lsr), OP(illegal), OP_IX1(ror), OP_IX1(asr),
			OP_IX1(lsl), OP_IX1(rol), OP_IX1(dec), OP(illegal), OP_IX1(inc), OP_IX1(tst), OP(illegal), OP_IX1(clr),
	/* 7 */ OP_IX(neg),  OP(illegal), OP(illegal), OP_IX(com),  OP_IX(lsr),  OP(illegal), OP_IX(ror),  OP_IX(asr),
			OP_IX(lsl),  OP_IX(rol),  OP_IX(dec),  OP(illegal), OP_IX(inc),  OP_IX(tst),  OP(illegal), OP_IX(clr),
	/* 8 */ OP(rti),     OP(rts),     OP(illegal), OP(swi),     OP(illegal), OP(illegal), OP(illegal), OP(illegal),
			OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(stop),    OP(wait),
	/* 9 */ OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(illegal), OP(tax),
			OP(clc),     OP(sec),     OP(cli),     OP(sei),     OP(rsp),     OP(nop),     OP(illegal), OP(txa),
	/* A */ OP_IM(suba), OP_IM(cmpa), OP_IM(sbca), OP_IM(cpx),  OP_IM(anda), OP_IM(bita), OP_IM(lda),  OP(illegal),
			OP_IM(eora), OP_IM(adca), OP_IM(ora),  OP_IM(adda), OP(illegal), OP(bsr),     OP_IM(ldx),  OP(illegal),
	/* B */ OP_DI(suba), OP_DI(cmpa), OP_DI(sbca), OP_DI(cpx),  OP_DI(anda), OP_DI(bita), OP_DI(lda),  OP_DI(sta),
			OP_DI(eora), OP_DI(adca), OP_DI(ora),  OP_DI(adda), OP_DI(jmp),  OP_DI(jsr),  OP_DI(ldx),  OP_DI(stx),
	/* C */ OP_EX(suba), OP_EX(cmpa), OP_EX(sbca), OP_EX(cpx),  OP_EX(anda), OP_EX(bita), OP_EX(lda),  OP_EX(sta),
			OP_EX(eora), OP_EX(adca), OP_EX(ora),  OP_EX(adda), OP_EX(jmp),  OP_EX(jsr),  OP_EX(ldx),  OP_EX(stx),
	/* D */ OP_IX2(suba),OP_IX2(cmpa),OP_IX2(sbca),OP_IX2(cpx), OP_IX2(anda),OP_IX2(bita),OP_IX2(lda), OP_IX2(sta),
			OP_IX2(eora),OP_IX2(adca),OP_IX2(ora), OP_IX2(adda),OP_IX2(jmp), OP_IX2(jsr), OP_IX2(ldx), OP_IX2(stx),
	/* E */ OP_IX1(suba),OP_IX1(cmpa),OP_IX1(sbca),OP_IX1(cpx), OP_IX1(anda),OP_IX1(bita),OP_IX1(lda), OP_IX1(sta),
			OP_IX1(eora),OP_IX1(adca),OP_IX1(ora), OP_IX1(adda),OP_IX1(jmp), OP_IX1(jsr), OP_IX1(ldx), OP_IX1(stx),
	/* F */ OP_IX(suba), OP_IX(cmpa), OP_IX(sbca), OP_IX(cpx),  OP_IX(anda), OP_IX(bita), OP_IX(lda),  OP_IX(sta),
			OP_IX(eora), OP_IX(adca), OP_IX(ora),  OP_IX(adda), OP_IX(jmp),  OP_IX(jsr),  OP_IX(ldx),  OP_IX(stx)
};
#undef big

#define XX 4 // illegal opcode unknown cycle count
const u8 m6805_base_device::s_hc_cycles[256] =
{
		/* 0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F */
	/*0*/  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
	/*1*/  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
	/*2*/  3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	/*3*/  5,XX,XX, 5, 5,XX, 5, 5, 5, 5, 5,XX, 5, 4,XX, 5,
	/*4*/  3,XX,11, 3, 3,XX, 3, 3, 3, 3, 3,XX, 3, 3,XX, 3,
	/*5*/  3,XX,XX, 3, 3,XX, 3, 3, 3, 3, 3,XX, 3, 3,XX, 3,
	/*6*/  6,XX,XX, 6, 6,XX, 6, 6, 6, 6, 6,XX, 6, 5,XX, 6,
	/*7*/  5,XX,XX, 5, 5,XX, 5, 5, 5, 5, 5,XX, 5, 4,XX, 5,
	/*8*/  9, 6,XX,10,XX,XX,XX,XX,XX,XX,XX,XX,XX,XX, 2, 2,
	/*9*/ XX,XX,XX,XX,XX,XX,XX, 2, 2, 2, 2, 2, 2, 2,XX, 2,
	/*A*/  2, 2, 2, 2, 2, 2, 2,XX, 2, 2, 2, 2,XX, 6, 2,XX,
	/*B*/  3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 3, 3, 2, 5, 3, 4,
	/*C*/  4, 4, 4, 4, 4, 4, 4, 5, 4, 4, 4, 4, 3, 6, 4, 5,
	/*D*/  5, 5, 5, 5, 5, 5, 5, 6, 5, 5, 5, 5, 4, 7, 5, 6,
	/*E*/  4, 4, 4, 4, 4, 4, 4, 5, 4, 4, 4, 4, 3, 6, 4, 5,
	/*F*/  3, 3, 3, 3, 3, 3, 3, 4, 3, 3, 3, 3, 2, 5, 3, 4
};
#undef XX

// m6805_base_device::device_reset, then m68hc05e1's vector
void m6805_base_device::reset() {
	m_ea.d = 0;
	m_pc.d = 0;
	m_s.d = 0;
	m_s.w.l = (u16)m_params.m_sp_mask;
	m_a = 0;
	m_x = 0;
	m_cc = IFLAG;
	rm16<false>(0x1ffe, m_pc);
}

// m6805_base_device::execute_run, one instruction
int m6805_base_device::step() {
	writes.clear();
	u8 const ireg = (u8)rdop<false>(m_pc.w.l++);
	(this->*s_hc_s_ops[ireg])();
	return s_hc_cycles[ireg];
}

void m6805_base_device::interrupt(u16 vector) {
	writes.clear();
	pushword<false>(m_pc);
	pushbyte<false>(m_x);
	pushbyte<false>(m_a);
	pushbyte<false>((u8)(m_cc | 0xe0));
	m_cc |= IFLAG;
	rm16<false>(vector, m_pc);
}

m6805_base_device cpu;

} // namespace hc05ref

using hc05ref::cpu;

extern "C" {

void hc05_ref_init(const uint8_t* rom, uint16_t rom_base, uint16_t rom_size) {
	std::memset(cpu.mem, 0, sizeof cpu.mem);
	for (unsigned i = 0; i < rom_size && rom_base + i < 0x2000u; i++) cpu.mem[rom_base + i] = rom[i];
	cpu.irq = false;
	cpu.writes.clear();
	cpu.reset();
}

void hc05_ref_set_io(hc05_io_read_fn fn, void* ctx) {
	cpu.io_fn = fn;
	cpu.io_ctx = ctx;
}

void hc05_ref_set_irq(int asserted) { cpu.irq = asserted != 0; }

void hc05_ref_get_state(hc05_state_t* s) {
	s->pc = cpu.m_pc.w.l;
	s->a = cpu.m_a;
	s->x = cpu.m_x;
	s->sp = (uint8_t)cpu.m_s.w.l;
	s->cc = cpu.m_cc;
}

void hc05_ref_set_state(const hc05_state_t* s) {
	cpu.m_pc.d = s->pc;
	cpu.m_a = s->a;
	cpu.m_x = s->x;
	cpu.m_s.d = s->sp;
	cpu.m_cc = s->cc;
}

int hc05_ref_step(void) { return cpu.step(); }

void hc05_ref_interrupt(uint16_t vector) { cpu.interrupt(vector); }

unsigned hc05_ref_write_count(void) { return (unsigned)cpu.writes.size(); }

void hc05_ref_write(unsigned i, uint16_t* addr, uint8_t* data) {
	*addr = cpu.writes[i].first;
	*data = cpu.writes[i].second;
}

uint8_t hc05_ref_peek(uint16_t addr) { return cpu.mem[addr & 0x1fff]; }

void hc05_ref_poke(uint16_t addr, uint8_t data) { cpu.mem[addr & 0x1fff] = data; }

}
