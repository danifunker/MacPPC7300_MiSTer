//============================================================================
//
//  PPCMac - the machine around the CPU
//  The ADB devices on Cuda's ADB line: a keyboard (address 2) and a mouse
//  (address 3), from the MiSTer's PS/2 keyboard and mouse
//
//  Cuda's firmware bit-banges the line (PPCMac_cuda's adb_low); these
//  devices decode its commands and answer on the same wire, at the wire
//  level, as the Mac LC core's adb_device.sv does (its structure and its
//  PS/2 table), with the devices' registers as dingusppc has them
//  (devices/common/adb/adbdevice.cpp, adbkeyboard.cpp, adbmouse.cpp):
//
//    keyboard  handler 2 (Apple Extended Keyboard); 1 and 2 may be set,
//              3 (left and right modifiers apart) is refused; Talk 0 gives
//              two key events (the second FF when there is one), Talk 2 the
//              modifier keys and the LEDs, Listen 2 sets the LEDs
//    mouse     handler 1 (100 counts an inch); 1 and 2 may be set (the
//              Apple Mouse II's; not the extended protocol, 4); Talk 0
//              gives the button and the movement since the last report,
//              clamped to 7 bits a report (the rest comes next time), only
//              when there is something to report
//    both      Talk 3 gives {0, exceptional event 1, SRQ enable, 0, address}
//              and the handler; Listen 3 with handler 00 moves the device
//              and sets its SRQ enable, with FE moves it; SendReset (and a
//              reset pulse on the line) restores them; Flush empties the
//              device's queue
//
//  The line, in the ADB's own timing (Cuda's firmware: attention 800 us,
//  bit cells 100 us, "0" 65 us low then 35 high, "1" 35 low then 65 high):
//  a command is attention, sync, eight bits and a stop bit; a device with
//  something to say while the command is for another device asks for
//  service by holding the stop bit low to 300 us (SRQ); a Talk is answered
//  160 us after the stop bit (Tlt) with a start bit "1", the bytes and a
//  stop bit "0"; a Listen's data follows the same framing from Cuda. The
//  firmware's receive (PPCMac_cuda's notes) waits 283 us for the start bit
//  and 79 us at most for any low.
//
//  Time is counted in Cuda's own 4,194,304 Hz ticks (PPCMac_cuda's tick), so
//  it keeps step with the firmware also while the test bench runs Cuda fast.
//  The command is decoded from Cuda's drive alone, not the wire, so the
//  devices' own pulses never read as commands.
//
//  The PS/2 inputs are hps_io's, from another clock: ps2_key[10] and
//  ps2_mouse[24] toggle once an event, its data steady long before, and are
//  synchronised here.
//
//============================================================================

module PPCMac_adb
(
	input  logic        clk,
	input  logic        reset,
	input  logic        tick,            // Cuda's 4,194,304 Hz time base
	input  logic        host_low,        // Cuda pulls the line low
	output logic        dev_low,         // a device pulls the line low

	input  logic [10:0] ps2_key,         // [10] toggles, [9] pressed, [8] extended, [7:0] the code
	input  logic [24:0] ps2_mouse        // [24] toggles, [23:16] Y, [15:8] X, [5] Y sign, [4] X sign, [0] left button
);

// ---- timing, in 4,194,304 Hz ticks ----------------------------------------------------------
localparam logic [13:0] T_ATTN  = 14'd1678;   // a low longer than 400 us is an attention
localparam logic [13:0] T_RESET = 14'd8389;   // longer than 2 ms, a reset (3 ms)
localparam logic [13:0] T_BIT   = 14'd210;    // a high longer than 50 us ends a "1"
localparam logic [13:0] D_SHORT = 14'd147;    // 35 us
localparam logic [13:0] D_LONG  = 14'd273;    // 65 us
localparam logic [13:0] D_TLT   = 14'd671;    // 160 us from the stop bit to the answer (Cuda waits 283 us)
localparam logic [13:0] D_SRQ   = 14'd1258;   // 300 us: the stop bit held low

localparam logic [3:0] ADDR_KBD = 4'd2, ADDR_MOUSE = 4'd3;

