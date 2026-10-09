// PPCMac: the whole machine (PPCMac_system) in a window, to watch it run.
//
// The same framework as the other cores' Verilator setups (ImGui + SDL2 +
// OpenGL: sim/sim_video, sim/sim_console, sim/imgui, the template's files
// as they are): a Control window (run, reset, the frame counter with the
// machine's frames a second, the speed: simulated MHz, instructions a
// second, the share of real time), a Machine window (pc, MSR, instructions,
// cycles), the Video window (the Control video's picture, zoom), the Debug
// log (notes, and what the machine sends on the modem port, Open
// Firmware's console), and a line to type at the modem port.
//
// The machine is built as machine_tb builds it (CUDA_FAST_BOOT), with the
// same stand-ins: a memory in its own clock for the SDRAM, a 4 MB DDR3 for
// the VRAM, the NVRAM image loaded during reset. No lockstep: this is for
// watching; machine_tb (run_machine.py) is the bench that checks.
//
//   ppcmac_gui --rom FILE [--nvram FILE] [--ram MB] [--monitor 16|13]
//              [--cpu-mhz F] [--mem-mhz F] [--pause]
//
// Built by `make gui` (verilator/Makefile); run_gui.py builds and starts it
// (under WSL, the window through WSLg).

#include <verilated.h>
#include "VPPCMac_system.h"

#include "imgui.h"
#include "imgui_impl_sdl.h"
#include "imgui_impl_opengl2.h"
#include "sim_video.h"
#include "sim_console.h"
#include <SDL.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

extern SDL_Window* window;                 // sim_video.cpp

namespace {

using Top = VPPCMac_system;

const uint32_t SDRAM_SIZE = 128u << 20;
const uint32_t ROM_SDRAM  = SDRAM_SIZE - (4u << 20);
const uint32_t ROM_SIZE   = 4u << 20;

struct Options {
	std::string rom, nvram;
	unsigned ram_mb = 16;
	unsigned monitor = 16;
	double cpu_mhz = 70.0, mem_mhz = 100.0;
	bool pause = false;
};

uint32_t rd32(const std::vector<uint8_t>& m, uint32_t a) {
	a &= SDRAM_SIZE - 1;
	a &= ~3u;
	return (uint32_t)m[a] << 24 | (uint32_t)m[a + 1] << 16 | (uint32_t)m[a + 2] << 8 | m[a + 3];
}

void wr32(std::vector<uint8_t>& m, uint32_t a, uint32_t v, uint32_t be) {
	a &= SDRAM_SIZE - 1;
	a &= ~3u;
	if (be & 8) m[a] = v >> 24;
	if (be & 4) m[a + 1] = v >> 16;
	if (be & 2) m[a + 2] = v >> 8;
	if (be & 1) m[a + 3] = v;
}

// the SDRAM's stand-in: a request is answered a memory clock later
struct Mem {
	bool pending = false, ack = false;
	uint32_t rdata[8] = {0};
};

// the VRAM's DDR3 (the framework's DDRAM port): 4 MB, reads after a few clocks
struct Ddr {
	static const uint32_t BASE = 0x06000000;          // 64-bit words: byte 3000_0000
	static const uint32_t WORDS = (4u << 20) / 8;
	std::vector<uint64_t> m = std::vector<uint64_t>(WORDS, 0);
	struct Rd { uint32_t addr; unsigned left; int wait; };
	std::deque<Rd> rq;
	uint32_t wr_addr = 0;
	unsigned wr_left = 0;
	bool ready = false;
	uint64_t dout = 0;
};

// the modem port: what the machine sends, decoded; what is typed, sent
struct Modem {
	double bit = 0;                     // CPU clocks per bit
	bool rx_busy = false;
	double rx_t = 0;
	int rx_bitn = 0;
	unsigned rx_sh = 0;
	std::string line;
	bool in_esc = false;
	std::deque<uint8_t> out;
	bool tx_busy = false;
	double tx_t = 0;
	unsigned tx_frame = 0;
	uint64_t gap = 0, gap_left = 0;     // clocks between typed characters (Open Firmware echoes each)
	bool txd = true;
	DebugConsole* con = nullptr;

