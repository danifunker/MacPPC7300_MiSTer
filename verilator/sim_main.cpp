// Replays single-instruction golden vectors from a real PowerPC against the
// DSPPC604 execute units (through vector_dut) and reports every difference.
//
// The vectors are the CSV written by `ppctest.py results`: the out_* columns
// are what the real chip produced.

#include <verilated.h>
#include "Vvector_dut.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct State {
	uint32_t r[4];      // r3..r6
	uint32_t cr, xer, ctr, fpscr;
	uint64_t f[4];      // f3..f6
};

struct Vector {
	long        index = 0;
	std::string name;
	std::string source;
	uint32_t    insn = 0;
	State       in{};   // in.f[0] (f3) is always +0.0
	State       out{};
};

enum Outcome { PASS, FAIL, UNIMPL };

struct Tally {
	long vectors = 0, pass = 0, fail = 0, unimpl = 0, shown = 0;
	unsigned max_cycles = 0;
};

struct Options {
	std::string csv = "../ppctest/runs/results_604_run2.csv";
	std::string only;                  // "", "int" or "fp"
	std::vector<std::string> names;    // empty: all
	long show = 4;                     // failures printed per instruction
	bool variants = false;             // one table row per Rc/OE variant
};

std::string upper(std::string s) {
	std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::toupper(c); });
	return s;
}

std::vector<std::string> split(const std::string& line, char sep) {
	std::vector<std::string> out;
	std::string item;
	std::stringstream ss(line);
	while (std::getline(ss, item, sep)) out.push_back(item);
	return out;
}

bool load_csv(const std::string& path, std::vector<Vector>& vectors) {
	std::ifstream fh(path);
	if (!fh) {
		std::fprintf(stderr, "cannot open %s\n", path.c_str());
		return false;
	}
	std::string line;
	if (!std::getline(fh, line)) return false;
	if (!line.empty() && line.back() == '\r') line.pop_back();
	std::map<std::string, size_t> col;
	{
		auto head = split(line, ',');
		for (size_t i = 0; i < head.size(); i++) col[head[i]] = i;
	}
	static const char* needed[] = {
		"index", "name", "source", "insn",
		"in_r3", "in_r4", "in_r5", "in_r6", "in_cr", "in_xer", "in_ctr", "in_fpscr",
		"in_f4", "in_f5", "in_f6",
		"out_r3", "out_r4", "out_r5", "out_r6", "out_cr", "out_xer", "out_ctr", "out_fpscr",
		"out_f3", "out_f4", "out_f5", "out_f6"};
	for (const char* n : needed) {
		if (!col.count(n)) {
			std::fprintf(stderr, "%s: column %s is missing\n", path.c_str(), n);
			return false;
		}
	}
	while (std::getline(fh, line)) {
		if (!line.empty() && line.back() == '\r') line.pop_back();
		if (line.empty()) continue;
		auto t = split(line, ',');
		auto hex = [&](const char* n) { return std::strtoull(t.at(col[n]).c_str(), nullptr, 16); };
		Vector v;
		v.index  = std::strtol(t.at(col["index"]).c_str(), nullptr, 10);
		v.name   = t.at(col["name"]);
		v.source = t.at(col["source"]);
		v.insn   = (uint32_t)hex("insn");
		v.in.r[0] = (uint32_t)hex("in_r3");
		v.in.r[1] = (uint32_t)hex("in_r4");
		v.in.r[2] = (uint32_t)hex("in_r5");
		v.in.r[3] = (uint32_t)hex("in_r6");
		v.in.cr    = (uint32_t)hex("in_cr");
		v.in.xer   = (uint32_t)hex("in_xer");
		v.in.ctr   = (uint32_t)hex("in_ctr");
		v.in.fpscr = (uint32_t)hex("in_fpscr");
		v.in.f[0] = 0;
		v.in.f[1] = hex("in_f4");
		v.in.f[2] = hex("in_f5");
		v.in.f[3] = hex("in_f6");
		v.out.r[0] = (uint32_t)hex("out_r3");
		v.out.r[1] = (uint32_t)hex("out_r4");
		v.out.r[2] = (uint32_t)hex("out_r5");
		v.out.r[3] = (uint32_t)hex("out_r6");
		v.out.cr    = (uint32_t)hex("out_cr");
		v.out.xer   = (uint32_t)hex("out_xer");
		v.out.ctr   = (uint32_t)hex("out_ctr");
		v.out.fpscr = (uint32_t)hex("out_fpscr");
		v.out.f[0] = hex("out_f3");
		v.out.f[1] = hex("out_f4");
		v.out.f[2] = hex("out_f5");
		v.out.f[3] = hex("out_f6");
		vectors.push_back(v);
	}
	return true;
}

