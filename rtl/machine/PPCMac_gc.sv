//============================================================================
//
//  PPCMac - the machine around the CPU
//  Grand Central, the 7600's I/O controller, as register stubs
//
//  The 128 KB register window (the ROM puts it at F3000000) as dingusppc's
//  devices/ioctrl/grandcentral.cpp decodes it (GrandCentral::read and
//  ::write, lines 176-450), each sub-device answering what dingusppc's
//  device answers from reset, and no more, until the ROM's progress asks
//  for more:
//
//    00000-07FFF  interrupt registers: events, mask, clear, levels
//                 (grandcentral.cpp:296-307, 432-449, 525-589; MAME's
//                 heathrow.cpp macio_device::set_irq_line): each source's
//                 line sets its event bit on a rising edge, or on either
//                 edge when the mask's top bit selects 68k mode (Mac OS's
//                 NanoKernel runs it so, and reads the levels to follow the
//                 line both ways); the CPU's interrupt is any event that is
//                 unmasked. Sources so far: the VIA (12)
//    08000-0FFFF  DMA channel registers, 256 bytes per channel
//                 (grandcentral.cpp:250-305; dbdma.cpp:307-380): stored and
//                 read back; a channel never runs (there is no bus master)
//    10000        Curio SCSI             reads 0
//    11000        MACE Ethernet          reads 0
//    12000-13FFF  ESCC serial            a command read gives RR0 = 44
//                                        (transmit buffer empty), other
//                                        registers 0 (escc.cpp:77-200)
//    14000        AWACS sound            awacs.cpp:189-257
//    15000        SWIM3 floppy           reads 0
//    16000-17FFF  VIA                    viacuda.cpp:142-322, the timers
//                                        counting at 783,360 Hz; port B and
//                                        the shift register wired to Cuda
//                                        (below); PPCMac_machine paces the
//                                        accesses to the VIA's clock
//    18000        MESH SCSI              reads 0
//    19000        Ethernet address ROM   08 00 07 44 55 66 00 00
//    1A000        board register 1       E13F (machinetnt.cpp:98-106)
//    1B000        RaDACal (the Control   reads 0 (control.cpp:156; no video
//                 video's RAMDAC)        yet)
//    1C000        no device              reads 0
//    1D000        NVRAM address, high    (macio.h:94-107)
//    1E000        no device on a 7600    reads 0 (board register 2 needs Bandit 2)
//    1F000        NVRAM data, 8 KB       (macio.h:109-125; nvram.cpp:41-60)
//
//  An access is presented for one cycle (sel); the read data is valid in
//  the next cycle.
//
//============================================================================

module PPCMac_gc
(
	input  logic        clk,
	input  logic        reset,
	input  logic        via_tick,      // one clock at 783,360 Hz
	input  logic        sel,
	input  logic        we,
	input  logic [16:2] addr,          // offset in the 128 KB window
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	output logic [31:0] rdata,
	output logic        irq,           // to the CPU's external interrupt

	// the VIA's lines to Cuda (PPCMac_cuda): port B and the shift register
	input  logic        cuda_treq,     // PB3 in: 0 when Cuda asks for a transaction
	input  logic        cuda_cb1,      // CB1: Cuda's shift clock
	input  logic        cb2,           // CB2: the data line, whoever drives it
	output logic        via_tip,       // PB5 out: 0 while a transaction is in progress
	output logic        via_byteack,   // PB4 out
	output logic        via_cb2_oe,    // the VIA drives CB2 (shifting out)
	output logic        via_cb2_out
);

import PPCMac_pkg::*;

wire [16:0] off    = {addr, first_lane(be)};    // the byte offset dingusppc sees
wire [7:0]  wb     = byte_reg_wdata(be, wdata); // what a byte-wide register stores
wire        devs   = addr[16];                  // device register space
wire        dma    = ~addr[16] & addr[15];      // DMA register space
wire        ints   = ~addr[16] & ~addr[15];     // interrupt registers
wire [3:0]  sub    = addr[15:12];               // device number in device space
wire        single = (be == 4'b1000) | (be == 4'b0100) | (be == 4'b0010) | (be == 4'b0001);