	void clock(bool rxd) {
		if (!rx_busy) {
			if (!rxd) { rx_busy = true; rx_t = 0; rx_bitn = 0; rx_sh = 0; }
		} else {
			rx_t += 1;
			if (rx_bitn < 8 && rx_t >= (rx_bitn + 1.5) * bit) {
				rx_sh |= (unsigned)rxd << rx_bitn;
				rx_bitn++;
			}
			else if (rx_bitn == 8 && rx_t >= 9.5 * bit) {
				rx_busy = false;
				char c = (char)(rx_sh & 0x7F);
				if (in_esc) in_esc = !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '@');
				else if (c == 0x1B) in_esc = true;
				else if (c == '\n') { con->AddLog("modem: %s", line.c_str()); line.clear(); }
				else if (c >= 0x20 && c < 0x7F) line += c;
			}
		}
		if (gap_left) gap_left--;
		if (!tx_busy && !out.empty() && !gap_left) {
			tx_frame = 0x600u | ((unsigned)out.front() << 1);   // start, 8 bits, 2 stop bits
			out.pop_front();
			tx_busy = true;
			tx_t = 0;
		}
		if (tx_busy) {
			int k = (int)(tx_t / bit);
			if (k >= 11) { tx_busy = false; txd = true; gap_left = gap; }
			else txd = (tx_frame >> k) & 1;
			tx_t += 1;
		}
	}
};

}  // namespace

