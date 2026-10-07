// The SCSI bench: MESH, its DBDMA channel (A) and the disks (scsi_tb_top),
// driven through Grand Central's registers the way the 7300's ROM and Mac OS
// 7.6.1's disk driver drive them (dingusppc's device log of the 7.6.1
// image's boot, docs/PPCMac_plan.md milestone S), with a memory on the DMA
// port and hps_io's block side as the MiSTer's Main serves an image.
//
//   1. the ROM's way: arbitrate, select without ATN, READ(6) of block 0,
//      bus free (a phase mismatch), the data by programmed I/O through the
//      FIFO 16 bytes at a time, status, message in (ACK left up), bus free;
//   2. READ(6) of 19 blocks from block 64 the same way (the boot driver);
//   3. Mac OS's driver: select with ATN, IDENTIFY, READ(10) of one block, its
//      first 6 bytes by programmed I/O, 504 by DMA into memory at an odd
//      address (a descriptor longer than MESH's count, flushed and stopped
//      after command done), the last 2 by programmed I/O;
//   4. READ(10) of 3 blocks wholly by DMA (two descriptors and a STOP);
//   5. WRITE(10) of 2 blocks by DMA out from memory, then read back by DMA;
//   6. an INQUIRY, a READ CAPACITY, a selection of an absent ID (timeout).
//
// Every byte the drivers take is checked against the image; every step's
// registers (interrupt, exception, bus phase) against what the reference
// log shows them to be.

#include <verilated.h>
#include "Vscsi_tb_top.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {

std::unique_ptr<Vscsi_tb_top> dut;
uint64_t cycles = 0;
int fails = 0;
bool verbose = false;

// ---- the image: a made-up one unless --disk --------------------------------------------------
const uint32_t BLOCKS = 4096;
FILE* disk_f = nullptr;
std::map<uint32_t, std::vector<uint8_t>> written;
uint8_t disk_byte(uint32_t lba, uint32_t k) { return (uint8_t)(lba * 7 + k * 13 + (k >> 8) * 5 + 1); }
void disk_read(uint32_t lba, uint8_t* out) {
	auto it = written.find(lba);
	if (it != written.end()) { std::memcpy(out, it->second.data(), 512); return; }
	if (disk_f) {
		std::fseek(disk_f, (long)lba * 512, SEEK_SET);
		if (std::fread(out, 1, 512, disk_f) != 512) std::memset(out, 0, 512);
		return;
	}
	for (int k = 0; k < 512; k++) out[k] = disk_byte(lba, k);
}

// ---- hps_io's block side, in clk_h ------------------------------------------------------------
struct Host {
	int st = 0, slot = 0, k = 0, sub = 0;
	bool we = false;
	uint32_t lba = 0, wait = 0;
	uint8_t buf[512];
	unsigned mounted = 0, ack = 0, addr = 0, dout = 0;
	bool wr = false;
	uint64_t clocks = 0;
	int reads = 0, writes = 0;
} host;

void host_edge() {
	host.clocks++;
	host.mounted = 0;
	host.wr = false;
	if (host.clocks == 20) host.mounted = 1;            // disk 0 mounted (ID 0)
	switch (host.st) {
		case 0:
			if ((dut->sd_rd | dut->sd_wr) & 3) {
				host.slot = ((dut->sd_rd | dut->sd_wr) & 1) ? 0 : 1;
				host.we = (dut->sd_wr >> host.slot) & 1;
				host.lba = dut->sd_lba;
				host.wait = 300 + (host.lba % 7) * 50;  // the ARM's file read, some hundreds of clocks
				host.st = 1;
			}
			break;
		case 1:
			if (host.wait) { host.wait--; break; }
			host.ack = 1u << host.slot;
			host.k = 0; host.sub = 0;
			if (!host.we) disk_read(host.lba, host.buf);
			host.st = 2;
			break;
		case 2:
			if (!host.we) {
				if (host.sub == 0) { host.addr = host.k; host.dout = host.buf[host.k]; host.wr = true; host.sub = 1; }
				else { host.sub = 0; if (++host.k == 512) host.st = 3; }
			} else {
				if (host.sub == 0) { host.addr = host.k; host.sub = 1; }
				else if (host.sub == 1) host.sub = 2;
				else { host.buf[host.k] = (uint8_t)dut->sd_buff_din; host.sub = 0; if (++host.k == 512) host.st = 3; }
			}
			break;
		default:
			if (host.we) { written[host.lba] = std::vector<uint8_t>(host.buf, host.buf + 512); host.writes++; }
			else host.reads++;
			if (verbose) std::printf("  hps: %s block %u\n", host.we ? "wrote" : "read", host.lba);
			host.ack = 0;
			host.st = 0;
			break;
	}
}

