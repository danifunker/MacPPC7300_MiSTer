//============================================================================
//
//  PPCMac - the machine around the CPU
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
//    00000000  installed RAM          ram_mb MB, flat from 0, as Hammerhead
//                                     maps it whatever its bank registers say
//                                     (machinetnt.cpp:135-143,
//                                     hammerhead.cpp:161-176); SDRAM offset 0
//    F0000000  Chaos, video bus       16 MB: configuration space only
//                                     (bandit.cpp:308-322) -> PPCMac_pcicfg
//    F2000000  Bandit 1, PCI          16 MB: configuration space only
//                                     (bandit.cpp:293-306) -> PPCMac_pcicfg
//    F3000000  Grand Central          128 KB, where the ROM sets its base
//                                     address register (grandcentral.cpp:52,
//                                     machinetnt.cpp:78-80) -> PPCMac_gc
//    F8000000  Hammerhead             1,280 bytes of registers
//                                     (hammerhead.cpp:39) -> below
//    FFC00000  ROM                    4 MB (machinetnt.cpp:131); SDRAM offset
//                                     SDRAM_MB - 4 MB; writes are ignored.
//                                     With boot_memtest, the 8 KB memory-test
//                                     program (PPCMac_bootrom) mirrored over
//                                     it instead
//    F9000000  debug registers        not a 7600 device: 256 bytes where the
//                                     memory test reports (see below); no
//                                     7600 ROM touches this address
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
//  Cuda (PPCMac_cuda), the board's microcontroller, sits on the VIA's port
//  B and shift register, and holds the CPU in reset (cpu_reset) until its
//  firmware has powered the machine up, as on the 7600.
//
//  A line request to a device is eight word accesses to it, the lowest
//  address first, as a burst on the real bus would be: with data
//  translation off the 604 treats every address as cacheable, and the ROM
//  reads Hammerhead's CPU ID through the data cache (its fortieth
//  instruction, FFF03108, after enabling the cache at FFF03094).
//
//  Also made here: tb_tick for the CPU's time base and decrementer, at
//  TB_HZ on average from any CPU clock (the 604 counts every fourth bus
//  clock; the 7600's bus is 50 MHz), the VIA's 783,360 Hz clock and the
//  ESCC's RTxC at 3,686,400 Hz; all by phase accumulation. ext_irq is Grand
//  Central's interrupt output. The ESCC's channel A, the modem port, comes
//  out as modem_txd and modem_rxd; Grand Central's NVRAM can be written
//  from outside through nv_ld_* (an image loaded while reset is held).
//
//============================================================================

module PPCMac_machine
#(
	parameter int unsigned CPU_HZ   = 65_000_000,
	parameter int unsigned TB_HZ    = 12_500_000,
	parameter int unsigned VIA_HZ   = 783_360,
	parameter int unsigned RTXC_HZ  = 3_686_400,     // the ESCC's RTxC clock
	parameter int unsigned SDRAM_MB = 128,          // the module; the ROM sits in its top 4 MB
	parameter int unsigned CUDA_FAST_BOOT = 0       // 1: the test bench's (PPCMac_cuda FAST_BOOT)
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

	// the modem port (the ESCC's channel A), 1 when idle
	output logic         modem_txd,
	input  logic         modem_rxd,

	// Grand Central's NVRAM written from outside, a byte a cycle, while
	// the machine is held in reset
	input  logic         nv_ld_we,
	input  logic [12:0]  nv_ld_addr,
	input  logic [7:0]   nv_ld_data,

	// the debug registers, for the debug readout
	output logic [31:0]  dbg_status,
	output logic [31:0]  dbg_passes,
	output logic [31:0]  dbg_errors,
	output logic [31:0]  dbg_first
);

import PPCMac_pkg::*;

localparam logic [9:0] ROM_SDRAM = 10'((SDRAM_MB - 4) / 4);   // SDRAM offset of the ROM, in 4 MB