int main(int argc, char** argv) {
	Options opt;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
		if (a == "--rom") opt.rom = next();
		else if (a == "--nvram") opt.nvram = next();
		else if (a == "--ram") opt.ram_mb = (unsigned)std::atoi(next().c_str());
		else if (a == "--monitor") opt.monitor = (unsigned)std::atoi(next().c_str());
		else if (a == "--cpu-mhz") opt.cpu_mhz = std::atof(next().c_str());
		else if (a == "--mem-mhz") opt.mem_mhz = std::atof(next().c_str());
		else if (a == "--pause") opt.pause = true;
		else {
			std::printf("usage: ppcmac_gui --rom FILE [--nvram FILE] [--ram MB] [--monitor 16|13]\n"
			            "                  [--cpu-mhz F] [--mem-mhz F] [--pause]\n");
			return a == "--help" ? 0 : 2;
		}
	}
	if (opt.rom.empty()) { std::fprintf(stderr, "--rom is needed\n"); return 2; }

	std::vector<uint8_t> mem(SDRAM_SIZE, 0);
	{
		std::ifstream fh(opt.rom, std::ios::binary);
		if (!fh) { std::fprintf(stderr, "cannot open %s\n", opt.rom.c_str()); return 2; }
		fh.read(reinterpret_cast<char*>(mem.data() + ROM_SDRAM), ROM_SIZE);
		if (fh.gcount() != (std::streamsize)ROM_SIZE) { std::fprintf(stderr, "%s is not a 4 MB ROM\n", opt.rom.c_str()); return 2; }
	}
	std::vector<uint8_t> nvimg;
	if (!opt.nvram.empty()) {
		std::ifstream fh(opt.nvram, std::ios::binary);
		nvimg.resize(8192);
		if (fh) fh.read(reinterpret_cast<char*>(nvimg.data()), 8192);
		if (!fh || fh.gcount() != 8192) { std::fprintf(stderr, "%s is not an 8 KB NVRAM image\n", opt.nvram.c_str()); return 2; }
	}

	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto dut = std::make_unique<Top>(ctx.get());

	int vw = opt.monitor == 13 ? 640 : 832, vh = opt.monitor == 13 ? 480 : 624;
	SimVideo video(vw, vh, 0);
	DebugConsole console;
	if (video.Initialise("PPCMac") == 1) return 1;
	SDL_SetWindowTitle(window, "PPCMac (Verilator)");
	SDL_SetWindowSize(window, 1440, 900);

	Mem mm;
	Ddr ddr;
	Modem modem;
	modem.bit = opt.cpu_mhz * 1e6 / 38400.0;
	modem.gap = (uint64_t)(opt.cpu_mhz * 1e6 * 0.004);   // 4 ms between typed characters
	modem.con = &console;

	uint64_t cycles = 0, retired = 0, dev_writes = 0;
	uint32_t last_pc = 0, last_msr = 0;
	// the machine's frames: counted at the start of each vertical sync, and
	// the CPU cycles between the last two (its refresh rate)
	uint64_t frames = 0, vs_cycle = 0, frame_cycles = 0;
	bool vs_q = false;
	// the monitor's refresh rate until the machine has scanned out two frames:
	// the 16-inch's 832 x 624 at 74.55 Hz, the 13-inch's 640 x 480 at 66.67
	const double nominal_hz = opt.monitor == 13 ? 66.67 : 74.55;
	// the speed, measured every half second
	auto t_last = std::chrono::steady_clock::now();
	uint64_t c_last = 0, r_last = 0;
	double sim_mhz = 0, ips = 0;
	bool cpu_held = true;
	int nv_ld = -1;
	const double pa = 1e6 / opt.cpu_mhz / 2, pb = 1e6 / opt.mem_mhz / 2;   // half periods, ps
	double ta = pa, tb = pb;

	auto drive = [&]() {
		dut->ram_mb = opt.ram_mb;
		dut->boot_memtest = 0;
		dut->l2_on = 1;
		dut->reset_pc = 0xFFF00100;
		dut->modem_rxd = modem.txd;
		dut->nv_ld_we = nv_ld >= 0;
		dut->nv_ld_re = 0;
		dut->nv_ld_addr = nv_ld >= 0 ? nv_ld : 0;
		dut->nv_ld_data = nv_ld >= 0 ? nvimg[nv_ld] : 0;
		dut->b_ack = mm.ack;
		for (int i = 0; i < 8; i++) dut->b_rdata[i] = mm.rdata[i];
		dut->mon_std = opt.monitor == 13 ? 6 : 7;
		dut->mon_ext = opt.monitor == 13 ? 0x2B : 0x2D;
		dut->ddr_busy = 0;
		dut->ddr_dout_ready = ddr.ready;
		dut->ddr_dout = ddr.dout;
	};

	auto mem_edge = [&]() {
		if (mm.ack) { mm.ack = false; mm.pending = false; return; }
		if (dut->b_req && !mm.pending) {
			bool we = dut->b_we, line = dut->b_line;
			uint32_t addr = ((uint32_t)dut->b_addr << 2) & (SDRAM_SIZE - 1), be = dut->b_be;
			if (line) {
				uint32_t base = addr & ~31u;
				for (int k = 0; k < 8; k++) {
					if (we && base < ROM_SDRAM) wr32(mem, base + 4 * k, dut->b_wdata[7 - k], 0xF);
					mm.rdata[7 - k] = rd32(mem, base + 4 * k);
				}
			} else {
				if (we && addr < ROM_SDRAM) wr32(mem, addr, dut->b_wdata[0], be);
				mm.rdata[0] = rd32(mem, addr);
			}
			mm.pending = true;
			mm.ack = true;
		}
	};

	auto ddr_edge = [&]() {
		ddr.ready = false;
		if (!ddr.rq.empty()) {
			Ddr::Rd& r = ddr.rq.front();
			if (r.wait > 0) r.wait--;
			else {
				ddr.dout = ddr.m[(r.addr - Ddr::BASE) % Ddr::WORDS];
				ddr.ready = true;
				r.addr++;
				if (--r.left == 0) ddr.rq.pop_front();
			}
		}
		unsigned cnt = dut->ddr_burstcnt;
		if (dut->ddr_rd) ddr.rq.push_back({(uint32_t)dut->ddr_addr, cnt ? cnt : 1, 4});
		if (dut->ddr_we) {
			if (ddr.wr_left == 0) { ddr.wr_addr = dut->ddr_addr; ddr.wr_left = cnt ? cnt : 1; }
			uint64_t& w = ddr.m[(ddr.wr_addr - Ddr::BASE) % Ddr::WORDS];
			uint64_t din = dut->ddr_din;
			unsigned be = dut->ddr_be;
			for (int k = 0; k < 8; k++)
				if (be & (1u << k)) w = (w & ~(0xFFull << (8 * k))) | (din & (0xFFull << (8 * k)));
			ddr.wr_addr++;
			ddr.wr_left--;
		}
	};

	// one cycle of the CPU's clock, with the memory's (and video's) edges between
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
				if (dut->clk_b) {
					mem_edge();
					ddr_edge();
					if (dut->vid_ce) {
						bool vs = dut->vid_vs;
						if (vs && !vs_q) {
							if (frames) frame_cycles = cycles - vs_cycle;
							vs_cycle = cycles;
							frames++;
						}
						vs_q = vs;
						video.Clock(dut->vid_hblank, dut->vid_vblank, dut->vid_hs, dut->vid_vs,
						            0xFF000000u | (uint32_t)dut->vid_b << 16 | (uint32_t)dut->vid_g << 8 | dut->vid_r);
					}
				}
			}
		}
		cycles++;
		if (dut->trace_valid && dut->trace_last) {
			retired++;
			last_pc = dut->trace_pc;
			last_msr = dut->trace_msr;
		}
		if (dut->cpu_req && dut->cpu_ack && dut->cpu_we && ((uint32_t)dut->cpu_addr << 2) >= 0xF0000000u)
			dev_writes++;
		if (cpu_held && !dut->cpu_in_reset) {
			cpu_held = false;
			console.AddLog("Cuda released the CPU's reset after %llu cycles", (unsigned long long)cycles);
		}
		modem.clock(dut->modem_txd);
	};

	auto reset_machine = [&]() {
		dut->clk = 0; dut->clk_b = 0;
		dut->reset = 1; dut->reset_b = 1;
		for (int i = 0; i < 4; i++) tick();
		if (!nvimg.empty()) {
			for (nv_ld = 0; nv_ld < 8192; nv_ld++) tick();
			nv_ld = -1;
			tick();
		}
		dut->reset = 0; dut->reset_b = 0;
		mm = Mem();
		cycles = retired = dev_writes = 0;
		frames = vs_cycle = frame_cycles = 0;
		vs_q = false;
		c_last = r_last = 0;
		t_last = std::chrono::steady_clock::now();
		cpu_held = true;
		console.AddLog("machine reset (%s, %u MB, %s monitor%s)", opt.rom.c_str(), opt.ram_mb,
		               opt.monitor == 13 ? "13-inch" : "16-inch", nvimg.empty() ? "" : ", NVRAM image");
	};
	reset_machine();

	bool run = !opt.pause;
	int frame_ms = 40;                  // simulation time per GUI frame, wall-clock milliseconds
	float zoom = 1.0f;
	bool show_log = true;
	char modem_line[256] = "";

	bool done = false;
	while (!done) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT) done = true;
		}
		video.StartFrame();
		ImGui::NewFrame();

		auto now = std::chrono::steady_clock::now();
		double dt = std::chrono::duration<double>(now - t_last).count();
		if (dt >= 0.5) {
			sim_mhz = (cycles - c_last) / dt / 1e6;
			ips = (retired - r_last) / dt;
			c_last = cycles; r_last = retired; t_last = now;
		}

		ImGui::Begin("Control");
		ImGui::SetWindowPos("Control", ImVec2(0, 0), ImGuiCond_Once);
		ImGui::SetWindowSize("Control", ImVec2(520, 200), ImGuiCond_Once);
		ImGui::Checkbox("RUN", &run);
		ImGui::SameLine();
		if (ImGui::Button("Reset machine")) reset_machine();
		ImGui::SameLine();
		if (ImGui::Button("Step 1000 cycles")) for (int i = 0; i < 1000; i++) tick();
		ImGui::SliderInt("ms per GUI frame", &frame_ms, 5, 200);
		ImGui::Separator();
		// the machine's frames a second: its share of real time times its
		// refresh rate (measured once it scans out, the monitor's before), so
		// the count is steady at well under a frame a second and right while
		// the video is still off
		double hz = frame_cycles ? opt.cpu_mhz * 1e6 / frame_cycles : nominal_hz;
		double fps = sim_mhz / opt.cpu_mhz * hz;
		if (frames)
			ImGui::Text("Frame %06llu  %.2f fps  %dx%d at %.2f Hz", (unsigned long long)frames, fps,
			            video.stats_xMax - video.stats_xMin + 1, video.stats_yMax - video.stats_yMin + 1, hz);
		else {
			ImGui::Text("Frame %06d  %.2f fps  (%.2f Hz)", 0, fps, hz);
			ImGui::TextDisabled("no picture yet: Mac OS turns the video on at about 128 M instructions");
		}
		ImGui::Text("Speed: %.3f MHz simulated (%.2f%% of real time at %.0f MHz)", sim_mhz,
		            100.0 * sim_mhz / opt.cpu_mhz, opt.cpu_mhz);
		ImGui::Text("       %.0f instructions a second", ips);
		ImGui::TextDisabled("window: %.0f redraws a second", ImGui::GetIO().Framerate);
		ImGui::End();

		ImGui::Begin("Machine");
		ImGui::SetWindowPos("Machine", ImVec2(0, 210), ImGuiCond_Once);
		ImGui::SetWindowSize("Machine", ImVec2(520, 170), ImGuiCond_Once);
		ImGui::Text("Power Macintosh 7300 - DSPPC604 @ %.0f MHz, %u MB", opt.cpu_mhz, opt.ram_mb);
		ImGui::Text("%s", cpu_held ? "Cuda holds the CPU in reset (its cold start)" : "the CPU runs");
		ImGui::Text("instructions %llu   cycles %llu", (unsigned long long)retired, (unsigned long long)cycles);
		ImGui::Text("pc %08X   MSR %08X", last_pc, last_msr);
		ImGui::Text("device writes %llu", (unsigned long long)dev_writes);
		if (video.count_frame == 0)
			ImGui::TextDisabled("the video is off until Mac OS's driver starts it (about 128 M instructions)");
		ImGui::End();

		ImGui::Begin("Modem port");
		ImGui::SetWindowPos("Modem port", ImVec2(0, 390), ImGuiCond_Once);
		ImGui::SetWindowSize("Modem port", ImVec2(520, 80), ImGuiCond_Once);
		ImGui::TextDisabled("Open Firmware's console (with an NVRAM image that stops at its prompt)");
		if (ImGui::InputText("type", modem_line, sizeof(modem_line), ImGuiInputTextFlags_EnterReturnsTrue)) {
			for (const char* p = modem_line; *p; p++) modem.out.push_back((uint8_t)*p);
			modem.out.push_back('\r');
			console.AddLog("(typed \"%s\")", modem_line);
			modem_line[0] = 0;
			ImGui::SetKeyboardFocusHere(-1);
		}
		ImGui::End();

		console.Draw("Debug log", &show_log, ImVec2(520, 400));
		ImGui::SetWindowPos("Debug log", ImVec2(0, 480), ImGuiCond_Once);

		ImGui::Begin("Video");
		ImGui::SetWindowPos("Video", ImVec2(530, 0), ImGuiCond_Once);
		ImGui::SetWindowSize("Video", ImVec2(vw * zoom + 24, vh * zoom + 64), ImGuiCond_Once);
		ImGui::SliderFloat("Zoom", &zoom, 0.5f, 2.0f);
		ImGui::Image(video.texture_id, ImVec2(vw * zoom, vh * zoom));
		ImGui::End();

		video.UpdateTexture();

		if (run) {
			auto start = std::chrono::steady_clock::now();
			do {
				for (int i = 0; i < 2000; i++) tick();
			} while (std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count() < frame_ms);
		}
		else SDL_Delay(10);
	}

	video.CleanUp();
	dut->final();
	return 0;
}
