// Runs a program on the DSPPC604 pipeline and checks it in up to three ways:
//
//   C records in the program file: the architectural state after a given
//       instruction retires must equal recorded values (golden vectors from a
//       real 604, replayed as code).
//   --lockstep: after every retired instruction the state must equal that of
//       dingusppc's interpreter executing the same program (verilator/ref).
//   Final memory contents must equal the reference's (with --lockstep).
//
// Built two ways from this one file:
//
//   core_tb     the CPU alone (top DSPPC604), with a memory model on its
//               line port (random wait states; at the end every line the
//               data cache may hold dirty is written back through the snoop
//               port), running a program file.
//   machine_tb  the whole machine (top PPCMac_system, PPCMAC_MACHINE
//               defined): the CPU, PPCMac_machine with its device stubs, the
//               clock crossing, and this bench's software memory standing in
//               for the SDRAM controller on the far side, in its own clock.
//               It runs a ROM from the reset vector: --machine --rom FILE
//               [--ram MB]. In lockstep the reference gets the ROM and RAM,
//               and every value the core's devices answered (a device read
//               in the reference returns what the core's machine returned;
//               mftb and mfdec get the core's values; the decrementer and
//               external interrupts are taken where the core took them), so
//               the comparison is of the CPU alone.
//
// Program file (core_tb), one record per line, numbers in hex:
//   R pc              reset address
//   M addr word       a word of memory
//   C pc r3 r4 r5 r6 cr xer ctr fpscr f3 f4 f5 f6 tag
//                     state required after the instruction at pc
//   X addr word       a word memory must hold at the end
//   E pc              stop after the instruction at pc

#include <verilated.h>
#ifdef PPCMAC_MACHINE
#include "VPPCMac_system.h"
#include "VPPCMac_system___024root.h"
typedef VPPCMac_system Top;
#else
#include "VDSPPC604.h"
typedef VDSPPC604 Top;
#endif

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
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

const uint32_t PVR_604  = 0x00040303;

#ifdef PPCMAC_MACHINE
// the machine's SDRAM module, as PPCMac_system is built (SDRAM_MB)
const uint32_t SDRAM_SIZE = 128u << 20;
const uint32_t ROM_BASE   = 0xFFC00000u;
const uint32_t ROM_SIZE   = 4u << 20;
const uint32_t ROM_SDRAM  = SDRAM_SIZE - ROM_SIZE;
uint32_t RAM_SIZE = 16u << 20;               // installed RAM (--ram)
uint32_t RAM_MASK = 0xFFFFFFFFu;             // the bench's memory is indexed by SDRAM offset
#else
const uint32_t RAM_SIZE = 16u << 20;
const uint32_t RAM_MASK = RAM_SIZE - 1;
#endif

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
	// machine_tb
	bool machine = false;
	std::string rom;
	unsigned ram_mb = 16;
	double cpu_mhz = 65.0, mem_mhz = 100.0;
	uint64_t max_instr = 0;        // stop after this many instructions (0: no limit)
	uint64_t progress = 0;         // a line every N instructions
	std::string dev_log;           // every device access, in machref's log format
	uint64_t trace_from = 0, trace_count = 0;
	uint64_t stuck = 1ull << 24;   // cycles without a retirement that count as stuck
	bool memtest = false;          // boot the memory test in place of the ROM
	uint32_t memtest_passes = 1;   // ... and stop when it has completed this many
	int64_t mem_fault = -1;        // SDRAM offset whose reads come back with bit 0 flipped
	std::string nvram;             // an 8 KB image for Grand Central's NVRAM, loaded during reset
	unsigned serial_baud = 38400;  // the modem port's rate, for the bench's terminal
	std::vector<std::string> serial_in;   // lines typed at the modem port, one at each prompt
	std::string serial_log;        // what the machine sent on the modem port
	bool serial_stop = false;      // stop at the prompt after the last line (or the first prompt)
	unsigned monitor = 13;         // 13: Apple's 13-inch RGB (dingusppc's default); 16: the 16-inch
	uint64_t frame_at = 0;         // after this many instructions, write the next whole frame
	uint64_t frame_every = 0;      // ... and again every this many (0: once)
	std::string frame_out;         // ... to this file (PNG if it ends in .png, else PPM)
	struct MouseMove { uint64_t at; int dx, dy; };
	std::vector<MouseMove> mouse;  // PS/2 mouse packets, each after so many instructions
	bool vram_check = false;       // every CPU read of the VRAM window checked against what it wrote
	std::string vram_log;          // every CPU access to the VRAM window
	std::string disk[2];           // disk images for SCSI IDs 0 and 1 (hps_io slots 0 and 1)
	unsigned disk_latency = 2000;  // memory clocks from a block request to hps_io's acknowledge
	bool disk_log = false;         // print every block moved
};

// A frame as a PNG, stored (uncompressed) deflate blocks: no zlib needed.
static uint32_t png_crc(const uint8_t* p, size_t n, uint32_t c = 0xFFFFFFFFu) {
	static uint32_t t[256];
	static bool init = false;
	if (!init) {
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t v = i;
			for (int k = 0; k < 8; k++) v = (v & 1) ? 0xEDB88320u ^ (v >> 1) : v >> 1;
			t[i] = v;
		}
		init = true;
	}
	for (size_t i = 0; i < n; i++) c = t[(c ^ p[i]) & 0xFF] ^ (c >> 8);
	return c;
}

static bool write_image(const std::string& path, size_t w, const std::vector<std::vector<uint32_t>>& rows) {
	size_t h = rows.size();
	std::string tmp = path + ".tmp";
	FILE* f = std::fopen(tmp.c_str(), "wb");
	if (!f) return false;
	bool png = path.size() > 4 && path.compare(path.size() - 4, 4, ".png") == 0;
	auto px = [&](size_t y, size_t x) -> uint32_t { return x < rows[y].size() ? rows[y][x] : 0; };
	if (!png) {
		std::fprintf(f, "P6\n%zu %zu\n255\n", w, h);
		for (size_t y = 0; y < h; y++)
			for (size_t x = 0; x < w; x++) {
				uint32_t p = px(y, x);
				std::fputc(p >> 16, f); std::fputc((p >> 8) & 0xFF, f); std::fputc(p & 0xFF, f);
			}
	} else {
		std::vector<uint8_t> raw;
		raw.reserve(h * (1 + 3 * w));
		for (size_t y = 0; y < h; y++) {
			raw.push_back(0);
			for (size_t x = 0; x < w; x++) {
				uint32_t p = px(y, x);
				raw.push_back(p >> 16); raw.push_back((p >> 8) & 0xFF); raw.push_back(p & 0xFF);
			}
		}
		std::vector<uint8_t> z = {0x78, 0x01};
		uint32_t a = 1, b = 0;
		for (uint8_t v : raw) { a = (a + v) % 65521; b = (b + a) % 65521; }
		for (size_t i = 0; i < raw.size() || i == 0; i += 65535) {
			size_t n = std::min<size_t>(65535, raw.size() - i);
			z.push_back(i + n >= raw.size() ? 1 : 0);
			z.push_back(n & 0xFF); z.push_back(n >> 8); z.push_back(~n & 0xFF); z.push_back((~n >> 8) & 0xFF);
			z.insert(z.end(), raw.begin() + i, raw.begin() + i + n);
			if (raw.empty()) break;
		}
		uint32_t ad = (b << 16) | a;
		for (int k = 3; k >= 0; k--) z.push_back(ad >> (8 * k));
		auto chunk = [&](const char* kind, const std::vector<uint8_t>& body) {
			uint8_t len[4] = {uint8_t(body.size() >> 24), uint8_t(body.size() >> 16), uint8_t(body.size() >> 8), uint8_t(body.size())};
			std::fwrite(len, 1, 4, f);
			std::fwrite(kind, 1, 4, f);
			if (!body.empty()) std::fwrite(body.data(), 1, body.size(), f);
			uint32_t c = png_crc(reinterpret_cast<const uint8_t*>(kind), 4);
			c = png_crc(body.data(), body.size(), c) ^ 0xFFFFFFFFu;
			uint8_t cb[4] = {uint8_t(c >> 24), uint8_t(c >> 16), uint8_t(c >> 8), uint8_t(c)};
			std::fwrite(cb, 1, 4, f);
		};
		static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
		std::fwrite(sig, 1, 8, f);
		std::vector<uint8_t> ihdr = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w),
		                             uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h), 8, 2, 0, 0, 0};
		chunk("IHDR", ihdr);
		chunk("IDAT", z);
		chunk("IEND", {});
	}
	std::fclose(f);
	return std::rename(tmp.c_str(), path.c_str()) == 0;
}

// The VRAM's DDR3 (the framework's DDRAM port, Avalon) and the picture: a
// 4 MB memory at the core's DDR3 base, reads answered after a few cycles,
// one beat a cycle, BUSY now and then when --stall asks for it.
struct Ddr {
	static const uint32_t BASE = 0x06000000;   // 64-bit words: byte 3000_0000
	static const uint32_t WORDS = (4u << 20) / 8;
	std::vector<uint64_t> m = std::vector<uint64_t>(WORDS, 0);
	bool busy = false;
	struct Rd { uint32_t addr; unsigned left; int wait; };
	std::deque<Rd> rq;             // reads accepted, in order
	uint32_t wr_addr = 0;          // the write burst in progress: its next word, and words left
	unsigned wr_left = 0;
	bool ready = false;
	uint64_t dout = 0;
};