// ---- decode -----------------------------------------------------------------------------
wire [31:0] a       = {c_addr, 2'b00};
wire        is_ram  = a[31:20] < {4'h0, ram_mb};
wire        is_rom  = a[31:22] == 10'h3FF;
wire        to_mem  = is_ram | (is_rom & ~c_we & ~boot_memtest);
wire        is_boot = is_rom & ~c_we & boot_memtest;
wire        is_dbg  = a[31:8] == 24'hF90000;
wire        is_cha  = a[31:24] == 8'hF0;
wire        is_ban  = a[31:24] == 8'hF2;
wire        is_gc   = a[31:17] == 15'h7980;                 // F3000000-F301FFFF
wire        is_hh   = a[31:12] == 20'hF8000 && a[11:4] < 8'h50;
wire        is_via  = is_gc && a[16:13] == 4'b1011;              // F3016000-F3017FFF

// RAM and ROM go straight through: the crossing captures the request and
// holds it, and ignores it in the cycle of its own acknowledge, exactly as
// the CPU's port behaves
assign m_req   = c_req & to_mem;
assign m_we    = c_we;
assign m_line  = c_line;
assign m_addr  = is_rom ? {ROM_SDRAM, a[21:2]} : a[31:2];
assign m_be    = c_be;
assign m_wdata = c_wdata;

// Everything else is answered here: a word a cycle after it is seen, a line
// as eight words presented on consecutive cycles, answered after the last.
logic       dev_ack, dev_busy;
logic [3:0] dev_cnt;                               // cycles since the request was taken
logic [5:0] dev_sel_q;                             // which block answers: Chaos, Bandit, GC, Hammerhead, debug, boot
logic       pres_q;                                // a word was presented in the last cycle
logic [2:0] pres_k_q;                              // ... this one of the line
logic [31:0] line_buf [8];

// a word access to the VIA waits for the VIA's clock: its next edge, then half
// a cycle (a line goes at once, as to any device)
localparam int unsigned VIA_HALF = CPU_HZ / VIA_HZ / 2;
logic [1:0] vw;                                    // 0 idle; 1 to the edge; 2 the half cycle
logic [7:0] vw_cnt;
wire  via_wait = is_via & ~c_line;
wire  via_go   = vw == 2'd2 && vw_cnt == 8'd0;
wire  dev_take = c_req & ~to_mem & ~dev_busy & ~dev_ack & (~via_wait | via_go);
// the word presented to the devices in this cycle
wire        present = dev_take | (dev_busy & c_line & dev_cnt <= 4'd7);
wire  [2:0] pres_k  = dev_take ? 3'd0 : dev_cnt[2:0];
wire [31:2] dev_a   = c_line ? {c_addr[31:5], pres_k} : c_addr;
wire  [3:0] dev_be  = c_line ? 4'hF : c_be;
wire [31:0] dev_wd  = c_line ? c_wdata[255 - 32 * pres_k -: 32] : c_wdata[31:0];

// ---- the time base, the VIA's clock and the ESCC's -------------------------------------
logic [31:0] tb_acc, via_acc, rtxc_acc;
logic        via_tick, rtxc_tick;
always_ff @(posedge clk) begin
	tb_tick   <= 1'b0;
	via_tick  <= 1'b0;
	rtxc_tick <= 1'b0;
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
		tb_tick   <= 1'b0;
		via_tick  <= 1'b0;
		rtxc_tick <= 1'b0;
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

PPCMac_pcicfg #(.BRIDGE(0)) chaos (
	.clk, .reset,
	.sel(present & is_cha), .we(c_we), .addr(dev_a[23:2]), .be(dev_be), .wdata(dev_wd),
	.rdata(cha_rdata)
);

PPCMac_pcicfg #(.BRIDGE(1)) bandit (
	.clk, .reset,
	.sel(present & is_ban), .we(c_we), .addr(dev_a[23:2]), .be(dev_be), .wdata(dev_wd),
	.rdata(ban_rdata)
);

logic cuda_treq, cuda_cb1, cuda_cb2_oe, cuda_cb2_out;
logic via_tip, via_byteack, via_cb2_oe, via_cb2_out;
wire  cb2_line = (cuda_cb2_oe ? cuda_cb2_out : 1'b1) & (via_cb2_oe ? via_cb2_out : 1'b1);

PPCMac_gc gc (
	.clk, .reset, .via_tick, .rtxc_tick,
	.sel(present & is_gc), .we(c_we), .addr(dev_a[16:2]), .be(dev_be), .wdata(dev_wd),
	.rdata(gc_rdata), .irq(gc_irq),
	.cuda_treq, .cuda_cb1, .cb2(cb2_line), .via_tip, .via_byteack, .via_cb2_oe, .via_cb2_out,
	.modem_txd, .modem_rxd, .nv_ld_we, .nv_ld_addr, .nv_ld_data
);

assign ext_irq = gc_irq;

// ---- Cuda ------------------------------------------------------------------------------------
// Nothing else is on its ADB line or its I2C lines yet: each reads as Cuda
// itself drives it.
logic        adb_low, iic_scl_low, iic_sda_low;
logic        cu_cen, cu_rd, cu_wr, cu_tr_valid, cu_tr_int, cu_cpi, cu_fast;
logic [12:0] cu_addr, cu_tr_pc;
logic [7:0]  cu_wdata, cu_rdata, cu_tr_op, cu_tr_a, cu_tr_x, cu_tr_sp, cu_tr_cc;

PPCMac_cuda #(.CLK_HZ(CPU_HZ), .FAST_BOOT(CUDA_FAST_BOOT != 0)) cuda (
	.clk, .reset,
	.via_tip, .via_byteack, .treq(cuda_treq), .cb1(cuda_cb1),
	.cb2_oe(cuda_cb2_oe), .cb2_out(cuda_cb2_out), .cb2(cb2_line),
	.cpu_reset,
	.adb_low, .adb_line(~adb_low),
	.iic_scl_low, .iic_sda_low, .iic_scl(~iic_scl_low), .iic_sda(~iic_sda_low),
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
// bank, high byte first) are stored and read back; RAM is mapped flat all
// the same.
localparam logic [7:0] HH_CPU_ID     = 8'h39;   // RISC machine, extended ID, TNT
localparam logic [7:0] HH_MB_ID      = 8'h90;   // video bus present, no second PCI bus; burst ROM (machinetnt.cpp:125-126)
localparam logic [7:0] HH_CPU_SPEED  = 8'h60;   // bus at 50 MHz (machinetnt.cpp:127)
localparam logic [7:0] HH_WHO_AM_I   = 8'h10;   // the primary CPU

logic [7:0]  hh_arb;
logic [15:0] hh_bank [26];
logic [31:0] hh_rdata;
wire  [7:0]  hh_reg   = dev_a[11:4];            // register number: offset >> 4
wire         hh_bank_r = hh_reg >= 8'h1C && hh_reg <= 8'h4F;
wire  [5:0]  hh_n     = 6'(hh_reg - 8'h1C);     // bank * 2 + (1 for the low byte)
wire         hh_at    = dev_a[3:2] == 2'b00 && dev_be[3];  // the access starts at the register
wire  [7:0]  hh_wbyte = dev_wd[31:24];