// ---- the PS/2 keyboard: scan code set 2 to ADB key codes (7F: none) -------------------------
// The Mac LC core's table (from lbmactwo_MiSTer's adb.sv): Alt is Command,
// the Windows keys Option; the right-hand modifiers give the left-hand codes,
// as the keyboard does with handlers 1 and 2 (dingusppc likewise).
function automatic logic [6:0] adb_code(input logic [8:0] sc);
	case (sc)
		9'h001: adb_code = 7'h65;   // F9
		9'h003: adb_code = 7'h60;   // F5
		9'h004: adb_code = 7'h63;   // F3
		9'h005: adb_code = 7'h7A;   // F1
		9'h006: adb_code = 7'h78;   // F2
		9'h007: adb_code = 7'h6F;   // F12
		9'h009: adb_code = 7'h6D;   // F10
		9'h00A: adb_code = 7'h64;   // F8
		9'h00B: adb_code = 7'h61;   // F6
		9'h00C: adb_code = 7'h76;   // F4
		9'h00D: adb_code = 7'h30;   // Tab
		9'h00E: adb_code = 7'h32;   // `
		9'h011: adb_code = 7'h37;   // left Alt: Command
		9'h012: adb_code = 7'h38;   // left Shift
		9'h014: adb_code = 7'h36;   // left Control
		9'h015: adb_code = 7'h0C;   // Q
		9'h016: adb_code = 7'h12;   // 1
		9'h01A: adb_code = 7'h06;   // Z
		9'h01B: adb_code = 7'h01;   // S
		9'h01C: adb_code = 7'h00;   // A
		9'h01D: adb_code = 7'h0D;   // W
		9'h01E: adb_code = 7'h13;   // 2
		9'h021: adb_code = 7'h08;   // C
		9'h022: adb_code = 7'h07;   // X
		9'h023: adb_code = 7'h02;   // D
		9'h024: adb_code = 7'h0E;   // E
		9'h025: adb_code = 7'h15;   // 4
		9'h026: adb_code = 7'h14;   // 3
		9'h029: adb_code = 7'h31;   // Space
		9'h02A: adb_code = 7'h09;   // V
		9'h02B: adb_code = 7'h03;   // F
		9'h02C: adb_code = 7'h11;   // T
		9'h02D: adb_code = 7'h0F;   // R
		9'h02E: adb_code = 7'h17;   // 5
		9'h031: adb_code = 7'h2D;   // N
		9'h032: adb_code = 7'h0B;   // B
		9'h033: adb_code = 7'h04;   // H
		9'h034: adb_code = 7'h05;   // G
		9'h035: adb_code = 7'h10;   // Y
		9'h036: adb_code = 7'h16;   // 6
		9'h03A: adb_code = 7'h2E;   // M
		9'h03B: adb_code = 7'h26;   // J
		9'h03C: adb_code = 7'h20;   // U
		9'h03D: adb_code = 7'h1A;   // 7
		9'h03E: adb_code = 7'h1C;   // 8
		9'h041: adb_code = 7'h2B;   // ,
		9'h042: adb_code = 7'h28;   // K
		9'h043: adb_code = 7'h22;   // I
		9'h044: adb_code = 7'h1F;   // O
		9'h045: adb_code = 7'h1D;   // 0
		9'h046: adb_code = 7'h19;   // 9
		9'h049: adb_code = 7'h2F;   // .
		9'h04A: adb_code = 7'h2C;   // /
		9'h04B: adb_code = 7'h25;   // L
		9'h04C: adb_code = 7'h29;   // ;
		9'h04D: adb_code = 7'h23;   // P
		9'h04E: adb_code = 7'h1B;   // -
		9'h052: adb_code = 7'h27;   // '
		9'h054: adb_code = 7'h21;   // [
		9'h055: adb_code = 7'h18;   // =
		9'h058: adb_code = 7'h39;   // Caps Lock
		9'h059: adb_code = 7'h38;   // right Shift
		9'h05A: adb_code = 7'h24;   // Return
		9'h05B: adb_code = 7'h1E;   // ]
		9'h05D: adb_code = 7'h2A;   // backslash
		9'h066: adb_code = 7'h33;   // Backspace: Delete
		9'h069: adb_code = 7'h53;   // keypad 1
		9'h06B: adb_code = 7'h56;   // keypad 4
		9'h06C: adb_code = 7'h59;   // keypad 7
		9'h070: adb_code = 7'h52;   // keypad 0
		9'h071: adb_code = 7'h41;   // keypad .
		9'h072: adb_code = 7'h54;   // keypad 2
		9'h073: adb_code = 7'h57;   // keypad 5
		9'h074: adb_code = 7'h58;   // keypad 6
		9'h075: adb_code = 7'h5B;   // keypad 8
		9'h076: adb_code = 7'h35;   // Escape
		9'h077: adb_code = 7'h47;   // Num Lock: Clear
		9'h078: adb_code = 7'h67;   // F11
		9'h079: adb_code = 7'h45;   // keypad +
		9'h07A: adb_code = 7'h55;   // keypad 3
		9'h07B: adb_code = 7'h4E;   // keypad -
		9'h07C: adb_code = 7'h43;   // keypad *
		9'h07D: adb_code = 7'h5C;   // keypad 9
		9'h07E: adb_code = 7'h6B;   // Scroll Lock: F14
		9'h083: adb_code = 7'h62;   // F7
		9'h111: adb_code = 7'h37;   // right Alt: Command
		9'h114: adb_code = 7'h36;   // right Control
		9'h11F: adb_code = 7'h3A;   // left Windows: Option
		9'h127: adb_code = 7'h3A;   // right Windows: Option
		9'h14A: adb_code = 7'h4B;   // keypad /
		9'h15A: adb_code = 7'h4C;   // keypad Enter
		9'h169: adb_code = 7'h77;   // End
		9'h16B: adb_code = 7'h3B;   // left
		9'h16C: adb_code = 7'h73;   // Home
		9'h170: adb_code = 7'h72;   // Insert: Help
		9'h171: adb_code = 7'h75;   // Delete: forward delete
		9'h172: adb_code = 7'h3D;   // down
		9'h174: adb_code = 7'h3C;   // right
		9'h175: adb_code = 7'h3E;   // up
		9'h17A: adb_code = 7'h79;   // Page Down
		9'h17C: adb_code = 7'h69;   // Print Screen: F13
		9'h17D: adb_code = 7'h74;   // Page Up
		9'h17E: adb_code = 7'h71;   // Break: F15
		default: adb_code = 7'h7F;
	endcase
