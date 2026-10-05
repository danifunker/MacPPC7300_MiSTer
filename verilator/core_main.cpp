// Runs a program on the DSPPC604 pipeline, with a memory model on its two
// buses, and checks it in up to three ways:
//
//   C records in the program file: the architectural state after a given
//       instruction retires must equal recorded values (golden vectors from a
//       real 604, replayed as code).
//   --lockstep: after every retired instruction the state must equal that of
//       dingusppc's interpreter executing the same program (verilator/ref).
//   Final memory contents must equal the reference's (with --lockstep).
//
// Program file, one record per line, numbers in hex:
//   R pc                              reset address
//   M addr word                       a word of memory
//   C pc r3 r4 r5 r6 cr xer ctr tag   check after the instruction at pc
//   E pc                              stop after the instruction at pc

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
	uint32_t r[4], cr, xer, ctr;
	std::string tag;
};

struct Options {
	std::string prog;
	bool lockstep = false;
	bool trace = false;
	int stall = 0;                 // percent chance of a wait state, per bus per cycle
	unsigned seed = 1;
	uint64_t max_cycles = 2000000000ull;
	long show = 10;
};

// One side of the bus protocol: req/gnt, then one rvalid per granted request.
struct Bus {
	bool pending = false;          // a granted request has not been answered
	int wait = 0;                  // cycles until it may be
	bool we = false;
	uint32_t addr = 0, be = 0, wdata = 0;
	bool gnt = true;               // inputs presented to the core this cycle
	bool rvalid = false;
	uint32_t rdata = 0;
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
				ss >> pc >> c.r[0] >> c.r[1] >> c.r[2] >> c.r[3] >> c.cr >> c.xer >> c.ctr >> c.tag;
				checks[pc] = c;
			}
		}
	}

#ifdef WITH_REF
	if (opt.lockstep) {
		if (ref_init(RAM_SIZE, PVR_604) != 0) { std::fprintf(stderr, "reference model failed to start\n"); return 2; }
		std::memcpy(ref_ram(), mem.data(), RAM_SIZE);
		ref_state_t s{};
		s.pc = reset_pc;
		ref_set_state(&s);
	}
