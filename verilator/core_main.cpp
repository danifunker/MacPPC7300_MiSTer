// Runs a program on the DSPPC604 pipeline, with a memory model on its line
// port (random wait states; at the end every line the data cache may hold
// dirty is written back through the snoop port), and checks it in up to
// three ways:
//
//   C records in the program file: the architectural state after a given
//       instruction retires must equal recorded values (golden vectors from a
//       real 604, replayed as code).
//   --lockstep: after every retired instruction the state must equal that of
//       dingusppc's interpreter executing the same program (verilator/ref).
//   Final memory contents must equal the reference's (with --lockstep).
//
// Program file, one record per line, numbers in hex:
//   R pc              reset address
//   M addr word       a word of memory
//   C pc r3 r4 r5 r6 cr xer ctr fpscr f3 f4 f5 f6 tag
//                     state required after the instruction at pc
//   X addr word       a word memory must hold at the end
//   E pc              stop after the instruction at pc

#include <verilated.h>
#include "VDSPPC604.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <random>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#ifdef WITH_REF
#include "dingus_ref.h"
#endif

namespace {

const uint32_t RAM_SIZE = 16u << 20;
const uint32_t RAM_MASK = RAM_SIZE - 1;
const uint32_t PVR_604  = 0x00040303;

struct Check {
	uint32_t r[4], cr, xer, ctr, fpscr;
	uint64_t f[4];
	std::string tag;
};

struct Options {
	std::string prog;
	bool lockstep = false;
	bool trace = false;
	int stall = 0;                 // percent chance of a wait state, per bus per cycle
	long irq_every = 0;            // raise the external interrupt every N cycles
	bool tb_run = false;           // time base and decrementer advance every cycle
	unsigned seed = 1;
	uint64_t max_cycles = 2000000000ull;
	long show = 10;
};

// The memory port: a request (one line or one word) is acknowledged after
// a random number of wait cycles, with the data.
struct Mem {
	bool pending = false;          // a request is in progress
	int wait = 0;                  // cycles until it is answered
	bool ack = false;              // presented to the core this cycle
	uint32_t rdata[8] = {0};
};

uint32_t rd32(const std::vector<uint8_t>& m, uint32_t a) {
	a &= RAM_MASK & ~3u;
	return (uint32_t)m[a] << 24 | (uint32_t)m[a + 1] << 16 | (uint32_t)m[a + 2] << 8 | m[a + 3];
}

void wr32(std::vector<uint8_t>& m, uint32_t a, uint32_t v, uint32_t be) {
	a &= RAM_MASK & ~3u;
	if (be & 8) m[a] = v >> 24;
	if (be & 4) m[a + 1] = v >> 16;
	if (be & 2) m[a + 2] = v >> 8;
	if (be & 1) m[a + 3] = v;
}

void usage() {
	std::printf(
		"usage: core_tb --prog FILE [options]\n"
		"  --lockstep       compare with dingusppc after every instruction\n"
		"  --stall P        percent chance of a bus wait state (default 0)\n"
		"  --seed N         seed for the wait states\n"
		"  --max-cycles N   give up after N clocks\n"
		"  --show N         mismatches printed before stopping (default 10)\n"
		"  --irq-every N    raise the external interrupt every N cycles; a store to\n"
		"                   address 00FFFFF0 takes it away again\n"
		"  --tb-run         advance the time base and decrementer every cycle\n"
		"  --trace          print every retired instruction\n");
}

} // namespace

int main(int argc, char** argv) {
	Options opt;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> std::string {
			if (i + 1 >= argc) { usage(); std::exit(2); }
			return argv[++i];
		};
		if (a == "--prog") opt.prog = next();
		else if (a == "--lockstep") opt.lockstep = true;
		else if (a == "--trace") opt.trace = true;
		else if (a == "--stall") opt.stall = std::atoi(next().c_str());
		else if (a == "--seed") opt.seed = (unsigned)std::strtoul(next().c_str(), nullptr, 0);
		else if (a == "--max-cycles") opt.max_cycles = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--show") opt.show = std::atol(next().c_str());
		else if (a == "--irq-every") opt.irq_every = std::atol(next().c_str());
		else if (a == "--tb-run") opt.tb_run = true;
		else { usage(); return a == "--help" ? 0 : 2; }
	}
	if (opt.prog.empty()) { usage(); return 2; }
#ifndef WITH_REF
	if (opt.lockstep) {
		std::fprintf(stderr, "this build has no reference model; rebuild with the dingusppc library\n");
		return 2;
	}