// A disk image behind hps_io's block interface, as the MiSTer's Main serves
// one: 512-byte blocks read from the file; blocks written are kept here, so
// the file is never changed.
struct Disk {
	FILE* f = nullptr;
	uint64_t size = 0;             // bytes
	std::map<uint32_t, std::vector<uint8_t>> written;
	void read(uint32_t lba, uint8_t* out) {
		auto it = written.find(lba);
		if (it != written.end()) { std::memcpy(out, it->second.data(), 512); return; }
		std::memset(out, 0, 512);
		if (f && (uint64_t)lba * 512 < size) {
			std::fseek(f, (long)((uint64_t)lba * 512), SEEK_SET);
			size_t got = std::fread(out, 1, 512, f);
			(void)got;
		}
	}
	void write(uint32_t lba, const uint8_t* in) { written[lba] = std::vector<uint8_t>(in, in + 512); }
};

// hps_io's side of the block interface (sys/hps_io.sv), in the memory's
// clock: the mounts at the start, then each request (sd_rd or sd_wr) taken
// after a latency (the ARM reading the file), sd_ack up, the 512 bytes
// written into the core's buffer (sd_buff_wr) or read from it (sd_buff_din,
// a clock or two after the address), sd_ack down.
struct SdHost {
	Disk disk[2];
	int st = 0;                    // 0 idle, 1 waiting, 2 moving, 3 the acknowledge falls
	int slot = 0;
	bool we = false;
	uint32_t lba = 0;
	unsigned wait = 0;
	int k = 0, sub = 0;
	uint8_t buf[512];
	uint64_t clocks = 0;
	// what the core sees
	unsigned mounted = 0, ack = 0;
	uint64_t img_size = 0;
	unsigned buff_addr = 0, buff_dout = 0;
	bool buff_wr = false;
	uint64_t reads = 0, writes = 0;
};

struct Frame {
	enum { WAIT, ARMED, TAKING, DONE } st = WAIT;
	uint64_t next = 0;             // the instruction count to take the next frame after
	std::vector<std::vector<uint32_t>> rows;
	bool in_line = false;
	bool vb_q = true;
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
#ifdef PPCMAC_MACHINE
		"usage: machine_tb --machine --rom FILE [options]\n"
		"  --ram MB         installed RAM (default 16)\n"
		"  --cpu-mhz F      the CPU's clock (default 65)\n"
		"  --mem-mhz F      the memory's clock (default 100)\n"
		"  --max-instr N    stop after N instructions\n"
		"  --progress N     print where the CPU is every N instructions\n"
		"  --dev-log FILE   log every device access (machref's format)\n"
		"  --trace-from N --trace-count M   print M retired instructions from the Nth\n"
		"  --stuck N        cycles without a retirement that end the run (default 2^24)\n"
		"  --boot memtest   run the memory-test boot program instead of the ROM (no --rom)\n"
		"  --memtest-passes N   stop after N passes of it (default 1); PASS if no errors\n"
		"  --mem-fault ADDR flip bit 0 of every read of this SDRAM byte offset\n"
		"  --nvram FILE     load this 8 KB image into Grand Central's NVRAM during reset\n"
		"  --serial-baud N  the modem port's rate for the bench's terminal (default 38400)\n"
		"  --serial-in TEXT type TEXT and a return at the modem port at the next prompt\n"
		"                   (\"> \"); repeat for more lines\n"
		"  --serial-log FILE  write what the machine sends on the modem port\n"
		"  --serial-stop    end the run at the prompt after the last line typed\n"
		"  --monitor 13|16  the monitor's sense code: Apple's 13-inch (640 x 480, the default,\n"
		"                   dingusppc's) or 16-inch RGB (832 x 624)\n"
		"  --frame-at N --frame-out FILE   after N instructions, write the next whole\n"
		"                   frame of the Control video's picture (PNG if FILE ends in .png,\n"
		"                   else PPM)\n"
		"  --frame-every N  and again every N instructions, over the same file (a\n"
		"                   picture to watch while the bench runs)\n"
		"  --mouse N:DX:DY  after N instructions, the PS/2 mouse moves DX right and DY down\n"
		"                   (repeat for more; N in order)\n"
		"  --vram-check     keep a copy of every CPU write to the VRAM window (90000000,\n"
		"                   Open Firmware's place for Control's VRAM), by VRAM byte (the\n"
		"                   window's low 22 bits: both apertures, wide mode, 8 bits a\n"
		"                   pixel), and check every CPU read of a byte written before\n"
		"  --vram-log FILE  write every CPU access to the VRAM window\n"
		"  --disk0 FILE --disk1 FILE   disk images for SCSI IDs 0 and 1 on MESH (hps_io\n"
		"                   slots 0 and 1; blocks written are kept in memory, the file\n"
		"                   is not changed)\n"
		"  --disk-latency N memory clocks from a block request to its answer (default 2000)\n"
		"  --disk-log       print every block moved\n"
#else
		"usage: core_tb --prog FILE [options]\n"
		"  --irq-every N    raise the external interrupt every N cycles; a store to\n"
		"                   address 00FFFFF0 takes it away again\n"
		"  --tb-run         advance the time base and decrementer every cycle\n"
#endif
		"  --lockstep       compare with dingusppc after every instruction\n"
		"  --stall P        percent chance of a bus wait state (default 0)\n"
		"  --seed N         seed for the wait states\n"
		"  --max-cycles N   give up after N clocks\n"
		"  --show N         mismatches printed before stopping (default 10)\n"
		"  --trace          print every retired instruction\n");
}

#ifdef PPCMAC_MACHINE
// A device access the core's machine answered, as seen on the CPU's port.
struct DevAccess {
	bool we, line;
	uint32_t addr;                 // byte address of the word, or of the line
	uint32_t be, wdata, rdata;     // a word access
	uint32_t lw[8], lr[8];         // a line, the lowest address first
};

// The device accesses not yet consumed by the reference, in order.
struct DevQueue {
	std::deque<DevAccess> q;
	// device lines the core's data cache read and may still hold: the
	// reference, which has no cache, reads them again and again
	std::map<uint32_t, std::vector<uint32_t>> cached;
	std::string error;             // the first disagreement, if any
	FILE* log = nullptr;
	uint64_t icount = 0;           // instructions before the one being stepped
	uint32_t pc = 0;
	uint64_t reads = 0, writes = 0, lines = 0, line_writes = 0, hits = 0;

	// a line written back to a device is the cache's business, not the
	// instruction's; it is not matched with the reference's stores
	void drop_writebacks() {
		while (!q.empty() && q.front().line && q.front().we) {
			const DevAccess& a = q.front();
			auto it = cached.find(a.addr);
			if (it != cached.end()) for (int k = 0; k < 8; k++) it->second[k] = a.lw[k];
			line_writes++;
			q.pop_front();
		}
	}
};

// A terminal on the modem port: decodes what the machine sends (8 data
// bits, no parity, at the given bit time in CPU clocks) and types lines,
// each one when the machine's output ends with a prompt ("> ") and has
// been quiet for two characters' time.
struct Terminal {
	double bit = 0;                // CPU clocks per bit
	// receiving what the machine sends
	bool rx_busy = false;
	double rx_t = 0;               // clocks into the current character
	int rx_bitn = 0;
	unsigned rx_sh = 0;
	std::string line, recent;      // the line so far (escape sequences left out); the output's last characters
	bool in_esc = false;           // inside an escape sequence (Open Firmware's line editor sends ANSI ones)
	uint64_t chars = 0, quiet = 0; // characters received; clocks since the last one
	FILE* log = nullptr;
	// typing
	std::vector<std::string> script;
	size_t next_line = 0;
	std::deque<uint8_t> out;       // characters still to type
	bool tx_busy = false;
	double tx_t = 0;
	unsigned tx_frame = 0;         // start, 8 data bits, 2 stop bits, LSB first
	bool txd = true;               // the line the machine receives
	bool prompted = false;         // a prompt has been seen since the last line was typed
	bool finished = false;         // the script is done and its last prompt seen

	void flush_line() {
		std::printf("serial: %s\n", line.c_str());
		line.clear();
	}