#endif

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<VDSPPC604>(ctx.get());

	std::mt19937 rng(opt.seed);
	auto stalled = [&]() { return opt.stall > 0 && (int)(rng() % 100) < opt.stall; };

	Bus ib, db;
	uint32_t gpr[32] = {0};
	uint64_t cycles = 0, retired = 0;
	long checked = 0, failed = 0;
	bool done = false, diverged = false;

	auto drive = [&]() {
		dut->ibus_gnt = ib.gnt; dut->ibus_rvalid = ib.rvalid; dut->ibus_rdata = ib.rdata;
		dut->dbus_gnt = db.gnt; dut->dbus_rvalid = db.rvalid; dut->dbus_rdata = db.rdata;
	};

	// The request seen in this cycle, and what the bus shows in the next one.
	auto step_bus = [&](Bus& b, bool req, bool we, uint32_t addr, uint32_t be, uint32_t wdata) {
		bool answered = b.rvalid;
		if (answered) b.pending = false;
		if (req && b.gnt) {
			b.pending = true;
			b.we = we; b.addr = addr; b.be = be; b.wdata = wdata;
			b.wait = 0;
			while (stalled()) b.wait++;
		} else if (b.pending && !answered && b.wait > 0) {
			b.wait--;
		}
		b.rvalid = false;
		if (b.pending && b.wait == 0) {
			// answer in the next cycle (at least one cycle after the grant)
			b.rvalid = true;
			if (b.we) wr32(mem, b.addr, b.wdata, b.be);
			b.rdata = b.we ? 0 : rd32(mem, b.addr);
		}
		// a new request can be taken when nothing is outstanding, or the
		// outstanding one is answered in that same cycle
		b.gnt = (!b.pending || b.rvalid) && !stalled();
	};

	auto tick = [&]() {
		drive();
		dut->clk = 0; dut->eval();
		bool ireq = dut->ibus_req, dreq = dut->dbus_req;
		uint32_t iaddr = dut->ibus_addr;
		bool dwe = dut->dbus_we;
		uint32_t daddr = (uint32_t)dut->dbus_addr << 2, dbe = dut->dbus_be, dwd = dut->dbus_wdata;
		dut->clk = 1; dut->eval();
		step_bus(ib, ireq, false, iaddr, 0xF, 0);
		step_bus(db, dreq, dwe, daddr, dbe, dwd);
		cycles++;
	};

	dut->reset_pc = reset_pc;
	dut->reset = 1;
	ib.gnt = db.gnt = false;
	tick(); tick();
	dut->reset = 0;
	ib = Bus(); db = Bus();

	while (!done && cycles < opt.max_cycles) {
		tick();

		if (dut->trace_valid) {
			if (dut->trace_gpr_we && dut->trace_gpr_idx < 32) gpr[dut->trace_gpr_idx] = dut->trace_gpr_val;
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
					          dut->trace_cr == c.cr && dut->trace_xer == c.xer && dut->trace_ctr == c.ctr;
					if (!ok) {
						if (failed++ < opt.show) {
							std::printf("FAIL %s at %08X insn=%08X\n", c.tag.c_str(), pc, insn);
							std::printf("  want r3=%08X r4=%08X r5=%08X r6=%08X cr=%08X xer=%08X ctr=%08X\n",
								c.r[0], c.r[1], c.r[2], c.r[3], c.cr, c.xer, c.ctr);
							std::printf("  got  r3=%08X r4=%08X r5=%08X r6=%08X cr=%08X xer=%08X ctr=%08X\n",
								gpr[3], gpr[4], gpr[5], gpr[6], dut->trace_cr, dut->trace_xer, dut->trace_ctr);
						}
					}
				}

#ifdef WITH_REF
				if (opt.lockstep) {
					ref_state_t before{}, s{};
					ref_get_state(&before);
					if (before.pc != pc) {
						std::printf("DIVERGED after %llu instructions: core retired %08X, reference is at %08X\n",
							(unsigned long long)retired, pc, before.pc);
						diverged = true;
						break;
					}
					int rc = ref_step();
					ref_get_state(&s);

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
					            s.lr == dut->trace_lr && s.ctr == dut->trace_ctr;
					for (int r = 0; r < 32 && same; r++) same = s.gpr[r] == gpr[r];
					if (!same) {
						std::printf("MISMATCH after %llu instructions at %08X insn=%08X (reference step returned %X)\n",
							(unsigned long long)retired, pc, insn, rc);
						for (int r = 0; r < 32; r++)
							if (s.gpr[r] != gpr[r]) std::printf("  r%-2d   reference %08X  core %08X\n", r, s.gpr[r], gpr[r]);
						if (s.cr != dut->trace_cr)   std::printf("  cr    reference %08X  core %08X\n", s.cr, dut->trace_cr);
						if (s.xer != dut->trace_xer) std::printf("  xer   reference %08X  core %08X\n", s.xer, dut->trace_xer);
						if (s.lr != dut->trace_lr)   std::printf("  lr    reference %08X  core %08X\n", s.lr, dut->trace_lr);
						if (s.ctr != dut->trace_ctr) std::printf("  ctr   reference %08X  core %08X\n", s.ctr, dut->trace_ctr);
						diverged = true;
						break;
					}
				}
#endif
				if (pc == end_pc) done = true;
			}
		}
		if (dut->halted) {
			std::printf("core halted at %08X (instruction not implemented)\n", dut->halt_pc);
			break;
		}
	}

	// let the last store reach memory
	for (int i = 0; i < 8; i++) tick();
	dut->final();

	bool mem_ok = true;
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
	if (opt.lockstep) std::printf("lockstep with the reference: %s\n", diverged ? "DIVERGED" : mem_ok ? "identical" : "memory differs");

	bool ok = done && !diverged && mem_ok && failed == 0 && checked == (long)checks.size();
	if (!done && !diverged) std::printf("the program did not reach its end\n");
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	return ok ? 0 : 1;
}
