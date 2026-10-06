// Drives DSPPC604_memcdc with two unrelated clocks: random line and word
// requests on the CPU's side, a memory with random wait states on the
// other, and a software copy of that memory to check every read against.
//
//   cdc_tb [--count N] [--pa PICOSECONDS] [--pb PICOSECONDS] [--stall P] [--seed S]
//
// The CPU's clock period is pa, the memory's pb; the default is 66 MHz
// against 100 MHz. Every ratio the SDRAM controller might run at should
// pass; the two sides never see each other's clock.

#include <verilated.h>
#include "VDSPPC604_memcdc.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

int main(int argc, char** argv) {
	long count = 20000;
	long pa = 15152, pb = 10000;        // picoseconds: 66 MHz, 100 MHz
	int stall = 30;
	unsigned seed = 1;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char* { if (i + 1 >= argc) std::exit(2); return argv[++i]; };
		if (a == "--count") count = std::atol(next());
		else if (a == "--pa") pa = std::atol(next());
		else if (a == "--pb") pb = std::atol(next());
		else if (a == "--stall") stall = std::atoi(next());
		else if (a == "--seed") seed = (unsigned)std::strtoul(next(), nullptr, 0);
		else { std::printf("usage: cdc_tb [--count N] [--pa ps] [--pb ps] [--stall P] [--seed S]\n"); return 2; }
	}

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<VDSPPC604_memcdc>(ctx.get());

	std::mt19937 rng(seed);
	const uint32_t SIZE = 1u << 16;
	std::vector<uint8_t> mem(SIZE, 0), model(SIZE, 0);
	for (uint32_t i = 0; i < SIZE; i++) mem[i] = model[i] = (uint8_t)rng();

	auto rd32 = [&](std::vector<uint8_t>& m, uint32_t a) {
		a &= (SIZE - 1) & ~3u;
		return (uint32_t)m[a] << 24 | (uint32_t)m[a + 1] << 16 | (uint32_t)m[a + 2] << 8 | m[a + 3];
	};
	auto wr32 = [&](std::vector<uint8_t>& m, uint32_t a, uint32_t v, uint32_t be) {
		a &= (SIZE - 1) & ~3u;
		if (be & 8) m[a] = v >> 24;
		if (be & 4) m[a + 1] = v >> 16;
		if (be & 2) m[a + 2] = v >> 8;
		if (be & 1) m[a + 3] = v;
	};

	// the CPU's side
	struct { bool req = false, we = false, line = false; uint32_t addr = 0, be = 0; uint32_t wdata[8] = {0}; uint32_t expect[8] = {0}; } a;
	long issued = 0, answered = 0, errors = 0;
	auto new_request = [&]() {
		a.we   = rng() % 2;
		a.line = rng() % 2;
		a.addr = (rng() % SIZE) & (a.line ? ~31u : ~3u);
		a.be   = a.line ? 0xF : (rng() % 16);
		for (int k = 0; k < 8; k++) a.wdata[k] = rng();
		// what the model says the answer is, applying the write to it
		if (a.line) {
			for (int k = 0; k < 8; k++) {
				if (a.we) wr32(model, a.addr + 4 * k, a.wdata[7 - k], 0xF);
				a.expect[7 - k] = rd32(model, a.addr + 4 * k);
			}
		} else {
			if (a.we) wr32(model, a.addr, a.wdata[0], a.be);
			a.expect[0] = rd32(model, a.addr);
		}
		a.req = true;
		issued++;
	};

	// the memory's side
	struct { bool pending = false, ack = false; int wait = 0; uint32_t rdata[8] = {0}; } b;

	auto drive = [&]() {
		dut->a_req = a.req; dut->a_we = a.we; dut->a_line = a.line; dut->a_addr = a.addr >> 2; dut->a_be = a.be;
		for (int k = 0; k < 8; k++) dut->a_wdata[k] = a.wdata[k];
		dut->b_ack = b.ack;
		for (int k = 0; k < 8; k++) dut->b_rdata[k] = b.rdata[k];
	};

	dut->reset_a = 1; dut->reset_b = 1;
	dut->clk_a = 0; dut->clk_b = 0;
	drive(); dut->eval();
	for (int i = 0; i < 4; i++) {
		dut->clk_a = 1; dut->clk_b = 1; dut->eval();
		dut->clk_a = 0; dut->clk_b = 0; dut->eval();
	}
	dut->reset_a = 0; dut->reset_b = 0;

	// two free-running clocks, by time
	long ta = pa / 2, tb = pb / 2;           // next edge of each
	long gap = 0;                            // cycles of the CPU's clock without an answer
	while (answered < count && errors < 10 && gap < 100000) {
		bool a_edge = ta <= tb;
		long t = a_edge ? ta : tb;
		if (a_edge) ta += pa / 2; else tb += pb / 2;
		(void)t;
		drive();
		if (a_edge) {
			dut->clk_a = !dut->clk_a;
			dut->eval();
			if (dut->clk_a) {
				// after the rising edge: the outputs of this cycle
				gap++;
				if (dut->a_ack) {
					gap = 0;
					answered++;
					int words = a.line ? 8 : 1;
					for (int k = 0; k < words; k++) {
						uint32_t got = dut->a_rdata[a.line ? k : 0];
						if (got != a.expect[a.line ? k : 0]) {
							if (errors++ < 10)
								std::printf("request %ld (%s %s at %08X): word %d want %08X got %08X\n",
									answered, a.we ? "write" : "read", a.line ? "line" : "word", a.addr,
									a.line ? 7 - k : 0, a.expect[a.line ? k : 0], got);
						}
					}
					a.req = false;
				}
				else if (!a.req && issued < count && (rng() % 4 != 0)) new_request();
			}
		} else {
			dut->clk_b = !dut->clk_b;
			dut->eval();
			if (dut->clk_b) {
				// the memory: a request is answered after some wait
				bool req = dut->b_req;
				if (b.ack) { b.ack = false; b.pending = false; }
				else if (req && !b.pending) {
					b.pending = true;
					b.wait = 1;
					while (stall > 0 && (int)(rng() % 100) < stall) b.wait++;
				}
				if (b.pending && --b.wait == 0) {
					bool we = dut->b_we, line = dut->b_line;
					uint32_t addr = (uint32_t)dut->b_addr << 2, be = dut->b_be;
					if (line) {
						for (int k = 0; k < 8; k++) {
							if (we) wr32(mem, addr + 4 * k, dut->b_wdata[7 - k], 0xF);
							b.rdata[7 - k] = rd32(mem, addr + 4 * k);
						}
					} else {
						if (we) wr32(mem, addr, dut->b_wdata[0], be);
						b.rdata[0] = rd32(mem, addr);
					}
					b.ack = true;
				}
			}
		}
	}
	dut->final();

	bool same = std::memcmp(mem.data(), model.data(), SIZE) == 0;
	std::printf("%ld requests answered, %ld wrong; memory %s\n", answered, errors, same ? "as expected" : "DIFFERS");
	bool ok = answered == count && errors == 0 && same;
	if (gap >= 100000) std::printf("no answer for 100000 cycles\n");
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	return ok ? 0 : 1;
}
