//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The Power Macintosh 7600 (dingusppc's TNT): the address map, the device
//  stubs, the time base
//
//  Sits on the CPU's side of the clock crossing, in the CPU's clock. It takes
//  the CPU's memory port, decodes the address, answers device accesses
//  itself and passes RAM and ROM accesses on, as SDRAM offsets, to
//  DSPPC604_memcdc. The protocol is the CPU's port's on both sides: one
//  request at a time, req held until ack, a 32-byte line or one word with
//  byte enables (the lowest address in bits 255-224 or 31-24).
//
//  The map, from dingusppc's machines/machinetnt.cpp and the devices it
//  builds (file and line for each entry):
//
//    00000000  installed RAM          ram_mb MB in Hammerhead's banks, one a
//                                     bit of ram_mb, where its bank registers
//                                     put them (flat until they are set)
//                                     (machinetnt.cpp:135-143,
//                                     hammerhead.cpp:161-176); SDRAM offset 0
//    F0000000  Chaos, video bus       16 MB: configuration space only
//                                     (bandit.cpp:308-322) -> MacPPC7300_pcicfg
//    F2000000  Bandit 1, PCI          16 MB: configuration space only
//                                     (bandit.cpp:293-306) -> MacPPC7300_pcicfg
//    F3000000  Grand Central          128 KB, where the ROM sets its base
//                                     address register (grandcentral.cpp:52,
//                                     machinetnt.cpp:78-80) -> MacPPC7300_gc
//    F8000000  Hammerhead             1,280 bytes of registers
//                                     (hammerhead.cpp:39) -> below
//    FFC00000  ROM                    4 MB (machinetnt.cpp:131); SDRAM offset
//                                     SDRAM_MB - 4 MB; writes are ignored.
//                                     With boot_memtest, the 8 KB memory-test
//                                     program (MacPPC7300_bootrom) mirrored over
//                                     it instead
//    F9000000  debug registers        not a 7600 device: 256 bytes where the
//                                     memory test reports (see below); no
//                                     7600 ROM touches this address
//    Control's second BAR             its registers, 4 KB (Open Firmware
//                                     puts them at 94000000) -> MacPPC7300_control
//    Control's third BAR              its VRAM window, 64 MB (90000000): not
//                                     a device but memory, through its own
//                                     crossing to the picture side
//                                     (MacPPC7300_video, the VRAM in DDR3)
//
//  Anything else reads as zeros and ignores writes. A device answers at
//  once, but for the VIA, which Grand Central paces to its 783,360 Hz clock:
//  an access waits for the clock's next edge and then half a cycle (MAME's
//  Grand Central, heathrow.cpp via_sync), 0.64-1.91 us. The 7600's ROM
//  counts on it: its Cuda timeouts are counts of VIA reads, and after each
//  byte it waits ten VIA reads for Cuda to take the byte's last bit. RAM
//  space beyond the installed memory reads 0, as measured on the 7300
//  (dingusppc reads all ones there).
//
//  Cuda (MacPPC7300_cuda), the board's microcontroller, sits on the VIA's port
//  B and shift register, and holds the CPU in reset (cpu_reset) until its
//  firmware has powered the machine up, as on the 7600. Athens, the video's
//  clock generator, answers on Cuda's I2C lines (MacPPC7300_athens).
//
//  Grand Central's DMA channels reach memory through one DMA port here
//  (rule 2): each access's line through the CPU's snoop port, then the
//  memory port, which the CPU and the DMA share (below). The internal SCSI
//  bus joins MESH (in Grand Central) and the disks (MacPPC7300_scsidisk, IDs 0
//  and 1, the MiSTer's disk images through hps_io's block devices, whose
//  side runs in clk_v).
//
//  A line request to a device is eight word accesses to it, the lowest
//  address first, as a burst on the real bus would be: with data
//  translation off the 604 treats every address as cacheable, and the ROM
//  reads Hammerhead's CPU ID through the data cache (its fortieth
//  instruction, FFF03108, after enabling the cache at FFF03094).
//
//  Also made here: tb_tick for the CPU's time base and decrementer, at
//  TB_HZ on average from any CPU clock (the 604 counts every fourth bus
//  clock; the 7600's bus is 50 MHz), the VIA's 783,360 Hz clock, the
//  ESCC's RTxC at 3,686,400 Hz, the SCSI controllers' 25 MHz (MESH's
//  delays and selection timeout, Curio's chip clock), a microsecond tick
//  (the SWIM3) and twice 44,100 Hz (AWACS's frames, whose samples come
//  out as snd_left and snd_right); all by phase accumulation. ext_irq is Grand
//  Central's interrupt output. The ESCC's channel A, the modem port, comes
//  out as modem_txd and modem_rxd; Grand Central's NVRAM can be written
//  from outside through nv_ld_* (an image loaded while reset is held).
//
//============================================================================