endfunction

// ---- the PS/2 inputs, synchronised --------------------------------------------------------
logic [2:0]  kt_s, mt_s;
logic [9:0]  kd_s1, kd_s2;
logic [18:0] md_s1, md_s2;            // {Y sign, Y, X sign, X, left button}
always_ff @(posedge clk) begin
	kt_s  <= {kt_s[1:0], ps2_key[10]};
	mt_s  <= {mt_s[1:0], ps2_mouse[24]};
	kd_s1 <= ps2_key[9:0];      kd_s2 <= kd_s1;
	md_s1 <= {ps2_mouse[5], ps2_mouse[23:16], ps2_mouse[4], ps2_mouse[15:8], ps2_mouse[0]};
	md_s2 <= md_s1;
end
wire key_ev   = kt_s[2] != kt_s[1];
wire mouse_ev = mt_s[2] != mt_s[1];

// ---- the devices' state ------------------------------------------------------------------
logic [3:0]  kbd_addr, mouse_addr;
logic [7:0]  kbd_hid, mouse_hid;      // handler IDs
logic        kbd_srq_en, mouse_srq_en;
logic [2:0]  kbd_led;                 // register 2's LEDs, 1 = off

logic [7:0]  kq [8];                  // key events, {up, code}
logic [2:0]  kq_rd, kq_wr;
wire         kq_empty = kq_rd == kq_wr;
wire  [2:0]  kq_n     = kq_wr - kq_rd;

logic        caps_on;                 // Caps Lock locks, as the Apple keyboard's key does
logic        dn_del, dn_ctrl, dn_shift, dn_opt, dn_cmd, dn_clear, dn_f14;

logic signed [9:0] mx, my;            // movement not yet reported, ADB's sense (Y down)
logic        btn, btn_rep;            // the button now, and as last reported
wire         mouse_has = mx != 0 || my != 0 || btn != btn_rep;

