//============================================================================
//
//  PPCMac - the machine around the CPU
//  MACE, the Ethernet controller (Am79C940) behind Grand Central: its cable
//  unplugged, or (2026-10-08) on the MiSTer's network through the Main
//  (PPCMac_enet, the OSD's Ethernet option)
//
//  The registers as dingusppc's devices/ethernet/mace.cpp reads and writes
//  them (MACE revision A2, chip ID 0941), the bits as the Am79C940's data
//  sheet and Linux's drivers/net/ethernet/apple/mace.h name them. One byte
//  each, 16 bytes apart in Grand Central's 11000 window (offset >> 4):
//     0  RCVFIFO   reads 0 (received bytes come by DMA, below)
//     1  XMTFIFO   writes ignored (the transmit data comes by DMA, below)
//     2  XMTFC     stored
//     3  XMTFS     transmit status after a frame: XMTSV (80), with LCAR
//                  (02) when the cable is unplugged; cleared by a read
//     4  XMTRC     0: no retries (nothing on the wire collides)
//     5  RCVFC     stored, 1 (ASTRPRCV) from reset
//     6  RCVFS     0
//     7  FIFOFC    transmit frames held (bits 3-0: 0 or 1)
//     8  IR        the interrupt flags: XMTINT (01) as a frame's status
//                  becomes valid, RCVINT (02) as a received frame has gone;
//                  a read returns them and clears them
//     9  IMR       stored; a 1 masks the flag
//    10  PR        XMTSV (80) while XMTFS is valid, TDTREQ (40) while the
//                  transmitter takes bytes
//    11  BIUCC     stored; SWRST (01) resets the chip's registers and clears
//                  itself at once
//    12  FIFOCC    stored
//    13  MACCC     stored: ENXMT (02) lets a frame go out (until it is set, a
//                  frame waits), ENRCV (01) lets frames in, PROM (80) all
//    14  PLSCC     stored (dingusppc reads it as 0)
//    15  PHYCC     stored; LNKFL (80) reads 1 with no network (no cable),
//                  unless DLNKTST (40) disables the link test
//    16  CHIPID    41, then 09 at 17
//    18  IAC       PHYADDR (04) or LOGADDR (02) set the byte pointer to 0
//                  for registers 21 (PADR, 6 bytes) and 20 (LADRF, 8 bytes),
//                  each clearing after its last byte; ADDRCHG (80) clears
//    24  MPC       frames missed (no DMA to take them); cleared by a read
//    29  UTR       stored; LOOP (bits 2-1) sends frames back to the receiver
//                  instead of the wire (any loopback mode, as the internal)
//  Others read 0 and ignore writes.
//
//  Transmit: Grand Central's DMA channel 2 (Ethernet out) puts the frame's
//  bytes (do_put), the last of an OUTPUT_LAST marking its end (do_last).
//  Unplugged, the frame takes its time on the wire at 10 Mbit/s (16 us of
//  preamble and gap, then 0.8 us a byte, on us_tick) and its status becomes
//  valid with loss of carrier (the Am79C940: LCAR for every frame sent in the
//  link fail state). On the network the bytes go into the bridge's buffer
//  and the status is valid once the frame is in the Main's ring. One frame
//  at a time: the next waits until then.
//
//  Receive (on the network): a frame from the bridge passes the address
//  filter (MACCC's PROM; PADR; broadcast; a multicast when LADRF has any
//  bit) and ENRCV, then goes to DMA channel 3 (Ethernet in) as Linux's
//  mace.c reads it: the frame's bytes, the FCS's four (zero; an 802.3 frame
//  under ASTRPRCV loses its pad and FCS instead), and the receive status
//  RFS0-3 (the byte count; no error bits, no runts, no collisions), the
//  last byte ending the INPUT_LAST. A frame the DMA does not start taking
//  within 2 ms is missed (MPC).
//
//  The interrupt (Grand Central's source 0E) is a flag in IR that IMR does
//  not mask, as the chip's INTR pin.
//
//  Left out (docs/PPCMac_stubs.md): the FIFOs' contents and watermarks,
//  transmit by programmed I/O, external loopback, collisions, CERR (the
//  heartbeat), LADRF's hash (any bit lets every multicast in), the FCS's
//  value.
//
//============================================================================

