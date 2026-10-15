// The Ethernet bridge's bench: MacPPC7300_enet alone, its DDR3 port against a
// model of the window in DDR3 (busy cycles, a read's latency), the Main's side
// as support/mac/mac_eth.cpp's ring_poll does it (polled every 30 us; its
// counters start over when the epoch changes), and MACE's side as
// MacPPC7300_mace keeps it: toggles kept across resets, a frame taken some
// clocks after it is offered, frames sent now and then.
//
//   enet_tb [--seed S] [--restarts N]
//
// 1. Frames both ways: every frame the Main puts in the receive ring reaches
//    MACE in order and intact, every frame MACE sends reaches the Main.
// 2. The machine off with a frame offered (MACE held, as Cuda holds it after a
//    Shut Down), then the power key: the bridge restarts (a new epoch) and
//    MACE runs again. Frames must flow in the new epoch (2026-10-15: the
//    offer forgotten at the restart, the next went unseen and the receive
//    side stopped until the core was loaded again).
// 3. Restarts at random moments, MACE held or not: the frames flow after each.

#include <verilated.h>
#include "Venet_tb.h"
#include "Venet_tb___024root.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <random>
#include <string>
#include <vector>

namespace {

const uint32_t W0 = 0x30400000u >> 3;         // the window, in 64-bit words
const uint32_t WIN = 0x1200;                  // words: the control words, both rings
const uint32_t MAGIC = 0x50504345u;

std::mt19937 rng(1);
int failures = 0;

void check(const char* what, bool ok, const std::string& got) {
	std::printf("%s %-66s %s\n", ok ? "  ok  " : "  FAIL", what, got.c_str());
	if (!ok) failures++;
}

// a frame's bytes from its number: the number in the first four bytes, then a pattern
std::vector<uint8_t> frame_bytes(uint32_t n) {
	uint32_t len = 60 + (n * 37) % 1400;
	std::vector<uint8_t> f(len);
	for (uint32_t i = 0; i < len; i++) f[i] = (uint8_t)(n * 13 + i * 7);
	f[0] = n >> 24; f[1] = n >> 16; f[2] = n >> 8; f[3] = n;
	return f;
}

struct Bench {
	std::unique_ptr<Venet_tb> dut{new Venet_tb};
	std::vector<uint64_t> mem = std::vector<uint64_t>(WIN, 0);
	uint64_t t = 0;                            // ps
	uint64_t th = 0, tc = 0;                   // the next edge of each clock
	const uint64_t PH = 5000, PC = 7143;       // half periods: 100 MHz, 70 MHz

	// the DDR3 port's reads in flight: {address, beats left, clocks to wait}
	struct Rd { uint32_t a; int n; int wait; };
	std::deque<Rd> rds;
	long beats = 0, reads = 0;

	// the Main
	uint32_t m_epoch = 0x100, m_tx_rd = 0, m_rx_wr = 0;
	uint32_t m_next = 0;                       // the next frame's number (frames are numbered globally)
	uint64_t m_poll_at = 0;
	long m_sent_seen = 0;                      // MACE's frames the Main got
	uint32_t m_tx_expect = 0;

	// MACE
	bool held = false;
	bool rx_seen = false, rx_done = false, tx_go = false, tx_seen = false;
	enum { R_IDLE, R_WAIT, R_READ } rs = R_IDLE;
	int take_in = 0;                           // clocks until MACE takes the frame offered
	uint32_t r_len = 0, r_w = 0;
	std::vector<uint8_t> r_f;
	long got = 0;                              // frames MACE took
	long stale = 0;                            // ... repeated (from before a restart)
	long bad = 0;
	uint32_t last_n = 0;
	bool have_last = false;
	enum { T_IDLE, T_WRITE, T_WAIT } ts = T_IDLE;
	std::vector<uint8_t> t_f;
	uint32_t t_w = 0;
	uint32_t tx_n = 0x80000000u;               // MACE's frames are numbered from here
	uint64_t tx_next_at = 0;

	// held (Cuda holds the machine in reset): a frame in hand is given back, as
	// MacPPC7300_mace does; a transmission under way is forgotten (its reset)
	void hold(bool h) {
		if (h && !held) {
			if (rs != R_IDLE) {
				rs = R_IDLE;
				rx_seen = dut->rx_avail;
				rx_done = !rx_done;
				dut->rx_done = rx_done;
			}
			ts = T_IDLE;
			dut->tx_we = 0;
			tx_seen = dut->tx_done;
		}
		held = h;
	}

	explicit Bench() {
		dut->reset_h = 1; dut->on = 1;
		dut->ddr_busy = 0; dut->ddr_dout_ready = 0;
		dut->tx_we = 0; dut->tx_go = 0; dut->rx_done = 0; dut->rx_ra = 0;
		dut->clk_h = 0; dut->clk = 0;
		dut->eval();
		for (int i = 0; i < 20; i++) step();
		dut->reset_h = 0;
	}

