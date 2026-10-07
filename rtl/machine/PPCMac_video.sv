//============================================================================
//
//  PPCMac - the machine around the CPU
//  The Control video's picture side, in the video clock (the memory clock):
//  the VRAM in DDR3, the dot clock, Swatch's timing, the scan-out
//
//  The VRAM (4 MB: Control's standard and optional banks) is DDR3 at
//  DDR_BASE, through the framework's DDRAM port (Avalon: a read is RD with a
//  burst count, the data coming back with DOUT_READY; a write is WE with
//  data on every beat; BUSY holds everything). Two users, the scan-out
//  first:
//
//    - the scan-out: at the start of every line, the next active line, from
//      16 bytes before its first pixel (the hardware cursor's data) to its
//      last, in bursts of up to 128 words, into one of two line buffers;
//    - the CPU, through its clock crossing (PPCMac_machine has already
//      turned the access into a VRAM byte address and the bytes into VRAM's
//      order): a word (one beat, with byte enables) or a 32-byte line (four,
//      from the line's first byte whatever word the address names: the
//      CPU's cache asks for a line with the address of the word it misses).
//
//  A VRAM byte at address a sits in DDR3 word a >> 3, byte lane a & 7.
//
//  The dot clock: Athens's (PPCMac_athens): 31.3344 MHz x N2 / (D2 x 2^(3 -
//  P2_MUX2[1:0])), or the crystal / 2^(...) with P2_MUX2[5:4] = 2, as a
//  clock enable of the video clock by phase accumulation (at most every
//  clock). PPCMac_swatch counts it.
//
//  The scan-out follows dingusppc's VideoCtrlBase and ControlVideo (control.cpp
//  enable_display and update_fb_ptr; videoctrl.cpp's converters;
//  appleramdac.cpp draw_hw_cursor):
//
//    - the first pixel of line y is at GBASE + y x ROW_WORDS, plus 16 (the
//      cursor's 16 bytes come first) unless HAL = PIPE_DELAY + 1 and the
//      pixels are not 32 bits, plus 2 MB when RaDACal's double-buffer
//      control is 0 (the optional bank);
//    - 8 bits a pixel through RaDACal's colour table; 16 bits as x-R5-G5-B5,
//      each component c widened to {c, c[4:2]}; 32 bits as x-R-G-B (no
//      colour table in the direct modes, as dingusppc);
//    - the hardware cursor (MISC_CTRL bit 1): 32 pixels of 4 bits from the
//      16 bytes before the line's first pixel, at RaDACal's cursor position:
//      bit 3 set, the cursor colour (bits 2-0); else bit 0 set, each
//      component 0 where it was 80 or more, FF where it was less.
//
//============================================================================

module PPCMac_video
#(
	parameter int unsigned CLKV_HZ  = 100_000_000,
	parameter logic [28:0] DDR_BASE = 29'h0600_0000     // byte 3000_0000, in 64-bit words
)
(
	input  logic         clk,             // the video clock: the memory clock
	input  logic         reset,

	// the CPU's VRAM accesses, from their clock crossing (the CPU port's protocol)
	input  logic         c_req,
	input  logic         c_we,
	input  logic         c_line,
	input  logic [21:2]  c_addr,          // VRAM byte address
	input  logic [3:0]   c_be,
	input  logic [255:0] c_wdata,
	output logic         c_ack,
	output logic [255:0] c_rdata,

	// DDR3, the framework's DDRAM port
	input  logic         ddr_busy,
	output logic [7:0]   ddr_burstcnt,
	output logic [28:0]  ddr_addr,
	input  logic [63:0]  ddr_dout,
	input  logic         ddr_dout_ready,
	output logic         ddr_rd,
	output logic [63:0]  ddr_din,
	output logic [7:0]   ddr_be,
	output logic         ddr_we,

	// the machine's video registers, from the CPU's clock
	input  logic         timing_on,
	input  logic [191:0] sw_params,
	input  logic [21:0]  fb_base,
	input  logic [14:0]  row_words,
	input  logic         hs_pos,
	input  logic         vs_pos,
	input  logic [7:0]   dac_cr,
	input  logic [7:0]   dbl_buf_cr,
	input  logic [15:0]  cursor_x,
	input  logic [191:0] cursor_clut,
	input  logic [7:0]   athens_d2,
	input  logic [7:0]   athens_n2,
	input  logic [7:0]   athens_p2,
	output logic         vbl_start_tog,
	output logic         vbl_end_tog,
	output logic [7:0]   clut_index,      // RaDACal's colour table, read a clock later
	input  logic [23:0]  clut_rgb,

	// the picture
	output logic         ce_pix,
	output logic [7:0]   r,
	output logic [7:0]   g,
	output logic [7:0]   b,
	output logic         hs,
	output logic         vs,
	output logic         hblank,
	output logic         vblank
);

