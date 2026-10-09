// The SDRAM controller's bench: MacPPC7300_sdram behind DSPPC604_memcdc
// (sdram_tb_top.sv), driven on the CPU's side with random line and word
// requests (the CDC bench's patterns) and on the upload port with a file
// written byte by byte, against a behavioural model of the SDRAM board.
//
//   sdram_tb [--count N] [--pa PS] [--pb PS] [--upload BYTES] [--seed S] [--show N]
//
// The model is a MiSTer 128 MB board: two ranks of 4 banks x 8192 rows x
// 1024 columns x 16 bits, nCS low selecting rank 0 and the board inverting
// it for rank 1. It runs on the SDRAM's clock (the controller's clock
// inverted, as SDRAM_CLK is on the board), holds the data, puts read data on
// the bus CAS latency 2 after the READ, and checks every command against the
// sequence and timings of an AS4C32M16SB-6 class part (the faster grade the
// MiSTer boards use; the -7's tRCD and tRP are 21 ns, see below):
//   power-up: 100 us of NOPs, then per rank PRECHARGE ALL, two AUTO REFRESH,
//     LOAD MODE (burst 8, sequential, CAS 2, single writes: 0x223), before
//     any ACTIVE; tMRD 2 clocks after LOAD MODE
//   ACTIVE only on an idle bank, tRP after its PRECHARGE, tRC after its last
//     ACTIVE, tRRD after the rank's last ACTIVE, tRFC after a refresh
//   READ and WRITE only on an open row, tRCD after its ACTIVE, column < 1024
//   PRECHARGE tRAS after the ACTIVE, tWR after the bank's last WRITE
//   AUTO REFRESH with every bank of the rank idle, tRP after the last
//     PRECHARGE; at most 8 refreshes owed at any time (7.8 us each)
//   the controller drives the bus only for a WRITE and never while the chip
//     drives read data; DQM low on every read beat (it never masks a read)
// Every read is checked against a software copy of the memory, and at the
// end the model's whole contents are compared with it.

#include <verilated.h>
#include "Vsdram_tb_top.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {

const uint32_t SIZE = 128u << 20;            // the board
const uint32_t UP_BASE = SIZE - (4u << 20);  // where the ROM goes

// timings in ns (AS4C32M16SB-6: tRCD = tRP = 18; the -7 grade's 21 ns would
// need three clocks at 100 MHz where sdram.sv has run two on hardware)
const double T_RCD = 18, T_RP = 18, T_RAS = 42, T_RC = 60, T_RFC = 60, T_RRD = 12, T_WR = 12;
const double T_REFI = 7812.5, T_POWERUP = 100000;
const int CL = 2;