	// one CPU clock: rxd is what the machine sends
	void clock(bool rxd) {
		quiet++;
		if (!rx_busy) {
			if (!rxd) { rx_busy = true; rx_t = 0; rx_bitn = 0; rx_sh = 0; }
		} else {
			rx_t += 1;
			// sample bit k (1-8) in its middle: (k + 0.5) bit times after the start bit began
			if (rx_bitn < 8 && rx_t >= (rx_bitn + 1.5) * bit) {
				rx_sh |= (unsigned)rxd << rx_bitn;
				rx_bitn++;
			}
			else if (rx_bitn == 8 && rx_t >= 9.5 * bit) {   // the middle of the stop bit
				rx_busy = false;
				char c = (char)(rx_sh & 0x7F);
				chars++;
				quiet = 0;
				if (log) std::fputc(c, log);
				if (in_esc) in_esc = !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '@');
				else if (c == 0x1B) in_esc = true;
				else if (c == '\n') flush_line();
				else if (c >= 0x20 && c < 0x7F) line += c;
				recent += c;
				if (recent.size() > 16) recent.erase(0, recent.size() - 16);
				if (recent.size() >= 2 && recent.compare(recent.size() - 2, 2, "> ") == 0) prompted = true;
			}
		}
		// typing: the next line once a prompt is followed by quiet
		if (!tx_busy && out.empty() && prompted && quiet > 20 * bit) {
			prompted = false;
			if (next_line < script.size()) {
				if (!line.empty()) flush_line();
				std::printf("serial: (typing \"%s\")\n", script[next_line].c_str());
				for (char c : script[next_line]) out.push_back((uint8_t)c);
				out.push_back('\r');
				next_line++;
			}
			else finished = true;
		}
		if (!tx_busy && !out.empty()) {
			tx_frame = 0x600u | ((unsigned)out.front() << 1);   // 0, the byte, 1 1
			out.pop_front();
			tx_busy = true;
			tx_t = 0;
		}
		if (tx_busy) {
			int k = (int)(tx_t / bit);
			if (k >= 12) { tx_busy = false; txd = true; }        // two stop bits and a little gap
			else txd = k < 11 ? (tx_frame >> k) & 1 : true;
			tx_t += 1;
		}
	}
};

// the value an access of `size` bytes at byte address `addr` takes from a
// big-endian word (the lowest address in bits 31-24)
uint32_t lane_value(uint32_t word, uint32_t addr, unsigned size) {
	unsigned shift = 32 - 8 * ((addr & 3) + size);
	uint32_t mask = size == 4 ? 0xFFFFFFFFu : ((1u << (8 * size)) - 1);
	return (word >> shift) & mask;
}

uint32_t lane_be(uint32_t addr, unsigned size) {
	return ((size == 4 ? 0xFu : size == 2 ? 0x3u : 0x1u) << (4 - (addr & 3) - size)) & 0xF;
}

uint32_t dev_read(void* ctx, uint32_t addr, unsigned size) {
	DevQueue& d = *static_cast<DevQueue*>(ctx);
	char buf[256];
	d.drop_writebacks();
	uint32_t line_addr = addr & ~31u;
	bool front_line = !d.q.empty() && d.q.front().line && d.q.front().addr == line_addr;
	bool front_word = !d.q.empty() && !d.q.front().line;
	if (front_line) {
		// the core read the whole line through its data cache, as a 604
		// does with data translation off; remember it for the reads that
		// hit in the cache
		const DevAccess& a = d.q.front();
		d.cached[line_addr] = std::vector<uint32_t>(a.lr, a.lr + 8);
		d.q.pop_front();
		d.lines++;
	}
	if (!front_word) {
		auto it = d.cached.find(line_addr);
		if (it == d.cached.end()) {
			if (d.error.empty()) {
				std::snprintf(buf, sizeof buf, "the reference read %u bytes at %08X; the core made no device access", size, addr);
				d.error = buf;
			}
			return 0;
		}
		if (!front_line) d.hits++;
		uint32_t v = lane_value(it->second[(addr >> 2) & 7], addr, size);
		if (d.log) std::fprintf(d.log, "A %llu %08X R %u %08X %0*X %s\n", (unsigned long long)d.icount, d.pc, size, addr, size * 2, v,
			front_line ? "line" : "cached");
		return v;
	}
	DevAccess a = d.q.front();
	d.q.pop_front();
	if (a.we || a.addr != (addr & ~3u) || a.be != lane_be(addr, size)) {
		if (d.error.empty()) {
			std::snprintf(buf, sizeof buf, "the reference read %u bytes at %08X; the core %s %08X with byte enables %X",
				size, addr, a.we ? "wrote" : "read", a.addr, a.be);
			d.error = buf;
		}
		return 0;
	}
	uint32_t v = lane_value(a.rdata, addr, size);
	d.reads++;
	if (d.log) std::fprintf(d.log, "A %llu %08X R %u %08X %0*X\n", (unsigned long long)d.icount, d.pc, size, addr, size * 2, v);
	return v;
}

void dev_write(void* ctx, uint32_t addr, unsigned size, uint32_t value) {
	DevQueue& d = *static_cast<DevQueue*>(ctx);
	char buf[256];
	d.writes++;
	d.drop_writebacks();
	uint32_t line_addr = addr & ~31u;
	bool front_line = !d.q.empty() && d.q.front().line && !d.q.front().we && d.q.front().addr == line_addr;
	bool front_word = !d.q.empty() && !d.q.front().line;
	if (front_line) {
		// a store that missed in the core's data cache: the line is read
		// and the store goes into the cache (a 604 with the cache on and data
		// translation off does the same)
		const DevAccess& a = d.q.front();
		d.cached[line_addr] = std::vector<uint32_t>(a.lr, a.lr + 8);
		d.q.pop_front();
		d.lines++;
	}
	if (!front_word) {
		auto it = d.cached.find(line_addr);
		if (it != d.cached.end()) {
			// the store stays in the cache until the line is written back
			uint32_t& w = it->second[(addr >> 2) & 7];
			unsigned shift = 32 - 8 * ((addr & 3) + size);
			uint32_t mask = (size == 4 ? 0xFFFFFFFFu : ((1u << (8 * size)) - 1)) << shift;
			w = (w & ~mask) | ((value << shift) & mask);
			if (d.log) std::fprintf(d.log, "A %llu %08X W %u %08X %0*X %s\n", (unsigned long long)d.icount, d.pc, size, addr, size * 2, value,
				front_line ? "line" : "cached");
			return;
		}
	}
	if (d.log) std::fprintf(d.log, "A %llu %08X W %u %08X %0*X\n", (unsigned long long)d.icount, d.pc, size, addr, size * 2, value);
	if (d.q.empty()) {
		if (d.error.empty()) {
			std::snprintf(buf, sizeof buf, "the reference wrote %u bytes %X at %08X; the core made no device access", size, value, addr);
			d.error = buf;
		}
		return;
	}
	DevAccess a = d.q.front();
	d.q.pop_front();
	// a write-through store (Mac OS maps the frame buffer so): the core's
	// cache keeps the line it holds up to date, and so does the copy here
	auto cl = d.cached.find(line_addr);
	if (cl != d.cached.end()) {
		uint32_t& w = cl->second[(addr >> 2) & 7];
		unsigned shift = 32 - 8 * ((addr & 3) + size);
		uint32_t mask = (size == 4 ? 0xFFFFFFFFu : ((1u << (8 * size)) - 1)) << shift;
		w = (w & ~mask) | ((value << shift) & mask);
	}
	uint32_t got = lane_value(a.wdata, addr, size);
	if (!a.we || a.line || a.addr != (addr & ~3u) || a.be != lane_be(addr, size) || got != value) {
		if (d.error.empty()) {
			std::snprintf(buf, sizeof buf, "the reference wrote %u bytes %X at %08X; the core %s %08X with byte enables %X, data %08X",
				size, value, addr, a.we ? "wrote" : "read", a.addr, a.be, a.wdata);
			d.error = buf;
		}
	}
}
#endif

} // namespace

int main(int argc, char** argv) {
	std::setvbuf(stdout, nullptr, _IOLBF, 0);   // a line at a time, also into a pipe
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
		else if (a == "--machine") opt.machine = true;
		else if (a == "--rom") opt.rom = next();
		else if (a == "--ram") opt.ram_mb = (unsigned)std::atoi(next().c_str());
		else if (a == "--cpu-mhz") opt.cpu_mhz = std::atof(next().c_str());
		else if (a == "--mem-mhz") opt.mem_mhz = std::atof(next().c_str());
		else if (a == "--max-instr") opt.max_instr = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--progress") opt.progress = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--dev-log") opt.dev_log = next();
		else if (a == "--trace-from") opt.trace_from = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--trace-count") opt.trace_count = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--stuck") opt.stuck = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--boot") {
			std::string b = next();
			if (b == "memtest") opt.memtest = true;
			else if (b != "rom") { usage(); return 2; }
		}
		else if (a == "--memtest-passes") opt.memtest_passes = (uint32_t)std::strtoul(next().c_str(), nullptr, 0);
		else if (a == "--mem-fault") opt.mem_fault = (int64_t)std::strtoll(next().c_str(), nullptr, 0);
		else if (a == "--nvram") opt.nvram = next();
		else if (a == "--serial-baud") opt.serial_baud = (unsigned)std::atoi(next().c_str());
		else if (a == "--serial-in") opt.serial_in.push_back(next());
		else if (a == "--serial-log") opt.serial_log = next();
		else if (a == "--serial-stop") opt.serial_stop = true;
		else if (a == "--monitor") opt.monitor = (unsigned)std::atoi(next().c_str());
		else if (a == "--frame-at") opt.frame_at = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--frame-every") opt.frame_every = std::strtoull(next().c_str(), nullptr, 0);
		else if (a == "--frame-out") opt.frame_out = next();
		else if (a == "--mouse") {
			Options::MouseMove m{};
			if (std::sscanf(next().c_str(), "%llu:%d:%d", reinterpret_cast<unsigned long long*>(&m.at), &m.dx, &m.dy) != 3) {
				usage();
				return 2;
			}
			opt.mouse.push_back(m);
		}
		else if (a == "--vram-check") opt.vram_check = true;
		else if (a == "--vram-log") opt.vram_log = next();
		else if (a == "--disk0") opt.disk[0] = next();
		else if (a == "--disk1") opt.disk[1] = next();
		else if (a == "--disk-latency") opt.disk_latency = (unsigned)std::atoi(next().c_str());
		else if (a == "--disk-log") opt.disk_log = true;
		else { usage(); return a == "--help" ? 0 : 2; }
	}