// The values the hardware harness's mtxer and mtfsf 0xFF left in the
// registers: a 604 keeps XER bits 0-2, 16-23 and 25-31, and every FPSCR bit
// but the two summaries, which it derives, and reserved bit 20.
uint32_t held_xer(uint32_t x) {
	return x & 0xE000FF7Fu;
}

uint32_t held_fpscr(uint32_t x) {
	x &= 0x9FFFF7FFu;
	if (x & 0x01F80700u) x |= 0x20000000u;                       // VX
	if (((x & 0x20000000u) && (x & 0x80u)) || ((x & 0x10000000u) && (x & 0x40u)) ||
	    ((x & 0x08000000u) && (x & 0x20u)) || ((x & 0x04000000u) && (x & 0x10u)) ||
	    ((x & 0x02000000u) && (x & 0x08u)))
		x |= 0x40000000u;                                        // FEX
	return x;
}

bool is_fp(const Vector& v) {
	uint32_t op = v.insn >> 26;
	return op == 59 || op == 63;
}

// divw / divwu whose quotient the architecture leaves undefined
bool is_undefined_divide(const Vector& v) {
	if ((v.insn >> 26) != 31) return false;
	uint32_t xo = (v.insn >> 1) & 0x1FF;
	uint32_t a = v.in.r[0], b = v.in.r[1];
	if (xo == 459) return b == 0;
	if (xo == 491) return b == 0 || (a == 0x80000000u && b == 0xFFFFFFFFu);
	return false;
}

struct Diff {
	const char* field;
	uint64_t want, got;
	bool wide;
};

std::vector<Diff> compare(const State& want, const State& got) {
	std::vector<Diff> d;
	static const char* rn[] = {"r3", "r4", "r5", "r6"};
	static const char* fn[] = {"f3", "f4", "f5", "f6"};
	for (int i = 0; i < 4; i++)
		if (want.r[i] != got.r[i]) d.push_back({rn[i], want.r[i], got.r[i], false});
	if (want.cr != got.cr)       d.push_back({"cr", want.cr, got.cr, false});
	if (want.xer != got.xer)     d.push_back({"xer", want.xer, got.xer, false});
	if (want.ctr != got.ctr)     d.push_back({"ctr", want.ctr, got.ctr, false});
	if (want.fpscr != got.fpscr) d.push_back({"fpscr", want.fpscr, got.fpscr, false});
	for (int i = 0; i < 4; i++)
		if (want.f[i] != got.f[i]) d.push_back({fn[i], want.f[i], got.f[i], true});
	return d;
}

void print_failure(const Vector& v, const std::vector<Diff>& diffs, bool unimpl, bool timeout) {
	std::printf("  %s #%ld %s insn=%08X", unimpl ? "UNIMPLEMENTED" : "FAIL", v.index, v.name.c_str(), v.insn);
	if (is_fp(v))
		std::printf("  f4=%016llX f5=%016llX f6=%016llX fpscr=%08X cr=%08X\n",
			(unsigned long long)v.in.f[1], (unsigned long long)v.in.f[2],
			(unsigned long long)v.in.f[3], v.in.fpscr, v.in.cr);
	else
		std::printf("  r3=%08X r4=%08X xer=%08X cr=%08X\n", v.in.r[0], v.in.r[1], v.in.xer, v.in.cr);
	if (timeout) std::printf("      no response from the unit\n");
	if (unimpl) return;
	for (const Diff& d : diffs) {
		if (d.wide)
			std::printf("      %-5s want %016llX  got %016llX\n", d.field,
				(unsigned long long)d.want, (unsigned long long)d.got);
		else
			std::printf("      %-5s want %08X  got %08X\n", d.field, (uint32_t)d.want, (uint32_t)d.got);
	}
}