int errors = 0, show = 10;
void fail(long cyc, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void fail(long cyc, const char* fmt, ...) {
	if (errors++ < show) {
		std::printf("SDRAM clock %ld: ", cyc);
		va_list ap;
		va_start(ap, fmt);
		std::vprintf(fmt, ap);
		va_end(ap);
		std::printf("\n");
	}
}

uint8_t init_byte(uint32_t a) { return (uint8_t)((a * 2654435761u) >> 24); }

struct Chip {
	double tck;                                   // SDRAM clock period, ns
	std::vector<uint16_t> mem;                    // [rank][bank][row][col]
	struct Bank { bool open = false; int row = 0; long t_act = -1000000, t_pre = -1000000, t_wr = -1000000; };
	struct Rank {
		Bank b[4];
		int stage = 0;                            // 0 none, 1 precharged, 2-3 refreshes, 4 mode set
		long t_ref = -1000000, t_mode = -1000000, t_act = -1000000;
		long refreshes = 0, ready_at = -1;
	} rk[2];
	// read data on the bus: per SDRAM clock, the halfword index or -1
	struct Beat { long cyc; int rank; uint32_t index; };
	std::vector<Beat> beats;                      // pending, in order
	int dqm_hist[3] = {0, 0, 0};                  // DQM of the last three clocks
	long first_cmd = -1;
	int max_owed = 0;

	explicit Chip(double tck_ns) : tck(tck_ns), mem(SIZE / 2) {
		for (uint32_t i = 0; i < SIZE / 2; i++) {
			// the same contents the bench's copy starts with, by byte offset
			uint32_t off = offset_of(i);
			mem[i] = (uint16_t)(init_byte(off) << 8 | init_byte(off + 1));
		}
	}
	static uint32_t index(int rank, int bank, int row, int col) {
		return (((uint32_t)rank * 4 + bank) * 8192 + row) * 1024 + col;
	}
	// the controller's documented map: rank off[26], bank off[25:24],
	// row off[23:11], column off[10:1]
	static uint32_t offset_of(uint32_t idx) {
		uint32_t col = idx & 1023, row = (idx >> 10) & 8191, bank = (idx >> 23) & 3, rank = idx >> 25;
		return rank << 26 | bank << 24 | row << 11 | col << 1;
	}
	bool met(long since, double ns, long now) const { return (now - since) * tck >= ns - 1e-6; }

	// one SDRAM clock: the command on the pins, and the bus for the next half
	void edge(long n, bool ncs, bool nras, bool ncas, bool nwe, int ba, int a, int dqm,
	          bool fpga_drives, uint16_t fpga_dq, bool& drive, uint16_t& dq) {
		int r = ncs ? 1 : 0;                      // the board inverts nCS for rank 1
		int cmd = (nras << 2) | (ncas << 1) | nwe;
		Rank& R = rk[r];
		dqm_hist[2] = dqm_hist[1]; dqm_hist[1] = dqm_hist[0]; dqm_hist[0] = dqm;
		if (cmd != 7) {
			if (first_cmd < 0) {
				first_cmd = n;
				if (n * tck < T_POWERUP) fail(n, "first command after %.1f us, before 100 us of NOPs", n * tck / 1000);
			}
			if (cmd != 2 && cmd != 1 && cmd != 0 && R.stage < 4) fail(n, "rank %d: command %d before its mode register is set", r, cmd);
			if (R.stage == 4 && !met(R.t_mode, 2 * tck, n)) fail(n, "rank %d: command within tMRD of LOAD MODE", r);
			if (!met(R.t_ref, T_RFC, n)) fail(n, "rank %d: command %d within tRFC of a refresh", r, cmd);
		}
		switch (cmd) {
		case 3: {                                  // ACTIVE
			Bank& B = R.b[ba];
			if (B.open) fail(n, "rank %d bank %d: ACTIVE on an open bank", r, ba);
			if (!met(B.t_pre, T_RP, n)) fail(n, "rank %d bank %d: ACTIVE %ld clocks after PRECHARGE (tRP)", r, ba, n - B.t_pre);
			if (!met(B.t_act, T_RC, n)) fail(n, "rank %d bank %d: ACTIVE %ld clocks after ACTIVE (tRC)", r, ba, n - B.t_act);
			if (!met(R.t_act, T_RRD, n)) fail(n, "rank %d: ACTIVE within tRRD of another", r);
			B.open = true; B.row = a & 8191; B.t_act = n; R.t_act = n;
			break;
		}
		case 5: case 4: {                          // READ, WRITE
			Bank& B = R.b[ba];
			int col = a & 1023;
			if (a & 0x400) fail(n, "auto-precharge requested (A10) on a %s", cmd == 5 ? "READ" : "WRITE");
			if (!B.open) { fail(n, "rank %d bank %d: %s on a closed bank", r, ba, cmd == 5 ? "READ" : "WRITE"); break; }
			if (!met(B.t_act, T_RCD, n)) fail(n, "rank %d bank %d: %s %ld clocks after ACTIVE (tRCD)", r, ba, cmd == 5 ? "READ" : "WRITE", n - B.t_act);
			// a new command ends a read burst still on the bus
			while (!beats.empty() && beats.back().cyc > n + (cmd == 5 ? CL - 1 : -1)) {
				if (cmd == 4 && beats.back().cyc <= n) fail(n, "WRITE while read data is on the bus");
				beats.pop_back();
			}
			if (cmd == 5) {
				for (int k = 0; k < 8; k++) {      // burst of 8, sequential, wrapping in the aligned block
					int c = (col & ~7) | ((col + k) & 7);
					beats.push_back({n + CL + k, r, index(r, ba, B.row, c)});
				}
			} else {
				if (!fpga_drives) fail(n, "WRITE without the data bus driven");
				uint16_t& w = mem[index(r, ba, B.row, col)];
				if (!(dqm & 2)) w = (uint16_t)((w & 0x00FF) | (fpga_dq & 0xFF00));
				if (!(dqm & 1)) w = (uint16_t)((w & 0xFF00) | (fpga_dq & 0x00FF));
				B.t_wr = n;
			}
			break;
		}
		case 2: {                                  // PRECHARGE
			for (int b = 0; b < 4; b++) {
				if (!(a & 0x400) && b != ba) continue;
				Bank& B = R.b[b];
				if (B.open && !met(B.t_act, T_RAS, n)) fail(n, "rank %d bank %d: PRECHARGE %ld clocks after ACTIVE (tRAS)", r, b, n - B.t_act);
				if (B.open && !met(B.t_wr, T_WR, n) ) fail(n, "rank %d bank %d: PRECHARGE within tWR of a write", r, b);
				if (B.open || (a & 0x400)) B.t_pre = n;
				B.open = false;
			}
			for (const Beat& bt : beats) if (bt.rank == r && bt.cyc > n) fail(n, "PRECHARGE during a read burst");
			if ((a & 0x400) && R.stage == 0) R.stage = 1;
			break;
		}
		case 1: {                                  // AUTO REFRESH
			for (int b = 0; b < 4; b++) {
				if (R.b[b].open) fail(n, "rank %d: refresh with bank %d open", r, b);
				if (!met(R.b[b].t_pre, T_RP, n)) fail(n, "rank %d: refresh within tRP of a precharge", r);
			}
			if (R.stage >= 1 && R.stage < 3) R.stage++;
			R.t_ref = n;
			R.refreshes++;
			break;
		}
		case 0: {                                  // LOAD MODE
			for (int b = 0; b < 4; b++) if (R.b[b].open) fail(n, "rank %d: LOAD MODE with a bank open", r);
			if (R.stage != 3) fail(n, "rank %d: LOAD MODE before PRECHARGE ALL and two refreshes", r);
			if ((a & 0x1FFF) != 0x223) fail(n, "rank %d: mode %03X, expected 223 (burst 8, sequential, CAS 2, single writes)", r, a & 0x1FFF);
			R.stage = 4; R.t_mode = n; R.ready_at = n;
			break;
		}
		default: break;
		}
		// refresh debt, once the rank is set up
		for (int k = 0; k < 2; k++) {
			if (rk[k].ready_at < 0) continue;
			long owed = (long)((n - rk[k].ready_at) * tck / T_REFI) - rk[k].refreshes + 2;
			if (owed > max_owed) max_owed = (int)owed;
			if (owed > 8) { fail(n, "rank %d owes %ld refreshes", k, owed); rk[k].ready_at = n; rk[k].refreshes = 0; }
		}
		// the bus for the next half clock
		drive = false;
		dq = 0xDEAD;
		while (!beats.empty() && beats.front().cyc < n) beats.erase(beats.begin());
		if (!beats.empty() && beats.front().cyc == n) {
			if (dqm_hist[2] != 0) fail(n, "a read beat masked by DQM");
			drive = true;
			dq = mem[beats.front().index];
		}
	}
};

} // namespace