	// the Main's ring_poll, as mac_eth.cpp
	void main_poll() {
		uint64_t magic = mem[0];
		if ((uint32_t)(magic >> 32) != MAGIC) return;
		if ((magic & 0xFF) != m_epoch) { m_epoch = magic & 0xFF; m_tx_rd = m_rx_wr = 0; }
		for (uint32_t tx_wr = (uint32_t)mem[1]; m_tx_rd != tx_wr; m_tx_rd++) {
			uint64_t* s = &mem[0x200 + (m_tx_rd & 7) * 0x100];
			uint32_t len = (uint32_t)s[0];
			if (len && len <= 1536) {
				const uint8_t* b = reinterpret_cast<const uint8_t*>(s + 1);
				uint32_t n = (uint32_t)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
				std::vector<uint8_t> want = frame_bytes(n);
				if (len != want.size() || std::memcmp(b, want.data(), len) != 0) bad++;
				m_sent_seen++;
			}
		}
		mem[2] = m_tx_rd;
		uint32_t rx_rd = (uint32_t)mem[4];
		while (m_rx_wr - rx_rd < 8) {
			std::vector<uint8_t> f = frame_bytes(m_next++);
			uint64_t* s = &mem[0xA00 + (m_rx_wr & 7) * 0x100];
			std::memcpy(s + 1, f.data(), f.size());
			s[0] = f.size();
			mem[3] = ++m_rx_wr;
		}
	}

	// the port's lines as the bridge presented them in the cycle before the edge
	struct Req { bool we, rd, busy; uint32_t addr; uint64_t din; int n; };
	Req pre() const { return {(bool)dut->ddr_we, (bool)dut->ddr_rd, (bool)dut->ddr_busy, (uint32_t)dut->ddr_addr, dut->ddr_din, dut->ddr_burstcnt}; }

	// the memory clock's rising edge: the DDR3 port and the Main
	void edge_h(const Req& q) {
		dut->ddr_dout_ready = 0;
		// a read's beats, one a clock once its latency has passed
		if (!rds.empty()) {
			Rd& r = rds.front();
			if (r.wait > 0) r.wait--;
			else {
				uint32_t i = r.a - W0;
				dut->ddr_dout = i < WIN ? mem[i] : 0;
				dut->ddr_dout_ready = 1;
				beats++;
				r.a++;
				if (--r.n == 0) rds.pop_front();
			}
		}
		if (!q.busy && q.we) {
			uint32_t i = q.addr - W0;
			if (i < WIN) mem[i] = q.din;
		}
		if (!q.busy && q.rd) { rds.push_back({q.addr, q.n, 4 + (int)(rng() % 12)}); reads++; }
		dut->ddr_busy = (rng() % 5) == 0;
		if (t >= m_poll_at) { main_poll(); m_poll_at = t + 30'000'000ull; }
	}

	// the CPU's clock's rising edge: MACE (the inputs set here are sampled at the next edge)
	void edge_c() {
		if (held) return;
		// a frame offered: taken a few clocks later, read a word a clock (rx_q is
		// the word rx_ra named at this edge), answered
		switch (rs) {
		case R_IDLE:
			if (dut->rx_avail != rx_seen) { take_in = 20 + rng() % 200; rs = R_WAIT; }
			break;
		case R_WAIT:
			if (--take_in == 0) {
				r_len = dut->rx_len;
				r_w = 0;
				r_f.clear();
				dut->rx_ra = 0;
				rs = R_READ;
			}
			break;
		case R_READ:
			// rx_q is word r_w (rx_ra named it at this edge)
			if (r_w < (r_len + 7) / 8) {
				uint64_t q = dut->rx_q;
				for (int b = 0; b < 8; b++) r_f.push_back((uint8_t)(q >> (8 * b)));
				r_w++;
			}
			if (r_w == (r_len + 7) / 8) {
				r_f.resize(r_len);
				uint32_t n = r_len >= 4 ? (uint32_t)r_f[0] << 24 | r_f[1] << 16 | r_f[2] << 8 | r_f[3] : 0;
				if (r_f != frame_bytes(n)) bad++;
				else if (have_last && n <= last_n) stale++;       // a frame given again
				else { got++; last_n = n; have_last = true; }
				rx_seen = dut->rx_avail;
				rx_done = !rx_done;
				dut->rx_done = rx_done;
				rs = R_IDLE;
			}
			else dut->rx_ra = r_w;
			break;
		}
		// a frame sent every 300 us or so, a word a clock into the buffer
		switch (ts) {
		case T_IDLE:
			if (t >= tx_next_at) { t_f = frame_bytes(tx_n++); t_w = 0; ts = T_WRITE; }
			break;
		case T_WRITE:
			if (t_w < (t_f.size() + 7) / 8) {
				uint64_t q = 0;
				for (int b = 0; b < 8; b++) if (t_w * 8 + b < t_f.size()) q |= (uint64_t)t_f[t_w * 8 + b] << (8 * b);
				dut->tx_we = 1; dut->tx_wa = t_w; dut->tx_wd = q;
				t_w++;
			} else {
				dut->tx_we = 0;
				dut->tx_len = t_f.size();
				tx_go = !tx_go;
				dut->tx_go = tx_go;
				ts = T_WAIT;
			}
			break;
		case T_WAIT:
			if (dut->tx_done != tx_seen) { tx_seen = dut->tx_done; ts = T_IDLE; tx_next_at = t + 300'000'000ull; }
			break;
		}
	}