// ---- memory on the DMA port, in clk: 1 MB, big-endian -------------------------------------------
std::vector<uint8_t> mem(1u << 20, 0);
int mem_wait = 0;
bool mem_ack = false;
uint32_t mem_rd[8];
int dma_lines = 0, dma_words = 0;

void mem_edge() {
	if (mem_ack) { mem_ack = false; return; }
	if (!dut->dm_req) { mem_wait = 0; return; }
	if (++mem_wait < 4) return;
	mem_wait = 0;
	uint32_t a = ((uint32_t)dut->dm_addr << 2) & (mem.size() - 1);
	if (dut->dm_line) {
		uint32_t base = a & ~31u;
		dma_lines++;
		for (int k = 0; k < 8; k++) {
			uint32_t o = base + 4 * k;
			if (dut->dm_we) {
				uint32_t w = dut->dm_wdata[7 - k];
				for (int i = 0; i < 4; i++) mem[o + i] = (uint8_t)(w >> (24 - 8 * i));
			}
			mem_rd[7 - k] = (uint32_t)mem[o] << 24 | (uint32_t)mem[o + 1] << 16 | (uint32_t)mem[o + 2] << 8 | mem[o + 3];
		}
	} else {
		dma_words++;
		uint32_t o = a & ~3u;
		if (dut->dm_we) {
			uint32_t w = dut->dm_wdata[0];
			for (int i = 0; i < 4; i++)
				if (dut->dm_be & (8u >> i)) mem[o + i] = (uint8_t)(w >> (24 - 8 * i));
		}
		for (int k = 0; k < 8; k++) mem_rd[k] = 0;
		mem_rd[0] = (uint32_t)mem[o] << 24 | (uint32_t)mem[o + 1] << 16 | (uint32_t)mem[o + 2] << 8 | mem[o + 3];
	}
	mem_ack = true;
}

// ---- the two clocks ---------------------------------------------------------------------------
const double PA = 1e6 / 65.0 / 2, PB = 1e6 / 100.0 / 2;   // half periods, ps
double ta = PA, tb = PB;

void drive() {
	dut->dm_ack = mem_ack;
	for (int k = 0; k < 8; k++) dut->dm_rdata[k] = mem_rd[k];
	dut->img_mounted = host.mounted;
	dut->img_size = (uint64_t)BLOCKS * 512;
	dut->sd_ack = host.ack;
	dut->sd_buff_addr = host.addr;
	dut->sd_buff_dout = host.dout;
	dut->sd_buff_wr = host.wr;
}

// one cycle of the CPU's clock
void tick() {
	for (;;) {
		bool a = ta <= tb;
		if (a) ta += PA; else tb += PB;
		drive();
		if (a) {
			dut->clk = !dut->clk;
			dut->eval();
			if (dut->clk) { mem_edge(); break; }
		} else {
			dut->clk_h = !dut->clk_h;
			dut->eval();
			if (dut->clk_h) host_edge();
		}
	}
	cycles++;
}

void run(int n) { while (n-- > 0) tick(); }

// ---- Grand Central's registers, as the CPU reaches them -------------------------------------------
uint32_t access(uint32_t off, unsigned size, bool we, uint32_t v) {
	unsigned lane = off & 3;
	dut->sel = 1;
	dut->we = we;
	dut->addr = off >> 2;
	dut->be = (size == 4 ? 0xF : size == 2 ? 0x3 : 0x1) << (4 - lane - size);
	dut->wdata = size == 4 ? v : (v << (8 * (4 - lane - size)));
	tick();
	dut->sel = 0;
	dut->we = 0;
	tick();
	uint32_t r = dut->rdata;
	run(2);
	if (size == 4) return r;
	return (r >> (8 * (4 - lane - size))) & (size == 2 ? 0xFFFF : 0xFF);
}
const uint32_t MESH = 0x18000, DMA_A = 0x08A00;
void mw(int reg, uint8_t v) { access(MESH + 16 * reg, 1, true, v); }
uint8_t mr(int reg) { return (uint8_t)access(MESH + 16 * reg, 1, false, 0); }
void dw(int reg, uint32_t le) {                         // a DMA register, little-endian value
	uint32_t be = (le >> 24) | ((le >> 8) & 0xFF00) | ((le << 8) & 0xFF0000) | (le << 24);
	access(DMA_A + 4 * reg, 4, true, be);
}
uint32_t dr(int reg) {
	uint32_t be = access(DMA_A + 4 * reg, 4, false, 0);
	return (be >> 24) | ((be >> 8) & 0xFF00) | ((be << 8) & 0xFF0000) | (be << 24);
}