#ifdef PPCMAC_MACHINE
	if (!opt.machine || opt.rom.empty() == !opt.memtest || !opt.prog.empty()) { usage(); return 2; }
	if (opt.memtest && opt.lockstep) {
		std::fprintf(stderr, "the memory test runs without the reference (it has no copy of the boot program)\n");
		return 2;
	}
	if (opt.ram_mb < 1 || (opt.ram_mb << 20) > ROM_SDRAM) {
		std::fprintf(stderr, "--ram must leave the top 4 MB of the %u MB module to the ROM\n", SDRAM_SIZE >> 20);
		return 2;
	}
	RAM_SIZE = opt.ram_mb << 20;
#else
	if (opt.machine) {
		std::fprintf(stderr, "this is the CPU-only bench; the machine runs in machine_tb\n");
		return 2;
	}
	if (opt.prog.empty()) { usage(); return 2; }
#endif
#ifndef WITH_REF
	if (opt.lockstep) {
		std::fprintf(stderr, "this build has no reference model; rebuild with the dingusppc library\n");
		return 2;
	}
#endif

	// ---- load the program, or the ROM ----
	std::map<uint32_t, Check> checks;
	std::vector<std::pair<uint32_t, uint32_t>> expect_mem;
	uint32_t reset_pc = 0x100, end_pc = 0xFFFFFFFF;
#ifdef PPCMAC_MACHINE
	std::vector<uint8_t> mem(SDRAM_SIZE, 0);
	std::vector<uint8_t> rom(ROM_SIZE, 0);
	if (!opt.memtest) {
		std::ifstream fh(opt.rom, std::ios::binary);
		if (!fh) { std::fprintf(stderr, "cannot open %s\n", opt.rom.c_str()); return 2; }
		fh.read(reinterpret_cast<char*>(rom.data()), ROM_SIZE);
		if (fh.gcount() != (std::streamsize)ROM_SIZE) { std::fprintf(stderr, "%s is not a 4 MB ROM\n", opt.rom.c_str()); return 2; }
		std::memcpy(mem.data() + ROM_SDRAM, rom.data(), ROM_SIZE);
	}
	reset_pc = 0xFFF00100;
	std::vector<uint8_t> nvimg;
	if (!opt.nvram.empty()) {
		std::ifstream fh(opt.nvram, std::ios::binary);
		nvimg.resize(8192);
		if (fh) fh.read(reinterpret_cast<char*>(nvimg.data()), 8192);
		if (!fh || fh.gcount() != 8192) { std::fprintf(stderr, "%s is not an 8 KB NVRAM image\n", opt.nvram.c_str()); return 2; }
	}
	Terminal term;
	term.bit = opt.cpu_mhz * 1e6 / opt.serial_baud;
	term.script = opt.serial_in;
	if (!opt.serial_log.empty()) {
		term.log = std::fopen(opt.serial_log.c_str(), "wb");
		if (!term.log) { std::fprintf(stderr, "cannot write %s\n", opt.serial_log.c_str()); return 2; }
	}
	int nv_ld = -1;                    // the NVRAM byte being loaded, while reset is held
	DevQueue devq;
	if (!opt.dev_log.empty()) {
		devq.log = std::fopen(opt.dev_log.c_str(), "w");
		if (!devq.log) { std::fprintf(stderr, "cannot write %s\n", opt.dev_log.c_str()); return 2; }
	}
#else
	std::vector<uint8_t> mem(RAM_SIZE, 0);
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
#endif

#ifdef WITH_REF
	if (opt.lockstep) {
		if (ref_init(RAM_SIZE, PVR_604) != 0) { std::fprintf(stderr, "reference model failed to start\n"); return 2; }
#ifdef PPCMAC_MACHINE
		// RAM, the ROM, and everything else answered by the core's machine
		if (ref_add_rom(ROM_BASE, rom.data(), ROM_SIZE) != 0 ||
		    ref_add_mmio(RAM_SIZE, ROM_BASE - RAM_SIZE, dev_read, dev_write, &devq) != 0) {
			std::fprintf(stderr, "reference model: cannot map the ROM and devices\n");
			return 2;
		}
#else
		std::memcpy(ref_ram(), mem.data(), RAM_SIZE);
#endif
		ref_state_t s{};
		s.pc = reset_pc;
		s.msr = 0x40;              // as the core leaves reset
		ref_set_state(&s);
	}
#endif

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<Top>(ctx.get());

	std::mt19937 rng(opt.seed);
	auto stalled = [&]() { return opt.stall > 0 && (int)(rng() % 100) < opt.stall; };

	Mem mm;
#ifdef PPCMAC_MACHINE
	Ddr ddr;
	Frame fr;
	fr.next = opt.frame_at;
	SdHost sd;
	for (int i = 0; i < 2; i++) {
		if (opt.disk[i].empty()) continue;
		sd.disk[i].f = std::fopen(opt.disk[i].c_str(), "rb");
		if (!sd.disk[i].f) { std::fprintf(stderr, "cannot open %s\n", opt.disk[i].c_str()); return 2; }
		std::fseek(sd.disk[i].f, 0, SEEK_END);
		sd.disk[i].size = (uint64_t)std::ftell(sd.disk[i].f);
		std::printf("disk %d: %s, %llu blocks\n", i, opt.disk[i].c_str(), (unsigned long long)(sd.disk[i].size / 512));
	}
#endif
	uint32_t gpr[32] = {0};
	std::pair<unsigned, uint64_t> beats[8];   // the register writes the core reported for this instruction
	int beats_n = 0;
	uint64_t fpr[32] = {0};
	uint64_t cycles = 0, retired = 0;
	long checked = 0, failed = 0;
	bool done = false, diverged = false;
	int cacheop_dsi_notes = 0;      // DSIs at cache instructions handed to the reference (both benches)

