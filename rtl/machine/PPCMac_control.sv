//============================================================================
//
//  PPCMac - the machine around the CPU
//  Control, the 7300/7600's video controller on Chaos: its registers, and
//  Swatch, its timing generator
//
//  PPCMac_control: the registers at Control's second BAR (4 KB; 512 bytes
//  repeated), as dingusppc's devices/video/control.cpp has them (lines
//  335-645): a register every 16 bytes ((offset >> 4) & 1F), little-endian
//  words, so the CPU's word is the register byte-swapped:
//
//    00  CUR_LINE       reads 0 (as dingusppc)
//    01-10  Swatch's sixteen timing values (12 bits; PIPE_DELAY 10, HEQ 8)
//    11  CNTTST         kept, reads 0
//    12  SWATCH_CTRL    11 bits; with DISABLE_TIMING (bit 10) changing the
//                       strobe count restarts; otherwise every second 0-to-1
//                       of RESET_TIMING (bit 3) switches the timing off (bit
//                       10 set) or on (clear) (control.cpp:564-585)
//    13  GBASE          the framebuffer's offset in VRAM, 32-byte aligned
//    14  ROW_WORDS      the framebuffer's pitch, 32-byte aligned
//    15  MON_SENSE      bits 5-3 the sense lines' directions (0 driven), 2-0
//                       their levels; reads give the monitor's answer in 8-6
//                       (displayid.cpp read_monitor_sense, AppleSense codes:
//                       mon_std and mon_ext, the machine's choice of monitor)
//    16  MISC_ENABLES   12 bits (0 progressive scan, 6 VRAM wide mode, ...)
//    17  GSC_DIVIDE     2 bits
//    18  REFRESH_COUNT  ignored, reads 0
//    19  INT_ENABLE     4 bits: 2 the VBL interrupt on, 3 a 1-to-0 clears it
//    1A  INT_STATUS     bit 2: in the vertical blanking (set when it starts,
//                       cleared when it ends or by INT_ENABLE's bit 3)
//
//  The interrupt (Grand Central's source 1A) is INT_STATUS's VBL bit while
//  INT_ENABLE's is set. The registers go to the video side as they stand:
//  the driver writes the timing while it is off.
//
//  PPCMac_swatch: the timing, in the video clock, one count every clk_div
//  dots (RaDACal's clock divisor) at the dot rate (ce_dot). The sixteen
//  values are what Linux's controlfb.c computes from a mode, and the 7300's
//  ROM's driver writes exactly those (640 x 480, 66.9 Hz: 864 x 525, sync
//  64 dots and 3 lines):
//
//    horizontal, in counts; a line is HPIX + 2 counts
//      HAL <= h < HFP          active
//      h >= HSP or h < HBWAY   sync
//    vertical, in half-lines (a progressive line is two); a frame is VHLINE
//      VAL <= v < VFP          active
//      v >= VSYNC or v < VBPEQ sync
//
//  Interlace (MISC_ENABLES bit 0 clear) is scanned as progressive.
//
//============================================================================

module PPCMac_control
(
	input  logic         clk,
	input  logic         reset,
	input  logic         sel,
	input  logic         we,
	input  logic [8:2]   addr,            // offset in the 512-byte register block
	input  logic [3:0]   be,
	input  logic [31:0]  wdata,
	output logic [31:0]  rdata,           // the cycle after sel
	output logic         irq,             // VBL, Grand Central's source 1A

	input  logic [2:0]   mon_std,         // the monitor's AppleSense codes
	input  logic [5:0]   mon_ext,

	// to the video side, standing still while the timing runs
	output logic [191:0] sw_params,       // value n (VFPEQ .. HSERR) in bits 12n+11 .. 12n
	output logic [21:0]  fb_base,
	output logic [14:0]  row_words,
	output logic [11:0]  enables,
	output logic         timing_on,
	output logic         hs_pos,          // SWATCH_CTRL's sync polarities: 1 positive
	output logic         vs_pos,

	// from the video side: toggles at the vertical blanking's start and end
	input  logic         vbl_start_tog,
	input  logic         vbl_end_tog
);

import PPCMac_pkg::*;

logic [11:0] params [16];
logic [10:0] swatch_ctrl;
logic [1:0]  strobes;
logic [11:0] cnt_tst;
logic [5:0]  mon_sense;
logic [2:0]  cur_mon_id;
logic [1:0]  gsc_divide;
logic [3:0]  int_enable;
logic        vbl;
logic [2:0]  vs_s, ve_s;                  // the toggles, synchronised; [2] as last seen