void check(bool ok, const char* what, ...) {
	if (ok) return;
	fails++;
	va_list ap;
	va_start(ap, what);
	std::printf("FAIL: ");
	std::vprintf(what, ap);
	std::printf(" (cycle %llu)\n", (unsigned long long)cycles);
	va_end(ap);
}

// the interrupt register until a bit in mask, as the drivers poll it
uint8_t wait_int(uint8_t mask, const char* what, int limit = 100000) {
	for (int i = 0; i < limit; i++) {
		uint8_t s = mr(0xA);
		if (s & mask) return s;
		run(20);
	}
	check(false, "no interrupt for %s", what);
	return 0;
}

// MESH's command, waited for: command done expected (or the exception)
uint8_t command(uint8_t seq, const char* what) {
	mw(3, seq);
	uint8_t s = wait_int(0x07, what);
	mw(0xA, s);                                         // cleared, as the drivers do
	return s;
}

void arbitrate_select(int id, bool atn) {
	uint8_t s = command(0x01, "arbitrate");
	check(s == 0x01 && mr(7) == 0, "arbitrate: interrupt %02X, exception %02X", s, mr(7));
	mw(0xC, id);
	mw(0xF, 0x19);
	mw(3, 0x0D);
	mw(3, 0x0F);
	s = command(atn ? 0x22 : 0x02, "select");
	check(s == 0x01 && mr(7) == 0, "select ID %d: interrupt %02X, exception %02X", id, s, mr(7));
}

void send_cdb(const std::vector<uint8_t>& cdb) {
	mw(1, 0); mw(0, (uint8_t)cdb.size());
	mw(3, 0x03);
	for (uint8_t b : cdb) mw(2, b);
	uint8_t s = wait_int(0x07, "command");
	mw(0xA, s);
	check(s == 0x01, "command %02X: interrupt %02X", cdb[0], s);
}

// the drivers' bus free after the command: a phase mismatch once the target asks for the next phase
uint8_t wait_phase() {
	mw(0xA, 0x07);
	uint8_t s = command(0x09, "bus free (the next phase)");
	check(s == 0x02 && (mr(7) & 2), "bus free after the command: interrupt %02X, exception %02X", s, mr(7));
	return mr(4) & 7;
}

// programmed I/O data in: n bytes, 16 at a time when the FIFO has them (the ROM's loop, FFEB9C7C)
void pio_in(uint8_t* out, int n) {
	mw(1, (uint8_t)(n >> 8)); mw(0, (uint8_t)n);
	mw(3, 0x06);
	int got = 0;
	for (int guard = 0; got < n && guard < 1000000; guard++) {
		mr(0xA);
		int c = mr(6);
		int want = std::min(16, n - got);
		if (c >= want) for (int i = 0; i < want; i++) out[got++] = mr(2);
		else run(10);
	}
	check(got == n, "programmed I/O: %d bytes of %d", got, n);
	uint8_t s = wait_int(0x07, "data in done");
	mw(0xA, s);
	check(s == 0x01, "data in: interrupt %02X", s);
}