// ---- the video registers, taken over loosely: they stand still while used -------------------
logic [191:0] prm;
logic [21:0]  fbb;
logic [14:0]  roww;
logic [7:0]   dcr, dbl;
logic [15:0]  cx;
logic [191:0] cclut;
logic [7:0]   ad2, an2, ap2;
logic         hsp, vsp;
always_ff @(posedge clk) begin
	prm <= sw_params; fbb <= fb_base; roww <= row_words; dcr <= dac_cr; dbl <= dbl_buf_cr;
	cx <= cursor_x; cclut <= cursor_clut; ad2 <= athens_d2; an2 <= athens_n2; ap2 <= athens_p2;
	hsp <= hs_pos; vsp <= vs_pos;
end

wire [11:0] PIPE = prm[12 * 7 +: 12];
wire [11:0] HFP  = prm[12 * 9 +: 12];
wire [11:0] HAL  = prm[12 * 10 +: 12];
wire [3:0]  clk_div = (dcr[7:6] == 2'd3) ? 4'd1 : (4'd2 << dcr[7:6]);
wire [1:0]  pw      = dcr[3:2];              // 0: 8 bits, 1: 16, 2 and up: 32

// ---- the dot clock ---------------------------------------------------------------------------
localparam longint unsigned XTAL = 31_334_400;
logic [39:0] numer, denom, acc;
logic        dot_off, ce_dot;
wire  [40:0] acc_n = {1'b0, acc} + {1'b0, numer};
wire  [7:0]  d_eff = (ap2[5:4] == 2'd2) ? 8'd1 : ad2;
always_ff @(posedge clk) begin
	// the dot rate is numer / denom of the video clock
	numer   <= (ap2[5:4] == 2'd2) ? 40'(XTAL) : 40'(an2) * 40'(XTAL);
	denom   <= (40'(d_eff) * 40'(CLKV_HZ)) << (2'd3 - ap2[1:0]);
	dot_off <= ap2[7] | ap2[4] | (ap2[5:4] == 2'd0 && (ad2 == 8'd0 || an2 == 8'd0));
	ce_dot  <= 1'b0;
	if (dot_off) acc <= 40'd0;
	else if (numer >= denom) begin acc <= 40'd0; ce_dot <= 1'b1; end
	else if (acc_n >= {1'b0, denom}) begin acc <= 40'(acc_n - {1'b0, denom}); ce_dot <= 1'b1; end
	else acc <= acc_n[39:0];
	if (reset) begin acc <= 40'd0; ce_dot <= 1'b0; end
end

// ---- Swatch -----------------------------------------------------------------------------------
logic        s_ce, s_hs, s_vs, s_hb, s_vb, fetch;
logic [11:0] s_x;
logic [10:0] s_y, fetch_y;

PPCMac_swatch swatch (
	.clk_v(clk), .timing_on, .sw_params(prm), .clk_div, .hs_pos(hsp), .vs_pos(vsp), .ce_dot,
	.ce_pix(s_ce), .hs(s_hs), .vs(s_vs), .hblank(s_hb), .vblank(s_vb), .x(s_x), .y(s_y),
	.fetch, .fetch_y, .vbl_start_tog, .vbl_end_tog
);

// ---- the line fetch ----------------------------------------------------------------------------
wire [11:0] width  = 12'((HFP - HAL) * {8'd0, clk_div});
wire        plus16 = (HAL != PIPE + 12'd1) || (pw >= 2'd2);
// bytes from the cursor's data to the line's last pixel, in 64-bit words
wire [14:0] lpix   = (pw == 2'd0) ? {3'd0, width} : (pw == 2'd1) ? {2'd0, width, 1'b0} : {1'd0, width, 2'b00};
wire [14:0] lbytes = lpix + 15'd23;          // 16 of the cursor's, and 7 to round up
wire [11:0] lwords = 12'(lbytes >> 3);
// where the cursor's data starts, from GBASE + y x ROW_WORDS: the optional
// bank when double-buffer control is 0, and 16 less when the pixels do not
// start 16 bytes in
logic [21:0] f_adj;
always_comb begin
	case ({dbl == 8'h00, plus16})
		2'b00:   f_adj = 22'h3F_FFF0;               // -16
		2'b01:   f_adj = 22'h00_0000;
		2'b10:   f_adj = 22'h1F_FFF0;               // 2 MB - 16
		default: f_adj = 22'h20_0000;
	endcase
end

typedef enum logic [2:0] {D_IDLE, D_FREAD, D_FWAIT, D_CREAD, D_CWAIT, D_CWRITE} ds_t;
ds_t         ds;
logic        f_pend;                   // a line is being fetched
logic        f_calc;                   // its address is being made
logic [21:0] f_line;                   // GBASE + y x ROW_WORDS
logic [21:0] f_addr;                   // the next byte to ask for
logic [11:0] f_left;                   // words still to ask for
logic [11:0] f_put;                    // where the next word goes
logic        f_bank;
logic [7:0]  f_burst;                  // the burst asked for
logic [7:0]  f_due;                    // its words still to come
logic        f_issue;
wire         f_word = (ds == D_FWAIT) && ddr_dout_ready;
wire  [7:0]  f_next = (f_left > 12'd128) ? 8'd128 : 8'(f_left);

always_ff @(posedge clk) begin
	f_calc <= 1'b0;
	if (fetch) begin
		f_line <= fbb + 22'(fetch_y * roww);
		f_bank <= fetch_y[0];
		f_calc <= 1'b1;
	end
	if (f_calc) begin
		f_addr <= f_line + f_adj;
		f_left <= lwords;
		f_put  <= 12'd0;
		f_pend <= 1'b1;
	end
	else if (f_issue) begin
		f_addr <= f_addr + {11'd0, f_burst, 3'b000};
		f_left <= f_left - {4'd0, f_burst};
		if (f_left == {4'd0, f_burst}) f_pend <= 1'b0;
	end
	if (f_word) f_put <= f_put + 12'd1;
	if (reset) f_pend <= 1'b0;
end

// ---- the line buffers: two lines of up to 1024 words; each line's cursor data in registers ---------
logic [63:0]  lbuf [0:2047];
logic [63:0]  lb_q;
logic [10:0]  lb_ra;
logic [127:0] cur0, cur1;
always_ff @(posedge clk) begin
	if (f_word) lbuf[{f_bank, f_put[9:0]}] <= ddr_dout;
	lb_q <= lbuf[lb_ra];
	if (f_word && f_put == 12'd0 && !f_bank) cur0[63:0]   <= ddr_dout;
	if (f_word && f_put == 12'd1 && !f_bank) cur0[127:64] <= ddr_dout;
	if (f_word && f_put == 12'd0 &&  f_bank) cur1[63:0]   <= ddr_dout;
	if (f_word && f_put == 12'd1 &&  f_bank) cur1[127:64] <= ddr_dout;
end

// ---- DDR3: the scan-out first, then the CPU ---------------------------------------------------------
logic [2:0]  c_beat;                   // CPU beats done
logic [63:0] c_got0, c_got1, c_got2, c_got3;
wire  [2:0]  c_n = c_line ? 3'd4 : 3'd1;

// a CPU word as one beat: its four bytes in lanes (addr & 4) .. +3, VRAM's order
wire [31:0] c_w0     = c_wdata[31:0];
wire [63:0] c_word64 = c_addr[2] ? {c_w0[7:0], c_w0[15:8], c_w0[23:16], c_w0[31:24], 32'h0}
                                 : {32'h0, c_w0[7:0], c_w0[15:8], c_w0[23:16], c_w0[31:24]};
wire [7:0]  c_be8    = c_addr[2] ? {c_be[0], c_be[1], c_be[2], c_be[3], 4'h0} : {4'h0, c_be[0], c_be[1], c_be[2], c_be[3]};
// a line's beat k: words 2k and 2k + 1, each in lanes in VRAM's order
function automatic logic [63:0] line_beat(input logic [255:0] w, input logic [1:0] k);
	logic [31:0] w0, w1;
	w0 = w[255 - 64 * k -: 32];
	w1 = w[223 - 64 * k -: 32];
	line_beat = {w1[7:0], w1[15:8], w1[23:16], w1[31:24], w0[7:0], w0[15:8], w0[23:16], w0[31:24]};
endfunction
function automatic logic [31:0] lane_word(input logic [63:0] q, input logic hi);
	lane_word = hi ? {q[39:32], q[47:40], q[55:48], q[63:56]} : {q[7:0], q[15:8], q[23:16], q[31:24]};
endfunction

always_ff @(posedge clk) begin
	f_issue <= 1'b0;
	c_ack   <= 1'b0;
	case (ds)
		D_IDLE: begin
			ddr_rd <= 1'b0;
			ddr_we <= 1'b0;
			if (f_pend && !f_issue && !f_calc) begin
				f_burst      <= f_next;
				ddr_addr     <= DDR_BASE + {10'd0, f_addr[21:3]};
				ddr_burstcnt <= f_next;
				ddr_rd       <= 1'b1;
				ds           <= D_FREAD;
			end
			else if (c_req && !c_ack) begin
				// a line from its first word: the CPU's cache asks for a line
				// with the address of the word it wants (bits 4-2 not 0)
				ddr_addr     <= DDR_BASE + {10'd0, c_addr[21:5], c_line ? 2'b00 : c_addr[4:3]};
				ddr_burstcnt <= {5'd0, c_n};
				c_beat       <= 3'd0;
				if (c_we) begin
					ddr_we  <= 1'b1;
					ddr_din <= c_line ? line_beat(c_wdata, 2'd0) : c_word64;
					ddr_be  <= c_line ? 8'hFF : c_be8;
					ds      <= D_CWRITE;
				end
				else begin
					ddr_rd <= 1'b1;
					ds     <= D_CREAD;
				end
			end
		end
		D_FREAD: if (!ddr_busy) begin
			ddr_rd  <= 1'b0;
			f_issue <= 1'b1;
			f_due   <= f_burst;
			ds      <= D_FWAIT;
		end
		D_FWAIT: if (ddr_dout_ready) begin
			f_due <= f_due - 8'd1;
			if (f_due == 8'd1) ds <= D_IDLE;
		end
		D_CREAD: if (!ddr_busy) begin
			ddr_rd <= 1'b0;
			ds     <= D_CWAIT;
		end
		D_CWAIT: if (ddr_dout_ready) begin
			case (c_beat[1:0])
				2'd0:    c_got0 <= ddr_dout;
				2'd1:    c_got1 <= ddr_dout;
				2'd2:    c_got2 <= ddr_dout;
				default: c_got3 <= ddr_dout;
			endcase
			c_beat <= c_beat + 3'd1;
			if (c_beat + 3'd1 == c_n) begin
				c_ack <= 1'b1;
				ds    <= D_IDLE;
			end
		end
		D_CWRITE: if (!ddr_busy) begin
			if (c_beat + 3'd1 == c_n) begin
				ddr_we <= 1'b0;
				c_ack  <= 1'b1;
				ds     <= D_IDLE;
			end
			else begin
				c_beat  <= c_beat + 3'd1;
				ddr_din <= line_beat(c_wdata, 2'(c_beat + 3'd1));
			end
		end
		default: ds <= D_IDLE;
	endcase
	if (reset) begin
		ds     <= D_IDLE;
		ddr_rd <= 1'b0;
		ddr_we <= 1'b0;
	end
end

// what a CPU read gets: the beats in the CPU's order; a word in bits 31-0
always_comb begin
	if (c_line)
		c_rdata = {lane_word(c_got0, 1'b0), lane_word(c_got0, 1'b1), lane_word(c_got1, 1'b0), lane_word(c_got1, 1'b1),
		           lane_word(c_got2, 1'b0), lane_word(c_got2, 1'b1), lane_word(c_got3, 1'b0), lane_word(c_got3, 1'b1)};
	else
		c_rdata = {224'h0, lane_word(c_got0, c_addr[2])};
end

// ---- the pixels ----------------------------------------------------------------------------------------
// stage 0, Swatch's dot (s_*): its word in the line buffer, 16 + x x bytes a pixel in
wire [14:0] p_byte = 15'd16 + ((pw == 2'd0) ? {3'd0, s_x} : (pw == 2'd1) ? {2'd0, s_x, 1'b0} : {1'd0, s_x, 2'b00});
assign lb_ra = {s_y[0], p_byte[12:3]};

// stage 1: the word comes out of the line buffer
logic        p1_ce, p1_de, p1_hs, p1_vs, p1_hb, p1_vb, p1_bank;
logic [2:0]  p1_lane;
logic [11:0] p1_x;
logic [7:0]  pix8;
logic [15:0] pix16;
logic [23:0] pix32;
always_comb begin
	pix8  = lb_q[8 * p1_lane +: 8];
	pix16 = {lb_q[8 * p1_lane +: 8], lb_q[8 * 3'(p1_lane + 3'd1) +: 8]};
	pix32 = {lb_q[8 * 3'(p1_lane + 3'd1) +: 8], lb_q[8 * 3'(p1_lane + 3'd2) +: 8], lb_q[8 * 3'(p1_lane + 3'd3) +: 8]};
end
// the cursor's pixel there: nibble (x - cursor x) of the line's 16 bytes, high nibble first
wire [127:0] cur_w  = p1_bank ? cur1 : cur0;
wire [12:0]  c_rel  = {1'b0, p1_x} - {1'b0, cx[11:0]};
wire         c_in   = dcr[1] && ({1'b0, p1_x} >= {1'b0, cx[11:0]}) && (c_rel < 13'd32);
wire [7:0]   c_byte = cur_w[8 * c_rel[4:1] +: 8];
wire [3:0]   c_nib  = c_rel[0] ? c_byte[3:0] : c_byte[7:4];

// stage 2: the pixel's colour, or its index going to the colour table
logic        p2_ce, p2_de, p2_hs, p2_vs, p2_hb, p2_vb, p2_idx;
logic [23:0] p2_rgb;
logic [3:0]  p2_cur;
// stage 3: the colour table answers
logic        p3_ce, p3_de, p3_hs, p3_vs, p3_hb, p3_vb, p3_idx;
logic [23:0] p3_rgb;
logic [3:0]  p3_cur;
logic [23:0] p3_c, p3_out;
always_comb begin
	p3_c = p3_idx ? clut_rgb : p3_rgb;
	if (p3_cur[3])      p3_out = cclut[24 * p3_cur[2:0] +: 24];
	else if (p3_cur[0]) p3_out = {p3_c[23] ? 8'h00 : 8'hFF, p3_c[15] ? 8'h00 : 8'hFF, p3_c[7] ? 8'h00 : 8'hFF};
	else                p3_out = p3_c;
	if (!p3_de) p3_out = 24'h0;
end

always_ff @(posedge clk) begin
	p1_ce   <= s_ce;
	p1_de   <= ~s_hb & ~s_vb;
	p1_hs   <= s_hs;
	p1_vs   <= s_vs;
	p1_hb   <= s_hb;
	p1_vb   <= s_vb;
	p1_bank <= s_y[0];
	p1_lane <= p_byte[2:0];
	p1_x    <= s_x;

	p2_ce      <= p1_ce;
	p2_de      <= p1_de;
	p2_hs      <= p1_hs;
	p2_vs      <= p1_vs;
	p2_hb      <= p1_hb;
	p2_vb      <= p1_vb;
	p2_idx     <= pw == 2'd0;
	p2_rgb     <= (pw == 2'd1) ? {pix16[14:10], pix16[14:12], pix16[9:5], pix16[9:7], pix16[4:0], pix16[4:2]} : pix32;
	p2_cur     <= c_in ? c_nib : 4'h0;
	clut_index <= pix8;

	p3_ce  <= p2_ce;
	p3_de  <= p2_de;
	p3_hs  <= p2_hs;
	p3_vs  <= p2_vs;
	p3_hb  <= p2_hb;
	p3_vb  <= p2_vb;
	p3_idx <= p2_idx;
	p3_rgb <= p2_rgb;
	p3_cur <= p2_cur;

	{r, g, b} <= p3_out;
	ce_pix    <= p3_ce;
	hs        <= p3_hs;
	vs        <= p3_vs;
	hblank    <= p3_hb;
	vblank    <= p3_vb;
end

endmodule