module PPCMac_mace
(
	input  logic        clk,
	input  logic        reset,
	input  logic        us_tick,         // one clock a microsecond

	// the registers: an access for one clock
	input  logic        sel,
	input  logic        we,
	input  logic [4:0]  rn,              // offset >> 4
	input  logic [7:0]  wdata,
	output logic [7:0]  rq,              // what a read of rn returns now

	// the transmit DMA channel's bytes
	output logic        do_ready,
	input  logic [7:0]  do_data,
	input  logic        do_put,
	input  logic        do_last,

	// the receive DMA channel
	output logic        di_valid,
	output logic [7:0]  di_data,
	output logic        di_last,
	input  logic        di_take,
	input  logic        rx_dma,          // it can take a byte now

	// the network (PPCMac_enet)
	input  logic        link,
	output logic        tx_we,
	output logic [7:0]  tx_wa,
	output logic [63:0] tx_wd,
	output logic        tx_go,
	output logic [10:0] tx_len,
	input  logic        tx_done,
	output logic [7:0]  rx_ra,
	input  logic [63:0] rx_q,
	input  logic        rx_avail,
	input  logic [10:0] rx_len,
	output logic        rx_done,

	output logic        irq,
	output logic        xmtsv            // a sent frame's status is valid (Grand Central: DMA channel 2's s5)
);