void finish(uint8_t want_status) {
	mw(1, 0); mw(0, 1);
	uint8_t s = command(0x04, "status");
	check(s == 0x01, "status: interrupt %02X", s);
	uint8_t st = mr(2);
	check(st == want_status, "status byte %02X, %02X expected", st, want_status);
	// the SIM waits here until REQ is down (FFEB8D98) before it asks for the message
	check((mr(4) & 0x20) == 0, "after the status byte, REQ is still up (bus status 0 %02X)", mr(4));
	mw(1, 0); mw(0, 1);
	s = command(0x08, "message in");
	uint8_t msg = mr(2);
	check(s == 0x01 && msg == 0x00, "message in: interrupt %02X, message %02X", s, msg);
	check((mr(4) & 0x17) == 0x17, "after message in, bus status 0 %02X (ACK and MESSAGE IN expected)", mr(4));
	s = command(0x09, "bus free");
	check(s == 0x01, "bus free: interrupt %02X", s);
	check(mr(4) == 0 && mr(5) == 0, "after bus free, bus status %02X %02X", mr(4), mr(5));
	mw(3, 0x0F);
	mw(3, 0x0C);
}

void compare_block(const uint8_t* got, uint32_t lba, int from, int n, const char* what) {
	uint8_t want[512];
	disk_read(lba, want);
	for (int k = 0; k < n; k++)
		if (got[k] != want[from + k]) {
			check(false, "%s: block %u byte %d read %02X, the image has %02X", what, lba, from + k, got[k], want[from + k]);
			return;
		}
}

// a DBDMA command in memory (little-endian)
void put_cmd(uint32_t at, uint8_t cmd, uint8_t bits, uint16_t req, uint32_t addr, uint32_t arg = 0) {
	mem[at] = req & 0xFF; mem[at + 1] = req >> 8; mem[at + 2] = bits; mem[at + 3] = cmd << 4;
	for (int i = 0; i < 4; i++) { mem[at + 4 + i] = (addr >> (8 * i)) & 0xFF; mem[at + 8 + i] = (arg >> (8 * i)) & 0xFF; }
	for (int i = 12; i < 16; i++) mem[at + i] = 0;
}
uint16_t res_count(uint32_t at) { return mem[at + 12] | mem[at + 13] << 8; }
uint16_t xfer_stat(uint32_t at) { return mem[at + 14] | mem[at + 15] << 8; }

} // namespace