#endif

	// ---- load the program ----
	std::vector<uint8_t> mem(RAM_SIZE, 0);
	std::map<uint32_t, Check> checks;
	std::vector<std::pair<uint32_t, uint32_t>> expect_mem;
	uint32_t reset_pc = 0x100, end_pc = 0xFFFFFFFF;
	{
		std::ifstream fh(opt.prog);
		if (!fh) { std::fprintf(stderr, "cannot open %s\n", opt.prog.c_str()); return 2; }
		std::string line;
		while (std::getline(fh, line)) {
			if (line.empty() || line[0] == '#') continue;
			std::istringstream ss(line);
			std::string kind;
			ss >> kind >> std::hex;
			if (kind == "R") ss >> reset_pc;
			else if (kind == "E") ss >> end_pc;
			else if (kind == "M") {
				uint32_t a, w;
				ss >> a >> w;
				wr32(mem, a, w, 0xF);
			}
			else if (kind == "C") {
				uint32_t pc;
				Check c;
				ss >> pc >> c.r[0] >> c.r[1] >> c.r[2] >> c.r[3] >> c.cr >> c.xer >> c.ctr >> c.fpscr
				   >> c.f[0] >> c.f[1] >> c.f[2] >> c.f[3] >> c.tag;
				checks[pc] = c;
			}
			else if (kind == "X") {
				uint32_t a, w;
				ss >> a >> w;
				expect_mem.push_back({a, w});
			}
		}
	}

#ifdef WITH_REF
	if (opt.lockstep) {
		if (ref_init(RAM_SIZE, PVR_604) != 0) { std::fprintf(stderr, "reference model failed to start\n"); return 2; }
		std::memcpy(ref_ram(), mem.data(), RAM_SIZE);
		ref_state_t s{};
		s.pc = reset_pc;
		s.msr = 0x40;              // as the core leaves reset
		ref_set_state(&s);
	}