module MacPPC7300_machine
#(
	parameter int unsigned CPU_HZ   = 65_000_000,
	parameter int unsigned TB_HZ    = 12_500_000,
	parameter int unsigned VIA_HZ   = 783_360,
	parameter int unsigned RTXC_HZ  = 3_686_400,     // the ESCC's RTxC clock
	parameter int unsigned SCSI_HZ  = 25_000_000,    // MESH's time base and Curio's clock (below CPU_HZ)
	parameter int unsigned SDRAM_MB = 128,          // the module; the ROM sits in its top 4 MB
	parameter int unsigned CUDA_FAST_BOOT = 0       // 1: the test bench's (MacPPC7300_cuda FAST_BOOT)
)
(
	input  logic         clk,
	input  logic         reset,
	input  logic [7:0]   ram_mb,                    // installed RAM, at most SDRAM_MB - 4
	input  logic         boot_memtest,              // run the memory test in place of the ROM

	// the CPU's memory port
	input  logic         c_req,
	input  logic         c_we,
	input  logic         c_line,
	input  logic [31:2]  c_addr,
	input  logic [3:0]   c_be,
	input  logic [255:0] c_wdata,
	output logic         c_ack,
	output logic [255:0] c_rdata,

	// RAM and ROM, by SDRAM offset, to DSPPC604_memcdc
	output logic         m_req,
	output logic         m_we,
	output logic         m_line,
	output logic [31:2]  m_addr,
	output logic [3:0]   m_be,
	output logic [255:0] m_wdata,
	input  logic         m_ack,
	input  logic [255:0] m_rdata,

	output logic         ext_irq,
	output logic         tb_tick,
	output logic         cpu_reset,                 // Cuda holds the CPU in reset
	output logic         power_wake,                // off, and the power key pressed: reset the machine

	// the CPU's snoop port: a DMA access's line, presented before it goes to memory
	output logic         snoop_req,
	output logic         snoop_we,
	output logic [31:5]  snoop_addr,
	input  logic         snoop_ack,

	// the SCSI targets' images: hps_io's block devices (0, 1 the disks, 3 the
	// Toolbox, 4 the CD-ROM, 5 the CD changer; 2 not driven here), in clk_v
	input  logic [5:0]   img_mounted,
	input  logic [63:0]  img_size,
	input  logic         img_readonly,
	output logic [31:0]  sd_lba,
	output logic [5:0]   sd_rd,
	output logic [5:0]   sd_wr,
	output logic [5:0]   sd_blk_cnt,
	input  logic [5:0]   sd_ack,
	input  logic [13:0]  sd_buff_addr,
	input  logic [7:0]   sd_buff_dout,
	output logic [7:0]   sd_buff_din,
	input  logic         sd_buff_wr,
	output logic         disk_busy,
	output logic signed [15:0] cd_left,  // the CD's audio, in this clock
	output logic signed [15:0] cd_right,
	// the floppy disk's image: hps_io's slot 6 (the other signals shared), in clk_v
	input  logic         fd_mounted,
	output logic [31:0]  fd_lba,
	output logic         fd_rd,
	output logic [5:0]   fd_blk_cnt,
	input  logic         fd_ack,

	// a DMA write to RAM, for the test bench (its reference has no DMA): one
	// clock, as it goes into memory
	output logic         dma_wr,
	output logic         dma_wr_line,
	output logic [31:2]  dma_wr_addr,
	output logic [3:0]   dma_wr_be,
	output logic [255:0] dma_wr_data,

	// the modem port (the ESCC's channel A), 1 when idle; its CTS and RTS
	output logic         modem_txd,
	input  logic         modem_rxd,
	input  logic         modem_cts,
	output logic         modem_rts,

	// the network bridge (MacPPC7300_enet): MACE's side
	input  logic         net_link,
	output logic         net_tx_we,
	output logic [7:0]   net_tx_wa,
	output logic [63:0]  net_tx_wd,
	output logic         net_tx_go,
	output logic [10:0]  net_tx_len,
	input  logic         net_tx_done,
	output logic [7:0]   net_rx_ra,
	input  logic [63:0]  net_rx_q,
	input  logic         net_rx_avail,
	input  logic [10:0]  net_rx_len,
	output logic         net_rx_done,
	input  logic [47:0]  net_mac,
	input  logic         net_mac_ok,

	// the sound AWACS plays (signed, changing at its frame rate)
	output logic [15:0]  snd_left,
	output logic [15:0]  snd_right,

	// Grand Central's NVRAM written from outside, a byte a cycle, while
	// the machine is held in reset
	input  logic         nv_ld_we,
	input  logic         nv_ld_re,                  // ... or read from outside (MacPPC7300_gc)
	input  logic [12:0]  nv_ld_addr,
	input  logic [7:0]   nv_ld_data,
	output logic         nv_ld_rack,
	output logic [7:0]   nv_ld_q,
	output logic         nv_wr_cpu,                 // the CPU wrote the NVRAM

	// the monitor: its AppleSense codes (MacPPC7300_control MON_SENSE)
	input  logic [2:0]   mon_std,
	input  logic [5:0]   mon_ext,

	// the keyboard, the mouse and the game controller, as hps_io gives them (MacPPC7300_adb)
	input  logic [10:0]  ps2_key,
	input  logic [24:0]  ps2_mouse,
	input  logic [51:0]  joy,

	// the date and time for Cuda's clock: seconds since 1904, steady in this clock
	input  logic         clock_ok,
	input  logic [31:0]  clock_secs,

	// the VRAM, by VRAM byte address, to its clock crossing (the CPU port's
	// protocol, VRAM's byte order)
	output logic         v_req,
	output logic         v_we,
	output logic         v_line,
	output logic [21:2]  v_addr,
	output logic [3:0]   v_be,
	output logic [255:0] v_wdata,
	input  logic         v_ack,
	input  logic [255:0] v_rdata,

	// the video registers, to the picture side (MacPPC7300_video), standing
	// still while they are used
	output logic         timing_on,
	output logic [191:0] sw_params,
	output logic [21:0]  fb_base,
	output logic [14:0]  row_words,
	output logic         hs_pos,
	output logic         vs_pos,
	output logic [7:0]   dac_cr,
	output logic [7:0]   dbl_buf_cr,
	output logic [15:0]  cursor_x,
	output logic [191:0] cursor_clut,
	output logic [7:0]   athens_d2,
	output logic [7:0]   athens_n2,
	output logic [7:0]   athens_p2,
	input  logic         vbl_start_tog,
	input  logic         vbl_end_tog,
	input  logic         clk_v,
	input  logic [23:0]  clut_index,
	output logic [23:0]  clut_rgb,

	// the debug registers, for the debug readout
	output logic [31:0]  dbg_status,
	output logic [31:0]  dbg_passes,
	output logic [31:0]  dbg_errors,
	output logic [31:0]  dbg_first,

	// the records for MacPPC7300_trace; tr_mesh adds MESH's and channel A's accesses
	input  logic         tr_mesh,
	output logic         tr_ev,
	output logic [255:0] tr_rec
);

import MacPPC7300_pkg::*;

localparam logic [9:0] ROM_SDRAM = 10'((SDRAM_MB - 4) / 4);   // SDRAM offset of the ROM, in 4 MB