#ifdef PPCMAC_MACHINE
	// ---- two clocks: the CPU's (and the machine's), and the memory's ----
	const double pa = 1e6 / opt.cpu_mhz / 2, pb = 1e6 / opt.mem_mhz / 2;   // half periods, ps
	double ta = pa, tb = pb;                                              // next edge of each
	uint64_t last_retire_cycle = 0;
	bool stuck = false;
	bool cpu_ran = false, restarted = false;   // Cuda has let the CPU run; has reset it since
	uint64_t release_cycle = 0;
	int illegal_spr_notes = 0;
	int line_notes = 0;
	uint32_t mt_passes = 0, mt_errors = 0, mt_status = 0, mt_first = 0;
	int mt_error_lines = 0;
	// the PS/2 mouse (hps_io's ps2_mouse: [24] toggles once a packet, [23:16]
	// Y up, [15:8] X right, [5] and [4] their signs, [3] always 1)
	uint32_t ps2_mouse = 0;
	size_t mouse_next = 0;
	// the VRAM window as the CPU wrote it: every byte's value and whether it
	// has been written
	const uint32_t VWIN = 0x90000000u, VWIN_SIZE = 64u << 20, VRAM_MASK = (4u << 20) - 1;
	std::vector<uint8_t> vshadow, vknown;
	if (opt.vram_check) { vshadow.assign(VRAM_MASK + 1, 0); vknown.assign(VRAM_MASK + 1, 0); }
	uint64_t v_lr = 0, v_lw = 0, v_wr = 0, v_ww = 0, v_bad = 0;
	FILE* vlog = nullptr;
	if (!opt.vram_log.empty()) {
		vlog = std::fopen(opt.vram_log.c_str(), "w");
		if (!vlog) { std::fprintf(stderr, "cannot write %s\n", opt.vram_log.c_str()); return 2; }
	}

	auto drive = [&]() {
		dut->ps2_mouse = ps2_mouse;
		dut->ps2_key = 0;
		dut->ram_mb = opt.ram_mb;
		dut->boot_memtest = opt.memtest;
		dut->reset_pc = reset_pc;
		dut->modem_rxd = term.txd;
		dut->nv_ld_we = nv_ld >= 0;
		dut->nv_ld_addr = nv_ld >= 0 ? nv_ld : 0;
		dut->nv_ld_data = nv_ld >= 0 ? nvimg[nv_ld] : 0;
		dut->b_ack = mm.ack;
		for (int i = 0; i < 8; i++) dut->b_rdata[i] = mm.rdata[i];
		dut->mon_std = opt.monitor == 16 ? 7 : 6;
		dut->mon_ext = opt.monitor == 16 ? 0x2D : 0x2B;
		dut->ddr_busy = ddr.busy;
		dut->ddr_dout_ready = ddr.ready;
		dut->ddr_dout = ddr.dout;
		dut->img_mounted = sd.mounted;
		dut->img_size = sd.img_size;
		dut->img_readonly = 0;
		dut->sd_ack = sd.ack;
		dut->sd_buff_addr = sd.buff_addr;
		dut->sd_buff_dout = sd.buff_dout;
		dut->sd_buff_wr = sd.buff_wr;
	};

	// hps_io's block interface, on a rising edge of the memory's clock
	auto sd_edge = [&]() {
		sd.clocks++;
		sd.mounted = 0;
		sd.buff_wr = false;
		// the mounts, early (the machine still in reset, as at a core's start)
		for (int i = 0; i < 2; i++)
			if (sd.disk[i].f && sd.clocks == 16u + 16u * i) { sd.mounted = 1u << i; sd.img_size = sd.disk[i].size; }
		switch (sd.st) {
			case 0: {
				unsigned rd = dut->sd_rd, wr = dut->sd_wr;
				if ((rd | wr) & 3) {
					sd.slot = ((rd | wr) & 1) ? 0 : 1;
					sd.we = (wr >> sd.slot) & 1;
					sd.lba = dut->sd_lba;
					sd.wait = opt.disk_latency;
					sd.st = 1;
				}
				break;
			}
			case 1:
				if (sd.wait > 0) { sd.wait--; break; }
				sd.ack = 1u << sd.slot;
				sd.k = 0; sd.sub = 0;
				if (!sd.we) sd.disk[sd.slot].read(sd.lba, sd.buf);
				sd.buff_addr = 0;
				sd.st = 2;
				break;
			case 2:
				if (!sd.we) {
					// a byte a write strobe, the address moving on after it
					if (sd.sub == 0) { sd.buff_addr = sd.k; sd.buff_dout = sd.buf[sd.k]; sd.buff_wr = true; sd.sub = 1; }
					else { sd.sub = 0; if (++sd.k == 512) sd.st = 3; }
				} else {
					// the address, then the buffer's answer two clocks later
					if (sd.sub == 0) { sd.buff_addr = sd.k; sd.sub = 1; }
					else if (sd.sub == 1) sd.sub = 2;
					else { sd.buf[sd.k] = (uint8_t)dut->sd_buff_din; sd.sub = 0; if (++sd.k == 512) sd.st = 3; }
				}
				break;
			default:
				if (sd.we) { sd.disk[sd.slot].write(sd.lba, sd.buf); sd.writes++; } else sd.reads++;
				if (opt.disk_log)
					std::printf("disk %d: %s block %u after %llu instructions\n", sd.slot, sd.we ? "wrote" : "read", sd.lba,
						(unsigned long long)retired);
				sd.ack = 0;
				sd.st = 0;
				break;
		}
	};

	// the DDR3's recent traffic (for --vram-check's report), and how many
	// CPU reads the picture side answered differently from the DDR3
	std::deque<std::string> ddr_hist;
	uint64_t ddr_bad = 0;
	auto ddr_note = [&](const char* fmt, ...) {
		char b[160];
		va_list ap;
		va_start(ap, fmt);
		std::vsnprintf(b, sizeof b, fmt, ap);
		va_end(ap);
		ddr_hist.push_back(b);
		if (ddr_hist.size() > 48) ddr_hist.pop_front();
	};

	// the VRAM's DDR3, on a rising edge of the memory's clock: what the port
	// shows in the coming cycle, from what the core drives in it
	auto ddr_edge = [&]() {
		// a CPU read answered by the picture side in this cycle: its data
		// against the DDR3's
		if (opt.vram_check && dut->vram_ack && !dut->vram_we) {
			uint32_t byte = (uint32_t)dut->vram_addr << 2;
			int nw = dut->vram_line ? 8 : 1;
			for (int j = 0; j < nw; j++) {
				uint32_t a = dut->vram_line ? (byte & ~31u) + 4 * j : byte;
				uint64_t q = ddr.m[(a >> 3) % Ddr::WORDS];
				unsigned sh = (a & 4) ? 32 : 0;
				uint32_t want = (uint32_t)((q >> sh) & 0xFF) << 24 | (uint32_t)((q >> (sh + 8)) & 0xFF) << 16 |
				                (uint32_t)((q >> (sh + 16)) & 0xFF) << 8 | (uint32_t)((q >> (sh + 24)) & 0xFF);
				uint32_t got = dut->vram_line ? dut->vram_rdata[7 - j] : dut->vram_rdata[0];
				if (got != want && ddr_bad++ < 10) {
					std::printf("ddr-check: after %llu instructions, the picture side answered a %s read of VRAM %06X "
						"with %08X at %06X; the DDR3 holds %08X. Its recent traffic:\n", (unsigned long long)retired,
						dut->vram_line ? "line" : "word", byte, got, a, want);
					for (auto& h : ddr_hist) std::printf("    %s\n", h.c_str());
				}
			}
		}
		if (dut->vram_ack) ddr_note("%llu: answer %s %s %06X", (unsigned long long)sd.clocks, dut->vram_we ? "W" : "R",
			dut->vram_line ? "line" : "word", (uint32_t)dut->vram_addr << 2);
		ddr.ready = false;
		if (!ddr.rq.empty()) {
			Ddr::Rd& r = ddr.rq.front();
			if (r.wait > 0) r.wait--;
			else {
				ddr.dout  = ddr.m[(r.addr - Ddr::BASE) % Ddr::WORDS];
				ddr.ready = true;
				if (opt.vram_check)
					ddr_note("%llu: beat of %06X: %016llX", (unsigned long long)sd.clocks, (r.addr - Ddr::BASE) * 8,
						(unsigned long long)ddr.dout);
				r.addr++;
				if (--r.left == 0) ddr.rq.pop_front();
			}
		}
		bool rd = dut->ddr_rd, we = dut->ddr_we;
		uint32_t addr = dut->ddr_addr;
		unsigned cnt = dut->ddr_burstcnt;
		ddr.busy = (rd || we) && stalled();
		if ((rd || we) && (addr < Ddr::BASE || addr >= Ddr::BASE + Ddr::WORDS)) {
			static int notes = 0;
			if (notes++ < 5) std::printf("note: DDR3 access at word %08X, outside the VRAM\n", addr);
		}
		if (!ddr.busy && rd) {
			ddr.rq.push_back({addr, cnt ? cnt : 1, 4});
			if (opt.vram_check)
				ddr_note("%llu: read %06X x%u", (unsigned long long)sd.clocks, (addr - Ddr::BASE) * 8, cnt ? cnt : 1);
		}
		if (!ddr.busy && we) {
			if (opt.vram_check)
				ddr_note("%llu: write %06X be %02X %016llX", (unsigned long long)sd.clocks,
					((ddr.wr_left ? ddr.wr_addr : addr) - Ddr::BASE) * 8, (unsigned)dut->ddr_be, (unsigned long long)dut->ddr_din);
			if (ddr.wr_left == 0) { ddr.wr_addr = addr; ddr.wr_left = cnt ? cnt : 1; }
			uint64_t& w = ddr.m[(ddr.wr_addr - Ddr::BASE) % Ddr::WORDS];
			uint64_t din = dut->ddr_din;
			unsigned be = dut->ddr_be;
			for (int k = 0; k < 8; k++)
				if (be & (1u << k)) w = (w & ~(0xFFull << (8 * k))) | (din & (0xFFull << (8 * k)));
			ddr.wr_addr++;
			ddr.wr_left--;
		}
	};

	// the picture: after --frame-at instructions, the next whole frame
	auto frame_edge = [&]() {
		if (opt.frame_out.empty() || fr.st == Frame::DONE) return;
		if (fr.st == Frame::WAIT && retired >= fr.next) fr.st = Frame::ARMED;
		if (!dut->vid_ce) return;
		bool vb = dut->vid_vblank, hb = dut->vid_hblank;
		if (fr.st == Frame::ARMED && fr.vb_q && !vb) { fr.st = Frame::TAKING; fr.rows.clear(); fr.in_line = false; }
		if (fr.st == Frame::TAKING) {
			if (!vb && !hb) {
				if (!fr.in_line) { fr.rows.emplace_back(); fr.in_line = true; }
				fr.rows.back().push_back((uint32_t)dut->vid_r << 16 | (uint32_t)dut->vid_g << 8 | dut->vid_b);
			}
			else fr.in_line = false;
			if (!fr.vb_q && vb) {
				size_t w = fr.rows.empty() ? 0 : fr.rows[0].size();
				// (a %llu in the name: the instruction count, a file per frame)
				std::string name = opt.frame_out;
				size_t pct = name.find("%llu");
				if (pct != std::string::npos) name.replace(pct, 4, std::to_string((unsigned long long)retired));
				write_image(name, w, fr.rows);
				std::printf("frame: %zu x %zu after %llu instructions, written to %s\n", w, fr.rows.size(),
					(unsigned long long)retired, name.c_str());
				std::fflush(stdout);
				if (opt.frame_every) { fr.st = Frame::WAIT; fr.next = retired + opt.frame_every; }
				else fr.st = Frame::DONE;
			}
		}
		fr.vb_q = vb;
	};

	// the SDRAM's stand-in, on a rising edge of the memory's clock
	auto mem_edge = [&]() {
		if (mm.ack) { mm.ack = false; mm.pending = false; return; }
		if (dut->b_req && !mm.pending) {
			mm.pending = true;
			mm.wait = 1;
			while (stalled()) mm.wait++;
		}
		if (mm.pending && --mm.wait == 0) {
			bool we = dut->b_we, line = dut->b_line;
			uint32_t addr = (uint32_t)dut->b_addr << 2, be = dut->b_be;
			if (addr >= SDRAM_SIZE) { std::printf("memory request beyond the module: %08X\n", addr); addr &= SDRAM_SIZE - 1; }
			if (line) {
				uint32_t base = addr & ~31u;
				for (int k = 0; k < 8; k++) {
					// the ROM's part of the module is written only by the upload
					if (we && base < ROM_SDRAM) wr32(mem, base + 4 * k, dut->b_wdata[7 - k], 0xF);
					mm.rdata[7 - k] = rd32(mem, base + 4 * k);
					if (opt.mem_fault >= 0 && base + 4 * k == ((uint32_t)opt.mem_fault & ~3u))
						mm.rdata[7 - k] ^= 1u << (8 * (3 - (opt.mem_fault & 3)));
				}
			} else {
				if (we && addr < ROM_SDRAM) wr32(mem, addr, dut->b_wdata[0], be);
				mm.rdata[0] = rd32(mem, addr);
				if (opt.mem_fault >= 0 && addr == ((uint32_t)opt.mem_fault & ~3u))
					mm.rdata[0] ^= 1u << (8 * (3 - (opt.mem_fault & 3)));
			}
			mm.ack = true;
		}
	};

	// one cycle of the CPU's clock, with the memory's edges in between
	auto tick = [&]() {
		for (;;) {
			bool a_edge = ta <= tb;
			if (a_edge) ta += pa; else tb += pb;
			drive();
			if (a_edge) {
				dut->clk = !dut->clk;
				dut->eval();
				if (dut->clk) break;
			} else {
				dut->clk_b = !dut->clk_b;
				dut->eval();
				if (dut->clk_b) { mem_edge(); ddr_edge(); frame_edge(); sd_edge(); }
			}
		}
		cycles++;
#ifdef WITH_REF
		// a DMA write to RAM goes into the reference's RAM too (it has no DMA)
		if (opt.lockstep && dut->dma_wr) {
			uint8_t* rr = ref_ram();
			uint32_t addr = (uint32_t)dut->dma_wr_addr << 2;
			if (dut->dma_wr_line) {
				uint32_t base = addr & ~31u;
				for (int k = 0; k < 8; k++) {
					uint32_t w = dut->dma_wr_data[7 - k];
					for (int i = 0; i < 4; i++)
						if (base + 4 * k + i < RAM_SIZE) rr[base + 4 * k + i] = (uint8_t)(w >> (24 - 8 * i));
				}
			} else {
				uint32_t w = dut->dma_wr_data[0], be = dut->dma_wr_be;
				for (int i = 0; i < 4; i++)
					if ((be & (8u >> i)) && addr + i < RAM_SIZE) rr[addr + i] = (uint8_t)(w >> (24 - 8 * i));
			}
		}
#endif
		// a device access answered by the machine: everything but RAM and ROM reads
		if (dut->cpu_ack && dut->cpu_req) {
			uint32_t addr = (uint32_t)dut->cpu_addr << 2;
			bool rom_read = addr >= ROM_BASE && !dut->cpu_we;
			if (addr >= RAM_SIZE && !rom_read) {
				DevAccess a{(bool)dut->cpu_we, (bool)dut->cpu_line, addr, dut->cpu_be, dut->cpu_wdata[0], dut->cpu_rdata[0], {}, {}};
				for (int k = 0; k < 8; k++) { a.lw[k] = dut->cpu_wdata[7 - k]; a.lr[k] = dut->cpu_rdata[7 - k]; }
				if (a.line) {
					a.addr &= ~31u;
					if (line_notes++ < 10) std::printf("note: a line %s at %08X outside RAM and ROM, after %llu instructions%s\n",
						a.we ? "write" : "read", a.addr, (unsigned long long)retired, line_notes == 10 ? " (no more notes)" : "");
				}
				if (opt.lockstep) devq.q.push_back(a);
				else if (devq.log) {
					if (a.we) std::fprintf(devq.log, "A %llu %08X W 4 %08X %08X be %X\n", (unsigned long long)retired, 0u, addr, a.wdata, a.be);
					else std::fprintf(devq.log, "A %llu %08X R 4 %08X %08X be %X\n", (unsigned long long)retired, 0u, addr, a.rdata, a.be);
				}
				if (a.addr - VWIN < VWIN_SIZE) {
					if (vlog) {
						std::fprintf(vlog, "%llu %08X %c %08X", (unsigned long long)retired, (uint32_t)dut->trace_pc,
							a.we ? 'W' : 'R', a.addr);
						if (a.line)
							for (int k = 0; k < 8; k++) std::fprintf(vlog, " %08X", a.we ? a.lw[k] : a.lr[k]);
						else std::fprintf(vlog, " %08X be %X", a.we ? a.wdata : a.rdata, a.be);
						std::fprintf(vlog, "\n");
					}
				}
				if (opt.vram_check && a.addr - VWIN < VWIN_SIZE) {
					// each byte of the access: its VRAM byte (both apertures alike,
					// as at 8 bits a pixel in wide mode), the value read or
					// written, whether the access covers it
					int nw = a.line ? 8 : 1;
					(a.line ? (a.we ? v_lw : v_lr) : (a.we ? v_ww : v_wr))++;
					for (int k = 0; k < nw; k++) {
						uint32_t wv = a.line ? (a.we ? a.lw[k] : a.lr[k]) : (a.we ? a.wdata : a.rdata);
						for (int i = 0; i < 4; i++) {
							if (!a.line && !(a.be & (8u >> i))) continue;
							uint32_t ca = a.addr + 4 * k + i;
							uint32_t off = ca & VRAM_MASK;
							uint8_t v = (uint8_t)(wv >> (24 - 8 * i));
							if (a.we) { vshadow[off] = v; vknown[off] = 1; }
							else if (vknown[off] && vshadow[off] != v && v_bad++ < 40)
								std::printf("vram-check: after %llu instructions (pc %08X), a %s read of %08X gave %02X, %02X was written\n",
									(unsigned long long)retired, (uint32_t)dut->trace_pc, a.line ? "line" : "word", ca, v, vshadow[off]);
						}
					}
				}
			}
		}
	};

	dut->clk = 0; dut->clk_b = 0;
	dut->reset = 1; dut->reset_b = 1;
	for (int i = 0; i < 4; i++) tick();
	// the NVRAM image, a byte a clock, with reset still held (as the MiSTer's
	// boot1.rom is loaded)
	if (!nvimg.empty()) {
		for (nv_ld = 0; nv_ld < 8192; nv_ld++) tick();
		nv_ld = -1;
		tick();
	}
	dut->reset = 0; dut->reset_b = 0;
	mm = Mem();
	cycles = 0;