wire  [4:0]  rn  = addr[8:4];
wire  [3:0]  pn  = 4'(rn - 5'd1);         // the timing value, for registers 01-10
wire         is_param = (rn >= 5'h01) && (rn <= 5'h10);
wire  [31:0] wle = bswap32(wdata);        // the register's new value (whole words)

always_comb
	for (int i = 0; i < 16; i++) sw_params[12 * i +: 12] = params[i];

assign irq    = vbl & int_enable[2];
assign hs_pos = swatch_ctrl[6];
assign vs_pos = swatch_ctrl[2];

// MON_SENSE: what the monitor answers for the lines as driven
// (displayid.cpp read_monitor_sense, the AppleSense case)
function automatic logic [2:0] sense(input logic [2:0] dirs, input logic [2:0] levels);
	case ({dirs, levels})
		6'b100_011: sense = {1'b0, mon_ext[5:4]};
		6'b010_101: sense = {mon_ext[3], 1'b0, mon_ext[2]};
		6'b001_110: sense = {mon_ext[1:0], 1'b0};
		default:    sense = mon_std;
	endcase
endfunction

wire [2:0] w_dirs   = wle[5:3] ^ 3'b111;
wire [2:0] w_levels = (wle[2:0] & w_dirs) | (w_dirs ^ 3'b111);

// what a read returns, as the register
logic [31:0] v;
always_comb begin
	v = 32'h0;
	case (rn)
		5'h00:   v = 32'h0;
		5'h11:   v = 32'h0;
		5'h12:   v = {21'h0, swatch_ctrl};
		5'h13:   v = {10'h0, fb_base};
		5'h14:   v = {17'h0, row_words};
		5'h15:   v = {23'h0, cur_mon_id, mon_sense};
		5'h16:   v = {20'h0, enables};
		5'h17:   v = {30'h0, gsc_divide};
		5'h18:   v = 32'h0;
		5'h19:   v = {28'h0, int_enable};
		5'h1A:   v = {29'h0, vbl, 2'b00};
		default: v = is_param ? {20'h0, params[pn]} : 32'h0;
	endcase
end

always_ff @(posedge clk) begin
	if (sel) rdata <= bswap32(v);

	vs_s <= {vs_s[1:0], vbl_start_tog};
	ve_s <= {ve_s[1:0], vbl_end_tog};
	if (vs_s[2] != vs_s[1]) vbl <= 1'b1;
	if (ve_s[2] != ve_s[1]) vbl <= 1'b0;

	if (sel & we) begin
		case (rn)
			5'h08:   params[7]  <= {2'b00, wle[9:0]};       // PIPE_DELAY: 10 bits
			5'h0E:   params[13] <= {4'h0, wle[7:0]};        // HEQ: 8 bits
			5'h11:   cnt_tst <= wle[11:0];
			5'h12: begin
				if ((swatch_ctrl[10] ^ wle[10]) == 1'b1) begin
					swatch_ctrl <= wle[10:0];
					strobes     <= 2'd0;
				end
				else if ((swatch_ctrl[3] ^ wle[3]) == 1'b1) begin
					swatch_ctrl <= wle[10:0];
					if (wle[3]) begin
						if (strobes != 2'd2) strobes <= strobes + 2'd1;
						if (strobes != 2'd0) timing_on <= ~wle[10];
					end
				end
				else swatch_ctrl <= wle[10:0];
			end
			5'h13:   fb_base   <= {wle[21:5], 5'h0};
			5'h14:   row_words <= {wle[14:5], 5'h0};
			5'h15: begin
				mon_sense  <= wle[5:0];
				cur_mon_id <= sense(w_dirs, w_levels);
			end
			5'h16:   enables    <= wle[11:0];
			5'h17:   gsc_divide <= wle[1:0];
			5'h19: begin
				if (int_enable[3] & ~wle[3]) vbl <= 1'b0;
				int_enable <= wle[3:0];
			end
			default:
				if (is_param) params[pn] <= wle[11:0];
		endcase
	end

	if (reset) begin
		for (int i = 0; i < 16; i++) params[i] <= 12'h0;
		swatch_ctrl <= 11'h0;
		strobes     <= 2'd0;
		timing_on   <= 1'b0;
		cnt_tst     <= 12'h0;
		fb_base     <= 22'h0;
		row_words   <= 15'h0;
		mon_sense   <= 6'h0;
		cur_mon_id  <= 3'd0;
		enables     <= 12'h0;
		gsc_divide  <= 2'd0;
		int_enable  <= 4'h0;
		vbl         <= 1'b0;
		vs_s        <= 3'b000;
		ve_s        <= 3'b000;
	end
end

endmodule


module PPCMac_swatch
(
	input  logic         clk_v,           // the video clock
	input  logic         timing_on,       // from the CPU's clock
	input  logic [191:0] sw_params,       // standing still while the timing runs
	input  logic [3:0]   clk_div,         // dots per count: 1, 2, 4 or 8
	input  logic         hs_pos,          // sync polarities: 1 positive
	input  logic         vs_pos,
	input  logic         ce_dot,          // one clock of the video clock at the dot rate

	output logic         ce_pix,          // the dot this cycle is a pixel position
	output logic         hs,
	output logic         vs,
	output logic         hblank,
	output logic         vblank,
	output logic [11:0]  x,               // the dot in the active line
	output logic [10:0]  y,               // the active line
	output logic         fetch,           // a line starts: fetch the next active one
	output logic [10:0]  fetch_y,
	output logic         vbl_start_tog,
	output logic         vbl_end_tog
);

logic [1:0]  on_s;
wire         run = on_s[1];

wire [11:0] VBPEQ = sw_params[12 * 4 +: 12];
wire [11:0] VFP   = sw_params[12 * 1 +: 12];
wire [11:0] VAL   = sw_params[12 * 2 +: 12];
wire [11:0] VSYNC = sw_params[12 * 5 +: 12];
wire [11:0] VHL   = sw_params[12 * 6 +: 12];
wire [11:0] HPIX  = sw_params[12 * 8 +: 12];
wire [11:0] HFP   = sw_params[12 * 9 +: 12];
wire [11:0] HAL   = sw_params[12 * 10 +: 12];
wire [11:0] HBWAY = sw_params[12 * 11 +: 12];
wire [11:0] HSP   = sw_params[12 * 12 +: 12];

logic [2:0]  sub;                         // the dot within the count
logic [11:0] h, v;
logic [11:0] xa;                          // the active line's dot, counted up

wire [11:0] v_next  = (v + 12'd2 >= VHL) ? 12'd0 : v + 12'd2;
wire        last_d  = ({1'b0, sub} == clk_div - 4'd1);
wire        last_h  = h >= HPIX + 12'd1;
wire        v2_act  = (v_next >= VAL) && (v_next < VFP);

always_ff @(posedge clk_v) begin
	on_s   <= {on_s[0], timing_on};
	ce_pix <= 1'b0;
	fetch  <= 1'b0;

	if (!run) begin
		sub    <= 3'd0;
		h      <= 12'd0;
		v      <= 12'd0;
		xa     <= 12'd0;
		hs     <= ~hs_pos;
		vs     <= ~vs_pos;
		hblank <= 1'b1;
		vblank <= 1'b1;
	end
	else if (ce_dot) begin
		ce_pix <= 1'b1;
		// the outputs for the dot at (h, v, sub)
		hblank <= ~((h >= HAL) && (h < HFP));
		vblank <= ~((v >= VAL) && (v < VFP));
		hs     <= ((h >= HSP) || (h < HBWAY)) ? hs_pos : ~hs_pos;
		vs     <= ((v >= VSYNC) || (v < VBPEQ)) ? vs_pos : ~vs_pos;
		x      <= xa;
		y      <= 11'((v - VAL) >> 1);
		if ((h >= HAL) && (h < HFP)) xa <= xa + 12'd1;

		// the next dot
		if (!last_d) sub <= sub + 3'd1;
		else begin
			sub <= 3'd0;
			if (!last_h) h <= h + 12'd1;
			else begin
				h  <= 12'd0;
				xa <= 12'd0;
				v  <= v_next;
				if (v_next == VFP) vbl_start_tog <= ~vbl_start_tog;
				if (v_next == VAL) vbl_end_tog   <= ~vbl_end_tog;
			end
		end
		// a line starts: fetch the line after it if that one is active
		if (h == 12'd0 && sub == 3'd0) begin
			fetch   <= v2_act;
			fetch_y <= 11'((v_next - VAL) >> 1);
		end
	end
end

initial begin
	vbl_start_tog = 1'b0;
	vbl_end_tog   = 1'b0;
	on_s          = 2'b00;
end

endmodule