int main(int argc, char** argv) {
	std::setvbuf(stdout, nullptr, _IOLBF, 0);
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--verbose") verbose = true;
		else if (a == "--disk" && i + 1 < argc) disk_f = std::fopen(argv[++i], "rb");
	}
	auto ctx = std::make_unique<VerilatedContext>();
	dut = std::make_unique<Vscsi_tb_top>(ctx.get());
	dut->reset = 1;
	run(50);
	dut->reset = 0;
	run(200);

	// MESH as the ROM sets it up (dingusppc's log, 86.1 million)
	mw(9, 0x00);
	mw(5, 0x80); run(1000); mw(5, 0x00);                // bus reset
	command(0x0E, "reset MESH");
	mw(0xA, 0x07); mw(0xD, 0x02); mw(0xB, 0x07); mw(9, 0x07);
	uint8_t buf[19 * 512];

	// ---- 1: the ROM's READ(6) of block 0 ----
	std::printf("1. READ(6) of block 0 by programmed I/O, as the ROM\n");
	arbitrate_select(0, false);
	send_cdb({0x08, 0x00, 0x00, 0x00, 0x01, 0x00});
	uint8_t ph = wait_phase();
	check(ph == 1, "phase after the command %d, DATA IN expected", ph);
	pio_in(buf, 512);
	compare_block(buf, 0, 0, 512, "READ(6) of block 0");
	finish(0x00);

	// ---- 2: 19 blocks from block 64 ----
	std::printf("2. READ(6) of 19 blocks from block 64 by programmed I/O\n");
	arbitrate_select(0, false);
	send_cdb({0x08, 0x00, 0x00, 0x40, 0x13, 0x00});
	wait_phase();
	for (int b = 0; b < 19; b++) pio_in(buf + 512 * b, 512);
	for (int b = 0; b < 19; b++) compare_block(buf + 512 * b, 64 + b, 0, 512, "READ(6) of 19 blocks");
	finish(0x00);

	// ---- 3: Mac OS's READ(10): 6 bytes PIO, 504 by DMA, 2 PIO ----
	std::printf("3. READ(10) of block 2: 6 bytes by programmed I/O, 504 by DMA, 2 by programmed I/O\n");
	arbitrate_select(0, true);
	mw(1, 0); mw(0, 1);
	mw(3, 0x07); mw(2, 0xC0);                           // IDENTIFY, disconnect allowed
	{ uint8_t s = wait_int(0x07, "message out"); mw(0xA, s); check(s == 0x01, "message out: interrupt %02X", s); }
	send_cdb({0x28, 0, 0, 0, 0, 2, 0, 0, 1, 0});
	wait_phase();
	pio_in(buf, 6);
	std::memset(&mem[0x10000], 0xEE, 0x400);
	put_cmd(0x300, 3, 0x00, 512, 0x10006);              // INPUT_LAST, 512: longer than MESH's count
	put_cmd(0x310, 7, 0x00, 0, 0);
	mw(0, 0xF8); mw(1, 0x01);
	mw(3, 0x86);
	dw(0, 0x00800000); dw(3, 0x300); dw(0, 0x80008000);   // (the driver: control 000000C8 first, then the pointer, then RUN)
	{
		uint8_t s = wait_int(0x07, "DMA data in");
		mw(0xA, s);
		check(s == 0x01, "DMA data in: interrupt %02X", s);
		dw(0, 0x20002000);                              // FLUSH
		uint32_t st = dr(1);
		check(st == 0x8400, "DMA status after the flush %04X, 8400 expected", st);
		dw(0, 0x80000000);                              // RUN off
		check(dr(1) == 0, "DMA status after stopping %04X", dr(1));
		check(mr(0) == 0 && mr(1) == 0, "MESH's count after DMA %02X%02X", mr(1), mr(0));
	}
	compare_block(&mem[0x10006], 2, 6, 504, "DMA data in");
	check(mem[0x10005] == 0xEE && mem[0x10006 + 504] == 0xEE, "DMA wrote outside its bytes (%02X %02X)",
		mem[0x10005], mem[0x10006 + 504]);
	check(res_count(0x300) == 8, "resCount after the flush %u, 8 expected", res_count(0x300));
	pio_in(buf + 6, 2);
	compare_block(buf, 2, 0, 6, "programmed I/O head");
	compare_block(buf + 6, 2, 510, 2, "programmed I/O tail");
	finish(0x00);

	// ---- 4: READ(10) of 3 blocks by DMA, two commands ----
	std::printf("4. READ(10) of 3 blocks from block 1000 by DMA, two commands and a STOP\n");
	arbitrate_select(0, true);
	mw(1, 0); mw(0, 1); mw(3, 0x07); mw(2, 0xC0);
	{ uint8_t s = wait_int(0x07, "message out"); mw(0xA, s); }
	send_cdb({0x28, 0, 0, 0, 0x03, 0xE8, 0, 0, 3, 0});
	wait_phase();
	put_cmd(0x400, 2, 0x00, 1000, 0x20000);             // INPUT_MORE 1000
	put_cmd(0x410, 3, 0x30, 536, 0x20000 + 1000);       // INPUT_LAST 536, interrupt always
	put_cmd(0x420, 7, 0x00, 0, 0);
	mw(0, 0x00); mw(1, 0x06);
	mw(3, 0x86);
	dw(3, 0x400); dw(0, 0x80008000);
	{
		uint8_t s = wait_int(0x07, "DMA data in, 3 blocks");
		mw(0xA, s);
		check(s == 0x01, "DMA data in (3 blocks): interrupt %02X", s);
		run(200);
		check(dr(1) == 0x8000, "DMA status after the STOP %04X, 8000 expected", dr(1));
		check(res_count(0x400) == 0 && res_count(0x410) == 0, "resCounts %u %u", res_count(0x400), res_count(0x410));
		check(xfer_stat(0x410) == 0x8400, "xferStatus %04X", xfer_stat(0x410));
		// the channel's interrupt: Grand Central's level for source 0A (the
		// levels register, little-endian inside), until the clear register drops it
		check((access(0x2C, 4, false, 0) & 0x00040000) != 0, "Grand Central: no level for DMA channel A");
		access(0x28, 4, true, 0x00040000);
		run(4);
		check((access(0x2C, 4, false, 0) & 0x00040000) == 0, "Grand Central: DMA channel A's level not cleared");
		dw(0, 0x80000000);
	}
	for (int b = 0; b < 3; b++) compare_block(&mem[0x20000 + 512 * b], 1000 + b, 0, 512, "DMA, 3 blocks");
	finish(0x00);

	// ---- 5: WRITE(10) of 2 blocks by DMA out, read back ----
	std::printf("5. WRITE(10) of 2 blocks at block 50 by DMA out, then READ(10) of them by DMA\n");
	for (int k = 0; k < 1024; k++) mem[0x30000 + k] = (uint8_t)(k * 3 + 0x55);
	arbitrate_select(0, true);
	mw(1, 0); mw(0, 1); mw(3, 0x07); mw(2, 0xC0);
	{ uint8_t s = wait_int(0x07, "message out"); mw(0xA, s); }
	send_cdb({0x2A, 0, 0, 0, 0, 50, 0, 0, 2, 0});
	{
		uint8_t p = wait_phase();
		check(p == 0, "phase after WRITE's command %d, DATA OUT expected", p);
	}
	put_cmd(0x500, 1, 0x00, 1024, 0x30000);             // OUTPUT_LAST
	put_cmd(0x510, 7, 0x00, 0, 0);
	mw(0, 0x00); mw(1, 0x04);
	mw(3, 0x85);
	dw(3, 0x500); dw(0, 0x80008000);
	{
		uint8_t s = wait_int(0x07, "DMA data out");
		mw(0xA, s);
		check(s == 0x01, "DMA data out: interrupt %02X", s);
		dw(0, 0x80000000);
	}
	finish(0x00);
	check(written.count(50) && written.count(51), "the card got no blocks 50 and 51");
	if (written.count(50) && written.count(51))
		for (int k = 0; k < 1024; k++)
			if (written[50 + k / 512][k % 512] != (uint8_t)(k * 3 + 0x55)) {
				check(false, "WRITE: byte %d of the blocks written is %02X", k, written[50 + k / 512][k % 512]);
				break;
			}
	arbitrate_select(0, true);
	mw(1, 0); mw(0, 1); mw(3, 0x07); mw(2, 0xC0);
	{ uint8_t s = wait_int(0x07, "message out"); mw(0xA, s); }
	send_cdb({0x28, 0, 0, 0, 0, 50, 0, 0, 2, 0});
	wait_phase();
	put_cmd(0x600, 3, 0x00, 1024, 0x40000);
	put_cmd(0x610, 7, 0x00, 0, 0);
	mw(0, 0x00); mw(1, 0x04);
	mw(3, 0x86);
	dw(3, 0x600); dw(0, 0x80008000);
	{ uint8_t s = wait_int(0x07, "DMA read back"); mw(0xA, s); dw(0, 0x80000000); }
	check(std::memcmp(&mem[0x40000], &mem[0x30000], 1024) == 0, "the blocks read back differ from those written");
	finish(0x00);

	// ---- 6: INQUIRY, READ CAPACITY, an absent ID ----
	std::printf("6. INQUIRY, READ CAPACITY, a selection of ID 3 (nothing there)\n");
	arbitrate_select(0, false);
	send_cdb({0x12, 0, 0, 0, 36, 0});
	wait_phase();
	pio_in(buf, 36);
	check(std::memcmp(buf + 8, "QUANTUM MiSTer PPCMac HD1.0 ", 28) == 0 && buf[0] == 0 && buf[2] == 2,
		"INQUIRY data: %.28s", (const char*)buf + 8);
	finish(0x00);
	arbitrate_select(0, false);
	send_cdb({0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0});
	wait_phase();
	pio_in(buf, 8);
	check(buf[0] == 0 && buf[1] == 0 && buf[2] == ((BLOCKS - 1) >> 8) && buf[3] == ((BLOCKS - 1) & 0xFF) && buf[6] == 2,
		"READ CAPACITY: %02X%02X%02X%02X %02X%02X%02X%02X", buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
	finish(0x00);
	{
		uint8_t s = command(0x01, "arbitrate");
		mw(0xC, 3);
		mw(0xF, 0x01);                                  // 10 ms
		s = command(0x02, "select ID 3");
		check(s == 0x03 && (mr(7) & 1), "select of an absent ID: interrupt %02X, exception %02X", s, mr(7));
	}

	std::printf("%llu cycles; DMA: %d lines, %d words; the card: %d blocks read, %d written\n",
		(unsigned long long)cycles, dma_lines, dma_words, host.reads, host.writes);
	std::printf("%s\n", fails ? "FAIL" : "PASS");
	dut->final();
	dut.reset();                                        // before its context goes
	return fails ? 1 : 0;
}