#else
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
#endif

	while (!done && cycles < opt.max_cycles) {
		tick();

#ifdef PPCMAC_MACHINE
		term.clock(dut->modem_txd);
		if (opt.serial_stop && term.finished) {
			std::printf("serial: the last line typed has been answered with a prompt\n");
			done = true;
		}
		// Cuda holds the CPU in reset from the start until its firmware has
		// powered the machine up; again if it restarts it
		if (dut->cpu_in_reset) {
			if (cpu_ran && !restarted) {
				std::printf("Cuda reset the CPU after %llu instructions, %llu cycles%s\n", (unsigned long long)retired,
					(unsigned long long)cycles, opt.lockstep ? ": the lockstep ends here" : "");
				restarted = true;
				if (opt.lockstep) done = true;
			}
			last_retire_cycle = cycles;
			continue;
		}
		if (!cpu_ran) {
			cpu_ran = true;
			release_cycle = cycles;
			std::printf("Cuda released the CPU's reset after %llu cycles\n", (unsigned long long)cycles);
		}
		if (cycles - last_retire_cycle > opt.stuck) { stuck = true; break; }
		// the memory test reports through the machine's debug registers
		if (opt.memtest) {
			uint32_t passes = dut->dbg_passes, errors = dut->dbg_errors, status = dut->dbg_status;
			uint32_t first = dut->dbg_first;
			if (first != mt_first && first != 0xFFFFFFFFu) {
				std::printf("memory test: first error at %08X, after %llu instructions\n", first, (unsigned long long)retired);
				mt_first = first;
			}
			if (passes != mt_passes || errors != mt_errors || status != mt_status) {
				if (errors != mt_errors && mt_error_lines++ < 10)
					std::printf("memory test: %u errors after %llu instructions\n", errors, (unsigned long long)retired);
				if (passes != mt_passes)
					std::printf("memory test: pass %u done after %llu instructions, %llu cycles, %u errors\n",
						passes, (unsigned long long)retired, (unsigned long long)cycles, errors);
				if ((status >> 24) == 0xEE)
					std::printf("memory test: exception at vector %X\n", status & 0xFFFF);
				mt_passes = passes; mt_errors = errors; mt_status = status;
			}
			if (passes >= opt.memtest_passes || (status >> 24) == 0xEE) done = true;
		}
#endif
		if (dut->trace_valid) {
			if (dut->trace_reg_we) {
				unsigned idx = dut->trace_reg_idx;
				if (idx < 32) gpr[idx] = (uint32_t)dut->trace_reg_val;
				else if (idx >= 64) fpr[idx - 64] = dut->trace_reg_val;
				if (beats_n < 8) beats[beats_n++] = {idx, (uint64_t)dut->trace_reg_val};
			}
			if (dut->trace_last) {
				uint32_t pc = dut->trace_pc, insn = dut->trace_insn;
				retired++;
#ifdef PPCMAC_MACHINE
				last_retire_cycle = cycles;
				bool show = opt.trace || (opt.trace_count && retired > opt.trace_from && retired <= opt.trace_from + opt.trace_count);
				if (show) {
					std::printf("%10llu %10llu  %08X: %08X  msr=%08X cr=%08X lr=%08X ctr=%08X",
						(unsigned long long)retired, (unsigned long long)cycles, pc, insn, dut->trace_msr,
						dut->trace_cr, dut->trace_lr, dut->trace_ctr);
					for (int k = 0; k < beats_n; k++)           // the registers it wrote (32: the sequencer's scratch)
						std::printf("  %s%u=%0*llX", beats[k].first >= 64 ? "f" : "r", beats[k].first & 63,
							beats[k].first >= 64 ? 16 : 8, (unsigned long long)beats[k].second);
					std::printf("\n");
				}
				if (opt.progress && retired % opt.progress == 0) {
					std::printf("progress: %llu instructions, %llu cycles, pc %08X, msr %08X\n",
						(unsigned long long)retired, (unsigned long long)cycles, pc, dut->trace_msr);
					if (!opt.disk[0].empty())
						std::printf("disks: valid %u (memory clock's side %u, toggle %u), blocks %u, target state %u\n",
							(unsigned)dut->rootp->PPCMac_system__DOT__machine__DOT__disks__DOT__m_valid,
							(unsigned)dut->rootp->PPCMac_system__DOT__machine__DOT__disks__DOT__h_valid,
							(unsigned)dut->rootp->PPCMac_system__DOT__machine__DOT__disks__DOT__h_mtog,
							(unsigned)dut->rootp->PPCMac_system__DOT__machine__DOT__disks__DOT__m_blocks[0],
							(unsigned)dut->rootp->PPCMac_system__DOT__machine__DOT__disks__DOT__ts);
					std::fflush(stdout);
				}
				if (opt.max_instr && retired >= opt.max_instr) done = true;
				while (mouse_next < opt.mouse.size() && retired >= opt.mouse[mouse_next].at) {
					const Options::MouseMove& m = opt.mouse[mouse_next++];
					int x = std::max(-255, std::min(255, m.dx)), y = std::max(-255, std::min(255, -m.dy));
					ps2_mouse = ((ps2_mouse ^ (1u << 24)) & (1u << 24)) | ((uint32_t)(y & 0xFF) << 16) | ((uint32_t)(x & 0xFF) << 8) |
					            (y < 0 ? 0x20u : 0u) | (x < 0 ? 0x10u : 0u) | 0x08u;
					std::printf("mouse: moved %d right, %d down after %llu instructions\n", m.dx, m.dy, (unsigned long long)retired);
				}
#else
				if (opt.trace)
					std::printf("%10llu  %08X: %08X  cr=%08X xer=%08X lr=%08X ctr=%08X\n",
						(unsigned long long)cycles, pc, insn, dut->trace_cr, dut->trace_xer, dut->trace_lr, dut->trace_ctr);
#endif

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
#ifdef PPCMAC_MACHINE
					// an interrupt the core took before this instruction: the
					// decrementer's and the external vector are reached no other way
					if (before.pc != pc && ((pc & 0xFFF00000u) == 0 || (pc & 0xFFF00000u) == 0xFFF00000u) &&
					    ((pc & 0xFFFFF) == 0x900 || (pc & 0xFFFFF) == 0x500)) {
						ref_interrupt(pc & 0xFFFFF);
						if (before.msr & 4u) ref_set_spr(27, ref_get_spr(27) | 4u);     // PM into SRR1, as below
						ref_get_state(&before);
					}
					// mtspr or mfspr of an SPR the real 604 does not have: a program
					// exception (illegal) on the chip and in the core, while dingusppc
					// accepts the 604e's (MMCR1, PMC3, PMC4: the NanoKernel probes
					// them). The reference is made to take it as the core did.
					if (before.pc != pc && (pc & 0xFFFFF) == 0x700 && !(before.msr & 0x20)) {
						uint32_t w = 0;
						bool known = false;
						if (before.pc >= ROM_BASE) {
							uint32_t o = before.pc - ROM_BASE;
							w = (uint32_t)rom[o] << 24 | (uint32_t)rom[o + 1] << 16 | (uint32_t)rom[o + 2] << 8 | rom[o + 3];
							known = true;
						}
						else if (before.pc + 4 <= RAM_SIZE) {
							const uint8_t* rm = ref_ram();
							w = (uint32_t)rm[before.pc] << 24 | (uint32_t)rm[before.pc + 1] << 16 | (uint32_t)rm[before.pc + 2] << 8 | rm[before.pc + 3];
							known = true;
						}
						uint32_t xo = (w >> 1) & 0x3FF;
						unsigned spr = ((w >> 16) & 31) | (((w >> 11) & 31) << 5);
						static const unsigned spr604[] = {1, 8, 9, 18, 19, 22, 25, 26, 27, 268, 269, 272, 273, 274, 275, 282,
						                                  284, 285, 287, 952, 953, 954, 955, 959, 1008, 1010, 1013, 1023};
						bool has = spr >= 528 && spr <= 543;
						for (unsigned s : spr604) has = has || s == spr;
						if (known && (w >> 26) == 31 && (xo == 467 || xo == 339) && !has) {
							uint32_t at = before.pc;
							ref_set_spr(26, at);
							ref_set_spr(27, (before.msr & 0x87C0FFFFu) | 0x00080000u);
							ref_state_t t = before;
							t.msr = (before.msr & 0x00001040u) | ((before.msr >> 16) & 1u);
							t.pc = pc;
							ref_set_state(&t);
							ref_get_state(&before);
							if (illegal_spr_notes++ < 10)
								std::printf("note: %s of SPR %u at %08X after %llu instructions: a program exception on a 604\n",
									xo == 467 ? "mtspr" : "mfspr", spr, at, (unsigned long long)retired);
						}
					}
#endif
					// A DSI at dcbst, dcbf, icbi or dcbi: the core translates them
					// (as loads; dcbi as a store) as the 604 does, dingusppc does
					// not translate them at all. The NanoKernel fills the hardware
					// page table on demand, so Mac OS takes such a DSI on the real
					// machine too. The reference is made to take it: DAR the
					// effective address, DSISR "no translation", or the protection
					// bit if dingusppc's MMU does translate the address (the handler
					// reads DSISR, and the comparison checks it there).
					if (before.pc != pc && (pc & 0xFFFFF) == 0x300 && (before.msr & 0x30) == 0x30) {
						uint32_t ipa = 0, w = 0;
						bool known = false;
						if (ref_translate_dbg(before.pc, &ipa) == 0) {
							if (ipa + 4 <= RAM_SIZE) {
								const uint8_t* rm = ref_ram();
								w = (uint32_t)rm[ipa] << 24 | (uint32_t)rm[ipa + 1] << 16 | (uint32_t)rm[ipa + 2] << 8 | rm[ipa + 3];
								known = true;
							}
#ifdef PPCMAC_MACHINE
							else if (ipa >= ROM_BASE) {
								uint32_t o = ipa - ROM_BASE;
								w = (uint32_t)rom[o] << 24 | (uint32_t)rom[o + 1] << 16 | (uint32_t)rom[o + 2] << 8 | rom[o + 3];
								known = true;
							}
#endif
						}
						uint32_t xo = (w >> 1) & 0x3FF;
						if (known && (w >> 26) == 31 && (xo == 54 || xo == 86 || xo == 982 || xo == 470)) {
							unsigned ra = (w >> 16) & 31, rb = (w >> 11) & 31;
							uint32_t ea = (ra ? before.gpr[ra] : 0) + before.gpr[rb];
							uint32_t dpa = 0;
							bool mapped = ref_translate_dbg(ea, &dpa) == 0;
							uint32_t dsisr = (mapped ? 0x08000000u : 0x40000000u) | (xo == 470 ? 0x02000000u : 0);
							ref_set_spr(26, before.pc);
							ref_set_spr(27, before.msr & 0x87C0FFFFu);
							ref_set_spr(19, ea);
							ref_set_spr(18, dsisr);
							ref_state_t t = before;
							t.msr = (before.msr & 0x00001040u) | ((before.msr >> 16) & 1u);
							t.pc = pc;
							ref_set_state(&t);
							ref_get_state(&before);
							if (cacheop_dsi_notes++ < 10)
								std::printf("note: DSI at %s of %08X (%08X) after %llu instructions, %s: the reference takes it too\n",
									xo == 54 ? "dcbst" : xo == 86 ? "dcbf" : xo == 982 ? "icbi" : "dcbi", ea, w,
									(unsigned long long)retired, mapped ? "a protection violation" : "no translation");
						}
					}
					// The core retires nothing for an instruction that takes an
					// exception; the reference has to take it now to catch up.
					for (int tries = 0; tries < 3 && before.pc != pc; tries++) {
#ifdef PPCMAC_MACHINE
						devq.icount = retired - 1;
						devq.pc = before.pc;
#endif
						int vec = ref_step();
						if (vec <= 0) break;
						// two places where dingusppc sets SRR1 bits it should not
						if (vec == 0xC00) ref_set_spr(27, ref_get_spr(27) & ~0x00020000u);
						if (vec == 0x800) ref_set_spr(27, ref_get_spr(27) & ~0x00100000u);
						// ... and one it drops: SRR1 takes MSR bits 0x87C0FFFF on a 604,
						// PM (bit 29) among them; dingusppc keeps 0x0000FF73
						// (ppc_exception_handler). Mac OS runs with PM set.
						if (before.msr & 4u) ref_set_spr(27, ref_get_spr(27) | 4u);
						// dingusppc clears CR0 before stwcx.'s store, so a DSI there
						// leaves CR0 changed; a 604 leaves it alone (the programs keep
						// the code where its address is its physical address)
						if (vec == 0x300) {
							const uint8_t* rm = ref_ram();
							uint32_t a = ref_get_spr(26) & RAM_MASK & ~3u;
							if (a + 4 <= RAM_SIZE) {
								uint32_t w = (uint32_t)rm[a] << 24 | (uint32_t)rm[a + 1] << 16 | (uint32_t)rm[a + 2] << 8 | rm[a + 3];
								if ((w >> 26) == 31 && ((w >> 1) & 0x3FF) == 150) {
									ref_state_t t{};
									ref_get_state(&t);
									t.cr = before.cr;
									ref_set_state(&t);
								}
							}
						}
						ref_get_state(&before);
					}
					if (before.pc != pc) {
						std::printf("DIVERGED after %llu instructions: core retired %08X, reference is at %08X\n",
							(unsigned long long)retired, pc, before.pc);
						std::printf("  the reference's state there (the core's too, up to this instruction): msr %08X cr %08X lr %08X ctr %08X\n",
							before.msr, before.cr, before.lr, before.ctr);
						for (int r = 0; r < 32; r += 8)
							std::printf("  r%-2d %08X %08X %08X %08X %08X %08X %08X %08X\n", r, before.gpr[r], before.gpr[r + 1],
								before.gpr[r + 2], before.gpr[r + 3], before.gpr[r + 4], before.gpr[r + 5], before.gpr[r + 6], before.gpr[r + 7]);
						diverged = true;
						break;
					}
#ifdef PPCMAC_MACHINE
					devq.icount = retired - 1;
					devq.pc = pc;
#endif
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
					// rfi: a 604 copies SRR1's low 16 bits into MSR, PM (bit 29)
					// among them (measured: README, MSR keeps 0005FF77 and rfi the
					// low 16); dingusppc's ppc_rfi leaves PM alone (its mask is
					// 0x87C0FF73). The NanoKernel returns to Mac OS with PM set.
					if (insn == 0x4C000064u && rc == 0) {
						s.msr = (s.msr & ~4u) | (ref_get_spr(27) & 4u);
						ref_set_state(&s);
					}
#ifdef PPCMAC_MACHINE
					// time is the core's: mftb and mfspr of the time base or the
					// decrementer read what the core's counters held
					uint32_t xo10 = (insn >> 1) & 0x3FF;
					uint32_t sprn = ((insn >> 16) & 31) | (((insn >> 11) & 31) << 5);
					if ((insn >> 26) == 31 && (xo10 == 371 || xo10 == 339) &&
					    (sprn == 22 || sprn == 268 || sprn == 269 || sprn == 284 || sprn == 285)) {
						unsigned rd = (insn >> 21) & 31;
						s.gpr[rd] = gpr[rd];
						ref_set_state(&s);
					}
					if (!devq.error.empty()) {
						std::printf("DEVICE ACCESSES DIFFER after %llu instructions at %08X insn=%08X: %s\n",
							(unsigned long long)retired, pc, insn, devq.error.c_str());
						diverged = true;
						break;
					}
#endif

					bool same = rc == 0 && s.cr == dut->trace_cr && s.xer == dut->trace_xer &&
					            s.lr == dut->trace_lr && s.ctr == dut->trace_ctr && s.msr == dut->trace_msr;
					for (int r = 0; r < 32 && same; r++) same = s.gpr[r] == gpr[r];
					if (!same) {
						std::printf("MISMATCH after %llu instructions at %08X insn=%08X (reference step returned %X; r0=%08X r1=%08X r2=%08X)\n",
							(unsigned long long)retired, pc, insn, rc, gpr[0], gpr[1], gpr[2]);
						if (rc == REF_STEP_FAULT) std::printf("  reference: %s\n", ref_last_error());
						for (int r = 0; r < 32; r++)
							if (s.gpr[r] != gpr[r]) std::printf("  r%-2d   reference %08X  core %08X\n", r, s.gpr[r], gpr[r]);
						if (s.cr != dut->trace_cr)   std::printf("  cr    reference %08X  core %08X\n", s.cr, dut->trace_cr);
						if (s.xer != dut->trace_xer) std::printf("  xer   reference %08X  core %08X\n", s.xer, dut->trace_xer);
						if (s.lr != dut->trace_lr)   std::printf("  lr    reference %08X  core %08X\n", s.lr, dut->trace_lr);
						if (s.ctr != dut->trace_ctr) std::printf("  ctr   reference %08X  core %08X\n", s.ctr, dut->trace_ctr);
						if (s.msr != dut->trace_msr) std::printf("  msr   reference %08X  core %08X\n", s.msr, dut->trace_msr);
						std::printf("  the core reported writing:");
						for (int k = 0; k < beats_n; k++) std::printf(" r%u=%08llX", beats[k].first, (unsigned long long)beats[k].second);
						std::printf("\n  before it: rD/rS field r%u=%08X, rA field r%u=%08X, rB field r%u=%08X\n",
							(insn >> 21) & 31, before.gpr[(insn >> 21) & 31], (insn >> 16) & 31, before.gpr[(insn >> 16) & 31],
							(insn >> 11) & 31, before.gpr[(insn >> 11) & 31]);
						diverged = true;
						break;
					}
				}
#endif
				beats_n = 0;
				if (pc == end_pc) done = true;
			}
		}
	}

	bool mem_ok = true;