// ---- interrupt registers (little-endian inside, as dingusppc keeps them) ------------
// The sources' lines, numbered as Grand Central numbers them
// (grandcentral.cpp:467-523): 0C Curio, 0D MESH, 0E MACE, 0F/10 SCC A/B,
// 11 AWACS, 12 the VIA, 13 SWIM3; 00-0A the DMA channels. int_lines_q is
// each line as last seen: the levels register, and the edge detector.
logic [31:0] int_mask, int_events, int_lines_q;
logic        via_irq;                           // the VIA's IRQ: an enabled flag is set
wire  [31:0] int_lines  = {13'h0, via_irq, 18'h0};
wire  [31:0] int_levels = int_lines_q | 32'h0000_0800;   // dingusppc ORs in bit 11 (grandcentral.cpp:306)
wire         int_68k    = int_mask[31];         // MACIO_INT_MODE: an event at either edge
wire  [31:0] int_chg    = int_lines ^ int_lines_q;
assign irq = |(int_events & int_mask & 32'h7FFF_FFFF);

// ---- DMA channels: 0-3 Curio, floppy, Ethernet out and in; 8 sound out; A MESH ----
// (4-7, the serial channels, and 9, sound in, read 0 and ignore writes)
localparam int NCH = 6;
logic [15:0] ch_stat [NCH];
logic [31:0] ch_cmd  [NCH];
logic [31:0] ch_isel [NCH];
logic [31:0] ch_bsel [NCH];
logic [31:0] ch_wsel [NCH];
logic [2:0]  ch;
logic        ch_ok;
always_comb begin
	ch_ok = 1'b1;
	case (addr[14:8])
		7'd0:  ch = 3'd0;
		7'd1:  ch = 3'd1;
		7'd2:  ch = 3'd2;
		7'd3:  ch = 3'd3;
		7'd8:  ch = 3'd4;
		7'd10: ch = 3'd5;
		default: begin ch = 3'd0; ch_ok = 1'b0; end
	endcase
end
wire [31:0] wle = bswap32(wdata);               // dingusppc swaps a written word (dbdma.cpp:348)

// ---- ESCC: one register pointer, shared, as in escc.cpp -----------------------------
logic [3:0] scc_ptr;
// compatible addressing (offset < 0C) maps (offset >> 1) to MacRISC registers
// 0 B command, 1 A command, 2 B data, 3 A data (escc.cpp:38-42); MacRISC
// addressing numbers them by (offset >> 4) (grandcentral.cpp:196-206)
wire scc_compat = sub == 4'h2 && off[7:0] < 8'h0C;
wire scc_risc   = sub == 4'h3 || (sub == 4'h2 && off[7:0] >= 8'h60);
wire scc_cmd    = (scc_compat && off[3:1] <= 3'd1) || (scc_risc && (off[7:4] == 4'd0 || off[7:4] == 4'd2));

// ---- AWACS (awacs.cpp:189-257) ---------------------------------------------------------
logic [31:0] snd_ctrl, codec_ctrl, clip_count, frame_count;
logic        byte_swap;

// ---- VIA (viacuda.cpp; port B and the shift register as a 6522 and Cuda have them) -------
// Port B is a 6522's: the output register holds all eight bits and a read
// gives it where DDRB is 1 and the pins elsewhere; the pins Cuda drives
// are PB3 (TREQ), the others read 0. PB5 (TIP) and PB4 (BYTEACK) go to
// Cuda, high where they are inputs. The shift register works in the modes
// Cuda's protocol uses, both clocked by Cuda on CB1, as MAME's 6522 does
// them (6522via.cpp shift_in, shift_out, write_cb1): every CB1 edge counts;
// shifting out (ACR SR bits 111) the VIA puts SR bit 7 on CB2 and rotates on
// a falling edge, the flag at the eighth; shifting in (011, and 000) it
// takes CB2 in on a rising edge, the flag at the eighth (not in 000). A
// read or write of SR clears the flag and starts the count again.
logic [7:0]  via_orb, via_porta, via_ddrb, via_ddra, via_sr, via_acr, via_pcr, via_ifr, via_ier;
logic [7:0]  t1ll, t1lh, t2ll;
logic [15:0] t1, t2;                 // the counters
logic [17:0] t1_left, t2_left;       // VIA clocks until the flag
logic        t1_run, t2_run;
logic [4:0]  sr_cnt;                 // CB1 edges until the flag (MAME's m_shift_counter)
logic        cb1_q;                  // CB1 as last seen
logic        cb2_q;                  // what the VIA drives on CB2
wire  [3:0]  via_reg    = addr[12:9];
wire  [7:0]  via_ifr_rd = {|(via_ifr[6:0] & via_ier[6:0]), via_ifr[6:0]};
assign via_irq = via_ifr_rd[7];
wire  [7:0]  via_pb_rd  = (via_orb & via_ddrb) | ({4'b0000, cuda_treq, 3'b000} & ~via_ddrb);

assign via_tip     = ~via_ddrb[5] | via_orb[5];
assign via_byteack = ~via_ddrb[4] | via_orb[4];
assign via_cb2_oe  = via_acr[4];
assign via_cb2_out = cb2_q;

// ---- NVRAM -----------------------------------------------------------------------------
logic [15:0] nv_hi;
logic [7:0]  nvram [0:8191];
logic [7:0]  nv_q;
logic        nv_rd_q;
wire  [12:0] nv_addr = 13'((nv_hi << 5) + 16'(off[8:4]));
// what an IOBus device is written: a single byte as it is, else the
// halfword byte-swapped (grandcentral.cpp:358-365)
wire  [15:0] io_w  = single ? {8'h00, wb} : (be[3] ? {wdata[23:16], wdata[31:24]} : {wdata[7:0], wdata[15:8]});
wire         nv_wr = sel & we & devs & (sub == 4'hF);

always_ff @(posedge clk) begin
	if (nv_wr) nvram[nv_addr] <= io_w[7:0];
	nv_q <= nvram[nv_addr];
end

// an IOBus device's 16-bit value as a CPU word (grandcentral.cpp:224-233)
function automatic logic [31:0] iobus_rdata(input logic [15:0] v);
	iobus_rdata = {v[7:0], v[15:8], 16'h0};
endfunction

// ---- what a read returns ---------------------------------------------------------------
logic [31:0] rq;
always_comb begin
	rq = 32'h0;
	if (ints) begin
		case (off[7:0])
			8'h20:   rq = bswap32(int_events & int_mask);
			8'h24:   rq = bswap32(int_mask);
			8'h2C:   rq = bswap32(int_levels);
			default: rq = 32'h0;
		endcase
	end
	else if (dma) begin
		if (ch_ok) begin
			case (off[7:2])
				6'd1:    rq = bswap32({16'h0, ch_stat[ch]});
				6'd3:    rq = bswap32(ch_cmd[ch]);
				6'd4:    rq = bswap32(ch_isel[ch]);
				6'd5:    rq = bswap32(ch_bsel[ch]);
				6'd6:    rq = bswap32(ch_wsel[ch]);
				default: rq = 32'h0;          // ChannelControl reads 0
			endcase
		end
	end
	else begin
		case (sub)
			4'h2, 4'h3: if (scc_cmd) rq = byte_reg_rdata(be, scc_ptr == 4'd0 ? 8'h44 : 8'h00);
			4'h4: begin
				case (off[7:0])
					8'h00:   rq = snd_ctrl;
					8'h10:   rq = codec_ctrl;
					8'h20:   rq = 32'h0031_4000;   // available, Crystal, Screamer
					8'h30:   rq = clip_count;
					8'h40:   rq = {31'h0, ~byte_swap};
					8'h50:   rq = frame_count;
					default: rq = 32'h0;
				endcase
			end
			4'h6, 4'h7: begin
				case (via_reg)
					4'd0:        rq = byte_reg_rdata(be, via_pb_rd);
					4'd1, 4'd15: rq = byte_reg_rdata(be, via_porta);
					4'd2:        rq = byte_reg_rdata(be, via_ddrb);
					4'd3:        rq = byte_reg_rdata(be, via_ddra);
					4'd4:        rq = byte_reg_rdata(be, t1[7:0]);
					4'd5:        rq = byte_reg_rdata(be, t1[15:8]);
					4'd6:        rq = byte_reg_rdata(be, t1ll);
					4'd7:        rq = byte_reg_rdata(be, t1lh);
					4'd8:        rq = byte_reg_rdata(be, t2[7:0]);
					4'd9:        rq = byte_reg_rdata(be, t2[15:8]);
					4'd10:       rq = byte_reg_rdata(be, via_sr);
					4'd11:       rq = byte_reg_rdata(be, via_acr);
					4'd12:       rq = byte_reg_rdata(be, via_pcr);
					4'd13:       rq = byte_reg_rdata(be, via_ifr_rd);
					default:     rq = byte_reg_rdata(be, via_ier | 8'h80);
				endcase
			end
			4'h9: begin
				case (off[6:4])
					3'd0:    rq = byte_reg_rdata(be, 8'h08);
					3'd2:    rq = byte_reg_rdata(be, 8'h07);
					3'd3:    rq = byte_reg_rdata(be, 8'h44);
					3'd4:    rq = byte_reg_rdata(be, 8'h55);
					3'd5:    rq = byte_reg_rdata(be, 8'h66);
					default: rq = byte_reg_rdata(be, 8'h00);
				endcase
			end
			4'hA:    rq = iobus_rdata(16'hE13F);
			4'hD:    rq = iobus_rdata(nv_hi);
			default: rq = 32'h0;              // 4'hF, the NVRAM, answers from its RAM
		endcase
	end
