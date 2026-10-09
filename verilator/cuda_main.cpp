// Test bench for MacPPC7300_cuda: Cuda (the 68HC05 and its firmware) with the
// ADB devices (MacPPC7300_adb) on its ADB line (cuda_tb_top.sv).
//
//   cuda_tb [--lockstep --rom 341s0060.bin] [--seconds S] [--trace-from N --trace-count M] [--show N]
//
// The bench is the 7600 around Cuda: a model of the VIA's port B and shift
// register (MAME's 6522 in its external-clock modes: shift out on CB1's
// falling edges, shift in on its rising ones, the flag at the eighth) and a
// host that talks to Cuda through it the way Linux's via-cuda.c does (sync,
// then packets out and replies in). The host makes one VIA access per cycle
// of the VIA's 783,360 Hz clock, as Grand Central paces them, and after a
// flag waits ten accesses before acting, as the 7600's ROM does: Cuda reads
// the last bit of a byte 3.8 us after the VIA sets the flag. The ADB devices
// take the bench's PS/2 events; nothing is on the I2C lines.
//
// It checks:
//   - the cold start: how long until Cuda releases the CPU's reset;
//   - a script of packets and their replies: READ_MCU_MEM of the ROM's
//     first bytes (its copyright), GET_REAL_TIME (the firmware's default
//     clock plus the seconds run), WRITE_PRAM and READ_PRAM back, the ROM's
//     first packet (I2C to address 88, nothing there); the ADB devices:
//     register 3 of the keyboard and the mouse, an empty address, a key
//     pressed and a mouse move reported, a device moved to another address
//     and its handler changed, the keyboard's register 2, SendReset;
//     the game controllers; POWER_DOWN last: the power goes off (PA0
//     driven low), the CPU stays in reset, the Menu key is the power key;
//   - with --lockstep, every instruction against MAME's 6805 core
//     (verilator/hc05ref): registers, the writes it made, and its length in
//     bus cycles. Reads of the registers (0000-001F) are handed to the
//     reference as the RTL read them; interrupts are taken in the reference
//     where the RTL took them.

#include "Vcuda_tb_top.h"
#include "verilated.h"

