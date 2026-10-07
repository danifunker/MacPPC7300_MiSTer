//============================================================================
//
//  PPCMac - the machine around the CPU
//  The ESCC, Grand Central's serial controller (a Z85C30): channel A, the
//  modem port, transmits and receives at the rate software programs;
//  channel B, the printer port, has the same registers and no line
//
//  What the 7300/7600's software uses, as the Z85C30's manual describes it
//  and dingusppc's devices/serial/escc.cpp models it:
//
//  - One register pointer for both channels (escc.cpp): a write to a
//    command register with the pointer at 0 sets it (WR0 bits 2-0, plus 8
//    for "point high", bits 5-3 = 001); any other command access reads or
//    writes the register pointed at and sets the pointer back to 0.
//  - WR9's reset commands (channel A, channel B, hardware), resetting the
//    registers as escc.cpp's EsccChannel::reset does.
//  - The transmitter: a byte written to the data register (or WR8) waits in
//    the transmit buffer (RR0 bit 2 clear) until the shift register is free
//    and WR5 enables the transmitter, then goes out LSB first with a start
//    bit, the data bits WR5 asks for, parity if WR4 asks for it, and one or
//    two stop bits (WR4; one and a half is sent as two). RR1 bit 0 (all
//    sent) once the line is idle again.
//  - The receiver (WR3 bit 0): a start bit's falling edge, then each bit
//    sampled in its middle; the byte into a three-byte FIFO (RR0 bit 0; an
//    overrun sets RR1 bit 5 and loses the byte); the data register (or RR8)
//    takes the oldest.
//  - The bit time: from the baud-rate generator when WR11 clocks the
//    transmitter or receiver from it and WR14 enables it, 2 x (time
//    constant + 2) clocks of its source; else one clock; times WR4's clock
//    mode (1, 16, 32 or 64). The source is RTxC, 3.6864 MHz on these
//    machines (rtxc_tick); PCLK as the source is taken to be RTxC too. Open
//    Firmware's driver (FCode image 6 in the ROM) sets time constant 1 from
//    RTxC in x16 mode: 38,400 baud, 8 data bits, 2 stop bits.
//
//  Left out (docs/PPCMac_stubs.md): interrupts, the synchronous modes,
//  DMA, the DPLL, CRC, break, the modem lines (RR0 reads 44 with the
//  transmitter idle, as escc.cpp's), and the read registers dingusppc does
//  not keep (RR2 reads WR2; all but RR0, RR1 and RR8 read 0).
//
//  Registers by MacRISC number (Grand Central maps both of its addressings
//  onto it): 0 B command, 1 B data, 2 A command, 3 A data, 4 B enhancement,
//  5 A enhancement (bit 4 kept, as escc.cpp).
//
//============================================================================

module PPCMac_escc
(
	input  logic       clk,
	input  logic       reset,
	input  logic       rtxc_tick,      // one clock at RTxC's rate, 3,686,400 Hz
	input  logic       sel,            // an access, for one cycle
	input  logic       we,
	input  logic [3:0] rn,             // MacRISC register number
	input  logic [7:0] wdata,
	output logic [7:0] rq,             // what a read of rn returns now (the caller registers it)
	output logic       txd_a,          // the modem port: transmit (1 when idle)
	input  logic       rxd_a           //   and receive, asynchronous (1 when idle)
);

logic [3:0] ptr;                       // the register pointer, shared
logic [7:0] wr2, wr9;                  // shared: the interrupt vector, master control
logic [7:0] enh_a, enh_b;