// ---- RAM: Hammerhead's banks ----------------------------------------------------------------
// One bank for each bit of ram_mb, the largest in bank 0 (120 MB: 64, 32, 16, 8 in banks
// 0-3), each answering only within its size at the base the ROM programs (bits 30-22: the
// bank's high register's bit 0, its low register), nothing above it; in the SDRAM largest
// first. The ROM (FFF041B8-FFF04454) sizes bank k at k x 64 MB, then packs the banks from 0.
// Until a base is programmed RAM is flat, as before (the start, the memory-test boot).
logic [15:0] hh_bank [26];
logic [8:0]  bk_base [7];                  // by size bit n: its bank's base
logic        banked;
always_ff @(posedge clk) begin
	logic [4:0] j;                         // size bit n's bank: the larger parts present
	logic       any;
	any = 1'b0;
	for (int n = 0; n < 7; n++) begin
		j = 5'd0;
		for (int m = n + 1; m < 7; m++) if (ram_mb[m]) j = j + 5'd1;
		bk_base[n] <= hh_bank[j][8:0];
		if (ram_mb[n] && hh_bank[j][8:0] != 9'd0) any = 1'b1;
	end
	banked <= any;
end
// {hit, SDRAM byte offset} of a physical address
function automatic logic [27:0] ram_map(input logic [31:0] x, input logic [7:0] mb,
                                         input logic bkd, input logic [62:0] bases);
	logic        hit, match;
	logic [26:0] off;
	logic [8:0]  bb;
	hit = 1'b0;
	off = x[26:0];
	if (!bkd) hit = x[31:20] < {4'h0, mb};
	else for (int n = 6; n >= 0; n--) begin
		bb = bases[9 * n +: 9];
		if (n >= 2) match = (x[30:22] >> (n - 2)) == (bb >> (n - 2));
		else        match = (x[30:22] == bb) && ((x[21:20] >> n) == 2'd0);
		if (!hit && mb[n] && !x[31] && match) begin
			hit = 1'b1;
			off = 27'((({24'd0, mb} >> (n + 1)) << (n + 21)) | ({5'd0, x[26:0]} & ((32'd1 << (n + 20)) - 32'd1)));
		end
	end
	ram_map = {hit, off};
endfunction
wire [62:0] bk_bases = {bk_base[6], bk_base[5], bk_base[4], bk_base[3], bk_base[2], bk_base[1], bk_base[0]};

// ---- decode -----------------------------------------------------------------------------
wire [31:0] a       = {c_addr, 2'b00};
wire [27:0] a_map   = ram_map(a, ram_mb, banked, bk_bases);
wire        is_ram  = a_map[27];
wire        is_rom  = a[31:22] == 10'h3FF;
wire        to_mem  = is_ram | (is_rom & ~c_we & ~boot_memtest);
wire        is_boot = is_rom & ~c_we & boot_memtest;
wire        is_dbg  = a[31:8] == 24'hF90000;
wire        is_cha  = a[31:24] == 8'hF0;
wire        is_ban  = a[31:24] == 8'hF2;
wire        is_gc   = a[31:17] == 15'h7980;                 // F3000000-F301FFFF
wire        is_hh   = a[31:12] == 20'hF8000 && a[11:4] < 8'h50;
wire        is_via  = is_gc && a[16:13] == 4'b1011;              // F3016000-F3017FFF
// Control's registers and VRAM, where Open Firmware put them (Chaos's BARs)
logic [31:12] ctl_regs_base;
logic [31:26] ctl_vram_base;
wire        is_ctl  = (ctl_regs_base != 20'h0) && (a[31:12] == ctl_regs_base);
wire        is_vram = (ctl_vram_base != 6'h0) && (a[31:26] == ctl_vram_base);

// ---- RAM and ROM: the CPU's accesses and the DMA channels', one port ------------------------
// The crossing captures a request and holds it, and ignores it in the cycle
// of its own acknowledge, exactly as the CPU's port behaves. Two masters
// share it (rule 2): the CPU's accesses go straight through when the port
// is free; a DMA access (Grand Central's DMA port, dm_*) first presents its
// line to the CPU's snoop port (the caches write it back if it is dirty,
// and drop it if the DMA writes), then takes the port as soon as it is
// free, before any new CPU access. The CPU's accesses go on during the
// snoop (the write-back is one of them, and a cache may have to finish a
// fill before it can answer), so a cache could fetch the line again after
// its part of the snoop and before the DMA writes it: a DMA write is
// therefore followed by a second snoop of the line, which drops any such
// copy. (A store into that copy in those few clocks would be written back
// over the DMA's bytes: MacPPC7300_stubs.md.) A DMA access outside RAM and the
// ROM reads 0 and writes nothing, at once.
logic         gdm_req, gdm_we, gdm_line, gdm_ack;
logic [31:2]  gdm_addr;
logic [3:0]   gdm_be;
logic [255:0] gdm_wdata, gdm_rdata;
wire  [31:0]  da      = {gdm_addr, 2'b00};
wire  [27:0]  da_map  = ram_map(da, ram_mb, banked, bk_bases);
wire          d_ram   = da_map[27];
wire          d_rom   = da[31:22] == 10'h3FF;
wire          d_mem   = d_ram | (d_rom & ~gdm_we);

typedef enum logic [2:0] {DQ_IDLE, DQ_SNOOP, DQ_MEM, DQ_SNOOP2, DQ_DONE} dq_t;
dq_t          dq;
logic         own_cpu, own_dma;                    // whose request the crossing holds
logic         snoop_gap;                           // a clock between the two snoops (the request drops)
wire          port_free = ~own_cpu & ~own_dma;
wire          grant_dma = port_free & (dq == DQ_MEM);
wire          grant_cpu = port_free & ~grant_dma & (dq != DQ_MEM) & c_req & to_mem;
wire          pres_dma  = own_dma | grant_dma;
wire          snoop_skip = reset | cpu_reset;     // a CPU held in reset has nothing to give back
// the board's devices (the bridges, Grand Central and all behind it, the
// Control video, the disks' bus side) are reset with the CPU, as a
// restart (Cuda's PC3) resets a 7600's whole board; Cuda, the ADB devices,
// Athens and the NVRAM's contents keep theirs
wire          board_reset = reset | cpu_reset;

assign snoop_req  = (dq == DQ_SNOOP || (dq == DQ_SNOOP2 && !snoop_gap)) && !snoop_skip;
assign snoop_we   = gdm_we;
assign snoop_addr = gdm_addr[31:5];

assign m_req   = pres_dma | ((own_cpu | grant_cpu) & c_req & to_mem);
assign m_we    = pres_dma ? gdm_we   : c_we;
assign m_line  = pres_dma ? gdm_line : c_line;
assign m_addr  = pres_dma ? (d_rom ? {ROM_SDRAM, da[21:2]} : {5'd0, da_map[26:2]})
                          : (is_rom ? {ROM_SDRAM, a[21:2]} : {5'd0, a_map[26:2]});
assign m_be    = pres_dma ? gdm_be   : c_be;
assign m_wdata = pres_dma ? gdm_wdata : c_wdata;
wire   cpu_m_ack = m_ack & own_cpu;

assign dma_wr      = m_ack & own_dma & gdm_we & d_ram;
assign dma_wr_line = gdm_line;
assign dma_wr_addr = gdm_addr;
assign dma_wr_be   = gdm_be;
assign dma_wr_data = gdm_wdata;

always_ff @(posedge clk) begin
	gdm_ack <= 1'b0;
	if (m_ack) begin
		own_cpu <= 1'b0;
		own_dma <= 1'b0;
	end
	else begin
		if (grant_cpu) own_cpu <= 1'b1;
		if (grant_dma) own_dma <= 1'b1;
	end
	snoop_gap <= 1'b0;
	case (dq)
		DQ_IDLE: if (gdm_req && !gdm_ack) begin
			if (!d_mem) begin                          // nothing there: 0, at once
				gdm_rdata <= 256'h0;
				gdm_ack   <= 1'b1;
				dq        <= DQ_DONE;
			end
			else dq <= DQ_SNOOP;
		end
		DQ_SNOOP: if (snoop_ack || snoop_skip) dq <= DQ_MEM;
		DQ_MEM: if (m_ack && own_dma) begin
			gdm_rdata <= m_rdata;
			if (gdm_we) begin                          // a write: the line snooped again
				snoop_gap <= 1'b1;
				dq        <= DQ_SNOOP2;
			end
			else begin
				gdm_ack <= 1'b1;
				dq      <= DQ_DONE;
			end
		end
		DQ_SNOOP2: if (!snoop_gap && (snoop_ack || snoop_skip)) begin
			gdm_ack <= 1'b1;
			dq      <= DQ_DONE;
		end
		default: dq <= DQ_IDLE;                        // the acknowledge's cycle
	endcase
	if (reset) begin
		dq        <= DQ_IDLE;
		own_cpu   <= 1'b0;
		own_dma   <= 1'b0;
		snoop_gap <= 1'b0;
		gdm_ack   <= 1'b0;
	end
end

// The VRAM is memory, not a device: it goes to the picture side through a
// crossing of its own, as RAM goes to the SDRAM. The 64 MB window as
// control.cpp maps it (read and write, 238-504), the optional bank fitted
// (4 MB in all): offset bit 23 set is the big-endian aperture; clear, the
// little-endian one, whose bytes are swapped within each pixel (16 bits:
// within halfwords; 32: within words; 8: as they are). In VRAM's wide mode
// (MISC_ENABLES bit 6, which Mac OS's driver sets) the window's low 4 MB are
// the VRAM; otherwise bits 22-21 pick a bank: 3 the optional, else the
// standard (writes to 1, which dingusppc also makes to the optional bank,
// are not mirrored: MacPPC7300_stubs.md).
logic [11:0] ctl_enables;
wire  [25:0] vo     = a[25:0];
wire  [1:0]  v_swap = vo[23] ? 2'd0 : (dac_cr[3:2] == 2'd0) ? 2'd0 : (dac_cr[3:2] == 2'd1) ? 2'd1 : 2'd2;
wire  [21:0] v_byte = ctl_enables[6] ? vo[21:0] : {vo[22:21] == 2'd3, vo[20:0]};

function automatic logic [31:0] v_sw(input logic [31:0] w, input logic [1:0] s);
	case (s)
		2'd1:    v_sw = {w[23:16], w[31:24], w[7:0], w[15:8]};
		2'd2:    v_sw = {w[7:0], w[15:8], w[23:16], w[31:24]};
		default: v_sw = w;
	endcase
endfunction
function automatic logic [3:0] v_swbe(input logic [3:0] e, input logic [1:0] s);
	case (s)
		2'd1:    v_swbe = {e[2], e[3], e[0], e[1]};
		2'd2:    v_swbe = {e[0], e[1], e[2], e[3]};
		default: v_swbe = e;
	endcase
endfunction
function automatic logic [255:0] v_swl(input logic [255:0] l, input logic [1:0] s);
	for (int i = 0; i < 8; i++) v_swl[32 * i +: 32] = v_sw(l[32 * i +: 32], s);
endfunction

assign v_req   = c_req & is_vram;
assign v_we    = c_we;
assign v_line  = c_line;
assign v_addr  = v_byte[21:2];
assign v_be    = v_swbe(c_be, v_swap);
assign v_wdata = v_swl(c_wdata, v_swap);

// Everything else is answered here: a word two cycles after it is seen, a line
// as eight words presented on consecutive cycles, answered after the last.
// The request goes to the devices from a register (p_*): the CPU's address and
// store data come straight off its caches' RAMs, and the decode and the
// devices' own muxes behind them set the clock before (build 28: -1.5 ns).
logic       dev_ack, dev_busy;
logic [3:0] dev_cnt;                               // cycles since the request was taken
logic [6:0] dev_sel_q;                             // which block answers: Control, Chaos, Bandit, GC, Hammerhead, debug, boot
logic       p_sel, pq_sel;                         // a word is before the devices in this cycle; was in the last
logic [2:0] p_k, pq_k;                             // ... this one of the line
logic [31:2] p_a;
logic [3:0]  p_be;
logic [31:0] p_wd;
logic        p_we;
logic [6:0]  p_dev;
logic [31:0] line_buf [8];

// a word access to the VIA waits for the VIA's clock: its next edge, then half
// a cycle (a line goes at once, as to any device)
localparam int unsigned VIA_HALF = CPU_HZ / VIA_HZ / 2;
logic [1:0] vw;                                    // 0 idle; 1 to the edge; 2 the half cycle
logic [7:0] vw_cnt;
wire  via_wait = is_via & ~c_line;
wire  via_go   = vw == 2'd2 && vw_cnt == 8'd0;
wire  dev_take = c_req & ~to_mem & ~is_vram & ~dev_busy & ~dev_ack & (~via_wait | via_go);
// the word presented to the devices in this cycle
wire        present = dev_take | (dev_busy & c_line & dev_cnt <= 4'd7);
wire  [2:0] pres_k  = dev_take ? 3'd0 : dev_cnt[2:0];
wire [31:2] dev_a   = c_line ? {c_addr[31:5], pres_k} : c_addr;
wire  [3:0] dev_be  = c_line ? 4'hF : c_be;
wire [31:0] dev_wd  = c_line ? c_wdata[255 - 32 * pres_k -: 32] : c_wdata[31:0];
always_ff @(posedge clk) begin
	p_sel <= present & ~reset;
	p_k   <= pres_k;
	p_a   <= dev_a;
	p_be  <= dev_be;
	p_wd  <= dev_wd;
	p_we  <= c_we;
	p_dev <= {is_ctl, is_cha, is_ban, is_gc, is_hh, is_dbg, is_boot};
end

// ---- the time base, the VIA's clock, the ESCC's and the SCSI controllers', the microsecond, ----
// ---- AWACS's twice 44,100 Hz ----
logic [31:0] tb_acc, via_acc, rtxc_acc, scsi_acc, us_acc, snd_acc;
logic        via_tick, rtxc_tick, scsi_tick, us_tick, snd_tick;
always_ff @(posedge clk) begin
	tb_tick   <= 1'b0;
	via_tick  <= 1'b0;
	rtxc_tick <= 1'b0;
	scsi_tick <= 1'b0;
	us_tick   <= 1'b0;
	snd_tick  <= 1'b0;
	if (snd_acc + 32'd88_200 >= CPU_HZ) begin
		snd_acc  <= snd_acc + 32'd88_200 - CPU_HZ;
		snd_tick <= 1'b1;
	end
	else snd_acc <= snd_acc + 32'd88_200;
	if (us_acc + 32'd1_000_000 >= CPU_HZ) begin
		us_acc  <= us_acc + 32'd1_000_000 - CPU_HZ;
		us_tick <= 1'b1;
	end
	else us_acc <= us_acc + 32'd1_000_000;
	if (scsi_acc + SCSI_HZ >= CPU_HZ) begin
		scsi_acc  <= scsi_acc + SCSI_HZ - CPU_HZ;
		scsi_tick <= 1'b1;
	end
	else scsi_acc <= scsi_acc + SCSI_HZ;
	if (rtxc_acc + RTXC_HZ >= CPU_HZ) begin
		rtxc_acc  <= rtxc_acc + RTXC_HZ - CPU_HZ;
		rtxc_tick <= 1'b1;
	end
	else rtxc_acc <= rtxc_acc + RTXC_HZ;
	if (tb_acc + TB_HZ >= CPU_HZ) begin
		tb_acc  <= tb_acc + TB_HZ - CPU_HZ;
		tb_tick <= 1'b1;
	end
	else tb_acc <= tb_acc + TB_HZ;
	if (via_acc + VIA_HZ >= CPU_HZ) begin
		via_acc  <= via_acc + VIA_HZ - CPU_HZ;
		via_tick <= 1'b1;
	end
	else via_acc <= via_acc + VIA_HZ;
	if (reset) begin
		tb_acc    <= 32'h0;
		via_acc   <= 32'h0;
		rtxc_acc  <= 32'h0;
		scsi_acc  <= 32'h0;
		us_acc    <= 32'h0;
		snd_acc   <= 32'h0;
		snd_tick  <= 1'b0;
		tb_tick   <= 1'b0;
		via_tick  <= 1'b0;
		rtxc_tick <= 1'b0;
		scsi_tick <= 1'b0;
		us_tick   <= 1'b0;
	end
end

always_ff @(posedge clk) begin
	case (vw)
		2'd0: if (c_req & ~to_mem & via_wait & ~dev_busy & ~dev_ack) vw <= 2'd1;
		2'd1: if (via_tick) begin vw <= 2'd2; vw_cnt <= 8'(VIA_HALF - 1); end
		default: begin
			if (vw_cnt != 8'd0) vw_cnt <= vw_cnt - 8'd1;
			else vw <= 2'd0;                        // via_go: the access is presented now
		end
	endcase
	if (reset) begin
		vw     <= 2'd0;
		vw_cnt <= 8'd0;
	end
end

// ---- the devices ------------------------------------------------------------------------
logic [31:0] cha_rdata, ban_rdata, gc_rdata;
logic        gc_irq;

MacPPC7300_pcicfg #(.BRIDGE(0)) chaos (
	.clk, .reset(board_reset),
	.sel(p_sel & p_dev[5]), .we(p_we), .addr(p_a[23:2]), .be(p_be), .wdata(p_wd),
	.rdata(cha_rdata), .ctl_regs_base, .ctl_vram_base
);

logic [31:12] ban_unused_regs;            // Bandit has no Control behind it
logic [31:26] ban_unused_vram;

MacPPC7300_pcicfg #(.BRIDGE(1)) bandit (
	.clk, .reset(board_reset),
	.sel(p_sel & p_dev[4]), .we(p_we), .addr(p_a[23:2]), .be(p_be), .wdata(p_wd),
	.rdata(ban_rdata), .ctl_regs_base(ban_unused_regs), .ctl_vram_base(ban_unused_vram)
);

// ---- Control's registers, at its second BAR (4 KB: the 512 bytes repeated) ------------------
logic [31:0] ctl_rdata;
logic        ctl_irq;
logic        cuda_nmi;                     // Cuda's NMI (PC2), Grand Central's source 14

MacPPC7300_control control (
	.clk, .reset(board_reset),
	.sel(p_sel & p_dev[6]), .we(p_we), .addr(p_a[8:2]), .be(p_be), .wdata(p_wd),
	.rdata(ctl_rdata), .irq(ctl_irq), .mon_std, .mon_ext,
	.sw_params, .fb_base, .row_words, .enables(ctl_enables), .timing_on, .hs_pos, .vs_pos,
	.vbl_start_tog, .vbl_end_tog
);

logic cuda_treq, cuda_cb1, cuda_cb2_oe, cuda_cb2_out;
logic via_tip, via_byteack, via_cb2_oe, via_cb2_out;
wire  cb2_line = (cuda_cb2_oe ? cuda_cb2_out : 1'b1) & (via_cb2_oe ? via_cb2_out : 1'b1);

// the internal SCSI bus: MESH's lines and the disks', wired together
logic       mesh_rst, mesh_bsy, mesh_sel, mesh_atn, mesh_ack, mesh_req, mesh_msg, mesh_cd, mesh_io;
logic [7:0] mesh_db;
logic       t_bsy, t_req, t_msg, t_cd, t_io;
logic [7:0] t_db;
wire        scsi_rst = mesh_rst;
wire        scsi_bsy = mesh_bsy | t_bsy;
wire        scsi_sel = mesh_sel;
wire        scsi_atn = mesh_atn;
wire        scsi_ack = mesh_ack;
wire        scsi_req = mesh_req | t_req;
wire        scsi_msg = mesh_msg | t_msg;
wire        scsi_cd  = mesh_cd  | t_cd;
wire        scsi_io  = mesh_io  | t_io;
wire [7:0]  scsi_db  = mesh_db  | t_db;

logic         dfin, dfin_ch;
logic [1:0]   dfin_type;
logic [127:0] dfin_info;
logic         itr_ev;
logic         fd_m_t, fd_m_ok, fd_m_dc42, fd_rq_t, fd_dn_t;
logic [1:0]   fd_m_fmt;
logic [11:0]  fd_rq_lba;
logic [9:0]   fd_ra;
logic [7:0]   fd_q;
logic [7:0]   itr_st;

MacPPC7300_gc #(.SCSI_HZ(SCSI_HZ)) gc (
	.clk, .reset(board_reset), .via_tick, .rtxc_tick, .scsi_tick, .us_tick, .snd_tick,
	.sel(p_sel & p_dev[3]), .we(p_we), .addr(p_a[16:2]), .be(p_be), .wdata(p_wd),
	.rdata(gc_rdata), .irq(gc_irq),
	.cuda_treq, .cuda_cb1, .cb2(cb2_line), .via_tip, .via_byteack, .via_cb2_oe, .via_cb2_out,
	.modem_txd, .modem_rxd, .modem_cts, .modem_rts,
	.net_link, .net_tx_we, .net_tx_wa, .net_tx_wd, .net_tx_go, .net_tx_len, .net_tx_done,
	.net_rx_ra, .net_rx_q, .net_rx_avail, .net_rx_len, .net_rx_done, .net_mac, .net_mac_ok,
	.nv_ld_we, .nv_ld_re, .nv_ld_addr, .nv_ld_data, .nv_ld_rack, .nv_ld_q, .nv_wr_cpu,
	.ctl_irq, .nmi(cuda_nmi),
	.mesh_rst, .mesh_bsy, .mesh_sel, .mesh_atn, .mesh_ack, .mesh_req, .mesh_msg, .mesh_cd, .mesh_io, .mesh_db,
	.scsi_rst, .scsi_bsy, .scsi_sel, .scsi_atn, .scsi_ack, .scsi_req, .scsi_msg, .scsi_cd, .scsi_io, .scsi_db,
	.dm_req(gdm_req), .dm_we(gdm_we), .dm_line(gdm_line), .dm_addr(gdm_addr), .dm_be(gdm_be),
	.dm_wdata(gdm_wdata), .dm_ack(gdm_ack), .dm_rdata(gdm_rdata),
	.snd_left, .snd_right,
	.dac_cr, .dbl_buf_cr, .cursor_x, .cursor_clut, .clk_v, .clut_index, .clut_rgb,
	.dfin, .dfin_ch, .dfin_type, .dfin_info, .itr_ev, .itr_st,
	.fd_m_t, .fd_m_ok, .fd_m_fmt, .fd_m_dc42, .fd_rq_t, .fd_rq_lba, .fd_dn_t, .fd_ra, .fd_q
);

assign ext_irq = gc_irq;

// ---- the internal bus's targets: disks at IDs 0 and 1, the CD-ROM at 3 (hps_io's slots) ----------
logic         sd_tr_ev;
logic [255:0] sd_tr_rec;

MacPPC7300_scsidisk #(.CLK_HZ(CPU_HZ)) disks (
	.clk, .reset(board_reset),
	.t_bsy, .t_req, .t_msg, .t_cd, .t_io, .t_db,
	.b_rst(scsi_rst), .b_bsy(scsi_bsy), .b_sel(scsi_sel), .b_atn(scsi_atn), .b_ack(scsi_ack), .b_db(scsi_db),
	.clk_h(clk_v), .img_mounted, .img_size, .img_readonly,
	.sd_lba, .sd_rd, .sd_wr, .sd_blk_cnt, .sd_ack, .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr,
	.busy(disk_busy), .cd_left, .cd_right, .tr_ev(sd_tr_ev), .tr_rec(sd_tr_rec)
);

// ---- the floppy disk's image (SWIM3's, in Grand Central) ---------------------------------------
MacPPC7300_fdblk fdblk (
	.clk_m(clk_v), .reset_m(1'b0),
	.img_mounted(fd_mounted), .img_size, .img_readonly,
	.sd_lba(fd_lba), .sd_rd(fd_rd), .sd_blk_cnt(fd_blk_cnt), .sd_ack(fd_ack),
	.sd_buff_addr, .sd_buff_dout, .sd_buff_wr,
	.m_t(fd_m_t), .m_ok(fd_m_ok), .m_fmt(fd_m_fmt), .m_dc42(fd_m_dc42),
	/* verilator lint_off PINCONNECTEMPTY */
	.m_ro(),
	/* verilator lint_on PINCONNECTEMPTY */
	.clk, .rq_t(fd_rq_t), .rq_lba(fd_rq_lba), .dn_t(fd_dn_t), .ra(fd_ra), .q(fd_q)
);

// ---- Cuda ------------------------------------------------------------------------------------
// On its ADB line: the keyboard and the mouse (MacPPC7300_adb), from the PS/2
// inputs. On its I2C lines: Athens, the video's clock generator (address 28).
logic        adb_low, adb_dev_low, cuda_tick, iic_scl_low, iic_sda_low, athens_sda_low;
wire         iic_scl = ~iic_scl_low;
wire         iic_sda = ~(iic_sda_low | athens_sda_low);

logic        adb_tr_ev;
logic [31:0] adb_tr_info;

logic power_off, power_key;
always_ff @(posedge clk) begin
	if (power_off & power_key) power_wake <= 1'b1;
	if (reset) power_wake <= 1'b0;
end

MacPPC7300_adb adb (
	.clk, .reset, .tick(cuda_tick), .host_low(adb_low), .dev_low(adb_dev_low),
	.ps2_key, .ps2_mouse, .joy, .power_key, .tr_ev(adb_tr_ev), .tr_info(adb_tr_info)
);

MacPPC7300_athens athens (
	.clk, .reset, .scl(iic_scl), .sda(iic_sda), .sda_low(athens_sda_low),
	.d2(athens_d2), .n2(athens_n2), .p2_mux2(athens_p2)
);

logic        cu_cen, cu_rd, cu_wr, cu_tr_valid, cu_tr_int, cu_cpi, cu_fast;
logic [12:0] cu_addr, cu_tr_pc;
logic [7:0]  cu_wdata, cu_rdata, cu_tr_op, cu_tr_a, cu_tr_x, cu_tr_sp, cu_tr_cc;

MacPPC7300_cuda #(.CLK_HZ(CPU_HZ), .FAST_BOOT(CUDA_FAST_BOOT != 0)) cuda (
	.clk, .reset,
	.via_tip, .via_byteack, .treq(cuda_treq), .cb1(cuda_cb1),
	.cb2_oe(cuda_cb2_oe), .cb2_out(cuda_cb2_out), .cb2(cb2_line),
	.cpu_reset, .power_off, .nmi(cuda_nmi), .clock_ok, .clock_secs,
	.adb_low, .adb_line(~(adb_low | adb_dev_low)), .tick(cuda_tick),
	.iic_scl_low, .iic_sda_low, .iic_scl, .iic_sda,
	.dbg_cen(cu_cen), .dbg_addr(cu_addr), .dbg_rd(cu_rd), .dbg_wr(cu_wr),
	.dbg_wdata(cu_wdata), .dbg_rdata(cu_rdata),
	.tr_valid(cu_tr_valid), .tr_int(cu_tr_int), .tr_pc(cu_tr_pc), .tr_op(cu_tr_op),
	.tr_a(cu_tr_a), .tr_x(cu_tr_x), .tr_sp(cu_tr_sp), .tr_cc(cu_tr_cc),
	.dbg_cpi(cu_cpi), .dbg_fast(cu_fast)
);

// ---- Hammerhead (hammerhead.cpp:41-140) ---------------------------------------------------
// One-byte registers 16 bytes apart, the byte in bits 31-24 of the word at
// the register's address (dingusppc returns it in the most significant byte
// of an access of any size). A write takes the access's first byte, and only
// at the register's own address. The bank base registers (1C0-4F0, two per
// bank, high byte first) are stored and read back, and place the RAM's banks
// (above: "RAM: Hammerhead's banks"; dingusppc maps RAM flat whatever they say).
localparam logic [7:0] HH_CPU_ID     = 8'h39;   // RISC machine, extended ID, TNT
localparam logic [7:0] HH_MB_ID      = 8'h90;   // video bus present, no second PCI bus; burst ROM (machinetnt.cpp:125-126)
localparam logic [7:0] HH_CPU_SPEED  = 8'h60;   // bus at 50 MHz (machinetnt.cpp:127)
localparam logic [7:0] HH_WHO_AM_I   = 8'h10;   // the primary CPU

logic [7:0]  hh_arb;
logic [31:0] hh_rdata;
wire  [7:0]  hh_reg   = p_a[11:4];              // register number: offset >> 4
wire         hh_bank_r = hh_reg >= 8'h1C && hh_reg <= 8'h4F;
wire  [5:0]  hh_n     = 6'(hh_reg - 8'h1C);     // bank * 2 + (1 for the low byte)
wire         hh_at    = p_a[3:2] == 2'b00 && p_be[3];  // the access starts at the register
wire  [7:0]  hh_wbyte = p_wd[31:24];

always_ff @(posedge clk) begin
	if (p_sel & p_dev[2]) begin
		if (hh_bank_r) begin
			hh_rdata <= {hh_n[0] ? hh_bank[hh_n[5:1]][7:0] : hh_bank[hh_n[5:1]][15:8], 24'h0};
			if (p_we & p_be[3]) begin
				if (hh_n[0]) hh_bank[hh_n[5:1]][7:0]  <= hh_wbyte;
				else         hh_bank[hh_n[5:1]][15:8] <= hh_wbyte;
			end
		end
		else begin
			case (hh_reg)
				8'h00:   hh_rdata <= {hh_at ? HH_CPU_ID    : 8'h00, 24'h0};
				8'h02:   hh_rdata <= {hh_at ? HH_MB_ID     : 8'h00, 24'h0};
				8'h03:   hh_rdata <= {hh_at ? HH_CPU_SPEED : 8'h00, 24'h0};
				8'h09:   hh_rdata <= {hh_at ? hh_arb       : 8'h00, 24'h0};
				8'h0B:   hh_rdata <= {hh_at ? HH_WHO_AM_I  : 8'h00, 24'h0};
				default: hh_rdata <= 32'h0;     // L2 cache configuration (0E) included: no L2
			endcase
			if (p_we & hh_at & hh_reg == 8'h09) hh_arb <= hh_wbyte;
		end
	end
	if (reset) begin
		hh_arb <= 8'h0;
		for (int i = 0; i < 26; i++) hh_bank[i] <= 16'h0;
	end
end

// ---- the memory-test boot program, in place of the ROM when the OSD asks ------------------
logic [31:0] boot_rdata;
MacPPC7300_bootrom bootrom (.clk, .addr(p_a[12:2]), .q(boot_rdata));

// ---- the debug registers (not a 7600 device) -------------------------------------------
// The memory test (verilator/progs.py, memtest) writes its progress here and
// the debug readout shows it:
//   00 status   04 passes completed   08 errors   0C first error address
//   10 the word read there   14 the word expected   20 installed RAM in bytes (read only)
logic [31:0] dbg_reg [6];
logic [31:0] dbg_rdata;
wire  [3:0]  dbg_n = p_a[7:2] < 6'd6 ? p_a[5:2] : 4'd15;
always_ff @(posedge clk) begin
	if (p_sel & p_dev[1]) begin
		dbg_rdata <= p_a[7:2] == 6'h08 ? {4'h0, ram_mb, 20'h0} : dbg_n < 4'd6 ? dbg_reg[dbg_n[2:0]] : 32'h0;
		if (p_we & dbg_n < 4'd6) dbg_reg[dbg_n[2:0]] <= merge_be(dbg_reg[dbg_n[2:0]], p_wd, p_be);
	end
	if (reset) for (int i = 0; i < 6; i++) dbg_reg[i] <= 32'h0;
end
assign dbg_status = dbg_reg[0];
assign dbg_passes = dbg_reg[1];
assign dbg_errors = dbg_reg[2];
assign dbg_first  = dbg_reg[3];

// ---- the answer ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
	if (dev_take) begin
		dev_busy  <= 1'b1;
		dev_cnt   <= 4'd1;
		dev_sel_q <= {is_ctl, is_cha, is_ban, is_gc, is_hh, is_dbg, is_boot};
	end
	else if (dev_busy) dev_cnt <= dev_cnt + 4'd1;
	// a word's answer is out the cycle after p_sel; a line's last word is in line_buf the cycle after that
	dev_ack  <= (p_sel & ~c_line) | (pq_sel & c_line & pq_k == 3'd7);
	if (dev_ack) dev_busy <= 1'b0;
	pq_sel   <= p_sel;
	pq_k     <= p_k;
	if (pq_sel) line_buf[pq_k] <= dev_rdata;
	if (reset) begin
		dev_busy  <= 1'b0;
		dev_ack   <= 1'b0;
		dev_cnt   <= 4'd0;
		dev_sel_q <= 7'b0;
		pq_sel    <= 1'b0;
	end
end

logic [31:0] dev_rdata;
always_comb begin
	dev_rdata = 32'h0;
	if (dev_sel_q[6]) dev_rdata = ctl_rdata;
	if (dev_sel_q[5]) dev_rdata = cha_rdata;
	if (dev_sel_q[4]) dev_rdata = ban_rdata;
	if (dev_sel_q[3]) dev_rdata = gc_rdata;
	if (dev_sel_q[2]) dev_rdata = hh_rdata;
	if (dev_sel_q[1]) dev_rdata = dbg_rdata;
	if (dev_sel_q[0]) dev_rdata = boot_rdata;
end

// ---- the trace: the targets' records, and (kind 4) the CPU's accesses to MESH and its DMA channel ----
logic        bt_pend, bt_we;
logic [31:0] bt_a, bt_wd, bt_us = 32'd0;
logic [3:0]  bt_be;
logic [15:0] bt_div = 16'd0;
// MACE (F3011000-F30111FF) and its DMA channels 2 and 3 (F3008200, 8300); MESH (F3018000)
// and its channel A (F3008A00) with tr_mesh. Not the interrupt registers: the NanoKernel
// reads and rewrites them thousands of times a second
wire         bt_hit = is_gc && (a[16:9] == 8'h88 || a[16:8] == 9'h082 || a[16:8] == 9'h083 ||
                                (tr_mesh && (a[16:8] == 9'h180 || a[16:8] == 9'h08A)));
always_ff @(posedge clk) begin
	if (bt_div == 16'(CPU_HZ / 1_000_000 - 1)) begin
		bt_div <= 16'd0;
		bt_us  <= bt_us + 32'd1;
	end
	else bt_div <= bt_div + 16'd1;
	if (dev_take & ~c_line) begin
		bt_pend <= bt_hit;
		bt_a    <= a;
		bt_we   <= c_we;
		bt_wd   <= c_wdata[31:0];
		bt_be   <= c_be;
	end
	else if (dev_ack) bt_pend <= 1'b0;
	if (reset) bt_pend <= 1'b0;
end
wire bt_ev = dev_ack & bt_pend;
// kind 5: a command of DMA channel 2 or 3 finished (8 fetched, 9 stopped); 6: the ADB keyboard;
// 10: MESH's interrupt (with tr_mesh)
wire   itr_tr = itr_ev & tr_mesh;
assign tr_ev  = sd_tr_ev | bt_ev | dfin | adb_tr_ev | itr_tr;
assign tr_rec = sd_tr_ev ? sd_tr_rec :
                bt_ev    ? {128'd0, bt_we ? bt_wd : dev_rdata, bt_a, bt_us, 19'd0, bt_we, bt_be, 8'd4} :
                dfin     ? {64'd0, dfin_info, bt_us, 16'd0, 7'd1, dfin_ch,
                            (dfin_type == 2'd0) ? 8'd5 : (dfin_type == 2'd1) ? 8'd8 : 8'd9} :
                itr_tr   ? {192'd0, bt_us, 16'd0, itr_st, 8'd10} :
                           {160'd0, adb_tr_info, bt_us, 24'd0, 8'd6};

assign c_ack   = cpu_m_ack | dev_ack | v_ack;
assign c_rdata = v_ack    ? v_swl(v_rdata, v_swap) :
                 ~dev_ack ? m_rdata :
                 c_line   ? {line_buf[0], line_buf[1], line_buf[2], line_buf[3],
                             line_buf[4], line_buf[5], line_buf[6], line_buf[7]} :
                            {224'h0, dev_rdata};

endmodule