#ifdef WITH_HC05REF
#include "hc05_ref.h"
#endif

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace {

const double CLK_HZ = 8388608.0;          // -GCLK_HZ in the Makefile

struct Options {
	std::string rom;              // the firmware, for the reference (the RTL has it built in)
	bool lockstep = false;
	bool log_via = false;         // print every VIA access the host makes
	bool log_adb = false;         // print the ADB line's edges, who drives it, in us
	double seconds = 4.0;
	uint64_t trace_from = 0, trace_count = 0;
	long show = 10;
};

// ---- the VIA: port B and the shift register, as Cuda sees them -------------------------
struct Via {
	uint8_t orb = 0, ddrb = 0, acr = 0, sr = 0, ifr = 0;
	int count = 0x0F;           // MAME's shift counter: every CB1 edge
	bool cb1 = true;            // the line as last seen
	bool cb2_out = true;        // what the VIA drives on CB2 when shifting out

	bool shift_out() const { return (acr & 0x10) != 0; }
	bool tip() const { return (ddrb & 0x20) ? (orb & 0x20) != 0 : true; }
	bool byteack() const { return (ddrb & 0x10) ? (orb & 0x10) != 0 : true; }

	// a change of CB1 (6522via.cpp write_cb1, shift_out, shift_in)
	void cb1_edge(bool level, bool cb2) {
		if (level == cb1) return;
		cb1 = level;
		uint32_t mode = acr & 0x1C;
		if (mode == 0x1C) {
			if (count & 1) {
				cb2_out = (sr >> 7) & 1;
				sr = (uint8_t)((sr << 1) | (cb2_out ? 1 : 0));
				if (count == 1) ifr |= 0x04;
			}
		}
		else if (mode == 0x0C || mode == 0x00) {
			if (!(count & 1)) {
				sr = (uint8_t)((sr << 1) | (cb2 ? 1 : 0));
				if (count == 0 && mode != 0x00) ifr |= 0x04;
			}
		}
		count = (count - 1) & 0x0F;
	}

	uint8_t read_sr() { ifr &= ~0x04; count = cb1 ? 0x0F : 0x10; return sr; }
	void write_sr(uint8_t v) { sr = v; ifr &= ~0x04; count = cb1 ? 0x0F : 0x10; }
};

// ---- the host: Linux's via-cuda.c state machine, one VIA access a step -------------------
struct Host {
	enum St {
		INIT, INIT_WAIT, SYNC1, SYNC2, SYNC3, SYNC4, IDLE,
		SENT_FIRST, SENDING, AWAIT_REPLY, READING, READ_DONE
	} st = INIT;
	uint64_t wait_until = 0;
	std::vector<uint8_t> out;     // the packet being sent
	size_t out_i = 0;
	std::vector<uint8_t> reply;
	size_t max_reply = 32;
	bool busy = false;            // a packet is in flight (sent or being answered)
	bool have_reply = false;
	std::string error;
	uint64_t sync_done_at = 0;
	std::vector<std::vector<uint8_t>> unsolicited;
	bool reading_reply = false;
	bool log = false;             // --log-via: every access the host makes

	static const uint8_t TREQ = 0x08, TACK = 0x10, TIP = 0x20;

	void send(const std::vector<uint8_t>& p) { out = p; out_i = 0; busy = true; have_reply = false; reply.clear(); }

	// one step: at most one access to the VIA. treq_low: the VIA's PB3 pin.
	void step(Via& v, bool treq_low, uint64_t now) {
		static const char* names[] = {"init", "init-wait", "sync1", "sync2", "sync3", "sync4", "idle",
		                              "sent-first", "sending", "await-reply", "reading", "read-done"};
		St st0 = st;
		uint8_t orb0 = v.orb, acr0 = v.acr, sr0 = v.sr;
		bool flag0 = (v.ifr & 0x04) != 0;
		step_(v, treq_low, now);
		if (log && (st != st0 || v.orb != orb0 || v.acr != acr0))
			std::printf("  %10.6f host %-11s -> %-11s TREQ %d flag %d SR %02X  TIP %d TACK %d  SR %s\n", now / CLK_HZ,
				names[st0], names[st], treq_low ? 0 : 1, flag0, sr0, (v.orb & TIP) ? 1 : 0, (v.orb & TACK) ? 1 : 0,
				(v.acr & 0x10) ? "out" : "in");
	}

	int settle = 0;               // accesses since the flag was first seen

	void step_(Via& v, bool treq_low, uint64_t now) {
		bool flag = (v.ifr & 0x04) != 0;
		// as the 7600's ROM does (FFF04BC4): ten more VIA accesses after the
		// flag before anything else, so that Cuda has read the last bit
		if (!flag) settle = 0;
		else if (settle < 10) { settle++; return; }
		switch (st) {
		case INIT:
			v.ddrb = (uint8_t)((v.ddrb | TACK | TIP) & ~TREQ);
			v.orb |= TACK | TIP;
			v.acr = (uint8_t)((v.acr & ~0x1C) | 0x0C);
			v.read_sr();
			wait_until = now + (uint64_t)(0.004 * CLK_HZ);
			st = INIT_WAIT;
			break;
		case INIT_WAIT:
			if (now < wait_until) break;
			v.read_sr();
			v.ifr &= ~0x04;
			v.orb &= ~TACK;                    // sync: TACK without TIP
			st = SYNC1;
			break;
		case SYNC1:                                // Cuda asserts TREQ, then the flag
			if (treq_low && flag) { v.read_sr(); v.orb |= TACK; st = SYNC2; }
			break;
		case SYNC2:                                // TREQ negated, the flag again
			if (!treq_low && flag) { v.read_sr(); v.orb |= TIP; st = IDLE; sync_done_at = now; }
			break;
		case IDLE:
			if (treq_low && flag) {
				// Cuda has something for us (an attention byte with TREQ)
				v.read_sr();
				v.orb &= ~TIP;
				reply.clear();
				reading_reply = false;
				st = READING;
			}
			else if (busy && out_i == 0 && !treq_low) {
				v.acr |= 0x10;
				v.write_sr(out[0]);
				out_i = 1;
				v.orb &= ~TIP;
				st = SENT_FIRST;
			}
			break;
		case SENT_FIRST:
			if (!flag) break;
			if (treq_low) {
				// a collision: Cuda wants to send first; try again later
				v.acr &= ~0x10;
				v.read_sr();
				v.orb |= TIP | TACK;
				out_i = 0;
				st = IDLE;
				break;
			}
			if (out_i >= out.size()) goto all_sent;
			v.write_sr(out[out_i++]);
			v.orb ^= TACK;
			st = SENDING;
			break;
		case SENDING:
			if (!flag) break;
			if (out_i < out.size()) { v.write_sr(out[out_i++]); v.orb ^= TACK; break; }
		all_sent:
			v.acr &= ~0x10;
			v.read_sr();
			v.orb |= TACK | TIP;
			st = AWAIT_REPLY;
			break;
		case AWAIT_REPLY:
			if (!flag) break;
			v.read_sr();
			if (treq_low) {
				// the attention byte: the reply follows
				v.orb &= ~TIP;
				reply.clear();
				reading_reply = true;
				st = READING;
			}
			// else the idle acknowledge of the packet just sent
			break;
		case READING:
			if (!flag) break;
			reply.push_back(v.read_sr());
			if (treq_low && reply.size() < max_reply) v.orb ^= TACK;
			else {
				// the end, or enough of an open-ended reply: Cuda answers TIP's
				// negation with an idle acknowledge (via-cuda.c read_done)
				v.orb |= TACK | TIP;
				st = READ_DONE;
			}
			break;
		case READ_DONE:
			if (!flag) break;
			v.read_sr();
			if (reading_reply) { have_reply = true; busy = false; }
			else unsolicited.push_back(reply);
			st = IDLE;
			break;
		case SYNC3:
		case SYNC4:
			break;
		}
	}
};

std::string hex(const std::vector<uint8_t>& v) {
	std::string s;
	char b[4];
	for (uint8_t c : v) { std::snprintf(b, sizeof b, "%02X ", c); s += b; }
	if (!s.empty()) s.pop_back();
	return s;
}

#ifdef WITH_HC05REF
std::deque<std::pair<uint16_t, uint8_t>> io_reads;    // the RTL's register reads, not yet consumed
std::string io_error;

uint8_t io_read(void*, uint16_t addr) {
	if (io_reads.empty() || io_reads.front().first != addr) {
		if (io_error.empty()) {
			char b[160];
			std::snprintf(b, sizeof b, "the reference read register %02X; the RTL %s", addr,
				io_reads.empty() ? "read no register" : ("read " + std::to_string(io_reads.front().first)).c_str());
			io_error = b;
		}
		return 0;
	}
	uint8_t v = io_reads.front().second;
	io_reads.pop_front();
	return v;
}
#endif

} // namespace