void usage() {
	std::printf(
		"usage: vector_tb [options]\n"
		"  --csv FILE     golden results (default ../ppctest/runs/results_604_run2.csv)\n"
		"  --only int|fp  integer or floating-point vectors only\n"
		"  --name A,B,..  only these instructions (ADDE matches ADDE, ADDE., ADDEO, ADDEO.)\n"
		"  --show N       failures printed per instruction (default 4, 0 for none)\n"
		"  --variants     one table row per Rc/OE variant\n");
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
		if (a == "--csv") opt.csv = next();
		else if (a == "--only") opt.only = next();
		else if (a == "--name") { for (auto& n : split(next(), ',')) opt.names.push_back(upper(n)); }
		else if (a == "--show") opt.show = std::strtol(next().c_str(), nullptr, 10);
		else if (a == "--variants") opt.variants = true;
		else { usage(); return a == "--help" || a == "-h" ? 0 : 2; }
	}
	if (!opt.only.empty() && opt.only != "int" && opt.only != "fp") { usage(); return 2; }

	std::vector<Vector> vectors;
	if (!load_csv(opt.csv, vectors)) return 2;

	// ADDO. and ADD belong to one instruction; FCMPO does not belong to "FCMP".
	std::set<std::string> plain;
	for (const Vector& v : vectors) {
		std::string n = v.name;
		if (!n.empty() && n.back() == '.') n.pop_back();
		plain.insert(n);
	}
	auto base_of = [&](const std::string& name) {
		std::string n = name;
		if (!n.empty() && n.back() == '.') n.pop_back();
		if (n.size() > 1 && n.back() == 'O' && plain.count(n.substr(0, n.size() - 1))) n.pop_back();
		return n;
	};

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<Vvector_dut>(ctx.get());

	auto tick = [&]() {
		dut->clk = 0; dut->eval();
		dut->clk = 1; dut->eval();
	};

	dut->start = 0;
	dut->reset = 1;
	tick(); tick();
	dut->reset = 0;
	tick();

	std::vector<std::string> order;
	std::map<std::string, Tally> tally;
	Tally total_int, total_fp, undef;
	std::vector<std::pair<Vector, std::vector<Diff>>> undef_fails;

	for (const Vector& v : vectors) {
		bool fp = is_fp(v);
		if (opt.only == "int" && fp) continue;
		if (opt.only == "fp" && !fp) continue;
		std::string base = base_of(v.name);
		if (!opt.names.empty() &&
		    std::find(opt.names.begin(), opt.names.end(), upper(base)) == opt.names.end() &&
		    std::find(opt.names.begin(), opt.names.end(), upper(v.name)) == opt.names.end())
			continue;

		dut->insn     = v.insn;
		dut->in_r3    = v.in.r[0];
		dut->in_r4    = v.in.r[1];
		dut->in_r5    = v.in.r[2];
		dut->in_r6    = v.in.r[3];
		dut->in_cr    = v.in.cr;
		dut->in_xer   = held_xer(v.in.xer);
		dut->in_ctr   = v.in.ctr;
		dut->in_fpscr = held_fpscr(v.in.fpscr);
		dut->in_f4    = v.in.f[1];
		dut->in_f5    = v.in.f[2];
		dut->in_f6    = v.in.f[3];
		dut->start    = 1;
		tick();
		dut->start    = 0;

		unsigned cycles = 0;
		bool timeout = false;
		while (!dut->done) {
			tick();
			if (++cycles > 1000) { timeout = true; break; }
		}

		State got{};
		got.r[0] = dut->out_r3; got.r[1] = dut->out_r4; got.r[2] = dut->out_r5; got.r[3] = dut->out_r6;
		got.cr = dut->out_cr; got.xer = dut->out_xer; got.ctr = dut->out_ctr; got.fpscr = dut->out_fpscr;
		got.f[0] = dut->out_f3; got.f[1] = dut->out_f4; got.f[2] = dut->out_f5; got.f[3] = dut->out_f6;
		bool unimpl = dut->unimplemented;

		if (timeout) {
			// get the wrapper back to idle
			dut->reset = 1; tick(); tick(); dut->reset = 0; tick();
		} else {
			tick();   // done -> idle
		}

		auto diffs = compare(v.out, got);
		Outcome oc = unimpl ? UNIMPL : (diffs.empty() && !timeout) ? PASS : FAIL;

		if (is_undefined_divide(v)) {
			undef.vectors++;
			if (oc == PASS) undef.pass++;
			else { undef.fail++; undef_fails.push_back({v, diffs}); }
			continue;
		}

		std::string key = opt.variants ? v.name : base;
		if (!tally.count(key)) order.push_back(key);
		Tally& t = tally[key];
		Tally& tot = fp ? total_fp : total_int;
		t.vectors++; tot.vectors++;
		if (cycles > t.max_cycles) t.max_cycles = cycles;
		if (oc == PASS) { t.pass++; tot.pass++; }
		else {
			if (oc == UNIMPL) { t.unimpl++; tot.unimpl++; }
			else { t.fail++; tot.fail++; }
			// one line is enough to say an instruction is not there yet
			long limit = (oc == UNIMPL) ? std::min(opt.show, 1L) : opt.show;
			if (t.shown < limit) {
				if (t.shown == 0) std::printf("%s\n", key.c_str());
				print_failure(v, diffs, oc == UNIMPL, timeout);
				t.shown++;
			}
		}
	}

	dut->final();

	std::printf("\n%-12s %8s %8s %8s %8s %7s\n", "instruction", "vectors", "pass", "fail", "unimpl", "cycles");
	for (const std::string& key : order) {
		const Tally& t = tally[key];
		std::printf("%-12s %8ld %8ld %8ld %8ld %7u%s\n", key.c_str(), t.vectors, t.pass, t.fail, t.unimpl,
			t.max_cycles, (t.fail || t.unimpl) ? "  <--" : "");
	}

	std::printf("\n");
	if (total_int.vectors)
		std::printf("integer         %6ld vectors  %6ld pass  %6ld fail  %6ld unimplemented\n",
			total_int.vectors, total_int.pass, total_int.fail, total_int.unimpl);
	if (total_fp.vectors)
		std::printf("floating point  %6ld vectors  %6ld pass  %6ld fail  %6ld unimplemented\n",
			total_fp.vectors, total_fp.pass, total_fp.fail, total_fp.unimpl);
	if (undef.vectors) {
		std::printf("undefined divides (kept apart): %ld vectors, %ld identical to the real chip, %ld differ\n",
			undef.vectors, undef.pass, undef.fail);
		long n = 0;
		for (auto& uf : undef_fails) {
			if (n++ >= opt.show) break;
			print_failure(uf.first, uf.second, false, false);
		}
	}

	// Vectors the execute units cannot run on their own (loads, stores, the
	// moves to and from XER and FPSCR) are reported, not counted as failures:
	// run_core.py runs every vector file as a program through the pipeline.
	long bad = total_int.fail + total_fp.fail;
	long ran = total_int.vectors + total_fp.vectors + undef.vectors;
	if (ran == 0) {
		std::printf("no vectors selected\n");
		return 2;
	}
	std::printf("\n%s\n", bad == 0 ? "RESULT: PASS" : "RESULT: FAIL");
	return bad == 0 ? 0 : 1;
}