always_ff @(posedge clk) begin
	if (present & is_hh) begin
		if (hh_bank_r) begin
			hh_rdata <= {hh_n[0] ? hh_bank[hh_n[5:1]][7:0] : hh_bank[hh_n[5:1]][15:8], 24'h0};
			if (c_we & dev_be[3]) begin
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
			if (c_we & hh_at & hh_reg == 8'h09) hh_arb <= hh_wbyte;
		end
	end
	if (reset) begin
		hh_arb <= 8'h0;
		for (int i = 0; i < 26; i++) hh_bank[i] <= 16'h0;
	end
end

// ---- the memory-test boot program, in place of the ROM when the OSD asks ------------------
logic [31:0] boot_rdata;
PPCMac_bootrom bootrom (.clk, .addr(dev_a[12:2]), .q(boot_rdata));

// ---- the debug registers (not a 7600 device) -------------------------------------------
// The memory test (verilator/progs.py, memtest) writes its progress here and
// the debug readout shows it:
//   00 status   04 passes completed   08 errors   0C first error address
//   10 the word read there   14 the word expected   20 installed RAM in bytes (read only)
logic [31:0] dbg_reg [6];
logic [31:0] dbg_rdata;
wire  [3:0]  dbg_n = dev_a[7:2] < 6'd6 ? dev_a[5:2] : 4'd15;
always_ff @(posedge clk) begin
	if (present & is_dbg) begin
		dbg_rdata <= dev_a[7:2] == 6'h08 ? {4'h0, ram_mb, 20'h0} : dbg_n < 4'd6 ? dbg_reg[dbg_n[2:0]] : 32'h0;
		if (c_we & dbg_n < 4'd6) dbg_reg[dbg_n[2:0]] <= merge_be(dbg_reg[dbg_n[2:0]], dev_wd, dev_be);
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
		dev_sel_q <= {is_cha, is_ban, is_gc, is_hh, is_dbg, is_boot};
	end
	else if (dev_busy) dev_cnt <= dev_cnt + 4'd1;
	dev_ack  <= (dev_take & ~c_line) | (dev_busy & c_line & dev_cnt == 4'd8);
	if (dev_ack) dev_busy <= 1'b0;
	pres_q   <= present;
	pres_k_q <= pres_k;
	if (pres_q) line_buf[pres_k_q] <= dev_rdata;
	if (reset) begin
		dev_busy  <= 1'b0;
		dev_ack   <= 1'b0;
		dev_cnt   <= 4'd0;
		dev_sel_q <= 6'b0;
		pres_q    <= 1'b0;
	end
end

logic [31:0] dev_rdata;
always_comb begin
	dev_rdata = 32'h0;
	if (dev_sel_q[5]) dev_rdata = cha_rdata;
	if (dev_sel_q[4]) dev_rdata = ban_rdata;
	if (dev_sel_q[3]) dev_rdata = gc_rdata;
	if (dev_sel_q[2]) dev_rdata = hh_rdata;
	if (dev_sel_q[1]) dev_rdata = dbg_rdata;
	if (dev_sel_q[0]) dev_rdata = boot_rdata;
end

assign c_ack   = m_ack | dev_ack;
assign c_rdata = ~dev_ack ? m_rdata :
                 c_line   ? {line_buf[0], line_buf[1], line_buf[2], line_buf[3],
                             line_buf[4], line_buf[5], line_buf[6], line_buf[7]} :
                            {224'h0, dev_rdata};

endmodule