#endif

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<VDSPPC604>(ctx.get());

	std::mt19937 rng(opt.seed);
	auto stalled = [&]() { return opt.stall > 0 && (int)(rng() % 100) < opt.stall; };

	Mem mm;
	uint32_t gpr[32] = {0};
	uint64_t fpr[32] = {0};
	uint64_t cycles = 0, retired = 0;
	long checked = 0, failed = 0;
	bool done = false, diverged = false;
	bool irq = false;
	long irq_count = 0, irq_acks = 0;
	// lines the data cache may hold dirty: every line stored to or zeroed,
	// written back through the snoop port when the program has ended
	std::set<uint32_t> touched;
	// the snoop port: driven by the DMA engine below while the program runs,
	// and at the end to collect the dirty lines
	bool snoop_req = false, snoop_we = false;
	uint32_t snoop_addr = 0;
	// A DMA engine, for the cache test: a store to 00FFFFF4 starts a write of
	// 64 bytes at 00FFF000 (pattern from the value stored), a store to
	// 00FFFFF8 a read of them whose checksum is then written to 00FFFFFC.
	// Every line is snooped first, as the bus demands.
	const uint32_t DMA_BUF = 0x00FFF000, DMA_RESULT = 0x00FFFFFC;
	int dma_step = 0;                     // 0 idle; 1-2 the buffer's lines; 3 the result word
	bool dma_write = false, dma_gap = false;
	uint32_t dma_value = 0, dma_sum = 0;

	auto drive = [&]() {
		dut->ext_irq = irq;
		dut->tb_tick = opt.tb_run;
		dut->mem_ack = mm.ack;
		for (int i = 0; i < 8; i++) dut->mem_rdata[i] = mm.rdata[i];
		dut->snoop_req = snoop_req; dut->snoop_we = snoop_we; dut->snoop_addr = snoop_addr >> 5;
	};

	// The request seen in this cycle, and what the port shows in the next one.
	// Word k of a line, the lowest address first, is in bits 255-32k downward:
	// Verilator's chunk 7-k.
	auto step_mem = [&](bool req, bool we, bool line, uint32_t addr, uint32_t be, const uint32_t* wdata) {
		bool answered = mm.ack;             // the request seen in this cycle is the one just answered
		if (answered) mm.pending = false;
		mm.ack = false;
		if (req && !mm.pending && !answered) {
			mm.pending = true;
			mm.wait = 1;                       // the earliest answer is in the next cycle
			while (stalled()) mm.wait++;
		}
		if (mm.pending) {
			if (--mm.wait == 0) {
				mm.ack = true;
				if (line) {
					uint32_t base = addr & ~31u;
					for (int k = 0; k < 8; k++) {
						if (we) wr32(mem, base + 4 * k, wdata[7 - k], 0xF);
						mm.rdata[7 - k] = rd32(mem, base + 4 * k);
					}
				} else {
					if (we) wr32(mem, addr, wdata[0], be);
					mm.rdata[0] = rd32(mem, addr);
				}
			}
		}
	};

	bool snoop_acked = false;      // the snoop port acknowledged in the last cycle

	auto tick = [&]() {
		drive();
		dut->clk = 0; dut->eval();
		snoop_acked = dut->snoop_ack;
		bool req = dut->mem_req, we = dut->mem_we, line = dut->mem_line;
		uint32_t addr = (uint32_t)dut->mem_addr << 2, be = dut->mem_be;
		uint32_t wdata[8];
		for (int i = 0; i < 8; i++) wdata[i] = dut->mem_wdata[i];
		// data accesses as they reach the cache
		bool dreq = dut->trace_dreq, dwe = dut->trace_dwe;
		uint32_t dkind = dut->trace_dkind, daddr = (uint32_t)dut->trace_daddr << 2;
		if (opt.trace && dreq)
			std::printf("%10llu        data %s kind %u at %08X be %X %08X\n", (unsigned long long)cycles,
				dwe ? "write" : "read ", dkind, daddr, (unsigned)dut->trace_dbe, (uint32_t)dut->trace_dwdata);
		if (opt.trace && req && !mm.pending)
			std::printf("%10llu        memory %s %s at %08X\n", (unsigned long long)cycles,
				we ? "write" : "read ", line ? "line" : "word", addr);
		dut->clk = 1; dut->eval();
		step_mem(req, we, line, addr, be, wdata);
		if (dreq && (dwe || dkind == 1)) touched.insert(daddr & ~31u);
		// the handler acknowledges an interrupt by storing to this address
		if (dreq && dwe && dkind == 0 && daddr == 0x00FFFFF0) { irq = false; irq_acks++; }
		// the cache test starts a DMA transfer by storing to these
		if (dreq && dwe && dkind == 0 && (daddr == 0x00FFFFF4 || daddr == 0x00FFFFF8) && dma_step == 0) {
			dma_write = daddr == 0x00FFFFF4;
			dma_value = dut->trace_dwdata;
			dma_sum   = 0;
			dma_step  = 1;
		}
		// the DMA engine: snoop, then access memory, one line at a time
		if (dma_step >= 1 && dma_step <= 3) {
			if (!snoop_req) {
				if (dma_gap) dma_gap = false;                       // a cycle between snoops
				else {
					snoop_req  = true;
					snoop_we   = dma_write || dma_step == 3;
					snoop_addr = (dma_step == 3) ? DMA_RESULT : DMA_BUF + 32 * (dma_step - 1);
				}
			}
			else if (snoop_acked) {
				snoop_req = false;
				dma_gap   = true;
				if (dma_step <= 2) {
					uint32_t base = DMA_BUF + 32 * (dma_step - 1);
					for (int i = 0; i < 8; i++) {
						if (dma_write) wr32(mem, base + 4 * i, dma_value + 0x01010101u * (uint32_t)(8 * (dma_step - 1) + i), 0xF);
						else dma_sum += rd32(mem, base + 4 * i);
					}
				}
				else wr32(mem, DMA_RESULT, dma_write ? 1 : dma_sum, 0xF);
				dma_step++;
				if (dma_step == 4) dma_step = 0;
			}
		}
		cycles++;
		if (opt.irq_every && !irq && cycles % opt.irq_every == 0) { irq = true; irq_count++; }
	};

	dut->reset_pc = reset_pc;
	dut->reset = 1;
	tick(); tick();
	dut->reset = 0;
	mm = Mem();

	while (!done && cycles < opt.max_cycles) {
		tick();

		if (dut->trace_valid) {
			if (dut->trace_reg_we) {
				unsigned idx = dut->trace_reg_idx;
				if (idx < 32) gpr[idx] = (uint32_t)dut->trace_reg_val;
				else if (idx >= 64) fpr[idx - 64] = dut->trace_reg_val;
			}
			if (dut->trace_last) {
				uint32_t pc = dut->trace_pc, insn = dut->trace_insn;
				retired++;
				if (opt.trace)
					std::printf("%10llu  %08X: %08X  cr=%08X xer=%08X lr=%08X ctr=%08X\n",
						(unsigned long long)cycles, pc, insn, dut->trace_cr, dut->trace_xer, dut->trace_lr, dut->trace_ctr);

				auto it = checks.find(pc);
				if (it != checks.end()) {
					const Check& c = it->second;
					checked++;
					bool ok = gpr[3] == c.r[0] && gpr[4] == c.r[1] && gpr[5] == c.r[2] && gpr[6] == c.r[3] &&
					          dut->trace_cr == c.cr && dut->trace_xer == c.xer && dut->trace_ctr == c.ctr &&
					          dut->trace_fpscr == c.fpscr && fpr[3] == c.f[0] && fpr[4] == c.f[1] &&
					          fpr[5] == c.f[2] && fpr[6] == c.f[3];
					if (!ok) {
						if (failed++ < opt.show) {
							std::printf("FAIL %s at %08X insn=%08X\n", c.tag.c_str(), pc, insn);
							std::printf("  want r3=%08X r4=%08X r5=%08X r6=%08X cr=%08X xer=%08X ctr=%08X fpscr=%08X\n",
								c.r[0], c.r[1], c.r[2], c.r[3], c.cr, c.xer, c.ctr, c.fpscr);
							std::printf("  got  r3=%08X r4=%08X r5=%08X r6=%08X cr=%08X xer=%08X ctr=%08X fpscr=%08X\n",
								gpr[3], gpr[4], gpr[5], gpr[6], dut->trace_cr, dut->trace_xer, dut->trace_ctr,
								dut->trace_fpscr);
							std::printf("  want f3=%016llX f4=%016llX f5=%016llX f6=%016llX\n",
								(unsigned long long)c.f[0], (unsigned long long)c.f[1],
								(unsigned long long)c.f[2], (unsigned long long)c.f[3]);
							std::printf("  got  f3=%016llX f4=%016llX f5=%016llX f6=%016llX\n",
								(unsigned long long)fpr[3], (unsigned long long)fpr[4],
								(unsigned long long)fpr[5], (unsigned long long)fpr[6]);
						}
					}
				}

#ifdef WITH_REF
				if (opt.lockstep) {
					ref_state_t before{}, s{};
					ref_get_state(&before);
					// The core retires nothing for an instruction that takes an
					// exception; the reference has to take it now to catch up.
					for (int tries = 0; tries < 3 && before.pc != pc; tries++) {
						int vec = ref_step();
						if (vec <= 0) break;
						// two places where dingusppc sets SRR1 bits it should not
						if (vec == 0xC00) ref_set_spr(27, ref_get_spr(27) & ~0x00020000u);
						if (vec == 0x800) ref_set_spr(27, ref_get_spr(27) & ~0x00100000u);
						// dingusppc clears CR0 before stwcx.'s store, so a DSI there
						// leaves CR0 changed; a 604 leaves it alone (the programs keep
						// the code where its address is its physical address)
						if (vec == 0x300) {
							const uint8_t* rm = ref_ram();
							uint32_t a = ref_get_spr(26) & RAM_MASK & ~3u;
							uint32_t w = (uint32_t)rm[a] << 24 | (uint32_t)rm[a + 1] << 16 | (uint32_t)rm[a + 2] << 8 | rm[a + 3];
							if ((w >> 26) == 31 && ((w >> 1) & 0x3FF) == 150) {
								ref_state_t t{};
								ref_get_state(&t);
								t.cr = before.cr;
								ref_set_state(&t);
							}
						}
						ref_get_state(&before);
					}
					if (before.pc != pc) {
						std::printf("DIVERGED after %llu instructions: core retired %08X, reference is at %08X\n",
							(unsigned long long)retired, pc, before.pc);
						diverged = true;
						break;
					}
					int rc = ref_step();
					ref_get_state(&s);
					if (opt.trace)
						for (unsigned i = 0; i < ref_last_store_count(); i++) {
							uint32_t a; unsigned sz; uint64_t v;
							ref_last_store(i, &a, &sz, &v);
							std::printf("            reference stores %u bytes %0*llX at %08X\n", sz, 2 * sz, (unsigned long long)v, a);
						}

					// divw/divwu results the architecture leaves undefined: the
					// core follows the real 604, the reference does not
					uint32_t xo9 = (insn >> 1) & 0x1FF;
					if ((insn >> 26) == 31 && (xo9 == 459 || xo9 == 491)) {
						uint32_t a = before.gpr[(insn >> 16) & 31], b = before.gpr[(insn >> 11) & 31];
						if (b == 0 || (xo9 == 491 && a == 0x80000000u && b == 0xFFFFFFFFu)) {
							unsigned rd = (insn >> 21) & 31;
							s.gpr[rd] = gpr[rd];
							if (insn & 1) {
								int32_t v = (int32_t)gpr[rd];
								uint32_t f = (v < 0 ? 8u : v > 0 ? 4u : 2u) | (s.xer >> 31);
								s.cr = (s.cr & 0x0FFFFFFFu) | (f << 28);
							}
							ref_set_state(&s);
						}
					}

					bool same = rc == 0 && s.cr == dut->trace_cr && s.xer == dut->trace_xer &&
					            s.lr == dut->trace_lr && s.ctr == dut->trace_ctr && s.msr == dut->trace_msr;
					for (int r = 0; r < 32 && same; r++) same = s.gpr[r] == gpr[r];
					if (!same) {
						std::printf("MISMATCH after %llu instructions at %08X insn=%08X (reference step returned %X; r0=%08X r1=%08X r2=%08X)\n",
							(unsigned long long)retired, pc, insn, rc, gpr[0], gpr[1], gpr[2]);
						for (int r = 0; r < 32; r++)
							if (s.gpr[r] != gpr[r]) std::printf("  r%-2d   reference %08X  core %08X\n", r, s.gpr[r], gpr[r]);
						if (s.cr != dut->trace_cr)   std::printf("  cr    reference %08X  core %08X\n", s.cr, dut->trace_cr);
						if (s.xer != dut->trace_xer) std::printf("  xer   reference %08X  core %08X\n", s.xer, dut->trace_xer);
						if (s.lr != dut->trace_lr)   std::printf("  lr    reference %08X  core %08X\n", s.lr, dut->trace_lr);
						if (s.ctr != dut->trace_ctr) std::printf("  ctr   reference %08X  core %08X\n", s.ctr, dut->trace_ctr);
						if (s.msr != dut->trace_msr) std::printf("  msr   reference %08X  core %08X\n", s.msr, dut->trace_msr);
						diverged = true;
						break;
					}
				}
#endif
				if (pc == end_pc) done = true;
			}
		}
	}

	// let the last access finish, then have the cache write back every line
	// it may hold dirty, through the snoop port as a DMA engine would
	for (int i = 0; i < 16; i++) tick();
	for (uint32_t a : touched) {
		snoop_req = true; snoop_we = false; snoop_addr = a;
		int n = 0;
		do { tick(); } while (!snoop_acked && ++n < 1000);
		snoop_req = false;
		tick();
	}
	dut->final();

	bool mem_ok = true;
	long mem_bad = 0;
	for (const auto& e : expect_mem) {
		uint32_t got = rd32(mem, e.first);
		if (got != e.second && mem_bad++ < opt.show)
			std::printf("MEMORY at %08X: want %08X, got %08X\n", e.first, e.second, got);
	}
	if (mem_bad) mem_ok = false;