int main(int argc, char** argv) {
	Options opt;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
		if (a == "--lockstep") opt.lockstep = true;
		else if (a == "--rom") opt.rom = next();
		else if (a == "--seconds") opt.seconds = std::atof(next().c_str());
		else if (a == "--trace-from") opt.trace_from = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--trace-count") opt.trace_count = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--show") opt.show = std::atol(next().c_str());
		else if (a == "--log-via") opt.log_via = true;
		else if (a == "--log-adb") opt.log_adb = true;
		else {
			std::fprintf(stderr, "usage: cuda_tb [--lockstep --rom 341s0060.bin] [--seconds S] [--trace-from N --trace-count M] [--show N]\n");
			return 2;
		}
	}
#ifndef WITH_HC05REF
	if (opt.lockstep) { std::fprintf(stderr, "built without the reference (hc05ref)\n"); return 2; }
#endif

	Verilated::commandArgs(argc, argv);
	Vcuda_tb_top* dut = new Vcuda_tb_top;

#ifdef WITH_HC05REF
	if (opt.lockstep) {
		std::vector<uint8_t> rom(0x1100);
		FILE* f = std::fopen(opt.rom.c_str(), "rb");
		if (!f || std::fread(rom.data(), 1, rom.size(), f) != rom.size()) {
			std::fprintf(stderr, "cannot read the firmware for the reference: --rom %s\n", opt.rom.c_str());
			return 2;
		}
		std::fclose(f);
		hc05_ref_init(rom.data(), 0x0F00, 0x1100);
		hc05_ref_set_io(io_read, nullptr);
	}