	void step() {
		if (th <= tc) {
			t = th; th += PH;
			Req q = pre();
			dut->clk_h = !dut->clk_h;
			dut->eval();
			if (dut->clk_h) edge_h(q);
			dut->eval();
		} else {
			t = tc; tc += PC;
			dut->clk = !dut->clk;
			dut->eval();
			if (dut->clk) edge_c();
			dut->eval();
		}
	}
	bool verbose = false;
	void run_us(uint64_t us) {
		uint64_t end = t + us * 1'000'000ull, next = t;
		while (t < end) {
			step();
			if (verbose && t >= next) {
				std::fprintf(stderr, "t %.3f ms: got %ld stale %ld bad %ld sent %ld; rx_wr %u rx_rd %llu tx_wr %llu tx_rd %u epoch %02llx; es %d rx_pend %d poll %d rds %zu\n",
				             t / 1e9, got, stale, bad, m_sent_seen, m_rx_wr, (unsigned long long)mem[4],
				             (unsigned long long)mem[1], m_tx_rd, (unsigned long long)(mem[0] & 0xFF),
				             dut->rootp->MacPPC7300_enet__DOT__es, dut->rootp->MacPPC7300_enet__DOT__rx_pend,
				             dut->rootp->MacPPC7300_enet__DOT__poll, rds.size());
				std::fprintf(stderr, "    kb %d len %d nb %d beats served %ld reads %ld\n", dut->rootp->MacPPC7300_enet__DOT__kb,
				             dut->rootp->MacPPC7300_enet__DOT__len, dut->rootp->MacPPC7300_enet__DOT__nb, beats, reads);
				next = t + 100'000'000ull;
			}
		}
	}
	// the top's reset (the power key, the OSD's): the bridge and the machine (MACE) together
	void restart(int clocks, bool stay_held) {
		bool was = held;
		hold(true);
		dut->reset_h = 1;
		for (int i = 0; i < 2 * clocks; i++) step();
		dut->reset_h = 0;
		if (!stay_held && !was) hold(false);
	}
};

std::string fmt(const char* f, long a, long b = 0, long c = 0) {
	char s[160];
	std::snprintf(s, sizeof s, f, a, b, c);
	return s;
}

} // namespace

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	unsigned seed = 1;
	int restarts = 24;
	bool verbose = false;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--seed" && i + 1 < argc) seed = (unsigned)std::strtoul(argv[++i], nullptr, 0);
		else if (a == "--restarts" && i + 1 < argc) restarts = std::atoi(argv[++i]);
		else if (a == "--verbose") verbose = true;
	}
	rng.seed(seed);
	Bench b;
	b.verbose = verbose;

	// 1. frames both ways
	b.run_us(3000);
	check("frames to MACE in order, intact", b.got > 50 && b.bad == 0 && b.stale == 0,
	      fmt("%ld taken, %ld bad, %ld repeated", b.got, b.bad, b.stale));
	check("MACE's frames to the Main", b.m_sent_seen >= 5 && b.bad == 0, fmt("%ld sent", b.m_sent_seen));

	// 2. Shut Down with a frame offered, then the power key
	b.hold(true);
	b.run_us(500);                             // the bridge offers one and waits; the ring fills
	bool offered = b.dut->rx_avail != b.rx_seen;
	b.restart(50, true);                       // the power key: the bridge restarts
	b.run_us(200);
	b.hold(false);                             // ... and the machine runs again
	long before = b.got;
	b.run_us(3000);
	check("the machine off with a frame offered: an offer was out", offered, offered ? "yes" : "no");
	check("after the power key, frames flow in the new epoch", b.got - before > 50 && b.bad == 0,
	      fmt("%ld taken after, %ld bad, %ld repeated", b.got - before, b.bad, b.stale));

	// 3. restarts at random moments, MACE held through some
	int stuck = 0;
	for (int k = 0; k < restarts; k++) {
		b.run_us(100 + rng() % 400);
		bool hold = rng() % 2;
		if (hold) { b.hold(true); b.run_us(50 + rng() % 300); }
		b.restart(1 + rng() % 100, hold);
		if (hold) { b.run_us(rng() % 200); b.hold(false); }
		long g = b.got;
		b.run_us(1000);
		if (b.got - g < 10) stuck++;
	}
	check("restarts at random moments: the frames flow after each", stuck == 0 && b.bad == 0,
	      fmt("%ld of %ld restarts stuck, %ld bad", stuck, restarts, b.bad));
	check("MACE's frames still reach the Main", b.m_sent_seen > 20, fmt("%ld sent in all", b.m_sent_seen));

	b.dut->final();
	std::printf("%ld frames taken by MACE, %ld repeated after a restart\n", b.got, b.stale);
	std::printf("RESULT: %s\n", failures ? "FAIL" : "PASS");
	return failures ? 1 : 0;
}
