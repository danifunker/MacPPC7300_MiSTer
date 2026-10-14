// Drives MacPPC7300_vramwc: random word, byte and line stores and loads on the
// CPU's side (the port's protocol), a memory with random wait states on the
// crossing's side, and two software copies: what the CPU has written (every
// load is checked against it) and what reached the memory (compared with the
// CPU's copy at the end, once everything has drained).
//
//   vramwc_tb [--count N] [--stall P] [--seed S] [--lines L]

#include <verilated.h>
#include "VMacPPC7300_vramwc.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

static const unsigned SPAN = 1u << 14;   // bytes of VRAM used (a few hundred lines)

int main(int argc, char** argv) {
	long count = 200000;
	int stall = 30;
	unsigned seed = 1;
	unsigned lines = 48;                 // the distinct lines the accesses land in (locality)
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char* { if (i + 1 >= argc) std::exit(2); return argv[++i]; };
		if (a == "--count") count = std::atol(next());
		else if (a == "--stall") stall = std::atoi(next());
		else if (a == "--seed") seed = (unsigned)std::atoi(next());
		else if (a == "--lines") lines = (unsigned)std::atoi(next());
		else { std::fprintf(stderr, "unknown option %s\n", a.c_str()); return 2; }
	}
	Verilated::commandArgs(argc, argv);
	auto dut = std::make_unique<VMacPPC7300_vramwc>();
	std::mt19937 rng(seed);
	std::vector<uint8_t> cpu(SPAN, 0), mem(SPAN, 0);
	for (unsigned i = 0; i < SPAN; i++) cpu[i] = mem[i] = (uint8_t)rng();

	// the line layout of the port: word 0 (the lowest address) in bits 255-224,
	// each word big-endian: its lowest address byte in bits 31-24
	auto line_get = [&](std::vector<uint8_t>& m, unsigned a, uint32_t* w) {
		for (int k = 0; k < 8; k++) w[7 - k] = ((uint32_t)m[a + 4 * k] << 24) | ((uint32_t)m[a + 4 * k + 1] << 16) |
		                                       ((uint32_t)m[a + 4 * k + 2] << 8) | m[a + 4 * k + 3];
	};

	auto tick = [&]() {
		dut->clk = 0; dut->eval();
		dut->clk = 1; dut->eval();
	};
	dut->clk = 0; dut->reset = 1; dut->a_req = 0; dut->b_ack = 0;
	tick(); tick();
	dut->reset = 0; tick();

	long done = 0, errors = 0, b_writes = 0, b_reads = 0;
	int b_wait = 0;
	bool b_busy = false;
	// the request in hand on the CPU's side
	bool req = false, we = false, line = false;
	unsigned addr = 0, be = 0;
	uint32_t wword = 0;
	uint32_t wline[8];
	auto rnd = [&](unsigned n) { return (unsigned)(rng() % n); };
	auto line_addr = [&]() { return (rnd(lines) * 32) % SPAN; };

	long cycles = 0;
	while (done < count || req) {
		cycles++;
		if (cycles > count * 60L) { std::printf("stuck after %ld accesses\n", done); return 1; }
		// the crossing's side: a request is taken after a random wait, answered at once
		dut->b_ack = 0;
		if (dut->b_req && !b_busy) { b_busy = true; b_wait = (rnd(100) < (unsigned)stall) ? 1 + (int)rnd(12) : 1; }
		if (b_busy) {
			if (--b_wait == 0) {
				unsigned ba = (dut->b_addr << 2) % SPAN;
				if (dut->b_we) {
					if (!dut->b_line) { std::printf("a word write on the crossing\n"); return 1; }
					b_writes++;
					for (int j = 0; j < 32; j++) {
						if (!((dut->b_be >> j) & 1)) continue;
						// bit j of the mask: the line's byte in bits 8j+7..8j, which is
						// byte 31 - j of the line (byte 0 the lowest address)
						uint8_t v = (uint8_t)(dut->b_wdata[j / 4] >> (8 * (j % 4)));
						mem[ba + 31 - j] = v;
					}
				}
				else {
					if (!dut->b_line) { std::printf("a word read on the crossing\n"); return 1; }
					b_reads++;
					uint32_t w[8];
					line_get(mem, ba, w);
					for (int k = 0; k < 8; k++) dut->b_rdata[k] = w[k];
				}
				dut->b_ack = 1;
				b_busy = false;
			}
		}
		// the CPU's side
		if (req && dut->a_ack) {
			if (!we) {
				if (line) {
					uint32_t w[8];
					line_get(cpu, addr, w);
					for (int k = 0; k < 8; k++)
						if (dut->a_rdata[k] != w[k]) { errors++; if (errors < 10) std::printf("line read %05X word %d: %08X, expected %08X\n", addr, 7 - k, dut->a_rdata[k], w[k]); }
				}
				else {
					uint32_t w = ((uint32_t)cpu[addr] << 24) | ((uint32_t)cpu[addr + 1] << 16) | ((uint32_t)cpu[addr + 2] << 8) | cpu[addr + 3];
					if (dut->a_rdata[0] != w) { errors++; if (errors < 10) std::printf("word read %05X: %08X, expected %08X\n", addr, dut->a_rdata[0], w); }
				}
			}
			req = false;
			dut->a_req = 0;
			done++;
		}
		else if (!req && done < count) {
			req = true;
			unsigned r = rnd(100);
			we = r < 80;
			line = rnd(100) < 5;
			if (line) addr = line_addr();
			else addr = (line_addr() + 4 * rnd(8)) % SPAN;
			be = 0xF;
			if (we && !line) {
				unsigned kind = rnd(4);
				be = kind == 0 ? 0xF : kind == 1 ? (rnd(2) ? 0xC : 0x3) : (1u << rnd(4));
				wword = (uint32_t)rng();
				for (int j = 0; j < 4; j++)
					if ((be >> j) & 1) cpu[addr + 3 - j] = (uint8_t)(wword >> (8 * j));   // be[3]: bits 31-24, the lowest address
			}
			if (we && line) {
				for (int k = 0; k < 8; k++) wline[k] = (uint32_t)rng();
				for (int k = 0; k < 8; k++)   // wline[7 - k] is word k
					for (int j = 0; j < 4; j++) cpu[addr + 4 * k + 3 - j] = (uint8_t)(wline[7 - k] >> (8 * j));
			}
			dut->a_req = 1; dut->a_we = we; dut->a_line = line; dut->a_addr = addr >> 2; dut->a_be = be;
			for (int k = 0; k < 8; k++) dut->a_wdata[k] = line ? wline[k] : (k == 0 ? wword : 0);
		}
		tick();
	}
	// drain: wait until the crossing's side is quiet for a while
	for (int i = 0; i < 2000; i++) {
		dut->b_ack = 0;
		if (dut->b_req && !b_busy) { b_busy = true; b_wait = 1; }
		if (b_busy && --b_wait == 0) {
			unsigned ba = (dut->b_addr << 2) % SPAN;
			if (dut->b_we) {
				b_writes++;
				for (int j = 0; j < 32; j++)
					if ((dut->b_be >> j) & 1) mem[ba + 31 - j] = (uint8_t)(dut->b_wdata[j / 4] >> (8 * (j % 4)));
			}
			dut->b_ack = 1; b_busy = false;
		}
		tick();
	}
	long diff = 0;
	for (unsigned i = 0; i < SPAN; i++)
		if (cpu[i] != mem[i]) { diff++; if (diff < 10) std::printf("memory byte %05X: %02X, the CPU wrote %02X\n", i, mem[i], cpu[i]); }
	std::printf("%ld accesses in %ld cycles; %ld line writes and %ld line reads on the crossing; %ld load errors, %ld bytes differ at the end\n",
	            done, cycles, b_writes, b_reads, errors, diff);
	std::printf("RESULT: %s\n", (errors || diff) ? "FAIL" : "PASS");
	return (errors || diff) ? 1 : 0;
}