wire       is_cmd = rn == 4'd0 || rn == 4'd2;
wire       chan_a = rn[1];                                   // 2, 3 and 5 are channel A
wire       ptr_wr = sel & we & is_cmd & (ptr == 4'd0);       // a write to WR0
wire       reg_wr = sel & we & is_cmd & (ptr != 4'd0);       // a write to the register pointed at
wire       reg_rd = sel & ~we & is_cmd;

// WR9's reset commands
wire       wr9_now = reg_wr & (ptr == 4'd9);
wire       hw_rst  = reset | (wr9_now & wdata[7:6] == 2'b11);
wire       rst_a   = wr9_now & wdata[7:6] == 2'b10;
wire       rst_b   = wr9_now & wdata[7:6] == 2'b01;

// what each channel is told
wire       ch_reg = ptr != 4'd2 && ptr != 4'd9;
wire       wr_a   = reg_wr & chan_a & ch_reg;
wire       wr_b   = reg_wr & ~chan_a & ch_reg;
wire       tx_a   = (sel & we & rn == 4'd3) | (wr_a & ptr == 4'd8);
wire       tx_b   = (sel & we & rn == 4'd1) | (wr_b & ptr == 4'd8);
wire       rx_a   = (sel & ~we & rn == 4'd3) | (reg_rd & chan_a & ptr == 4'd8);
wire       rx_b   = (sel & ~we & rn == 4'd1) | (reg_rd & ~chan_a & ptr == 4'd8);

logic [7:0] rr0_a, rr1_a, rd_a, rr0_b, rr1_b, rd_b;
logic       txd_b;
logic [1:0] rxd_s;                     // the modem port's receive line, synchronised

always_ff @(posedge clk) rxd_s <= {rxd_s[0], rxd_a};

PPCMac_escc_ch ch_a (
	.clk, .hw_rst, .ch_rst(rst_a), .rtxc_tick,
	.wr_en(wr_a), .wr_n(ptr), .wr_v(wdata), .tx_wr(tx_a), .rx_rd(rx_a),
	.rr0(rr0_a), .rr1(rr1_a), .rx_data(rd_a), .txd(txd_a), .rxd(rxd_s[1])
);

PPCMac_escc_ch ch_b (
	.clk, .hw_rst, .ch_rst(rst_b), .rtxc_tick,
	.wr_en(wr_b), .wr_n(ptr), .wr_v(wdata), .tx_wr(tx_b), .rx_rd(rx_b),
	.rr0(rr0_b), .rr1(rr1_b), .rx_data(rd_b), .txd(txd_b), .rxd(1'b1)
);

// what a read returns
always_comb begin
	rq = 8'h00;
	case (rn)
		4'd0, 4'd2: begin
			case (ptr)
				4'd0:    rq = chan_a ? rr0_a : rr0_b;
				4'd1:    rq = chan_a ? rr1_a : rr1_b;
				4'd2:    rq = wr2;
				4'd8:    rq = chan_a ? rd_a : rd_b;
				default: rq = 8'h00;
			endcase
		end
		4'd1:    rq = rd_b;
		4'd3:    rq = rd_a;
		4'd4:    rq = enh_b;
		4'd5:    rq = enh_a;
		default: rq = 8'h00;
	endcase
end

always_ff @(posedge clk) begin
	if (ptr_wr)
		ptr <= {wdata[5:3] == 3'b001, wdata[2:0]};
	else if (reg_wr | reg_rd)
		ptr <= 4'd0;
	if (reg_wr & ptr == 4'd2) wr2 <= wdata;
	if (wr9_now) wr9 <= wdata & 8'h3F;
	if (sel & we & rn == 4'd4) enh_b <= wdata & 8'h10;
	if (sel & we & rn == 4'd5) enh_a <= wdata & 8'h10;
	if (reset) begin
		ptr   <= 4'd0;
		wr2   <= 8'h00;
		wr9   <= 8'hC0;
		enh_a <= 8'h00;
		enh_b <= 8'h00;
	end
end

endmodule


// One channel: its write registers, the transmitter, the receiver.
module PPCMac_escc_ch
(
	input  logic       clk,
	input  logic       hw_rst,         // reset, or WR9's hardware reset
	input  logic       ch_rst,         // WR9's reset of this channel
	input  logic       rtxc_tick,
	input  logic       wr_en,          // write register wr_n
	input  logic [3:0] wr_n,
	input  logic [7:0] wr_v,
	input  logic       tx_wr,          // a byte for the transmitter
	input  logic       rx_rd,          // the oldest received byte taken
	output logic [7:0] rr0,
	output logic [7:0] rr1,
	output logic [7:0] rx_data,
	output logic       txd,
	input  logic       rxd             // synchronised
);

logic [7:0] wr1, wr3, wr4, wr5, wr10, wr11, wr12, wr13, wr14, wr15;

// ---- the bit time, in RTxC clocks -------------------------------------------------------
wire [16:0] tc2     = {1'b0, wr13, wr12} + 17'd2;
wire [17:0] brg_div = {tc2, 1'b0};                               // 2 x (time constant + 2)
wire        brg_on  = wr14[0];
wire        tx_brg  = brg_on & wr11[4:3] == 2'b10;
wire        rx_brg  = brg_on & wr11[6:5] == 2'b10;
wire [2:0]  mode_sh = wr4[7:6] == 2'b00 ? 3'd0 : wr4[7:6] == 2'b01 ? 3'd4 : wr4[7:6] == 2'b10 ? 3'd5 : 3'd6;
wire [23:0] tx_bit  = {6'd0, tx_brg ? brg_div : 18'd1} << mode_sh;
wire [23:0] rx_bit  = {6'd0, rx_brg ? brg_div : 18'd1} << mode_sh;

// ---- the transmitter ------------------------------------------------------------------------
logic [7:0]  tx_buf;
logic        tx_full;                  // a byte waits in the transmit buffer
logic [11:0] tx_sh;                    // the frame going out, LSB first
logic [3:0]  tx_left;                  // bits still to send, the current one included
logic [23:0] tx_cnt;                   // RTxC clocks left in the current bit
wire  [3:0]  tx_dbits = wr5[6:5] == 2'b00 ? 4'd5 : wr5[6:5] == 2'b01 ? 4'd7 : wr5[6:5] == 2'b10 ? 4'd6 : 4'd8;
wire  [7:0]  tx_dmask = wr5[6:5] == 2'b00 ? 8'h1F : wr5[6:5] == 2'b01 ? 8'h7F : wr5[6:5] == 2'b10 ? 8'h3F : 8'hFF;
wire         tx_par   = wr4[0];
wire  [3:0]  tx_stops = wr4[3:2] == 2'b01 ? 4'd1 : 4'd2;
wire  [7:0]  tx_d     = tx_buf & tx_dmask;
wire         tx_pbit  = ^tx_d ^ ~wr4[1];                         // WR4 bit 1: even parity
// the frame, LSB first: the start bit, the data bits, the parity bit; 1s after
wire  [11:0] d_field  = {3'b000, tx_d, 1'b0};
wire  [11:0] d_mask   = {3'b000, tx_dmask, 1'b1};
wire  [11:0] p_pos    = tx_par ? (12'd2 << tx_dbits) : 12'd0;
wire  [11:0] tx_frame = (~d_mask & ~p_pos) | d_field | (tx_pbit ? p_pos : 12'd0);
wire  [3:0]  tx_ds    = tx_dbits + tx_stops;
wire  [3:0]  tx_sp    = tx_par ? 4'd2 : 4'd1;                    // the start bit, and parity
wire  [3:0]  tx_nbits = tx_ds + tx_sp;
wire         tx_idle  = tx_left == 4'd0;

// ---- the receiver -----------------------------------------------------------------------------
logic [1:0]  rx_state;                 // 0 idle, 1 the start bit, 2 the data bits, 3 the stop bit
logic [23:0] rx_cnt;                   // RTxC clocks to the middle of the next bit
logic [3:0]  rx_left;                  // data bits still to come
logic [7:0]  rx_sh;                    // the data bits, shifted in from the top
logic        rx_q;                     // the line as last seen
logic [7:0]  rx_f0, rx_f1, rx_f2;      // the FIFO, the oldest first
logic [1:0]  rx_n;                     // bytes in it
logic        rx_ovr;
wire  [3:0]  rx_dbits = wr3[7:6] == 2'b00 ? 4'd5 : wr3[7:6] == 2'b01 ? 4'd7 : wr3[7:6] == 2'b10 ? 4'd6 : 4'd8;
wire         rx_on    = wr3[0];
wire  [7:0]  rx_byte  = rx_sh >> (4'd8 - rx_dbits);              // the first bit received at bit 0
wire         rx_mid   = rtxc_tick & (rx_cnt <= 24'd1);
wire         rx_push  = rx_state == 2'd3 & rx_mid;
wire         rx_pop   = rx_rd & (rx_n != 2'd0);
wire         rx_take  = rx_push & ~(rx_n == 2'd3 & ~rx_pop);     // room for it
wire  [1:0]  rx_at    = rx_n - {1'b0, rx_pop};                   // where it goes

assign rr0     = {1'b0, 1'b1, 1'b0, 1'b0, 1'b0, ~tx_full, 1'b0, rx_n != 2'd0};
assign rr1     = {2'b00, rx_ovr, 2'b00, 2'b11, ~tx_full & tx_idle};
assign rx_data = rx_f0;
assign txd     = tx_idle | tx_sh[0];

always_ff @(posedge clk) begin
	// the registers
	if (wr_en) begin
		case (wr_n)
			4'd1:  wr1  <= wr_v;
			4'd3:  wr3  <= wr_v;
			4'd4:  wr4  <= wr_v;
			4'd5:  wr5  <= wr_v;
			4'd10: wr10 <= wr_v;
			4'd11: wr11 <= wr_v;
			4'd12: wr12 <= wr_v;
			4'd13: wr13 <= wr_v;
			4'd14: wr14 <= wr_v;
			4'd15: wr15 <= wr_v;
			default: ;
		endcase
	end

	// the transmitter
	if (tx_wr) begin
		tx_buf  <= wr_v;
		tx_full <= 1'b1;
	end
	if (tx_idle) begin
		if (tx_full & ~tx_wr & wr5[3]) begin
			tx_sh   <= tx_frame;
			tx_left <= tx_nbits;
			tx_cnt  <= tx_bit;
			tx_full <= 1'b0;
		end
	end
	else if (rtxc_tick) begin
		if (tx_cnt <= 24'd1) begin
			tx_sh   <= {1'b1, tx_sh[11:1]};
			tx_left <= tx_left - 4'd1;
			tx_cnt  <= tx_bit;
		end
		else tx_cnt <= tx_cnt - 24'd1;
	end

	// the receiver
	rx_q <= rxd;
	case (rx_state)
		2'd0: if (rx_on & rx_q & ~rxd) begin                      // a start bit begins
			rx_state <= 2'd1;
			rx_cnt   <= {1'b0, rx_bit[23:1]};
		end
		2'd1: if (rtxc_tick) begin
			if (rx_cnt <= 24'd1) begin                            // the middle of the start bit
				rx_state <= rxd ? 2'd0 : 2'd2;                    // high again: a glitch
				rx_left  <= rx_dbits;
				rx_cnt   <= rx_bit;
			end
			else rx_cnt <= rx_cnt - 24'd1;
		end
		2'd2: if (rtxc_tick) begin
			if (rx_cnt <= 24'd1) begin                            // the middle of a data bit
				rx_sh   <= {rxd, rx_sh[7:1]};
				rx_left <= rx_left - 4'd1;
				rx_cnt  <= rx_bit;
				if (rx_left == 4'd1) rx_state <= 2'd3;
			end
			else rx_cnt <= rx_cnt - 24'd1;
		end
		default: if (rtxc_tick) begin                             // the stop bit (parity is not received)
			if (rx_cnt <= 24'd1) rx_state <= 2'd0;
			else rx_cnt <= rx_cnt - 24'd1;
		end
	endcase
	if (!rx_on) rx_state <= 2'd0;

	// the FIFO: the oldest leaves when read; a new byte goes in behind the rest
	if (rx_pop) begin
		rx_f0 <= rx_f1;
		rx_f1 <= rx_f2;
	end
	if (rx_take) begin
		case (rx_at)
			2'd0:    rx_f0 <= rx_byte;
			2'd1:    rx_f1 <= rx_byte;
			default: rx_f2 <= rx_byte;
		endcase
	end
	if (rx_push & ~rx_take) rx_ovr <= 1'b1;
	if (rx_take & ~rx_pop) rx_n <= rx_n + 2'd1;
	else if (rx_pop & ~rx_take) rx_n <= rx_n - 2'd1;

	// WR9's channel reset (escc.cpp EsccChannel::reset(false)); the hardware
	// reset, from registers that start at 0 as dingusppc's do
	if (ch_rst) begin
		wr1  <= wr1 & 8'h24;
		wr3  <= wr3 & 8'hFE;
		wr4  <= wr4 | 8'h04;
		wr5  <= wr5 & 8'h61;
		wr15 <= 8'hF8;
		wr10 <= wr10 & 8'h60;
		wr14 <= (wr14 & 8'hC3) | 8'h20;
	end
	if (hw_rst) begin
		wr1  <= 8'h00;
		wr3  <= 8'h00;
		wr4  <= 8'h04;
		wr5  <= 8'h00;
		wr10 <= 8'h00;
		wr11 <= 8'h08;
		wr12 <= 8'h00;
		wr13 <= 8'h00;
		wr14 <= 8'h20;
		wr15 <= 8'hF8;
	end
	if (ch_rst | hw_rst) begin
		tx_full  <= 1'b0;
		tx_left  <= 4'd0;
		rx_state <= 2'd0;
		rx_n     <= 2'd0;
		rx_ovr   <= 1'b0;
	end
end

endmodule