#ifdef PPCMAC_MACHINE
	dut->final();
	if (devq.log) std::fclose(devq.log);
	if (!term.line.empty()) term.flush_line();
	if (term.log) std::fclose(term.log);
	if (term.chars || !term.script.empty())
		std::printf("serial: %llu characters received, %zu of %zu lines typed\n", (unsigned long long)term.chars,
			term.next_line, term.script.size());
	std::printf("%llu instructions in %llu cycles after Cuda released the CPU (%.2f cycles per instruction)\n",
		(unsigned long long)retired, (unsigned long long)(cycles - release_cycle),
		retired ? (double)(cycles - release_cycle) / retired : 0.0);
	std::printf("last retired: pc %08X, msr %08X\n", (uint32_t)dut->trace_pc, (uint32_t)dut->trace_msr);
	if (opt.lockstep)
		std::printf("device accesses: %llu reads and %llu writes compared; %llu line reads and %llu line writes "
			"outside RAM and ROM, %llu reads answered from a cached device line\n",
			(unsigned long long)devq.reads, (unsigned long long)devq.writes, (unsigned long long)devq.lines,
			(unsigned long long)devq.line_writes, (unsigned long long)devq.hits);
	if (vlog) std::fclose(vlog);
	if (sd.reads || sd.writes)
		std::printf("disks: %llu blocks read, %llu written\n", (unsigned long long)sd.reads, (unsigned long long)sd.writes);
	if (opt.vram_check)
		std::printf("vram-check: %llu line reads, %llu line writes, %llu word reads, %llu word writes of the VRAM window; "
			"%llu bytes read back differently from what was written\n", (unsigned long long)v_lr, (unsigned long long)v_lw,
			(unsigned long long)v_wr, (unsigned long long)v_ww, (unsigned long long)v_bad);
	if (stuck) std::printf("STUCK: nothing retired for %llu cycles\n", (unsigned long long)opt.stuck);
	if (opt.lockstep) std::printf("lockstep with the reference: %s\n", diverged ? "DIVERGED" : "identical");
	bool ok = !diverged && !stuck && (done || cycles >= opt.max_cycles);
	if (opt.serial_stop && !term.finished) {
		std::printf("serial: the run ended before the last line typed was answered with a prompt\n");
		ok = false;
	}
	if (opt.memtest) {
		std::printf("memory test: %u passes over %u MB, %u errors", mt_passes, opt.ram_mb, mt_errors);
		if (mt_errors) std::printf(", the first at %08X", (uint32_t)dut->dbg_first);
		std::printf("\n");
		// with a fault injected the test must find it; without, find nothing
		ok = !stuck && mt_passes >= opt.memtest_passes && (mt_status >> 24) != 0xEE &&
		     (opt.mem_fault >= 0 ? mt_errors > 0 : mt_errors == 0);
	}
	(void)mem_ok; (void)checked; (void)failed; (void)end_pc;
	std::printf("%s\n", ok ? "RESULT: PASS" : "RESULT: FAIL");
	return ok ? 0 : 1;
#else
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
#endif
}
