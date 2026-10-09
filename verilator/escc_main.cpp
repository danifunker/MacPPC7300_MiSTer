// The ESCC's bench (MacPPC7300_escc alone): the modem port's bit rates as Open
// Firmware, a MIDI driver and PPP program them, a byte received at MIDI's
// rate, RTS while it waits, CTS and its external/status interrupt.
//
//     escc_tb        (run_escc.py builds and runs it)

#include "Vescc_tb.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <vector>

static const double CLK_HZ = 65e6;
static Vescc_tb* dut;
static uint64_t clocks = 0;
static uint64_t rtxc_acc = 0, us_acc = 0;
static int failures = 0;

static void tick() {
	dut->rtxc_tick = 0;
	dut->trxc_tick = 0;
	rtxc_acc += 3686400;
	if (rtxc_acc >= (uint64_t)CLK_HZ) { rtxc_acc -= (uint64_t)CLK_HZ; dut->rtxc_tick = 1; }
	us_acc += 1000000;
	if (us_acc >= (uint64_t)CLK_HZ) { us_acc -= (uint64_t)CLK_HZ; dut->trxc_tick = 1; }
	dut->clk = 0; dut->eval();
	dut->clk = 1; dut->eval();
	clocks++;
	dut->sel = 0;
}

static void access(int rn, bool we, uint8_t v) {
	dut->sel = 1; dut->we = we; dut->rn = rn; dut->wdata = v;
	tick();
}

// channel A's write register n
static void wr(int n, uint8_t v) {
	access(2, true, n < 8 ? n : 0x08 | (n - 8));
	access(2, true, v);
}

static uint8_t rr(int n) {
	if (n) access(2, true, n < 8 ? n : 0x08 | (n - 8));
	dut->sel = 1; dut->we = 0; dut->rn = 2; dut->eval();
	uint8_t q = dut->rq;
	tick();
	return q;
}

static void check(const char* what, bool ok, const char* got) {
	std::printf("%s %-58s %s\n", ok ? "  ok  " : "  FAIL", what, got);
	if (!ok) failures++;
}

// the async setup: WR4 (clock mode, stop bits), WR11 (clock sources), the time constant
static void setup(uint8_t wr4, uint8_t wr11, uint16_t tc, bool brg) {
	wr(9, 0xC0);                       // hardware reset
	wr(4, wr4);
	wr(11, wr11);
	wr(12, tc & 0xFF);
	wr(13, tc >> 8);
	wr(14, brg ? 0x01 : 0x00);
	wr(3, 0xC1);                       // 8 bits, receiver on
	wr(5, 0x6A);                       // 8 bits, transmitter on, RTS
}

// a byte sent: the bit time from its 0x55 pattern's edges
static void bit_time(const char* what, double want_hz) {
	access(3, true, 0x55);
	std::vector<uint64_t> edges;
	int q = dut->txd_a;
	for (uint64_t i = 0; i < (uint64_t)(CLK_HZ / want_hz * 14) && edges.size() < 9; i++) {
		tick();
		if (dut->txd_a != q) { edges.push_back(clocks); q = dut->txd_a; }
	}
	char got[96];
	if (edges.size() < 9) {
		std::snprintf(got, sizeof got, "%zu edges", edges.size());
		check(what, false, got);
		return;
	}
	double bit = (edges[8] - edges[0]) / 8.0 / CLK_HZ;
	double hz = 1.0 / bit;
	std::snprintf(got, sizeof got, "%.0f bit/s (want %.0f)", hz, want_hz);
	check(what, std::fabs(hz - want_hz) / want_hz < 0.01, got);
	for (int i = 0; i < (int)(CLK_HZ / want_hz * 4); i++) tick();   // the stop bits
}

int main(int argc, char** argv) {
	Verilated::commandArgs(argc, argv);
	dut = new Vescc_tb;
	dut->rxd_a = 1;
	dut->cts_a = 0;
	dut->reset = 1;
	for (int i = 0; i < 8; i++) tick();
	dut->reset = 0;

	setup(0x4C, 0x50, 1, true);
	bit_time("Open Firmware: x16 from the BRG, time constant 1", 38400);
	setup(0x84, 0x28, 0, false);
	bit_time("MIDI: x32 from TRxC (1 MHz)", 31250);
	setup(0x44, 0x50, 0, true);
	bit_time("PPP 57,600: x16 from the BRG, time constant 0", 57600);
	setup(0x84, 0x00, 0, false);
	bit_time("PPP 115,200: x32 from RTxC", 115200);

	// a byte in at MIDI's rate: 0x90 (note on), LSB first, one stop bit
	setup(0x84, 0x28, 0, false);
	const uint64_t bit = (uint64_t)(CLK_HZ / 31250);
	int frame[10] = {0, 0, 0, 0, 0, 1, 0, 0, 1, 1};
	for (int b = 0; b < 10; b++) {
		dut->rxd_a = frame[b];
		for (uint64_t i = 0; i < bit; i++) tick();
	}
	dut->rxd_a = 1;
	for (int i = 0; i < 100; i++) tick();
	uint8_t rr0 = rr(0);
	char got[96];
	std::snprintf(got, sizeof got, "RR0 %02X, RTS %d", rr0, dut->rts_a);
	check("MIDI in: a byte waits, RTS holds the other end", (rr0 & 1) && dut->rts_a, got);
	dut->sel = 1; dut->we = 0; dut->rn = 3; dut->eval();
	uint8_t d = dut->rq;
	tick();
	std::snprintf(got, sizeof got, "%02X, RTS %d", d, dut->rts_a);
	check("MIDI in: the byte is 90, RTS released", d == 0x90 && !dut->rts_a, got);

	// CTS: RR0 bit 5 follows the pin, uninverted; WR15's CTS enable interrupts
	wr(15, 0x20);
	wr(1, 0x01);
	wr(9, 0x08);                       // master interrupt enable
	access(2, true, 0x10);             // reset ext/status interrupts
	dut->cts_a = 1;
	for (int i = 0; i < 10; i++) tick();
	rr0 = rr(0);
	std::snprintf(got, sizeof got, "RR0 %02X, IRQ %d", rr0, dut->irq_a);
	check("CTS high: RR0 bit 5 set, an external/status interrupt", (rr0 & 0x20) && dut->irq_a, got);
	access(2, true, 0x10);
	dut->cts_a = 0;
	for (int i = 0; i < 10; i++) tick();
	rr0 = rr(0);
	std::snprintf(got, sizeof got, "RR0 %02X", rr0);
	check("CTS low: clear to send", !(rr0 & 0x20), got);

	std::printf("RESULT: %s\n", failures ? "FAIL" : "PASS");
	delete dut;
	return failures ? 1 : 0;
}