#ifdef WITH_REF
	if (opt.lockstep && !diverged) {
		const uint8_t* rm = ref_ram();
		for (uint32_t a = 0; a < RAM_SIZE; a++) {
			if (rm[a] != mem[a]) {
				std::printf("MEMORY differs at %08X: reference %02X, core %02X\n", a, rm[a], mem[a]);
				mem_ok = false;
				break;
			}
		}
	}
#endif

	std::printf("%llu instructions in %llu cycles (%.2f cycles per instruction)\n",
		(unsigned long long)retired, (unsigned long long)cycles, retired ? (double)cycles / retired : 0.0);
	if (!checks.empty())
		std::printf("recorded-state checks: %ld of %zu reached, %ld failed\n", checked, checks.size(), failed);
	// the interrupt handlers of progs.py's irqtest count in memory
	if (opt.irq_every) {
		uint32_t counted = rd32(mem, 0x00FFFFE0);
		std::printf("external interrupts: %ld raised, %ld acknowledged, %u counted by the handler\n",
			irq_count, irq_acks, counted);
		if (counted != (uint32_t)irq_acks || irq_acks == 0 || irq_count - irq_acks > 1) mem_ok = false;
	}
	if (opt.tb_run) {
		uint32_t counted = rd32(mem, 0x00FFFFE4);
		std::printf("decrementer interrupts counted by the handler: %u\n", counted);
		if (counted == 0) mem_ok = false;
	}
	if (!expect_mem.empty())
		std::printf("memory words checked at the end: %zu, %ld wrong\n", expect_mem.size(), mem_bad);
	if (opt.lockstep) std::printf("lockstep with the reference: %s\n", diverged ? "DIVERGED" : mem_ok ? "identical" : "memory differs");

	bool ok = done && !diverged && mem_ok && failed == 0 && checked == (long)checks.size();
	if (!done && !diverged) std::printf("the program did not reach its end\n");
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	return ok ? 0 : 1;
}