#endif

	Via via;
	Host host;
	host.log = opt.log_via;
	// the reset's two bus cycles (the vector) belong to no instruction
	uint64_t clocks = 0, retired = 0, ints = 0, bus_cycles = 0, insn_start_cycle = 2;
	uint64_t released_at = 0;
	bool released = false, failed = false;
	long shown = 0;
	std::vector<std::pair<uint16_t, uint8_t>> rtl_writes;
	// the PS/2 keyboard and mouse as hps_io gives them (a toggle an event)
	uint32_t ps2_key = 0, ps2_mouse = 0;
	// the game controller (MacPPC7300_adb's joy): {pointer, mode, right stick, left stick, joystick_0}
	uint64_t joy = 0;
	auto J = [](int ptr, int mode, int ly, int lx, int js) -> int64_t {
		return (int64_t)ptr << 51 | (int64_t)mode << 48 | (int64_t)(ly & 0xFF) << 24 | (int64_t)(lx & 0xFF) << 16 | js;
	};

	auto drive = [&]() {
		dut->via_tip = via.tip();
		dut->via_byteack = via.byteack();
		bool cuda_drives = dut->cb2_oe;
		bool line = (cuda_drives ? (bool)dut->cb2_out : true) && (via.shift_out() ? via.cb2_out : true);
		dut->cb2 = line;
		dut->ps2_key = ps2_key;
		dut->ps2_mouse = ps2_mouse;
		dut->joy = joy;
		dut->iic_scl = !dut->iic_scl_low;
		dut->iic_sda = !dut->iic_sda_low;
	};

	dut->clk = 0;
	dut->reset = 1;
	drive();
	for (int i = 0; i < 8; i++) { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
	dut->reset = 0;

	// the script: packet, what the reply must start with (empty: just print it),
	// and a PS/2 event made just before the packet goes (1: A pressed;
	// 2: the mouse moved right 5 and up 3), and the controller from then on
	struct Step { const char* what; std::vector<uint8_t> pkt; std::vector<uint8_t> want; size_t max; int inject = 0; int64_t joy = -1; };
	std::vector<Step> script = {
		{"READ_MCU_MEM 0F00 (the ROM's copyright)", {0x01, 0x02, 0x0F, 0x00}, {0x01, 0x00, 0x02, 0x28, 0x63, 0x29, 0x20, 0x31, 0x39, 0x38, 0x39}, 12},
		{"GET_REAL_TIME", {0x01, 0x03}, {0x01, 0x00, 0x03}, 7},
		{"WRITE_PRAM 0010 = AA 55", {0x01, 0x0C, 0x00, 0x10, 0xAA, 0x55}, {0x01, 0x00, 0x0C}, 8},
		{"READ_PRAM 0010", {0x01, 0x07, 0x00, 0x10}, {0x01, 0x00, 0x07, 0xAA, 0x55}, 5},
		{"the ROM's first packet: I2C write to 88, 61 55", {0x01, 0x22, 0x88, 0x61, 0x55}, {}, 8},
		// the ADB devices (MacPPC7300_adb) answering Cuda's firmware: flags 00 an
		// answer, 02 none (a timeout)
		{"ADB talk 3 of address 2: the keyboard", {0x00, 0x2F}, {0x00, 0x00, 0x2F, 0x62, 0x02}, 8},
		{"ADB talk 3 of address 3: the mouse", {0x00, 0x3F}, {0x00, 0x00, 0x3F, 0x63, 0x01}, 8},
		{"ADB talk 3 of address 4: nothing there", {0x00, 0x4F}, {0x00, 0x02, 0x4F}, 8},
		{"ADB talk 0 of address 2: no key yet", {0x00, 0x2C}, {0x00, 0x02, 0x2C}, 8},
		{"ADB talk 0 of address 2 after A is pressed", {0x00, 0x2C}, {0x00, 0x00, 0x2C, 0x00, 0xFF}, 8, 1},
		{"ADB talk 0 of address 3 after a move right 5, up 3", {0x00, 0x3C}, {0x00, 0x00, 0x3C, 0xFD, 0x85}, 8, 2},
		{"ADB talk 0 of address 3: nothing new", {0x00, 0x3C}, {0x00, 0x02, 0x3C}, 8},
		{"ADB listen 3 of address 3: move to address 9 (FE)", {0x00, 0x3B, 0x09, 0xFE}, {0x00, 0x00, 0x3B}, 8},
		{"ADB talk 3 of address 9: the mouse, moved", {0x00, 0x9F}, {0x00, 0x00, 0x9F, 0x69, 0x01}, 8},
		{"ADB talk 3 of address 3: nothing there now", {0x00, 0x3F}, {0x00, 0x02, 0x3F}, 8},
		{"ADB listen 3 of address 9: handler 2", {0x00, 0x9B, 0x09, 0x02}, {0x00, 0x00, 0x9B}, 8},
		{"ADB talk 3 of address 9: handler 2", {0x00, 0x9F}, {0x00, 0x00, 0x9F, 0x69, 0x02}, 8},
		{"ADB talk 2 of address 2: modifiers and LEDs", {0x00, 0x2E}, {0x00, 0x00, 0x2E, 0xFF, 0xFF}, 8},
		{"ADB reset (SendReset)", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8},
		{"ADB talk 3 of address 3: the mouse, back home", {0x00, 0x3F}, {0x00, 0x00, 0x3F, 0x63, 0x01}, 8},
		// a MouseStick II on the mouse's address: ADBReInit's collisions, its handlers
		{"ADB with a MouseStick II: SendReset", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(0, 1, 0, 0, 0)},
		{"ADB talk 3 of address 3: the mouse wins", {0x00, 0x3F}, {0x00, 0x00, 0x3F, 0x63, 0x01}, 8},
		{"ADB listen 3 of address 3: to 9 (FE), the mouse", {0x00, 0x3B, 0x09, 0xFE}, {0x00, 0x00, 0x3B}, 8},
		{"ADB talk 3 of address 3: the MouseStick", {0x00, 0x3F}, {0x00, 0x00, 0x3F, 0x63, 0x01}, 8},
		{"ADB listen 3 of address 3: to 10 (FE), the MouseStick", {0x00, 0x3B, 0x0A, 0xFE}, {0x00, 0x00, 0x3B}, 8},
		{"ADB talk 3 of address 3: nothing there now", {0x00, 0x3F}, {0x00, 0x02, 0x3F}, 8},
		{"ADB talk 3 of address 9: the mouse", {0x00, 0x9F}, {0x00, 0x00, 0x9F, 0x69, 0x01}, 8},
		{"ADB talk 0 of address 10: stick right, pointer off", {0x00, 0xAC}, {0x00, 0x02, 0xAC}, 8, 0, J(0, 1, 0, 0x7F, 0)},
		{"ADB talk 0 of address 10: stick right, pointer on", {0x00, 0xAC}, {0x00, 0x00, 0xAC, 0x80, 0x8C}, 8, 0, J(1, 1, 0, 0x7F, 0)},
		{"ADB listen 3 of address 10: handler 23", {0x00, 0xAB, 0x0A, 0x23}, {0x00, 0x00, 0xAB}, 8, 0, J(0, 1, 0, 0, 0)},
		{"ADB talk 3 of address 10: handler 23", {0x00, 0xAF}, {0x00, 0x00, 0xAF, 0x6A, 0x23}, 8},
		{"ADB talk 1 of address 10: the 7-byte protocol", {0x00, 0xAD}, {0x00, 0x00, 0xAD, 0x03, 0x00}, 8},
		{"ADB talk 0 of address 10: right, up, the trigger", {0x00, 0xAC},
			{0x00, 0x00, 0xAC, 0x80, 0x80, 0x02, 0x53, 0xFD, 0xAC, 0xFB}, 12, 0, J(0, 1, 0x81, 0x7F, 0x10)},
		{"ADB talk 0 of address 10: nothing new", {0x00, 0xAC}, {0x00, 0x02, 0xAC}, 8},
		// a GamePad on the keyboard's address: arrow keys, then its driver's handler
		{"ADB with a GamePad: SendReset", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(0, 3, 0, 0, 0)},
		{"ADB talk 3 of address 2: the keyboard wins", {0x00, 0x2F}, {0x00, 0x00, 0x2F, 0x62, 0x02}, 8},
		{"ADB listen 3 of address 2: to 11 (FE), the keyboard", {0x00, 0x2B, 0x0B, 0xFE}, {0x00, 0x00, 0x2B}, 8},
		{"ADB talk 3 of address 2: the GamePad", {0x00, 0x2F}, {0x00, 0x00, 0x2F, 0x62, 0x02}, 8},
		{"ADB talk 0 of address 2: D-pad left, an arrow down", {0x00, 0x2C}, {0x00, 0x00, 0x2C, 0x3B, 0xFF}, 8, 0, J(0, 3, 0, 0, 0x02)},
		{"ADB talk 0 of address 2: D-pad released", {0x00, 0x2C}, {0x00, 0x00, 0x2C, 0xBB, 0xFF}, 8, 0, J(0, 3, 0, 0, 0)},
		{"ADB listen 3 of address 2: handler 34", {0x00, 0x2B, 0x02, 0x34}, {0x00, 0x00, 0x2B}, 8},
		{"ADB talk 1 of address 2: 03 00", {0x00, 0x2D}, {0x00, 0x00, 0x2D, 0x03, 0x00}, 8},
		{"ADB talk 0 of address 2: handler 34, up, button 1", {0x00, 0x2C}, {0x00, 0x00, 0x2C, 0xB7, 0xFF}, 8, 0, J(0, 3, 0, 0, 0x18)},
		// a Firebird (eight bytes) and a SideWinder 3D Pro (its joystick at 4)
		{"ADB with a Firebird: SendReset", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(0, 2, 0, 0, 0)},
		{"ADB talk 3 of address 3: the mouse wins", {0x00, 0x3F}, {0x00, 0x00, 0x3F, 0x63, 0x01}, 8},
		{"ADB listen 3 of address 3: to 9 (FE), the mouse", {0x00, 0x3B, 0x09, 0xFE}, {0x00, 0x00, 0x3B}, 8},
		{"ADB listen 3 of address 3: handler 4E", {0x00, 0x3B, 0x03, 0x4E}, {0x00, 0x00, 0x3B}, 8},
		{"ADB talk 1 of address 3: 0A 01 30", {0x00, 0x3D}, {0x00, 0x00, 0x3D, 0x0A, 0x01, 0x30}, 8},
		{"ADB talk 0 of address 3: stick left", {0x00, 0x3C},
			{0x00, 0x00, 0x3C, 0xFF, 0xFF, 0xFF, 0x01, 0x80, 0x80, 0x80, 0x80}, 12, 0, J(0, 2, 0, 0x81, 0)},
		{"ADB with a SideWinder: SendReset", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(0, 4, 0, 0, 0)},
		{"ADB talk 3 of address 4: the joystick", {0x00, 0x4F}, {0x00, 0x00, 0x4F, 0x64, 0x5D}, 8},
		{"ADB talk 0 of address 4: centred", {0x00, 0x4C}, {0x00, 0x00, 0x4C, 0xF8, 0x0A, 0x02, 0x01, 0x01, 0xF2, 0x02}, 12},
		// no controller, the stick moving the pointer through the mouse
		{"ADB with the stick as the mouse: SendReset", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(1, 0, 0, 0, 0)},
		{"ADB talk 0 of address 3: D-pad down, button 1", {0x00, 0x3C}, {0x00, 0x00, 0x3C, 0x0C, 0x80}, 8, 0, J(1, 0, 0, 0, 0x14)},
		{"ADB talk 0 of address 3: released", {0x00, 0x3C}, {0x00, 0x00, 0x3C, 0x80, 0x80}, 8, 0, J(1, 0, 0, 0, 0)},
		{"ADB talk 0 of address 3: nothing new", {0x00, 0x3C}, {0x00, 0x02, 0x3C}, 8},
		{"ADB reset (SendReset)", {0x00, 0x00}, {0x00, 0x00, 0x00}, 8, 0, J(0, 0, 0, 0, 0)},
		{"POWER_DOWN (Shut Down's, Linux's power-off)", {0x01, 0x0A}, {}, 8},
	};
	// the power: off only after POWER_DOWN, the CPU held; then the Menu key (the power key)
	bool off_seen = false, off_early = false, off_held = false, wake_seen = false;
	uint64_t off_at = 0;
	size_t script_i = 0;
	bool script_sent = false;
	uint64_t script_started = 0;
	uint32_t time_at_get = 0;
	int failures = 0;

	const uint64_t max_clocks = (uint64_t)(opt.seconds * CLK_HZ);
	// a VIA access every cycle of the VIA's 783,360 Hz clock, as Grand Central
	// paces them (MAME, heathrow.cpp via_sync)
	const uint64_t host_period = (uint64_t)(CLK_HZ / 783360.0 + 0.5);

	while (clocks < max_clocks && !failed) {
		// ---- before the edge: the bus cycle that this edge ends ----
		drive();
		dut->clk = 0;
		dut->eval();
		bool cen = dut->dbg_cen;
		if (cen) {
			bus_cycles++;
#ifdef WITH_HC05REF
			if (opt.lockstep && dut->dbg_rd && dut->dbg_addr < 0x20) io_reads.push_back({(uint16_t)dut->dbg_addr, (uint8_t)dut->dbg_rdata});
#endif
			if (dut->dbg_wr) rtl_writes.push_back({(uint16_t)dut->dbg_addr, (uint8_t)dut->dbg_wdata});
		}
		dut->clk = 1;
		dut->eval();
		clocks++;

		// ---- the ADB line's edges ----
		if (opt.log_adb) {
			static int adb_q = 0;
			static uint64_t adb_t = 0;
			int adb_now = (dut->adb_low ? 1 : 0) | (dut->adb_dev_low ? 2 : 0);
			if (adb_now != adb_q) {
				std::printf("adb %10.1f us  +%7.1f  %-10s  instruction %llu\n", clocks * 1e6 / CLK_HZ, (clocks - adb_t) * 1e6 / CLK_HZ,
					adb_now == 0 ? "released" : adb_now == 1 ? "Cuda low" : adb_now == 2 ? "device low" : "both low",
					(unsigned long long)retired);
				adb_q = adb_now;
				adb_t = clocks;
			}
		}

		// ---- after it: the VIA sees Cuda's lines, the host runs ----
		bool cb2_line = (dut->cb2_oe ? (bool)dut->cb2_out : true) && (via.shift_out() ? via.cb2_out : true);
		via.cb1_edge(dut->cb1, cb2_line);
		if (!released && !dut->cpu_reset) {
			released = true;
			released_at = clocks;
			std::printf("Cuda released the CPU's reset after %.3f s (%llu instructions)\n",
				clocks / CLK_HZ, (unsigned long long)retired);
		}
		if (dut->power_off && !off_seen) {
			off_seen  = true;
			off_at    = clocks;
			off_early = script_i + 1 < script.size();
			std::printf("Cuda switched the power off at %.3f s%s\n", clocks / CLK_HZ, off_early ? ": too early, FAIL" : "");
		}
		if (off_seen && !wake_seen && clocks == off_at + (uint64_t)(0.05 * CLK_HZ)) {
			off_held = dut->cpu_reset;
			std::printf("50 ms later the CPU is %s; the Menu key (the power key) pressed\n", off_held ? "held in reset" : "running, FAIL");
			ps2_key = ((ps2_key ^ 0x400) & 0x400) | 0x200 | 0x12F;
		}
		if (off_seen && !wake_seen && dut->power_key) {
			wake_seen = true;
			std::printf("the power key seen at %.3f s (the machine's reset follows: MacPPC7300_machine power_wake)\n", clocks / CLK_HZ);
		}
		if (released && clocks % host_period == 0) {
			host.step(via, !dut->treq, clocks);
			if (host.st == Host::IDLE && host.sync_done_at == clocks)
				std::printf("host: synchronised with Cuda at %.3f s\n", clocks / CLK_HZ);
			if (host.st == Host::IDLE && !host.busy && host.sync_done_at && script_i < script.size()) {
				if (!script_sent) {
					if (script[script_i].inject == 1)
						ps2_key = ((ps2_key ^ 0x400) & 0x400) | 0x200 | 0x1C;
					else if (script[script_i].inject == 2)
						ps2_mouse = ((ps2_mouse ^ 0x1000000) & 0x1000000) | 3u << 16 | 5u << 8 | 0x08;
					if (script[script_i].joy >= 0)
						joy = (uint64_t)script[script_i].joy;
					host.send(script[script_i].pkt);
					host.max_reply = script[script_i].max;
					script_sent = true;
					script_started = clocks;
				}
			}
			if (script_sent && host.have_reply) {
				const Step& s = script[script_i];
				bool ok = host.reply.size() >= s.want.size() &&
				          std::equal(s.want.begin(), s.want.end(), host.reply.begin());
				std::printf("%s %-52s -> %s  (%.2f ms)\n", ok ? "  ok  " : "  FAIL", s.what, hex(host.reply).c_str(),
					(clocks - script_started) * 1e3 / CLK_HZ);
				if (!ok) { std::printf("        want %s ...\n", hex(s.want).c_str()); failures++; }
				if (script_i == 1 && host.reply.size() >= 7)
					time_at_get = (uint32_t)host.reply[3] << 24 | host.reply[4] << 16 | host.reply[5] << 8 | host.reply[6];
				script_i++;
				script_sent = false;
				host.have_reply = false;
			}
			if (script_sent && clocks - script_started > (uint64_t)(0.5 * CLK_HZ)) {
				if (script_i + 1 == script.size() && off_seen) {
					std::printf("  ok   %-52s -> no reply: the power went off\n", script[script_i].what);
					script_i++;
					script_sent = false;
				}
				else {
					std::printf("  FAIL %-52s -> no reply in 500 ms (host state %d, got %s)\n", script[script_i].what, (int)host.st,
						hex(host.reply).c_str());
					failures++;
					failed = true;
				}
			}
		}

		// ---- an instruction ended ----
		if (dut->tr_valid) {
			uint64_t ncyc = bus_cycles - insn_start_cycle;
			insn_start_cycle = bus_cycles;
			bool is_int = dut->tr_int;
			if (is_int) ints++; else retired++;
			bool show = opt.trace_count && retired > opt.trace_from && retired <= opt.trace_from + opt.trace_count;
			if (show)
				std::printf("%10llu %12llu  %04X: %02X%s  a=%02X x=%02X sp=%02X cc=%02X  %llu cycles\n",
					(unsigned long long)retired, (unsigned long long)clocks, (unsigned)dut->tr_pc, (unsigned)dut->tr_op,
					is_int ? " (interrupt)" : "", (unsigned)dut->tr_a, (unsigned)dut->tr_x, (unsigned)dut->tr_sp,
					(unsigned)dut->tr_cc, (unsigned long long)ncyc);
#ifdef WITH_HC05REF
			if (opt.lockstep) {
				hc05_state_t before, after;
				hc05_ref_get_state(&before);
				int rcyc;
				if (is_int) {
					hc05_ref_interrupt((uint16_t)dut->tr_pc);
					rcyc = 10;
				}
				else {
					if (before.pc != dut->tr_pc) {
						std::printf("DIVERGED after %llu instructions: the RTL ran %04X, the reference is at %04X\n",
							(unsigned long long)retired, (unsigned)dut->tr_pc, before.pc);
						failed = true;
					}
					rcyc = hc05_ref_step();
				}
				hc05_ref_get_state(&after);
				bool same = !failed && io_error.empty() && after.a == dut->tr_a && after.x == dut->tr_x &&
				            after.sp == dut->tr_sp && (after.cc & 0x1F) == (dut->tr_cc & 0x1F) &&
				            (int)ncyc == rcyc && io_reads.empty();
				unsigned nw = hc05_ref_write_count();
				same = same && nw == rtl_writes.size();
				for (unsigned k = 0; same && k < nw; k++) {
					uint16_t wa; uint8_t wv;
					hc05_ref_write(k, &wa, &wv);
					same = wa == rtl_writes[k].first && wv == rtl_writes[k].second;
				}
				if (!same && !failed) {
					std::printf("MISMATCH after %llu instructions at %04X op %02X%s\n", (unsigned long long)retired,
						(unsigned)dut->tr_pc, (unsigned)dut->tr_op, is_int ? " (interrupt)" : "");
					std::printf("  reference a=%02X x=%02X sp=%02X cc=%02X pc=%04X cycles %d\n", after.a, after.x, after.sp,
						after.cc & 0x1F, after.pc, rcyc);
					std::printf("  RTL       a=%02X x=%02X sp=%02X cc=%02X cycles %llu\n", (unsigned)dut->tr_a,
						(unsigned)dut->tr_x, (unsigned)dut->tr_sp, (unsigned)dut->tr_cc & 0x1F, (unsigned long long)ncyc);
					for (unsigned k = 0; k < nw; k++) {
						uint16_t wa; uint8_t wv;
						hc05_ref_write(k, &wa, &wv);
						std::printf("  reference writes %02X at %04X\n", wv, wa);
					}
					for (auto& w : rtl_writes) std::printf("  RTL writes %02X at %04X\n", w.second, w.first);
					if (!io_error.empty()) std::printf("  %s\n", io_error.c_str());
					if (!io_reads.empty()) std::printf("  the RTL read %zu more registers\n", io_reads.size());
					if (++shown >= opt.show) failed = true;
					// carry on from the RTL's state
					hc05_state_t s = after;
					s.a = dut->tr_a; s.x = dut->tr_x; s.sp = dut->tr_sp; s.cc = dut->tr_cc;
					hc05_ref_set_state(&s);
					io_reads.clear();
					io_error.clear();
					failures++;
				}
			}
#endif
			rtl_writes.clear();
		}
	}

	std::printf("%.3f s of Cuda's time: %llu instructions, %llu interrupts, %llu bus cycles\n", clocks / CLK_HZ,
		(unsigned long long)retired, (unsigned long long)ints, (unsigned long long)bus_cycles);
	if (time_at_get)
		std::printf("Cuda's clock read %08X at %.3f s after its reset (the firmware starts it at 630BD178)\n",
			time_at_get, (double)script_started / CLK_HZ);
	if (!host.unsolicited.empty())
		for (auto& u : host.unsolicited) std::printf("unsolicited from Cuda: %s\n", hex(u).c_str());
	if (!off_seen) std::printf("Cuda never switched the power off: FAIL\n");
	bool ok = released && host.sync_done_at && script_i == script.size() && failures == 0 && !failed &&
	          off_seen && !off_early && off_held && wake_seen;
	if (opt.lockstep) std::printf("lockstep with MAME's 6805: %s\n", failures || failed ? "DIFFERENT" : "identical");
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	dut->final();
	delete dut;
	return ok ? 0 : 1;
}