end

logic [31:0] rdata_q;
assign rdata = nv_rd_q ? iobus_rdata({8'h00, nv_q}) : rdata_q;

// ---- the shift register: the CPU's access to it, then a CB1 edge in the same clock --------
wire       sr_acc = sel & devs & (sub == 4'h6 || sub == 4'h7) & (via_reg == 4'd10);
wire [4:0] cnt_a  = sr_acc ? (cb1_q ? 5'd15 : 5'd16) : sr_cnt;
wire [7:0] sr_a   = (sr_acc & we) ? wb : via_sr;
wire [2:0] sr_m   = via_acr[4:2];
logic [7:0] sr_n;
logic [4:0] cnt_n;
logic       cb2_n, sr_flag;
always_comb begin
	sr_n    = sr_a;
	cnt_n   = cnt_a;
	cb2_n   = cb2_q;
	sr_flag = 1'b0;
	if (cuda_cb1 != cb1_q) begin
		if (sr_m == 3'b111) begin
			if (cnt_a[0]) begin
				cb2_n = sr_a[7];
				sr_n  = {sr_a[6:0], sr_a[7]};
				if (cnt_a == 5'd1) sr_flag = 1'b1;
			end
		end
		else if (sr_m == 3'b011 || sr_m == 3'b000) begin
			if (!cnt_a[0]) begin
				sr_n = {sr_a[6:0], cb2};
				if (cnt_a == 5'd0 && sr_m != 3'b000) sr_flag = 1'b1;
			end
		end
		cnt_n = {1'b0, cnt_a[3:0] - 4'd1};
	end
end

// ---- writes, and the reads that change something --------------------------------------
always_ff @(posedge clk) begin
	// the VIA's timers count all the time
	if (via_tick) begin
		t1 <= t1 - 16'd1;
		t2 <= t2 - 16'd1;
		if (t1_run) begin
			if (t1_left == 18'd1) begin
				via_ifr[6] <= 1'b1;                            // T1
				t1 <= {t1lh, t1ll};
				t1_left <= 18'({t1lh, t1ll}) + 18'd3;
				t1_run <= via_acr[6];                          // free-running, or once
			end
			else t1_left <= t1_left - 18'd1;
		end
		if (t2_run) begin
			if (t2_left == 18'd1) begin
				via_ifr[5] <= 1'b1;                            // T2
				t2_run <= 1'b0;
			end
			else t2_left <= t2_left - 18'd1;
		end
	end

	nv_rd_q <= sel & ~we & devs & (sub == 4'hF);
	if (sel) rdata_q <= rq;

	if (sel & ints & we) begin
		case (off[7:0])
			8'h24: int_mask <= bswap32(merge_be(bswap32(int_mask), wdata, be));
			8'h28: begin
				// with MACIO_INT_MODE in the mask, MACIO_INT_CLR clears everything
				if (int_mask[31] & wle[31]) int_events <= 32'h0;
				else int_events <= int_events & ~(wle & 32'h7FFF_FFFF);
			end
			default: ;
		endcase
	end

	// the sources' lines: an event at a rising edge, or at either edge in
	// 68k mode; in native mode a falling edge takes the event away
	// (set_irq_line, which MAME's devices call when a line changes). An edge
	// in the cycle of a clear is a new event and stays.
	for (int i = 0; i < 32; i++)
		if (int_chg[i]) int_events[i] <= int_68k | int_lines[i];
	int_lines_q <= int_lines;

	if (sel & dma & we & ch_ok) begin
		case (off[7:2])
			6'd0: begin
				// ChannelControl: the top half masks the bottom half
				// (dbdma.cpp:351-380): s0-s7, RUN and PAUSE as written; the
				// channel never runs, so ACTIVE stays clear
				ch_stat[ch][7:0] <= (ch_stat[ch][7:0] & ~wle[23:16]) | (wle[7:0] & wle[23:16]);
				if (wle[31]) ch_stat[ch][15] <= wle[15];
				if (wle[30]) ch_stat[ch][14] <= wle[14];
			end
			6'd3: ch_cmd[ch]  <= wle;
			6'd4: ch_isel[ch] <= wle;
			6'd5: ch_bsel[ch] <= wle;
			6'd6: ch_wsel[ch] <= wle;
			default: ;
		endcase
	end

	if (sel & devs) begin
		case (sub)
			4'h2, 4'h3: if (scc_cmd) begin
				if (~we) scc_ptr <= 4'd0;
				else if (scc_ptr == 4'd0) scc_ptr <= {wb[5:3] == 3'd1, wb[2:0]};   // "point high" adds 8
				else scc_ptr <= 4'd0;
			end
			4'h4: begin
				case (off[7:0])
					8'h00: if (we) snd_ctrl <= wle;
					8'h10: if (we) codec_ctrl <= wdata | {8'h0, wdata[15:14], 22'h0};
					8'h30: clip_count <= we ? wle : 32'h0;
					8'h40: if (we) byte_swap <= wdata != 32'h0;
					8'h50: if (we) frame_count <= wle;
					default: ;
				endcase
			end
			4'h6, 4'h7: begin
				case (via_reg)
					4'd0:        if (we) via_orb <= wb;
					4'd1, 4'd15: if (we) via_porta <= wb;
					4'd2:        if (we) via_ddrb <= wb;
					4'd3:        if (we) via_ddra <= wb;
					4'd4:        if (we) t1ll <= wb; else via_ifr[6] <= 1'b0;
					4'd5: if (we) begin
						t1lh <= wb;
						t1 <= {wb, t1ll};
						t1_left <= 18'({wb, t1ll}) + 18'd3;
						t1_run <= 1'b1;
						via_ifr[6] <= 1'b0;
					end
					4'd6:        if (we) t1ll <= wb;
					4'd7:        if (we) begin t1lh <= wb; via_ifr[6] <= 1'b0; end
					4'd8:        if (we) t2ll <= wb; else via_ifr[5] <= 1'b0;
					4'd9: if (we) begin
						t2 <= {wb, t2ll};
						t2_left <= 18'({wb, t2ll}) + 18'd3;
						t2_run <= 1'b1;
						via_ifr[5] <= 1'b0;
					end
					4'd10:       via_ifr[2] <= 1'b0;      // the register itself: sr_n

					4'd11: if (we) via_acr <= wb & 8'h5C;
					4'd12: if (we) via_pcr <= wb;
					4'd13: if (we) via_ifr[6:0] <= via_ifr[6:0] & ~wb[6:0];
					default: if (we) via_ier <= wb[7] ? (via_ier | {1'b0, wb[6:0]}) : (via_ier & ~wb);
				endcase
			end
			4'hD: if (we) nv_hi <= io_w;
			default: ;
		endcase
	end

	// the shift register, clocked by Cuda
	via_sr <= sr_n;
	sr_cnt <= cnt_n;
	cb2_q  <= cb2_n;
	cb1_q  <= cuda_cb1;
	if (sr_flag) via_ifr[2] <= 1'b1;

	if (reset) begin
		int_mask    <= 32'h0;
		int_events  <= 32'h0;
		int_lines_q <= 32'h0;
		for (int i = 0; i < NCH; i++) begin
			ch_stat[i] <= 16'h0;
			ch_cmd[i]  <= 32'h0;
			ch_isel[i] <= 32'h0;
			ch_bsel[i] <= 32'h0;
			ch_wsel[i] <= 32'h0;
		end
		scc_ptr     <= 4'd0;
		snd_ctrl    <= 32'h0;
		codec_ctrl  <= 32'h0;
		clip_count  <= 32'h0;
		frame_count <= 32'h0;
		byte_swap   <= 1'b0;
		via_orb     <= 8'h0;
		via_porta   <= 8'h0;
		sr_cnt      <= 5'd15;
		cb1_q       <= 1'b1;
		cb2_q       <= 1'b1;
		via_ddrb    <= 8'h0;
		via_ddra    <= 8'h0;
		via_sr      <= 8'h0;
		via_acr     <= 8'h0;
		via_pcr     <= 8'h0;
		via_ifr     <= 8'h0;
		via_ier     <= 8'h0;
		t1ll        <= 8'h0;
		t1lh        <= 8'h0;
		t2ll        <= 8'h0;
		t1          <= 16'h0;
		t2          <= 16'h0;
		t1_left     <= 18'h0;
		t2_left     <= 18'h0;
		t1_run      <= 1'b0;
		t2_run      <= 1'b0;
		nv_hi       <= 16'h0;
		nv_rd_q     <= 1'b0;
	end
end

endmodule