logic [7:0]  xmt_fc, rcv_fc, int_stat, int_mask, biu_cc, fifo_cc, mac_cc, pls_cc, phy_cc, iac, utr, xmt_fs, mpc;
logic [2:0]  aptr;
logic [7:0]  padr [6];
logic        ladr_any;                 // a bit of LADRF set
logic [11:0] f_len;                    // bytes of the frame being taken
logic        f_held;                   // a whole frame waits for the wire
logic        f_wire;                   // ... and is on it (or in the bridge)
logic        f_loop;                   // ... in UTR's loopback: back to the receiver, not the wire
logic [63:0] lbb [256];                // the transmitted frame, for the loopback
logic [63:0] lb_q;
logic        lb_pend;                  // a looped-back frame waits for the receiver
logic [10:0] lb_len;
logic [11:0] f_us;                     // microseconds left on the wire
logic [63:0] t_word;                   // the frame's word being gathered
logic        tx_seen;
wire         swrst = sel & we & (rn == 5'd11) & wdata[0];
// the frame's time on the wire: 16 us, and 13/16 us a byte (0.8, near enough)
wire  [11:0] len_a = f_len - {2'b00, f_len[11:2]};
wire  [11:0] len_b = len_a + {4'h0, f_len[11:4]};
wire  [11:0] f_time = len_b + 12'd16;
wire  [63:0] t_next = t_word | ({56'd0, do_data} << {f_len[2:0], 3'b000});

assign irq      = |(int_stat & ~int_mask);
assign xmtsv    = xmt_fs[7];
assign do_ready = ~f_held;

always_comb begin
	case (rn)
		5'd2:    rq = xmt_fc;
		5'd3:    rq = xmt_fs;
		5'd5:    rq = rcv_fc;
		5'd7:    rq = {7'h0, f_held};
		5'd8:    rq = int_stat;
		5'd9:    rq = int_mask;
		5'd10:   rq = {xmt_fs[7], ~f_held, 6'h0};
		5'd11:   rq = biu_cc;
		5'd12:   rq = fifo_cc;
		5'd13:   rq = mac_cc;
		5'd14:   rq = pls_cc;
		5'd15:   rq = {~phy_cc[6] & ~link, phy_cc[6:0]};
		5'd16:   rq = 8'h41;
		5'd17:   rq = 8'h09;
		5'd18:   rq = iac;
		5'd24:   rq = mpc;
		5'd29:   rq = utr;
		default: rq = 8'h00;
	endcase
end

// ---- receive -------------------------------------------------------------------------------------
typedef enum logic [2:0] { R_IDLE, R_DST, R_TYPE, R_DMA, R_SEND, R_DONE } r_t;
r_t          rs;
logic        rx_seen;
logic [1:0]  r_wt;                     // clocks until rx_q holds the word asked for
logic [47:0] r_dst;
logic [10:0] r_n;                      // the frame's bytes to deliver
logic        r_fcs;                    // ... and four of FCS
logic [11:0] r_p, r_tot;               // the next byte, and all of them (with the status)
logic [11:0] r_us;                     // microseconds waited for the DMA
logic        r_ok;                     // the frame went (RCVINT)
logic        r_lb;                     // the frame is the looped-back one
wire  [63:0] r_q    = r_lb ? lb_q : rx_q;
wire  [10:0] r_len  = r_lb ? lb_len : rx_len;
wire  [11:0] r_cnt  = {1'b0, r_n} + (r_fcs ? 12'd4 : 12'd0);   // the bytes before the status
wire  [15:0] r_type = {r_q[39:32], r_q[47:40]};                 // bytes 12 and 13
wire         r_pad  = {padr[5], padr[4], padr[3], padr[2], padr[1], padr[0]} == r_dst;
wire         r_want = mac_cc[0] && (mac_cc[7] || r_pad || r_dst == 48'hFFFF_FFFF_FFFF || (r_dst[0] && ladr_any));
wire  [11:0] r_n802 = (r_type + 16'd14 < {5'd0, r_len}) ? 12'(r_type + 16'd14) : {1'b0, r_len};

assign rx_ra    = (rs == R_DST) ? 8'd0 : (rs == R_TYPE) ? 8'd1 : r_p[10:3];
assign di_valid = rs == R_SEND && r_wt == 2'd0;
assign di_last  = r_p == r_tot - 12'd1;

always_ff @(posedge clk) begin
	if (tx_we) lbb[tx_wa] <= tx_wd;
	lb_q <= lbb[rx_ra];
end

// the FCS: Ethernet's CRC-32 of the bytes delivered, low byte first
function automatic logic [31:0] crc_byte(input logic [31:0] c, input logic [7:0] d);
	logic [31:0] x;
	x = c ^ {24'd0, d};
	for (int i = 0; i < 8; i++) x = x[0] ? ((x >> 1) ^ 32'hEDB8_8320) : (x >> 1);
	return x;
endfunction
logic [31:0] r_crc;
wire  [31:0] r_fcs_v = ~r_crc;
wire  [11:0] r_fi    = r_p - {1'b0, r_n};

always_comb begin
	if (r_p < {1'b0, r_n})  di_data = r_q[8 * r_p[2:0] +: 8];
	else if (r_p < r_cnt)   di_data = r_fcs_v[8 * r_fi[1:0] +: 8];  // the FCS
	else case (r_p - r_cnt)
		12'd0:   di_data = r_cnt[7:0];                             // RFS0, RFS1: the count
		12'd1:   di_data = {4'h0, r_cnt[11:8]};
		default: di_data = 8'h00;                                  // RFS2, RFS3: no runts, collisions
	endcase
end

always_ff @(posedge clk) begin
	tx_we <= 1'b0;

	// ---- the transmitter: the frame's bytes, then the wire or the bridge ----
	if (do_put) begin
		f_len  <= (f_len == 12'd2047) ? f_len : f_len + 12'd1;
		t_word <= (f_len[2:0] == 3'd7 || do_last) ? 64'd0 : t_next;
		tx_we  <= f_len[2:0] == 3'd7 || do_last;
		tx_wa  <= f_len[10:3];
		tx_wd  <= t_next;
		if (do_last) f_held <= 1'b1;
	end
	if (f_held && !f_wire && mac_cc[1]) begin
		f_wire <= 1'b1;
		f_us   <= f_time;
		f_loop <= utr[2:1] != 2'b00;
		if (link && utr[2:1] == 2'b00) begin
			tx_len <= f_len[10:0];
			tx_go  <= ~tx_go;
		end
	end
	if (f_wire && !f_loop && link && tx_done != tx_seen) begin
		tx_seen     <= tx_done;
		f_wire      <= 1'b0;
		f_held      <= 1'b0;
		f_len       <= 12'd0;
		xmt_fs      <= 8'h80;                // XMTSV
		int_stat[0] <= 1'b1;                 // XMTINT
	end
	else if (f_wire && (f_loop || !link) && us_tick) begin
		if (f_us == 12'd0) begin
			f_wire      <= 1'b0;
			f_held      <= 1'b0;
			f_len       <= 12'd0;
			xmt_fs      <= f_loop ? 8'h80 : 8'h82;   // XMTSV, with LCAR unplugged
			int_stat[0] <= 1'b1;                 // XMTINT
			if (f_loop) begin
				lb_pend <= 1'b1;
				lb_len  <= f_len[10:0];
			end
		end
		else f_us <= f_us - 12'd1;
	end

	// ---- the receiver ----
	if (r_wt != 2'd0) r_wt <= r_wt - 2'd1;
	case (rs)
		R_IDLE: if (lb_pend || rx_avail != rx_seen) begin
			r_lb <= lb_pend;
			r_wt <= 2'd2;
			rs   <= R_DST;
		end
		R_DST: if (r_wt == 2'd0) begin
			r_dst <= r_q[47:0];
			r_wt  <= 2'd2;
			rs    <= R_TYPE;
		end
		R_TYPE: if (r_wt == 2'd0) begin
			if (!r_want) begin r_ok <= 1'b0; rs <= R_DONE; end
			else begin
				r_fcs <= !(r_type < 16'd1536 && rcv_fc[0]);
				r_n   <= (r_type < 16'd1536 && rcv_fc[0]) ? r_n802[10:0] : r_len;
				r_us  <= 12'd2000;
				rs    <= R_DMA;
			end
		end
		R_DMA: begin                                   // the channel ready to take it, or missed
			r_p <= 12'd0;
			r_tot <= r_cnt + 12'd4;
			r_crc <= 32'hFFFF_FFFF;
			if (rx_dma) begin r_wt <= 2'd2; rs <= R_SEND; end
			else if (us_tick) begin
				if (r_us == 12'd0) begin
					mpc  <= mpc + 8'd1;
					r_ok <= 1'b0;
					rs   <= R_DONE;
				end
				else r_us <= r_us - 12'd1;
			end
		end
		R_SEND: if (di_take) begin
			r_p  <= r_p + 12'd1;
			if (r_p < {1'b0, r_n}) r_crc <= crc_byte(r_crc, di_data);
			r_wt <= 2'd2;
			if (di_last) begin r_ok <= 1'b1; rs <= R_DONE; end
		end
		R_DONE: begin
			if (r_lb) lb_pend <= 1'b0;
			else begin
				rx_seen <= rx_avail;
				rx_done <= ~rx_done;
			end
			if (r_ok) int_stat[1] <= 1'b1;                 // RCVINT
			rs <= R_IDLE;
		end
		default: rs <= R_IDLE;
	endcase

	// reads that clear
	if (sel & ~we & (rn == 5'd8)) int_stat <= 8'h00;
	if (sel & ~we & (rn == 5'd3)) xmt_fs <= 8'h00;
	if (sel & ~we & (rn == 5'd24)) mpc <= 8'h00;

	if (sel & we) begin
		case (rn)
			5'd2:  xmt_fc   <= wdata;
			5'd5:  rcv_fc   <= wdata;
			5'd9:  int_mask <= wdata;
			5'd11: biu_cc   <= wdata & 8'hFE;
			5'd12: fifo_cc  <= wdata;
			5'd13: mac_cc   <= wdata;
			5'd14: pls_cc   <= wdata;
			5'd15: phy_cc   <= wdata & 8'h7F;
			5'd18: begin
				// LOGADDR wins over PHYADDR; either sets the pointer to 0
				iac  <= {1'b0, wdata[6:3], (wdata[2] & ~wdata[1]), wdata[1:0]};
				if (wdata[2] | wdata[1]) aptr <= 3'd0;
				if (wdata[1]) ladr_any <= 1'b0;
			end
			5'd20: if (iac[1]) begin
				if (wdata != 8'h00) ladr_any <= 1'b1;
				aptr <= aptr + 3'd1;
				if (aptr == 3'd7) iac[1] <= 1'b0;
			end
			5'd21: if (iac[2]) begin
				padr[aptr] <= wdata;
				if (aptr == 3'd5) begin
					aptr    <= 3'd0;
					iac[2]  <= 1'b0;
				end
				else aptr <= aptr + 3'd1;
			end
			5'd29: utr      <= wdata;
			default: ;
		endcase
	end

	if (reset | swrst) begin
		xmt_fc    <= 8'h00;
		rcv_fc    <= 8'h01;
		int_stat  <= 8'h00;
		int_mask  <= 8'h00;
		biu_cc    <= 8'h00;
		fifo_cc   <= 8'h00;
		mac_cc    <= 8'h00;
		pls_cc    <= 8'h00;
		phy_cc    <= 8'h00;
		iac       <= 8'h00;
		utr       <= 8'h00;
		xmt_fs    <= 8'h00;
		mpc       <= 8'h00;
		aptr      <= 3'd0;
		ladr_any  <= 1'b0;
		f_len     <= 12'd0;
		f_held    <= 1'b0;
		f_wire    <= 1'b0;
		f_loop    <= 1'b0;
		f_us      <= 12'd0;
		t_word    <= 64'd0;
		tx_seen   <= tx_done;
		r_wt      <= 2'd0;
		r_ok      <= 1'b0;
		lb_pend   <= 1'b0;
		r_lb      <= 1'b0;
		// a frame in hand is given back (the bridge waits for it)
		if (rs != R_IDLE && !r_lb) begin rx_seen <= rx_avail; rx_done <= ~rx_done; end
		rs        <= R_IDLE;
	end
end

// the toggles keep step across resets
initial begin
	tx_go   = 1'b0;
	rx_done = 1'b0;
	rx_seen = 1'b0;
end

endmodule