function automatic logic signed [6:0] clamp7(input logic signed [9:0] v);
	if (v > 10'sd63)       clamp7 = 7'sd63;
	else if (v < -10'sd64) clamp7 = 7'h40;          // -64
	else                   clamp7 = v[6:0];
endfunction

wire signed [6:0] mx7 = clamp7(mx), my7 = clamp7(my);

function automatic logic signed [9:0] sat10(input logic signed [10:0] v);
	if (v > 11'sd511)       sat10 = 10'sd511;
	else if (v < -11'sd512) sat10 = 10'h200;        // -512
	else                    sat10 = v[9:0];
endfunction

// the accumulators and PS/2's 9-bit movement, sign-extended to 11 bits
wire signed [10:0] mx_wide = {mx[9], mx};
wire signed [10:0] my_wide = {my[9], my};
wire signed [10:0] ps2_dx  = {{2{md_s2[9]}},  md_s2[9],  md_s2[8:1]};
wire signed [10:0] ps2_dy  = {{2{md_s2[18]}}, md_s2[18], md_s2[17:10]};

// ---- the line ------------------------------------------------------------------------------
typedef enum logic [3:0] {
	S_IDLE, S_SYNC, S_CMD, S_STOP, S_SRQ, S_ACT, S_TLT, S_SEND_L, S_SEND_H,
	S_LRX_WAIT, S_LRX_START, S_LRX_BITS, S_LRX_DONE
} state_t;
state_t st;

logic        hl, hl_q;                // Cuda's drive: 1 released
logic [13:0] dur;                     // ticks since its last edge
logic [13:0] tmr;
logic [7:0]  cmd;
logic [3:0]  nbit;
logic [17:0] frame;                   // the answer: start bit, two bytes, stop bit
logic [4:0]  fbits;
logic [15:0] lrx;                     // a Listen's data
logic        l_mouse;                 // the Listen is the mouse's (else the keyboard's)
logic [1:0]  l_reg;
logic        reset_seen;              // the current low has already reset the devices

assign hl = ~host_low;
wire fall = hl_q & ~hl;
wire rise = ~hl_q & hl;

wire [3:0] c_addr = cmd[7:4];
wire [1:0] c_type = cmd[3:2];
wire [1:0] c_reg  = cmd[1:0];

// the command as its last bit comes in, for the service request
wire [7:0] cmd_full = {cmd[6:0], dur > T_BIT};
wire       srq_want = (!kq_empty && kbd_srq_en && cmd_full[7:4] != kbd_addr) ||
                      (mouse_has && mouse_srq_en && cmd_full[7:4] != mouse_addr);

// register 2 of the keyboard (dingusppc's: 0 where a key is down)
wire [15:0] kbd_reg2 = {1'b1, ~dn_del, ~caps_on, 1'b1, ~dn_ctrl, ~dn_shift, ~dn_opt, ~dn_cmd,
                        ~dn_clear, ~dn_f14, 3'b111, kbd_led};

// a key event from PS/2: {up, code}, or none
logic [6:0]  k_code;
logic        k_up, k_push;
always_comb begin
	k_code = adb_code(kd_s2[8:0]);
	k_up   = ~kd_s2[9];
	k_push = key_ev && k_code != 7'h7F;
	if (k_code == 7'h39) begin                       // Caps Lock: a press toggles it
		k_push = key_ev && kd_s2[9];
		k_up   = caps_on;
	end
end

task automatic devices_reset;
	kbd_addr     <= ADDR_KBD;
	mouse_addr   <= ADDR_MOUSE;
	kbd_hid      <= 8'h02;
	mouse_hid    <= 8'h01;
	kbd_srq_en   <= 1'b1;
	mouse_srq_en <= 1'b1;
	kbd_led      <= 3'b111;
	kq_rd        <= kq_wr;
	mx <= '0; my <= '0;
	btn_rep      <= btn;
endtask

always_ff @(posedge clk) begin
	hl_q <= hl;
	if (fall || rise) dur <= '0;
	else if (tick && dur != 14'h3FFF) dur <= dur + 14'd1;
	if (tick && tmr != 0) tmr <= tmr - 14'd1;

	// ---- the keyboard's events ----
	if (k_push) begin
		if (kq_n != 3'd7) begin
			kq[kq_wr] <= {k_up, k_code};
			kq_wr <= kq_wr + 3'd1;
		end
		case (k_code)
			7'h33: dn_del   <= ~k_up;
			7'h36: dn_ctrl  <= ~k_up;
			7'h38: dn_shift <= ~k_up;
			7'h3A: dn_opt   <= ~k_up;
			7'h37: dn_cmd   <= ~k_up;
			7'h47: dn_clear <= ~k_up;
			7'h6B: dn_f14   <= ~k_up;
			7'h39: caps_on  <= ~caps_on;
			default: ;
		endcase
	end

	// ---- the mouse's events: PS/2 Y is up, ADB's down ----
	if (mouse_ev) begin
		mx  <= sat10(mx_wide + ps2_dx);
		my  <= sat10(my_wide - ps2_dy);
		btn <= md_s2[0];
	end

	// ---- a reset pulse (past the fall: at the fall, dur is still the high's) ----
	if (!hl && !hl_q && dur >= T_RESET && !reset_seen) begin
		reset_seen <= 1'b1;
		devices_reset();
		dev_low <= 1'b0;
		st <= S_IDLE;
	end
	if (hl) reset_seen <= 1'b0;

	case (st)
		S_IDLE: ;
		S_SYNC: if (fall) begin cmd <= '0; nbit <= '0; st <= S_CMD; end
		S_CMD: if (fall) begin
			// this fall ends a bit's high: its length is the bit
			cmd  <= cmd_full;
			nbit <= nbit + 4'd1;
			if (nbit == 4'd7) begin
				// the stop bit begins: hold it low if a device wants service
				if (srq_want) begin dev_low <= 1'b1; tmr <= D_SRQ; st <= S_SRQ; end
				else st <= S_STOP;
			end
		end
		S_STOP: if (rise) st <= S_ACT;
		S_SRQ: if (tmr == 0) begin dev_low <= 1'b0; st <= S_ACT; end
		S_ACT: begin
			st <= S_IDLE;
			case (c_type)
				2'b00: begin
					if (c_reg == 2'd0) devices_reset();                     // SendReset
					else if (c_reg == 2'd1) begin                           // Flush
						if (c_addr == kbd_addr) kq_rd <= kq_wr;
						else if (c_addr == mouse_addr) begin mx <= '0; my <= '0; btn_rep <= btn; end
					end
				end
				2'b10: begin                                                // Listen
					if ((c_addr == kbd_addr && (c_reg == 2'd2 || c_reg == 2'd3)) ||
					    (c_addr == mouse_addr && c_reg == 2'd3)) begin
						l_mouse <= c_addr != kbd_addr;
						l_reg   <= c_reg;
						st      <= S_LRX_WAIT;
					end
				end
				2'b11: begin                                                // Talk
					fbits <= 5'd18;
					tmr   <= D_TLT;
					if (c_addr == kbd_addr) begin
						case (c_reg)
							2'd0: if (!kq_empty) begin
								frame <= {1'b1, kq[kq_rd], kq_n >= 3'd2 ? kq[kq_rd + 3'd1] : 8'hFF, 1'b0};
								kq_rd <= kq_n >= 3'd2 ? kq_rd + 3'd2 : kq_rd + 3'd1;
								st    <= S_TLT;
							end
							2'd2: begin frame <= {1'b1, kbd_reg2, 1'b0}; st <= S_TLT; end
							2'd3: begin frame <= {1'b1, 1'b0, 1'b1, kbd_srq_en, 1'b0, kbd_addr, kbd_hid, 1'b0}; st <= S_TLT; end
							default: ;
						endcase
					end
					else if (c_addr == mouse_addr) begin
						case (c_reg)
							2'd0: if (mouse_has) begin
								frame   <= {1'b1, ~btn, my7, 1'b1, mx7, 1'b0};
								mx      <= mx - {{3{mx7[6]}}, mx7};
								my      <= my - {{3{my7[6]}}, my7};
								btn_rep <= btn;
								st      <= S_TLT;
							end
							2'd3: begin frame <= {1'b1, 1'b0, 1'b1, mouse_srq_en, 1'b0, mouse_addr, mouse_hid, 1'b0}; st <= S_TLT; end
							default: ;
						endcase
					end
				end
				default: ;                                                  // reserved
			endcase
		end
		S_TLT: if (tmr == 0) begin
			dev_low <= 1'b1;
			tmr     <= frame[17] ? D_SHORT : D_LONG;
			st      <= S_SEND_L;
		end
		S_SEND_L: if (tmr == 0) begin
			dev_low <= 1'b0;
			if (fbits == 5'd1) st <= S_IDLE;                          // the stop bit's low is out
			else begin tmr <= frame[17] ? D_LONG : D_SHORT; st <= S_SEND_H; end
		end
		S_SEND_H: if (tmr == 0) begin
			frame   <= {frame[16:0], 1'b0};
			fbits   <= fbits - 5'd1;
			dev_low <= 1'b1;
			tmr     <= frame[16] ? D_SHORT : D_LONG;
			st      <= S_SEND_L;
		end
		// a Listen's data: the start bit's low, its high, then a bit at each fall
		S_LRX_WAIT:  if (fall) st <= S_LRX_START;
		S_LRX_START: if (fall) begin nbit <= '0; st <= S_LRX_BITS; end
		S_LRX_BITS: if (fall) begin
			lrx  <= {lrx[14:0], dur > T_BIT};
			nbit <= nbit + 4'd1;
			if (nbit == 4'd15) st <= S_LRX_DONE;
		end
		S_LRX_DONE: begin
			st <= S_IDLE;
			if (l_reg == 2'd2) kbd_led <= lrx[2:0];
			else if (!l_mouse) begin
				case (lrx[7:0])
					8'h01, 8'h02: kbd_hid <= lrx[7:0];
					8'h00: begin kbd_addr <= lrx[11:8]; kbd_srq_en <= lrx[13]; end
					8'hFE: kbd_addr <= lrx[11:8];
					default: ;                                          // 3 and the rest refused
				endcase
			end
			else begin
				case (lrx[7:0])
					8'h01, 8'h02: mouse_hid <= lrx[7:0];
					8'h00: begin mouse_addr <= lrx[11:8]; mouse_srq_en <= lrx[13]; end
					8'hFE: mouse_addr <= lrx[11:8];
					default: ;
				endcase
			end
		end
		default: st <= S_IDLE;
	endcase

	// an attention starts a command whatever was going on (but while answering)
	if (rise && dur > T_ATTN && st != S_SEND_L && st != S_SEND_H && st != S_TLT)
		st <= S_SYNC;
	// a Listen's data that never comes
	if ((st == S_LRX_WAIT || st == S_LRX_START || st == S_LRX_BITS) && hl && hl_q && dur >= T_RESET)
		st <= S_IDLE;

	if (reset) begin
		st <= S_IDLE;
		dev_low <= 1'b0;
		hl_q <= 1'b1;
		dur <= '0; tmr <= '0; reset_seen <= 1'b0;
		kq_wr <= '0; kq_rd <= '0;
		caps_on <= 1'b0;
		{dn_del, dn_ctrl, dn_shift, dn_opt, dn_cmd, dn_clear, dn_f14} <= '0;
		btn <= 1'b0;
		kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE;
		kbd_hid <= 8'h02; mouse_hid <= 8'h01;
		kbd_srq_en <= 1'b1; mouse_srq_en <= 1'b1;
		kbd_led <= 3'b111;
		mx <= '0; my <= '0; btn_rep <= 1'b0;
	end
end

// a bench's view (verilator -DADB_DEBUG): the commands and the PS/2 events
`ifdef ADB_DEBUG
always_ff @(posedge clk) begin
	if (mouse_ev) $display("adb: mouse event x %0d y %0d button %0d", $signed({md_s2[9], md_s2[8:1]}),
	                       $signed({md_s2[18], md_s2[17:10]}), md_s2[0]);
	if (k_push) $display("adb: key %02X %s", k_code, k_up ? "up" : "down");
	if (st == S_ACT) $display("adb: command %02X (keyboard at %0d, mouse at %0d)", cmd, kbd_addr, mouse_addr);
	if (!hl && !hl_q && dur >= T_RESET && !reset_seen) $display("adb: reset pulse");
end
`endif

endmodule