int main(int argc, char** argv) {
	long count = 20000;
	long pa = 15385, pb = 10000;                 // 65 MHz CPU, 100 MHz memory (ps)
	uint32_t upload = 64 * 1024;
	unsigned seed = 1;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> const char* { if (i + 1 >= argc) std::exit(2); return argv[++i]; };
		if (a == "--count") count = std::atol(next());
		else if (a == "--pa") pa = std::atol(next());
		else if (a == "--pb") pb = std::atol(next());
		else if (a == "--upload") upload = (uint32_t)std::strtoul(next(), nullptr, 0);
		else if (a == "--seed") seed = (unsigned)std::strtoul(next(), nullptr, 0);
		else if (a == "--show") show = std::atoi(next());
		else { std::printf("usage: sdram_tb [--count N] [--pa ps] [--pb ps] [--upload BYTES] [--seed S] [--show N]\n"); return 2; }
	}
	if (pb != 10000) std::printf("note: the controller is built for 100 MHz; its timings scale with CLK_MHZ\n");

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<Vsdram_tb_top>(ctx.get());
	std::mt19937 rng(seed);

	Chip chip(pb / 1000.0);
	std::vector<uint8_t> model(SIZE);
	for (uint32_t i = 0; i < SIZE; i++) model[i] = init_byte(i);
	auto rd32 = [&](uint32_t a) {
		return (uint32_t)model[a] << 24 | (uint32_t)model[a + 1] << 16 | (uint32_t)model[a + 2] << 8 | model[a + 3];
	};
	auto wr32 = [&](uint32_t a, uint32_t v, uint32_t be) {
		if (be & 8) model[a] = v >> 24;
		if (be & 4) model[a + 1] = v >> 16;
		if (be & 2) model[a + 2] = v >> 8;
		if (be & 1) model[a + 3] = v;
	};

	// the upload: a byte per strobe, gaps of 0-3 clocks, holding while busy
	uint32_t up_done = 0;
	int up_gap = 0;
	bool up_pulse = false;
	long up_idle = 0;                             // memory clocks since the last halfword went in
	std::vector<uint8_t> file(upload);
	for (auto& b : file) b = (uint8_t)rng();
	auto upload_written = [&]() { return up_done == upload && up_idle > 64; };

	// the CPU's side: one request at a time, checked when answered (the
	// data of a write's answer is not used by the CPU, and not checked)
	struct { bool req = false, we = false, line = false; uint32_t addr = 0, be = 0, wdata[8] = {0}, expect[8] = {0}; } a;
	long issued = 0, answered = 0, wrong = 0;
	uint32_t hot = (rng() % (SIZE / 65536)) * 65536;
	auto new_request = [&]() {
		a.we   = rng() % 2;
		a.line = rng() % 2;
		uint32_t pick = rng() % 8, addr;
		// (the uploaded file only once it is all written: on the machine the
		// CPU is held in reset during the upload)
		if (pick < 3 || (pick == 3 && !upload_written())) addr = hot + rng() % 65536;   // a hot 64 KB
		else if (pick == 3) addr = UP_BASE + rng() % (upload ? upload : 4);   // the uploaded file
		else if (pick == 4) addr = (64u << 20) - 64 + rng() % 128;   // across the ranks
		else if (pick == 5) addr = ((rng() % 65536) << 11) - 16 + rng() % 32;  // around a row boundary
		else addr = rng() % SIZE;
		addr %= SIZE;
		a.addr = addr & (a.line ? ~31u : ~3u);
		a.be   = a.line ? 0xF : (rng() % 15 + 1);
		for (int k = 0; k < 8; k++) a.wdata[k] = rng();
		if (a.line) {
			for (int k = 0; k < 8; k++) {
				if (a.we) wr32(a.addr + 4 * k, a.wdata[7 - k], 0xF);
				a.expect[7 - k] = rd32(a.addr + 4 * k);
			}
		} else {
			if (a.we) wr32(a.addr, a.wdata[0], a.be);
			a.expect[0] = rd32(a.addr);
		}
		a.req = true;
		issued++;
	};

	auto drive = [&]() {
		dut->a_req = a.req; dut->a_we = a.we; dut->a_line = a.line; dut->a_addr = a.addr >> 2; dut->a_be = a.be;
		for (int k = 0; k < 8; k++) dut->a_wdata[k] = a.wdata[k];
	};

	dut->reset_a = 1; dut->init = 1;
	dut->clk_a = 0; dut->clk_b = 0;
	dut->up_wr = 0;
	drive(); dut->eval();
	for (int i = 0; i < 4; i++) {
		dut->clk_a = 1; dut->clk_b = 1; dut->eval();
		dut->clk_a = 0; dut->clk_b = 0; dut->eval();
	}
	dut->reset_a = 0; dut->init = 0;

	long ta = pa / 2, tb = pb / 2;
	long sd = 0;                                  // SDRAM clocks
	bool chip_drives = false;
	long gap = 0;
	bool started = false;
	while ((answered < count || !upload_written()) && errors < show && gap < 1000000) {
		bool a_edge = ta <= tb;
		if (a_edge) ta += pa / 2; else tb += pb / 2;
		drive();
		if (a_edge) {
			dut->clk_a = !dut->clk_a;
			dut->eval();
			if (dut->clk_a) {
				gap++;
				if (dut->a_ack) {
					gap = 0;
					answered++;
					int words = a.we ? 0 : a.line ? 8 : 1;
					for (int k = 0; k < words; k++) {
						uint32_t got = dut->a_rdata[a.line ? k : 0];
						if (got != a.expect[a.line ? k : 0] && wrong++ < show)
							std::printf("request %ld (%s %s at %08X): word %d want %08X got %08X\n", answered,
								a.we ? "write" : "read", a.line ? "line" : "word", a.addr, a.line ? 7 - k : 0,
								a.expect[a.line ? k : 0], got);
					}
					a.req = false;
				}
				else if (!a.req && started && issued < count && rng() % 4 != 0) new_request();
			}
		} else {
			dut->clk_b = !dut->clk_b;
			if (dut->clk_b) {
				// the controller's rising edge
				dut->eval();
				if (dut->dq_oe && chip_drives) fail(sd, "the controller and the chip both drive the bus");
				up_idle = dut->up_busy ? 0 : up_idle + 1;
				// the upload, in this clock
				if (up_pulse) { dut->up_wr = 0; up_pulse = false; }
				else if (dut->ready && up_done < upload && !dut->up_busy) {
					if (up_gap > 0) up_gap--;
					else {
						dut->up_wr = 1; dut->up_addr = UP_BASE + up_done; dut->up_data = file[up_done];
						model[UP_BASE + up_done] = file[up_done];
						up_done++;
						up_pulse = true;
						up_gap = rng() % 4;
					}
				}
				if (dut->ready) started = true;
			} else {
				// the SDRAM's rising edge (SDRAM_CLK is the controller's clock inverted)
				bool drv; uint16_t dq;
				chip.edge(sd, dut->SDRAM_nCS, dut->SDRAM_nRAS, dut->SDRAM_nCAS, dut->SDRAM_nWE, dut->SDRAM_BA,
				          dut->SDRAM_A, (dut->SDRAM_DQMH << 1) | dut->SDRAM_DQML, dut->dq_oe, dut->dq_out, drv, dq);
				if (!dut->SDRAM_CKE) fail(sd, "CKE low");
				chip_drives = drv;
				dut->dq_in = dq;
				if (dut->dq_oe && chip_drives) fail(sd, "the controller and the chip both drive the bus");
				dut->eval();
				sd++;
			}
		}
	}
	dut->final();

	// the whole memory, by the controller's map
	long bad = 0;
	for (uint32_t i = 0; i < SIZE / 2; i++) {
		uint32_t off = Chip::offset_of(i);
		uint16_t want = (uint16_t)(model[off] << 8 | model[off + 1]);
		if (chip.mem[i] != want && bad++ < show)
			std::printf("MEMORY at %08X: want %04X, the chip holds %04X\n", off, want, chip.mem[i]);
	}
	std::printf("%ld requests answered (%ld wrong), %u bytes uploaded, %ld SDRAM clocks (%.2f ms)\n",
		answered, wrong, up_done, sd, sd * (pb / 1e9));
	std::printf("refreshes: rank 0 %ld, rank 1 %ld; at most %d owed\n", chip.rk[0].refreshes, chip.rk[1].refreshes, chip.max_owed);
	std::printf("protocol errors: %d; memory differences at the end: %ld\n", errors, bad);
	bool ok = answered == count && up_done == upload && wrong == 0 && errors == 0 && bad == 0;
	if (gap >= 1000000) std::printf("no answer for 1000000 cycles\n");
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	return ok ? 0 : 1;
}
